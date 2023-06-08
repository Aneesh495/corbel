import 'dart:math' as math;
import 'dart:typed_data';
import 'package:corbel/src/vector/distance.dart';
import 'package:corbel/src/vector/hnsw_graph.dart';

void main() {
  print('========================================================');
  print('          CORBEL VECTOR MICRO-BENCHMARK SUITE           ');
  print('========================================================');

  const dim = 128;
  const numVectors = 1000;
  final random = math.Random(42);

  print('Generating $numVectors random $dim-dimensional vectors...');
  final vectors = List.generate(numVectors, (_) {
    final v = Float32List(dim);
    for (var i = 0; i < dim; i++) {
      v[i] = random.nextDouble() * 2.0 - 1.0;
    }
    return v;
  });

  // Benchmark dot product distance kernel
  const numPairwise = 500000;
  print('Benchmarking $numPairwise pairwise dot-product distance calculations...');
  final swDistance = Stopwatch()..start();

  var dummy = 0.0;
  for (var i = 0; i < numPairwise; i++) {
    final v1 = vectors[i % numVectors];
    final v2 = vectors[(i + 1) % numVectors];
    dummy += VectorDistance.dotProduct(v1, v2);
  }
  swDistance.stop();

  final elapsedDistanceMs = swDistance.elapsedMilliseconds;
  final distanceMops = (numPairwise / (elapsedDistanceMs / 1000.0) / 1000000.0).toStringAsFixed(2);
  print('Calculated $numPairwise distances in ${elapsedDistanceMs}ms ($distanceMops MOps/sec, checksum=$dummy)');

  // Benchmark HNSW index building
  print('Building HNSW graph index (M=16, efConstruction=64)...');
  final graph = HnswGraph(
    dimension: dim,
    m: 16,
    efConstruction: 64,
  );

  final swIndex = Stopwatch()..start();
  for (var i = 0; i < numVectors; i++) {
    graph.insert(i, vectors[i]);
  }
  swIndex.stop();

  final elapsedIndexMs = swIndex.elapsedMilliseconds;
  print('Indexed $numVectors vectors in ${elapsedIndexMs}ms');

  // Benchmark HNSW search queries
  const numSearches = 1000;
  print('Benchmarking $numSearches approximate nearest neighbor queries (k=10)...');
  final swSearch = Stopwatch()..start();

  for (var i = 0; i < numSearches; i++) {
    final query = vectors[i % numVectors];
    final neighbors = graph.search(query, 10, efSearch: 32);
    assert(neighbors.isNotEmpty);
  }
  swSearch.stop();

  final elapsedSearchMs = swSearch.elapsedMilliseconds;
  final qps = (numSearches / (elapsedSearchMs / 1000.0)).toStringAsFixed(1);
  print('Executed $numSearches vector searches in ${elapsedSearchMs}ms ($qps QPS)');
}
