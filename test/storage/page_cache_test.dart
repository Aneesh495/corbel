import 'dart:typed_data';
import 'package:corbel/corbel.dart';
import 'package:test/test.dart';

void main() {
  group('Replacer Algorithm Tests', () {
    test('ClockReplacer second-chance circular eviction', () {
      final replacer = ClockReplacer(3);
      expect(replacer.size, equals(0));

      // Unpin frames 0, 1, 2
      replacer.unpin(0);
      replacer.unpin(1);
      replacer.unpin(2);
      expect(replacer.size, equals(3));

      // Record access to frame 0 and 1 (sets reference bit)
      replacer.recordAccess(0);
      replacer.recordAccess(1);

      // Victim selection: frame 2 has not been referenced since unpin,
      // so clock hand clears bits on 0 and 1 and evicts frame 2!
      final victim1 = replacer.victim();
      expect(victim1, equals(2));
      expect(replacer.size, equals(2));

      // Pin frame 0
      replacer.pin(0);
      expect(replacer.size, equals(1));

      // Next victim must be frame 1
      final victim2 = replacer.victim();
      expect(victim2, equals(1));
      expect(replacer.size, equals(0));

      // No more frames eligible
      expect(replacer.victim(), isNull);
    });

    test('TwoQueueReplacer separates single-touch from re-referenced frames', () {
      final replacer = TwoQueueReplacer(4);

      replacer.unpin(0);
      replacer.unpin(1);
      replacer.unpin(2);
      expect(replacer.size, equals(3));

      // Frame 0 is accessed a second time: promotes to Am queue
      replacer.recordAccess(0);

      // Eviction order: should evict from A1in first (frame 1, then frame 2)
      final v1 = replacer.victim();
      expect(v1, equals(1));

      final v2 = replacer.victim();
      expect(v2, equals(2));

      // Finally evicts frequently accessed frame 0
      final v3 = replacer.victim();
      expect(v3, equals(0));
    });
  });

  group('BufferPoolManager Lifecycle and Eviction Tests', () {
    late Directory dir;

    setUp(() {
      dir = RAMDirectory();
    });

    tearDown(() {
      dir.close();
    });

    test('fetchPage caches pages and records hits and misses', () {
      final bpm = BufferPoolManager(
        directory: dir,
        poolSize: 2,
        pageSize: 128,
      );

      final p0 = const PageId('test.bin', 0);
      final p1 = const PageId('test.bin', 1);

      // Miss 1
      final frame0 = bpm.fetchPage(p0);
      expect(frame0.pinCount, equals(1));
      bpm.unpinPage(p0);

      // Miss 2
      final frame1 = bpm.fetchPage(p1);
      expect(frame1.pinCount, equals(1));
      bpm.unpinPage(p1);

      // Hit 1
      final frame0Hit = bpm.fetchPage(p0);
      expect(frame0Hit.frameId, equals(frame0.frameId));
      bpm.unpinPage(p0);

      final stats = bpm.stats;
      expect(stats.misses, equals(2));
      expect(stats.hits, equals(1));
      expect(stats.hitRatio, closeTo(1.0 / 3.0, 1e-3));

      bpm.close();
    });

    test('evicts dirty pages and flushes modified contents to disk', () {
      final bpm = BufferPoolManager(
        directory: dir,
        poolSize: 2,
        pageSize: 64,
      );

      final p0 = const PageId('data.bin', 0);
      final p1 = const PageId('data.bin', 1);
      final p2 = const PageId('data.bin', 2);

      // Write data to page 0
      final f0 = bpm.fetchPage(p0);
      f0.data[0] = 42;
      f0.data[1] = 99;
      bpm.unpinPage(p0, isDirty: true);

      // Fetch page 1
      bpm.fetchPage(p1);
      bpm.unpinPage(p1);

      // Fetch page 2: buffer pool size is 2, so this triggers eviction of page 0!
      bpm.fetchPage(p2);
      bpm.unpinPage(p2);

      expect(bpm.stats.evictions, equals(1));
      expect(bpm.stats.flushes, equals(1));

      // Verify page 0 was written to underlying storage
      final diskInput = dir.openInput('data.bin');
      final diskBytes = diskInput.readBytes(64);
      expect(diskBytes[0], equals(42));
      expect(diskBytes[1], equals(99));
      diskInput.close();

      bpm.close();
    });

    test('throws StateError when buffer pool is exhausted with pinned frames', () {
      final bpm = BufferPoolManager(
        directory: dir,
        poolSize: 1,
        pageSize: 64,
      );

      final p0 = const PageId('pinned.bin', 0);
      final p1 = const PageId('pinned.bin', 1);

      // Fetch page 0 and DO NOT unpin it
      bpm.fetchPage(p0);

      // Attempting to fetch page 1 while frame 0 is pinned must throw StateError
      expect(() => bpm.fetchPage(p1), throwsStateError);

      bpm.unpinPage(p0);
      bpm.close();
    });
  });

  group('PagedIndexOutput and PagedIndexInput Stream Tests', () {
    late Directory dir;
    late BufferPoolManager bpm;

    setUp(() {
      dir = RAMDirectory();
      bpm = BufferPoolManager(
        directory: dir,
        poolSize: 4,
        pageSize: 256, // Small 256-byte page size to test boundary spanning
      );
    });

    tearDown(() {
      bpm.close();
      dir.close();
    });

    test('writes and reads data spanning multiple page boundaries', () {
      final out = PagedIndexOutput(bufferPool: bpm, fileName: 'multi_page.dat');

      // Write 2000 bytes (spans ~8 pages of 256 bytes)
      final rawData = Uint8List(2000);
      for (var i = 0; i < 2000; i++) {
        rawData[i] = (i * 7) & 0xFF;
      }

      out.writeBytes(rawData);
      out.writeInt32(12345678);
      out.writeInt64(9876543210123);
      out.writeFloat64(3.1415926535);
      out.writeString('corbel high-throughput page cache');
      out.close();

      // Read back with PagedIndexInput
      final fileLen = dir.fileLength('multi_page.dat');
      final input = PagedIndexInput(
        bufferPool: bpm,
        fileName: 'multi_page.dat',
        fileLength: fileLen,
      );

      final readBytes = input.readBytes(2000);
      expect(readBytes, equals(rawData));

      expect(input.readInt32(), equals(12345678));
      expect(input.readInt64(), equals(9876543210123));
      expect(input.readFloat64(), closeTo(3.1415926535, 1e-9));
      expect(input.readString(), equals('corbel high-throughput page cache'));

      // Test seek and clone
      input.seek(100);
      expect(input.readByte(), equals(rawData[100]));

      final cloned = input.clone();
      expect(cloned.position, equals(101));
      expect(cloned.readByte(), equals(rawData[101]));

      input.close();
      cloned.close();
    });
  });
}
