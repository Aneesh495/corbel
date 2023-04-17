/// Abstract contract for query execution over segment postings and doc values.
abstract class Scorer {
  /// Sentinel document ID returned when the postings list is exhausted.
  static const int noMoreDocs = 0x7FFFFFFF;

  /// Current document ID.
  int get docId;

  /// Calculates relevance score for the current document.
  double score();

  /// Advances to the next matching document ID.
  int nextDoc();

  /// Leaps forward to the first document with docId >= [target].
  int advance(int target);

  /// Estimated cost (number of matching docs) for query optimization.
  double cost();
}

/// Constant score scorer wrapping matching document iterations.
class ConstantScoreScorer extends Scorer {
  final int Function() _nextDocFn;
  final int Function(int target) _advanceFn;
  final int Function() _docIdFn;
  final double Function() _costFn;
  final double boost;

  ConstantScoreScorer({
    required int Function() nextDoc,
    required int Function(int target) advance,
    required int Function() docId,
    required double Function() cost,
    this.boost = 1.0,
  })  : _nextDocFn = nextDoc,
        _advanceFn = advance,
        _docIdFn = docId,
        _costFn = cost;

  @override
  int get docId => _docIdFn();

  @override
  double score() => boost;

  @override
  int nextDoc() => _nextDocFn();

  @override
  int advance(int target) => _advanceFn(target);

  @override
  double cost() => _costFn();
}

/// No-op empty scorer for non-matching queries.
class EmptyScorer extends Scorer {
  @override
  int get docId => Scorer.noMoreDocs;

  @override
  double score() => 0.0;

  @override
  int nextDoc() => Scorer.noMoreDocs;

  @override
  int advance(int target) => Scorer.noMoreDocs;

  @override
  double cost() => 0.0;
}
