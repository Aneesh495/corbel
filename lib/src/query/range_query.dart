import '../index/segment_reader.dart';
import 'explanation.dart';
import 'query.dart';
import 'scorer.dart';

/// Range query over columnar numeric doc values.
class NumericRangeQuery extends Query {
  final String field;
  final num? min;
  final num? max;
  final bool includeMin;
  final bool includeMax;

  const NumericRangeQuery({
    required this.field,
    this.min,
    this.max,
    this.includeMin = true,
    this.includeMax = true,
    super.boost = 1.0,
  });

  @override
  Weight createWeight(IndexSearchContext context, {bool needsScores = true}) {
    return NumericRangeWeight(
      query: this,
      field: field,
      min: min,
      max: max,
      includeMin: includeMin,
      includeMax: includeMax,
    );
  }

  @override
  String toString() {
    final lower = min != null ? (includeMin ? '[$min' : '{$min') : '{*';
    final upper = max != null ? (includeMax ? '$max]' : '$max}') : '*}';
    final boostSuffix = boost != 1.0 ? '^$boost' : '';
    return '$field:$lower TO $upper$boostSuffix';
  }
}

/// Weight binding [NumericRangeQuery] to segment columnar DocValues.
class NumericRangeWeight extends Weight {
  final String field;
  final num? min;
  final num? max;
  final bool includeMin;
  final bool includeMax;

  const NumericRangeWeight({
    required NumericRangeQuery query,
    required this.field,
    required this.min,
    required this.max,
    required this.includeMin,
    required this.includeMax,
  }) : super(query);

  @override
  Scorer? scorer(SegmentReader segmentReader) {
    final ndv = segmentReader.getNumericDocValues(field);
    if (ndv == null) return null;

    return NumericRangeScorer(
      ndv: ndv,
      segmentReader: segmentReader,
      min: min,
      max: max,
      includeMin: includeMin,
      includeMax: includeMax,
      boost: query.boost,
    );
  }

  @override
  Explanation explain(SegmentReader segmentReader, int docId) {
    final ndv = segmentReader.getNumericDocValues(field);
    if (ndv == null) {
      return Explanation.noMatch('Field "$field" has no numeric doc values');
    }

    if (docId >= segmentReader.maxDoc || !segmentReader.isLive(docId)) {
      return Explanation.noMatch('Document $docId is not live in segment');
    }

    final val = ndv.get(docId);
    final inRange = _matches(val);

    if (!inRange) {
      return Explanation.noMatch('Value $val for field "$field" outside range');
    }

    return Explanation.match(
      query.boost,
      'NumericRangeQuery match: $val in range',
    );
  }

  bool _matches(num val) {
    if (min != null) {
      if (includeMin ? val < min! : val <= min!) return false;
    }
    if (max != null) {
      if (includeMax ? val > max! : val >= max!) return false;
    }
    return true;
  }

  @override
  double cost() => 100.0;
}

/// Scorer iterating doc values matching numeric interval constraints.
class NumericRangeScorer extends Scorer {
  final dynamic ndv;
  final SegmentReader segmentReader;
  final num? min;
  final num? max;
  final bool includeMin;
  final bool includeMax;
  final double boost;

  int _currentDocId = -1;

  NumericRangeScorer({
    required this.ndv,
    required this.segmentReader,
    required this.min,
    required this.max,
    required this.includeMin,
    required this.includeMax,
    required this.boost,
  });

  @override
  int get docId => _currentDocId;

  @override
  double score() => boost;

  @override
  int nextDoc() => advance(_currentDocId + 1);

  @override
  int advance(int target) {
    final maxDoc = segmentReader.maxDoc;
    var candidate = target;

    while (candidate < maxDoc) {
      if (segmentReader.isLive(candidate)) {
        final val = ndv.get(candidate) as num;
        if (_matches(val)) {
          _currentDocId = candidate;
          return _currentDocId;
        }
      }
      candidate++;
    }

    _currentDocId = Scorer.noMoreDocs;
    return Scorer.noMoreDocs;
  }

  bool _matches(num val) {
    if (min != null) {
      if (includeMin ? val < min! : val <= min!) return false;
    }
    if (max != null) {
      if (includeMax ? val > max! : val >= max!) return false;
    }
    return true;
  }

  @override
  double cost() => segmentReader.maxDoc.toDouble();
}

/// Lexicographical range query over term doc values or FST dictionary.
class TermRangeQuery extends Query {
  final String field;
  final String? lowerTerm;
  final String? upperTerm;
  final bool includeLower;
  final bool includeUpper;

  const TermRangeQuery({
    required this.field,
    this.lowerTerm,
    this.upperTerm,
    this.includeLower = true,
    this.includeUpper = true,
    super.boost = 1.0,
  });

  @override
  Weight createWeight(IndexSearchContext context, {bool needsScores = true}) {
    return TermRangeWeight(
      query: this,
      field: field,
      lowerTerm: lowerTerm,
      upperTerm: upperTerm,
      includeLower: includeLower,
      includeUpper: includeUpper,
      context: context,
      needsScores: needsScores,
    );
  }

  @override
  String toString() {
    final lower = lowerTerm != null ? (includeLower ? '[$lowerTerm' : '{$lowerTerm') : '{*';
    final upper = upperTerm != null ? (includeUpper ? '$upperTerm]' : '$upperTerm}') : '*}';
    final boostSuffix = boost != 1.0 ? '^$boost' : '';
    return '$field:$lower TO $upper$boostSuffix';
  }
}

/// Weight executing term range expansion across FST or SortedSetDocValues.
class TermRangeWeight extends Weight {
  final String field;
  final String? lowerTerm;
  final String? upperTerm;
  final bool includeLower;
  final bool includeUpper;
  final IndexSearchContext context;
  final bool needsScores;

  const TermRangeWeight({
    required TermRangeQuery query,
    required this.field,
    required this.lowerTerm,
    required this.upperTerm,
    required this.includeLower,
    required this.includeUpper,
    required this.context,
    required this.needsScores,
  }) : super(query);

  @override
  Scorer? scorer(SegmentReader segmentReader) {
    // 1. Check if SortedSetDocValues exists for fast ordinal filtering
    final ssdv = segmentReader.getSortedSetDocValues(field);
    if (ssdv != null) {
      return _buildSortedSetScorer(segmentReader, ssdv);
    }

    // 2. Fall back to FST term expansion
    final fst = segmentReader.getFst(field);
    if (fst == null) return null;

    final matching = fst.searchMatching((term) => _matches(term));
    if (matching.isEmpty) return null;

    final scorers = <Scorer>[];
    for (final m in matching) {
      final p = segmentReader.postings(field, m.key);
      if (p != null) {
        scorers.add(ConstantScoreScorer(
          nextDoc: p.nextDoc,
          advance: p.advance,
          docId: () => p.docId,
          cost: () => p.docCount.toDouble(),
          boost: query.boost,
        ));
      }
    }

    if (scorers.isEmpty) return null;
    return _DisjunctionUnionScorer(scorers, query.boost);
  }

  Scorer? _buildSortedSetScorer(SegmentReader segmentReader, dynamic ssdv) {
    return _SortedSetRangeScorer(
      ssdv: ssdv,
      segmentReader: segmentReader,
      matcher: _matches,
      boost: query.boost,
    );
  }

  bool _matches(String term) {
    if (lowerTerm != null) {
      final cmp = term.compareTo(lowerTerm!);
      if (includeLower ? cmp < 0 : cmp <= 0) return false;
    }
    if (upperTerm != null) {
      final cmp = term.compareTo(upperTerm!);
      if (includeUpper ? cmp > 0 : cmp >= 0) return false;
    }
    return true;
  }

  @override
  Explanation explain(SegmentReader segmentReader, int docId) {
    final s = scorer(segmentReader);
    if (s == null) return Explanation.noMatch('No terms matched range in field "$field"');

    final target = s.advance(docId);
    if (target != docId) return Explanation.noMatch('Doc $docId does not match term range');

    return Explanation.match(query.boost, 'TermRangeQuery match for doc $docId');
  }

  @override
  double cost() => 50.0;
}

class _SortedSetRangeScorer extends Scorer {
  final dynamic ssdv;
  final SegmentReader segmentReader;
  final bool Function(String term) matcher;
  final double boost;

  int _currentDocId = -1;

  _SortedSetRangeScorer({
    required this.ssdv,
    required this.segmentReader,
    required this.matcher,
    required this.boost,
  });

  @override
  int get docId => _currentDocId;

  @override
  double score() => boost;

  @override
  int nextDoc() => advance(_currentDocId + 1);

  @override
  int advance(int target) {
    final maxDoc = segmentReader.maxDoc;
    var candidate = target;

    while (candidate < maxDoc) {
      if (segmentReader.isLive(candidate)) {
        final ordinals = ssdv.getOrdinals(candidate) as List<int>;
        var matched = false;
        for (final ord in ordinals) {
          final term = ssdv.lookupOrd(ord) as String;
          if (matcher(term)) {
            matched = true;
            break;
          }
        }
        if (matched) {
          _currentDocId = candidate;
          return _currentDocId;
        }
      }
      candidate++;
    }

    _currentDocId = Scorer.noMoreDocs;
    return Scorer.noMoreDocs;
  }

  @override
  double cost() => segmentReader.maxDoc.toDouble();
}

class _DisjunctionUnionScorer extends Scorer {
  final List<Scorer> scorers;
  final double boost;
  int _currentDocId = -1;

  _DisjunctionUnionScorer(this.scorers, this.boost);

  @override
  int get docId => _currentDocId;

  @override
  double score() => boost;

  @override
  int nextDoc() => advance(_currentDocId + 1);

  @override
  int advance(int target) {
    var minDoc = Scorer.noMoreDocs;
    for (final s in scorers) {
      if (s.docId < target) {
        s.advance(target);
      }
      if (s.docId < minDoc) {
        minDoc = s.docId;
      }
    }
    _currentDocId = minDoc;
    return _currentDocId;
  }

  @override
  double cost() {
    var sum = 0.0;
    for (final s in scorers) {
      sum += s.cost();
    }
    return sum;
  }
}
