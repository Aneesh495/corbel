import 'dart:convert';
import 'dart:typed_data';

/// Immutable or non-copying slice over a byte buffer.
/// Crucial for term dictionaries, postings lookups, and zero-copy string references.
class BytesRef implements Comparable<BytesRef> {
  /// Underlying byte array.
  final Uint8List bytes;

  /// Starting offset into [bytes].
  final int offset;

  /// Number of bytes in this slice.
  final int length;

  /// Creates a slice over an existing byte array without copying.
  const BytesRef(this.bytes, [this.offset = 0, int? length])
      : length = length ?? (bytes.length - offset);

  /// Empty byte reference constant.
  static final BytesRef empty = BytesRef(Uint8List(0), 0, 0);

  /// Factory constructing a BytesRef by UTF-8 encoding a String.
  factory BytesRef.fromString(String text) {
    final encoded = utf8.encode(text);
    return BytesRef(
        encoded);
  }

  /// Factory constructing a BytesRef from a list of ints.
  factory BytesRef.fromList(List<int> list) {
    return BytesRef(
        list is Uint8List ? list : Uint8List.fromList(list), 0, list.length);
  }

  /// Returns single byte at relative index in this slice.
  int operator [](int index) {
    if (index < 0 || index >= length) {
      throw RangeError.index(index, this, 'index', 'Index out of bounds', length);
    }
    return bytes[offset + index];
  }

  /// Creates a sub-slice without copying underlying memory.
  BytesRef slice(int start, [int? subLength]) {
    final resolvedLength = subLength ?? (length - start);
    if (start < 0 ||
        resolvedLength < 0 ||
        start + resolvedLength > length) {
      throw RangeError('Invalid slice range: start=$start, length=$resolvedLength in slice of length $length');
    }
    return BytesRef(bytes, offset + start, resolvedLength);
  }

  /// Converts this byte slice to a UTF-8 decoded String.
  String utf8String() {
    return utf8.decode(bytes.sublist(offset, offset + length));
  }

  /// Deep copies bytes into a newly allocated BytesRef.
  BytesRef deepCopy() {
    final copy = Uint8List(length);
    copy.setRange(0, length, bytes, offset);
    return BytesRef(copy, 0, length);
  }

  @override
  int compareTo(BytesRef other) {
    final minLen = length < other.length ? length : other.length;
    final aOff = offset;
    final bOff = other.offset;
    for (var i = 0; i < minLen; i++) {
      final a = bytes[aOff + i];
      final b = other.bytes[bOff + i];
      if (a != b) return a - b;
    }
    return length - other.length;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! BytesRef) return false;
    if (length != other.length) return false;
    final aOff = offset;
    final bOff = other.offset;
    for (var i = 0; i < length; i++) {
      if (bytes[aOff + i] != other.bytes[bOff + i]) return false;
    }
    return true;
  }

  @override
  int get hashCode {
    // 32-bit FNV-1a hash algorithm
    var hash = 0x811c9dc5;
    final end = offset + length;
    for (var i = offset; i < end; i++) {
      hash ^= bytes[i];
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }

  @override
  String toString() {
    try {
      return 'BytesRef("${utf8String()}")';
    } catch (_) {
      return 'BytesRef([${bytes.sublist(offset, offset + (length > 16 ? 16 : length)).join(", ")}${length > 16 ? '...' : ''}])';
    }
  }
}

/// Dynamic, growable byte builder returning lightweight BytesRef views.
class BytesRefBuilder {
  Uint8List _buffer;
  int _length = 0;

  /// Creates a builder with initial capacity.
  BytesRefBuilder([int initialCapacity = 32])
      : _buffer = Uint8List(initialCapacity > 0 ? initialCapacity : 32);

  /// Current number of populated bytes.
  int get length => _length;

  /// Clears the builder without freeing underlying buffer memory.
  void clear() {
    _length = 0;
  }

  /// Appends a single byte.
  void append(int byte) {
    _ensureCapacity(_length + 1);
    _buffer[_length++] = byte & 0xFF;
  }

  /// Appends an iterable of raw bytes.
  void appendBytes(List<int> bytes, [int start = 0, int? len]) {
    final count = len ?? (bytes.length - start);
    _ensureCapacity(_length + count);
    for (var i = 0; i < count; i++) {
      _buffer[_length++] = bytes[start + i] & 0xFF;
    }
  }

  /// Appends bytes from a BytesRef.
  void appendBytesRef(BytesRef ref) {
    appendBytes(ref.bytes, ref.offset, ref.length);
  }

  /// Appends UTF-8 encoded text.
  void appendString(String text) {
    final encoded = utf8.encode(text);
    appendBytes(encoded);
  }

  /// Returns a non-copying BytesRef view of current content.
  BytesRef toBytesRef() => BytesRef(_buffer, 0, _length);

  /// Allocates and returns an exact standalone byte array.
  Uint8List toByteArray() {
    final result = Uint8List(_length);
    result.setRange(0, _length, _buffer);
    return result;
  }

  void _ensureCapacity(int required) {
    if (required > _buffer.length) {
      var newCap = _buffer.length * 2;
      if (newCap < required) newCap = required;
      final newBuf = Uint8List(newCap);
      newBuf.setRange(0, _length, _buffer);
      _buffer = newBuf;
    }
  }
}
