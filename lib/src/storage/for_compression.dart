import 'dart:typed_data';
import 'byte_buffer.dart';
import 'vbyte.dart';

/// Frame of Reference (FoR) bitpacking codec for 128-integer blocks.
/// Provides optimal compression ratio and SIMD-friendly unpacking for postings lists.
class FrameOfReference {
  /// Block size processed by each FoR frame.
  static const int blockSize = 128;

  /// Compresses a 128-integer block into writer stream.
  /// Format:
  /// - minValue: vLong
  /// - numBits: 1 byte (0 to 32)
  /// - packedBits: ceil(128 * numBits / 8) bytes
  static void encodeBlock(
    ByteBufferWriter writer,
    List<int> block, [
    int offset = 0,
  ]) {
    if (block.length - offset < blockSize) {
      throw ArgumentError(
          'Block must contain at least $blockSize elements starting at offset $offset');
    }

    var minVal = block[offset];
    var maxVal = minVal;
    for (var i = 1; i < blockSize; i++) {
      final v = block[offset + i];
      if (v < minVal) minVal = v;
      if (v > maxVal) maxVal = v;
    }

    VByteCodec.writeVLong(writer, minVal);

    final range = maxVal - minVal;
    final int numBits = range == 0 ? 0 : range.bitLength;
    writer.writeByte(numBits);

    if (numBits == 0) {
      // All values in this block are identical to minVal
      return;
    }

    _pack128(writer, block, offset, minVal, numBits);
  }

  /// Decodes a 128-integer block from reader stream into target output array.
  static void decodeBlock(
    ByteBufferReader reader,
    Int32List output, [
    int outputOffset = 0,
  ]) {
    final minVal = VByteCodec.readVLong(reader);
    final numBits = reader.readByte();

    if (numBits == 0) {
      for (var i = 0; i < blockSize; i++) {
        output[outputOffset + i] = minVal;
      }
      return;
    }

    _unpack128(reader, output, outputOffset, minVal, numBits);
  }

  static void _pack128(
    ByteBufferWriter writer,
    List<int> block,
    int offset,
    int minVal,
    int numBits,
  ) {
    var bitPos = 0;
    var currentByte = 0;

    for (var i = 0; i < blockSize; i++) {
      var val = block[offset + i] - minVal;
      var bitsLeft = numBits;

      while (bitsLeft > 0) {
        final bitsInCurrentByte = 8 - bitPos;
        final take = bitsLeft < bitsInCurrentByte ? bitsLeft : bitsInCurrentByte;
        final shift = bitsLeft - take;
        final chunk = (val >> shift) & ((1 << take) - 1);

        currentByte = (currentByte << take) | chunk;
        bitPos += take;
        bitsLeft -= take;

        if (bitPos == 8) {
          writer.writeByte(currentByte);
          bitPos = 0;
          currentByte = 0;
        }
      }
    }

    if (bitPos > 0) {
      currentByte <<= (8 - bitPos);
      writer.writeByte(currentByte);
    }
  }

  static void _unpack128(
    ByteBufferReader reader,
    Int32List output,
    int outputOffset,
    int minVal,
    int numBits,
  ) {
    var bitPos = 0;
    var currentByte = reader.readByte();

    for (var i = 0; i < blockSize; i++) {
      var val = 0;
      var bitsNeeded = numBits;

      while (bitsNeeded > 0) {
        final bitsAvailable = 8 - bitPos;
        final take = bitsNeeded < bitsAvailable ? bitsNeeded : bitsAvailable;
        final shift = bitsAvailable - take;
        final chunk = (currentByte >> shift) & ((1 << take) - 1);

        val = (val << take) | chunk;
        bitPos += take;
        bitsNeeded -= take;

        if (bitPos == 8) {
          if (i < blockSize - 1 || bitsNeeded > 0) {
            currentByte = reader.readByte();
          }
          bitPos = 0;
        }
      }

      output[outputOffset + i] = minVal + val;
    }
  }
}
