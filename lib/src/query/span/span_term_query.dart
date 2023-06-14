import '../../index/segment_reader.dart';
import '../query.dart';
import 'span_query.dart';
import 'spans.dart';

/// Leaf span query matching a single term and exposing its token positions.
class SpanTermQuery extends SpanQuery {
  @override
  final String field;
  final String term;

  const SpanTermQuery({
    required this.field,
    required this.term,
    super.boost = 1.0,
  });

  @override
  SpanWeight createWeight(IndexSearchContext context, {bool needsScores = true}) {
    return SpanTermWeight(this);
  }

  @override
  String toString() => '$field:$term';
}

/// Weight binding [SpanTermQuery] to a single term's postings list.
class SpanTermWeight extends SpanWeight {
  final SpanTermQuery termQuery;

  const SpanTermWeight(this.termQuery) : super(termQuery);

  @override
  Spans? getSpans(SegmentReader segmentReader) {
    final postings = segmentReader.postings(termQuery.field, termQuery.term);
    if (postings == null) return null;
    return TermSpans(postings: postings);
  }

  @override
  double cost() => 10.0;
}
