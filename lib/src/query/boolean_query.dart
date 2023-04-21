import 'dart:math' as math;
import '../index/segment_reader.dart';
import 'explanation.dart';
import 'query.dart';
import 'scorer.dart';

/// Clause occurrence operators defining Boolean evaluation semantics.
enum Occur {
  /// Must appear in matching documents and contributes to relevance score.
  must,

  /// May appear in matching documents and contributes to score if present.
  should,

  /// Must not appear in matching documents. Excludes matching documents.
  mustNot,

  /// Must appear in matching documents but does not contribute to score.
  filter,
}

/// Single clause in a [BooleanQuery].
class BooleanClause {
  final Query query;
  final Occur occur;

  const BooleanClause({
    required this.query,
    required this.occur,
  });

  @override
  String toString() {
    final prefix = switch (occur) {
      Occur.must => '+',
      Occur.should => '',
      Occur.mustNot => '-',
      Occur.filter => '#',
    };
    return '$prefix$query';
  }
}

/// Composite query combining multiple clauses with Boolean logic.
class BooleanQuery extends Query {
  final List<BooleanClause> clauses;
  final int minimumNumberShouldMatch;

  const BooleanQuery({
    required this.clauses,
    this.minimumNumberShouldMatch = 0,
    super.boost = 1.0,
  });

  @override
  Weight createWeight(IndexSearchContext context, {bool needsScores = true}) {
    final clauseWeights = <Occur, List<Weight>>{
      Occur.must: [],
      Occur.should: [],
      Occur.mustNot: [],
      Occur.filter: [],
    };

    for (final clause in clauses) {
      final w = clause.query.createWeight(
        context,
        needsScores: needsScores && (clause.occur == Occur.must || clause.occur == Occur.should),
      );
      clauseWeights[clause.occur]!.add(w);
    }

    return BooleanWeight(
      query: this,
      clauseWeights: clauseWeights,
      minimumShouldMatch: minimumNumberShouldMatch,
      needsScores: needsScores,
    );
  }

  @override
  String toString() {
    final body = clauses.map((c) => c.toString()).join(' ');
    return '($body)${boost != 1.0 ? '^$boost' : ''}';
  }
}

/// Weight managing Boolean clause weights and compiling segment scorers.
class BooleanWeight extends Weight {
  final Map<Occur, List<Weight>> clauseWeights;
  final int minimumShouldMatch;
  final bool needsScores;

  const BooleanWeight({
    required BooleanQuery query,
    required this.clauseWeights,
    required this.minimumShouldMatch,
    required this.needsScores,
  }) : super(query);

  @override
  Scorer? scorer(SegmentReader segmentReader) {
    final mustScorers = <Scorer>[];
    for (final w in clauseWeights[Occur.must]!) {
      final s = w.scorer(segmentReader);
      if (s == null) return null; // MUST clause missing means empty result
      mustScorers.add(s);
    }

    final filterScorers = <Scorer>[];
    for (final w in clauseWeights[Occur.filter]!) {
      final s = w.scorer(segmentReader);
      if (s == null) return null; // FILTER clause missing means empty result
      filterScorers.add(s);
    }

    final mustNotScorers = <Scorer>[];
    for (final w in clauseWeights[Occur.mustNot]!) {
      final s = w.scorer(segmentReader);
      if (s != null) mustNotScorers.add(s);
    }

    final shouldScorers = <Scorer>[];
    for (final w in clauseWeights[Occur.should]!) {
      final s = w.scorer(segmentReader);
      if (s != null) shouldScorers.add(s);
    }

    // Validation: if no clauses exist, or required clauses cannot be met
    final hasMustOrFilter = mustScorers.isNotEmpty || filterScorers.isNotEmpty;
    if (!hasMustOrFilter && shouldScorers.isEmpty) {
      return null;
    }

    final effectiveMinShould = !hasMustOrFilter
        ? math.max(1, minimumShouldMatch)
        : minimumShouldMatch;

    if (shouldScorers.length < effectiveMinShould) {
      return null;
    }

    return BooleanScorer(
      mustScorers: mustScorers,
      filterScorers: filterScorers,
      mustNotScorers: mustNotScorers,
      shouldScorers: shouldScorers,
      minimumShouldMatch: effectiveMinShould,
      boost: query.boost,
      needsScores: needsScores,
    );
  }

  @override
  Explanation explain(SegmentReader segmentReader, int docId) {
    final details = <Explanation>[];
    var totalScore = 0.0;
    var matches = true;

    // Check MUST clauses
    for (final w in clauseWeights[Occur.must]!) {
      final exp = w.explain(segmentReader, docId);
      details.add(exp);
      if (!exp.isMatch) matches = false;
      totalScore += exp.value;
    }

    // Check FILTER clauses
    for (final w in clauseWeights[Occur.filter]!) {
      final exp = w.explain(segmentReader, docId);
      details.add(exp);
      if (!exp.isMatch) matches = false;
    }

    // Check MUST_NOT clauses
    for (final w in clauseWeights[Occur.mustNot]!) {
      final exp = w.explain(segmentReader, docId);
      if (exp.isMatch) {
        details.add(Explanation.noMatch('Matched forbidden MUST_NOT clause: ${w.query}'));
        matches = false;
      }
    }

    // Check SHOULD clauses
    var shouldMatchCount = 0;
    for (final w in clauseWeights[Occur.should]!) {
      final exp = w.explain(segmentReader, docId);
      details.add(exp);
      if (exp.isMatch) {
        shouldMatchCount++;
        totalScore += exp.value;
      }
    }

    final hasMust = clauseWeights[Occur.must]!.isNotEmpty || clauseWeights[Occur.filter]!.isNotEmpty;
    final minShould = !hasMust ? math.max(1, minimumShouldMatch) : minimumShouldMatch;

    if (shouldMatchCount < minShould) {
      matches = false;
    }

    if (!matches) {
      return Explanation.noMatch('BooleanQuery did not match doc $docId', details);
    }

    final finalScore = totalScore * query.boost;
    return Explanation.match(
      finalScore,
      'BooleanQuery match (score=$finalScore, boost=${query.boost})',
      details,
    );
  }

  @override
  double cost() {
    var minCost = double.infinity;
    for (final w in clauseWeights[Occur.must]!) {
      minCost = math.min(minCost, w.cost());
    }
    for (final w in clauseWeights[Occur.filter]!) {
      minCost = math.min(minCost, w.cost());
    }
    if (minCost < double.infinity) return minCost;

    var sumShould = 0.0;
    for (final w in clauseWeights[Occur.should]!) {
      sumShould += w.cost();
    }
    return sumShould;
  }
}

/// Execution scorer coordinating conjunction, disjunction, and exclusion.
class BooleanScorer extends Scorer {
  final List<Scorer> mustScorers;
  final List<Scorer> filterScorers;
  final List<Scorer> mustNotScorers;
  final List<Scorer> shouldScorers;
  final int minimumShouldMatch;
  final double boost;
  final bool needsScores;

  int _currentDocId = -1;
  late final List<Scorer> _requiredScorers;

  BooleanScorer({
    required this.mustScorers,
    required this.filterScorers,
    required this.mustNotScorers,
    required this.shouldScorers,
    required this.minimumShouldMatch,
    required this.boost,
    required this.needsScores,
  }) {
    _requiredScorers = [...mustScorers, ...filterScorers];
  }

  @override
  int get docId => _currentDocId;

  @override
  double score() {
    if (!needsScores) return boost;
    var total = 0.0;
    for (final s in mustScorers) {
      if (s.docId == _currentDocId) {
        total += s.score();
      }
    }
    for (final s in shouldScorers) {
      if (s.docId == _currentDocId) {
        total += s.score();
      }
    }
    return total * boost;
  }

  @override
  int nextDoc() => advance(_currentDocId + 1);

  @override
  int advance(int target) {
    if (_requiredScorers.isNotEmpty) {
      return _advanceConjunction(target);
    } else {
      return _advanceDisjunction(target);
    }
  }

  /// Conjunction leapfrog advance algorithm.
  int _advanceConjunction(int target) {
    var candidate = target;

    outer:
    while (candidate != Scorer.noMoreDocs) {
      for (final scorer in _requiredScorers) {
        if (scorer.docId < candidate) {
          final advanced = scorer.advance(candidate);
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

      // Check MUST_NOT exclusion
      if (_isExcluded(candidate)) {
        candidate++;
        continue;
      }

      // Check minimumShouldMatch
      if (minimumShouldMatch > 0) {
        var matchCount = 0;
        for (final s in shouldScorers) {
          if (s.docId < candidate) s.advance(candidate);
          if (s.docId == candidate) matchCount++;
        }
        if (matchCount < minimumShouldMatch) {
          candidate++;
          continue;
        }
      }

      _currentDocId = candidate;
      return _currentDocId;
    }

    _currentDocId = Scorer.noMoreDocs;
    return Scorer.noMoreDocs;
  }

  /// Disjunction leapfrog advance algorithm across SHOULD clauses.
  int _advanceDisjunction(int target) {
    var candidate = target;

    while (candidate != Scorer.noMoreDocs) {
      var minDoc = Scorer.noMoreDocs;
      var matchCount = 0;

      for (final s in shouldScorers) {
        if (s.docId < candidate) {
          s.advance(candidate);
        }
        if (s.docId < minDoc) {
          minDoc = s.docId;
        }
        if (s.docId == candidate) {
          matchCount++;
        }
      }

      if (minDoc == Scorer.noMoreDocs) {
        _currentDocId = Scorer.noMoreDocs;
        return Scorer.noMoreDocs;
      }

      if (minDoc > candidate) {
        candidate = minDoc;
        continue;
      }

      if (matchCount >= minimumShouldMatch && !_isExcluded(candidate)) {
        _currentDocId = candidate;
        return _currentDocId;
      }

      candidate++;
    }

    _currentDocId = Scorer.noMoreDocs;
    return Scorer.noMoreDocs;
  }

  bool _isExcluded(int doc) {
    for (final s in mustNotScorers) {
      if (s.docId < doc) s.advance(doc);
      if (s.docId == doc) return true;
    }
    return false;
  }

  @override
  double cost() {
    if (_requiredScorers.isNotEmpty) {
      var c = double.infinity;
      for (final s in _requiredScorers) {
        c = math.min(c, s.cost());
      }
      return c;
    }
    var sum = 0.0;
    for (final s in shouldScorers) {
      sum += s.cost();
    }
    return sum;
  }
}
