import '../index/segment_reader.dart';
import 'explanation.dart';
import 'query.dart';
import 'scorer.dart';

/// Disjunction max query that generates the maximum score of its sub-queries, plus
/// a tie-breaker multiplier for any additional matching sub-queries.
class DisjunctionMaxQuery extends Query {
  final List<Query> disjuncts;
  final double tieBreakerMultiplier;

  const DisjunctionMaxQuery({
    required this.disjuncts,
    this.tieBreakerMultiplier = 0.0,
    super.boost = 1.0,
  }) : assert(tieBreakerMultiplier >= 0.0 && tieBreakerMultiplier <= 1.0,
            'tieBreakerMultiplier must be between 0.0 and 1.0');

  @override
  Weight createWeight(IndexSearchContext context, {bool needsScores = true}) {
    final weights = disjuncts
        .map((q) => q.createWeight(context, needsScores: needsScores))
        .toList();

    return DisjunctionMaxWeight(
      query: this,
      weights: weights,
      tieBreakerMultiplier: tieBreakerMultiplier,
      needsScores: needsScores,
    );
  }

  @override
  String toString() {
    final body = disjuncts.map((d) => d.toString()).join(' | ');
    final tieSuffix = tieBreakerMultiplier > 0.0 ? '~$tieBreakerMultiplier' : '';
    final boostSuffix = boost != 1.0 ? '^$boost' : '';
    return '($body)$tieSuffix$boostSuffix';
  }
}

/// Weight compiling DisMax sub-weights into a max-scoring disjunction.
class DisjunctionMaxWeight extends Weight {
  final List<Weight> weights;
  final double tieBreakerMultiplier;
  final bool needsScores;

  const DisjunctionMaxWeight({
    required DisjunctionMaxQuery query,
    required this.weights,
    required this.tieBreakerMultiplier,
    required this.needsScores,
  }) : super(query);

  @override
  Scorer? scorer(SegmentReader segmentReader) {
    final scorers = <Scorer>[];
    for (final w in weights) {
      final s = w.scorer(segmentReader);
      if (s != null) {
        scorers.add(s);
      }
    }

    if (scorers.isEmpty) return null;

    return DisjunctionMaxScorer(
      scorers: scorers,
      tieBreakerMultiplier: tieBreakerMultiplier,
      boost: query.boost,
      needsScores: needsScores,
    );
  }

  @override
  Explanation explain(SegmentReader segmentReader, int docId) {
    var maxScore = 0.0;
    var otherScoreSum = 0.0;
    final details = <Explanation>[];
    var matched = false;

    for (final w in weights) {
      final exp = w.explain(segmentReader, docId);
      details.add(exp);
      if (exp.isMatch) {
        matched = true;
        if (exp.value > maxScore) {
          otherScoreSum += maxScore;
          maxScore = exp.value;
        } else {
          otherScoreSum += exp.value;
        }
      }
    }

    if (!matched) {
      return Explanation.noMatch('DisjunctionMaxQuery did not match doc $docId', details);
    }

    final totalScore = (maxScore + otherScoreSum * tieBreakerMultiplier) * query.boost;
    return Explanation.match(
      totalScore,
      'DisMax match (max=$maxScore, tieBreaker=$tieBreakerMultiplier, otherSum=$otherScoreSum)',
      details,
    );
  }

  @override
  double cost() {
    var sum = 0.0;
    for (final w in weights) {
      sum += w.cost();
    }
    return sum;
  }
}

/// Scorer that tracks maximum score across active disjuncts with tie breaking.
class DisjunctionMaxScorer extends Scorer {
  final List<Scorer> scorers;
  final double tieBreakerMultiplier;
  final double boost;
  final bool needsScores;

  int _currentDocId = -1;

  DisjunctionMaxScorer({
    required this.scorers,
    required this.tieBreakerMultiplier,
    required this.boost,
    required this.needsScores,
  });

  @override
  int get docId => _currentDocId;

  @override
  double score() {
    if (!needsScores) return boost;

    var maxScore = 0.0;
    var otherSum = 0.0;

    for (final s in scorers) {
      if (s.docId == _currentDocId) {
        final subScore = s.score();
        if (subScore > maxScore) {
          otherSum += maxScore;
          maxScore = subScore;
        } else {
          otherSum += subScore;
        }
      }
    }

    return (maxScore + otherSum * tieBreakerMultiplier) * boost;
  }

  @override
  int nextDoc() => advance(_currentDocId + 1);

  @override
  int advance(int target) {
    var minDoc = Scorer.noMoreDocs;

    for (final s in scorers) {
      if (s.docId < target) {
        s.advance(target);
      }
      if (s.docId < minDoc) {
        minDoc = s.docId;
      }
    }

    _currentDocId = minDoc;
    return _currentDocId;
  }

  @override
  double cost() {
    var sum = 0.0;
    for (final s in scorers) {
      sum += s.cost();
    }
    return sum;
  }
}
