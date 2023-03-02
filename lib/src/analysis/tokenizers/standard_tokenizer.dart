import '../token.dart';
import '../token_stream.dart';

/// Standard tokenizer segmenting text on alphanumeric word boundaries.
class StandardTokenizer extends TokenStream {
  final String _text;
  int _position = 0;
  Token? _current;

  StandardTokenizer(this._text);

  @override
  bool incrementToken() {
    while (_position < _text.length) {
      // Find start of next alphanumeric word
      final start = _position;
      final codeUnit = _text.codeUnitAt(start);
      if (!_isWordChar(codeUnit)) {
        _position++;
        continue;
      }

      // Word boundary scan
      var end = start + 1;
      while (end < _text.length && _isWordChar(_text.codeUnitAt(end))) {
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
      throw StateError('No active token in StandardTokenizer');
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

  static bool _isWordChar(int codeUnit) {
    // Alphanumeric ASCII and extended Unicode letters
    return (codeUnit >= 48 && codeUnit <= 57) || // 0-9
        (codeUnit >= 65 && codeUnit <= 90) || // A-Z
        (codeUnit >= 97 && codeUnit <= 122) || // a-z
        (codeUnit >= 192); // Extended Latin and Unicode scripts
  }
}
