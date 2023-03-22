import 'dart:math' as math;
import 'dart:typed_data';
import '../../storage/index_input.dart';
import '../../storage/index_output.dart';
import '../../storage/vbyte.dart';

/// Columnar 64-bit integer DocValues with GCD and delta-offset compression.
class NumericDocValues {
  final int minVal;
  final int gcd;
  final int numBits;
  final int count;
  final Uint8List _packedData;

  NumericDocValues._({
    required this.minVal,
    required this.gcd,
    required this.numBits,
    required this.count,
    required Uint8List packedData,
  }) : _packedData = packedData;

  /// Builds and serializes compressed NumericDocValues into output stream.
  static void write(IndexOutput out, List<int> values) {
    final count = values.length;
    VByteCodec.writeVInt(out, count);
    if (count == 0) return;

    var minVal = values[0];
    var maxVal = values[0];
    for (var i = 1; i < count; i++) {
      final v = values[i];
      if (v < minVal) minVal = v;
      if (v > maxVal) maxVal = v;
    }

    // Compute GCD across non-zero deltas
    var currentGcd = 0;
    for (var i = 0; i < count; i++) {
      final delta = values[i] - minVal;
      if (delta != 0) {
        currentGcd = currentGcd == 0 ? delta : _gcd(currentGcd, delta);
      }
    }
    if (currentGcd == 0) currentGcd = 1;

    final maxDividedDelta = (maxVal - minVal) ~/ currentGcd;
    final int numBits = maxDividedDelta == 0 ? 0 : maxDividedDelta.bitLength;

    VByteCodec.writeZLong(out, minVal);
    VByteCodec.writeVLong(out, currentGcd);
    out.writeByte(numBits);

    if (numBits == 0) return; // All values are identical to minVal

    // Bitpack divided deltas
    final totalBits = count * numBits;
    final packedBytes = Uint8List((totalBits + 7) >> 3);

    var bitPos = 0;
    for (var i = 0; i < count; i++) {
      final val = (values[i] - minVal) ~/ currentGcd;
      var bitsLeft = numBits;

      while (bitsLeft > 0) {
        final byteIdx = bitPos >> 3;
        final bitInByte = bitPos & 7;
        final bitsAvailable = 8 - bitInByte;
        final take = bitsLeft < bitsAvailable ? bitsLeft : bitsAvailable;
        final shift = bitsLeft - take;
        final chunk = (val >> shift) & ((1 << take) - 1);

        packedBytes[byteIdx] |= (chunk << (bitsAvailable - take));
        bitPos += take;
        bitsLeft -= take;
      }
    }

    VByteCodec.writeVInt(out, packedBytes.length);
    out.writeBytes(packedBytes);
  }

  /// Deserializes NumericDocValues from input stream.
  static NumericDocValues read(IndexInput inp) {
    final count = inp.readVInt();
    if (count == 0) {
      return NumericDocValues._(
        minVal: 0,
        gcd: 1,
        numBits: 0,
        count: 0,
        packedData: Uint8List(0),
      );
    }

    final minVal = inp.readZLong();
    final gcd = inp.readVLong();
    final numBits = inp.readByte();

    if (numBits == 0) {
      return NumericDocValues._(
        minVal: minVal,
        gcd: gcd,
        numBits: 0,
        count: count,
        packedData: Uint8List(0),
      );
    }

    final dataLen = inp.readVInt();
    final packed = inp.readBytes(dataLen);

    return NumericDocValues._(
      minVal: minVal,
      gcd: gcd,
      numBits: numBits,
      count: count,
      packedData: packed,
    );
  }

  /// O(1) random access retrieving the 64-bit integer for document [docId].
  int get(int docId) {
    if (docId < 0 || docId >= count) {
      throw RangeError.index(docId, this, 'docId', 'Document ID out of bounds', count);
    }
    if (numBits == 0) return minVal;

    var bitPos = docId * numBits;
    var bitsNeeded = numBits;
    var val = 0;

    while (bitsNeeded > 0) {
      final byteIdx = bitPos >> 3;
      final bitInByte = bitPos & 7;
      final bitsAvailable = 8 - bitInByte;
      final take = bitsNeeded < bitsAvailable ? bitsNeeded : bitsAvailable;
      final shift = bitsAvailable - take;
      final chunk = (_packedData[byteIdx] >> shift) & ((1 << take) - 1);

      val = (val << take) | chunk;
      bitPos += take;
      bitsNeeded -= take;
    }

    return minVal + val * gcd;
  }

  static int _gcd(int a, int b) {
    var x = a.abs();
    var y = b.abs();
    while (y != 0) {
      final t = y;
      y = x % y;
      x = t;
    }
    return x;
  }
}
