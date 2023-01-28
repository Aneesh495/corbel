import 'dart:convert';
import 'dart:typed_data';
import '../utils/bytes_ref.dart';

/// Direct binary stream serializer supporting endian-aware primitives.
class ByteBufferWriter {
  Uint8List _buffer;
  ByteData _byteData;
  int _position = 0;
  final Endian endian;

  /// Creates a writer with initial buffer capacity.
  ByteBufferWriter([int initialCapacity = 256, this.endian = Endian.big])
      : _buffer = Uint8List(initialCapacity > 0 ? initialCapacity : 256),
        _byteData = ByteData.sublistView(
            Uint8List(initialCapacity > 0 ? initialCapacity : 256)) {
    _byteData = ByteData.sublistView(_buffer);
  }

  /// Current write offset in bytes.
  int get position => _position;

  /// Total allocated capacity in bytes.
  int get capacity => _buffer.length;

  /// Sets write position.
  void seek(int pos) {
    if (pos < 0) {
      throw RangeError.value(pos, 'pos', 'Cannot seek to negative position');
    }
    _ensureCapacity(pos);
    _position = pos;
  }

  /// Clears writer position without reallocating buffer.
  void reset() {
    _position = 0;
  }

  /// Writes single 8-bit unsigned byte.
  void writeByte(int byte) {
    _ensureCapacity(_position + 1);
    _buffer[_position++] = byte & 0xFF;
  }

  /// Writes sequence of raw bytes.
  void writeBytes(List<int> bytes, [int offset = 0, int? length]) {
    final count = length ?? (bytes.length - offset);
    if (count <= 0) return;
    _ensureCapacity(_position + count);
    for (var i = 0; i < count; i++) {
      _buffer[_position++] = bytes[offset + i] & 0xFF;
    }
  }

  /// Writes BytesRef slice directly into stream.
  void writeBytesRef(BytesRef ref) {
    writeBytes(ref.bytes, ref.offset, ref.length);
  }

  /// Writes signed 16-bit integer.
  void writeInt16(int value) {
    _ensureCapacity(_position + 2);
    _byteData.setInt16(_position, value, endian);
    _position += 2;
  }

  /// Writes signed 32-bit integer.
  void writeInt32(int value) {
    _ensureCapacity(_position + 4);
    _byteData.setInt32(_position, value, endian);
    _position += 4;
  }

  /// Writes unsigned 32-bit integer.
  void writeUint32(int value) {
    _ensureCapacity(_position + 4);
    _byteData.setUint32(_position, value, endian);
    _position += 4;
  }

  /// Writes signed 64-bit integer.
  void writeInt64(int value) {
    _ensureCapacity(_position + 8);
    _byteData.setInt64(_position, value, endian);
    _position += 8;
  }

  /// Writes 32-bit IEEE 754 floating point number.
  void writeFloat32(double value) {
    _ensureCapacity(_position + 4);
    _byteData.setFloat32(_position, value, endian);
    _position += 4;
  }

  /// Writes 64-bit IEEE 754 floating point number.
  void writeFloat64(double value) {
    _ensureCapacity(_position + 8);
    _byteData.setFloat64(_position, value, endian);
    _position += 8;
  }

  /// Writes length-prefixed UTF-8 string (int32 length followed by UTF-8 bytes).
  void writeString(String text) {
    final bytes = utf8.encode(text);
    writeInt32(bytes.length);
    writeBytes(bytes);
  }

  /// Returns exact byte array copy of written data.
  Uint8List toBytes() {
    final result = Uint8List(_position);
    result.setRange(0, _position, _buffer);
    return result;
  }

  /// Returns a non-copying BytesRef view of written data.
  BytesRef toBytesRef() => BytesRef(_buffer, 0, _position);

  void _ensureCapacity(int required) {
    if (required > _buffer.length) {
      var newCap = _buffer.length * 2;
      if (newCap < required) newCap = required;
      final newBuf = Uint8List(newCap);
      newBuf.setRange(0, _position, _buffer);
      _buffer = newBuf;
      _byteData = ByteData.sublistView(_buffer);
    }
  }
}

/// Binary stream deserializer with zero-copy slice support.
class ByteBufferReader {
  final Uint8List _buffer;
  final ByteData _byteData;
  int _position = 0;
  final Endian endian;

  /// Creates a reader over an existing byte buffer.
  ByteBufferReader(this._buffer, [this.endian = Endian.big])
      : _byteData = ByteData.sublistView(_buffer);

  /// Factory creating a reader from a BytesRef slice.
  factory ByteBufferReader.fromBytesRef(BytesRef ref, [Endian endian = Endian.big]) {
    final slice = ref.bytes.sublist(ref.offset, ref.offset + ref.length);
    return ByteBufferReader(slice, endian);
  }

  /// Current read position in bytes.
  int get position => _position;

  /// Total number of bytes available.
  int get length => _buffer.length;

  /// Number of unread bytes remaining in stream.
  int get remaining => _buffer.length - _position;

  /// Checks if stream has more unread bytes.
  bool get hasRemaining => _position < _buffer.length;

  /// Seeks to absolute byte offset.
  void seek(int pos) {
    if (pos < 0 || pos > _buffer.length) {
      throw RangeError.range(pos, 0, _buffer.length, 'pos', 'Seek target out of bounds');
    }
    _position = pos;
  }

  /// Reads single 8-bit unsigned byte.
  int readByte() {
    _checkBounds(1);
    return _buffer[_position++];
  }

  /// Reads fixed number of raw bytes into a new byte array.
  Uint8List readBytes(int count) {
    _checkBounds(count);
    final slice = Uint8List(count);
    slice.setRange(0, count, _buffer, _position);
    _position += count;
    return slice;
  }

  /// Reads non-copying BytesRef view over the stream.
  BytesRef readBytesRef(int count) {
    _checkBounds(count);
    final ref = BytesRef(_buffer, _position, count);
    _position += count;
    return ref;
  }

  /// Reads signed 16-bit integer.
  int readInt16() {
    _checkBounds(2);
    final val = _byteData.getInt16(_position, endian);
    _position += 2;
    return val;
  }

  /// Reads signed 32-bit integer.
  int readInt32() {
    _checkBounds(4);
    final val = _byteData.getInt32(_position, endian);
    _position += 4;
    return val;
  }

  /// Reads unsigned 32-bit integer.
  int readUint32() {
    _checkBounds(4);
    final val = _byteData.getUint32(_position, endian);
    _position += 4;
    return val;
  }

  /// Reads signed 64-bit integer.
  int readInt64() {
    _checkBounds(8);
    final val = _byteData.getInt64(_position, endian);
    _position += 8;
    return val;
  }

  /// Reads 32-bit IEEE 754 float.
  double readFloat32() {
    _checkBounds(4);
    final val = _byteData.getFloat32(_position, endian);
    _position += 4;
    return val;
  }

  /// Reads 64-bit IEEE 754 float.
  double readFloat64() {
    _checkBounds(8);
    final val = _byteData.getFloat64(_position, endian);
    _position += 8;
    return val;
  }

  /// Reads length-prefixed UTF-8 string.
  String readString() {
    final len = readInt32();
    _checkBounds(len);
    final text = utf8.decode(_buffer.sublist(_position, _position + len));
    _position += len;
    return text;
  }

  /// Creates a sub-reader slice starting at current position.
  ByteBufferReader slice(int count) {
    _checkBounds(count);
    final sub = Uint8List(count);
    sub.setRange(0, count, _buffer, _position);
    _position += count;
    return ByteBufferReader(sub, endian);
  }

  void _checkBounds(int count) {
    if (_position + count > _buffer.length) {
      throw RangeError('Buffer underflow: requested $count bytes, only ${_buffer.length - _position} remaining');
    }
  }
}
