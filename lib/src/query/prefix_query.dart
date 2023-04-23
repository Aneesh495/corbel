import '../index/segment_reader.dart';
import 'boolean_query.dart';
import 'explanation.dart';
import 'query.dart';
import 'scorer.dart';
import 'term_query.dart';

/// Query matching all terms in a field beginning with a specified prefix.
class PrefixQuery extends Query {
  final String field;
  final String prefix;

  const PrefixQuery({
    required this.field,
    required this.prefix,
    super.boost = 1.0,
  });

  @override
  Weight createWeight(IndexSearchContext context, {bool needsScores = true}) {
    return PrefixWeight(
      query: this,
      field: field,
      prefix: prefix,
      context: context,
      needsScores: needsScores,
    );
  }

  @override
  String toString() => '$field:$prefix*${boost != 1.0 ? '^$boost' : ''}';
}

/// Weight for [PrefixQuery] expanding terms dynamically per segment reader.
class PrefixWeight extends Weight {
  final String field;
  final String prefix;
  final IndexSearchContext context;
  final bool needsScores;

  const PrefixWeight({
    required PrefixQuery query,
    required this.field,
    required this.prefix,
    required this.context,
    required this.needsScores,
  }) : super(query);

  @override
  Scorer? scorer(SegmentReader segmentReader) {
    final fst = segmentReader.getFst(field);
    if (fst == null) return null;

    final matchingEntries = fst.prefixSearch(prefix);
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

    final matches = fst.prefixSearch(prefix);
    if (matches.isEmpty) {
      return Explanation.noMatch('No terms match prefix "$prefix" in field "$field"');
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
      return Explanation.noMatch('PrefixQuery did not match doc $docId');
    }

    return Explanation.match(
      totalScore,
      'PrefixQuery match ($field:$prefix*)',
      details,
    );
  }

  @override
  double cost() => 10.0;
}
