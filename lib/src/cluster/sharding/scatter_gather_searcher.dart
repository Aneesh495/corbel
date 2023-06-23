import 'dart:async';
import '../../aggregation/terms_aggregation.dart';
import '../../engine/index_searcher.dart';
import '../../query/query.dart';
import '../../utils/priority_queue.dart';
import 'shard_routing.dart';

/// Single shard search result with execution timing.
class ShardSearchResult {
  final ShardId shardId;
  final TopDocs topDocs;
  final Duration took;

  const ShardSearchResult({
    required this.shardId,
    required this.topDocs,
    required this.took,
  });
}

/// Consolidated distributed search result aggregated across cluster shards.
class DistributedTopDocs {
  final int totalHits;
  final List<ScoreDoc> scoreDocs;
  final double maxScore;
  final Map<String, AggregationResult> aggregations;
  final int totalShards;
  final int successfulShards;
  final int failedShards;
  final Duration took;

  const DistributedTopDocs({
    required this.totalHits,
    required this.scoreDocs,
    required this.maxScore,
    required this.aggregations,
    required this.totalShards,
    required this.successfulShards,
    required this.failedShards,
    required this.took,
  });

  Map<String, dynamic> toJson() => {
        'total_hits': totalHits,
        'max_score': maxScore,
        'took_ms': took.inMilliseconds,
        'shards': {
          'total': totalShards,
          'successful': successfulShards,
          'failed': failedShards,
        },
        'hits': scoreDocs.map((s) => s.toJson()).toList(),
        'aggregations': aggregations.map((k, v) => MapEntry(k, v.toJson())),
      };

  @override
  String toString() =>
      'DistributedTopDocs(totalHits: $totalHits, maxScore: ${maxScore.toStringAsFixed(4)}, shards: $successfulShards/$totalShards, took: ${took.inMilliseconds}ms)';
}

/// Abstract contract for executing a query on a single shard partition.
abstract class ShardSearchTarget {
  ShardId get shardId;

  Future<TopDocs> search(
    Query query, {
    int topK = 10,
    List<Aggregation> aggregations = const [],
  });
}

/// Scatter-gather coordinator distributing queries across multiple shards in parallel
/// and consolidating top-k results and aggregations.
class ScatterGatherSearcher {
  final List<ShardSearchTarget> targets;

  const ScatterGatherSearcher(this.targets);

  /// Executes distributed search across all shards with scatter-gather parallel dispatch.
  Future<DistributedTopDocs> search(
    Query query, {
    int topK = 10,
    List<Aggregation> aggregations = const [],
  }) async {
    final stopwatch = Stopwatch()..start();

    // 1. Scatter: execute search on all targets concurrently
    final futures = targets.map((target) async {
      final shardStopwatch = Stopwatch()..start();
      try {
        final topDocs = await target.search(
          query,
          topK: topK,
          aggregations: aggregations,
        );
        return ShardSearchResult(
          shardId: target.shardId,
          topDocs: topDocs,
          took: shardStopwatch.elapsed,
        );
      } catch (_) {
        return null;
      }
    });

    final results = await Future.wait(futures);
    stopwatch.stop();

    // 2. Gather: merge top-k hits and aggregations across shards
    var totalHits = 0;
    var successfulShards = 0;
    var failedShards = 0;
    var maxScore = 0.0;

    final pq = BoundedPriorityQueue<ScoreDoc>(
      topK,
      (a, b) => a.compareTo(b),
    );
    final mergedAggregations = <String, AggregationResult>{};

    for (final res in results) {
      if (res == null) {
        failedShards++;
        continue;
      }

      successfulShards++;
      final topDocs = res.topDocs;
      totalHits += topDocs.totalHits;
      if (topDocs.maxScore > maxScore) {
        maxScore = topDocs.maxScore;
      }

      // Merge ScoreDocs into global bounded priority queue
      for (final doc in topDocs.scoreDocs) {
        pq.insertWithOverflow(doc);
      }

      // Merge Columnar Aggregations across shards
      for (final entry in topDocs.aggregations.entries) {
        final aggName = entry.key;
        final aggVal = entry.value;

        if (mergedAggregations.containsKey(aggName)) {
          mergedAggregations[aggName] =
              mergedAggregations[aggName]!.mergeWith(aggVal);
        } else {
          mergedAggregations[aggName] = aggVal;
        }
      }
    }

    final globalScoreDocs = pq.drainToListDescending();

    return DistributedTopDocs(
      totalHits: totalHits,
      scoreDocs: globalScoreDocs,
      maxScore: maxScore,
      aggregations: mergedAggregations,
      totalShards: targets.length,
      successfulShards: successfulShards,
      failedShards: failedShards,
      took: stopwatch.elapsed,
    );
  }
}
