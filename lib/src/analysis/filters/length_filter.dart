import '../token.dart';
import 'token_filter.dart';

/// Filters out tokens whose character length is outside [min] and [max].
class LengthFilter extends TokenFilter {
  final int min;
  final int max;
  Token? _current;

  LengthFilter(super.input, {this.min = 2, this.max = 64}) {
    if (min < 0 || max < min) {
      throw ArgumentError('Invalid length bounds: min=$min, max=$max');
    }
  }

  @override
  bool incrementToken() {
    var skippedIncr = 0;
    while (input.incrementToken()) {
      final t = input.currentToken;
      final len = t.term.length;
      if (len >= min && len <= max) {
        _current = t.copyWith(
          positionIncrement: t.positionIncrement + skippedIncr,
        );
        return true;
      }
      skippedIncr += t.positionIncrement;
    }
    _current = null;
    return false;
  }

  @override
  Token get currentToken {
    if (_current == null) {
      throw StateError('No active token in LengthFilter');
    }
    return _current!;
  }

  @override
  void reset() {
    super.reset();
    _current = null;
  }
}
