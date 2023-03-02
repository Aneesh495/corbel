import 'token.dart';

/// Abstract stream producing sequential tokens from an analyzed text field.
abstract class TokenStream {
  /// Advances stream to next token. Returns true if token available, false if exhausted.
  bool incrementToken();

  /// Currently active token. Throws StateError if stream has not started or is exhausted.
  Token get currentToken;

  /// Resets the stream to initial state for reuse over the same or new input.
  void reset();

  /// Releases resources associated with stream.
  void close();

  /// Consumes the entire stream and returns tokens as a List.
  List<Token> toList() {
    final tokens = <Token>[];
    reset();
    while (incrementToken()) {
      tokens.add(currentToken);
    }
    return tokens;
  }

  /// Consumes stream and extracts only term strings.
  List<String> toTermsList() {
    return toList().map((t) => t.term).toList();
  }
}

/// TokenStream backed by a pre-computed in-memory list of tokens.
class ListTokenStream extends TokenStream {
  final List<Token> _tokens;
  int _index = -1;

  ListTokenStream(this._tokens);

  @override
  bool incrementToken() {
    _index++;
    return _index < _tokens.length;
  }

  @override
  Token get currentToken {
    if (_index < 0 || _index >= _tokens.length) {
      throw StateError('TokenStream is not pointing at a valid token');
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
