import '../index/segment_reader.dart';
import 'terms_aggregation.dart';

/// Specification for a numeric range bucket [from, to).
class RangeBucketSpec {
  final String? key;
  final num? from;
  final num? to;

  const RangeBucketSpec({
    this.key,
    this.from,
    this.to,
  });

  String get effectiveKey => key ?? '${from ?? "*"}-${to ?? "*"}';

  bool contains(num val) {
    if (from != null && val < from!) return false;
    if (to != null && val >= to!) return false;
    return true;
  }
}

/// Aggregation dividing numeric columnar data into defined intervals.
class RangeAggregation extends Aggregation {
  final String field;
  final List<RangeBucketSpec> ranges;

  const RangeAggregation({
    required super.name,
    required this.field,
    required this.ranges,
  });

  @override
  AggregationCollector newCollector(SegmentReader segmentReader) {
    return _RangeCollector(
      name: name,
      field: field,
      ranges: ranges,
      segmentReader: segmentReader,
    );
  }
}

class _RangeCollector extends AggregationCollector {
  final String field;
  final List<RangeBucketSpec> ranges;
  final SegmentReader segmentReader;

  final List<int> _counts;
  dynamic _ndv;

  _RangeCollector({
    required super.name,
    required this.field,
    required this.ranges,
    required this.segmentReader,
  }) : _counts = List<int>.filled(ranges.length, 0) {
    _ndv = segmentReader.getNumericDocValues(field);
  }

  @override
  void collect(int docId) {
    if (_ndv == null) return;
    final val = _ndv.get(docId) as num;

    for (var i = 0; i < ranges.length; i++) {
      if (ranges[i].contains(val)) {
        _counts[i]++;
      }
    }
  }

  @override
  AggregationResult buildResult() {
    return RangeAggregationResult(
      name: name,
      ranges: ranges,
      counts: _counts,
    );
  }
}

/// Result of numeric range aggregation.
class RangeAggregationResult extends AggregationResult {
  final List<RangeBucketSpec> ranges;
  final List<int> counts;

  const RangeAggregationResult({
    required super.name,
    required this.ranges,
    required this.counts,
  });

  @override
  AggregationResult mergeWith(AggregationResult other) {
    if (other is! RangeAggregationResult) return this;

    final mergedCounts = List<int>.filled(ranges.length, 0);
    for (var i = 0; i < ranges.length; i++) {
      mergedCounts[i] = counts[i] + (i < other.counts.length ? other.counts[i] : 0);
    }

    return RangeAggregationResult(
      name: name,
      ranges: ranges,
      counts: mergedCounts,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    final bucketList = <Map<String, dynamic>>[];
    for (var i = 0; i < ranges.length; i++) {
      final r = ranges[i];
      bucketList.add({
        'key': r.effectiveKey,
        if (r.from != null) 'from': r.from,
        if (r.to != null) 'to': r.to,
        'doc_count': counts[i],
      });
    }
    return {'buckets': bucketList};
  }
}
