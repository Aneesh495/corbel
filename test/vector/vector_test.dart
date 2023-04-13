import 'dart:math' as math;
import 'dart:typed_data';
import 'package:corbel/src/core/schema.dart';
import 'package:corbel/src/storage/directory.dart';
import 'package:corbel/src/vector/distance.dart';
import 'package:corbel/src/vector/hnsw_graph.dart';
import 'package:corbel/src/vector/quantization.dart';
import 'package:corbel/src/vector/vector_index.dart';
import 'package:test/test.dart';

void main() {
  group('Vector Distance Metric Tests', () {
    test('Euclidean and squared Euclidean distances', () {
      final a = Float32List.fromList([1.0, 2.0, 3.0]);
      final b = Float32List.fromList([4.0, 6.0, 8.0]);

      // diffs: 3, 4, 5 -> 9 + 16 + 25 = 50
      expect(VectorDistance.squaredEuclidean(a, b), closeTo(50.0, 0.001));
      expect(VectorDistance.euclidean(a, b), closeTo(math.sqrt(50.0), 0.001));
    });

    test('Dot product and Cosine similarity', () {
      final a = Float32List.fromList([1.0, 0.0, 0.0]);
      final b = Float32List.fromList([0.0, 1.0, 0.0]);
      final c = Float32List.fromList([2.0, 0.0, 0.0]);

      // Orthogonal vectors
      expect(VectorDistance.dotProduct(a, b), closeTo(0.0, 0.001));
      expect(VectorDistance.cosineSimilarity(a, b), closeTo(0.0, 0.001));
      expect(VectorDistance.cosineDistance(a, b), closeTo(1.0, 0.001));

      // Collinear vectors
      expect(VectorDistance.cosineSimilarity(a, c), closeTo(1.0, 0.001));
      expect(VectorDistance.cosineDistance(a, c), closeTo(0.0, 0.001));
    });

    test('Manhattan distance', () {
      final a = Float32List.fromList([1.0, 5.0, 2.0]);
      final b = Float32List.fromList([4.0, 1.0, 6.0]);
      // |1-4| + |5-1| + |2-6| = 3 + 4 + 4 = 11
      expect(VectorDistance.manhattan(a, b), closeTo(11.0, 0.001));
    });
  });

  group('Scalar Quantization (SQ8) Tests', () {
    test('quantize and dequantize preserves relative distances', () {
      final rng = math.Random(123);
      final corpus = List<Float32List>.generate(50, (_) {
        final vec = Float32List(8);
        for (var i = 0; i < 8; i++) {
          vec[i] = rng.nextDouble() * 10.0 - 5.0; // [-5.0, 5.0]
        }
        return vec;
      });

      final sq = ScalarQuantizer.train(corpus);
      expect(sq.dimension, equals(8));

      final testVec = corpus[0];
      final quantized = sq.quantize(testVec);
      final reconstructed = sq.dequantize(quantized);

      for (var i = 0; i < 8; i++) {
        expect(reconstructed[i], closeTo(testVec[i], 0.1));
      }
    });
  });

  group('HNSW Graph and VectorIndex Tests', () {
    test('HNSW indexing and recall verification against brute-force scan', () {
      const dim = 16;
      const count = 100;
      final rng = math.Random(999);

      final vectors = List<Float32List>.generate(count, (_) {
        final v = Float32List(dim);
        for (var i = 0; i < dim; i++) {
          v[i] = rng.nextDouble() * 2.0 - 1.0;
        }
        VectorDistance.normalizeInPlace(v);
        return v;
      });

      final graph = HnswGraph(
        dimension: dim,
        metric: VectorDistanceMetric.cosine,
        m: 16,
        efConstruction: 64,
      );

      for (var i = 0; i < count; i++) {
        graph.insert(i, vectors[i]);
      }

      expect(graph.size, equals(count));
      expect(graph.maxLayer, greaterThanOrEqualTo(0));

      // Test queries
      const queryCount = 10;
      const k = 5;
      var totalRecallHits = 0;

      for (var q = 0; q < queryCount; q++) {
        final query = Float32List(dim);
        for (var i = 0; i < dim; i++) {
          query[i] = rng.nextDouble() * 2.0 - 1.0;
        }
        VectorDistance.normalizeInPlace(query);

        // Brute-force exact 5-NN
        final bruteForce = List<NeighborPair>.generate(count, (i) {
          final d = VectorDistance.cosineDistance(query, vectors[i]);
          return NeighborPair(i, d);
        })..sort((a, b) => a.distance.compareTo(b.distance));
        final exactTopK = bruteForce.take(k).map((p) => p.docId).toSet();

        // HNSW search
        final hnswHits = graph.search(query, k, efSearch: 50);
        final hnswTopK = hnswHits.map((h) => h.docId).toSet();

        totalRecallHits += exactTopK.intersection(hnswTopK).length;
      }

      final recall = totalRecallHits / (queryCount * k);
      expect(recall, greaterThanOrEqualTo(0.90),
          reason: 'Expected HNSW recall@5 to be >= 90%, got ${(recall * 100).toStringAsFixed(1)}%');
    });

    test('HNSW search respects pre-filtering predicate', () {
      const dim = 4;
      final graph = HnswGraph(dimension: dim, metric: VectorDistanceMetric.l2);

      graph.insert(0, Float32List.fromList([1.0, 0.0, 0.0, 0.0]));
      graph.insert(1, Float32List.fromList([0.9, 0.0, 0.0, 0.0]));
      graph.insert(2, Float32List.fromList([0.8, 0.0, 0.0, 0.0]));

      final query = Float32List.fromList([1.0, 0.0, 0.0, 0.0]);

      // Filter out doc 0 and doc 1
      final hits = graph.search(query, 5, filter: (id) => id >= 2);
      expect(hits.length, equals(1));
      expect(hits.first.docId, equals(2));
    });

    test('VectorIndex serialization and deserialization round-trip', () {
      final vIndex = VectorIndex(
        fieldName: 'embedding',
        dimension: 4,
        metric: VectorDistanceMetric.cosine,
      );

      vIndex.add(10, Float32List.fromList([0.1, 0.2, 0.3, 0.4]));
      vIndex.add(20, Float32List.fromList([0.4, 0.3, 0.2, 0.1]));

      final dir = RAMDirectory();
      final out = dir.createOutput('vectors.hns');
      vIndex.flush(out);
      out.close();

      final inp = dir.openInput('vectors.hns');
      final restored = VectorIndex.load(inp);
      inp.close();

      expect(restored.fieldName, equals('embedding'));
      expect(restored.size, equals(2));
      expect(restored.dimension, equals(4));

      final hits = restored.search(Float32List.fromList([0.1, 0.2, 0.3, 0.4]), 1);
      expect(hits.length, equals(1));
      expect(hits.first.docId, equals(10));
    });
  });
}
