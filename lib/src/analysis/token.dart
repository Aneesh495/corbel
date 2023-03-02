import 'dart:typed_data';

/// Inverted index token representation capturing term text, character offsets,
/// positional increments, and optional binary payloads.
class Token {
  /// Normalized term text.
  final String term;

  /// Starting character offset in the source document.
  final int startOffset;

  /// Ending character offset in the source document.
  final int endOffset;

  /// Position increment relative to preceding token (default 1; 0 for synonyms).
  final int positionIncrement;

  /// Positional span covered by this token (default 1).
  final int positionLength;

  /// Arbitrary binary payload stored in postings lists.
  final Uint8List? payload;

  const Token({
    required this.term,
    required this.startOffset,
    required this.endOffset,
    this.positionIncrement = 1,
    this.positionLength = 1,
    this.payload,
  });

  /// Creates a cloned token with modified attributes.
  Token copyWith({
    String? term,
    int? startOffset,
    int? endOffset,
    int? positionIncrement,
    int? positionLength,
    Uint8List? payload,
  }) {
    return Token(
      term: term ?? this.term,
      startOffset: startOffset ?? this.startOffset,
      endOffset: endOffset ?? this.endOffset,
      positionIncrement: positionIncrement ?? this.positionIncrement,
      positionLength: positionLength ?? this.positionLength,
      payload: payload ?? this.payload,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! Token) return false;
    return term == other.term &&
        startOffset == other.startOffset &&
        endOffset == other.endOffset &&
        positionIncrement == other.positionIncrement &&
        positionLength == other.positionLength;
  }

  @override
  int get hashCode => Object.hash(
        term,
        startOffset,
        endOffset,
        positionIncrement,
        positionLength,
      );

  @override
  String toString() =>
      'Token("$term", [$startOffset-$endOffset], posIncr: $positionIncrement)';
}
