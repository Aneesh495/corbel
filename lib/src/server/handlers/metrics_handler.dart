import 'dart:convert';
import 'dart:io';
import '../../engine/corbel_engine.dart';

/// Exposes Prometheus text-formatted metrics and JSON cluster health diagnostics.
class MetricsHandler {
  final CorbelEngine engine;

  const MetricsHandler({required this.engine});

  /// Handles GET /_metrics returning Prometheus exposition format.
  void handleMetrics(HttpRequest request, HttpResponse response) {
    final buf = StringBuffer();
    final indices = engine.listIndices();
    var totalDocs = 0;
    var totalSegments = 0;

    for (final name in indices) {
      final idx = engine.getIndex(name);
      if (idx != null) {
        final stats = idx.stats();
        final docCount = stats['doc_count'] as int? ?? 0;
        final segCount = stats['segment_count'] as int? ?? 0;
        totalDocs += docCount;
        totalSegments += segCount;

        buf.writeln('corbel_index_docs_total{index="$name"} $docCount');
        buf.writeln('corbel_index_segments_total{index="$name"} $segCount');
      }
    }

    buf.writeln('# HELP corbel_indices_total Total number of active index collections');
    buf.writeln('# TYPE corbel_indices_total gauge');
    buf.writeln('corbel_indices_total ${indices.length}');

    buf.writeln('# HELP corbel_documents_total Total documents indexed across all collections');
    buf.writeln('# TYPE corbel_documents_total gauge');
    buf.writeln('corbel_documents_total $totalDocs');

    buf.writeln('# HELP corbel_segments_total Total segments across all collections');
    buf.writeln('# TYPE corbel_segments_total gauge');
    buf.writeln('corbel_segments_total $totalSegments');

    buf.writeln('# HELP corbel_memory_rss_bytes Process resident set memory size');
    buf.writeln('# TYPE corbel_memory_rss_bytes gauge');
    buf.writeln('corbel_memory_rss_bytes ${ProcessInfo.currentRss}');

    response.statusCode = HttpStatus.ok;
    response.headers.contentType = ContentType.parse('text/plain; version=0.0.4; charset=utf-8');
    response.write(buf.toString());
    response.close();
  }

  /// Handles GET /_cluster/health returning JSON health status.
  void handleHealth(HttpRequest request, HttpResponse response) {
    final indices = engine.listIndices();
    final indexHealthMap = <String, dynamic>{};

    for (final name in indices) {
      final idx = engine.getIndex(name);
      if (idx != null) {
        final stats = idx.stats();
        indexHealthMap[name] = {
          'status': 'green',
          'number_of_shards': 1,
          'number_of_replicas': 0,
          'active_shards': 1,
          'doc_count': stats['doc_count'],
        };
      }
    }

    final health = {
      'cluster_name': 'corbel-cluster',
      'status': 'green',
      'timed_out': false,
      'number_of_nodes': 1,
      'number_of_data_nodes': 1,
      'active_primary_shards': indices.length,
      'active_shards': indices.length,
      'indices': indexHealthMap,
    };

    response.statusCode = HttpStatus.ok;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(health));
    response.close();
  }
}
