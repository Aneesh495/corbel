import 'dart:typed_data';

/// High-performance dynamic bit vector backed by 64-bit integer words.
/// Optimized for dense postings operations, deletions, and bitset algebra.
class BitVector {
  Uint64List _words;
  int _length;

  /// Creates a bit vector with initial capacity in bits.
  BitVector([int initialBits = 64])
      : _length = initialBits > 0 ? initialBits : 0,
        _words = Uint64List((initialBits + 63) >> 6);

  /// Number of addressable bits in this vector.
  int get length => _length;

  /// Number of 64-bit words backing this vector.
  int get wordsCount => _words.length;

  /// Reads bit at given index.
  bool get(int index) {
    if (index < 0 || index >= _length) return false;
    final wordIdx = index >> 6;
    if (wordIdx >= _words.length) return false;
    return (_words[wordIdx] & (1 << (index & 63))) != 0;
  }

  /// Sets bit at given index to 1 (true).
  void set(int index) {
    _ensureCapacity(index + 1);
    final wordIdx = index >> 6;
    _words[wordIdx] |= (1 << (index & 63));
  }

  /// Clears bit at given index to 0 (false).
  void clear(int index) {
    if (index < 0 || index >= _length) return;
    final wordIdx = index >> 6;
    if (wordIdx >= _words.length) return;
    _words[wordIdx] &= ~(1 << (index & 63));
  }

  /// Flips bit at given index.
  void flip(int index) {
    _ensureCapacity(index + 1);
    final wordIdx = index >> 6;
    _words[wordIdx] ^= (1 << (index & 63));
  }

  /// Computes total number of set bits (population count / Hamming weight).
  int cardinality() {
    var count = 0;
    for (var i = 0; i < _words.length; i++) {
      count += _popcount64(_words[i]);
    }
    return count;
  }

  /// Checks if any bit is set.
  bool get isEmpty => cardinality() == 0;

  /// Checks if at least one bit is set.
  bool get isNotEmpty => !isEmpty;

  /// Finds the index of the first bit set to true on or after [fromIndex].
  /// Returns -1 if no such bit exists.
  int nextSetBit(int fromIndex) {
    if (fromIndex < 0) fromIndex = 0;
    if (fromIndex >= _length) return -1;

    var wordIdx = fromIndex >> 6;
    if (wordIdx >= _words.length) return -1;

    var word = _words[wordIdx] & (~0 << (fromIndex & 63));
    while (true) {
      if (word != 0) {
        final bitIdx = (wordIdx << 6) + _numberOfTrailingZeros64(word);
        return bitIdx < _length ? bitIdx : -1;
      }
      wordIdx++;
      if (wordIdx >= _words.length || (wordIdx << 6) >= _length) {
        return -1;
      }
      word = _words[wordIdx];
    }
  }

  /// Finds the index of the first bit set to false on or after [fromIndex].
  /// Returns -1 if fromIndex >= length.
  int nextClearBit(int fromIndex) {
    if (fromIndex < 0) fromIndex = 0;
    if (fromIndex >= _length) return -1;

    var wordIdx = fromIndex >> 6;
    if (wordIdx >= _words.length) return fromIndex;

    var word = (~_words[wordIdx]) & (~0 << (fromIndex & 63));
    while (true) {
      if (word != 0) {
        final bitIdx = (wordIdx << 6) + _numberOfTrailingZeros64(word);
        return bitIdx < _length ? bitIdx : _length;
      }
      wordIdx++;
      if (wordIdx >= _words.length) {
        final bitIdx = wordIdx << 6;
        return bitIdx < _length ? bitIdx : _length;
      }
      word = ~_words[wordIdx];
    }
  }

  /// Performs in-place bitwise AND with [other].
  void and(BitVector other) {
    final commonWords = _words.length < other._words.length
        ? _words.length
        : other._words.length;
    for (var i = 0; i < commonWords; i++) {
      _words[i] &= other._words[i];
    }
    for (var i = commonWords; i < _words.length; i++) {
      _words[i] = 0;
    }
  }

  /// Performs in-place bitwise OR with [other].
  void or(BitVector other) {
    if (other._length > _length) {
      _ensureCapacity(other._length);
    }
    final commonWords = _words.length < other._words.length
        ? _words.length
        : other._words.length;
    for (var i = 0; i < commonWords; i++) {
      _words[i] |= other._words[i];
    }
  }

  /// Performs in-place bitwise XOR with [other].
  void xor(BitVector other) {
    if (other._length > _length) {
      _ensureCapacity(other._length);
    }
    final commonWords = _words.length < other._words.length
        ? _words.length
        : other._words.length;
    for (var i = 0; i < commonWords; i++) {
      _words[i] ^= other._words[i];
    }
  }

  /// Performs in-place bitwise AND-NOT (set difference: this AND NOT other).
  void andNot(BitVector other) {
    final commonWords = _words.length < other._words.length
        ? _words.length
        : other._words.length;
    for (var i = 0; i < commonWords; i++) {
      _words[i] &= ~other._words[i];
    }
  }

  /// Creates a deep copy of this bit vector.
  BitVector clone() {
    final copy = BitVector(_length);
    for (var i = 0; i < _words.length; i++) {
      copy._words[i] = _words[i];
    }
    return copy;
  }

  void _ensureCapacity(int requiredBits) {
    if (requiredBits > _length) {
      _length = requiredBits;
      final requiredWords = (requiredBits + 63) >> 6;
      if (requiredWords > _words.length) {
        var newCap = _words.isEmpty ? 1 : _words.length * 2;
        if (newCap < requiredWords) newCap = requiredWords;
        final newWords = Uint64List(newCap);
        newWords.setRange(0, _words.length, _words);
        _words = newWords;
      }
    }
  }

  /// Fast 64-bit Hamming weight population count.
  static int _popcount64(int x) {
    var n = x;
    n = n - ((n >> 1) & 0x5555555555555555);
    n = (n & 0x3333333333333333) + ((n >> 2) & 0x3333333333333333);
    n = (n + (n >> 4)) & 0x0F0F0F0F0F0F0F0F;
    return (n * 0x0101010101010101) >> 56;
  }

  /// Computes number of zero bits following lowest-order one-bit in 64-bit int.
  static int _numberOfTrailingZeros64(int i) {
    if (i == 0) return 64;
    final lowestBit = i & -i;
    if (lowestBit == -9223372036854775808) {
      return 63;
    }
    return lowestBit.bitLength - 1;
  }
}
