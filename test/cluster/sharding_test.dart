import 'package:corbel/corbel.dart';
import 'package:test/test.dart';

class _MockShardTarget implements ShardSearchTarget {
  @override
  final ShardId shardId;
  final CorbelIndex index;
  final bool shouldFail;

  _MockShardTarget({
    required this.shardId,
    required this.index,
    this.shouldFail = false,
  });

  @override
  Future<TopDocs> search(
    Query query, {
    int topK = 10,
    List<Aggregation> aggregations = const [],
  }) async {
    if (shouldFail) {
      throw StateError('Simulated network partition on shard $shardId');
    }
    return index.searchQuery(query, topN: topK, aggregations: aggregations);
  }
}

void main() {
  group('ConsistentHashRing Tests', () {
    test('distributes keys across dynamic nodes with minimal rebalancing', () {
      final ring = ConsistentHashRing<String>(virtualNodesPerNode: 50);

      ring.addNode('nodeA');
      ring.addNode('nodeB');
      ring.addNode('nodeC');

      expect(ring.nodeCount, equals(3));

      // Key to node mapping
      final keyAssignments = <String, String>{};
      for (var i = 0; i < 1000; i++) {
        final key = 'doc_key_$i';
        keyAssignments[key] = ring.getNode(key)!;
      }

      // Check all 3 nodes receive a fair share of keys
      final counts = <String, int>{};
      for (final node in keyAssignments.values) {
        counts[node] = (counts[node] ?? 0) + 1;
      }

      expect(counts['nodeA'], greaterThan(150));
      expect(counts['nodeB'], greaterThan(150));
      expect(counts['nodeC'], greaterThan(150));

      // Add nodeD: only a fraction of keys should relocate
      ring.addNode('nodeD');
      var relocated = 0;
      for (var i = 0; i < 1000; i++) {
        final key = 'doc_key_$i';
        final newNode = ring.getNode(key)!;
        if (newNode != keyAssignments[key]) {
          relocated++;
        }
      }

      // In consistent hashing with 4 nodes, approx 25% of keys should relocate
      expect(relocated, greaterThan(100));
      expect(relocated, lessThan(400));
    });

    test('getNodes returns distinct replica nodes', () {
      final ring = ConsistentHashRing<String>(virtualNodesPerNode: 30);
      ring.addNode('node1');
      ring.addNode('node2');
      ring.addNode('node3');
      ring.addNode('node4');

      final replicas = ring.getNodes('customer_account_42', 3);
      expect(replicas.length, equals(3));
      expect(replicas.toSet().length, equals(3)); // All physical nodes must be distinct
    });
  });

  group('IndexRoutingTable Tests', () {
    test('routes keys consistently to shard partitions', () {
      final table = IndexRoutingTable(indexName: 'logs', numShards: 5);

      final shardIdx1 = table.route('server_1_log');
      final shardIdx2 = table.route('server_1_log');
      expect(shardIdx1, equals(shardIdx2));
      expect(shardIdx1, inInclusiveRange(0, 4));

      table.addRouting(const ShardRouting(
        shardId: ShardId('logs', 0),
        nodeId: 'nodeA',
        isPrimary: true,
      ));
      table.addRouting(const ShardRouting(
        shardId: ShardId('logs', 0),
        nodeId: 'nodeB',
        isPrimary: false,
      ));

      final primary = table.getPrimaryShard(0);
      expect(primary, isNotNull);
      expect(primary!.nodeId, equals('nodeA'));

      final replicas = table.getReplicaShards(0);
      expect(replicas.length, equals(1));
      expect(replicas.first.nodeId, equals('nodeB'));
    });
  });

  group('ScatterGatherSearcher Distributed Search Tests', () {
    late CorbelIndex shard0;
    late CorbelIndex shard1;
    late CorbelIndex shard2;
    late Schema schema;

    setUp(() {
      schema = Schema(
        idFieldName: 'id',
        fields: {
          'id': FieldDefinition.string('id'),
          'category': FieldDefinition.string('category'),
          'title': FieldDefinition.text('title'),
          'views': FieldDefinition.int64('views'),
        },
      );

      shard0 = CorbelIndex(
        name: 'shard0',
        schema: schema,
        directory: RAMDirectory(),
      );
      shard1 = CorbelIndex(
        name: 'shard1',
        schema: schema,
        directory: RAMDirectory(),
      );
      shard2 = CorbelIndex(
        name: 'shard2',
        schema: schema,
        directory: RAMDirectory(),
      );

      // Shard 0 docs
      shard0.index({
        'id': 's0_doc1',
        'category': 'tech',
        'title': 'distributed storage engine in dart',
        'views': 150,
      });

      // Shard 1 docs
      shard1.index({
        'id': 's1_doc1',
        'category': 'tech',
        'title': 'high performance search index',
        'views': 300,
      });

      // Shard 2 docs
      shard2.index({
        'id': 's2_doc1',
        'category': 'finance',
        'title': 'distributed ledger and market trading',
        'views': 450,
      });

      shard0.flush();
      shard1.flush();
      shard2.flush();
      shard0.refresh();
      shard1.refresh();
      shard2.refresh();
    });

    tearDown(() {
      shard0.close();
      shard1.close();
      shard2.close();
    });

    test('consolidates top hits and merges facet aggregations across shards', () async {
      final targets = [
        _MockShardTarget(shardId: const ShardId('items', 0), index: shard0),
        _MockShardTarget(shardId: const ShardId('items', 1), index: shard1),
        _MockShardTarget(shardId: const ShardId('items', 2), index: shard2),
      ];

      final searcher = ScatterGatherSearcher(targets);

      // Search for "distributed"
      final query = const TermQuery(field: 'title', term: 'distributed');
      final agg = const TermsAggregation(name: 'cat_facet', field: 'category');

      final result = await searcher.search(
        query,
        topK: 10,
        aggregations: [agg],
      );

      expect(result.totalShards, equals(3));
      expect(result.successfulShards, equals(3));
      expect(result.failedShards, equals(0));
      expect(result.totalHits, equals(2)); // Found in Shard 0 and Shard 2

      final hitIds = result.scoreDocs.map((s) => s.id).toList();
      expect(hitIds, containsAll(['s0_doc1', 's2_doc1']));

      // Verify merged terms aggregation
      final catResult =
          result.aggregations['cat_facet'] as TermsAggregationResult;
      final bucketMap = {for (final b in catResult.buckets) b.key: b.count};
      expect(bucketMap['tech'], equals(1)); // From shard0
      expect(bucketMap['finance'], equals(1)); // From shard2
    });

    test('survives partial shard failures with graceful degradation', () async {
      final targets = [
        _MockShardTarget(shardId: const ShardId('items', 0), index: shard0),
        _MockShardTarget(
          shardId: const ShardId('items', 1),
          index: shard1,
          shouldFail: true, // Partition failure
        ),
        _MockShardTarget(shardId: const ShardId('items', 2), index: shard2),
      ];

      final searcher = ScatterGatherSearcher(targets);
      final query = const TermQuery(field: 'title', term: 'distributed');

      final result = await searcher.search(query);

      expect(result.totalShards, equals(3));
      expect(result.successfulShards, equals(2));
      expect(result.failedShards, equals(1));
      expect(result.totalHits, equals(2));
    });
  });
}
