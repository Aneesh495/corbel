import '../token.dart';
import 'porter_stemmer.dart';
import 'token_filter.dart';

/// Stemmer filter reducing English terms to their linguistic morphological roots.
class StemmerFilter extends TokenFilter {
  Token? _current;

  StemmerFilter(super.input);

  @override
  bool incrementToken() {
    if (input.incrementToken()) {
      final t = input.currentToken;
      final stemmed = PorterStemmer.stem(t.term);
      _current = t.copyWith(term: stemmed);
      return true;
    }
    _current = null;
    return false;
  }

  @override
  Token get currentToken {
    if (_current == null) {
      throw StateError('No active token in StemmerFilter');
    }
    return _current!;
  }

  @override
  void reset() {
    super.reset();
    _current = null;
  }
}
