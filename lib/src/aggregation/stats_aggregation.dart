import 'dart:math' as math;
import '../index/segment_reader.dart';
import 't_digest.dart';
import 'terms_aggregation.dart';

/// Single-pass numerically stable statistics aggregation (min, max, sum, avg, variance, stdDev).
class StatsAggregation extends Aggregation {
  final String field;

  const StatsAggregation({
    required super.name,
    required this.field,
  });

  @override
  AggregationCollector newCollector(SegmentReader segmentReader) {
    return _StatsCollector(
      name: name,
      field: field,
      segmentReader: segmentReader,
    );
  }
}

class _StatsCollector extends AggregationCollector {
  final String field;
  final SegmentReader segmentReader;

  dynamic _ndv;
  int _count = 0;
  double _min = double.infinity;
  double _max = -double.infinity;
  double _sum = 0.0;
  double _m2 = 0.0; // Welford's accumulator for variance

  _StatsCollector({
    required super.name,
    required this.field,
    required this.segmentReader,
  }) {
    _ndv = segmentReader.getNumericDocValues(field);
  }

  @override
  void collect(int docId) {
    if (_ndv == null) return;
    final val = (_ndv.get(docId) as num).toDouble();

    _count++;
    _sum += val;
    if (val < _min) _min = val;
    if (val > _max) _max = val;

    // Welford's update
    final delta = val - (_sum / _count);
    final delta2 = val - ((_sum - val) / math.max(1, _count - 1));
    _m2 += delta * delta2;
  }

  @override
  AggregationResult buildResult() {
    return StatsAggregationResult(
      name: name,
      count: _count,
      min: _count > 0 ? _min : 0.0,
      max: _count > 0 ? _max : 0.0,
      sum: _sum,
      m2: _m2,
    );
  }
}

/// Statistics aggregation result container.
class StatsAggregationResult extends AggregationResult {
  final int count;
  final double min;
  final double max;
  final double sum;
  final double m2;

  const StatsAggregationResult({
    required super.name,
    required this.count,
    required this.min,
    required this.max,
    required this.sum,
    required this.m2,
  });

  double get avg => count > 0 ? sum / count : 0.0;

  double get variance => count > 1 ? m2 / (count - 1) : 0.0;

  double get stdDeviation => math.sqrt(variance);

  @override
  AggregationResult mergeWith(AggregationResult other) {
    if (other is! StatsAggregationResult) return this;
    if (count == 0) return other;
    if (other.count == 0) return this;

    final newCount = count + other.count;
    final newSum = sum + other.sum;
    final newMin = math.min(min, other.min);
    final newMax = math.max(max, other.max);

    // Parallel Welford variance merge
    final delta = other.avg - avg;
    final newM2 = m2 + other.m2 + (delta * delta * count * other.count / newCount);

    return StatsAggregationResult(
      name: name,
      count: newCount,
      min: newMin,
      max: newMax,
      sum: newSum,
      m2: newM2,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'count': count,
        'min': min,
        'max': max,
        'avg': avg,
        'sum': sum,
        'variance': variance,
        'std_deviation': stdDeviation,
      };
}

/// Streaming percentiles aggregation based on T-Digest sketches.
class PercentilesAggregation extends Aggregation {
  final String field;
  final List<double> percents;

  const PercentilesAggregation({
    required super.name,
    required this.field,
    this.percents = const [1.0, 5.0, 25.0, 50.0, 75.0, 95.0, 99.0],
  });

  @override
  AggregationCollector newCollector(SegmentReader segmentReader) {
    return _PercentilesCollector(
      name: name,
      field: field,
      percents: percents,
      segmentReader: segmentReader,
    );
  }
}

class _PercentilesCollector extends AggregationCollector {
  final String field;
  final List<double> percents;
  final SegmentReader segmentReader;

  final TDigest _tDigest = TDigest();
  dynamic _ndv;

  _PercentilesCollector({
    required super.name,
    required this.field,
    required this.percents,
    required this.segmentReader,
  }) {
    _ndv = segmentReader.getNumericDocValues(field);
  }

  @override
  void collect(int docId) {
    if (_ndv == null) return;
    final val = (_ndv.get(docId) as num).toDouble();
    _tDigest.add(val);
  }

  @override
  AggregationResult buildResult() {
    return PercentilesAggregationResult(
      name: name,
      percents: percents,
      tDigest: _tDigest,
    );
  }
}

/// Result of T-Digest percentiles sketch estimation.
class PercentilesAggregationResult extends AggregationResult {
  final List<double> percents;
  final TDigest tDigest;

  const PercentilesAggregationResult({
    required super.name,
    required this.percents,
    required this.tDigest,
  });

  @override
  AggregationResult mergeWith(AggregationResult other) {
    if (other is! PercentilesAggregationResult) return this;

    final mergedDigest = TDigest();
    mergedDigest.merge(tDigest);
    mergedDigest.merge(other.tDigest);

    return PercentilesAggregationResult(
      name: name,
      percents: percents,
      tDigest: mergedDigest,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    final values = <String, double>{};
    for (final p in percents) {
      final q = p / 100.0;
      values[p.toString()] = tDigest.quantile(q);
    }
    return {'values': values};
  }
}
