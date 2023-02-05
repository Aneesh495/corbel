import 'dart:math' as math;
import 'dart:typed_data';
import 'package:corbel/src/storage/byte_buffer.dart';
import 'package:corbel/src/storage/elias_fano.dart';
import 'package:corbel/src/storage/for_compression.dart';
import 'package:corbel/src/storage/vbyte.dart';
import 'package:corbel/src/utils/bytes_ref.dart';
import 'package:test/test.dart';

void main() {
  group('ByteBufferWriter and ByteBufferReader Tests', () {
    test('primitive serialization and deserialization round-trip', () {
      final writer = ByteBufferWriter(64);
      writer.writeByte(254);
      writer.writeInt16(-12345);
      writer.writeInt32(987654321);
      writer.writeUint32(3500000000);
      writer.writeInt64(-9000000000000000000);
      writer.writeFloat32(3.14159);
      writer.writeFloat64(2.718281828459);
      writer.writeString('Corbel Inverted Index');
      writer.writeBytesRef(BytesRef.fromString('PayloadSlice'));

      final bytes = writer.toBytes();
      final reader = ByteBufferReader(bytes);

      expect(reader.readByte(), equals(254));
      expect(reader.readInt16(), equals(-12345));
      expect(reader.readInt32(), equals(987654321));
      expect(reader.readUint32(), equals(3500000000));
      expect(reader.readInt64(), equals(-9000000000000000000));
      expect(reader.readFloat32(), closeTo(3.14159, 0.0001));
      expect(reader.readFloat64(), closeTo(2.718281828459, 0.0000000001));
      expect(reader.readString(), equals('Corbel Inverted Index'));
      expect(reader.readBytesRef(12).utf8String(), equals('PayloadSlice'));
      expect(reader.hasRemaining, isFalse);
    });

    test('reader underflow throws RangeError', () {
      final reader = ByteBufferReader(Uint8List.fromList([1, 2]));
      reader.readInt16();
      expect(() => reader.readByte(), throwsRangeError);
    });
  });

  group('VByte and ZigZag Codec Tests', () {
    test('VInt and VLong round-trip across integer ranges', () {
      final testValues = [
        0, 1, 127, 128, 255, 256, 16383, 16384, 2097151, 2097152,
        0x7FFFFFFF,
      ];

      final writer = ByteBufferWriter();
      for (final val in testValues) {
        VByteCodec.writeVInt(writer, val);
      }

      final reader = ByteBufferReader(writer.toBytes());
      for (final val in testValues) {
        expect(VByteCodec.readVInt(reader), equals(val));
      }
    });

    test('ZigZag signed integer encoding', () {
      final signedValues = [0, -1, 1, -2, 2, -1000, 1000, -2147483648, 2147483647];
      final writer = ByteBufferWriter();
      for (final val in signedValues) {
        VByteCodec.writeZInt(writer, val);
      }

      final reader = ByteBufferReader(writer.toBytes());
      for (final val in signedValues) {
        expect(VByteCodec.readZInt(reader), equals(val));
      }
    });

    test('delta gaps encoding and decoding', () {
      final sortedIds = [5, 12, 19, 45, 100, 105, 300, 10000];
      final bytes = VByteCodec.encodeDeltaGaps(sortedIds);
      final decoded = VByteCodec.decodeDeltaGaps(bytes, sortedIds.length);
      expect(decoded, equals(sortedIds));
    });
  });

  group('Frame of Reference (FoR) Compression Tests', () {
    test('constant block compression with zero bits', () {
      final block = List<int>.filled(128, 42);
      final writer = ByteBufferWriter();
      FrameOfReference.encodeBlock(writer, block);

      final reader = ByteBufferReader(writer.toBytes());
      final decoded = Int32List(128);
      FrameOfReference.decodeBlock(reader, decoded);

      expect(decoded, equals(block));
    });

    test('dense sequence and variable bit-width block compression', () {
      final block = List<int>.generate(128, (i) => 1000 + i * 3);
      final writer = ByteBufferWriter();
      FrameOfReference.encodeBlock(writer, block);

      final reader = ByteBufferReader(writer.toBytes());
      final decoded = Int32List(128);
      FrameOfReference.decodeBlock(reader, decoded);

      expect(decoded, equals(block));
    });

    test('random integer block compression', () {
      final rng = math.Random(42);
      final block = List<int>.generate(128, (i) => 50000 + rng.nextInt(500));
      final writer = ByteBufferWriter();
      FrameOfReference.encodeBlock(writer, block);

      final reader = ByteBufferReader(writer.toBytes());
      final decoded = Int32List(128);
      FrameOfReference.decodeBlock(reader, decoded);

      expect(decoded, equals(block));
    });
  });

  group('Elias-Fano Quasi-Succinct Monotone Sequence Tests', () {
    test('encode and decode monotonic sequence with O(1) random access', () {
      final values = [3, 8, 14, 25, 42, 60, 110, 250, 400, 999];
      final encoder = EliasFanoEncoder(values.length, values.last);
      for (final v in values) {
        encoder.add(v);
      }

      final writer = ByteBufferWriter();
      encoder.serialize(writer);

      final reader = ByteBufferReader(writer.toBytes());
      final decoder = EliasFanoDecoder.deserialize(reader);

      expect(decoder.count, equals(values.length));
      for (var i = 0; i < values.length; i++) {
        expect(decoder.get(i), equals(values[i]), reason: 'Mismatch at index $i');
      }
      expect(decoder.toList(), equals(values));
    });

    test('encode large dense sequence', () {
      final count = 200;
      final values = List<int>.generate(count, (i) => i * 7 + 10);
      final encoder = EliasFanoEncoder(count, values.last);
      for (final v in values) {
        encoder.add(v);
      }

      final writer = ByteBufferWriter();
      encoder.serialize(writer);

      final reader = ByteBufferReader(writer.toBytes());
      final decoder = EliasFanoDecoder.deserialize(reader);

      expect(decoder.toList(), equals(values));
    });
  });
}
