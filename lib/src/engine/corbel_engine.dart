import '../aggregation/terms_aggregation.dart';
import '../analysis/analyzer.dart';
import '../core/document.dart';
import '../core/schema.dart';
import '../query/highlighter.dart';
import '../query/query.dart';
import '../query/query_parser.dart';
import '../storage/directory.dart';
import 'index_searcher.dart';
import 'index_writer.dart';
import 'index_writer_config.dart';

/// High-level single collection handle orchestrating read-write pipelines.
class CorbelIndex {
  final String name;
  final Schema schema;
  final Directory directory;
  final Analyzer defaultAnalyzer;

  late final IndexWriter _writer;
  IndexSearcher? _currentSearcher;
  late final QueryParser _parser;
  late final Highlighter _highlighter;

  CorbelIndex({
    required this.name,
    required this.schema,
    required this.directory,
    Analyzer? analyzer,
  }) : defaultAnalyzer = analyzer ?? const StandardAnalyzer() {
    _writer = IndexWriter(IndexWriterConfig(
      schema: schema,
      directory: directory,
    ));
    _parser = QueryParser(
      defaultField: schema.fields.keys.firstWhere(
        (k) => k != schema.idFieldName,
        orElse: () => schema.idFieldName,
      ),
      analyzer: defaultAnalyzer,
    );
    _highlighter = Highlighter(analyzer: defaultAnalyzer);
    refresh();
  }

  /// Refreshes the point-in-time searcher snapshot to expose recent commits.
  void refresh() {
    _currentSearcher?.close();
    _currentSearcher = IndexSearcher.fromWriter(_writer);
  }

  /// Indexes a single document represented as a map.
  void index(Map<String, dynamic> data) {
    final id = data[schema.idFieldName]?.toString() ??
        'doc_${DateTime.now().microsecondsSinceEpoch}';
    final doc = Document.fromMap(id, data, schema: schema);
    _writer.updateDocument(id, doc);
  }

  /// Bulk indexes multiple documents efficiently.
  void bulkIndex(List<Map<String, dynamic>> docs) {
    for (final data in docs) {
      index(data);
    }
  }

  /// Soft-deletes a document by ID.
  void delete(String id) {
    _writer.deleteDocument(id);
  }

  /// Flushes in-memory buffer to immutable segments.
  void flush() {
    _writer.flush();
    refresh();
  }

  /// Commits pending segments, manifests, and checkpoints WAL.
  void commit() {
    _writer.commit();
    refresh();
  }

  /// Executes Lucene-style search query string.
  TopDocs search(
    String queryString, {
    int topN = 10,
    List<Aggregation> aggregations = const [],
  }) {
    final query = _parser.parse(queryString);
    return searchQuery(query, topN: topN, aggregations: aggregations);
  }

  /// Executes an AST Query object directly.
  TopDocs searchQuery(
    Query query, {
    int topN = 10,
    List<Aggregation> aggregations = const [],
  }) {
    if (_currentSearcher == null) refresh();
    return _currentSearcher!.searchWithAggregations(query, topN, aggregations);
  }

  /// Retrieves a document by search hit.
  Document doc(ScoreDoc hit) {
    if (_currentSearcher == null) refresh();
    return _currentSearcher!.doc(hit);
  }

  /// Extracts HTML highlighted snippets from text.
  String highlight(String text, Set<String> queryTerms) {
    return _highlighter.highlight(text, queryTerms);
  }

  /// Returns collection statistics (doc counts, segment count).
  Map<String, dynamic> stats() {
    return {
      'name': name,
      'doc_count': _writer.numDocs,
      'segment_count': _writer.segmentInfos.length,
      'segments': _writer.segmentInfos.map((s) => s.name).toList(),
    };
  }

  /// Simulates an abrupt crash without flushing or committing.
  void crash() {
    _currentSearcher?.close();
    _writer.crash();
  }

  /// Closes the index, committing writes and releasing reader handles.
  void close() {
    _currentSearcher?.close();
    _writer.close();
  }
}

/// Unified runtime facade managing multiple index collections in Corbel.
class CorbelEngine {
  final Directory baseDirectory;
  final Map<String, CorbelIndex> _indices = {};
  bool _closed = false;

  CorbelEngine({required this.baseDirectory});

  /// Creates a new index collection.
  CorbelIndex createIndex(
    String name,
    Schema schema, {
    Directory? directory,
    Analyzer? analyzer,
  }) {
    _checkOpen();
    if (_indices.containsKey(name)) {
      throw StateError('Index "$name" already exists');
    }

    final dir = directory ?? baseDirectory;
    final index = CorbelIndex(
      name: name,
      schema: schema,
      directory: dir,
      analyzer: analyzer,
    );
    _indices[name] = index;
    return index;
  }

  /// Retrieves an existing index collection.
  CorbelIndex? getIndex(String name) {
    _checkOpen();
    return _indices[name];
  }

  /// Lists all registered index collection names.
  List<String> listIndices() {
    _checkOpen();
    return _indices.keys.toList();
  }

  /// Drops and closes an index collection.
  void dropIndex(String name) {
    _checkOpen();
    final index = _indices.remove(name);
    index?.close();
  }

  /// Closes all managed indices and shuts down runtime.
  void close() {
    if (!_closed) {
      for (final index in _indices.values) {
        index.close();
      }
      _indices.clear();
      _closed = true;
    }
  }

  void _checkOpen() {
    if (_closed) throw StateError('CorbelEngine is closed');
  }
}
