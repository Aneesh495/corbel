import 'dart:convert';
import 'dart:typed_data';
import 'checksum.dart';
import 'vbyte.dart';

/// Abstract output stream for writing index segments with automatic CRC32C tracking.
abstract class IndexOutput {
  final CRC32C _crc = CRC32C();

  /// Current write position in bytes.
  int get position;

  /// Writes single 8-bit byte.
  void writeByte(int byte) {
    _crc.updateByte(byte);
  }

  /// Writes sequence of raw bytes.
  void writeBytes(List<int> bytes, [int offset = 0, int? length]) {
    final count = length ?? (bytes.length - offset);
    _crc.update(bytes, offset, count);
  }

  /// Writes signed 16-bit integer (big endian).
  void writeInt16(int value) {
    writeByte((value >> 8) & 0xFF);
    writeByte(value & 0xFF);
  }

  /// Writes signed 32-bit integer (big endian).
  void writeInt32(int value) {
    writeByte((value >> 24) & 0xFF);
    writeByte((value >> 16) & 0xFF);
    writeByte((value >> 8) & 0xFF);
    writeByte(value & 0xFF);
  }

  /// Writes unsigned 32-bit integer (big endian).
  void writeUint32(int value) {
    writeInt32(value);
  }

  /// Writes signed 64-bit integer (big endian).
  void writeInt64(int value) {
    for (var i = 7; i >= 0; i--) {
      writeByte((value >> (i * 8)) & 0xFF);
    }
  }

  /// Writes 32-bit IEEE 754 float.
  void writeFloat32(double value) {
    final data = ByteData(4)..setFloat32(0, value);
    for (var i = 0; i < 4; i++) {
      writeByte(data.getUint8(i));
    }
  }

  /// Writes 64-bit IEEE 754 float.
  void writeFloat64(double value) {
    final data = ByteData(8)..setFloat64(0, value);
    for (var i = 0; i < 8; i++) {
      writeByte(data.getUint8(i));
    }
  }

  /// Writes length-prefixed UTF-8 string.
  void writeString(String text) {
    final encoded = utf8.encode(text);
    writeInt32(encoded.length);
    writeBytes(encoded);
  }

  /// Writes unsigned variable-byte 32-bit int.
  void writeVInt(int value) {
    var v = value & 0xFFFFFFFF;
    while ((v & ~0x7F) != 0) {
      writeByte((v & 0x7F) | 0x80);
      v >>= 7;
    }
    writeByte(v & 0x7F);
  }

  /// Writes unsigned variable-byte 64-bit int.
  void writeVLong(int value) {
    var v = value;
    while ((v & ~0x7F) != 0) {
      writeByte((v & 0x7F) | 0x80);
      v >>= 7;
    }
    writeByte(v & 0x7F);
  }

  /// Writes signed ZigZag 32-bit int.
  void writeZInt(int value) {
    writeVInt(VByteCodec.encodeZigZag32(value));
  }

  /// Writes signed ZigZag 64-bit int.
  void writeZLong(int value) {
    writeVLong(VByteCodec.encodeZigZag64(value));
  }

  /// Current computed 32-bit CRC32C checksum of all written bytes.
  int get checksum => _crc.value;

  /// Closes the output stream.
  void close();
}

/// In-memory implementation of IndexOutput.
class RAMIndexOutput extends IndexOutput {
  final List<Uint8List> _blocks = [];
  static const int blockSize = 1024;
  int _currentBlockIndex = 0;
  int _currentBlockOffset = 0;
  int _totalLength = 0;
  bool _closed = false;

  RAMIndexOutput() {
    _blocks.add(Uint8List(blockSize));
  }

  @override
  int get position => _totalLength;

  @override
  void writeByte(int byte) {
    _checkOpen();
    super.writeByte(byte);
    if (_currentBlockOffset == blockSize) {
      _blocks.add(Uint8List(blockSize));
      _currentBlockIndex++;
      _currentBlockOffset = 0;
    }
    _blocks[_currentBlockIndex][_currentBlockOffset++] = byte & 0xFF;
    _totalLength++;
  }

  @override
  void writeBytes(List<int> bytes, [int offset = 0, int? length]) {
    _checkOpen();
    final count = length ?? (bytes.length - offset);
    for (var i = 0; i < count; i++) {
      writeByte(bytes[offset + i]);
    }
  }

  /// Returns consolidated raw byte array of all written content.
  Uint8List toByteArray() {
    final result = Uint8List(_totalLength);
    var pos = 0;
    for (var i = 0; i < _blocks.length; i++) {
      final block = _blocks[i];
      final bytesInBlock = (i == _blocks.length - 1) ? _currentBlockOffset : blockSize;
      result.setRange(pos, pos + bytesInBlock, block);
      pos += bytesInBlock;
    }
    return result;
  }

  @override
  void close() {
    _closed = true;
  }

  void _checkOpen() {
    if (_closed) throw StateError('Cannot write to closed RAMIndexOutput');
  }
}
