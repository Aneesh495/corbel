import 'dart:typed_data';
import '../../core/schema.dart';
import '../../storage/index_input.dart';
import '../../storage/index_output.dart';
import 'distance.dart';
import 'hnsw_graph.dart';

/// Top-level vector index managing high-dimensional embeddings for an index field.
class VectorIndex {
  final String fieldName;
  final HnswGraph _graph;

  VectorIndex({
    required this.fieldName,
    required int dimension,
    VectorDistanceMetric metric = VectorDistanceMetric.cosine,
    int m = 16,
    int efConstruction = 100,
  }) : _graph = HnswGraph(
          dimension: dimension,
          metric: metric,
          m: m,
          efConstruction: efConstruction,
        );

  VectorIndex._fromGraph(this.fieldName, this._graph);

  /// Number of indexed vectors.
  int get size => _graph.size;

  /// Underlying vector dimension.
  int get dimension => _graph.dimension;

  /// Inserts a vector with document ID [docId].
  void add(int docId, Float32List vector) {
    _graph.insert(docId, vector);
  }

  /// Approximate nearest neighbor search.
  List<NeighborPair> search(
    Float32List query,
    int k, {
    int efSearch = 50,
    bool Function(int docId)? filter,
  }) {
    return _graph.search(query, k, efSearch: efSearch, filter: filter);
  }

  /// Serializes vector index to segment output stream.
  void flush(IndexOutput out) {
    out.writeString(fieldName);
    _graph.serialize(out);
  }

  /// Deserializes vector index from segment input stream.
  static VectorIndex load(IndexInput inp) {
    final fieldName = inp.readString();
    final graph = HnswGraph.deserialize(inp);
    return VectorIndex._fromGraph(fieldName, graph);
  }
}
