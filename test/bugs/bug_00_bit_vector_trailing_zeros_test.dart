import 'package:corbel/src/utils/bit_vector.dart';
import 'package:test/test.dart';

/// Bug 0: In 64-bit BitVector nextSetBit navigation, manual bit-shift cascade
/// caused arithmetic overflow on intermediate 32-bit registers.
/// Resolution: Implemented signed two's complement lowest-bit isolation (i & -i)
/// with 64-bit sign-bit guard.
void main() {
  group('Bug Regression: BitVector Trailing Zeros and Navigation', () {
    test('all 64-bit boundaries are accurately resolved', () {
      final bv = BitVector(1000);
      for (var i = 0; i < 256; i++) {
        bv.set(i);
        expect(bv.nextSetBit(i), equals(i));
        bv.clear(i);
      }
    });

    test('isolated sparse bit navigation across word boundaries', () {
      final bv = BitVector(512);
      final setIndices = [0, 1, 10, 63, 64, 65, 127, 128, 255, 256, 500];
      for (final idx in setIndices) {
        bv.set(idx);
      }

      var current = 0;
      final retrieved = <int>[];
      while (true) {
        final next = bv.nextSetBit(current);
        if (next == -1) break;
        retrieved.add(next);
        current = next + 1;
      }

      expect(retrieved, equals(setIndices));
    });
  });
}
