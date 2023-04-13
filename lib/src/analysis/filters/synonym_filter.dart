import '../token.dart';
import 'token_filter.dart';

/// Synonym filter expanding matching terms with synonym tokens at positionIncrement = 0.
class SynonymFilter extends TokenFilter {
  final Map<String, List<String>> synonymMap;
  final List<Token> _pendingSynonyms = [];
  Token? _current;

  SynonymFilter(super.input, this.synonymMap);

  @override
  bool incrementToken() {
    if (_pendingSynonyms.isNotEmpty) {
      _current = _pendingSynonyms.removeAt(0);
      return true;
    }

    if (input.incrementToken()) {
      final t = input.currentToken;
      _current = t;

      final synonyms = synonymMap[t.term.toLowerCase()];
      if (synonyms != null) {
        for (final syn in synonyms) {
          _pendingSynonyms.add(Token(
            term: syn,
            startOffset: t.startOffset,
            endOffset: t.endOffset,
            positionIncrement: 0, // Inverted index synonym colocated at same position
            positionLength: t.positionLength,
          ));
        }
      }
      return true;
    }

    _current = null;
    return false;
  }

  @override
  Token get currentToken {
    if (_current == null) {
      throw StateError('No active token in SynonymFilter');
    }
    return _current!;
  }

  @override
  void reset() {
    super.reset();
    _pendingSynonyms.clear();
    _current = null;
  }
}
