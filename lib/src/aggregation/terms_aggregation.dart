import '../index/segment_reader.dart';
import '../utils/priority_queue.dart';

/// Abstract contract for columnar aggregations.
abstract class Aggregation {
  final String name;

  const Aggregation({required this.name});

  /// Instantiates a segment-level collector for accumulating values in [segmentReader].
  AggregationCollector newCollector(SegmentReader segmentReader);
}

/// Collector operating on a single segment during search execution.
abstract class AggregationCollector {
  final String name;

  AggregationCollector({required this.name});

  /// Collects columnar data for the specified live [docId].
  void collect(int docId);

  /// Builds the segment-level aggregation result.
  AggregationResult buildResult();
}

/// Generic aggregation result container.
abstract class AggregationResult {
  final String name;

  const AggregationResult({required this.name});

  /// Merges another segment's partial aggregation result into this one.
  AggregationResult mergeWith(AggregationResult other);

  /// Serializes result to a JSON-compatible map.
  Map<String, dynamic> toJson();
}

/// Single term frequency bucket.
class TermBucket implements Comparable<TermBucket> {
  final String key;
  int count;

  TermBucket({
    required this.key,
    required this.count,
  });

  @override
  int compareTo(TermBucket other) {
    final cmp = count.compareTo(other.count);
    if (cmp != 0) return cmp;
    return other.key.compareTo(key); // Secondary alphabetical tie-break
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'doc_count': count,
      };
}

/// Multi-bucket terms aggregation grouping documents by categorical field values.
class TermsAggregation extends Aggregation {
  final String field;
  final int size;
  final int minDocCount;

  const TermsAggregation({
    required super.name,
    required this.field,
    this.size = 10,
    this.minDocCount = 1,
  });

  @override
  AggregationCollector newCollector(SegmentReader segmentReader) {
    return _TermsCollector(
      name: name,
      field: field,
      size: size,
      minDocCount: minDocCount,
      segmentReader: segmentReader,
    );
  }
}

class _TermsCollector extends AggregationCollector {
  final String field;
  final int size;
  final int minDocCount;
  final SegmentReader segmentReader;

  final Map<String, int> _counts = {};
  dynamic _ssdv;
  dynamic _bdv;

  _TermsCollector({
    required super.name,
    required this.field,
    required this.size,
    required this.minDocCount,
    required this.segmentReader,
  }) {
    _ssdv = segmentReader.getSortedSetDocValues(field);
    if (_ssdv == null) {
      _bdv = segmentReader.getBinaryDocValues(field);
    }
  }

  @override
  void collect(int docId) {
    if (_ssdv != null) {
      final ordinals = _ssdv.getOrdinals(docId) as List<int>;
      for (final ord in ordinals) {
        final term = _ssdv.lookupOrd(ord) as String;
        _counts[term] = (_counts[term] ?? 0) + 1;
      }
    } else if (_bdv != null) {
      final bytesRef = _bdv.get(docId);
      if (bytesRef != null && (bytesRef.length as int) > 0) {
        final term = bytesRef.utf8String() as String;
        _counts[term] = (_counts[term] ?? 0) + 1;
      }
    }
  }

  @override
  AggregationResult buildResult() {
    return TermsAggregationResult(
      name: name,
      counts: _counts,
      size: size,
      minDocCount: minDocCount,
    );
  }
}

/// Result of terms facet aggregation containing top-k term buckets.
class TermsAggregationResult extends AggregationResult {
  final Map<String, int> counts;
  final int size;
  final int minDocCount;

  const TermsAggregationResult({
    required super.name,
    required this.counts,
    required this.size,
    required this.minDocCount,
  });

  List<TermBucket> get buckets {
    final pq = BoundedPriorityQueue<TermBucket>(
      size,
      (a, b) => a.compareTo(b),
    );

    for (final entry in counts.entries) {
      if (entry.value >= minDocCount) {
        pq.insertWithOverflow(TermBucket(key: entry.key, count: entry.value));
      }
    }

    final topK = <TermBucket>[];
    while (pq.isNotEmpty) {
      topK.add(pq.pop());
    }
    return topK.reversed.toList();
  }

  @override
  AggregationResult mergeWith(AggregationResult other) {
    if (other is! TermsAggregationResult) return this;

    final merged = Map<String, int>.from(counts);
    for (final entry in other.counts.entries) {
      merged[entry.key] = (merged[entry.key] ?? 0) + entry.value;
    }

    return TermsAggregationResult(
      name: name,
      counts: merged,
      size: size,
      minDocCount: minDocCount,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    final bucketList = buckets.map((b) => b.toJson()).toList();
    var otherDocCount = 0;
    final topKeys = bucketList.map((b) => b['key']).toSet();

    for (final entry in counts.entries) {
      if (!topKeys.contains(entry.key)) {
        otherDocCount += entry.value;
      }
    }

    return {
      'doc_count_error_upper_bound': 0,
      'sum_other_doc_count': otherDocCount,
      'buckets': bucketList,
    };
  }
}
