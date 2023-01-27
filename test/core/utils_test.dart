import 'dart:typed_data';
import 'package:corbel/src/utils/bit_vector.dart';
import 'package:corbel/src/utils/bytes_ref.dart';
import 'package:corbel/src/utils/priority_queue.dart';
import 'package:test/test.dart';

void main() {
  group('PriorityQueue and BoundedPriorityQueue Tests', () {
    test('min-heap orders integers in ascending order', () {
      final pq = PriorityQueue<int>((a, b) => a.compareTo(b));
      final numbers = [45, 12, 89, 3, 27, 64, 18, 3, 100];
      for (final n in numbers) {
        pq.add(n);
      }

      expect(pq.length, equals(numbers.length));
      expect(pq.top, equals(3));

      final extracted = <int>[];
      while (pq.isNotEmpty) {
        extracted.add(pq.pop());
      }

      expect(extracted, equals([3, 3, 12, 18, 27, 45, 64, 89, 100]));
    });

    test('bounded priority queue retains exactly top-K highest elements', () {
      // Min-heap comparator where smaller score sits at root (weakest)
      final bpq = BoundedPriorityQueue<double>(
        3,
        (a, b) => a.compareTo(b),
      );

      final scores = [0.12, 0.95, 0.45, 0.78, 0.05, 0.88, 0.33, 0.99, 0.65];
      for (final s in scores) {
        bpq.insertWithOverflow(s);
      }

      expect(bpq.length, equals(3));
      // Top 3 should be 0.99, 0.95, 0.88
      final descending = bpq.drainToListDescending();
      expect(descending.length, equals(3));
      expect(descending[0], closeTo(0.99, 0.001));
      expect(descending[1], closeTo(0.95, 0.001));
      expect(descending[2], closeTo(0.88, 0.001));
    });

    test('bounded priority queue under-capacity behaves correctly', () {
      final bpq = BoundedPriorityQueue<int>(5, (a, b) => a.compareTo(b));
      bpq.insertWithOverflow(40);
      bpq.insertWithOverflow(20);

      expect(bpq.length, equals(2));
      expect(bpq.top, equals(20));
      expect(bpq.drainToListDescending(), equals([40, 20]));
    });
  });

  group('BitVector Tests', () {
    test('setting, getting, clearing, and cardinality', () {
      final bv = BitVector(128);
      expect(bv.cardinality(), equals(0));
      expect(bv.isEmpty, isTrue);

      bv.set(5);
      bv.set(63);
      bv.set(64);
      bv.set(127);
      bv.set(200); // Dynamic expansion

      expect(bv.cardinality(), equals(5));
      expect(bv.get(5), isTrue);
      expect(bv.get(63), isTrue);
      expect(bv.get(64), isTrue);
      expect(bv.get(127), isTrue);
      expect(bv.get(200), isTrue);
      expect(bv.get(6), isFalse);
      expect(bv.get(199), isFalse);

      bv.clear(63);
      expect(bv.get(63), isFalse);
      expect(bv.cardinality(), equals(4));

      bv.flip(5);
      expect(bv.get(5), isFalse);
      expect(bv.cardinality(), equals(3));
    });

    test('nextSetBit navigation', () {
      final bv = BitVector(256);
      bv.set(10);
      bv.set(70);
      bv.set(71);
      bv.set(190);

      expect(bv.nextSetBit(0), equals(10));
      expect(bv.nextSetBit(10), equals(10));
      expect(bv.nextSetBit(11), equals(70));
      expect(bv.nextSetBit(70), equals(70));
      expect(bv.nextSetBit(71), equals(71));
      expect(bv.nextSetBit(72), equals(190));
      expect(bv.nextSetBit(191), equals(-1));
    });

    test('nextClearBit navigation', () {
      final bv = BitVector(10);
      bv.set(0);
      bv.set(1);
      bv.set(2);

      expect(bv.nextClearBit(0), equals(3));
      expect(bv.nextClearBit(3), equals(3));
    });

    test('bitwise set algebra: AND, OR, XOR, AND-NOT', () {
      final a = BitVector(100);
      final b = BitVector(100);

      a.set(1);
      a.set(2);
      a.set(3);

      b.set(2);
      b.set(3);
      b.set(4);

      final andBv = a.clone()..and(b);
      expect(andBv.cardinality(), equals(2));
      expect(andBv.get(2), isTrue);
      expect(andBv.get(3), isTrue);
      expect(andBv.get(1), isFalse);

      final orBv = a.clone()..or(b);
      expect(orBv.cardinality(), equals(4));
      expect(orBv.get(1), isTrue);
      expect(orBv.get(2), isTrue);
      expect(orBv.get(3), isTrue);
      expect(orBv.get(4), isTrue);

      final xorBv = a.clone()..xor(b);
      expect(xorBv.cardinality(), equals(2));
      expect(xorBv.get(1), isTrue);
      expect(xorBv.get(4), isTrue);
      expect(xorBv.get(2), isFalse);

      final andNotBv = a.clone()..andNot(b);
      expect(andNotBv.cardinality(), equals(1));
      expect(andNotBv.get(1), isTrue);
      expect(andNotBv.get(2), isFalse);
    });
  });

  group('BytesRef and BytesRefBuilder Tests', () {
    test('BytesRef lexicographical ordering', () {
      final apple = BytesRef.fromString('apple');
      final banana = BytesRef.fromString('banana');
      final app = BytesRef.fromString('app');
      final appleCopy = BytesRef.fromString('apple');

      expect(apple.compareTo(banana), lessThan(0));
      expect(banana.compareTo(apple), greaterThan(0));
      expect(app.compareTo(apple), lessThan(0));
      expect(apple.compareTo(appleCopy), equals(0));
      expect(apple == appleCopy, isTrue);
      expect(apple.hashCode, equals(appleCopy.hashCode));
    });

    test('BytesRef slice without memory copy', () {
      final raw = Uint8List.fromList([10, 20, 30, 40, 50, 60]);
      final ref = BytesRef(raw, 1, 4); // [20, 30, 40, 50]

      expect(ref.length, equals(4));
      expect(ref[0], equals(20));
      expect(ref[3], equals(50));

      final sub = ref.slice(1, 2); // [30, 40]
      expect(sub.length, equals(2));
      expect(sub[0], equals(30));
      expect(sub[1], equals(40));
    });

    test('BytesRefBuilder dynamic accumulation', () {
      final builder = BytesRefBuilder(4);
      builder.append(65); // 'A'
      builder.appendBytes([66, 67]); // 'B', 'C'
      builder.appendString('DEF');

      final ref = builder.toBytesRef();
      expect(ref.length, equals(6));
      expect(ref.utf8String(), equals('ABCDEF'));

      final arr = builder.toByteArray();
      expect(arr, equals(Uint8List.fromList([65, 66, 67, 68, 69, 70])));
    });
  });
}
