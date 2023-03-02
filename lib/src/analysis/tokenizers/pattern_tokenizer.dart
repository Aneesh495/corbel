import '../token.dart';
import '../token_stream.dart';

/// Regex pattern-based tokenizer.
class PatternTokenizer extends TokenStream {
  final String _text;
  final RegExp _pattern;
  final bool _isDelimiter;
  int _position = 0;
  Token? _current;
  late final List<Token> _precomputed;
  int _currentIndex = -1;

  PatternTokenizer(this._text, RegExp pattern, {bool isDelimiter = true})
      : _pattern = pattern,
        _isDelimiter = isDelimiter {
    _precomputed = _tokenize();
  }

  List<Token> _tokenize() {
    final tokens = <Token>[];
    if (_isDelimiter) {
      final matches = _pattern.allMatches(_text).toList();
      var lastEnd = 0;
      for (final match in matches) {
        if (match.start > lastEnd) {
          final term = _text.substring(lastEnd, match.start);
          tokens.add(Token(
            term: term,
            startOffset: lastEnd,
            endOffset: match.start,
            positionIncrement: 1,
          ));
        }
        lastEnd = match.end;
      }
      if (lastEnd < _text.length) {
        final term = _text.substring(lastEnd);
        tokens.add(Token(
          term: term,
          startOffset: lastEnd,
          endOffset: _text.length,
          positionIncrement: 1,
        ));
      }
    } else {
      final matches = _pattern.allMatches(_text);
      for (final match in matches) {
        final term = _text.substring(match.start, match.end);
        tokens.add(Token(
          term: term,
          startOffset: match.start,
          endOffset: match.end,
          positionIncrement: 1,
        ));
      }
    }
    return tokens;
  }

  @override
  bool incrementToken() {
    _currentIndex++;
    if (_currentIndex < _precomputed.length) {
      _current = _precomputed[_currentIndex];
      return true;
    }
    _current = null;
    return false;
  }

  @override
  Token get currentToken {
    if (_current == null) {
      throw StateError('No active token in PatternTokenizer');
    }
    return _current!;
  }

  @override
  void reset() {
    _currentIndex = -1;
    _current = null;
  }

  @override
  void close() {}
}
