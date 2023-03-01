import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';
import 'package:corbel/src/storage/checksum.dart';
import 'package:corbel/src/storage/directory.dart';
import 'package:corbel/src/storage/wal.dart';
import 'package:test/test.dart';

void main() {
  group('Checksum Tests (CRC32C and XXHash64)', () {
    test('CRC32C matches standard Castagnoli vector for "123456789"', () {
      final input = utf8.encode('123456789');
      final crc = CRC32C.compute(input);
      // Standard CRC32C of '123456789' is 0xE3069283
      expect(crc, equals(0xE3069283));
    });

    test('XXHash64 generates non-zero deterministic hashes', () {
      final input = utf8.encode('Corbel Information Retrieval Kernel');
      final h1 = XXHash64.hash(input, 0);
      final h2 = XXHash64.hash(input, 0);
      final h3 = XXHash64.hash(input, 42);

      expect(h1, equals(h2));
      expect(h1, isNot(equals(h3)));
      expect(h1, isNot(equals(0)));
    });
  });

  group('Directory and File System Tests (RAMDirectory & DiskDirectory)', () {
    test('RAMDirectory file lifecycle: write, read, rename, delete', () {
      final dir = RAMDirectory();
      expect(dir.listAll(), isEmpty);

      // Create and write file
      final out = dir.createOutput('test.idx');
      out.writeString('Header');
      out.writeInt64(1234567890123);
      out.close();

      expect(dir.fileExists('test.idx'), isTrue);
      expect(dir.fileLength('test.idx'), greaterThan(0));
      expect(dir.listAll(), contains('test.idx'));

      // Read file
      final inp = dir.openInput('test.idx');
      expect(inp.readString(), equals('Header'));
      expect(inp.readInt64(), equals(1234567890123));
      inp.close();

      // Rename file
      dir.rename('test.idx', 'renamed.idx');
      expect(dir.fileExists('test.idx'), isFalse);
      expect(dir.fileExists('renamed.idx'), isTrue);

      // Delete file
      dir.deleteFile('renamed.idx');
      expect(dir.fileExists('renamed.idx'), isFalse);
      expect(dir.listAll(), isEmpty);
    });

    test('RAMDirectory mutual exclusion locking', () {
      final dir = RAMDirectory();
      final lock1 = dir.obtainLock('write');
      expect(lock1.isValid, isTrue);

      // Attempting second lock must throw
      expect(() => dir.obtainLock('write'), throwsA(isA<io.FileSystemException>()));

      lock1.release();
      expect(lock1.isValid, isFalse);

      // Now lock can be acquired again
      final lock2 = dir.obtainLock('write');
      expect(lock2.isValid, isTrue);
      lock2.release();
    });

    test('DiskDirectory file lifecycle and persistence on disk', () {
      final tempDir = io.Directory.systemTemp.createTempSync('corbel_disk_test_');
      try {
        final dir = DiskDirectory(tempDir.path);
        final out = dir.createOutput('segment.data');
        out.writeString('Persisted Data');
        out.writeInt32(9999);
        out.close();

        expect(dir.fileExists('segment.data'), isTrue);

        final inp = dir.openInput('segment.data');
        expect(inp.readString(), equals('Persisted Data'));
        expect(inp.readInt32(), equals(9999));
        inp.close();

        // Lock test on disk
        final lock = dir.obtainLock('writer');
        expect(lock.isValid, isTrue);
        expect(() => dir.obtainLock('writer'), throwsA(isA<io.FileSystemException>()));
        lock.release();

        dir.close();
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });

  group('WriteAheadLog (WAL) Recovery and Durability Tests', () {
    test('WAL append, recover, and replay', () {
      final dir = RAMDirectory();
      final wal = WriteAheadLog(dir);
      wal.open();

      final lsn1 = wal.appendInsert('doc_1', {'title': 'Systems Engineering'});
      final lsn2 = wal.appendInsert('doc_2', {'title': 'Distributed Consensus'});
      final lsn3 = wal.appendDelete('doc_1');
      final lsn4 = wal.appendCommit('_0');

      expect(lsn1, equals(1));
      expect(lsn2, equals(2));
      expect(lsn3, equals(3));
      expect(lsn4, equals(4));

      wal.sync();
      wal.close();

      // Open new WAL instance to recover
      final recoverWal = WriteAheadLog(dir);
      final records = recoverWal.recover();

      expect(records.length, equals(4));
      expect(records[0].lsn, equals(1));
      expect(records[0].type, equals(WalRecordType.insertDoc));
      expect(records[0].docId, equals('doc_1'));
      expect(records[0].data!['title'], equals('Systems Engineering'));

      expect(records[1].lsn, equals(2));
      expect(records[1].type, equals(WalRecordType.insertDoc));

      expect(records[2].lsn, equals(3));
      expect(records[2].type, equals(WalRecordType.deleteDoc));
      expect(records[2].docId, equals('doc_1'));

      expect(records[3].lsn, equals(4));
      expect(records[3].type, equals(WalRecordType.commitSegment));
      expect(records[3].docId, equals('_0'));
    });

    test('WAL crash recovery stops safely before corrupted/truncated tail', () {
      final dir = RAMDirectory();
      final wal = WriteAheadLog(dir);
      wal.open();
      wal.appendInsert('doc_1', {'key': 'val1'});
      wal.appendInsert('doc_2', {'key': 'val2'});
      wal.close();

      // Read WAL bytes and append corrupt garbage bytes at tail simulating mid-write crash
      final bytes = dir.openInput('corbel.wal').readBytes(dir.fileLength('corbel.wal'));
      final corruptBytes = Uint8List(bytes.length + 7);
      corruptBytes.setRange(0, bytes.length, bytes);
      corruptBytes.setRange(bytes.length, corruptBytes.length, [0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03]);

      dir.deleteFile('corbel.wal');
      final out = dir.createOutput('corbel.wal');
      out.writeBytes(corruptBytes);
      out.close();

      // Recovery should yield the 2 valid records and ignore the corrupted tail
      final recoverWal = WriteAheadLog(dir);
      final records = recoverWal.recover();

      expect(records.length, equals(2));
      expect(records[0].docId, equals('doc_1'));
      expect(records[1].docId, equals('doc_2'));
    });
  });
}
