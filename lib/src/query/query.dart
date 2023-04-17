import '../index/segment_reader.dart';
import 'explanation.dart';
import 'scorer.dart';

/// Context provided during weight creation across all index segments.
class IndexSearchContext {
  final int totalDocumentCount;
  final Map<String, int> fieldDocCounts;
  final Map<String, int> fieldTotalTermFrequencies;

  const IndexSearchContext({
    required this.totalDocumentCount,
    this.fieldDocCounts = const {},
    this.fieldTotalTermFrequencies = const {},
  });
}

/// Abstract base query class in the Corbel search engine AST.
abstract class Query {
  final double boost;

  const Query({this.boost = 1.0});

  /// Compiles this query into an executable [Weight] for a search context.
  Weight createWeight(IndexSearchContext context, {bool needsScores = true});

  /// Explains score contribution for a given document across a segment.
  Explanation explain(SegmentReader segmentReader, IndexSearchContext context, int docId) {
    final weight = createWeight(context, needsScores: true);
    return weight.explain(segmentReader, docId);
  }

  @override
  String toString();
}

/// Weight interface that binds a Query to an index reader and similarity model.
abstract class Weight {
  final Query query;

  const Weight(this.query);

  /// Instantiates a [Scorer] for iterating and scoring documents in [segmentReader].
  Scorer? scorer(SegmentReader segmentReader);

  /// Explains score calculation for [docId] in [segmentReader].
  Explanation explain(SegmentReader segmentReader, int docId);

  /// Estimated match cost for lead iterator scheduling.
  double cost();
}
