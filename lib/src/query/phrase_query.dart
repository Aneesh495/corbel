import 'dart:math' as math;
import '../index/postings/postings_reader.dart';
import '../index/segment_reader.dart';
import 'explanation.dart';
import 'query.dart';
import 'scorer.dart';

/// Positional sequence query matching terms in exact or slop-tolerant order.
class PhraseQuery extends Query {
  final String field;
  final List<String> terms;
  final int slop;

  const PhraseQuery({
    required this.field,
    required this.terms,
    this.slop = 0,
    super.boost = 1.0,
  });

  @override
  Weight createWeight(IndexSearchContext context, {bool needsScores = true}) {
    final totalDocs = context.totalDocumentCount;
    var totalIdf = 0.0;
    for (var i = 0; i < terms.length; i++) {
      final docFreq = context.fieldDocCounts[field] ?? 1;
      final idf = math.max(0.0, math.log(1.0 + (totalDocs - docFreq + 0.5) / (docFreq + 0.5)));
      totalIdf += idf;
    }

    return PhraseWeight(
      query: this,
      field: field,
      terms: terms,
      slop: slop,
      idf: totalIdf,
      needsScores: needsScores,
    );
  }

  @override
  String toString() {
    final phrase = terms.join(' ');
    final slopSuffix = slop > 0 ? '~$slop' : '';
    final boostSuffix = boost != 1.0 ? '^$boost' : '';
    return '$field:"$phrase"$slopSuffix$boostSuffix';
  }
}

/// Weight binding [PhraseQuery] to positional postings readers.
class PhraseWeight extends Weight {
  final String field;
  final List<String> terms;
  final int slop;
  final double idf;
  final bool needsScores;

  const PhraseWeight({
    required PhraseQuery query,
    required this.field,
    required this.terms,
    required this.slop,
    required this.idf,
    required this.needsScores,
  }) : super(query);

  @override
  Scorer? scorer(SegmentReader segmentReader) {
    if (terms.isEmpty) return null;

    final postingsList = <PostingsReader>[];
    for (final term in terms) {
      final p = segmentReader.postings(field, term);
      if (p == null) return null;
      if (!p.storePositions) {
        throw StateError('Field "$field" does not index positions required for PhraseQuery');
      }
      postingsList.add(p);
    }

    return PhraseScorer(
      postingsList: postingsList,
      slop: slop,
      idf: idf,
      boost: query.boost,
      needsScores: needsScores,
    );
  }

  @override
  Explanation explain(SegmentReader segmentReader, int docId) {
    final s = scorer(segmentReader);
    if (s == null) {
      return Explanation.noMatch('Phrase terms not indexed in segment');
    }

    final target = s.advance(docId);
    if (target != docId) {
      return Explanation.noMatch('Document $docId does not match phrase $terms');
    }

    final score = s.score();
    return Explanation.match(
      score,
      'PhraseQuery match for $terms with slop=$slop',
      [
        Explanation.match(idf, 'Combined IDF for phrase terms'),
        Explanation.match(score, 'Calculated phrase score with boost=${query.boost}'),
      ],
    );
  }

  @override
  double cost() => 1.0;
}

/// Scorer that verifies exact or slop-bounded positional adjacency across terms.
class PhraseScorer extends Scorer {
  final List<PostingsReader> postingsList;
  final int slop;
  final double idf;
  final double boost;
  final bool needsScores;

  int _currentDocId = -1;
  int _currentPhraseFreq = 0;
  static const double k1 = 1.2;

  PhraseScorer({
    required this.postingsList,
    required this.slop,
    required this.idf,
    required this.boost,
    required this.needsScores,
  });

  @override
  int get docId => _currentDocId;

  @override
  double score() {
    if (!needsScores) return boost;
    final freq = _currentPhraseFreq;
    final tf = (freq * (k1 + 1.0)) / (freq + k1);
    return boost * idf * tf;
  }

  @override
  int nextDoc() => advance(_currentDocId + 1);

  @override
  int advance(int target) {
    var candidate = target;

    outer:
    while (candidate != Scorer.noMoreDocs) {
      // Leapfrog advance across all term postings to align on same docId
      for (final p in postingsList) {
        if (p.docId < candidate) {
          final advanced = p.advance(candidate);
          if (advanced == Scorer.noMoreDocs) {
            _currentDocId = Scorer.noMoreDocs;
            return Scorer.noMoreDocs;
          }
          if (advanced > candidate) {
            candidate = advanced;
            continue outer;
          }
        }
      }

      // Candidate doc matched across all terms: evaluate phrase positional alignment
      final matchFreq = _countPhraseMatches();
      if (matchFreq > 0) {
        _currentDocId = candidate;
        _currentPhraseFreq = matchFreq;
        return _currentDocId;
      }

      // Not matched positionally, try next doc
      candidate++;
    }

    _currentDocId = Scorer.noMoreDocs;
    return Scorer.noMoreDocs;
  }

  /// Evaluates positions of all terms in the current document to count phrase matches.
  int _countPhraseMatches() {
    if (postingsList.length == 1) {
      return postingsList[0].positions.length;
    }

    if (slop == 0) {
      return _countExactMatches();
    } else {
      return _countSlopMatches();
    }
  }

  /// Exact consecutive match counter (pos[i+1] == pos[i] + 1).
  int _countExactMatches() {
    final firstPositions = postingsList[0].positions;
    var matches = 0;

    for (final startPos in firstPositions) {
      var matched = true;
      for (var i = 1; i < postingsList.length; i++) {
        final expectedPos = startPos + i;
        final targetPositions = postingsList[i].positions;
        if (!_binarySearchContains(targetPositions, expectedPos)) {
          matched = false;
          break;
        }
      }
      if (matched) {
        matches++;
      }
    }

    return matches;
  }

  /// Slop-tolerant phrase match counter.
  int _countSlopMatches() {
    final positions = postingsList.map((p) => p.positions).toList();
    final indices = List<int>.filled(positions.length, 0);
    var matches = 0;

    while (true) {
      // Check if any list exhausted
      for (var i = 0; i < positions.length; i++) {
        if (indices[i] >= positions[i].length) {
          return matches;
        }
      }

      var minPos = positions[0][indices[0]];
      var maxPos = minPos;
      var minIndex = 0;

      for (var i = 1; i < positions.length; i++) {
        final pos = positions[i][indices[i]];
        if (pos < minPos) {
          minPos = pos;
          minIndex = i;
        }
        if (pos > maxPos) {
          maxPos = pos;
        }
      }

      final span = maxPos - minPos;
      final expectedMinSpan = positions.length - 1;
      final matchSlop = span - expectedMinSpan;

      if (matchSlop <= slop && matchSlop >= 0) {
        // Also verify terms appear in monotonic non-decreasing order
        var inOrder = true;
        for (var i = 0; i < positions.length - 1; i++) {
          if (positions[i][indices[i]] >= positions[i + 1][indices[i + 1]]) {
            inOrder = false;
            break;
          }
        }
        if (inOrder) {
          matches++;
        }
      }

      indices[minIndex]++;
    }
  }

  bool _binarySearchContains(List<int> sorted, int target) {
    var low = 0;
    var high = sorted.length - 1;
    while (low <= high) {
      final mid = (low + high) >>> 1;
      final val = sorted[mid];
      if (val == target) return true;
      if (val < target) {
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return false;
  }

  @override
  double cost() {
    var minCost = double.infinity;
    for (final p in postingsList) {
      minCost = math.min(minCost, p.docCount.toDouble());
    }
    return minCost;
  }
}
