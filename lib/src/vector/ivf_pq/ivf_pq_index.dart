import 'dart:math' as math;
import 'dart:typed_data';
import '../../storage/index_input.dart';
import '../../storage/index_output.dart';
import '../../utils/priority_queue.dart';
import 'kmeans.dart';
import 'product_quantizer.dart';

/// Single posting in an inverted cluster list storing document ID and quantized residual byte code.
class IvfPosting {
  final int docId;
  final Uint8List code;

  const IvfPosting(this.docId, this.code);
}

class _ScoredDoc implements Comparable<_ScoredDoc> {
  final int docId;
  final double distance;
  _ScoredDoc(this.docId, this.distance);

  @override
  int compareTo(_ScoredDoc other) => distance.compareTo(other.distance);
}

/// Inverted File with Product Quantization (IVF-PQ) vector index.
/// Provides up to 64x memory compression and millisecond scan speeds using
/// two-level hierarchical vector quantization and Asymmetric Distance Computation (ADC).
class IvfPqIndex {
  final int dimension;
  final int nList;
  final int numSubVectors;
  final int nProbe;

  late ProductQuantizer pq;
  final List<Float32List> coarseCentroids = [];
  final List<List<IvfPosting>> invertedLists = [];
  int _totalDocs = 0;
  bool _isTrained = false;

  IvfPqIndex({
    required this.dimension,
    this.nList = 64,
    this.numSubVectors = 8,
    this.nProbe = 8,
    ProductQuantizer? productQuantizer,
  }) {
    pq = productQuantizer ??
        ProductQuantizer(
          dimension: dimension,
          numSubVectors: numSubVectors,
        );
    for (var i = 0; i < nList; i++) {
      invertedLists.add([]);
    }
  }

  int get totalDocs => _totalDocs;
  bool get isTrained => _isTrained;

  /// Trains coarse cluster centroids and fine residual product quantizer codebooks.
  void train(List<Float32List> vectors) {
    if (vectors.isEmpty) return;

    // 1. Train coarse centroids with K-Means
    final coarseKmeans = KMeans(k: nList, maxIterations: 30);
    final trainedCoarse = coarseKmeans.fit(vectors);
    coarseCentroids.clear();
    coarseCentroids.addAll(trainedCoarse);

    // 2. Compute residual vectors r = x - C_i
    final residuals = <Float32List>[];
    for (final v in vectors) {
      final cIdx = coarseKmeans.predict(v, coarseCentroids);
      final centroid = coarseCentroids[cIdx];
      final r = Float32List(dimension);
      for (var d = 0; d < dimension; d++) {
        r[d] = v[d] - centroid[d];
      }
      residuals.add(r);
    }

    // 3. Train fine product quantizer on residuals
    pq.fit(residuals);
    _isTrained = true;
  }

  /// Adds a document vector to the inverted lists.
  void add(int docId, Float32List vector) {
    if (!_isTrained) {
      throw StateError('IvfPqIndex must be trained before adding vectors');
    }

    // 1. Assign to nearest coarse centroid
    var bestCluster = 0;
    var bestDist = double.infinity;

    for (var i = 0; i < coarseCentroids.length; i++) {
      final c = coarseCentroids[i];
      var dist = 0.0;
      for (var d = 0; d < dimension; d++) {
        final diff = vector[d] - c[d];
        dist += diff * diff;
      }
      if (dist < bestDist) {
        bestDist = dist;
        bestCluster = i;
      }
    }

    // 2. Compute residual r = x - C_i
    final centroid = coarseCentroids[bestCluster];
    final residual = Float32List(dimension);
    for (var d = 0; d < dimension; d++) {
      residual[d] = vector[d] - centroid[d];
    }

    // 3. Quantize residual with PQ
    final code = pq.encode(residual);

    invertedLists[bestCluster].add(IvfPosting(docId, code));
    _totalDocs++;
  }

  /// Searches for the top-k nearest neighbors using Asymmetric Distance Computation (ADC).
  List<MapEntry<int, double>> search(
    Float32List query,
    int topK, {
    int? probeOverride,
  }) {
    if (!_isTrained || _totalDocs == 0) return const [];

    final actualProbe = math.min(
      probeOverride ?? nProbe,
      coarseCentroids.length,
    );

    // 1. Find nProbe nearest coarse centroids to query
    final coarseDists = <MapEntry<int, double>>[];
    for (var i = 0; i < coarseCentroids.length; i++) {
      final c = coarseCentroids[i];
      var dist = 0.0;
      for (var d = 0; d < dimension; d++) {
        final diff = query[d] - c[d];
        dist += diff * diff;
      }
      coarseDists.add(MapEntry(i, dist));
    }
    coarseDists.sort((a, b) => a.value.compareTo(b.value));
    final probedClusters = coarseDists.take(actualProbe).map((e) => e.key);

    // 2. Scan inverted lists of probed clusters via precomputed ADC distance tables
    final pqHeap = BoundedPriorityQueue<_ScoredDoc>(
      topK,
      (a, b) => b.distance.compareTo(a.distance),
    );

    final numSub = pq.numSubVectors;
    final numCent = pq.numCentroids;

    for (final clusterIdx in probedClusters) {
      final centroid = coarseCentroids[clusterIdx];
      final postings = invertedLists[clusterIdx];
      if (postings.isEmpty) continue;

      // Residual query: q_r = query - centroid
      final residualQuery = Float32List(dimension);
      for (var d = 0; d < dimension; d++) {
        residualQuery[d] = query[d] - centroid[d];
      }

      // Precompute M x 256 distance lookup table
      final distanceTable = pq.computeDistanceTable(residualQuery);

      for (final posting in postings) {
        final code = posting.code;
        var dist = 0.0;

        // Ultra-fast ADC inner loop: array lookups and additions only!
        for (var m = 0; m < numSub; m++) {
          final cIdx = code[m];
          dist += distanceTable[m * numCent + cIdx];
        }

        pqHeap.insertWithOverflow(_ScoredDoc(posting.docId, dist));
      }
    }

    final topResults = pqHeap.drainToListDescending();
    return topResults
        .map((s) => MapEntry(s.docId, math.sqrt(s.distance)))
        .toList();
  }

  /// Serializes the IVF-PQ index to [output].
  void writeTo(IndexOutput output) {
    output.writeVInt(dimension);
    output.writeVInt(nList);
    output.writeVInt(numSubVectors);
    output.writeVInt(nProbe);
    output.writeVInt(_totalDocs);
    output.writeByte(_isTrained ? 1 : 0);

    // Write coarse centroids
    output.writeVInt(coarseCentroids.length);
    for (final c in coarseCentroids) {
      for (var d = 0; d < dimension; d++) {
        output.writeFloat32(c[d]);
      }
    }

    // Write fine PQ codebooks
    pq.writeTo(output);

    // Write inverted lists
    output.writeVInt(invertedLists.length);
    for (var i = 0; i < invertedLists.length; i++) {
      final list = invertedLists[i];
      output.writeVInt(list.length);
      for (final p in list) {
        output.writeVInt(p.docId);
        output.writeBytes(p.code);
      }
    }
  }

  /// Deserializes an IVF-PQ index from [input].
  static IvfPqIndex readFrom(IndexInput input) {
    final dim = input.readVInt();
    final nList = input.readVInt();
    final numSub = input.readVInt();
    final nProbe = input.readVInt();
    final totalDocs = input.readVInt();
    final isTrained = input.readByte() == 1;

    final index = IvfPqIndex(
      dimension: dim,
      nList: nList,
      numSubVectors: numSub,
      nProbe: nProbe,
    );
    index._totalDocs = totalDocs;
    index._isTrained = isTrained;

    // Read coarse centroids
    final coarseCount = input.readVInt();
    for (var i = 0; i < coarseCount; i++) {
      final c = Float32List(dim);
      for (var d = 0; d < dim; d++) {
        c[d] = input.readFloat32();
      }
      index.coarseCentroids.add(c);
    }

    // Read fine PQ codebooks
    index.pq = ProductQuantizer.readFrom(input);

    // Read inverted lists
    final listCount = input.readVInt();
    index.invertedLists.clear();
    for (var i = 0; i < listCount; i++) {
      final postingCount = input.readVInt();
      final postings = <IvfPosting>[];
      for (var j = 0; j < postingCount; j++) {
        final docId = input.readVInt();
        final code = input.readBytes(numSub);
        postings.add(IvfPosting(docId, code));
      }
      index.invertedLists.add(postings);
    }

    return index;
  }
}
