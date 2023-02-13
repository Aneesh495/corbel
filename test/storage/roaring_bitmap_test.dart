import 'package:corbel/src/storage/byte_buffer.dart';
import 'package:corbel/src/storage/roaring_bitmap.dart';
import 'package:test/test.dart';

void main() {
  group('RoaringBitmap and Container Transition Tests', () {
    test('sparse additions remain in ArrayContainer', () {
      final rb = RoaringBitmap();
      rb.add(10);
      rb.add(500);
      rb.add(25);
      rb.add(1000);

      expect(rb.cardinality, equals(4));
      expect(rb.contains(10), isTrue);
      expect(rb.contains(25), isTrue);
      expect(rb.contains(500), isTrue);
      expect(rb.contains(1000), isTrue);
      expect(rb.contains(999), isFalse);
      expect(rb.toList(), equals([10, 25, 500, 1000]));
    });

    test('promotion from ArrayContainer to BitmapContainer at threshold > 4096', () {
      final rb = RoaringBitmap();
      // Add 4096 elements
      for (var i = 0; i < 4096; i++) {
        rb.add(i * 2);
      }
      expect(rb.cardinality, equals(4096));

      // 4097th element triggers promotion to BitmapContainer
      rb.add(1);
      expect(rb.cardinality, equals(4097));
      expect(rb.contains(1), isTrue);
      for (var i = 0; i < 4096; i++) {
        expect(rb.contains(i * 2), isTrue);
      }

      // Demotion back to ArrayContainer
      rb.remove(1);
      expect(rb.cardinality, equals(4096));
      expect(rb.contains(1), isFalse);
    });

    test('multi-chunk 32-bit values spanning distinct 16-bit blocks', () {
      final rb = RoaringBitmap();
      final values = [5, 65536 + 10, 131072 + 50, 2000000];
      rb.addAll(values);

      expect(rb.cardinality, equals(values.length));
      for (final v in values) {
        expect(rb.contains(v), isTrue);
      }
      expect(rb.contains(65536), isFalse);
      expect(rb.toList(), equals(values));
    });

    test('set operations: AND, OR, XOR, ANDNOT', () {
      final rb1 = RoaringBitmap();
      final rb2 = RoaringBitmap();

      rb1.addAll([1, 2, 3, 4, 100000]);
      rb2.addAll([3, 4, 5, 6, 100000]);

      final intersection = rb1.and(rb2);
      expect(intersection.toList(), equals([3, 4, 100000]));

      final union = rb1.or(rb2);
      expect(union.toList(), equals([1, 2, 3, 4, 5, 6, 100000]));

      final xor = rb1.xor(rb2);
      expect(xor.toList(), equals([1, 2, 5, 6]));

      final diff = rb1.andNot(rb2);
      expect(diff.toList(), equals([1, 2]));
    });

    test('RunContainer contiguous sequence handling', () {
      final runs = List<int>.generate(500, (i) => 100 + i); // 100 to 599
      final rc = RunContainer.fromList(runs);

      expect(rc.cardinality, equals(500));
      expect(rc.contains(100), isTrue);
      expect(rc.contains(350), isTrue);
      expect(rc.contains(599), isTrue);
      expect(rc.contains(600), isFalse);
      expect(rc.toList(), equals(runs));
    });

    test('serialization and deserialization round-trip', () {
      final rb = RoaringBitmap();
      // Add sparse elements in block 0
      rb.addAll([12, 99, 450]);
      // Add dense block in block 1
      for (var i = 0; i < 5000; i++) {
        rb.add(65536 + i);
      }
      // Add run block in block 2
      for (var i = 0; i < 300; i++) {
        rb.add(131072 + i);
      }

      final writer = ByteBufferWriter();
      rb.serialize(writer);

      final reader = ByteBufferReader(writer.toBytes());
      final restored = RoaringBitmap.deserialize(reader);

      expect(restored.cardinality, equals(rb.cardinality));
      expect(restored.contains(12), isTrue);
      expect(restored.contains(99), isTrue);
      expect(restored.contains(65536 + 2500), isTrue);
      expect(restored.contains(131072 + 150), isTrue);
      expect(restored.toList(), equals(rb.toList()));
    });
  });
}
