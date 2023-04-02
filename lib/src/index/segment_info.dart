import '../../core/schema.dart';
import '../../storage/index_input.dart';
import '../../storage/index_output.dart';
import '../../storage/vbyte.dart';

/// Immutable metadata describing an individual index segment.
class SegmentInfo {
  /// Unique segment identifier (e.g., '_0', '_1').
  final String name;

  /// Maximum internal document ID in this segment.
  final int maxDoc;

  /// Number of soft-deleted documents.
  final int delCount;

  /// Total storage footprint of this segment in bytes.
  final int sizeInBytes;

  /// Segment format version.
  final int version;

  /// Schema snapshot configured for this segment.
  final Schema schema;

  const SegmentInfo({
    required this.name,
    required this.maxDoc,
    this.delCount = 0,
    this.sizeInBytes = 0,
    this.version = 1,
    required this.schema,
  });

  /// Number of live, non-deleted documents in this segment.
  int get numDocs => maxDoc - delCount;

  /// Serializes segment info to output stream.
  void serialize(IndexOutput out) {
    out.writeString(name);
    VByteCodec.writeVInt(out, maxDoc);
    VByteCodec.writeVInt(out, delCount);
    VByteCodec.writeVLong(out, sizeInBytes);
    VByteCodec.writeVInt(out, version);
  }

  /// Deserializes segment info from input stream.
  static SegmentInfo deserialize(IndexInput inp, Schema schema) {
    final name = inp.readString();
    final maxDoc = inp.readVInt();
    final delCount = inp.readVInt();
    final sizeInBytes = inp.readVLong();
    final version = inp.readVInt();

    return SegmentInfo(
      name: name,
      maxDoc: maxDoc,
      delCount: delCount,
      sizeInBytes: sizeInBytes,
      version: version,
      schema: schema,
    );
  }

  @override
  String toString() =>
      'SegmentInfo($name, maxDoc: $maxDoc, delCount: $delCount, live: $numDocs)';
}
