import '../token.dart';
import '../token_stream.dart';
import 'token_filter.dart';

/// Normalizes token text to lowercase.
class LowerCaseFilter extends TokenFilter {
  Token? _current;

  LowerCaseFilter(super.input);

  @override
  bool incrementToken() {
    if (input.incrementToken()) {
      final t = input.currentToken;
      _current = t.copyWith(term: t.term.toLowerCase());
      return true;
    }
    _current = null;
    return false;
  }

  @override
  Token get currentToken {
    if (_current == null) {
      throw StateError('No active token in LowerCaseFilter');
    }
    return _current!;
  }

  @override
  void reset() {
    super.reset();
    _current = null;
  }
}
