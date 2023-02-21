import 'dart:convert';
import 'dart:typed_data';
import 'vbyte.dart';

/// Abstract input stream for reading binary index segment files.
abstract class IndexInput {
  /// Current read position in bytes.
  int get position;

  /// Total length of stream in bytes.
  int get length;

  /// Number of remaining unread bytes.
  int get remaining => length - position;

  /// Reads single 8-bit unsigned byte.
  int readByte();

  /// Reads [count] bytes into a newly allocated byte buffer.
  Uint8List readBytes(int count) {
    final buffer = Uint8List(count);
    for (var i = 0; i < count; i++) {
      buffer[i] = readByte();
    }
    return buffer;
  }

  /// Reads signed 16-bit integer (big endian).
  int readInt16() {
    return (readByte() << 8) | readByte();
  }

  /// Reads signed 32-bit integer (big endian).
  int readInt32() {
    return (readByte() << 24) |
        (readByte() << 16) |
        (readByte() << 8) |
        readByte();
  }

  /// Reads unsigned 32-bit integer (big endian).
  int readUint32() {
    return readInt32() & 0xFFFFFFFF;
  }

  /// Reads signed 64-bit integer (big endian).
  int readInt64() {
    var val = 0;
    for (var i = 0; i < 8; i++) {
      val = (val << 8) | readByte();
    }
    return val;
  }

  /// Reads 32-bit IEEE 754 float.
  double readFloat32() {
    final bytes = readBytes(4);
    return ByteData.sublistView(bytes).getFloat32(0);
  }

  /// Reads 64-bit IEEE 754 float.
  double readFloat64() {
    final bytes = readBytes(8);
    return ByteData.sublistView(bytes).getFloat64(0);
  }

  /// Reads length-prefixed UTF-8 string.
  String readString() {
    final len = readInt32();
    final bytes = readBytes(len);
    return utf8.decode(bytes);
  }

  /// Reads unsigned variable-byte 32-bit int.
  int readVInt() {
    var b = readByte();
    var val = b & 0x7F;
    var shift = 7;
    while ((b & 0x80) != 0) {
      b = readByte();
      val |= (b & 0x7F) << shift;
      shift += 7;
    }
    return val;
  }

  /// Reads unsigned variable-byte 64-bit int.
  int readVLong() {
    var b = readByte();
    var val = b & 0x7F;
    var shift = 7;
    while ((b & 0x80) != 0) {
      b = readByte();
      val |= (b & 0x7F) << shift;
      shift += 7;
    }
    return val;
  }

  /// Reads signed ZigZag 32-bit int.
  int readZInt() {
    return VByteCodec.decodeZigZag32(readVInt());
  }

  /// Reads signed ZigZag 64-bit int.
  int readZLong() {
    return VByteCodec.decodeZigZag64(readVLong());
  }

  /// Seeks to absolute byte offset.
  void seek(int pos);

  /// Slices this input stream into a sub-stream without copying underlying buffers.
  IndexInput slice(String description, int offset, int count);

  /// Clones this input stream with independent position cursor.
  IndexInput clone();

  /// Closes stream resources.
  void close();
}

/// In-memory implementation of IndexInput backed by Uint8List.
class RAMIndexInput extends IndexInput {
  final Uint8List _data;
  final int _offset;
  final int _length;
  int _position = 0;
  bool _closed = false;

  RAMIndexInput(this._data, [this._offset = 0, int? length])
      : _length = length ?? (_data.length - _offset);

  @override
  int get position => _position;

  @override
  int get length => _length;

  @override
  int readByte() {
    _checkOpen();
    if (_position >= _length) {
      throw RangeError('End of stream reached at position $_position');
    }
    return _data[_offset + _position++];
  }

  @override
  Uint8List readBytes(int count) {
    _checkOpen();
    if (_position + count > _length) {
      throw RangeError('Buffer underflow: requested $count bytes, only ${_length - _position} available');
    }
    final slice = Uint8List(count);
    slice.setRange(0, count, _data, _offset + _position);
    _position += count;
    return slice;
  }

  @override
  void seek(int pos) {
    _checkOpen();
    if (pos < 0 || pos > _length) {
      throw RangeError.range(pos, 0, _length, 'pos', 'Seek target out of bounds');
    }
    _position = pos;
  }

  @override
  IndexInput slice(String description, int offset, int count) {
    _checkOpen();
    if (offset < 0 || count < 0 || offset + count > _length) {
      throw RangeError('Slice range [$offset, ${offset + count}) exceeds stream length $_length');
    }
    return RAMIndexInput(_data, _offset + offset, count);
  }

  @override
  IndexInput clone() {
    _checkOpen();
    final copy = RAMIndexInput(_data, _offset, _length);
    copy.seek(_position);
    return copy;
  }

  @override
  void close() {
    _closed = true;
  }

  void _checkOpen() {
    if (_closed) throw StateError('Cannot read from closed RAMIndexInput');
  }
}
