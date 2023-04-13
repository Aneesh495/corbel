import 'dart:math' as math;
import 'dart:typed_data';
import 'package:corbel/src/core/schema.dart';
import 'package:corbel/src/vector/hnsw_graph.dart';
import 'package:test/test.dart';

/// Bug 3: In HNSW insertion, when a node's random level exceeded current maxLayer,
/// higher layers [maxLayer + 1 .. level] were not initialized with empty neighbor lists
/// before becoming the new entry point, resulting in null pointer dereference on subsequent searches.
/// Resolution: Initialize _layers[l][docId] = [] for all layers 0 .. level unconditionally.
void main() {
  group('Bug Regression: HNSW Higher Layer Initialization on Promotion', () {
    test('nodes promoted above current maxLayer properly initialize all layer adjacency maps', () {
      final graph = HnswGraph(dimension: 4, metric: VectorDistanceMetric.l2);
      final rng = math.Random(42);

      // Insert 200 random vectors to guarantee multiple layer promotions
      for (var i = 0; i < 200; i++) {
        final v = Float32List.fromList([
          rng.nextDouble(),
          rng.nextDouble(),
          rng.nextDouble(),
          rng.nextDouble(),
        ]);
        expect(() => graph.insert(i, v), returnsNormally, reason: 'Failed inserting node $i');
      }

      expect(graph.maxLayer, greaterThan(0));
      expect(graph.size, equals(200));

      // Query should succeed without null error
      final query = Float32List.fromList([0.5, 0.5, 0.5, 0.5]);
      final hits = graph.search(query, 10);
      expect(hits.length, equals(10));
    });
  });
}
