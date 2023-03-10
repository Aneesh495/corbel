import '../token.dart';
import '../token_stream.dart';

/// CJK (Chinese, Japanese, Korean) overlapping bi-gram and Latin word tokenizer.
class CJKTokenizer extends TokenStream {
  final String _text;
  final List<Token> _tokens = [];
  int _index = -1;

  CJKTokenizer(this._text) {
    _tokenize();
  }

  void _tokenize() {
    var i = 0;
    final len = _text.length;

    while (i < len) {
      final code = _text.codeUnitAt(i);
      if (_isWhitespace(code)) {
        i++;
        continue;
      }

      if (_isCJK(code)) {
        // CJK character: produce 2-gram with next CJK character
        if (i + 1 < len && _isCJK(_text.codeUnitAt(i + 1))) {
          _tokens.add(Token(
            term: _text.substring(i, i + 2),
            startOffset: i,
            endOffset: i + 2,
            positionIncrement: 1,
          ));
        } else if (i == 0 || !_isCJK(_text.codeUnitAt(i - 1))) {
          _tokens.add(Token(
            term: _text.substring(i, i + 1),
            startOffset: i,
            endOffset: i + 1,
            positionIncrement: 1,
          ));
        }
        i++;
      } else {
        // Alphanumeric sequence
        final start = i;
        while (i < len && !_isWhitespace(_text.codeUnitAt(i)) && !_isCJK(_text.codeUnitAt(i))) {
          i++;
        }
        _tokens.add(Token(
          term: _text.substring(start, i),
          startOffset: start,
          endOffset: i,
          positionIncrement: 1,
        ));
      }
    }
  }

  @override
  bool incrementToken() {
    _index++;
    return _index < _tokens.length;
  }

  @override
  Token get currentToken {
    if (_index < 0 || _index >= _tokens.length) {
      throw StateError('No active token in CJKTokenizer');
    }
    return _tokens[_index];
  }

  @override
  void reset() {
    _index = -1;
  }

  @override
  void close() {}

  static bool _isCJK(int code) {
    return (code >= 0x4E00 && code <= 0x9FFF) || // CJK Unified Ideographs
        (code >= 0x3400 && code <= 0x4DBF) || // CJK Extension A
        (code >= 0x3040 && code <= 0x309F) || // Hiragana
        (code >= 0x30A0 && code <= 0x30FF) || // Katakana
        (code >= 0xAC00 && code <= 0xD7AF); // Hangul Syllables
  }

  static bool _isWhitespace(int code) {
    return code == 32 || code == 9 || code == 10 || code == 13;
  }
}
