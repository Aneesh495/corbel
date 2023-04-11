import 'dart:math' as math;
import 'dart:typed_data';

/// 8-bit uniform scalar quantizer reducing vector memory footprint by 75%.
class ScalarQuantizer {
  final int dimension;
  final double minVal;
  final double maxVal;
  final double _scale;
  final double _invScale;

  ScalarQuantizer({
    required this.dimension,
    required this.minVal,
    required this.maxVal,
  })  : _scale = (maxVal > minVal) ? 255.0 / (maxVal - minVal) : 1.0,
        _invScale = (maxVal > minVal) ? (maxVal - minVal) / 255.0 : 1.0;

  /// Trains a scalar quantizer over a representative training corpus of vectors.
  factory ScalarQuantizer.train(List<Float32List> corpus) {
    if (corpus.isEmpty) {
      throw ArgumentError('Training corpus cannot be empty');
    }
    final dim = corpus[0].length;
    var globalMin = corpus[0][0];
    var globalMax = corpus[0][0];

    for (final vec in corpus) {
      for (var i = 0; i < dim; i++) {
        final v = vec[i];
        if (v < globalMin) globalMin = v;
        if (v > globalMax) globalMax = v;
      }
    }

    return ScalarQuantizer(
      dimension: dim,
      minVal: globalMin,
      maxVal: globalMax,
    );
  }

  /// Quantizes a 32-bit float vector into 8-bit bytes.
  Uint8List quantize(Float32List vector) {
    if (vector.length != dimension) {
      throw ArgumentError('Dimension mismatch: expected $dimension, got ${vector.length}');
    }
    final bytes = Uint8List(dimension);
    for (var i = 0; i < dimension; i++) {
      var val = (vector[i] - minVal) * _scale;
      if (val < 0.0) val = 0.0;
      if (val > 255.0) val = 255.0;
      bytes[i] = val.round();
    }
    return bytes;
  }

  /// Reconstructs approximate float vector from 8-bit quantized bytes.
  Float32List dequantize(Uint8List bytes) {
    final vector = Float32List(dimension);
    for (var i = 0; i < dimension; i++) {
      vector[i] = minVal + (bytes[i] * _invScale);
    }
    return vector;
  }

  /// High-speed asymmetric squared Euclidean distance between raw float query and quantized vector.
  double asymmetricSquaredDistance(Float32List query, Uint8List quantized) {
    var sum = 0.0;
    for (var i = 0; i < dimension; i++) {
      final recon = minVal + (quantized[i] * _invScale);
      final diff = query[i] - recon;
      sum += diff * diff;
    }
    return sum;
  }
}
