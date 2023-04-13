import '../token.dart';
import 'token_filter.dart';

/// Filters out high-frequency grammatical stopwords.
class StopFilter extends TokenFilter {
  final Set<String> stopWords;
  Token? _current;

  /// Default set of standard English stopwords.
  static const Set<String> englishStopWords = {
    'a', 'an', 'and', 'are', 'as', 'at', 'be', 'but', 'by', 'for', 'if',
    'in', 'into', 'is', 'it', 'no', 'not', 'of', 'on', 'or', 'such', 'that',
    'the', 'their', 'then', 'there', 'these', 'they', 'this', 'to', 'was',
    'will', 'with'
  };

  StopFilter(super.input, [Set<String>? customStopWords])
      : stopWords = customStopWords ?? englishStopWords;

  @override
  bool incrementToken() {
    var skippedCount = 0;
    while (input.incrementToken()) {
      final t = input.currentToken;
      if (!stopWords.contains(t.term.toLowerCase())) {
        _current = t.copyWith(
          positionIncrement: t.positionIncrement + skippedCount,
        );
        return true;
      }
      skippedCount += t.positionIncrement;
    }
    _current = null;
    return false;
  }

  @override
  Token get currentToken {
    if (_current == null) {
      throw StateError('No active token in StopFilter');
    }
    return _current!;
  }

  @override
  void reset() {
    super.reset();
    _current = null;
  }
}
