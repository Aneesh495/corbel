import '../token.dart';
import '../token_stream.dart';

/// Code-aware tokenizer designed for programming language source code.
/// Splits compound identifiers on camelCase, snake_case, PascalCase, and symbol boundaries,
/// emitting both the complete original token and decomposed sub-tokens.
class CodeTokenizer extends TokenStream {
  final String _text;
  final bool emitOriginal;
  final List<Token> _tokens = [];
  int _index = -1;

  CodeTokenizer(this._text, {this.emitOriginal = true}) {
    _tokenize();
  }

  void _tokenize() {
    var i = 0;
    final len = _text.length;

    while (i < len) {
      // Skip non-identifier characters (whitespace and symbols)
      while (i < len && !_isIdentChar(_text.codeUnitAt(i))) {
        i++;
      }
      if (i >= len) break;

      final start = i;
      while (i < len && _isIdentChar(_text.codeUnitAt(i))) {
        i++;
      }
      final ident = _text.substring(start, i);

      // Add full composite identifier
      if (emitOriginal) {
        _tokens.add(Token(
          term: ident,
          startOffset: start,
          endOffset: i,
          positionIncrement: 1,
        ));
      }

      // Decompose camelCase and snake_case sub-tokens
      final subTokens = _splitIdentifier(ident, start);
      for (final sub in subTokens) {
        if (!emitOriginal || sub.term != ident) {
          _tokens.add(sub);
        }
      }
    }
  }

  List<Token> _splitIdentifier(String ident, int baseOffset) {
    final result = <Token>[];
    var subStart = 0;
    final len = ident.length;

    for (var i = 1; i < len; i++) {
      final prev = ident.codeUnitAt(i - 1);
      final curr = ident.codeUnitAt(i);

      // Boundary condition 1: underscore
      if (curr == 95) { // '_'
        if (i > subStart) {
          result.add(Token(
            term: ident.substring(subStart, i),
            startOffset: baseOffset + subStart,
            endOffset: baseOffset + i,
            positionIncrement: emitOriginal ? 0 : 1,
          ));
        }
        subStart = i + 1;
        continue;
      }

      // Boundary condition 2: lower-to-upper transition (camelCase: aB)
      final isLowerUpper = _isLower(prev) && _isUpper(curr);

      // Boundary condition 3: acronym to word transition (HTMLParser: L to P)
      final isAcronymWord = i + 1 < len &&
          _isUpper(prev) &&
          _isUpper(curr) &&
          _isLower(ident.codeUnitAt(i + 1));

      // Boundary condition 4: letter-to-digit or digit-to-letter
      final isAlphaDigit = (_isAlpha(prev) && _isDigit(curr)) ||
          (_isDigit(prev) && _isAlpha(curr));

      if (isLowerUpper || isAcronymWord || isAlphaDigit) {
        if (i > subStart) {
          result.add(Token(
            term: ident.substring(subStart, i),
            startOffset: baseOffset + subStart,
            endOffset: baseOffset + i,
            positionIncrement: emitOriginal ? 0 : 1,
          ));
        }
        subStart = i;
      }
    }

    if (subStart < len) {
      final remaining = ident.substring(subStart);
      if (remaining.isNotEmpty && remaining != '_') {
        result.add(Token(
          term: remaining,
          startOffset: baseOffset + subStart,
          endOffset: baseOffset + len,
          positionIncrement: emitOriginal ? 0 : 1,
        ));
      }
    }

    return result;
  }

  @override
  bool incrementToken() {
    _index++;
    return _index < _tokens.length;
  }

  @override
  Token get currentToken {
    if (_index < 0 || _index >= _tokens.length) {
      throw StateError('No active token in CodeTokenizer');
    }
    return _tokens[_index];
  }

  @override
  void reset() {
    _index = -1;
  }

  @override
  void close() {}

  static bool _isIdentChar(int c) {
    return _isAlpha(c) || _isDigit(c) || c == 95; // [a-zA-Z0-9_]
  }

  static bool _isAlpha(int c) => _isLower(c) || _isUpper(c);

  static bool _isLower(int c) => c >= 97 && c <= 122;

  static bool _isUpper(int c) => c >= 65 && c <= 90;

  static bool _isDigit(int c) => c >= 48 && c <= 57;
}
