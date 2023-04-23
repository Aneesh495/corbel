import '../index/segment_reader.dart';
import 'boolean_query.dart';
import 'explanation.dart';
import 'query.dart';
import 'scorer.dart';
import 'term_query.dart';

/// Query matching terms in a field based on wildcard glob patterns (* and ?).
class WildcardQuery extends Query {
  final String field;
  final String pattern;
  late final RegExp _regex;

  WildcardQuery({
    required this.field,
    required this.pattern,
    super.boost = 1.0,
  }) {
    _regex = _compileWildcardPattern(pattern);
  }

  static RegExp _compileWildcardPattern(String glob) {
    final buf = StringBuffer('^');
    for (var i = 0; i < glob.length; i++) {
      final ch = glob[i];
      if (ch == '*') {
        buf.write('.*');
      } else if (ch == '?') {
        buf.write('.');
      } else if (r'\.^$|()[]{}+'.contains(ch)) {
        buf.write('\\$ch');
      } else {
        buf.write(ch);
      }
    }
    buf.write(r'$');
    return RegExp(buf.toString());
  }

  @override
  Weight createWeight(IndexSearchContext context, {bool needsScores = true}) {
    return WildcardWeight(
      query: this,
      field: field,
      regex: _regex,
      pattern: pattern,
      context: context,
      needsScores: needsScores,
    );
  }

  @override
  String toString() => '$field:$pattern${boost != 1.0 ? '^$boost' : ''}';
}

/// Weight expanding wildcard glob matches across the segment FST.
class WildcardWeight extends Weight {
  final String field;
  final RegExp regex;
  final String pattern;
  final IndexSearchContext context;
  final bool needsScores;

  const WildcardWeight({
    required WildcardQuery query,
    required this.field,
    required this.regex,
    required this.pattern,
    required this.context,
    required this.needsScores,
  }) : super(query);

  @override
  Scorer? scorer(SegmentReader segmentReader) {
    final fst = segmentReader.getFst(field);
    if (fst == null) return null;

    final matchingEntries = fst.searchMatching((term) => regex.hasMatch(term));
    if (matchingEntries.isEmpty) return null;

    if (matchingEntries.length == 1) {
      final tq = TermQuery(
        field: field,
        term: matchingEntries.first.key,
        boost: query.boost,
      );
      return tq.createWeight(context, needsScores: needsScores).scorer(segmentReader);
    }

    final clauses = matchingEntries.map((e) {
      return BooleanClause(
        query: TermQuery(field: field, term: e.key),
        occur: Occur.should,
      );
    }).toList();

    final bq = BooleanQuery(
      clauses: clauses,
      minimumNumberShouldMatch: 1,
      boost: query.boost,
    );
    return bq.createWeight(context, needsScores: needsScores).scorer(segmentReader);
  }

  @override
  Explanation explain(SegmentReader segmentReader, int docId) {
    final fst = segmentReader.getFst(field);
    if (fst == null) {
      return Explanation.noMatch('Field "$field" not indexed in segment');
    }

    final matches = fst.searchMatching((term) => regex.hasMatch(term));
    if (matches.isEmpty) {
      return Explanation.noMatch('No terms match wildcard "$pattern" in field "$field"');
    }

    final details = <Explanation>[];
    var matched = false;
    var totalScore = 0.0;

    for (final m in matches) {
      final tq = TermQuery(field: field, term: m.key, boost: query.boost);
      final exp = tq.explain(segmentReader, context, docId);
      if (exp.isMatch) {
        details.add(exp);
        matched = true;
        totalScore += exp.value;
      }
    }

    if (!matched) {
      return Explanation.noMatch('WildcardQuery did not match doc $docId');
    }

    return Explanation.match(
      totalScore,
      'WildcardQuery match ($field:$pattern)',
      details,
    );
  }

  @override
  double cost() => 15.0;
}
