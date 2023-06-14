import '../../index/segment_reader.dart';
import '../query.dart';
import '../scorer.dart';
import 'span_query.dart';
import 'spans.dart';

/// Matches the union (disjunction) of multiple [SpanQuery] clauses in the same field.
class SpanOrQuery extends SpanQuery {
  final List<SpanQuery> clauses;

  const SpanOrQuery({
    required this.clauses,
    super.boost = 1.0,
  });

  @override
  String get field => clauses.first.field;

  @override
  SpanWeight createWeight(IndexSearchContext context, {bool needsScores = true}) {
    final subWeights = clauses
        .map((c) => c.createWeight(context, needsScores: needsScores))
        .toList();
    return SpanOrWeight(query: this, subWeights: subWeights);
  }

  @override
  String toString() {
    final clauseStrs = clauses.map((c) => c.toString()).join(' OR ');
    return 'SpanOr($clauseStrs)';
  }
}

/// Weight binding [SpanOrQuery] to its sub-clause weights.
class SpanOrWeight extends SpanWeight {
  final List<SpanWeight> subWeights;

  const SpanOrWeight({
    required SpanOrQuery query,
    required this.subWeights,
  }) : super(query);

  @override
  Spans? getSpans(SegmentReader segmentReader) {
    final subSpans = <Spans>[];
    for (final w in subWeights) {
      final s = w.getSpans(segmentReader);
      if (s != null) {
        subSpans.add(s);
      }
    }

    if (subSpans.isEmpty) return null;
    if (subSpans.length == 1) return subSpans.first;

    return _OrSpans(subSpans);
  }

  @override
  double cost() =>
      subWeights.map((w) => w.cost()).fold(0.0, (a, b) => a + b);
}

class _SpanCandidate {
  final int start;
  final int end;
  _SpanCandidate(this.start, this.end);
}

class _OrSpans extends Spans {
  final List<Spans> subSpans;
  int _docId = -1;
  final List<_SpanCandidate> _currentDocSpans = [];
  int _spanIndex = -1;

  _OrSpans(this.subSpans);

  @override
  int get docId => _docId;

  @override
  int nextDoc() {
    _spanIndex = -1;
    _currentDocSpans.clear();

    var minDoc = Scorer.noMoreDocs;
    for (final s in subSpans) {
      var d = s.docId;
      if (d == -1 || d == _docId) {
        d = s.nextDoc();
      }
      if (d < minDoc) {
        minDoc = d;
      }
    }

    if (minDoc == Scorer.noMoreDocs) {
      _docId = Scorer.noMoreDocs;
      return Scorer.noMoreDocs;
    }

    _docId = minDoc;
    _gatherSpansForCurrentDoc();
    return _docId;
  }

  @override
  int advance(int target) {
    _spanIndex = -1;
    _currentDocSpans.clear();

    var minDoc = Scorer.noMoreDocs;
    for (final s in subSpans) {
      var d = s.docId;
      if (d < target) {
        d = s.advance(target);
      }
      if (d < minDoc) {
        minDoc = d;
      }
    }

    if (minDoc == Scorer.noMoreDocs) {
      _docId = Scorer.noMoreDocs;
      return Scorer.noMoreDocs;
    }

    _docId = minDoc;
    _gatherSpansForCurrentDoc();
    return _docId;
  }

  void _gatherSpansForCurrentDoc() {
    _currentDocSpans.clear();
    _spanIndex = -1;

    for (final s in subSpans) {
      if (s.docId == _docId) {
        while (s.nextStartPosition() != Spans.noMorePositions) {
          _currentDocSpans.add(_SpanCandidate(s.startPosition(), s.endPosition()));
        }
      }
    }

    // Sort spans by start position, then end position
    _currentDocSpans.sort((a, b) {
      final cmp = a.start.compareTo(b.start);
      if (cmp != 0) return cmp;
      return a.end.compareTo(b.end);
    });
  }

  @override
  int nextStartPosition() {
    _spanIndex++;
    if (_spanIndex >= _currentDocSpans.length) {
      return Spans.noMorePositions;
    }
    return _currentDocSpans[_spanIndex].start;
  }

  @override
  int startPosition() {
    if (_spanIndex < 0) return -1;
    if (_spanIndex >= _currentDocSpans.length) return Spans.noMorePositions;
    return _currentDocSpans[_spanIndex].start;
  }

  @override
  int endPosition() {
    if (_spanIndex < 0) return -1;
    if (_spanIndex >= _currentDocSpans.length) return Spans.noMorePositions;
    return _currentDocSpans[_spanIndex].end;
  }

  @override
  double cost() =>
      subSpans.map((s) => s.cost()).fold(0.0, (a, b) => a + b);
}
