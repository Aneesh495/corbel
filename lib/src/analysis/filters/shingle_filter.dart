import '../token.dart';
import 'token_filter.dart';

/// Shingle filter constructing word n-gram tuples from consecutive tokens.
class ShingleFilter extends TokenFilter {
  final int minShingleSize;
  final int maxShingleSize;
  final String tokenSeparator;
  final bool outputUnigrams;

  final List<Token> _window = [];
  final List<Token> _pendingShingles = [];
  Token? _current;

  ShingleFilter(
    super.input, {
    this.minShingleSize = 2,
    this.maxShingleSize = 2,
    this.tokenSeparator = ' ',
    this.outputUnigrams = true,
  }) {
    if (minShingleSize < 2 || maxShingleSize < minShingleSize) {
      throw ArgumentError('Invalid shingle size bounds: min=$minShingleSize, max=$maxShingleSize');
    }
  }

  @override
  bool incrementToken() {
    if (_pendingShingles.isNotEmpty) {
      _current = _pendingShingles.removeAt(0);
      return true;
    }

    while (input.incrementToken()) {
      final t = input.currentToken;
      _window.add(t);

      if (outputUnigrams) {
        _pendingShingles.add(t);
      }

      for (var size = minShingleSize; size <= maxShingleSize; size++) {
        if (_window.length >= size) {
          final sub = _window.sublist(_window.length - size);
          final term = sub.map((tok) => tok.term).join(tokenSeparator);
          _pendingShingles.add(Token(
            term: term,
            startOffset: sub.first.startOffset,
            endOffset: sub.last.endOffset,
            positionIncrement: outputUnigrams ? 0 : 1,
            positionLength: size,
          ));
        }
      }

      if (_window.length > maxShingleSize) {
        _window.removeAt(0);
      }

      if (_pendingShingles.isNotEmpty) {
        _current = _pendingShingles.removeAt(0);
        return true;
      }
    }

    _current = null;
    return false;
  }

  @override
  Token get currentToken {
    if (_current == null) {
      throw StateError('No active token in ShingleFilter');
    }
    return _current!;
  }

  @override
  void reset() {
    super.reset();
    _window.clear();
    _pendingShingles.clear();
    _current = null;
  }
}
