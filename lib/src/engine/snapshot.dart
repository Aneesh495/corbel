import '../core/schema.dart';
import '../index/segment_reader.dart';
import '../query/query.dart';

/// Immutable point-in-time snapshot of committed segments for consistent read isolation.
class IndexSnapshot {
  final List<SegmentReader> segmentReaders;
  final Schema schema;
  final IndexSearchContext context;
  bool _closed = false;

  IndexSnapshot({
    required this.segmentReaders,
    required this.schema,
  }) : context = _computeContext(segmentReaders);

  static IndexSearchContext _computeContext(List<SegmentReader> readers) {
    var totalDocs = 0;
    final docCounts = <String, int>{};

    for (final reader in readers) {
      totalDocs += reader.info.numDocs;
    }

    return IndexSearchContext(
      totalDocumentCount: totalDocs,
      fieldDocCounts: docCounts,
    );
  }

  /// Total number of live documents visible in this snapshot.
  int get numDocs => context.totalDocumentCount;

  /// Closes snapshot reader handles.
  void close() {
    if (!_closed) {
      for (final r in segmentReaders) {
        r.close();
      }
      _closed = true;
    }
  }
}
