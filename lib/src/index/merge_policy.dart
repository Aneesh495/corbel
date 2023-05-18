import '../core/document.dart';
import '../core/schema.dart';
import '../storage/directory.dart';
import 'deletion_vector.dart';
import 'segment_info.dart';
import 'segment_reader.dart';
import 'segment_writer.dart';

/// Specification for a merge operation combining multiple segments into a new segment.
class MergeSpec {
  /// Target new consolidated segment name.
  final String mergedSegmentName;

  /// Source segments to be merged and compacted.
  final List<SegmentInfo> segmentsToMerge;

  const MergeSpec({
    required this.mergedSegmentName,
    required this.segmentsToMerge,
  });
}

/// Abstract policy determining when and which segments should be merged.
abstract class MergePolicy {
  const MergePolicy();

  /// Evaluates segment topology and selects candidate segments for merging.
  List<MergeSpec> findMerges(List<SegmentInfo> segments, int nextSegmentIndex);
}

/// Tiered log-merge policy organizing segments into logarithmic size tiers.
class TieredMergePolicy extends MergePolicy {
  /// Maximum number of segments allowed in a tier before triggering a merge.
  final int maxSegmentsPerTier;

  /// Maximum segment size in bytes eligible for merging.
  final int maxMergedSegmentBytes;

  /// Deletion percentage threshold (0.0 to 1.0) above which a segment is aggressively merged.
  final double reclaimDeletesWeight;

  const TieredMergePolicy({
    this.maxSegmentsPerTier = 10,
    this.maxMergedSegmentBytes = 5 * 1024 * 1024 * 1024, // 5 GB
    this.reclaimDeletesWeight = 0.20, // 20% deleted documents
  });

  /// Evaluates segment topology and selects candidate segments for merging.
  List<MergeSpec> findMerges(List<SegmentInfo> segments, int nextSegmentIndex) {
    if (segments.length < 2) return [];

    // Filter out segments exceeding maximum merge size
    final candidates = segments
        .where((s) => s.sizeInBytes < maxMergedSegmentBytes)
        .toList();

    // Sort by size ascending
    candidates.sort((a, b) => a.sizeInBytes.compareTo(b.sizeInBytes));

    final merges = <MergeSpec>[];

    // Check for high-deletion segments
    for (final seg in candidates) {
      if (seg.maxDoc > 0) {
        final delRatio = seg.delCount / seg.maxDoc;
        if (delRatio >= reclaimDeletesWeight && candidates.length >= 2) {
          // Merge with closest neighbor
          final others = candidates.where((s) => s.name != seg.name).toList();
          if (others.isNotEmpty) {
            merges.add(MergeSpec(
              mergedSegmentName: '_merge_${nextSegmentIndex++}',
              segmentsToMerge: [seg, others.first],
            ));
            return merges;
          }
        }
      }
    }

    // Tiered grouping: merge when segment count in a tier exceeds maxSegmentsPerTier
    if (candidates.length >= maxSegmentsPerTier) {
      final toMerge = candidates.take(maxSegmentsPerTier).toList();
      merges.add(MergeSpec(
        mergedSegmentName: '_merge_${nextSegmentIndex++}',
        segmentsToMerge: toMerge,
      ));
    }

    return merges;
  }
}

/// Compacts and merges multiple source segments into a single consolidated segment.
class SegmentMerger {
  final Directory directory;
  final Schema schema;
  final MergeSpec spec;
  final Map<String, DeletionVector> deletionVectors;

  SegmentMerger({
    required this.directory,
    required this.schema,
    required this.spec,
    required this.deletionVectors,
  });

  /// Executes the merge operation, creating the consolidated segment and purging deleted documents.
  SegmentInfo execute() {
    final writer = SegmentWriter(
      segmentName: spec.mergedSegmentName,
      schema: schema,
      directory: directory,
    );

    // Stream live non-deleted documents from all source segments
    for (final segInfo in spec.segmentsToMerge) {
      final delVec = deletionVectors[segInfo.name] ?? DeletionVector();
      final reader = SegmentReader.open(
        info: segInfo,
        directory: directory,
        deletionVector: delVec,
      );

      try {
        for (var docId = 0; docId < segInfo.maxDoc; docId++) {
          if (reader.isLive(docId)) {
            final rawMap = reader.document(docId);
            final doc = Document.fromMap(rawMap['_id'] as String, rawMap, schema: schema);
            writer.addDocument(doc);
          }
        }
      } finally {
        reader.close();
      }
    }

    final newInfo = writer.flush();

    // Clean up obsolete source segment files
    for (final segInfo in spec.segmentsToMerge) {
      _deleteSegmentFiles(segInfo.name);
    }

    return newInfo;
  }

  void _deleteSegmentFiles(String segName) {
    const extensions = [
      '.cbl_fst',
      '.cbl_pos',
      '.cbl_dvs',
      '.cbl_fdx',
      '.cbl_fdt',
    ];
    for (final ext in extensions) {
      final fileName = '$segName$ext';
      if (directory.fileExists(fileName)) {
        try {
          directory.deleteFile(fileName);
        } catch (_) {}
      }
    }
  }
}
