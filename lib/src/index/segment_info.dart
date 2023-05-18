import '../core/schema.dart';
import '../storage/index_input.dart';
import '../storage/index_output.dart';

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
    out.writeVInt(maxDoc);
    out.writeVInt(delCount);
    out.writeVLong(sizeInBytes);
    out.writeVInt(version);
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

  /// Converts segment info metadata to JSON map.
  Map<String, dynamic> toJson() => {
        'name': name,
        'max_doc': maxDoc,
        'del_count': delCount,
        'size_bytes': sizeInBytes,
        'version': version,
      };

  /// Constructs segment info metadata from JSON map and schema.
  factory SegmentInfo.fromJson(Map<String, dynamic> json, Schema schema) {
    return SegmentInfo(
      name: json['name'] as String,
      maxDoc: json['max_doc'] as int,
      delCount: json['del_count'] as int? ?? 0,
      sizeInBytes: json['size_bytes'] as int? ?? 0,
      version: json['version'] as int? ?? 1,
      schema: schema,
    );
  }

  @override
  String toString() =>
      'SegmentInfo($name, maxDoc: $maxDoc, delCount: $delCount, live: $numDocs)';
}
