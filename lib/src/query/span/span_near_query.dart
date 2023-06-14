import 'dart:math' as math;
import '../../index/segment_reader.dart';
import '../query.dart';
import '../scorer.dart';
import 'span_query.dart';
import 'spans.dart';

/// Matches spans occurring within [slop] positions of each other.
class SpanNearQuery extends SpanQuery {
  final List<SpanQuery> clauses;
  final int slop;
  final bool inOrder;

  const SpanNearQuery({
    required this.clauses,
    required this.slop,
    this.inOrder = true,
    super.boost = 1.0,
  });

  @override
  String get field => clauses.first.field;

  @override
  SpanWeight createWeight(IndexSearchContext context, {bool needsScores = true}) {
    final subWeights = clauses
        .map((c) => c.createWeight(context, needsScores: needsScores))
        .toList();
    return SpanNearWeight(query: this, subWeights: subWeights);
  }

  @override
  String toString() {
    final clauseStrs = clauses.map((c) => c.toString()).join(', ');
    return 'SpanNear([$clauseStrs], slop: $slop, inOrder: $inOrder)';
  }
}

/// Weight binding [SpanNearQuery] to sub-query spans.
class SpanNearWeight extends SpanWeight {
  final SpanNearQuery nearQuery;
  final List<SpanWeight> subWeights;

  const SpanNearWeight({
    required SpanNearQuery query,
    required this.subWeights,
  })  : nearQuery = query,
        super(query);

  @override
  Spans? getSpans(SegmentReader segmentReader) {
    final subSpans = <Spans>[];
    for (final w in subWeights) {
      final s = w.getSpans(segmentReader);
      if (s == null) return null; // If any clause is absent, query matches nothing
      subSpans.add(s);
    }

    return _NearSpans(
      clauses: subSpans,
      slop: nearQuery.slop,
      inOrder: nearQuery.inOrder,
    );
  }

  @override
  double cost() =>
      subWeights.map((w) => w.cost()).reduce((a, b) => math.min(a, b));
}

class _SpanInterval {
  final int start;
  final int end;
  _SpanInterval(this.start, this.end);
}

class _NearSpans extends Spans {
  final List<Spans> clauses;
  final int slop;
  final bool inOrder;

  int _docId = -1;
  final List<_SpanInterval> _matchedSpans = [];
  int _matchIndex = -1;

  _NearSpans({
    required this.clauses,
    required this.slop,
    required this.inOrder,
  });

  @override
  int get docId => _docId;

  @override
  int nextDoc() {
    _matchIndex = -1;
    _matchedSpans.clear();

    // Advance first clause to next doc
    var target = clauses.first.nextDoc();
    while (target != Scorer.noMoreDocs) {
      var matchAll = true;
      for (var i = 1; i < clauses.length; i++) {
        var d = clauses[i].docId;
        if (d < target) {
          d = clauses[i].advance(target);
        }
        if (d > target) {
          target = clauses.first.advance(d);
          matchAll = false;
          break;
        }
      }

      if (matchAll) {
        _docId = target;
        _findSpansInCurrentDoc();
        if (_matchedSpans.isNotEmpty) {
          return _docId;
        }
        // No span combinations within slop in this doc, advance to next
        target = clauses.first.nextDoc();
      }
    }

    _docId = Scorer.noMoreDocs;
    return Scorer.noMoreDocs;
  }

  @override
  int advance(int target) {
    _matchIndex = -1;
    _matchedSpans.clear();

    var current = clauses.first.advance(target);
    while (current != Scorer.noMoreDocs) {
      var matchAll = true;
      for (var i = 1; i < clauses.length; i++) {
        var d = clauses[i].docId;
        if (d < current) {
          d = clauses[i].advance(current);
        }
        if (d > current) {
          current = clauses.first.advance(d);
          matchAll = false;
          break;
        }
      }

      if (matchAll) {
        _docId = current;
        _findSpansInCurrentDoc();
        if (_matchedSpans.isNotEmpty) {
          return _docId;
        }
        current = clauses.first.nextDoc();
      }
    }

    _docId = Scorer.noMoreDocs;
    return Scorer.noMoreDocs;
  }

  void _findSpansInCurrentDoc() {
    _matchedSpans.clear();
    _matchIndex = -1;

    // Collect all token positions per clause for this document
    final clausePositions = <List<_SpanInterval>>[];
    for (final c in clauses) {
      final list = <_SpanInterval>[];
      while (c.nextStartPosition() != Spans.noMorePositions) {
        list.add(_SpanInterval(c.startPosition(), c.endPosition()));
      }
      if (list.isEmpty) return; // Clause has no positions
      clausePositions.add(list);
    }

    if (inOrder) {
      _matchInOrder(clausePositions, 0, -1, -1, 0);
    } else {
      _matchUnordered(clausePositions);
    }

    // Sort matched intervals by start position, then by width
    _matchedSpans.sort((a, b) {
      final cmp = a.start.compareTo(b.start);
      if (cmp != 0) return cmp;
      return (a.end - a.start).compareTo(b.end - b.start);
    });
  }

  void _matchInOrder(
    List<List<_SpanInterval>> clausePositions,
    int clauseIdx,
    int currentStart,
    int lastEnd,
    int totalClauseWidth,
  ) {
    if (clauseIdx == clausePositions.length) {
      final spanWidth = lastEnd - currentStart;
      final distance = spanWidth - totalClauseWidth;
      if (distance <= slop) {
        _matchedSpans.add(_SpanInterval(currentStart, lastEnd));
      }
      return;
    }

    final positions = clausePositions[clauseIdx];
    for (final p in positions) {
      if (clauseIdx == 0) {
        _matchInOrder(
          clausePositions,
          1,
          p.start,
          p.end,
          p.end - p.start,
        );
      } else {
        if (p.start >= lastEnd) {
          final spanWidth = p.end - currentStart;
          final widthSoFar = totalClauseWidth + (p.end - p.start);
          final distance = spanWidth - widthSoFar;
          if (distance <= slop) {
            _matchInOrder(
              clausePositions,
              clauseIdx + 1,
              currentStart,
              p.end,
              widthSoFar,
            );
          }
        }
      }
    }
  }

  void _matchUnordered(List<List<_SpanInterval>> clausePositions) {
    // Generate combinations of 1 interval from each clause
    final indices = List<int>.filled(clausePositions.length, 0);

    void searchComb(int clauseIdx) {
      if (clauseIdx == clausePositions.length) {
        var minStart = 0x7FFFFFFF;
        var maxEnd = -1;
        var totalClauseWidth = 0;

        for (var i = 0; i < clausePositions.length; i++) {
          final interval = clausePositions[i][indices[i]];
          if (interval.start < minStart) minStart = interval.start;
          if (interval.end > maxEnd) maxEnd = interval.end;
          totalClauseWidth += (interval.end - interval.start);
        }

        final distance = (maxEnd - minStart) - totalClauseWidth;
        if (distance <= slop) {
          _matchedSpans.add(_SpanInterval(minStart, maxEnd));
        }
        return;
      }

      for (var i = 0; i < clausePositions[clauseIdx].length; i++) {
        indices[clauseIdx] = i;
        searchComb(clauseIdx + 1);
      }
    }

    searchComb(0);
  }

  @override
  int nextStartPosition() {
    _matchIndex++;
    if (_matchIndex >= _matchedSpans.length) {
      return Spans.noMorePositions;
    }
    return _matchedSpans[_matchIndex].start;
  }

  @override
  int startPosition() {
    if (_matchIndex < 0) return -1;
    if (_matchIndex >= _matchedSpans.length) return Spans.noMorePositions;
    return _matchedSpans[_matchIndex].start;
  }

  @override
  int endPosition() {
    if (_matchIndex < 0) return -1;
    if (_matchIndex >= _matchedSpans.length) return Spans.noMorePositions;
    return _matchedSpans[_matchIndex].end;
  }

  @override
  double cost() => clauses.first.cost();
}
