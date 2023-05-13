import 'dart:math' as math;

/// Single centroid in a T-Digest cluster holding mean value and cumulative weight.
class Centroid implements Comparable<Centroid> {
  double mean;
  double weight;

  Centroid(this.mean, this.weight);

  void add(double x, double w) {
    weight += w;
    mean += w * (x - mean) / weight;
  }

  @override
  int compareTo(Centroid other) => mean.compareTo(other.mean);
}

/// T-Digest data structure for highly accurate online streaming quantile estimation.
/// Reference: Ted Dunning, Otmar Ertl, "Computing Extremely Accurate Quantiles Using t-Digests", 2019.
class TDigest {
  /// Compression parameter controlling accuracy versus memory overhead.
  final double delta;

  final List<Centroid> _centroids = [];
  double _totalWeight = 0.0;
  double _min = double.infinity;
  double _max = -double.infinity;

  TDigest({this.delta = 100.0});

  /// Total count/weight of observations added.
  double get totalWeight => _totalWeight;

  /// Minimum value observed.
  double get min => _min;

  /// Maximum value observed.
  double get max => _max;

  /// Number of centroids currently stored.
  int get centroidCount => _centroids.length;

  /// Adds an observation [x] with optional weight [w].
  void add(double x, [double w = 1.0]) {
    if (x.isNaN) return;
    if (x < _min) _min = x;
    if (x > _max) _max = x;

    _centroids.add(Centroid(x, w));
    _totalWeight += w;

    if (_centroids.length > delta * 10) {
      compress();
    }
  }

  /// Merges another T-Digest into this one.
  void merge(TDigest other) {
    if (other._centroids.isEmpty) return;
    if (other._min < _min) _min = other._min;
    if (other._max > _max) _max = other._max;

    _centroids.addAll(other._centroids);
    _totalWeight += other._totalWeight;
    compress();
  }

  /// Compresses centroids by merging adjacent clusters within size thresholds.
  void compress() {
    if (_centroids.length <= 1) return;

    _centroids.sort();
    final merged = <Centroid>[_centroids.first];
    var weightSoFar = _centroids.first.weight;

    for (var i = 1; i < _centroids.length; i++) {
      final curr = _centroids[i];
      final last = merged.last;

      final q = weightSoFar / _totalWeight;
      // Scale function limit k1: clusters near tails (q ~ 0 or 1) have small maximum sizes
      final maxSize = 4.0 * _totalWeight * q * (1.0 - q) / delta;
      final proposedWeight = last.weight + curr.weight;

      if (proposedWeight <= math.max(1.0, maxSize)) {
        last.add(curr.mean, curr.weight);
      } else {
        merged.add(curr);
      }
      weightSoFar += curr.weight;
    }

    _centroids
      ..clear()
      ..addAll(merged);
  }

  /// Computes the value at the given percentile fraction [q] (between 0.0 and 1.0).
  double quantile(double q) {
    if (_centroids.isEmpty) return double.nan;
    if (_centroids.length == 1) return _centroids.first.mean;
    if (q <= 0.0) return _min;
    if (q >= 1.0) return _max;

    compress();

    final targetWeight = q * _totalWeight;
    var currentWeight = 0.0;

    for (var i = 0; i < _centroids.length; i++) {
      final c = _centroids[i];
      final nextWeight = currentWeight + c.weight;

      if (nextWeight >= targetWeight) {
        if (i == 0) {
          final frac = targetWeight / c.weight;
          return _min + frac * (c.mean - _min);
        } else if (i == _centroids.length - 1) {
          final frac = (targetWeight - currentWeight) / c.weight;
          return c.mean + frac * (_max - c.mean);
        } else {
          final prev = _centroids[i - 1];
          final prevMid = currentWeight - prev.weight / 2.0;
          final currMid = currentWeight + c.weight / 2.0;
          final span = currMid - prevMid;
          if (span <= 0.0) return c.mean;
          final frac = (targetWeight - prevMid) / span;
          return prev.mean + frac * (c.mean - prev.mean);
        }
      }
      currentWeight = nextWeight;
    }

    return _max;
  }
}
