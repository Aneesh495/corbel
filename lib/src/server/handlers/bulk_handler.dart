import 'dart:convert';
import 'dart:io';
import '../../engine/corbel_engine.dart';

/// Streaming line-delimited JSON (NDJSON) bulk ingestion handler.
class BulkHandler {
  final CorbelEngine engine;

  const BulkHandler({required this.engine});

  /// Handles POST /_bulk requests with streaming NDJSON lines.
  Future<void> handle(HttpRequest request, HttpResponse response) async {
    final stopwatch = Stopwatch()..start();
    final lines = utf8.decoder
        .bind(request)
        .transform(const LineSplitter());

    var hasErrors = false;
    final items = <Map<String, dynamic>>[];
    Map<String, dynamic>? pendingAction;
    String? pendingOp;
    String? pendingIndex;
    String? pendingId;

    await for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      final dynamic decoded = jsonDecode(trimmed);
      if (decoded is! Map<String, dynamic>) continue;

      if (pendingAction == null) {
        // Line is an action directive: {"index": {...}}, {"create": {...}}, {"delete": {...}}
        if (decoded.containsKey('index') || decoded.containsKey('create')) {
          pendingOp = 'index';
          final action = (decoded['index'] ?? decoded['create']) as Map<String, dynamic>;
          pendingIndex = action['_index'] as String?;
          pendingId = action['_id']?.toString();
          pendingAction = action;
        } else if (decoded.containsKey('delete')) {
          final action = decoded['delete'] as Map<String, dynamic>;
          final indexName = action['_index'] as String?;
          final id = action['_id']?.toString();

          if (indexName != null && id != null) {
            final idx = engine.getIndex(indexName);
            if (idx != null) {
              idx.delete(id);
              items.add({
                'delete': {
                  '_index': indexName,
                  '_id': id,
                  'status': HttpStatus.ok,
                  'result': 'deleted',
                }
              });
            } else {
              hasErrors = true;
              items.add({
                'delete': {
                  '_index': indexName,
                  '_id': id,
                  'status': HttpStatus.notFound,
                  'error': 'Index not found',
                }
              });
            }
          }
        }
      } else {
        // Line is the document source body for the pending index/create action
        final indexName = pendingIndex;
        final idx = indexName != null ? engine.getIndex(indexName) : null;

        if (idx != null) {
          final id = pendingId ?? decoded[idx.schema.idFieldName]?.toString() ??
              'doc_${DateTime.now().microsecondsSinceEpoch}';
          decoded[idx.schema.idFieldName] = id;
          idx.index(decoded);

          items.add({
            pendingOp!: {
              '_index': indexName,
              '_id': id,
              'status': HttpStatus.created,
              'result': 'created',
            }
          });
        } else {
          hasErrors = true;
          items.add({
            pendingOp!: {
              '_index': indexName,
              '_id': pendingId,
              'status': HttpStatus.notFound,
              'error': 'Index "$indexName" not found',
            }
          });
        }

        pendingAction = null;
        pendingOp = null;
        pendingIndex = null;
        pendingId = null;
      }
    }

    stopwatch.stop();

    final responseBody = {
      'took': stopwatch.elapsedMilliseconds,
      'errors': hasErrors,
      'items': items,
    };

    final jsonStr = jsonEncode(responseBody);
    response.statusCode = HttpStatus.ok;
    response.headers.contentType = ContentType.json;
    response.write(jsonStr);
    await response.close();
  }
}
