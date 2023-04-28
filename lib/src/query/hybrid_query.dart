import '../index/segment_reader.dart';
import 'explanation.dart';
import 'knn_vector_query.dart';
import 'query.dart';
import 'scorer.dart';

/// Fusion mode for blending lexical and vector search rankings.
enum HybridFusionMode {
  /// Reciprocal Rank Fusion (RRF): rank-based, parameter-free and scale-invariant.
  rrf,

  /// Linear score interpolation with min-max normalization.
  linear,
}

/// Hybrid query fusing lexical keyword search with dense vector ANN search.
class HybridQuery extends Query {
  final Query lexicalQuery;
  final KnnVectorQuery vectorQuery;
  final HybridFusionMode fusionMode;
  final int rrfK;
  final double alpha;

  const HybridQuery({
    required this.lexicalQuery,
    required this.vectorQuery,
    this.fusionMode = HybridFusionMode.rrf,
    this.rrfK = 60,
    this.alpha = 0.5,
    super.boost = 1.0,
  })  : assert(alpha >= 0.0 && alpha <= 1.0, 'alpha must be between 0.0 and 1.0'),
        assert(rrfK > 0, 'rrfK must be positive');

  @override
  Weight createWeight(IndexSearchContext context, {bool needsScores = true}) {
    final lexWeight = lexicalQuery.createWeight(context, needsScores: true);
    final vecWeight = vectorQuery.createWeight(context, needsScores: true);

    return HybridWeight(
      query: this,
      lexicalWeight: lexWeight,
      vectorWeight: vecWeight,
      fusionMode: fusionMode,
      rrfK: rrfK,
      alpha: alpha,
    );
  }

  @override
  String toString() =>
      'HybridQuery(lexical: $lexicalQuery, vector: $vectorQuery, mode: $fusionMode)${boost != 1.0 ? '^$boost' : ''}';
}

/// Weight compiling lexical and vector weights into a unified fusion scorer.
class HybridWeight extends Weight {
  final Weight lexicalWeight;
  final Weight vectorWeight;
  final HybridFusionMode fusionMode;
  final int rrfK;
  final double alpha;

  const HybridWeight({
    required HybridQuery query,
    required this.lexicalWeight,
    required this.vectorWeight,
    required this.fusionMode,
    required this.rrfK,
    required this.alpha,
  }) : super(query);

  @override
  Scorer? scorer(SegmentReader segmentReader) {
    final lexScorer = lexicalWeight.scorer(segmentReader);
    final vecScorer = vectorWeight.scorer(segmentReader);

    if (lexScorer == null && vecScorer == null) return null;

    final docScores = <int, double>{};

    if (fusionMode == HybridFusionMode.rrf) {
      _fuseRrf(lexScorer, vecScorer, docScores);
    } else {
      _fuseLinear(lexScorer, vecScorer, docScores);
    }

    if (docScores.isEmpty) return null;

    final sortedDocs = docScores.keys.toList()..sort();
    return _HybridListScorer(
      docIds: sortedDocs,
      scores: docScores,
      boost: query.boost,
    );
  }

  void _fuseRrf(Scorer? lexScorer, Scorer? vecScorer, Map<int, double> docScores) {
    // 1. Collect lexical candidates with raw scores and sort by score
    final lexList = <MapEntry<int, double>>[];
    if (lexScorer != null) {
      var d = lexScorer.nextDoc();
      while (d != Scorer.noMoreDocs) {
        lexList.add(MapEntry(d, lexScorer.score()));
        d = lexScorer.nextDoc();
      }
    }
    lexList.sort((a, b) => b.value.compareTo(a.value));

    for (var r = 0; r < lexList.length; r++) {
      final docId = lexList[r].key;
      final rrfScore = 1.0 / (rrfK + (r + 1));
      docScores[docId] = (docScores[docId] ?? 0.0) + rrfScore;
    }

    // 2. Collect vector candidates with raw scores and sort by score
    final vecList = <MapEntry<int, double>>[];
    if (vecScorer != null) {
      var d = vecScorer.nextDoc();
      while (d != Scorer.noMoreDocs) {
        vecList.add(MapEntry(d, vecScorer.score()));
        d = vecScorer.nextDoc();
      }
    }
    vecList.sort((a, b) => b.value.compareTo(a.value));

    for (var r = 0; r < vecList.length; r++) {
      final docId = vecList[r].key;
      final rrfScore = 1.0 / (rrfK + (r + 1));
      docScores[docId] = (docScores[docId] ?? 0.0) + rrfScore;
    }
  }

  void _fuseLinear(Scorer? lexScorer, Scorer? vecScorer, Map<int, double> docScores) {
    final lexMap = <int, double>{};
    var maxLex = 0.0;
    var minLex = double.infinity;

    if (lexScorer != null) {
      var d = lexScorer.nextDoc();
      while (d != Scorer.noMoreDocs) {
        final s = lexScorer.score();
        lexMap[d] = s;
        if (s > maxLex) maxLex = s;
        if (s < minLex) minLex = s;
        d = lexScorer.nextDoc();
      }
    }

    final vecMap = <int, double>{};
    var maxVec = 0.0;
    var minVec = double.infinity;

    if (vecScorer != null) {
      var d = vecScorer.nextDoc();
      while (d != Scorer.noMoreDocs) {
        final s = vecScorer.score();
        vecMap[d] = s;
        if (s > maxVec) maxVec = s;
        if (s < minVec) minVec = s;
        d = vecScorer.nextDoc();
      }
    }

    final allDocs = {...lexMap.keys, ...vecMap.keys};
    final lexSpan = maxLex - minLex > 0.00001 ? maxLex - minLex : 1.0;
    final vecSpan = maxVec - minVec > 0.00001 ? maxVec - minVec : 1.0;

    for (final docId in allDocs) {
      final rawLex = lexMap[docId];
      final normLex = rawLex != null ? (rawLex - minLex) / lexSpan : 0.0;

      final rawVec = vecMap[docId];
      final normVec = rawVec != null ? (rawVec - minVec) / vecSpan : 0.0;

      final fused = (alpha * normLex) + ((1.0 - alpha) * normVec);
      docScores[docId] = fused;
    }
  }

  @override
  Explanation explain(SegmentReader segmentReader, int docId) {
    final s = scorer(segmentReader);
    if (s == null) return Explanation.noMatch('Hybrid query produced no matches');

    final target = s.advance(docId);
    if (target != docId) return Explanation.noMatch('Doc $docId not in hybrid results');

    return Explanation.match(s.score(), 'HybridQuery match (mode=$fusionMode)');
  }

  @override
  double cost() => lexicalWeight.cost() + vectorWeight.cost();
}

class _HybridListScorer extends Scorer {
  final List<int> docIds;
  final Map<int, double> scores;
  final double boost;
  int _cursor = -1;

  _HybridListScorer({
    required this.docIds,
    required this.scores,
    required this.boost,
  });

  @override
  int get docId {
    if (_cursor < 0 || _cursor >= docIds.length) return Scorer.noMoreDocs;
    return docIds[_cursor];
  }

  @override
  double score() {
    if (_cursor < 0 || _cursor >= docIds.length) return 0.0;
    final id = docIds[_cursor];
    return (scores[id] ?? 0.0) * boost;
  }

  @override
  int nextDoc() {
    _cursor++;
    if (_cursor >= docIds.length) return Scorer.noMoreDocs;
    return docIds[_cursor];
  }

  @override
  int advance(int target) {
    while (_cursor + 1 < docIds.length && docIds[_cursor + 1] < target) {
      _cursor++;
    }
    _cursor++;
    if (_cursor >= docIds.length) return Scorer.noMoreDocs;
    return docIds[_cursor];
  }

  @override
  double cost() => docIds.length.toDouble();
}
