import '../phonetic/double_metaphone.dart';
import '../phonetic/metaphone.dart';
import '../phonetic/soundex.dart';
import '../token.dart';
import 'token_filter.dart';

/// Supported phonetic encoding algorithms for full-text token filters.
enum PhoneticAlgorithm {
  soundex,
  metaphone,
  doubleMetaphone,
}

/// Token filter converting words into their phonetic representations (Soundex, Metaphone, Double Metaphone)
/// to enable sound-alike fuzzy matching.
class PhoneticFilter extends TokenFilter {
  final PhoneticAlgorithm algorithm;
  final bool replaceOriginal;
  final List<Token> _pendingTokens = [];
  Token? _current;

  PhoneticFilter(
    super.input, {
    this.algorithm = PhoneticAlgorithm.doubleMetaphone,
    this.replaceOriginal = false,
  });

  @override
  bool incrementToken() {
    if (_pendingTokens.isNotEmpty) {
      _current = _pendingTokens.removeAt(0);
      return true;
    }

    if (input.incrementToken()) {
      final t = input.currentToken;
      final phoneticCodes = _encode(t.term);

      if (replaceOriginal) {
        if (phoneticCodes.isNotEmpty) {
          _current = Token(
            term: phoneticCodes.first,
            startOffset: t.startOffset,
            endOffset: t.endOffset,
            positionIncrement: t.positionIncrement,
            positionLength: t.positionLength,
          );
          for (var i = 1; i < phoneticCodes.length; i++) {
            _pendingTokens.add(Token(
              term: phoneticCodes[i],
              startOffset: t.startOffset,
              endOffset: t.endOffset,
              positionIncrement: 0,
              positionLength: t.positionLength,
            ));
          }
        } else {
          _current = t;
        }
      } else {
        // Emit original token first, then phonetic aliases with positionIncrement = 0
        _current = t;
        for (final code in phoneticCodes) {
          if (code != t.term) {
            _pendingTokens.add(Token(
              term: code,
              startOffset: t.startOffset,
              endOffset: t.endOffset,
              positionIncrement: 0,
              positionLength: t.positionLength,
            ));
          }
        }
      }
      return true;
    }

    _current = null;
    return false;
  }

  List<String> _encode(String term) {
    switch (algorithm) {
      case PhoneticAlgorithm.soundex:
        final code = Soundex.encode(term);
        return code.isNotEmpty ? [code] : const [];

      case PhoneticAlgorithm.metaphone:
        final code = Metaphone.encode(term);
        return code.isNotEmpty ? [code] : const [];

      case PhoneticAlgorithm.doubleMetaphone:
        final res = DoubleMetaphone.encode(term);
        final list = <String>[];
        if (res.primary.isNotEmpty) list.add(res.primary);
        if (res.alternate.isNotEmpty && res.alternate != res.primary) {
          list.add(res.alternate);
        }
        return list;
    }
  }

  @override
  Token get currentToken {
    if (_current == null) {
      throw StateError('No active token in PhoneticFilter');
    }
    return _current!;
  }

  @override
  void reset() {
    super.reset();
    _pendingTokens.clear();
    _current = null;
  }
}
