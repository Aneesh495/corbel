import '../token.dart';
import '../token_stream.dart';

/// Whitespace tokenizer splitting text strictly on whitespace characters.
class WhitespaceTokenizer extends TokenStream {
  final String _text;
  int _position = 0;
  Token? _current;

  WhitespaceTokenizer(this._text);

  @override
  bool incrementToken() {
    while (_position < _text.length) {
      final codeUnit = _text.codeUnitAt(_position);
      if (_isWhitespace(codeUnit)) {
        _position++;
        continue;
      }

      final start = _position;
      var end = start + 1;
      while (end < _text.length && !_isWhitespace(_text.codeUnitAt(end))) {
        end++;
      }

      final term = _text.substring(start, end);
      _current = Token(
        term: term,
        startOffset: start,
        endOffset: end,
        positionIncrement: 1,
      );
      _position = end;
      return true;
    }

    _current = null;
    return false;
  }

  @override
  Token get currentToken {
    if (_current == null) {
      throw StateError('No active token in WhitespaceTokenizer');
    }
    return _current!;
  }

  @override
  void reset() {
    _position = 0;
    _current = null;
  }

  @override
  void close() {}

  static bool _isWhitespace(int codeUnit) {
    return codeUnit == 32 || // space
        codeUnit == 9 || // tab
        codeUnit == 10 || // newline \n
        codeUnit == 13 || // carriage return \r
        codeUnit == 160; // non-breaking space
  }
}
