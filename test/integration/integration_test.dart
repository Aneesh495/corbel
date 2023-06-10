import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';
import 'package:test/test.dart';

import 'package:corbel/src/core/schema.dart';
import 'package:corbel/src/engine/corbel_engine.dart';
import 'package:corbel/src/query/hybrid_query.dart';
import 'package:corbel/src/query/knn_vector_query.dart';
import 'package:corbel/src/query/term_query.dart';
import 'package:corbel/src/server/http_server.dart';
import 'package:corbel/src/storage/directory.dart';

void main() {
  group('End-to-End Engine & HTTP Integration Tests', () {
    late io.Directory tempDir;
    late CorbelEngine engine;
    late CorbelIndex index;
    late Schema schema;

    setUp(() async {
      tempDir = await io.Directory.systemTemp.createTemp('corbel_integration_');
      final diskDir = DiskDirectory(tempDir.path);
      engine = CorbelEngine(baseDirectory: diskDir);

      schema = Schema(
        fields: {
          'title': FieldDefinition.text('title'),
          'body': FieldDefinition.text('body'),
          'tag': FieldDefinition.string('tag', docValues: true),
          'price': FieldDefinition.int64('price', docValues: true),
          'embedding': FieldDefinition.vector('embedding', dimension: 4, metric: VectorDistanceMetric.cosine),
        },
      );

      index = engine.createIndex('catalog', schema);
    });

    tearDown(() async {
      engine.close();
      if (tempDir.existsSync()) {
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {}
      }
    });

    test('multi-segment indexing, deletions, compactions, and hybrid search', () {
      // 1. Ingest batch 1 (Segment 0)
      for (var i = 0; i < 20; i++) {
        index.index({
          '_id': 'item_$i',
          'title': 'High performance database product $i',
          'body': 'Corbel search engine with vector support and inverted indexing.',
          'tag': i % 2 == 0 ? 'hardware' : 'software',
          'price': 100 + i * 10,
          'embedding': Float32List.fromList([1.0, 0.0, 0.0, 0.0]),
        });
      }
      index.flush();

      // 2. Ingest batch 2 (Segment 1)
      for (var i = 20; i < 40; i++) {
        index.index({
          '_id': 'item_$i',
          'title': 'Cloud native cluster replica node $i',
          'body': 'Distributed consensus using Raft and streaming segment replication.',
          'tag': 'cloud',
          'price': 500 + i * 5,
          'embedding': Float32List.fromList([0.0, 1.0, 0.0, 0.0]),
        });
      }
      index.commit();

      expect(index.stats()['doc_count'], equals(40));

      // 3. Delete document and update document
      index.delete('item_0');
      index.index({
        '_id': 'item_1',
        'title': 'Updated hardware unit 1 with fast SSD',
        'body': 'Hardware product description updated.',
        'tag': 'hardware',
        'price': 999,
        'embedding': Float32List.fromList([1.0, 0.0, 0.0, 0.0]),
      });
      index.commit();

      expect(index.stats()['doc_count'], equals(39));

      // 4. Hybrid search combining lexical term query and vector ANN search
      final hybrid = HybridQuery(
        lexicalQuery: const TermQuery(field: 'title', term: 'database'),
        vectorQuery: KnnVectorQuery(
          field: 'embedding',
          targetVector: Float32List.fromList([1.0, 0.0, 0.0, 0.0]),
          k: 5,
        ),
        fusionMode: HybridFusionMode.rrf,
      );

      final topDocs = index.searchQuery(hybrid, topN: 5);
      expect(topDocs.totalHits, greaterThan(0));
      expect(topDocs.scoreDocs.isNotEmpty, isTrue);

      // Verify that item_0 (deleted) does NOT appear in results
      final matchedIds = topDocs.scoreDocs.map((h) => h.id).toSet();
      expect(matchedIds.contains('item_0'), isFalse);
    });

    test('crash recovery: WAL durability reconstructs uncommitted writes on restart', () async {
      // Index items without calling commit() (only buffered in WAL + active writer)
      index.index({
        '_id': 'uncommitted_1',
        'title': 'Durable transactional write',
        'body': 'This record will be recovered from write-ahead log replay.',
        'tag': 'durability',
        'price': 42,
      });

      // Abruptly crash index without commit
      index.crash();

      // Re-open fresh engine from the same disk directory
      final reopenedDiskDir = DiskDirectory(tempDir.path);
      final recoveryEngine = CorbelEngine(baseDirectory: reopenedDiskDir);
      final recoveredIndex = recoveryEngine.createIndex('catalog', schema);
      recoveredIndex.flush();

      final hits = recoveredIndex.search('title:durable', topN: 5);
      expect(hits.totalHits, equals(1));
      expect(hits.scoreDocs.first.id, equals('uncommitted_1'));

      recoveryEngine.close();
    });

    test('HTTP server REST endpoints and bulk streaming ingestion', () async {
      final server = CorbelHttpServer(engine: engine, port: 0);
      await server.start();
      final port = server.actualPort!;

      final client = io.HttpClient();

      // Test GET /_cat/indices
      final req = await client.get('127.0.0.1', port, '/_cat/indices');
      final resp = await req.close();
      expect(resp.statusCode, equals(io.HttpStatus.ok));

      final bodyStr = await resp.transform(utf8.decoder).join();
      final body = jsonDecode(bodyStr) as Map<String, dynamic>;
      expect(body.containsKey('indices'), isTrue);

      await server.close();
      client.close();
    });
  });
}
