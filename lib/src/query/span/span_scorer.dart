import '../scorer.dart';
import 'spans.dart';

/// Scores documents matching a SpanQuery by aggregating span occurrences and compactness.
class SpanScorer extends Scorer {
  final Spans spans;
  final double boost;

  int _docId = -1;
  double _score = 0.0;
  int _matchCount = 0;

  SpanScorer({
    required this.spans,
    this.boost = 1.0,
  });

  @override
  int get docId => _docId;

  @override
  int nextDoc() {
    _docId = spans.nextDoc();
    if (_docId != Scorer.noMoreDocs) {
      _calculateScore();
    }
    return _docId;
  }

  @override
  int advance(int target) {
    _docId = spans.advance(target);
    if (_docId != Scorer.noMoreDocs) {
      _calculateScore();
    }
    return _docId;
  }

  void _calculateScore() {
    _matchCount = 0;
    var totalCompactness = 0.0;

    while (spans.nextStartPosition() != Spans.noMorePositions) {
      _matchCount++;
      final width = spans.width();
      // Compactness weight: tighter spans score higher
      totalCompactness += 1.0 / (1.0 + width);
    }

    if (_matchCount == 0) {
      _score = 0.0;
    } else {
      // Score combining span frequency and compactness
      _score = boost * (totalCompactness + 0.5 * _matchCount);
    }
  }

  @override
  double score() => _score;

  int get matchCount => _matchCount;

  @override
  double cost() => spans.cost();
}
