import 'dart:math' as math;
import 'dart:typed_data';

/// K-Means vector clustering using k-means++ initialization and Lloyd's iterative refinement.
class KMeans {
  final int k;
  final int maxIterations;
  final double tolerance;
  final math.Random _random;

  KMeans({
    required this.k,
    this.maxIterations = 50,
    this.tolerance = 1e-4,
    int? seed,
  }) : _random = math.Random(seed ?? 42);

  /// Trains [k] cluster centroids from input training vectors.
  List<Float32List> fit(List<Float32List> vectors) {
    if (vectors.isEmpty) {
      throw ArgumentError('Cannot fit KMeans on empty vectors list');
    }

    final n = vectors.length;
    final dim = vectors.first.length;
    final actualK = math.min(k, n);

    // 1. K-Means++ initialization
    final centroids = <Float32List>[];
    centroids.add(Float32List.fromList(vectors[_random.nextInt(n)]));

    final distances = List<double>.filled(n, double.infinity);

    while (centroids.length < actualK) {
      final lastCentroid = centroids.last;
      var sumDist = 0.0;

      for (var i = 0; i < n; i++) {
        final d = _squaredDistance(vectors[i], lastCentroid);
        if (d < distances[i]) {
          distances[i] = d;
        }
        sumDist += distances[i];
      }

      final target = _random.nextDouble() * sumDist;
      var accum = 0.0;
      var chosenIndex = 0;

      for (var i = 0; i < n; i++) {
        accum += distances[i];
        if (accum >= target) {
          chosenIndex = i;
          break;
        }
      }

      centroids.add(Float32List.fromList(vectors[chosenIndex]));
    }

    // 2. Lloyd's iterations
    final clusterSums = List.generate(
      actualK,
      (_) => Float64List(dim),
    );
    final clusterCounts = List<int>.filled(actualK, 0);

    for (var iter = 0; iter < maxIterations; iter++) {
      for (var i = 0; i < actualK; i++) {
        clusterSums[i].fillRange(0, dim, 0.0);
        clusterCounts[i] = 0;
      }

      // Assignment step
      for (var i = 0; i < n; i++) {
        final v = vectors[i];
        var bestIdx = 0;
        var bestDist = double.infinity;

        for (var c = 0; c < actualK; c++) {
          final dist = _squaredDistance(v, centroids[c]);
          if (dist < bestDist) {
            bestDist = dist;
            bestIdx = c;
          }
        }

        clusterCounts[bestIdx]++;
        for (var d = 0; d < dim; d++) {
          clusterSums[bestIdx][d] += v[d];
        }
      }

      // Update step & check convergence
      var maxShift = 0.0;
      for (var c = 0; c < actualK; c++) {
        final count = clusterCounts[c];
        if (count == 0) continue;

        var shift = 0.0;
        for (var d = 0; d < dim; d++) {
          final newCoord = (clusterSums[c][d] / count).toDouble();
          final diff = newCoord - centroids[c][d];
          shift += diff * diff;
          centroids[c][d] = newCoord;
        }

        if (shift > maxShift) {
          maxShift = shift;
        }
      }

      if (math.sqrt(maxShift) < tolerance) {
        break; // Converged
      }
    }

    return centroids;
  }

  /// Assigns a vector to its nearest centroid index.
  int predict(Float32List vector, List<Float32List> centroids) {
    var bestIdx = 0;
    var bestDist = double.infinity;

    for (var i = 0; i < centroids.length; i++) {
      final dist = _squaredDistance(vector, centroids[i]);
      if (dist < bestDist) {
        bestDist = dist;
        bestIdx = i;
      }
    }

    return bestIdx;
  }

  static double _squaredDistance(Float32List a, Float32List b) {
    var sum = 0.0;
    for (var i = 0; i < a.length; i++) {
      final diff = a[i] - b[i];
      sum += diff * diff;
    }
    return sum;
  }
}
