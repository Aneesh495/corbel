import 'dart:typed_data';
import '../../storage/index_input.dart';
import '../../storage/index_output.dart';
import 'kmeans.dart';

/// Product Quantizer (PQ) decomposing high-dimensional vector spaces into
/// Cartesian products of low-dimensional quantized subspaces.
class ProductQuantizer {
  final int dimension;
  final int numSubVectors;
  final int numCentroids;

  late final int subVectorDim;

  // codebooks[m][c] = Float32List of subVectorDim
  final List<List<Float32List>> codebooks = [];

  ProductQuantizer({
    required this.dimension,
    required this.numSubVectors,
    this.numCentroids = 256,
  }) : assert(dimension % numSubVectors == 0,
            'Dimension ($dimension) must be divisible by numSubVectors ($numSubVectors)') {
    subVectorDim = dimension ~/ numSubVectors;
  }

  /// Trains codebooks across all sub-vector dimensions.
  void fit(List<Float32List> vectors) {
    codebooks.clear();

    for (var m = 0; m < numSubVectors; m++) {
      final subVectors = <Float32List>[];
      final offset = m * subVectorDim;

      for (final v in vectors) {
        final sub = Float32List(subVectorDim);
        for (var d = 0; d < subVectorDim; d++) {
          sub[d] = v[offset + d];
        }
        subVectors.add(sub);
      }

      final kmeans = KMeans(k: numCentroids, maxIterations: 20);
      final centroids = kmeans.fit(subVectors);
      codebooks.add(centroids);
    }
  }

  /// Encodes a high-dimensional vector into an M-byte compact code.
  Uint8List encode(Float32List vector) {
    final code = Uint8List(numSubVectors);

    for (var m = 0; m < numSubVectors; m++) {
      final offset = m * subVectorDim;
      var bestIdx = 0;
      var bestDist = double.infinity;

      final book = codebooks[m];
      for (var c = 0; c < book.length; c++) {
        final centroid = book[c];
        var dist = 0.0;
        for (var d = 0; d < subVectorDim; d++) {
          final diff = vector[offset + d] - centroid[d];
          dist += diff * diff;
        }

        if (dist < bestDist) {
          bestDist = dist;
          bestIdx = c;
        }
      }

      code[m] = bestIdx & 0xFF;
    }

    return code;
  }

  /// Reconstructs an approximate vector from its quantized code.
  Float32List decode(Uint8List code) {
    final reconstructed = Float32List(dimension);

    for (var m = 0; m < numSubVectors; m++) {
      final offset = m * subVectorDim;
      final cIdx = code[m];
      final centroid = codebooks[m][cIdx];

      for (var d = 0; d < subVectorDim; d++) {
        reconstructed[offset + d] = centroid[d];
      }
    }

    return reconstructed;
  }

  /// Precomputes an M x numCentroids squared Euclidean distance table for Asymmetric Distance Computation (ADC).
  Float32List computeDistanceTable(Float32List query) {
    final table = Float32List(numSubVectors * numCentroids);

    for (var m = 0; m < numSubVectors; m++) {
      final offset = m * subVectorDim;
      final book = codebooks[m];
      final tableOffset = m * numCentroids;

      for (var c = 0; c < book.length; c++) {
        final centroid = book[c];
        var dist = 0.0;
        for (var d = 0; d < subVectorDim; d++) {
          final diff = query[offset + d] - centroid[d];
          dist += diff * diff;
        }
        table[tableOffset + c] = dist;
      }
    }

    return table;
  }

  /// Serializes the trained codebooks to [output].
  void writeTo(IndexOutput output) {
    output.writeVInt(dimension);
    output.writeVInt(numSubVectors);
    output.writeVInt(numCentroids);

    for (var m = 0; m < numSubVectors; m++) {
      final book = codebooks[m];
      output.writeVInt(book.length);
      for (final centroid in book) {
        for (var d = 0; d < subVectorDim; d++) {
          output.writeFloat32(centroid[d]);
        }
      }
    }
  }

  /// Deserializes trained codebooks from [input].
  static ProductQuantizer readFrom(IndexInput input) {
    final dim = input.readVInt();
    final numSub = input.readVInt();
    final numCent = input.readVInt();

    final pq = ProductQuantizer(
      dimension: dim,
      numSubVectors: numSub,
      numCentroids: numCent,
    );

    for (var m = 0; m < numSub; m++) {
      final count = input.readVInt();
      final book = <Float32List>[];
      for (var c = 0; c < count; c++) {
        final centroid = Float32List(pq.subVectorDim);
        for (var d = 0; d < pq.subVectorDim; d++) {
          centroid[d] = input.readFloat32();
        }
        book.add(centroid);
      }
      pq.codebooks.add(book);
    }

    return pq;
  }
}
