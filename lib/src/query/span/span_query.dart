import '../../index/segment_reader.dart';
import '../explanation.dart';
import '../query.dart';
import '../scorer.dart';
import 'span_scorer.dart';
import 'spans.dart';

/// Abstract base query class for positional span queries.
abstract class SpanQuery extends Query {
  const SpanQuery({super.boost = 1.0});

  /// The field targeted by this span query.
  String get field;

  @override
  SpanWeight createWeight(IndexSearchContext context, {bool needsScores = true});
}

/// Abstract weight binding a [SpanQuery] to segment postings and positional iterators.
abstract class SpanWeight extends Weight {
  @override
  SpanQuery get query => super.query as SpanQuery;

  const SpanWeight(SpanQuery super.query);

  /// Instantiates a positional [Spans] iterator for [segmentReader].
  Spans? getSpans(SegmentReader segmentReader);

  @override
  Scorer? scorer(SegmentReader segmentReader) {
    final spans = getSpans(segmentReader);
    if (spans == null) return null;
    return SpanScorer(spans: spans, boost: query.boost);
  }

  @override
  Explanation explain(SegmentReader segmentReader, int docId) {
    final spans = getSpans(segmentReader);
    if (spans == null) {
      return Explanation.noMatch('No spans found for query: $query');
    }

    final targetDoc = spans.advance(docId);
    if (targetDoc != docId) {
      return Explanation.noMatch('Document $docId does not match span query: $query');
    }

    final scorer = SpanScorer(spans: spans, boost: query.boost);
    scorer.advance(docId);
    final score = scorer.score();

    return Explanation.match(
      score,
      'SpanQuery match in doc $docId (${scorer.matchCount} occurrences): $query',
    );
  }

  @override
  double cost() => 10.0;
}
