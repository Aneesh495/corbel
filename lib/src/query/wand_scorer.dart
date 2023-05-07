import 'scorer.dart';

/// Scorer wrapper pairing a sub-scorer with its static or dynamic maximum upper-bound score.
class WandScorerEntry {
  final Scorer scorer;
  final double maxScore;

  WandScorerEntry({
    required this.scorer,
    required this.maxScore,
  });
}

/// Weak AND (WAND) dynamic pruning scorer for fast top-k candidate retrieval.
///
/// Implements Broder et al. WAND optimization to leapfrog non-competitive documents
/// whose cumulative upper-bound scores cannot exceed the dynamic top-k threshold.
class WandScorer extends Scorer {
  final List<WandScorerEntry> _entries;
  double threshold;
  final double boost;

  int _currentDocId = -1;

  WandScorer({
    required List<WandScorerEntry> entries,
    this.threshold = 0.0,
    this.boost = 1.0,
  }) : _entries = List.of(entries);

  /// Dynamically updates the pruning threshold as top-k priority queues fill up.
  void updateThreshold(double newThreshold) {
    if (newThreshold > threshold) {
      threshold = newThreshold;
    }
  }

  @override
  int get docId => _currentDocId;

  @override
  double score() {
    var total = 0.0;
    for (final entry in _entries) {
      if (entry.scorer.docId == _currentDocId) {
        total += entry.scorer.score();
      }
    }
    return total * boost;
  }

  @override
  int nextDoc() => advance(_currentDocId + 1);

  @override
  int advance(int target) {
    var candidate = target;

    while (true) {
      // 1. Advance all active scorers with docId < candidate
      for (final entry in _entries) {
        if (entry.scorer.docId < candidate) {
          entry.scorer.advance(candidate);
        }
      }

      // 2. Sort entries by docId ascending
      _entries.sort((a, b) => a.scorer.docId.compareTo(b.scorer.docId));

      // Check if all scorers exhausted
      if (_entries.first.scorer.docId == Scorer.noMoreDocs) {
        _currentDocId = Scorer.noMoreDocs;
        return Scorer.noMoreDocs;
      }

      // 3. Find pivot index where cumulative maxScore reaches threshold
      var accumulatedScore = 0.0;
      var pivotIndex = -1;

      for (var i = 0; i < _entries.length; i++) {
        if (_entries[i].scorer.docId == Scorer.noMoreDocs) break;
        accumulatedScore += _entries[i].maxScore * boost;
        if (accumulatedScore >= threshold) {
          pivotIndex = i;
          break;
        }
      }

      // Threshold is unreachable even with all remaining posting lists
      if (pivotIndex == -1) {
        _currentDocId = Scorer.noMoreDocs;
        return Scorer.noMoreDocs;
      }

      final pivotDoc = _entries[pivotIndex].scorer.docId;

      // 4. If lead scorer is aligned with pivot doc, evaluate candidate
      if (_entries[0].scorer.docId == pivotDoc) {
        _currentDocId = pivotDoc;
        final exactScore = score();
        if (exactScore >= threshold) {
          return _currentDocId;
        }
        // Score did not meet threshold upon exact evaluation, advance lead
        candidate = pivotDoc + 1;
      } else {
        // Leapfrog: advance lead scorer directly to pivotDoc
        _entries[0].scorer.advance(pivotDoc);
        candidate = pivotDoc;
      }
    }
  }

  @override
  double cost() {
    var sum = 0.0;
    for (final e in _entries) {
      sum += e.scorer.cost();
    }
    return sum;
  }
}
