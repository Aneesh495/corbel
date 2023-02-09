import 'dart:typed_data';
import 'byte_buffer.dart';
import 'vbyte.dart';

/// Base abstraction for RoaringBitmap 16-bit chunk containers.
abstract class Container {
  /// Number of 16-bit integers stored in this container.
  int get cardinality;

  /// Checks if value (0 to 65535) is present.
  bool contains(int value);

  /// Adds value (0 to 65535). Returns new container if promotion occurred, or this.
  Container add(int value);

  /// Removes value (0 to 65535). Returns new container if demotion occurred, or this.
  Container remove(int value);

  /// Clones container.
  Container clone();

  /// Performs bitwise AND with [other].
  Container and(Container other);

  /// Performs bitwise OR with [other].
  Container or(Container other);

  /// Performs bitwise XOR with [other].
  Container xor(Container other);

  /// Performs bitwise AND-NOT (this AND NOT other).
  Container andNot(Container other);

  /// Converts contents to an ordered list of 16-bit unsigned ints.
  List<int> toList();

  /// Serializes container to binary writer.
  void serialize(ByteBufferWriter writer);
}

/// Sparse container storing at most 4096 sorted 16-bit unsigned integers.
class ArrayContainer extends Container {
  Uint16List _content;
  int _cardinality;

  /// Maximum cardinality before an ArrayContainer must be promoted to a BitmapContainer.
  static const int maxCapacity = 4096;

  /// Creates empty or pre-sized array container.
  ArrayContainer([int initialCapacity = 8])
      : _cardinality = 0,
        _content = Uint16List(initialCapacity > 0 ? initialCapacity : 8);

  ArrayContainer._from(this._content, this._cardinality);

  @override
  int get cardinality => _cardinality;

  @override
  bool contains(int value) {
    return _binarySearch(value) >= 0;
  }

  @override
  Container add(int value) {
    final idx = _binarySearch(value);
    if (idx >= 0) return this; // Already present

    final insertIdx = -idx - 1;
    if (_cardinality >= maxCapacity) {
      // Promote to BitmapContainer
      final bitmap = BitmapContainer();
      for (var i = 0; i < _cardinality; i++) {
        bitmap.add(_content[i]);
      }
      bitmap.add(value);
      return bitmap;
    }

    _ensureCapacity(_cardinality + 1);
    for (var i = _cardinality; i > insertIdx; i--) {
      _content[i] = _content[i - 1];
    }
    _content[insertIdx] = value & 0xFFFF;
    _cardinality++;
    return this;
  }

  @override
  Container remove(int value) {
    final idx = _binarySearch(value);
    if (idx < 0) return this;

    for (var i = idx; i < _cardinality - 1; i++) {
      _content[i] = _content[i + 1];
    }
    _cardinality--;
    return this;
  }

  @override
  Container clone() {
    final copy = Uint16List(_cardinality);
    copy.setRange(0, _cardinality, _content);
    return ArrayContainer._from(copy, _cardinality);
  }

  @override
  Container and(Container other) {
    if (other is ArrayContainer) {
      final result = ArrayContainer(_cardinality < other._cardinality
          ? _cardinality
          : other._cardinality);
      var i = 0;
      var j = 0;
      while (i < _cardinality && j < other._cardinality) {
        final valA = _content[i];
        final valB = other._content[j];
        if (valA == valB) {
          result.add(valA);
          i++;
          j++;
        } else if (valA < valB) {
          i++;
        } else {
          j++;
        }
      }
      return result;
    } else if (other is BitmapContainer) {
      return other.and(this);
    } else if (other is RunContainer) {
      return other.and(this);
    }
    return ArrayContainer();
  }

  @override
  Container or(Container other) {
    if (other is ArrayContainer) {
      final total = _cardinality + other._cardinality;
      if (total > maxCapacity) {
        final bitmap = BitmapContainer();
        for (var i = 0; i < _cardinality; i++) {
          bitmap.add(_content[i]);
        }
        for (var j = 0; j < other._cardinality; j++) {
          bitmap.add(other._content[j]);
        }
        return bitmap;
      }

      final result = ArrayContainer(total);
      var i = 0;
      var j = 0;
      while (i < _cardinality && j < other._cardinality) {
        final valA = _content[i];
        final valB = other._content[j];
        if (valA == valB) {
          result.add(valA);
          i++;
          j++;
        } else if (valA < valB) {
          result.add(valA);
          i++;
        } else {
          result.add(valB);
          j++;
        }
      }
      while (i < _cardinality) {
        result.add(_content[i++]);
      }
      while (j < other._cardinality) {
        result.add(other._content[j++]);
      }
      return result;
    } else if (other is BitmapContainer) {
      return other.or(this);
    } else if (other is RunContainer) {
      return other.or(this);
    }
    return clone();
  }

  @override
  Container xor(Container other) {
    final bitmap = BitmapContainer();
    for (var i = 0; i < _cardinality; i++) {
      bitmap.add(_content[i]);
    }
    return bitmap.xor(other);
  }

  @override
  Container andNot(Container other) {
    final result = ArrayContainer(_cardinality);
    for (var i = 0; i < _cardinality; i++) {
      final val = _content[i];
      if (!other.contains(val)) {
        result.add(val);
      }
    }
    return result;
  }

  @override
  List<int> toList() {
    return _content.sublist(0, _cardinality);
  }

  @override
  void serialize(ByteBufferWriter writer) {
    writer.writeByte(1); // Type 1: ArrayContainer
    VByteCodec.writeVInt(writer, _cardinality);
    for (var i = 0; i < _cardinality; i++) {
      writer.writeInt16(_content[i]);
    }
  }

  static ArrayContainer deserialize(ByteBufferReader reader) {
    final card = VByteCodec.readVInt(reader);
    final arr = Uint16List(card);
    for (var i = 0; i < card; i++) {
      arr[i] = reader.readInt16() & 0xFFFF;
    }
    return ArrayContainer._from(arr, card);
  }

  int _binarySearch(int key) {
    var low = 0;
    var high = _cardinality - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final midVal = _content[mid];
      if (midVal < key) {
        low = mid + 1;
      } else if (midVal > key) {
        high = mid - 1;
      } else {
        return mid;
      }
    }
    return -(low + 1);
  }

  void _ensureCapacity(int required) {
    if (required > _content.length) {
      var newCap = _content.length * 2;
      if (newCap < required) newCap = required;
      final newContent = Uint16List(newCap);
      newContent.setRange(0, _cardinality, _content);
      _content = newContent;
    }
  }
}

/// Dense container storing values as a 1024 x 64-bit word bitmap (65536 bits).
class BitmapContainer extends Container {
  final Uint64List _words;
  int _cardinality;

  /// Creates an empty bitmap container of 1024 64-bit words (8192 bytes).
  BitmapContainer()
      : _words = Uint64List(1024),
        _cardinality = 0;

  BitmapContainer._from(this._words, this._cardinality);

  @override
  int get cardinality => _cardinality;

  @override
  bool contains(int value) {
    final wordIdx = value >> 6;
    final bitIdx = value & 63;
    return (_words[wordIdx] & (1 << bitIdx)) != 0;
  }

  @override
  Container add(int value) {
    final wordIdx = value >> 6;
    final bitIdx = value & 63;
    final mask = 1 << bitIdx;
    if ((_words[wordIdx] & mask) == 0) {
      _words[wordIdx] |= mask;
      _cardinality++;
    }
    return this;
  }

  @override
  Container remove(int value) {
    final wordIdx = value >> 6;
    final bitIdx = value & 63;
    final mask = 1 << bitIdx;
    if ((_words[wordIdx] & mask) != 0) {
      _words[wordIdx] &= ~mask;
      _cardinality--;

      // Demote to ArrayContainer if cardinality drops to or below threshold
      if (_cardinality <= ArrayContainer.maxCapacity) {
        final arr = ArrayContainer(_cardinality);
        for (var w = 0; w < 1024; w++) {
          var word = _words[w];
          while (word != 0) {
            final bit = _lowestBitIndex(word);
            arr.add((w << 6) + bit);
            word &= word - 1;
          }
        }
        return arr;
      }
    }
    return this;
  }

  @override
  Container clone() {
    final copyWords = Uint64List(1024);
    copyWords.setRange(0, 1024, _words);
    return BitmapContainer._from(copyWords, _cardinality);
  }

  @override
  Container and(Container other) {
    if (other is BitmapContainer) {
      final resultWords = Uint64List(1024);
      var card = 0;
      for (var i = 0; i < 1024; i++) {
        final w = _words[i] & other._words[i];
        resultWords[i] = w;
        card += _popcount64(w);
      }
      if (card <= ArrayContainer.maxCapacity) {
        final arr = ArrayContainer(card);
        for (var w = 0; w < 1024; w++) {
          var word = resultWords[w];
          while (word != 0) {
            final bit = _lowestBitIndex(word);
            arr.add((w << 6) + bit);
            word &= word - 1;
          }
        }
        return arr;
      }
      return BitmapContainer._from(resultWords, card);
    } else if (other is ArrayContainer) {
      final arr = ArrayContainer(other.cardinality);
      for (final val in other.toList()) {
        if (contains(val)) arr.add(val);
      }
      return arr;
    } else if (other is RunContainer) {
      return other.and(this);
    }
    return BitmapContainer();
  }

  @override
  Container or(Container other) {
    if (other is BitmapContainer) {
      final resultWords = Uint64List(1024);
      var card = 0;
      for (var i = 0; i < 1024; i++) {
        final w = _words[i] | other._words[i];
        resultWords[i] = w;
        card += _popcount64(w);
      }
      return BitmapContainer._from(resultWords, card);
    } else if (other is ArrayContainer) {
      final result = clone() as BitmapContainer;
      for (final val in other.toList()) {
        result.add(val);
      }
      return result;
    } else if (other is RunContainer) {
      return other.or(this);
    }
    return clone();
  }

  @override
  Container xor(Container other) {
    if (other is BitmapContainer) {
      final resultWords = Uint64List(1024);
      var card = 0;
      for (var i = 0; i < 1024; i++) {
        final w = _words[i] ^ other._words[i];
        resultWords[i] = w;
        card += _popcount64(w);
      }
      if (card <= ArrayContainer.maxCapacity) {
        final arr = ArrayContainer(card);
        for (var w = 0; w < 1024; w++) {
          var word = resultWords[w];
          while (word != 0) {
            final bit = _lowestBitIndex(word);
            arr.add((w << 6) + bit);
            word &= word - 1;
          }
        }
        return arr;
      }
      return BitmapContainer._from(resultWords, card);
    } else if (other is ArrayContainer) {
      final result = clone();
      for (final val in other.toList()) {
        if (result.contains(val)) {
          result.remove(val);
        } else {
          result.add(val);
        }
      }
      return result;
    }
    return clone();
  }

  @override
  Container andNot(Container other) {
    final result = clone();
    for (final val in other.toList()) {
      result.remove(val);
    }
    return result;
  }

  @override
  List<int> toList() {
    final list = <int>[];
    for (var w = 0; w < 1024; w++) {
      var word = _words[w];
      while (word != 0) {
        final bit = _lowestBitIndex(word);
        list.add((w << 6) + bit);
        word &= word - 1;
      }
    }
    return list;
  }

  @override
  void serialize(ByteBufferWriter writer) {
    writer.writeByte(2); // Type 2: BitmapContainer
    VByteCodec.writeVInt(writer, _cardinality);
    for (var i = 0; i < 1024; i++) {
      writer.writeInt64(_words[i]);
    }
  }

  static BitmapContainer deserialize(ByteBufferReader reader) {
    final card = VByteCodec.readVInt(reader);
    final words = Uint64List(1024);
    for (var i = 0; i < 1024; i++) {
      words[i] = reader.readInt64();
    }
    return BitmapContainer._from(words, card);
  }

  static int _lowestBitIndex(int word) {
    final lowest = word & -word;
    if (lowest == -9223372036854775808) return 63;
    return lowest.bitLength - 1;
  }

  static int _popcount64(int x) {
    var n = x;
    n = n - ((n >> 1) & 0x5555555555555555);
    n = (n & 0x3333333333333333) + ((n >> 2) & 0x3333333333333333);
    n = (n + (n >> 4)) & 0x0F0F0F0F0F0F0F0F;
    return (n * 0x0101010101010101) >> 56;
  }
}
