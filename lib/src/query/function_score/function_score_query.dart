import 'dart:math' as math;
import '../../index/segment_reader.dart';
import '../explanation.dart';
import '../query.dart';
import '../scorer.dart';
import 'score_functions.dart';

/// Method used to combine scores computed by multiple score functions.
enum ScoreMode {
  multiply,
  sum,
  avg,
  first,
  max,
  min,
}

/// Method used to combine the sub-query relevance score with the final function score.
enum BoostMode {
  multiply,
  replace,
  sum,
  avg,
  max,
  min,
}

/// Query modifying base relevance scores using custom mathematical score functions.
class FunctionScoreQuery extends Query {
  final Query query;
  final List<ScoreFunction> functions;
  final ScoreMode scoreMode;
  final BoostMode boostMode;
  final double? maxBoost;
  final double? minScore;

  const FunctionScoreQuery({
    required this.query,
    required this.functions,
    this.scoreMode = ScoreMode.multiply,
    this.boostMode = BoostMode.multiply,
    this.maxBoost,
    this.minScore,
    super.boost = 1.0,
  });

  @override
  Weight createWeight(IndexSearchContext context, {bool needsScores = true}) {
    final subWeight = query.createWeight(context, needsScores: needsScores);
    return FunctionScoreWeight(
      query: this,
      subWeight: subWeight,
      functions: functions,
      scoreMode: scoreMode,
      boostMode: boostMode,
      maxBoost: maxBoost,
      minScore: minScore,
    );
  }

  @override
  String toString() =>
      'FunctionScore($query, functions: ${functions.length}, boostMode: ${boostMode.name})';
}

/// Weight binding [FunctionScoreQuery] to segment readers.
class FunctionScoreWeight extends Weight {
  final Weight subWeight;
  final List<ScoreFunction> functions;
  final ScoreMode scoreMode;
  final BoostMode boostMode;
  final double? maxBoost;
  final double? minScore;

  const FunctionScoreWeight({
    required FunctionScoreQuery query,
    required this.subWeight,
    required this.functions,
    required this.scoreMode,
    required this.boostMode,
    this.maxBoost,
    this.minScore,
  }) : super(query);

  @override
  Scorer? scorer(SegmentReader segmentReader) {
    final subScorer = subWeight.scorer(segmentReader);
    if (subScorer == null) return null;

    return _FunctionScorer(
      subScorer: subScorer,
      segmentReader: segmentReader,
      functions: functions,
      scoreMode: scoreMode,
      boostMode: boostMode,
      maxBoost: maxBoost,
      minScore: minScore,
      boost: query.boost,
    );
  }

  @override
  Explanation explain(SegmentReader segmentReader, int docId) {
    final subExplain = subWeight.explain(segmentReader, docId);
    if (!subExplain.isMatch) return subExplain;

    final baseScore = subExplain.value;
    final fnScore = _computeFunctionsScore(segmentReader, docId, baseScore);
    final finalScore = _combineScores(baseScore, fnScore);

    return Explanation.match(
      finalScore,
      'FunctionScoreQuery (base: $baseScore, function: $fnScore, combined: $finalScore)',
      [subExplain],
    );
  }

  double _computeFunctionsScore(
    SegmentReader reader,
    int docId,
    double baseScore,
  ) {
    if (functions.isEmpty) return 1.0;

    final scores = functions
        .map((fn) => fn.score(reader, docId, baseScore))
        .toList();

    double result;
    switch (scoreMode) {
      case ScoreMode.multiply:
        result = scores.fold(1.0, (a, b) => a * b);
        break;
      case ScoreMode.sum:
        result = scores.fold(0.0, (a, b) => a + b);
        break;
      case ScoreMode.avg:
        result = scores.fold(0.0, (a, b) => a + b) / scores.length;
        break;
      case ScoreMode.first:
        result = scores.first;
        break;
      case ScoreMode.max:
        result = scores.reduce((a, b) => math.max(a, b));
        break;
      case ScoreMode.min:
        result = scores.reduce((a, b) => math.min(a, b));
        break;
    }

    if (maxBoost != null && result > maxBoost!) {
      result = maxBoost!;
    }
    return result;
  }

  double _combineScores(double subScore, double fnScore) {
    double combined;
    switch (boostMode) {
      case BoostMode.multiply:
        combined = subScore * fnScore;
        break;
      case BoostMode.replace:
        combined = fnScore;
        break;
      case BoostMode.sum:
        combined = subScore + fnScore;
        break;
      case BoostMode.avg:
        combined = (subScore + fnScore) / 2.0;
        break;
      case BoostMode.max:
        combined = math.max(subScore, fnScore);
        break;
      case BoostMode.min:
        combined = math.min(subScore, fnScore);
        break;
    }
    return combined * query.boost;
  }

  @override
  double cost() => subWeight.cost();
}

class _FunctionScorer extends Scorer {
  final Scorer subScorer;
  final SegmentReader segmentReader;
  final List<ScoreFunction> functions;
  final ScoreMode scoreMode;
  final BoostMode boostMode;
  final double? maxBoost;
  final double? minScore;
  final double boost;

  double _currentScore = 0.0;

  _FunctionScorer({
    required this.subScorer,
    required this.segmentReader,
    required this.functions,
    required this.scoreMode,
    required this.boostMode,
    this.maxBoost,
    this.minScore,
    required this.boost,
  });

  @override
  int get docId => subScorer.docId;

  @override
  int nextDoc() {
    var d = subScorer.nextDoc();
    while (d != Scorer.noMoreDocs) {
      if (_evaluateScore()) {
        return d;
      }
      d = subScorer.nextDoc();
    }
    return Scorer.noMoreDocs;
  }

  @override
  int advance(int target) {
    var d = subScorer.advance(target);
    while (d != Scorer.noMoreDocs) {
      if (_evaluateScore()) {
        return d;
      }
      d = subScorer.nextDoc();
    }
    return Scorer.noMoreDocs;
  }

  bool _evaluateScore() {
    final baseScore = subScorer.score();
    var fnScore = 1.0;

    if (functions.isNotEmpty) {
      final scores = functions
          .map((fn) => fn.score(segmentReader, docId, baseScore))
          .toList();

      switch (scoreMode) {
        case ScoreMode.multiply:
          fnScore = scores.fold(1.0, (a, b) => a * b);
          break;
        case ScoreMode.sum:
          fnScore = scores.fold(0.0, (a, b) => a + b);
          break;
        case ScoreMode.avg:
          fnScore = scores.fold(0.0, (a, b) => a + b) / scores.length;
          break;
        case ScoreMode.first:
          fnScore = scores.first;
          break;
        case ScoreMode.max:
          fnScore = scores.reduce((a, b) => math.max(a, b));
          break;
        case ScoreMode.min:
          fnScore = scores.reduce((a, b) => math.min(a, b));
          break;
      }

      if (maxBoost != null && fnScore > maxBoost!) {
        fnScore = maxBoost!;
      }
    }

    double finalScore;
    switch (boostMode) {
      case BoostMode.multiply:
        finalScore = baseScore * fnScore;
        break;
      case BoostMode.replace:
        finalScore = fnScore;
        break;
      case BoostMode.sum:
        finalScore = baseScore + fnScore;
        break;
      case BoostMode.avg:
        finalScore = (baseScore + fnScore) / 2.0;
        break;
      case BoostMode.max:
        finalScore = math.max(baseScore, fnScore);
        break;
      case BoostMode.min:
        finalScore = math.min(baseScore, fnScore);
        break;
    }

    _currentScore = finalScore * boost;
    if (minScore != null && _currentScore < minScore!) {
      return false; // Prune match below minScore threshold
    }
    return true;
  }

  @override
  double score() => _currentScore;

  @override
  double cost() => subScorer.cost();
}
