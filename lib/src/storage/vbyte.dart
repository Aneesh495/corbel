import 'dart:typed_data';
import 'byte_buffer.dart';

/// Variable-byte, LEB128, and ZigZag integer codecs.
/// Essential for delta-encoded postings lists, doc-id gaps, and term frequencies.
class VByteCodec {
  /// Writes unsigned 32-bit integer as variable-byte sequence.
  /// Uses standard 7-bit payload per byte with high-order continuation bit.
  static void writeVInt(ByteBufferWriter writer, int value) {
    var v = value & 0xFFFFFFFF;
    while ((v & ~0x7F) != 0) {
      writer.writeByte((v & 0x7F) | 0x80);
      v >>= 7;
    }
    writer.writeByte(v & 0x7F);
  }

  /// Reads unsigned 32-bit integer encoded with [writeVInt].
  static int readVInt(ByteBufferReader reader) {
    var b = reader.readByte();
    var val = b & 0x7F;
    var shift = 7;
    while ((b & 0x80) != 0) {
      b = reader.readByte();
      val |= (b & 0x7F) << shift;
      shift += 7;
    }
    return val;
  }

  /// Writes unsigned 64-bit integer as variable-byte sequence.
  static void writeVLong(ByteBufferWriter writer, int value) {
    var v = value;
    while ((v & ~0x7F) != 0) {
      writer.writeByte((v & 0x7F) | 0x80);
      v >>= 7;
    }
    writer.writeByte(v & 0x7F);
  }

  /// Reads unsigned 64-bit integer encoded with [writeVLong].
  static int readVLong(ByteBufferReader reader) {
    var b = reader.readByte();
    var val = b & 0x7F;
    var shift = 7;
    while ((b & 0x80) != 0) {
      b = reader.readByte();
      val |= (b & 0x7F) << shift;
      shift += 7;
    }
    return val;
  }

  /// ZigZag encodes signed 32-bit integer to unsigned representation.
  static int encodeZigZag32(int n) {
    return ((n << 1) ^ (n >> 31)) & 0xFFFFFFFF;
  }

  /// Decodes ZigZag encoded 32-bit integer.
  static int decodeZigZag32(int n) {
    return (n >> 1) ^ -(n & 1);
  }

  /// ZigZag encodes signed 64-bit integer to unsigned representation.
  static int encodeZigZag64(int n) {
    return (n << 1) ^ (n >> 63);
  }

  /// Decodes ZigZag encoded 64-bit integer.
  static int decodeZigZag64(int n) {
    return (n >> 1) ^ -(n & 1);
  }

  /// Writes signed 32-bit integer using ZigZag + VByte encoding.
  static void writeZInt(ByteBufferWriter writer, int value) {
    writeVInt(writer, encodeZigZag32(value));
  }

  /// Reads signed 32-bit integer encoded with [writeZInt].
  static int readZInt(ByteBufferReader reader) {
    return decodeZigZag32(readVInt(reader));
  }

  /// Writes signed 64-bit integer using ZigZag + VByte encoding.
  static void writeZLong(ByteBufferWriter writer, int value) {
    writeVLong(writer, encodeZigZag64(value));
  }

  /// Reads signed 64-bit integer encoded with [writeZLong].
  static int readZLong(ByteBufferReader reader) {
    return decodeZigZag64(readVLong(reader));
  }

  /// Encodes list of integers in-place into raw byte array using delta-VByte.
  /// Sorted doc IDs are converted to consecutive gaps (docId - prevDocId).
  static Uint8List encodeDeltaGaps(List<int> sortedIds) {
    final writer = ByteBufferWriter(sortedIds.length * 2);
    var prev = 0;
    for (var i = 0; i < sortedIds.length; i++) {
      final id = sortedIds[i];
      final gap = id - prev;
      writeVInt(writer, gap);
      prev = id;
    }
    return writer.toBytes();
  }

  /// Decodes delta-encoded VByte sequence into absolute IDs.
  static List<int> decodeDeltaGaps(Uint8List bytes, int count) {
    final reader = ByteBufferReader(bytes);
    final result = List<int>.filled(count, 0);
    var acc = 0;
    for (var i = 0; i < count; i++) {
      final gap = readVInt(reader);
      acc += gap;
      result[i] = acc;
    }
    return result;
  }
}
