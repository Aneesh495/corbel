import 'dart:math' as math;
import 'dart:typed_data';
import '../utils/bit_vector.dart';
import 'byte_buffer.dart';
import 'vbyte.dart';

int _computeLowBitsLength(int count, int universe) {
  if (count <= 0 || universe < count) return 0;
  final val = (math.log(universe / count) / math.ln2).floor();
  return val > 0 ? val : 0;
}

/// Elias-Fano quasi-succinct representation of non-decreasing integer sequences.
/// Provides optimal theoretical compression for sorted doc IDs with O(1) random access.
class EliasFanoEncoder {
  final int count;
  final int universe;
  final int lowBitsLength;
  final BitVector _highBits;
  final Uint8List _lowBits;
  int _currentIndex = 0;
  int _lastValue = 0;

  /// Creates an encoder for [count] non-decreasing integers with maximum value [universe].
  EliasFanoEncoder(this.count, this.universe)
      : lowBitsLength = _computeLowBitsLength(count, universe),
        _highBits = BitVector(
            count + (universe >> _computeLowBitsLength(count, universe)) + 64),
        _lowBits = Uint8List(
            (((count * _computeLowBitsLength(count, universe)) + 7) ~/ 8));

  /// Number of encoded elements.
  int get length => _currentIndex;

  /// Encodes next sorted value.
  void add(int value) {
    if (_currentIndex >= count) {
      throw StateError('Cannot add more than $count elements to Elias-Fano sequence');
    }
    if (value < _lastValue) {
      throw ArgumentError('Sequence must be non-decreasing: got $value after $_lastValue');
    }
    _lastValue = value;

    if (lowBitsLength > 0) {
      final lowMask = (1 << lowBitsLength) - 1;
      final lowPart = value & lowMask;
      _writeLowBits(_currentIndex, lowPart);
    }

    final highPart = value >> lowBitsLength;
    // Unary encoding: highPart zeros followed by a 1 bit.
    // The position of the i-th 1 bit is (highPart + i).
    final highBitPos = highPart + _currentIndex;
    _highBits.set(highBitPos);

    _currentIndex++;
  }

  void _writeLowBits(int index, int val) {
    var bitPos = index * lowBitsLength;
    var bitsLeft = lowBitsLength;

    while (bitsLeft > 0) {
      final byteIdx = bitPos >> 3;
      final bitInByte = bitPos & 7;
      final bitsAvailable = 8 - bitInByte;
      final take = bitsLeft < bitsAvailable ? bitsLeft : bitsAvailable;
      final shift = bitsLeft - take;
      final chunk = (val >> shift) & ((1 << take) - 1);

      _lowBits[byteIdx] |= (chunk << (bitsAvailable - take));
      bitPos += take;
      bitsLeft -= take;
    }
  }

  /// Serializes encoded Elias-Fano structure into writer.
  void serialize(ByteBufferWriter writer) {
    VByteCodec.writeVInt(writer, count);
    VByteCodec.writeVLong(writer, universe);
    VByteCodec.writeVInt(writer, lowBitsLength);

    // Write low bits
    VByteCodec.writeVInt(writer, _lowBits.length);
    writer.writeBytes(_lowBits);

    // Write high bits
    final highWords = _highBits.wordsCount;
    VByteCodec.writeVInt(writer, highWords);
    final rawBits = _highBits.cardinality();
    VByteCodec.writeVInt(writer, rawBits);
    // Write bit offsets
    var current = 0;
    for (var i = 0; i < count; i++) {
      final pos = _highBits.nextSetBit(current);
      VByteCodec.writeVInt(writer, pos - current);
      current = pos + 1;
    }
  }
}

/// Reader and decoder for Elias-Fano compressed sequences.
class EliasFanoDecoder {
  final int count;
  final int universe;
  final int lowBitsLength;
  final Uint8List _lowBits;
  final List<int> _highBitPositions;

  EliasFanoDecoder._({
    required this.count,
    required this.universe,
    required this.lowBitsLength,
    required Uint8List lowBits,
    required List<int> highBitPositions,
  })  : _lowBits = lowBits,
        _highBitPositions = highBitPositions;

  /// Reconstructs decoder from serialized stream.
  factory EliasFanoDecoder.deserialize(ByteBufferReader reader) {
    final count = VByteCodec.readVInt(reader);
    final universe = VByteCodec.readVLong(reader);
    final lowBitsLen = VByteCodec.readVInt(reader);

    final lowBitsByteCount = VByteCodec.readVInt(reader);
    final lowBits = reader.readBytes(lowBitsByteCount);

    VByteCodec.readVInt(reader); // highWords
    VByteCodec.readVInt(reader); // rawBits

    final positions = List<int>.filled(count, 0);
    var acc = 0;
    for (var i = 0; i < count; i++) {
      final gap = VByteCodec.readVInt(reader);
      acc += gap;
      positions[i] = acc;
      acc++; // next search starts after current 1-bit
    }

    return EliasFanoDecoder._(
      count: count,
      universe: universe,
      lowBitsLength: lowBitsLen,
      lowBits: lowBits,
      highBitPositions: positions,
    );
  }

  /// O(1) random access to the i-th element in sequence.
  int get(int index) {
    if (index < 0 || index >= count) {
      throw RangeError.index(index, this, 'index', 'Index out of bounds', count);
    }

    final highBitPos = _highBitPositions[index];
    final highPart = highBitPos - index;

    var lowPart = 0;
    if (lowBitsLength > 0) {
      lowPart = _readLowBits(index);
    }

    return (highPart << lowBitsLength) | lowPart;
  }

  int _readLowBits(int index) {
    var bitPos = index * lowBitsLength;
    var bitsNeeded = lowBitsLength;
    var val = 0;

    while (bitsNeeded > 0) {
      final byteIdx = bitPos >> 3;
      final bitInByte = bitPos & 7;
      final bitsAvailable = 8 - bitInByte;
      final take = bitsNeeded < bitsAvailable ? bitsNeeded : bitsAvailable;
      final shift = bitsAvailable - take;
      final chunk = (_lowBits[byteIdx] >> shift) & ((1 << take) - 1);

      val = (val << take) | chunk;
      bitPos += take;
      bitsNeeded -= take;
    }

    return val;
  }

  /// Decodes full sequence into plain list.
  List<int> toList() {
    final list = List<int>.filled(count, 0);
    for (var i = 0; i < count; i++) {
      list[i] = get(i);
    }
    return list;
  }
}
