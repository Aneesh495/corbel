import 'dart:typed_data';
import '../../storage/index_input.dart';
import '../../storage/index_output.dart';
import '../../storage/vbyte.dart';
import '../../utils/bytes_ref.dart';

/// Columnar binary DocValues storing arbitrary byte slices per document.
class BinaryDocValues {
  final int count;
  final Int32List _offsets;
  final Uint8List _bytes;

  BinaryDocValues._(this.count, this._offsets, this._bytes);

  /// Writes binary DocValues to output stream.
  static void write(IndexOutput out, List<Uint8List> values) {
    final count = values.length;
    VByteCodec.writeVInt(out, count);
    if (count == 0) return;

    var totalBytes = 0;
    for (final v in values) {
      totalBytes += v.length;
    }

    VByteCodec.writeVInt(out, totalBytes);
    var currentOffset = 0;
    for (final v in values) {
      VByteCodec.writeVInt(out, v.length);
      out.writeBytes(v);
      currentOffset += v.length;
    }
  }

  /// Reads binary DocValues from input stream.
  static BinaryDocValues read(IndexInput inp) {
    final count = inp.readVInt();
    if (count == 0) {
      return BinaryDocValues._(0, Int32List(0), Uint8List(0));
    }

    final totalBytes = inp.readVInt();
    final offsets = Int32List(count + 1);
    final buffer = Uint8List(totalBytes);

    var currentOffset = 0;
    for (var i = 0; i < count; i++) {
      offsets[i] = currentOffset;
      final len = inp.readVInt();
      final bytes = inp.readBytes(len);
      buffer.setRange(currentOffset, currentOffset + len, bytes);
      currentOffset += len;
    }
    offsets[count] = currentOffset;

    return BinaryDocValues._(count, offsets, buffer);
  }

  /// Retrieves byte slice for document [docId].
  BytesRef get(int docId) {
    if (docId < 0 || docId >= count) {
      throw RangeError.index(docId, this, 'docId', 'Document ID out of bounds', count);
    }
    final start = _offsets[docId];
    final end = _offsets[docId + 1];
    return BytesRef(_bytes, start, end - start);
  }
}
