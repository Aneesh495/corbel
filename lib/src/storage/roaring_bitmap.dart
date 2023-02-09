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

/// Run-length encoded container for dense contiguous integer runs.
class RunContainer extends Container {
  final List<int> _starts = [];
  final List<int> _lengths = []; // length - 1 (0 means 1 element)

  RunContainer();

  RunContainer._from(List<int> starts, List<int> lengths) {
    _starts.addAll(starts);
    _lengths.addAll(lengths);
  }

  @override
  int get cardinality {
    var total = 0;
    for (var i = 0; i < _starts.length; i++) {
      total += _lengths[i] + 1;
    }
    return total;
  }

  @override
  bool contains(int value) {
    var low = 0;
    var high = _starts.length - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final start = _starts[mid];
      final end = start + _lengths[mid];
      if (value < start) {
        high = mid - 1;
      } else if (value > end) {
        low = mid + 1;
      } else {
        return true;
      }
    }
    return false;
  }

  @override
  Container add(int value) {
    if (contains(value)) return this;
    // Fall back to converting to Bitmap or inserting run
    final list = toList();
    list.add(value);
    list.sort();
    return RunContainer.fromList(list);
  }

  @override
  Container remove(int value) {
    if (!contains(value)) return this;
    final list = toList()..remove(value);
    return RunContainer.fromList(list);
  }

  @override
  Container clone() => RunContainer._from(_starts, _lengths);

  @override
  Container and(Container other) {
    final result = <int>[];
    for (final val in toList()) {
      if (other.contains(val)) result.add(val);
    }
    return RunContainer.fromList(result);
  }

  @override
  Container or(Container other) {
    final set = toList().toSet()..addAll(other.toList());
    final sorted = set.toList()..sort();
    return RunContainer.fromList(sorted);
  }

  @override
  Container xor(Container other) {
    final setA = toList().toSet();
    final setB = other.toList().toSet();
    final xorSet = setA.difference(setB).union(setB.difference(setA));
    final sorted = xorSet.toList()..sort();
    return RunContainer.fromList(sorted);
  }

  @override
  Container andNot(Container other) {
    final list = <int>[];
    for (final val in toList()) {
      if (!other.contains(val)) list.add(val);
    }
    return RunContainer.fromList(list);
  }

  @override
  List<int> toList() {
    final result = <int>[];
    for (var i = 0; i < _starts.length; i++) {
      final start = _starts[i];
      final count = _lengths[i] + 1;
      for (var j = 0; j < count; j++) {
        result.add(start + j);
      }
    }
    return result;
  }

  @override
  void serialize(ByteBufferWriter writer) {
    writer.writeByte(3); // Type 3: RunContainer
    VByteCodec.writeVInt(writer, _starts.length);
    for (var i = 0; i < _starts.length; i++) {
      writer.writeInt16(_starts[i]);
      writer.writeInt16(_lengths[i]);
    }
  }

  static RunContainer deserialize(ByteBufferReader reader) {
    final numRuns = VByteCodec.readVInt(reader);
    final starts = <int>[];
    final lengths = <int>[];
    for (var i = 0; i < numRuns; i++) {
      starts.add(reader.readInt16() & 0xFFFF);
      lengths.add(reader.readInt16() & 0xFFFF);
    }
    return RunContainer._from(starts, lengths);
  }

  /// Constructs RunContainer from sorted list of 16-bit integers.
  factory RunContainer.fromList(List<int> sorted) {
    final rc = RunContainer();
    if (sorted.isEmpty) return rc;

    var start = sorted[0];
    var len = 0;

    for (var i = 1; i < sorted.length; i++) {
      final val = sorted[i];
      if (val == start + len + 1) {
        len++;
      } else {
        rc._starts.add(start);
        rc._lengths.add(len);
        start = val;
        len = 0;
      }
    }
    rc._starts.add(start);
    rc._lengths.add(len);
    return rc;
  }
}

/// RoaringBitmap: High-performance compressed bitmap index for 32-bit unsigned integers.
class RoaringBitmap {
  final Map<int, Container> _containers = {};

  /// Creates an empty RoaringBitmap.
  RoaringBitmap();

  /// Total number of unique 32-bit integers stored.
  int get cardinality {
    var count = 0;
    for (final c in _containers.values) {
      count += c.cardinality;
    }
    return count;
  }

  /// Checks if bitmap contains zero elements.
  bool get isEmpty => _containers.isEmpty;

  /// Checks if bitmap contains at least one element.
  bool get isNotEmpty => _containers.isNotEmpty;

  /// Adds a 32-bit integer (0 to 4294967295) to the bitmap.
  void add(int value) {
    final chunkKey = (value >> 16) & 0xFFFF;
    final low16 = value & 0xFFFF;

    final existing = _containers[chunkKey];
    if (existing == null) {
      final arr = ArrayContainer()..add(low16);
      _containers[chunkKey] = arr;
    } else {
      _containers[chunkKey] = existing.add(low16);
    }
  }

  /// Adds an entire list of 32-bit integers.
  void addAll(Iterable<int> values) {
    for (final v in values) {
      add(v);
    }
  }

  /// Removes a 32-bit integer from the bitmap.
  void remove(int value) {
    final chunkKey = (value >> 16) & 0xFFFF;
    final low16 = value & 0xFFFF;

    final existing = _containers[chunkKey];
    if (existing != null) {
      final updated = existing.remove(low16);
      if (updated.cardinality == 0) {
        _containers.remove(chunkKey);
      } else {
        _containers[chunkKey] = updated;
      }
    }
  }

  /// Checks if 32-bit integer is present in the bitmap.
  bool contains(int value) {
    final chunkKey = (value >> 16) & 0xFFFF;
    final low16 = value & 0xFFFF;
    final container = _containers[chunkKey];
    if (container == null) return false;
    return container.contains(low16);
  }

  /// Clears all elements.
  void clear() {
    _containers.clear();
  }

  /// Creates a deep copy of this bitmap.
  RoaringBitmap clone() {
    final copy = RoaringBitmap();
    for (final entry in _containers.entries) {
      copy._containers[entry.key] = entry.value.clone();
    }
    return copy;
  }

  /// Computes intersection (AND) with [other], returning a new RoaringBitmap.
  RoaringBitmap and(RoaringBitmap other) {
    final result = RoaringBitmap();
    for (final entry in _containers.entries) {
      final otherContainer = other._containers[entry.key];
      if (otherContainer != null) {
        final intersection = entry.value.and(otherContainer);
        if (intersection.cardinality > 0) {
          result._containers[entry.key] = intersection;
        }
      }
    }
    return result;
  }

  /// Computes union (OR) with [other], returning a new RoaringBitmap.
  RoaringBitmap or(RoaringBitmap other) {
    final result = clone();
    for (final entry in other._containers.entries) {
      final existing = result._containers[entry.key];
      if (existing == null) {
        result._containers[entry.key] = entry.value.clone();
      } else {
        result._containers[entry.key] = existing.or(entry.value);
      }
    }
    return result;
  }

  /// Computes symmetric difference (XOR) with [other], returning a new RoaringBitmap.
  RoaringBitmap xor(RoaringBitmap other) {
    final result = RoaringBitmap();
    final allKeys = {..._containers.keys, ...other._containers.keys};
    for (final key in allKeys) {
      final a = _containers[key];
      final b = other._containers[key];
      if (a != null && b != null) {
        final diff = a.xor(b);
        if (diff.cardinality > 0) {
          result._containers[key] = diff;
        }
      } else if (a != null) {
        result._containers[key] = a.clone();
      } else if (b != null) {
        result._containers[key] = b.clone();
      }
    }
    return result;
  }

  /// Computes set difference (this AND NOT other), returning a new RoaringBitmap.
  RoaringBitmap andNot(RoaringBitmap other) {
    final result = RoaringBitmap();
    for (final entry in _containers.entries) {
      final otherContainer = other._containers[entry.key];
      if (otherContainer == null) {
        result._containers[entry.key] = entry.value.clone();
      } else {
        final diff = entry.value.andNot(otherContainer);
        if (diff.cardinality > 0) {
          result._containers[entry.key] = diff;
        }
      }
    }
    return result;
  }

  /// Decodes all elements in the bitmap into an ordered list of 32-bit integers.
  List<int> toList() {
    final list = <int>[];
    final keys = _containers.keys.toList()..sort();
    for (final key in keys) {
      final high32 = key << 16;
      final lowList = _containers[key]!.toList();
      for (var i = 0; i < lowList.length; i++) {
        list.add(high32 | lowList[i]);
      }
    }
    return list;
  }

  /// Serializes RoaringBitmap into binary writer.
  void serialize(ByteBufferWriter writer) {
    final keys = _containers.keys.toList()..sort();
    VByteCodec.writeVInt(writer, keys.length);
    for (final key in keys) {
      writer.writeInt16(key);
      _containers[key]!.serialize(writer);
    }
  }

  /// Deserializes RoaringBitmap from binary reader.
  factory RoaringBitmap.deserialize(ByteBufferReader reader) {
    final result = RoaringBitmap();
    final numContainers = VByteCodec.readVInt(reader);
    for (var i = 0; i < numContainers; i++) {
      final key = reader.readInt16() & 0xFFFF;
      final type = reader.readByte();
      final Container container;
      if (type == 1) {
        container = ArrayContainer.deserialize(reader);
      } else if (type == 2) {
        container = BitmapContainer.deserialize(reader);
      } else if (type == 3) {
        container = RunContainer.deserialize(reader);
      } else {
        throw FormatException('Unknown RoaringBitmap container type: $type');
      }
      result._containers[key] = container;
    }
    return result;
  }
}
