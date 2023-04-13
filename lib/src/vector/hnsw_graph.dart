import 'dart:math' as math;
import 'dart:typed_data';
import '../core/schema.dart';
import '../storage/index_input.dart';
import '../storage/index_output.dart';
import '../utils/priority_queue.dart';
import 'distance.dart';

/// Single neighbor distance pair for priority queue sorting.
class NeighborPair implements Comparable<NeighborPair> {
  final int docId;
  final double distance;

  const NeighborPair(this.docId, this.distance);

  @override
  int compareTo(NeighborPair other) => distance.compareTo(other.distance);

  @override
  String toString() => 'Neighbor($docId, dist: ${distance.toStringAsFixed(4)})';
}

/// Hierarchical Navigable Small World (HNSW) multi-layer graph vector index.
/// Reference: Yu. A. Malkov, D. A. Yashunin, "Efficient and robust approximate nearest neighbor
/// search using Hierarchical Navigable Small World graphs", TPAMI 2018.
class HnswGraph {
  final int dimension;
  final VectorDistanceMetric metric;
  final int m;
  final int m0;
  final int efConstruction;
  final double ml;

  final math.Random _rng = math.Random(42);

  // docId -> Float32List vector
  final Map<int, Float32List> _vectors = {};

  // layer -> docId -> List of neighbor docIds
  final List<Map<int, List<int>>> _layers = [];

  int? _entryPoint;
  int _maxLayer = -1;

  HnswGraph({
    required this.dimension,
    this.metric = VectorDistanceMetric.cosine,
    this.m = 16,
    int? m0,
    this.efConstruction = 100,
  })  : m0 = m0 ?? (2 * 16),
        ml = 1.0 / math.log(16);

  /// Number of indexed vectors.
  int get size => _vectors.length;

  /// Maximum layer currently populated in the graph.
  int get maxLayer => _maxLayer;

  /// Inserts a vector with document ID [docId] into the HNSW graph.
  void insert(int docId, Float32List vector) {
    if (vector.length != dimension) {
      throw ArgumentError('Dimension mismatch: expected $dimension, got ${vector.length}');
    }

    _vectors[docId] = vector;

    // Determine random maximum level for this node
    final level = _randomLevel();

    // Ensure layers list has enough capacity
    final targetMax = math.max(level, _maxLayer);
    while (_layers.length <= targetMax) {
      _layers.add({});
    }
    for (var l = 0; l <= level; l++) {
      _layers[l][docId] = [];
    }

    if (_entryPoint == null) {
      _entryPoint = docId;
      _maxLayer = level;
      return;
    }

    var currObj = _entryPoint!;
    var currDist = VectorDistance.compute(metric, vector, _vectors[currObj]!);

    // Phase 1: Top-down greedy search from _maxLayer down to level + 1
    for (var l = _maxLayer; l > level; l--) {
      var changed = true;
      while (changed) {
        changed = false;
        final neighbors = _layers[l][currObj] ?? const [];
        for (final nId in neighbors) {
          final d = VectorDistance.compute(metric, vector, _vectors[nId]!);
          if (d < currDist) {
            currDist = d;
            currObj = nId;
            changed = true;
          }
        }
      }
    }

    // Phase 2: From min(level, _maxLayer) down to layer 0, perform beam search and connect edges
    var epCandidates = [NeighborPair(currObj, currDist)];
    for (var l = math.min(level, _maxLayer); l >= 0; l--) {
      final candidates = _searchLayer(vector, epCandidates, efConstruction, l);
      final maxConnections = (l == 0) ? m0 : m;
      final selectedNeighbors = _selectNeighborsHeuristic(vector, candidates, maxConnections);

      _layers[l][docId] = [];
      for (final nId in selectedNeighbors) {
        _layers[l][docId]!.add(nId);
        _layers[l][nId]!.add(docId);

        // Shrink neighbor list if exceeding maximum allowed degree
        if (_layers[l][nId]!.length > maxConnections) {
          _shrinkConnections(nId, l, maxConnections);
        }
      }

      epCandidates = candidates;
    }

    // Update global entry point if new node has higher level
    if (level > _maxLayer) {
      _maxLayer = level;
      _entryPoint = docId;
    }
  }

  /// Searches for [k] approximate nearest neighbors to [query].
  /// Supports optional [filter] for pre-filtering candidate document IDs.
  List<NeighborPair> search(
    Float32List query,
    int k, {
    int efSearch = 50,
    bool Function(int docId)? filter,
  }) {
    if (_entryPoint == null) return [];

    var currObj = _entryPoint!;
    var currDist = VectorDistance.compute(metric, query, _vectors[currObj]!);

    // Greedily zoom down to layer 0
    for (var l = _maxLayer; l > 0; l--) {
      var changed = true;
      while (changed) {
        changed = false;
        final neighbors = _layers[l][currObj] ?? const [];
        for (final nId in neighbors) {
          final d = VectorDistance.compute(metric, query, _vectors[nId]!);
          if (d < currDist) {
            currDist = d;
            currObj = nId;
            changed = true;
          }
        }
      }
    }

    // Layer 0 beam search with capacity max(k, efSearch)
    final ef = math.max(k, efSearch);
    final candidates = _searchLayer(
      query,
      [NeighborPair(currObj, currDist)],
      ef,
      0,
      filter: filter,
    );

    // Sort ascending by distance and return top k
    candidates.sort((a, b) => a.distance.compareTo(b.distance));
    return candidates.take(k).toList();
  }

  List<NeighborPair> _searchLayer(
    Float32List query,
    List<NeighborPair> entryPoints,
    int ef,
    int layer, {
    bool Function(int docId)? filter,
  }) {
    final v = <int>{};
    final candidatePQ = PriorityQueue<NeighborPair>((a, b) => a.distance.compareTo(b.distance));
    final resultPQ = PriorityQueue<NeighborPair>((a, b) => b.distance.compareTo(a.distance)); // max-heap

    for (final ep in entryPoints) {
      v.add(ep.docId);
      candidatePQ.add(ep);
      if (filter == null || filter(ep.docId)) {
        resultPQ.add(ep);
      }
    }

    while (candidatePQ.isNotEmpty) {
      final curr = candidatePQ.pop();
      final furthestDist = resultPQ.isNotEmpty ? resultPQ.top.distance : double.infinity;

      if (curr.distance > furthestDist && resultPQ.length >= ef) {
        break;
      }

      final neighbors = _layers[layer][curr.docId] ?? const [];
      for (final nId in neighbors) {
        if (!v.contains(nId)) {
          v.add(nId);
          final d = VectorDistance.compute(metric, query, _vectors[nId]!);

          if (d < furthestDist || resultPQ.length < ef) {
            final candidate = NeighborPair(nId, d);
            candidatePQ.add(candidate);

            if (filter == null || filter(nId)) {
              resultPQ.add(candidate);
              if (resultPQ.length > ef) {
                resultPQ.pop();
              }
            }
          }
        }
      }
    }

    return resultPQ.toSortedList();
  }

  List<int> _selectNeighborsHeuristic(
    Float32List query,
    List<NeighborPair> candidates,
    int maxM,
  ) {
    if (candidates.length <= maxM) {
      return candidates.map((c) => c.docId).toList();
    }

    // Sort ascending by distance
    final sorted = List<NeighborPair>.from(candidates)
      ..sort((a, b) => a.distance.compareTo(b.distance));

    final result = <int>[];
    for (final c in sorted) {
      if (result.length >= maxM) break;

      var keep = true;
      final cVec = _vectors[c.docId]!;
      for (final rId in result) {
        final distToExisting = VectorDistance.compute(metric, cVec, _vectors[rId]!);
        if (distToExisting < c.distance) {
          keep = false;
          break;
        }
      }

      if (keep) {
        result.add(c.docId);
      }
    }

    // Fall back to closest neighbors if diversity filter pruned too aggressively
    if (result.length < maxM) {
      for (final c in sorted) {
        if (result.length >= maxM) break;
        if (!result.contains(c.docId)) {
          result.add(c.docId);
        }
      }
    }

    return result;
  }

  void _shrinkConnections(int node, int layer, int maxM) {
    final neighbors = _layers[layer][node]!;
    if (neighbors.length <= maxM) return;

    final nodeVec = _vectors[node]!;
    final pairs = neighbors
        .map((nId) => NeighborPair(nId, VectorDistance.compute(metric, nodeVec, _vectors[nId]!)))
        .toList();

    final selected = _selectNeighborsHeuristic(nodeVec, pairs, maxM);
    _layers[layer][node] = selected;
  }

  int _randomLevel() {
    var r = _rng.nextDouble();
    if (r == 0.0) r = 0.0000001;
    return (-math.log(r) * ml).floor();
  }

  /// Serializes HNSW graph to binary stream.
  void serialize(IndexOutput out) {
    out.writeVInt(dimension);
    out.writeByte(metric.index);
    out.writeVInt(m);
    out.writeVInt(m0);
    out.writeVInt(efConstruction);

    out.writeVInt(_vectors.length);
    for (final entry in _vectors.entries) {
      out.writeVInt(entry.key);
      for (var i = 0; i < dimension; i++) {
        out.writeFloat32(entry.value[i]);
      }
    }

    out.writeVInt(_maxLayer);
    out.writeZInt(_entryPoint ?? -1);

    out.writeVInt(_layers.length);
    for (var l = 0; l < _layers.length; l++) {
      final layerMap = _layers[l];
      out.writeVInt(layerMap.length);
      for (final entry in layerMap.entries) {
        out.writeVInt(entry.key);
        out.writeVInt(entry.value.length);
        for (final neighbor in entry.value) {
          out.writeVInt(neighbor);
        }
      }
    }
  }

  /// Deserializes HNSW graph from binary stream.
  static HnswGraph deserialize(IndexInput inp) {
    final dim = inp.readVInt();
    final metricIdx = inp.readByte();
    final metric = VectorDistanceMetric.values[metricIdx];
    final m = inp.readVInt();
    final m0 = inp.readVInt();
    final efConstruction = inp.readVInt();

    final graph = HnswGraph(
      dimension: dim,
      metric: metric,
      m: m,
      m0: m0,
      efConstruction: efConstruction,
    );

    final numVectors = inp.readVInt();
    for (var i = 0; i < numVectors; i++) {
      final docId = inp.readVInt();
      final vec = Float32List(dim);
      for (var d = 0; d < dim; d++) {
        vec[d] = inp.readFloat32();
      }
      graph._vectors[docId] = vec;
    }

    graph._maxLayer = inp.readVInt();
    final ep = inp.readZInt();
    graph._entryPoint = (ep == -1) ? null : ep;

    final numLayers = inp.readVInt();
    for (var l = 0; l < numLayers; l++) {
      final layerMap = <int, List<int>>{};
      final numNodes = inp.readVInt();
      for (var n = 0; n < numNodes; n++) {
        final node = inp.readVInt();
        final numNeighbors = inp.readVInt();
        final neighbors = List<int>.filled(numNeighbors, 0);
        for (var k = 0; k < numNeighbors; k++) {
          neighbors[k] = inp.readVInt();
        }
        layerMap[node] = neighbors;
      }
      graph._layers.add(layerMap);
    }

    return graph;
  }
}
