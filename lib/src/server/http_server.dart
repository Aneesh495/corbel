import 'dart:convert';
import 'dart:io';
import '../core/schema.dart';
import '../engine/corbel_engine.dart';
import 'handlers/bulk_handler.dart';
import 'handlers/metrics_handler.dart';
import 'router.dart';

/// Embedded REST HTTP API server exposing index and search endpoints.
class CorbelHttpServer {
  final CorbelEngine engine;
  final int port;
  final String host;

  HttpServer? _server;
  late final CorbelRouter _router;
  bool _closed = false;

  CorbelHttpServer({
    required this.engine,
    this.port = 9200,
    this.host = '0.0.0.0',
  }) {
    _router = CorbelRouter();
    _registerRoutes();
  }

  CorbelRouter get router => _router;

  void _registerRoutes() {
    // 1. Cluster info root
    _router.get('/', (req, res, params) async {
      _sendJson(res, HttpStatus.ok, {
        'name': 'corbel-node',
        'cluster_name': 'corbel-cluster',
        'version': '1.0.0',
        'tagline': 'High-performance distributed search engine written in Dart',
      });
    });

    // 2. Streaming NDJSON bulk ingestion
    _router.post('/_bulk', (req, res, params) => BulkHandler(engine: engine).handle(req, res));

    // 3. Prometheus metrics and cluster health
    _router.get('/_metrics', (req, res, params) async => MetricsHandler(engine: engine).handleMetrics(req, res));
    _router.get('/_cluster/health', (req, res, params) async => MetricsHandler(engine: engine).handleHealth(req, res));

    // 4. List indices
    _router.get('/_cat/indices', (req, res, params) async {
      final names = engine.listIndices();
      final statsList = <Map<String, dynamic>>[];
      for (final name in names) {
        final idx = engine.getIndex(name);
        if (idx != null) {
          statsList.add(idx.stats());
        }
      }
      _sendJson(res, HttpStatus.ok, {'indices': statsList});
    });

    // 3. Create index
    _router.put('/:index', (req, res, params) async {
      final indexName = params['index']!;
      final body = await _readJsonBody(req);
      final fieldsJson = body['fields'] as Map<String, dynamic>? ?? {};

      final fieldDefs = <String, FieldDefinition>{};
      for (final entry in fieldsJson.entries) {
        fieldDefs[entry.key] = FieldDefinition.fromJson(entry.value as Map<String, dynamic>);
      }

      final schema = Schema(
        idFieldName: body['id_field'] as String? ?? '_id',
        fields: fieldDefs,
      );

      final created = engine.createIndex(indexName, schema);
      _sendJson(res, HttpStatus.created, {
        'acknowledged': true,
        'index': indexName,
        'doc_count': created.stats()['doc_count'],
      });
    });

    // 4. Drop index
    _router.delete('/:index', (req, res, params) async {
      final indexName = params['index']!;
      engine.dropIndex(indexName);
      _sendJson(res, HttpStatus.ok, {'acknowledged': true, 'index': indexName});
    });

    // 5. Index document (POST /:index/_doc)
    _router.post('/:index/_doc', (req, res, params) async {
      final indexName = params['index']!;
      final idx = engine.getIndex(indexName);
      if (idx == null) {
        _sendJson(res, HttpStatus.notFound, {'error': 'Index "$indexName" not found'});
        return;
      }

      final body = await _readJsonBody(req);
      final id = body[idx.schema.idFieldName]?.toString() ??
          'doc_${DateTime.now().microsecondsSinceEpoch}';
      body[idx.schema.idFieldName] = id;

      idx.index(body);
      _sendJson(res, HttpStatus.created, {
        '_index': indexName,
        '_id': id,
        'result': 'created',
      });
    });

    // 6. Index document with explicit ID (PUT /:index/_doc/:id)
    _router.put('/:index/_doc/:id', (req, res, params) async {
      final indexName = params['index']!;
      final id = params['id']!;
      final idx = engine.getIndex(indexName);
      if (idx == null) {
        _sendJson(res, HttpStatus.notFound, {'error': 'Index "$indexName" not found'});
        return;
      }

      final body = await _readJsonBody(req);
      body[idx.schema.idFieldName] = id;
      idx.index(body);

      _sendJson(res, HttpStatus.ok, {
        '_index': indexName,
        '_id': id,
        'result': 'updated',
      });
    });

    // 7. Delete document (DELETE /:index/_doc/:id)
    _router.delete('/:index/_doc/:id', (req, res, params) async {
      final indexName = params['index']!;
      final id = params['id']!;
      final idx = engine.getIndex(indexName);
      if (idx == null) {
        _sendJson(res, HttpStatus.notFound, {'error': 'Index "$indexName" not found'});
        return;
      }

      idx.delete(id);
      _sendJson(res, HttpStatus.ok, {
        '_index': indexName,
        '_id': id,
        'result': 'deleted',
      });
    });

    // 8. Search query (POST /:index/_search)
    _router.post('/:index/_search', (req, res, params) async {
      final indexName = params['index']!;
      final idx = engine.getIndex(indexName);
      if (idx == null) {
        _sendJson(res, HttpStatus.notFound, {'error': 'Index "$indexName" not found'});
        return;
      }

      final body = await _readJsonBody(req);
      final qStr = body['query'] as String? ?? req.uri.queryParameters['q'] ?? '*';
      final topN = body['size'] as int? ?? 10;

      final topDocs = idx.search(qStr, topN: topN);
      final hitsJson = <Map<String, dynamic>>[];

      for (final hit in topDocs.scoreDocs) {
        final doc = idx.doc(hit);
        hitsJson.add({
          '_id': hit.id,
          '_score': hit.score,
          '_source': doc.toMap(),
        });
      }

      _sendJson(res, HttpStatus.ok, {
        'took_ms': 1,
        'timed_out': false,
        'hits': {
          'total': {'value': topDocs.totalHits, 'relation': 'eq'},
          'max_score': topDocs.maxScore,
          'hits': hitsJson,
        },
      });
    });

    // 9. Commit / Refresh (POST /:index/_refresh)
    _router.post('/:index/_refresh', (req, res, params) async {
      final indexName = params['index']!;
      final idx = engine.getIndex(indexName);
      if (idx == null) {
        _sendJson(res, HttpStatus.notFound, {'error': 'Index "$indexName" not found'});
        return;
      }

      idx.commit();
      _sendJson(res, HttpStatus.ok, {'_shards': {'total': 1, 'successful': 1}});
    });
  }

  Future<Map<String, dynamic>> _readJsonBody(HttpRequest req) async {
    final content = await utf8.decoder.bind(req).join();
    if (content.trim().isEmpty) return {};
    return jsonDecode(content) as Map<String, dynamic>;
  }

  static void _sendJson(HttpResponse response, int statusCode, Map<String, dynamic> body) {
    final jsonStr = jsonEncode(body);
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.json;
    response.write(jsonStr);
    response.close();
  }

  /// Starts the HTTP server on configured host and port.
  Future<void> start() async {
    _server = await HttpServer.bind(host, port);
    _server!.listen((req) => _router.handle(req));
  }

  /// Shuts down the HTTP server.
  Future<void> close() async {
    if (!_closed) {
      await _server?.close(force: true);
      _closed = true;
    }
  }
}
