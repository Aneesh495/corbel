import 'dart:convert';
import 'dart:typed_data';
import 'byte_buffer.dart';
import 'checksum.dart';
import 'directory.dart';
import 'index_input.dart';
import 'index_output.dart';

/// WAL Record Types.
enum WalRecordType {
  insertDoc(1),
  updateDoc(2),
  deleteDoc(3),
  commitSegment(4),
  rollback(5);

  final int code;
  const WalRecordType(this.code);

  static WalRecordType fromCode(int code) {
    for (final t in WalRecordType.values) {
      if (t.code == code) return t;
    }
    throw FormatException('Unknown WAL record type code: $code');
  }
}

/// Single immutable transaction record decoded from WAL.
class WalRecord {
  /// Monotonically increasing Log Sequence Number.
  final int lsn;

  /// Transaction operation type.
  final WalRecordType type;

  /// Document identifier associated with this operation.
  final String docId;

  /// Document payload data (null for delete or commit records).
  final Map<String, dynamic>? data;

  const WalRecord({
    required this.lsn,
    required this.type,
    required this.docId,
    this.data,
  });

  @override
  String toString() => 'WalRecord(lsn: $lsn, type: ${type.name}, docId: $docId)';
}

/// Write-Ahead Log (WAL) engine ensuring crash resilience and durability.
class WriteAheadLog {
  static const int magicHeader = 0x57414C31; // 'WAL1'
  static const int walVersion = 1;

  final Directory _directory;
  final String _fileName;
  IndexOutput? _output;
  int _nextLsn = 1;
  bool _closed = false;

  WriteAheadLog(this._directory, [this._fileName = 'corbel.wal']);

  /// Opens or creates the WAL file, reading existing LSN if present.
  void open() {
    _checkNotClosed();
    if (_directory.fileExists(_fileName)) {
      final records = recover();
      if (records.isNotEmpty) {
        _nextLsn = records.last.lsn + 1;
      }
    } else {
      final out = _directory.createOutput(_fileName);
      out.writeInt32(magicHeader);
      out.writeInt32(walVersion);
      out.close();
    }
    _output = _directory.createOutput(_fileName);
  }

  /// Appends an insert document record to the WAL.
  int appendInsert(String docId, Map<String, dynamic> data) {
    return _appendRecord(WalRecordType.insertDoc, docId, data);
  }

  /// Appends a delete document record to the WAL.
  int appendDelete(String docId) {
    return _appendRecord(WalRecordType.deleteDoc, docId, null);
  }

  /// Appends a segment commit marker record.
  int appendCommit(String segmentName) {
    return _appendRecord(WalRecordType.commitSegment, segmentName, null);
  }

  int _appendRecord(WalRecordType type, String docId, Map<String, dynamic>? data) {
    _checkNotClosed();
    final lsn = _nextLsn++;

    final payloadWriter = ByteBufferWriter();
    payloadWriter.writeString(docId);
    if (data != null) {
      final jsonStr = jsonEncode(data);
      payloadWriter.writeString(jsonStr);
    } else {
      payloadWriter.writeString('');
    }
    final payloadBytes = payloadWriter.toBytes();

    // Compute CRC32C over: LSN (8 bytes) + type (1 byte) + payload
    final crc = CRC32C();
    final headerBuf = ByteData(9)
      ..setInt64(0, lsn)
      ..setUint8(8, type.code);
    crc.update(Uint8List.sublistView(headerBuf));
    crc.update(payloadBytes);

    final out = _output!;
    final frameLen = 9 + payloadBytes.length; // LSN (8) + type (1) + payload
    out.writeInt32(frameLen);
    out.writeInt64(lsn);
    out.writeByte(type.code);
    out.writeBytes(payloadBytes);
    out.writeUint32(crc.value);

    return lsn;
  }

  /// Replays and verifies WAL records from storage, stopping gracefully at any corrupted tail.
  List<WalRecord> recover() {
    if (!_directory.fileExists(_fileName)) return [];

    final input = _directory.openInput(_fileName);
    final records = <WalRecord>[];

    try {
      if (input.length < 8) return [];
      final magic = input.readInt32();
      if (magic != magicHeader) return [];
      final ver = input.readInt32();
      if (ver != walVersion) return [];

      while (input.remaining >= 4) {
        final frameLen = input.readInt32();
        if (frameLen <= 9 || input.remaining < frameLen + 4) {
          // Truncated trailing record
          break;
        }

        final lsn = input.readInt64();
        final typeCode = input.readByte();
        final payloadLen = frameLen - 9;
        final payloadBytes = input.readBytes(payloadLen);
        final expectedCrc = input.readUint32();

        // Verify CRC
        final crc = CRC32C();
        final headerBuf = ByteData(9)
          ..setInt64(0, lsn)
          ..setUint8(8, typeCode);
        crc.update(Uint8List.sublistView(headerBuf));
        crc.update(payloadBytes);

        if (crc.value != expectedCrc) {
          // Corruption detected at this frame: stop replay safely
          break;
        }

        final payloadReader = ByteBufferReader(payloadBytes);
        final docId = payloadReader.readString();
        final jsonStr = payloadReader.readString();
        Map<String, dynamic>? data;
        if (jsonStr.isNotEmpty) {
          data = jsonDecode(jsonStr) as Map<String, dynamic>;
        }

        records.add(WalRecord(
          lsn: lsn,
          type: WalRecordType.fromCode(typeCode),
          docId: docId,
          data: data,
        ));
      }
    } catch (_) {
      // Any parsing failure on crash boundary safely terminates log replay
    } finally {
      input.close();
    }

    return records;
  }

  /// Truncates the WAL after a successful segment flush checkpoint.
  void truncate() {
    _checkNotClosed();
    _output?.close();
    _directory.deleteFile(_fileName);

    final out = _directory.createOutput(_fileName);
    out.writeInt32(magicHeader);
    out.writeInt32(walVersion);
    out.close();

    _output = _directory.createOutput(_fileName);
    _nextLsn = 1;
  }

  /// Flushes all pending writes to directory storage.
  void sync() {
    _checkNotClosed();
    _directory.sync([_fileName]);
  }

  /// Closes the write-ahead log.
  void close() {
    if (!_closed) {
      _output?.close();
      _output = null;
      _closed = true;
    }
  }

  void _checkNotClosed() {
    if (_closed) throw StateError('WriteAheadLog is closed');
  }
}
