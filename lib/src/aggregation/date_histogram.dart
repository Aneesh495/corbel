import '../index/segment_reader.dart';
import 'terms_aggregation.dart';

/// Aggregation bucketing temporal timestamps into fixed time intervals.
class DateHistogramAggregation extends Aggregation {
  final String field;
  final Duration interval;
  final int minDocCount;

  const DateHistogramAggregation({
    required super.name,
    required this.field,
    required this.interval,
    this.minDocCount = 0,
  });

  @override
  AggregationCollector newCollector(SegmentReader segmentReader) {
    return _DateHistogramCollector(
      name: name,
      field: field,
      intervalMs: interval.inMilliseconds,
      minDocCount: minDocCount,
      segmentReader: segmentReader,
    );
  }
}

class _DateHistogramCollector extends AggregationCollector {
  final String field;
  final int intervalMs;
  final int minDocCount;
  final SegmentReader segmentReader;

  final Map<int, int> _buckets = {};
  dynamic _ndv;

  _DateHistogramCollector({
    required super.name,
    required this.field,
    required this.intervalMs,
    required this.minDocCount,
    required this.segmentReader,
  }) {
    _ndv = segmentReader.getNumericDocValues(field);
  }

  @override
  void collect(int docId) {
    if (_ndv == null) return;
    final timestamp = _ndv.get(docId) as int;
    final bucketKey = (timestamp ~/ intervalMs) * intervalMs;
    _buckets[bucketKey] = (_buckets[bucketKey] ?? 0) + 1;
  }

  @override
  AggregationResult buildResult() {
    return DateHistogramResult(
      name: name,
      intervalMs: intervalMs,
      minDocCount: minDocCount,
      buckets: _buckets,
    );
  }
}

/// Result of date histogram aggregation ordered chronologically.
class DateHistogramResult extends AggregationResult {
  final int intervalMs;
  final int minDocCount;
  final Map<int, int> buckets;

  const DateHistogramResult({
    required super.name,
    required this.intervalMs,
    required this.minDocCount,
    required this.buckets,
  });

  @override
  AggregationResult mergeWith(AggregationResult other) {
    if (other is! DateHistogramResult) return this;

    final merged = Map<int, int>.from(buckets);
    for (final entry in other.buckets.entries) {
      merged[entry.key] = (merged[entry.key] ?? 0) + entry.value;
    }

    return DateHistogramResult(
      name: name,
      intervalMs: intervalMs,
      minDocCount: minDocCount,
      buckets: merged,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    final sortedKeys = buckets.keys.toList()..sort();
    final bucketList = <Map<String, dynamic>>[];

    for (final key in sortedKeys) {
      final count = buckets[key]!;
      if (count >= minDocCount) {
        final dateStr = DateTime.fromMillisecondsSinceEpoch(key, isUtc: true).toIso8601String();
        bucketList.add({
          'key_as_string': dateStr,
          'key': key,
          'doc_count': count,
        });
      }
    }

    return {'buckets': bucketList};
  }
}
