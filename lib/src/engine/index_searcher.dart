import 'dart:convert';
import '../aggregation/terms_aggregation.dart';
import '../core/document.dart';
import '../core/schema.dart';
import '../index/deletion_vector.dart';
import '../index/segment_info.dart';
import '../index/segment_reader.dart';
import '../query/explanation.dart';
import '../query/query.dart';
import '../query/scorer.dart';
import '../query/similarity.dart';
import '../storage/directory.dart';
import '../utils/priority_queue.dart';
import 'index_writer.dart';
import 'snapshot.dart';

/// Single search hit with document score and segment positioning.
class ScoreDoc implements Comparable<ScoreDoc> {
  final int docId;
  final double score;
  final int segmentIndex;
  final String id;

  const ScoreDoc({
    required this.docId,
    required this.score,
    required this.segmentIndex,
    required this.id,
  });

  @override
  int compareTo(ScoreDoc other) {
    // Min-heap ordering: lowest score at the root so highest scores survive eviction
    final cmp = score.compareTo(other.score);
    if (cmp != 0) return cmp;
    // Secondary tie-breaker: smaller docId has higher priority
    return other.docId.compareTo(docId);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'doc_id': docId,
        'score': score,
        'segment_index': segmentIndex,
      };

  @override
  String toString() => 'ScoreDoc(id: $id, score: ${score.toStringAsFixed(4)})';
}

/// Consolidated top search results container with optional facet aggregations.
class TopDocs {
  final int totalHits;
  final List<ScoreDoc> scoreDocs;
  final double maxScore;
  final Map<String, AggregationResult> aggregations;

  const TopDocs({
    required this.totalHits,
    required this.scoreDocs,
    this.maxScore = 0.0,
    this.aggregations = const {},
  });

  Map<String, dynamic> toJson() => {
        'total_hits': totalHits,
        'max_score': maxScore,
        'hits': scoreDocs.map((h) => h.toJson()).toList(),
        if (aggregations.isNotEmpty)
          'aggregations': {
            for (final entry in aggregations.entries)
              entry.key: entry.value.toJson(),
          },
      };
}

/// Point-in-time search executor navigating multi-segment snapshots and scoring top-k results.
class IndexSearcher {
  final IndexSnapshot snapshot;
  final Similarity similarity;

  IndexSearcher(
    this.snapshot, {
    this.similarity = const BM25Similarity(),
  });

  /// Opens an IndexSearcher from an IndexWriter's committed state.
  factory IndexSearcher.fromWriter(IndexWriter writer) {
    final directory = writer.directory;
    final schema = writer.schema;
    final readers = <SegmentReader>[];

    for (final info in writer.segmentInfos) {
      final delVec = writer.deletionVectors[info.name] ?? DeletionVector();
      readers.add(SegmentReader.open(
        info: info,
        directory: directory,
        deletionVector: delVec,
      ));
    }

    final snapshot = IndexSnapshot(segmentReaders: readers, schema: schema);
    return IndexSearcher(snapshot);
  }

  /// Opens an IndexSearcher from on-disk directory files and manifest.
  static IndexSearcher open(Directory directory, Schema schema) {
    final readers = <SegmentReader>[];
    if (directory.fileExists(IndexWriter.manifestFileName)) {
      final input = directory.openInput(IndexWriter.manifestFileName);
      try {
        final bytes = input.readBytes(input.length);
        final jsonStr = String.fromCharCodes(bytes);
        final dynamic decoded = jsonDecode(jsonStr);
        final segList = decoded['segments'] as List<dynamic>? ?? [];

        for (final s in segList) {
          final info = SegmentInfo.fromJson(s as Map<String, dynamic>, schema);
          DeletionVector? delVec;
          final delName = '${info.name}.cbl_del';
          if (directory.fileExists(delName)) {
            final delIn = directory.openInput(delName);
            try {
              delVec = DeletionVector.deserialize(delIn);
            } finally {
              delIn.close();
            }
          }
          readers.add(SegmentReader.open(
            info: info,
            directory: directory,
            deletionVector: delVec,
          ));
        }
      } finally {
        input.close();
      }
    }

    final snapshot = IndexSnapshot(segmentReaders: readers, schema: schema);
    return IndexSearcher(snapshot);
  }

  /// Executes a query and returns the top [topN] scoring hits.
  TopDocs search(Query query, int topN) {
    return searchWithAggregations(query, topN, const []);
  }

  /// Executes a query with concurrent columnar aggregation collection.
  TopDocs searchWithAggregations(
    Query query,
    int topN,
    List<Aggregation> aggregations,
  ) {
    if (topN <= 0) {
      throw ArgumentError.value(topN, 'topN', 'Must be strictly positive');
    }

    final weight = query.createWeight(snapshot.context, needsScores: true);
    final pq = BoundedPriorityQueue<ScoreDoc>(topN, (a, b) => a.compareTo(b));
    var totalHits = 0;
    var maxScore = 0.0;

    final aggResults = <String, AggregationResult>{};
    final collectorsBySeg = <int, List<AggregationCollector>>{};

    for (var segIdx = 0; segIdx < snapshot.segmentReaders.length; segIdx++) {
      final reader = snapshot.segmentReaders[segIdx];
      final scorer = weight.scorer(reader);

      // Initialize aggregation collectors for this segment
      final collectors = aggregations.map((a) => a.newCollector(reader)).toList();
      collectorsBySeg[segIdx] = collectors;

      if (scorer == null) continue;

      var docId = scorer.nextDoc();
      while (docId != Scorer.noMoreDocs) {
        if (reader.isLive(docId)) {
          totalHits++;
          final score = scorer.score();
          if (score > maxScore) maxScore = score;

          // Collect aggregations
          for (final c in collectors) {
            c.collect(docId);
          }

          final rawDoc = reader.document(docId);
          final id = rawDoc[snapshot.schema.idFieldName] as String? ?? 'doc_$docId';

          pq.insertWithOverflow(ScoreDoc(
            docId: docId,
            score: score,
            segmentIndex: segIdx,
            id: id,
          ));
        }
        docId = scorer.nextDoc();
      }
    }

    // Merge aggregation results across all segments
    for (var i = 0; i < aggregations.length; i++) {
      final aggName = aggregations[i].name;
      AggregationResult? merged;

      for (var segIdx = 0; segIdx < snapshot.segmentReaders.length; segIdx++) {
        final c = collectorsBySeg[segIdx]?[i];
        if (c != null) {
          final res = c.buildResult();
          merged = merged == null ? res : merged.mergeWith(res);
        }
      }

      if (merged != null) {
        aggResults[aggName] = merged;
      }
    }

    final hits = <ScoreDoc>[];
    while (pq.isNotEmpty) {
      hits.add(pq.pop());
    }

    return TopDocs(
      totalHits: totalHits,
      scoreDocs: hits.reversed.toList(),
      maxScore: maxScore,
      aggregations: aggResults,
    );
  }

  /// Retrieves stored fields document for a search hit.
  Document doc(ScoreDoc hit) {
    if (hit.segmentIndex < 0 || hit.segmentIndex >= snapshot.segmentReaders.length) {
      throw RangeError.index(hit.segmentIndex, snapshot.segmentReaders, 'segmentIndex');
    }
    final reader = snapshot.segmentReaders[hit.segmentIndex];
    final map = reader.document(hit.docId);
    return Document.fromMap(hit.id, map, schema: snapshot.schema);
  }

  /// Explains score breakdown for a search hit.
  Explanation explain(Query query, ScoreDoc hit) {
    final reader = snapshot.segmentReaders[hit.segmentIndex];
    return query.explain(reader, snapshot.context, hit.docId);
  }

  /// Closes the underlying snapshot and all segment readers.
  void close() {
    snapshot.close();
  }
}
