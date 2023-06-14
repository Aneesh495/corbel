import '../../index/segment_reader.dart';
import '../query.dart';
import '../scorer.dart';
import 'span_query.dart';
import 'spans.dart';

/// Matches spans from an [include] query that do not overlap with or fall within
/// [pre] or [post] token positions of an [exclude] span match.
class SpanNotQuery extends SpanQuery {
  final SpanQuery include;
  final SpanQuery exclude;
  final int pre;
  final int post;

  const SpanNotQuery({
    required this.include,
    required this.exclude,
    this.pre = 0,
    this.post = 0,
    super.boost = 1.0,
  });

  @override
  String get field => include.field;

  @override
  SpanWeight createWeight(IndexSearchContext context, {bool needsScores = true}) {
    final includeWeight =
        include.createWeight(context, needsScores: needsScores);
    final excludeWeight =
        exclude.createWeight(context, needsScores: needsScores);
    return SpanNotWeight(
      query: this,
      includeWeight: includeWeight,
      excludeWeight: excludeWeight,
      pre: pre,
      post: post,
    );
  }

  @override
  String toString() =>
      'SpanNot(include: $include, exclude: $exclude, pre: $pre, post: $post)';
}

/// Weight binding [SpanNotQuery] to include and exclude weights.
class SpanNotWeight extends SpanWeight {
  final SpanWeight includeWeight;
  final SpanWeight excludeWeight;
  final int pre;
  final int post;

  const SpanNotWeight({
    required SpanNotQuery query,
    required this.includeWeight,
    required this.excludeWeight,
    required this.pre,
    required this.post,
  }) : super(query);

  @override
  Spans? getSpans(SegmentReader segmentReader) {
    final includeSpans = includeWeight.getSpans(segmentReader);
    if (includeSpans == null) return null;

    final excludeSpans = excludeWeight.getSpans(segmentReader);
    if (excludeSpans == null) {
      // No exclude occurrences in this segment, includeSpans match untouched
      return includeSpans;
    }

    return _NotSpans(
      includeSpans: includeSpans,
      excludeSpans: excludeSpans,
      pre: pre,
      post: post,
    );
  }

  @override
  double cost() => includeWeight.cost();
}

class _SpanInterval {
  final int start;
  final int end;
  _SpanInterval(this.start, this.end);
}

class _NotSpans extends Spans {
  final Spans includeSpans;
  final Spans excludeSpans;
  final int pre;
  final int post;

  int _docId = -1;
  final List<_SpanInterval> _validSpans = [];
  int _spanIndex = -1;

  _NotSpans({
    required this.includeSpans,
    required this.excludeSpans,
    required this.pre,
    required this.post,
  });

  @override
  int get docId => _docId;

  @override
  int nextDoc() {
    _spanIndex = -1;
    _validSpans.clear();

    while (includeSpans.nextDoc() != Scorer.noMoreDocs) {
      _docId = includeSpans.docId;
      _filterSpansInDoc();
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

    var d = includeSpans.advance(target);
    while (d != Scorer.noMoreDocs) {
      _docId = d;
      _filterSpansInDoc();
      if (_validSpans.isNotEmpty) {
        return _docId;
      }
      d = includeSpans.nextDoc();
    }

    _docId = Scorer.noMoreDocs;
    return Scorer.noMoreDocs;
  }

  void _filterSpansInDoc() {
    _validSpans.clear();
    _spanIndex = -1;

    // Collect all include spans for current doc
    final includes = <_SpanInterval>[];
    while (includeSpans.nextStartPosition() != Spans.noMorePositions) {
      includes.add(_SpanInterval(
        includeSpans.startPosition(),
        includeSpans.endPosition(),
      ));
    }

    // Collect all exclude spans for current doc (if exclude is present in this doc)
    final excludes = <_SpanInterval>[];
    if (excludeSpans.docId < _docId) {
      excludeSpans.advance(_docId);
    }
    if (excludeSpans.docId == _docId) {
      while (excludeSpans.nextStartPosition() != Spans.noMorePositions) {
        excludes.add(_SpanInterval(
          excludeSpans.startPosition(),
          excludeSpans.endPosition(),
        ));
      }
    }

    if (excludes.isEmpty) {
      _validSpans.addAll(includes);
      return;
    }

    // Filter each include span against exclude spans considering pre/post window
    for (final inc in includes) {
      var overlaps = false;
      for (final exc in excludes) {
        final excStart = exc.start - post;
        final excEnd = exc.end + pre;

        // Check intersection of [inc.start, inc.end] with [excStart, excEnd]
        if (!(inc.end <= excStart || inc.start >= excEnd)) {
          overlaps = true;
          break;
        }
      }

      if (!overlaps) {
        _validSpans.add(inc);
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
  double cost() => includeSpans.cost();
}
