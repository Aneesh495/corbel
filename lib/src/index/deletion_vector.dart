import '../storage/byte_buffer.dart';
import '../storage/index_input.dart';
import '../storage/index_output.dart';
import '../storage/roaring_bitmap.dart';

/// Tracks soft-deleted document IDs within an index segment using RoaringBitmaps.
class DeletionVector {
  final RoaringBitmap _deletedDocs;
  int _delGen = 0;

  DeletionVector([RoaringBitmap? bitmap, this._delGen = 0])
      : _deletedDocs = bitmap ?? RoaringBitmap();

  /// Total number of deleted documents in this segment.
  int get numDeletions => _deletedDocs.cardinality;

  /// Deletion generation version counter.
  int get delGen => _delGen;

  /// Checks if [docId] has been marked as deleted.
  bool isDeleted(int docId) => _deletedDocs.contains(docId);

  /// Marks [docId] as deleted. Returns true if newly deleted, false if already deleted.
  bool delete(int docId) {
    if (_deletedDocs.contains(docId)) return false;
    _deletedDocs.add(docId);
    _delGen++;
    return true;
  }

  /// Clones the deletion vector for snapshotting.
  DeletionVector clone() {
    return DeletionVector(_deletedDocs.clone(), _delGen);
  }

  /// Serializes deletion vector to output stream.
  void serialize(IndexOutput out) {
    out.writeVInt(_delGen);
    final writer = ByteBufferWriter();
    _deletedDocs.serialize(writer);
    final bytes = writer.toBytes();
    out.writeVInt(bytes.length);
    out.writeBytes(bytes);
  }

  /// Deserializes deletion vector from input stream.
  static DeletionVector deserialize(IndexInput inp) {
    final delGen = inp.readVInt();
    final byteLen = inp.readVInt();
    final bytes = inp.readBytes(byteLen);
    final reader = ByteBufferReader(bytes);
    final bitmap = RoaringBitmap.deserialize(reader);
    return DeletionVector(bitmap, delGen);
  }
}
