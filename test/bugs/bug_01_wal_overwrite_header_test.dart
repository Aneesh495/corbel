import 'package:corbel/src/storage/directory.dart';
import 'package:corbel/src/storage/wal.dart';
import 'package:test/test.dart';

/// Bug 1: WAL open() overwrote existing header by calling createOutput() twice,
/// resulting in corrupted/zero-byte WAL files upon recovery.
/// Resolution: Preserve existing bytes during reopen and write magic header once.
void main() {
  group('Bug Regression: WAL Header Preservation and Multi-Session Reopen', () {
    test('WAL retains records across multiple consecutive open/close sessions', () {
      final dir = RAMDirectory();

      // Session 1
      final wal1 = WriteAheadLog(dir);
      wal1.open();
      wal1.appendInsert('doc_1', {'session': 1});
      wal1.close();

      // Session 2
      final wal2 = WriteAheadLog(dir);
      wal2.open();
      wal2.appendInsert('doc_2', {'session': 2});
      wal2.close();

      // Recovery
      final recoverWal = WriteAheadLog(dir);
      final records = recoverWal.recover();

      expect(records.length, equals(2));
      expect(records[0].docId, equals('doc_1'));
      expect(records[1].docId, equals('doc_2'));
    });
  });
}
