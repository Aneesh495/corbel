import 'dart:math' as math;
import 'dart:typed_data';
import 'package:corbel/corbel.dart';
import 'package:test/test.dart';

void main() {
  group('K-Means Vector Clustering Tests', () {
    test('K-Means partitions clustered vectors and predicts assignments', () {
      final random = math.Random(42);
      final vectors = <Float32List>[];

      // Cluster 0 centered around (10, 10)
      for (var i = 0; i < 50; i++) {
        final v = Float32List(2);
        v[0] = 10.0 + (random.nextDouble() - 0.5) * 2.0;
        v[1] = 10.0 + (random.nextDouble() - 0.5) * 2.0;
        vectors.add(v);
      }

      // Cluster 1 centered around (-10, -10)
      for (var i = 0; i < 50; i++) {
        final v = Float32List(2);
        v[0] = -10.0 + (random.nextDouble() - 0.5) * 2.0;
        v[1] = -10.0 + (random.nextDouble() - 0.5) * 2.0;
        vectors.add(v);
      }

      final kmeans = KMeans(k: 2, maxIterations: 20);
      final centroids = kmeans.fit(vectors);

      expect(centroids.length, equals(2));

      // One centroid should be near (10, 10) and one near (-10, -10)
      final hasPositive = centroids.any((c) => c[0] > 5.0 && c[1] > 5.0);
      final hasNegative = centroids.any((c) => c[0] < -5.0 && c[1] < -5.0);
      expect(hasPositive, isTrue);
      expect(hasNegative, isTrue);

      // Prediction test
      final testPos = Float32List.fromList([9.5, 10.2]);
      final predPos = kmeans.predict(testPos, centroids);
      expect(centroids[predPos][0], greaterThan(0.0));

      final testNeg = Float32List.fromList([-9.8, -10.1]);
      final predNeg = kmeans.predict(testNeg, centroids);
      expect(centroids[predNeg][0], lessThan(0.0));
    });
  });

  group('Product Quantization (PQ) Tests', () {
    test('encodes, decodes, and computes asymmetric distance lookup tables', () {
      const dim = 16;
      const numSub = 4;
      const subDim = 4;
      final random = math.Random(123);

      final trainingVectors = <Float32List>[];
      for (var i = 0; i < 100; i++) {
        final v = Float32List(dim);
        for (var d = 0; d < dim; d++) {
          v[d] = random.nextDouble() * 10.0;
        }
        trainingVectors.add(v);
      }

      final pq = ProductQuantizer(
        dimension: dim,
        numSubVectors: numSub,
        numCentroids: 16, // 16 centroids per codebook
      );
      pq.fit(trainingVectors);

      expect(pq.codebooks.length, equals(numSub));
      for (final book in pq.codebooks) {
        expect(book.length, equals(16));
        expect(book.first.length, equals(subDim));
      }

      // Encode and decode test
      final target = trainingVectors.first;
      final code = pq.encode(target);
      expect(code.length, equals(numSub));

      final decoded = pq.decode(code);
      expect(decoded.length, equals(dim));

      // Reconstructed vector should be close to original
      var diffSq = 0.0;
      for (var d = 0; d < dim; d++) {
        final diff = target[d] - decoded[d];
        diffSq += diff * diff;
      }
      expect(math.sqrt(diffSq), lessThan(10.0));

      // Distance lookup table test
      final query = Float32List(dim);
      for (var d = 0; d < dim; d++) {
        query[d] = 5.0;
      }

      final distTable = pq.computeDistanceTable(query);
      expect(distTable.length, equals(numSub * 16));

      // ADC distance check
      var adcDist = 0.0;
      for (var m = 0; m < numSub; m++) {
        adcDist += distTable[m * 16 + code[m]];
      }
      expect(adcDist, greaterThanOrEqualTo(0.0));
    });

    test('ProductQuantizer serialization and deserialization round-trip', () {
      final dir = RAMDirectory();
      const dim = 8;
      const numSub = 2;
      final random = math.Random(77);

      final vectors = List.generate(
        40,
        (_) => Float32List.fromList(
          List.generate(dim, (_) => random.nextDouble()),
        ),
      );

      final pq = ProductQuantizer(
        dimension: dim,
        numSubVectors: numSub,
        numCentroids: 4,
      );
      pq.fit(vectors);

      final out = dir.createOutput('test_pq.bin');
      pq.writeTo(out);
      out.close();

      final input = dir.openInput('test_pq.bin');
      final loadedPq = ProductQuantizer.readFrom(input);
      input.close();

      expect(loadedPq.dimension, equals(dim));
      expect(loadedPq.numSubVectors, equals(numSub));
      expect(loadedPq.codebooks.length, equals(numSub));
    });
  });

  group('IVF-PQ Index Search Tests', () {
    test('indexes vectors and searches with high recall using ADC', () {
      const dim = 16;
      const nList = 4;
      const numSub = 4;
      final random = math.Random(999);

      final vectors = <Float32List>[];
      for (var i = 0; i < 120; i++) {
        final v = Float32List(dim);
        for (var d = 0; d < dim; d++) {
          v[d] = (random.nextDouble() - 0.5) * 5.0;
        }
        vectors.add(v);
      }

      final ivfPq = IvfPqIndex(
        dimension: dim,
        nList: nList,
        numSubVectors: numSub,
        nProbe: 4, // Probe all coarse clusters for high recall
      );

      // Train index on vector dataset
      ivfPq.train(vectors);
      expect(ivfPq.isTrained, isTrue);

      // Add vectors
      for (var i = 0; i < vectors.length; i++) {
        ivfPq.add(i, vectors[i]);
      }
      expect(ivfPq.totalDocs, equals(120));

      // Query with vector 0: doc 0 should be top result or in top 3
      final query = vectors[0];
      final results = ivfPq.search(query, 5);

      expect(results, isNotEmpty);
      final topDocIds = results.map((e) => e.key).toList();
      expect(topDocIds, contains(0));
      expect(results.first.value, closeTo(0.0, 1.5)); // Low distance to self
    });

    test('IVF-PQ serialization and deserialization round-trip', () {
      final dir = RAMDirectory();
      const dim = 8;
      const nList = 2;
      const numSub = 2;
      final random = math.Random(1234);

      final vectors = List.generate(
        30,
        (_) => Float32List.fromList(
          List.generate(dim, (_) => random.nextDouble()),
        ),
      );

      final originalIndex = IvfPqIndex(
        dimension: dim,
        nList: nList,
        numSubVectors: numSub,
        nProbe: 2,
      );
      originalIndex.train(vectors);
      for (var i = 0; i < vectors.length; i++) {
        originalIndex.add(i, vectors[i]);
      }

      final out = dir.createOutput('test_ivf_pq.cbl_ivf');
      originalIndex.writeTo(out);
      out.close();

      final input = dir.openInput('test_ivf_pq.cbl_ivf');
      final loadedIndex = IvfPqIndex.readFrom(input);
      input.close();

      expect(loadedIndex.dimension, equals(dim));
      expect(loadedIndex.totalDocs, equals(30));
      expect(loadedIndex.isTrained, isTrue);

      final query = vectors.first;
      final origResults = originalIndex.search(query, 3);
      final loadedResults = loadedIndex.search(query, 3);

      expect(
        loadedResults.map((e) => e.key).toList(),
        equals(origResults.map((e) => e.key).toList()),
      );
    });
  });
}
