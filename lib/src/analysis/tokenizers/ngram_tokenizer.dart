import '../token.dart';
import '../token_stream.dart';

/// Character n-gram tokenizer generating sliding window substrings.
class NGramTokenizer extends TokenStream {
  final String _text;
  final int minGram;
  final int maxGram;
  final List<Token> _tokens = [];
  int _index = -1;

  NGramTokenizer(
    this._text, {
    this.minGram = 2,
    this.maxGram = 3,
  }) {
    if (minGram <= 0 || maxGram < minGram) {
      throw ArgumentError('Invalid gram range: minGram=$minGram, maxGram=$maxGram');
    }
    _buildGrams();
  }

  void _buildGrams() {
    final len = _text.length;
    for (var i = 0; i < len; i++) {
      for (var n = minGram; n <= maxGram; n++) {
        if (i + n <= len) {
          final term = _text.substring(i, i + n);
          _tokens.add(Token(
            term: term,
            startOffset: i,
            endOffset: i + n,
            positionIncrement: 1,
          ));
        }
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
      throw StateError('No active token in NGramTokenizer');
    }
    return _tokens[_index];
  }

  @override
  void reset() {
    _index = -1;
  }

  @override
  void close() {}
}
