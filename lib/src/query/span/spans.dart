import '../../index/postings/postings_reader.dart';

/// Abstract positional iterator over span matches within documents.
abstract class Spans {
  /// Sentinel position returned when all spans in the current document are exhausted.
  static const int noMorePositions = 0x7FFFFFFF;

  /// Current document ID.
  int get docId;

  /// Advances to the next document containing at least one span match.
  int nextDoc();

  /// Advances to the first document with docId >= [target].
  int advance(int target);

  /// Advances to the next match within the current document.
  /// Returns [startPosition], or [noMorePositions] if no more spans exist.
  int nextStartPosition();

  /// Start position of the current span (inclusive).
  int startPosition();

  /// End position of the current span (exclusive).
  int endPosition();

  /// Width in token positions of the current span: `endPosition - startPosition`.
  int width() => endPosition() - startPosition();

  /// Estimated match cost for query planning.
  double cost();
}

/// Leaf spans iterator iterating over positions in a postings list for a single term.
class TermSpans extends Spans {
  final PostingsReader postings;
  int _posIndex = -1;

  TermSpans({required this.postings});

  @override
  int get docId => postings.docId;

  @override
  int nextDoc() {
    _posIndex = -1;
    return postings.nextDoc();
  }

  @override
  int advance(int target) {
    _posIndex = -1;
    return postings.advance(target);
  }

  @override
  int nextStartPosition() {
    final positions = postings.positions;
    _posIndex++;
    if (_posIndex >= positions.length) {
      return Spans.noMorePositions;
    }
    return positions[_posIndex];
  }

  @override
  int startPosition() {
    if (_posIndex < 0) return -1;
    final positions = postings.positions;
    if (_posIndex >= positions.length) return Spans.noMorePositions;
    return positions[_posIndex];
  }

  @override
  int endPosition() {
    final start = startPosition();
    if (start < 0) return -1;
    if (start == Spans.noMorePositions) return Spans.noMorePositions;
    return start + 1; // Single-token span has length 1
  }

  @override
  double cost() => postings.docCount.toDouble();
}
