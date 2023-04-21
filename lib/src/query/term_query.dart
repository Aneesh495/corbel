import 'dart:math' as math;
import '../index/postings/postings_reader.dart';
import '../index/segment_reader.dart';
import 'explanation.dart';
import 'query.dart';
import 'scorer.dart';

/// Exact term match query over an inverted index field.
class TermQuery extends Query {
  final String field;
  final String term;

  const TermQuery({
    required this.field,
    required this.term,
    super.boost = 1.0,
  });

  @override
  Weight createWeight(IndexSearchContext context, {bool needsScores = true}) {
    // Robertson-Spärck Jones IDF calculation
    final totalDocs = context.totalDocumentCount;
    final docFreq = context.fieldDocCounts[field] ?? 1;
    final idf = needsScores
        ? math.max(0.0, math.log(1.0 + (totalDocs - docFreq + 0.5) / (docFreq + 0.5)))
        : 1.0;

    return TermWeight(
      query: this,
      field: field,
      term: term,
      idf: idf,
      needsScores: needsScores,
    );
  }

  @override
  String toString() => '$field:$term${boost != 1.0 ? '^$boost' : ''}';
}

/// Weight binding [TermQuery] to segment postings readers.
class TermWeight extends Weight {
  final String field;
  final String term;
  final double idf;
  final bool needsScores;

  const TermWeight({
    required TermQuery query,
    required this.field,
    required this.term,
    required this.idf,
    required this.needsScores,
  }) : super(query);

  @override
  Scorer? scorer(SegmentReader segmentReader) {
    final postings = segmentReader.postings(field, term);
    if (postings == null) return null;

    final docValues = segmentReader.getNumericDocValues(field);
    return TermScorer(
      postings: postings,
      docValues: docValues,
      idf: idf,
      boost: query.boost,
      needsScores: needsScores,
    );
  }

  @override
  Explanation explain(SegmentReader segmentReader, int docId) {
    final postings = segmentReader.postings(field, term);
    if (postings == null) {
      return Explanation.noMatch('Field "$field" term "$term" does not exist in segment');
    }

    final target = postings.advance(docId);
    if (target != docId) {
      return Explanation.noMatch('Document $docId does not match term "$term"');
    }

    final freq = postings.freq;
    final k1 = 1.2;
    final b = 0.75;
    final tf = (freq * (k1 + 1.0)) / (freq + k1);
    final score = query.boost * idf * tf;

    return Explanation.match(
      score,
      'TermQuery score (field=$field, term=$term, boost=${query.boost})',
      [
        Explanation.match(idf, 'idf, calculated as log(1 + (N - n + 0.5) / (n + 0.5))'),
        Explanation.match(tf, 'tf, term frequency $freq with k1=$k1, b=$b'),
      ],
    );
  }

  @override
  double cost() => 1.0;
}

/// Scorer that navigates a term postings list and evaluates BM25 scores.
class TermScorer extends Scorer {
  final PostingsReader postings;
  final dynamic docValues;
  final double idf;
  final double boost;
  final bool needsScores;
  static const double k1 = 1.2;

  TermScorer({
    required this.postings,
    this.docValues,
    required this.idf,
    required this.boost,
    required this.needsScores,
  });

  @override
  int get docId => postings.docId;

  @override
  double score() {
    if (!needsScores) return boost;
    final freq = postings.freq;
    final tf = (freq * (k1 + 1.0)) / (freq + k1);
    return boost * idf * tf;
  }

  @override
  int nextDoc() => postings.nextDoc();

  @override
  int advance(int target) => postings.advance(target);

  @override
  double cost() => postings.docCount.toDouble();
}
