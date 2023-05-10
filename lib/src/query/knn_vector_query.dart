import 'dart:typed_data';
import '../index/segment_reader.dart';
import 'explanation.dart';
import 'query.dart';
import 'scorer.dart';

/// Approximate nearest neighbor vector search query over HNSW graph index.
class KnnVectorQuery extends Query {
  final String field;
  final Float32List targetVector;
  final int k;
  final int efSearch;
  final Query? filter;

  const KnnVectorQuery({
    required this.field,
    required this.targetVector,
    required this.k,
    this.efSearch = 64,
    this.filter,
    super.boost = 1.0,
  });

  @override
  Weight createWeight(IndexSearchContext context, {bool needsScores = true}) {
    final filterWeight = filter?.createWeight(context, needsScores: false);
    return KnnVectorWeight(
      query: this,
      field: field,
      targetVector: targetVector,
      k: k,
      efSearch: efSearch,
      filterWeight: filterWeight,
    );
  }

  @override
  String toString() => 'KnnVectorQuery($field, k=$k, ef=$efSearch)${boost != 1.0 ? '^$boost' : ''}';
}

/// Weight executing HNSW beam search with optional pre-filtering.
class KnnVectorWeight extends Weight {
  final String field;
  final Float32List targetVector;
  final int k;
  final int efSearch;
  final Weight? filterWeight;

  const KnnVectorWeight({
    required KnnVectorQuery query,
    required this.field,
    required this.targetVector,
    required this.k,
    required this.efSearch,
    this.filterWeight,
  }) : super(query);

  @override
  Scorer? scorer(SegmentReader segmentReader) {
    final vectorIndex = segmentReader.getVectorIndex(field);
    if (vectorIndex == null) return null;

    // Optional pre-filtering
    bool Function(int docId)? filterPredicate;
    if (filterWeight != null) {
      final filterScorer = filterWeight!.scorer(segmentReader);
      if (filterScorer != null) {
        final allowedDocs = <int>{};
        var doc = filterScorer.nextDoc();
        while (doc != Scorer.noMoreDocs) {
          allowedDocs.add(doc);
          doc = filterScorer.nextDoc();
        }
        filterPredicate = (d) => allowedDocs.contains(d);
      } else {
        return null; // Filter matched zero documents
      }
    }

    final topK = vectorIndex.search(
      targetVector,
      k,
      efSearch: efSearch,
      filter: filterPredicate,
    );

    if (topK.isEmpty) return null;

    // Sort by docId for monotonic advance navigation
    final sortedMatches = topK.toList()..sort((a, b) => a.docId.compareTo(b.docId));
    return KnnVectorScorer(
      matches: sortedMatches,
      boost: query.boost,
    );
  }

  @override
  Explanation explain(SegmentReader segmentReader, int docId) {
    final s = scorer(segmentReader);
    if (s == null) return Explanation.noMatch('Vector index not found or empty');

    final target = s.advance(docId);
    if (target != docId) {
      return Explanation.noMatch('Document $docId is not in top-$k nearest neighbors');
    }

    final score = s.score();
    return Explanation.match(
      score,
      'KnnVector match for doc $docId (boost=${query.boost})',
    );
  }

  @override
  double cost() => k.toDouble();
}

/// Scorer navigating pre-computed top-k vector search results.
class KnnVectorScorer extends Scorer {
  final List<dynamic> matches;
  final double boost;
  int _cursor = -1;

  KnnVectorScorer({
    required this.matches,
    required this.boost,
  });

  @override
  int get docId {
    if (_cursor < 0 || _cursor >= matches.length) return Scorer.noMoreDocs;
    return matches[_cursor].docId as int;
  }

  @override
  double score() {
    if (_cursor < 0 || _cursor >= matches.length) return 0.0;
    final match = matches[_cursor];
    final dist = (match.distance as num).toDouble();
    final sim = 1.0 / (1.0 + dist);
    return sim * boost;
  }

  @override
  int nextDoc() {
    _cursor++;
    if (_cursor >= matches.length) return Scorer.noMoreDocs;
    return matches[_cursor].docId as int;
  }

  @override
  int advance(int target) {
    while (_cursor + 1 < matches.length && (matches[_cursor + 1].docId as int) < target) {
      _cursor++;
    }
    _cursor++;
    if (_cursor >= matches.length) return Scorer.noMoreDocs;
    return matches[_cursor].docId as int;
  }

  @override
  double cost() => matches.length.toDouble();
}
