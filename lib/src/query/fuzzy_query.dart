import 'dart:math' as math;
import '../index/segment_reader.dart';
import 'boolean_query.dart';
import 'explanation.dart';
import 'query.dart';
import 'scorer.dart';
import 'term_query.dart';

/// Approximate string matching query using Levenshtein edit distance.
class FuzzyQuery extends Query {
  final String field;
  final String term;
  final int maxEdits;
  final int prefixLength;

  const FuzzyQuery({
    required this.field,
    required this.term,
    this.maxEdits = 2,
    this.prefixLength = 0,
    super.boost = 1.0,
  }) : assert(maxEdits >= 0 && maxEdits <= 2, 'maxEdits must be between 0 and 2');

  @override
  Weight createWeight(IndexSearchContext context, {bool needsScores = true}) {
    return FuzzyWeight(
      query: this,
      field: field,
      term: term,
      maxEdits: maxEdits,
      prefixLength: prefixLength,
      context: context,
      needsScores: needsScores,
    );
  }

  @override
  String toString() {
    final prefixSuffix = prefixLength > 0 ? ',prefix=$prefixLength' : '';
    final boostSuffix = boost != 1.0 ? '^$boost' : '';
    return '$field:$term~$maxEdits$prefixSuffix$boostSuffix';
  }
}

/// Weight executing fuzzy term expansion across the segment FST.
class FuzzyWeight extends Weight {
  final String field;
  final String term;
  final int maxEdits;
  final int prefixLength;
  final IndexSearchContext context;
  final bool needsScores;

  const FuzzyWeight({
    required FuzzyQuery query,
    required this.field,
    required this.term,
    required this.maxEdits,
    required this.prefixLength,
    required this.context,
    required this.needsScores,
  }) : super(query);

  @override
  Scorer? scorer(SegmentReader segmentReader) {
    final fst = segmentReader.getFst(field);
    if (fst == null) return null;

    final candidates = fst.fuzzySearch(term, maxEdits);
    if (candidates.isEmpty) return null;

    final prefix = prefixLength > 0 && prefixLength <= term.length
        ? term.substring(0, prefixLength)
        : null;

    final matchingClauses = <BooleanClause>[];
    for (final entry in candidates) {
      final candidateTerm = entry.key;
      if (prefix != null && !candidateTerm.startsWith(prefix)) {
        continue;
      }

      final dist = _levenshtein(term, candidateTerm);
      if (dist > maxEdits) continue;

      final similarity = 1.0 - (dist / math.max(term.length, candidateTerm.length));
      final termBoost = query.boost * similarity;

      matchingClauses.add(BooleanClause(
        query: TermQuery(field: field, term: candidateTerm, boost: termBoost),
        occur: Occur.should,
      ));
    }

    if (matchingClauses.isEmpty) return null;

    final bq = BooleanQuery(
      clauses: matchingClauses,
      minimumNumberShouldMatch: 1,
      boost: query.boost,
    );
    return bq.createWeight(context, needsScores: needsScores).scorer(segmentReader);
  }

  @override
  Explanation explain(SegmentReader segmentReader, int docId) {
    final s = scorer(segmentReader);
    if (s == null) {
      return Explanation.noMatch('No terms matched fuzzy query "$term" in field "$field"');
    }

    final target = s.advance(docId);
    if (target != docId) {
      return Explanation.noMatch('Document $docId does not match fuzzy term "$term"');
    }

    final score = s.score();
    return Explanation.match(
      score,
      'FuzzyQuery match for "$term" (maxEdits=$maxEdits, prefixLength=$prefixLength)',
    );
  }

  static int _levenshtein(String s1, String s2) {
    if (s1 == s2) return 0;
    if (s1.isEmpty) return s2.length;
    if (s2.isEmpty) return s1.length;

    var prev = List<int>.generate(s2.length + 1, (i) => i);
    var curr = List<int>.filled(s2.length + 1, 0);

    for (var i = 0; i < s1.length; i++) {
      curr[0] = i + 1;
      for (var j = 0; j < s2.length; j++) {
        final cost = s1.codeUnitAt(i) == s2.codeUnitAt(j) ? 0 : 1;
        final deletion = prev[j + 1] + 1;
        final insertion = curr[j] + 1;
        final substitution = prev[j] + cost;
        var m = deletion < insertion ? deletion : insertion;
        if (substitution < m) m = substitution;
        curr[j + 1] = m;
      }
      final temp = prev;
      prev = curr;
      curr = temp;
    }

    return prev[s2.length];
  }

  @override
  double cost() => 20.0;
}
