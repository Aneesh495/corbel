import 'dart:math' as math;
import 'dart:typed_data';
import '../../core/schema.dart';

/// High-performance vector distance kernels optimized for 32-bit floating point vectors.
class VectorDistance {
  /// Squared Euclidean (L2) distance avoiding square root calculation during heap scoring.
  static double squaredEuclidean(Float32List a, Float32List b) {
    if (a.length != b.length) {
      throw ArgumentError('Vector dimension mismatch: ${a.length} vs ${b.length}');
    }

    final len = a.length;
    var sum = 0.0;
    var i = 0;

    // 4-wide loop unrolling
    final limit = len - 3;
    while (i < limit) {
      final d0 = a[i] - b[i];
      final d1 = a[i + 1] - b[i + 1];
      final d2 = a[i + 2] - b[i + 2];
      final d3 = a[i + 3] - b[i + 3];
      sum += d0 * d0 + d1 * d1 + d2 * d2 + d3 * d3;
      i += 4;
    }

    // Residual elements
    while (i < len) {
      final d = a[i] - b[i];
      sum += d * d;
      i++;
    }

    return sum;
  }

  /// Euclidean (L2) distance.
  static double euclidean(Float32List a, Float32List b) {
    return math.sqrt(squaredEuclidean(a, b));
  }

  /// Inner dot product of two vectors.
  static double dotProduct(Float32List a, Float32List b) {
    if (a.length != b.length) {
      throw ArgumentError('Vector dimension mismatch: ${a.length} vs ${b.length}');
    }

    final len = a.length;
    var sum = 0.0;
    var i = 0;

    final limit = len - 3;
    while (i < limit) {
      sum += a[i] * b[i] +
          a[i + 1] * b[i + 1] +
          a[i + 2] * b[i + 2] +
          a[i + 3] * b[i + 3];
      i += 4;
    }

    while (i < len) {
      sum += a[i] * b[i];
      i++;
    }

    return sum;
  }

  /// Cosine similarity: normalized inner product in [-1.0, 1.0].
  static double cosineSimilarity(Float32List a, Float32List b) {
    if (a.length != b.length) {
      throw ArgumentError('Vector dimension mismatch: ${a.length} vs ${b.length}');
    }

    var dot = 0.0;
    var normA = 0.0;
    var normB = 0.0;
    final len = a.length;

    for (var i = 0; i < len; i++) {
      final va = a[i];
      final vb = b[i];
      dot += va * vb;
      normA += va * va;
      normB += vb * vb;
    }

    if (normA == 0.0 || normB == 0.0) return 0.0;
    final sim = dot / (math.sqrt(normA) * math.sqrt(normB));
    // Clamp to valid range [-1.0, 1.0] against precision drift
    if (sim > 1.0) return 1.0;
    if (sim < -1.0) return -1.0;
    return sim;
  }

  /// Cosine distance: metric in [0.0, 2.0] where 0.0 represents identical vectors.
  static double cosineDistance(Float32List a, Float32List b) {
    return 1.0 - cosineSimilarity(a, b);
  }

  /// Manhattan (L1) distance.
  static double manhattan(Float32List a, Float32List b) {
    if (a.length != b.length) {
      throw ArgumentError('Vector dimension mismatch: ${a.length} vs ${b.length}');
    }

    var sum = 0.0;
    final len = a.length;
    for (var i = 0; i < len; i++) {
      sum += (a[i] - b[i]).abs();
    }
    return sum;
  }

  /// Normalizes vector to unit L2 norm in-place.
  static void normalizeInPlace(Float32List v) {
    var norm = 0.0;
    for (var i = 0; i < v.length; i++) {
      norm += v[i] * v[i];
    }
    if (norm == 0.0) return;
    final scale = 1.0 / math.sqrt(norm);
    for (var i = 0; i < v.length; i++) {
      v[i] *= scale;
    }
  }

  /// Computes distance according to configured VectorDistanceMetric.
  static double compute(
    VectorDistanceMetric metric,
    Float32List a,
    Float32List b,
  ) {
    switch (metric) {
      case VectorDistanceMetric.l2:
        return squaredEuclidean(a, b);
      case VectorDistanceMetric.cosine:
        return cosineDistance(a, b);
      case VectorDistanceMetric.dotProduct:
        return -dotProduct(a, b); // Negate so smaller distance means more similar
      case VectorDistanceMetric.manhattan:
        return manhattan(a, b);
    }
  }
}
