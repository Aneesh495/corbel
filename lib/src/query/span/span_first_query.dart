import '../../index/segment_reader.dart';
import '../query.dart';
import '../scorer.dart';
import 'span_query.dart';
import 'spans.dart';

/// Matches spans from [match] whose end token position is at or before [end].
class SpanFirstQuery extends SpanQuery {
  final SpanQuery match;
  final int end;

  const SpanFirstQuery({
    required this.match,
    required this.end,
    super.boost = 1.0,
  }) : assert(end > 0, 'SpanFirstQuery end limit must be positive');

  @override
  String get field => match.field;

  @override
  SpanWeight createWeight(IndexSearchContext context, {bool needsScores = true}) {
    final subWeight = match.createWeight(context, needsScores: needsScores);
    return SpanFirstWeight(query: this, matchWeight: subWeight, end: end);
  }

  @override
  String toString() => 'SpanFirst($match, end: $end)';
}

/// Weight binding [SpanFirstQuery] to sub-query spans with an end position cutoff.
class SpanFirstWeight extends SpanWeight {
  final SpanWeight matchWeight;
  final int end;

  const SpanFirstWeight({
    required SpanFirstQuery query,
    required this.matchWeight,
    required this.end,
  }) : super(query);

  @override
  Spans? getSpans(SegmentReader segmentReader) {
    final subSpans = matchWeight.getSpans(segmentReader);
    if (subSpans == null) return null;
    return _FirstSpans(subSpans: subSpans, maxEnd: end);
  }

  @override
  double cost() => matchWeight.cost();
}

class _SpanInterval {
  final int start;
  final int end;
  _SpanInterval(this.start, this.end);
}

class _FirstSpans extends Spans {
  final Spans subSpans;
  final int maxEnd;

  int _docId = -1;
  final List<_SpanInterval> _validSpans = [];
  int _spanIndex = -1;

  _FirstSpans({required this.subSpans, required this.maxEnd});

  @override
  int get docId => _docId;

  @override
  int nextDoc() {
    _spanIndex = -1;
    _validSpans.clear();

    while (subSpans.nextDoc() != Scorer.noMoreDocs) {
      _docId = subSpans.docId;
      _filterSpans();
      if (_validSpans.isNotEmpty) {
        return _docId;
      }
    }

    _docId = Scorer.noMoreDocs;
    return Scorer.noMoreDocs;
  }

  @override
  int advance(int target) {
    _spanIndex = -1;
    _validSpans.clear();

    var d = subSpans.advance(target);
    while (d != Scorer.noMoreDocs) {
      _docId = d;
      _filterSpans();
      if (_validSpans.isNotEmpty) {
        return _docId;
      }
      d = subSpans.nextDoc();
    }

    _docId = Scorer.noMoreDocs;
    return Scorer.noMoreDocs;
  }

  void _filterSpans() {
    _validSpans.clear();
    _spanIndex = -1;

    while (subSpans.nextStartPosition() != Spans.noMorePositions) {
      if (subSpans.endPosition() <= maxEnd) {
        _validSpans.add(_SpanInterval(
          subSpans.startPosition(),
          subSpans.endPosition(),
        ));
      }
    }
  }

  @override
  int nextStartPosition() {
    _spanIndex++;
    if (_spanIndex >= _validSpans.length) {
      return Spans.noMorePositions;
    }
    return _validSpans[_spanIndex].start;
  }

  @override
  int startPosition() {
    if (_spanIndex < 0) return -1;
    if (_spanIndex >= _validSpans.length) return Spans.noMorePositions;
    return _validSpans[_spanIndex].start;
  }

  @override
  int endPosition() {
    if (_spanIndex < 0) return -1;
    if (_spanIndex >= _validSpans.length) return Spans.noMorePositions;
    return _validSpans[_spanIndex].end;
  }

  @override
  double cost() => subSpans.cost();
}
