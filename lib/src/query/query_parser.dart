import '../analysis/analyzer.dart';
import 'boolean_query.dart';
import 'fuzzy_query.dart';
import 'phrase_query.dart';
import 'prefix_query.dart';
import 'query.dart';
import 'range_query.dart';
import 'term_query.dart';
import 'wildcard_query.dart';

/// Recursive descent parser translating Lucene-style search query strings into AST [Query] objects.
class QueryParser {
  final String defaultField;
  final Analyzer analyzer;

  QueryParser({
    required this.defaultField,
    required this.analyzer,
  });

  /// Parses input [queryString] into a compiled AST [Query].
  Query parse(String queryString) {
    final tokens = _tokenize(queryString);
    if (tokens.isEmpty) {
      return const BooleanQuery(clauses: []);
    }

    final state = _ParserState(tokens);
    final query = _parseDisjunction(state);
    return query;
  }

  Query _parseDisjunction(_ParserState state) {
    final clauses = <BooleanClause>[];
    var currentOccur = Occur.should;

    while (!state.isEof) {
      final token = state.peek();

      if (token.type == _TokenType.rParen) {
        break;
      }

      if (token.type == _TokenType.opOr) {
        state.consume();
        currentOccur = Occur.should;
        continue;
      }

      if (token.type == _TokenType.opAnd) {
        state.consume();
        // Retroactively set previous clause to MUST if it was SHOULD
        if (clauses.isNotEmpty && clauses.last.occur == Occur.should) {
          final last = clauses.removeLast();
          clauses.add(BooleanClause(query: last.query, occur: Occur.must));
        }
        currentOccur = Occur.must;
        continue;
      }

      if (token.type == _TokenType.opNot) {
        state.consume();
        currentOccur = Occur.mustNot;
        continue;
      }

      if (token.type == _TokenType.plus) {
        state.consume();
        currentOccur = Occur.must;
        continue;
      }

      if (token.type == _TokenType.minus) {
        state.consume();
        currentOccur = Occur.mustNot;
        continue;
      }

      final subQuery = _parsePrimary(state);
      clauses.add(BooleanClause(query: subQuery, occur: currentOccur));
      currentOccur = Occur.should; // Reset default occur
    }

    if (clauses.isEmpty) {
      return const BooleanQuery(clauses: []);
    }

    if (clauses.length == 1 && clauses.first.occur == Occur.should) {
      return clauses.first.query;
    }

    return BooleanQuery(clauses: clauses);
  }

  Query _parsePrimary(_ParserState state) {
    final token = state.peek();

    // Check for field specification: e.g. "field:value"
    var field = defaultField;
    if (token.type == _TokenType.term && state.peekNext()?.type == _TokenType.colon) {
      field = state.consume().text;
      state.consume(); // Consume colon ':'
    }

    final current = state.peek();

    // 1. Parenthesized sub-expression
    if (current.type == _TokenType.lParen) {
      state.consume(); // Consume '('
      final sub = _parseDisjunction(state);
      if (state.peek().type == _TokenType.rParen) {
        state.consume(); // Consume ')'
      }
      return _applyBoost(sub, state);
    }

    // 2. Phrase: "..."
    if (current.type == _TokenType.phrase) {
      final phraseToken = state.consume();
      var slop = 0;
      if (state.peek().type == _TokenType.tilde) {
        state.consume();
        if (state.peek().type == _TokenType.number) {
          slop = int.tryParse(state.consume().text) ?? 0;
        }
      }

      final terms = _analyzeTerms(phraseToken.text);
      if (terms.length <= 1) {
        final termText = terms.isNotEmpty ? terms.first : phraseToken.text;
        final q = TermQuery(field: field, term: termText);
        return _applyBoost(q, state);
      }

      final pq = PhraseQuery(field: field, terms: terms, slop: slop);
      return _applyBoost(pq, state);
    }

    // 3. Range: [min TO max] or {min TO max}
    if (current.type == _TokenType.lBracket || current.type == _TokenType.lBrace) {
      final isMinInclusive = current.type == _TokenType.lBracket;
      state.consume(); // Consume '[' or '{'

      final minText = state.peek().type != _TokenType.opTo ? state.consume().text : null;
      if (state.peek().type == _TokenType.opTo) {
        state.consume(); // Consume 'TO'
      }
      final maxText = (state.peek().type != _TokenType.rBracket && state.peek().type != _TokenType.rBrace)
          ? state.consume().text
          : null;

      final isMaxInclusive = state.peek().type == _TokenType.rBracket;
      if (state.peek().type == _TokenType.rBracket || state.peek().type == _TokenType.rBrace) {
        state.consume(); // Consume ']' or '}'
      }

      // Check if numeric range
      final minNum = minText != null && minText != '*' ? num.tryParse(minText) : null;
      final maxNum = maxText != null && maxText != '*' ? num.tryParse(maxText) : null;

      if ((minNum != null || minText == '*') && (maxNum != null || maxText == '*')) {
        final rq = NumericRangeQuery(
          field: field,
          min: minNum,
          max: maxNum,
          includeMin: isMinInclusive,
          includeMax: isMaxInclusive,
        );
        return _applyBoost(rq, state);
      }

      final trq = TermRangeQuery(
        field: field,
        lowerTerm: minText != '*' ? minText : null,
        upperTerm: maxText != '*' ? maxText : null,
        includeLower: isMinInclusive,
        includeUpper: isMaxInclusive,
      );
      return _applyBoost(trq, state);
    }

    // 4. Term, Prefix, Wildcard, or Fuzzy
    final termToken = state.consume();
    final text = termToken.text;

    // Check for fuzzy '~'
    if (state.peek().type == _TokenType.tilde) {
      state.consume();
      var edits = 2;
      if (state.peek().type == _TokenType.number) {
        edits = int.tryParse(state.consume().text) ?? 2;
      }
      final fq = FuzzyQuery(field: field, term: text.toLowerCase(), maxEdits: edits);
      return _applyBoost(fq, state);
    }

    // Check for prefix '*'
    if (text.endsWith('*') && !text.contains('?') && text.length > 1) {
      final prefix = text.substring(0, text.length - 1).toLowerCase();
      final pq = PrefixQuery(field: field, prefix: prefix);
      return _applyBoost(pq, state);
    }

    // Check for wildcard '*' or '?'
    if (text.contains('*') || text.contains('?')) {
      final wq = WildcardQuery(field: field, pattern: text.toLowerCase());
      return _applyBoost(wq, state);
    }

    // Standard TermQuery or analyzed tokens
    final analyzed = _analyzeTerms(text);
    if (analyzed.isEmpty) {
      final tq = TermQuery(field: field, term: text.toLowerCase());
      return _applyBoost(tq, state);
    }

    if (analyzed.length == 1) {
      final tq = TermQuery(field: field, term: analyzed.first);
      return _applyBoost(tq, state);
    }

    final clauses = analyzed.map((t) {
      return BooleanClause(
        query: TermQuery(field: field, term: t),
        occur: Occur.should,
      );
    }).toList();

    return _applyBoost(BooleanQuery(clauses: clauses), state);
  }

  Query _applyBoost(Query query, _ParserState state) {
    if (state.peek().type == _TokenType.caret) {
      state.consume(); // Consume '^'
      if (state.peek().type == _TokenType.number || state.peek().type == _TokenType.term) {
        final boostVal = double.tryParse(state.consume().text);
        if (boostVal != null) {
          // Wrap in a boosted clause or recreate
          return _withBoost(query, boostVal);
        }
      }
    }
    return query;
  }

  Query _withBoost(Query query, double boost) {
    if (query is TermQuery) {
      return TermQuery(field: query.field, term: query.term, boost: boost);
    }
    if (query is BooleanQuery) {
      return BooleanQuery(
        clauses: query.clauses,
        minimumNumberShouldMatch: query.minimumNumberShouldMatch,
        boost: boost,
      );
    }
    if (query is PhraseQuery) {
      return PhraseQuery(field: query.field, terms: query.terms, slop: query.slop, boost: boost);
    }
    if (query is PrefixQuery) {
      return PrefixQuery(field: query.field, prefix: query.prefix, boost: boost);
    }
    if (query is WildcardQuery) {
      return WildcardQuery(field: query.field, pattern: query.pattern, boost: boost);
    }
    if (query is FuzzyQuery) {
      return FuzzyQuery(
        field: query.field,
        term: query.term,
        maxEdits: query.maxEdits,
        prefixLength: query.prefixLength,
        boost: boost,
      );
    }
    if (query is NumericRangeQuery) {
      return NumericRangeQuery(
        field: query.field,
        min: query.min,
        max: query.max,
        includeMin: query.includeMin,
        includeMax: query.includeMax,
        boost: boost,
      );
    }
    return query;
  }

  List<String> _analyzeTerms(String text) {
    final stream = analyzer.tokenStream(defaultField, text);
    return stream.toTermsList();
  }

  List<_Token> _tokenize(String input) {
    final tokens = <_Token>[];
    var i = 0;

    while (i < input.length) {
      final ch = input[i];

      // Whitespace
      if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n') {
        i++;
        continue;
      }

      // Single char punctuation
      if (ch == ':') {
        tokens.add(const _Token(_TokenType.colon, ':'));
        i++;
        continue;
      }
      if (ch == '(') {
        tokens.add(const _Token(_TokenType.lParen, '('));
        i++;
        continue;
      }
      if (ch == ')') {
        tokens.add(const _Token(_TokenType.rParen, ')'));
        i++;
        continue;
      }
      if (ch == '[') {
        tokens.add(const _Token(_TokenType.lBracket, '['));
        i++;
        continue;
      }
      if (ch == ']') {
        tokens.add(const _Token(_TokenType.rBracket, ']'));
        i++;
        continue;
      }
      if (ch == '{') {
        tokens.add(const _Token(_TokenType.lBrace, '{'));
        i++;
        continue;
      }
      if (ch == '}') {
        tokens.add(const _Token(_TokenType.rBrace, '}'));
        i++;
        continue;
      }
      if (ch == '+') {
        tokens.add(const _Token(_TokenType.plus, '+'));
        i++;
        continue;
      }
      if (ch == '-') {
        tokens.add(const _Token(_TokenType.minus, '-'));
        i++;
        continue;
      }
      if (ch == '^') {
        tokens.add(const _Token(_TokenType.caret, '^'));
        i++;
        continue;
      }
      if (ch == '~') {
        tokens.add(const _Token(_TokenType.tilde, '~'));
        i++;
        continue;
      }

      // Quoted Phrase
      if (ch == '"') {
        i++;
        final start = i;
        while (i < input.length && input[i] != '"') {
          i++;
        }
        final phraseStr = input.substring(start, i);
        if (i < input.length && input[i] == '"') i++; // Skip closing quote
        tokens.add(_Token(_TokenType.phrase, phraseStr));
        continue;
      }

      // Number or Term
      final start = i;
      while (i < input.length) {
        final c = input[i];
        if (c == ' ' || c == '\t' || c == '\r' || c == '\n' ||
            c == ':' || c == '(' || c == ')' || c == '[' || c == ']' ||
            c == '{' || c == '}' || c == '+' || c == '-' || c == '^' ||
            c == '~' || c == '"') {
          break;
        }
        i++;
      }

      final rawWord = input.substring(start, i);
      if (rawWord == 'AND') {
        tokens.add(const _Token(_TokenType.opAnd, 'AND'));
      } else if (rawWord == 'OR') {
        tokens.add(const _Token(_TokenType.opOr, 'OR'));
      } else if (rawWord == 'NOT') {
        tokens.add(const _Token(_TokenType.opNot, 'NOT'));
      } else if (rawWord == 'TO') {
        tokens.add(const _Token(_TokenType.opTo, 'TO'));
      } else if (num.tryParse(rawWord) != null) {
        tokens.add(_Token(_TokenType.number, rawWord));
      } else {
        tokens.add(_Token(_TokenType.term, rawWord));
      }
    }

    tokens.add(const _Token(_TokenType.eof, ''));
    return tokens;
  }
}

enum _TokenType {
  term,
  phrase,
  number,
  colon,
  lParen,
  rParen,
  lBracket,
  rBracket,
  lBrace,
  rBrace,
  plus,
  minus,
  caret,
  tilde,
  opAnd,
  opOr,
  opNot,
  opTo,
  eof,
}

class _Token {
  final _TokenType type;
  final String text;

  const _Token(this.type, this.text);
}

class _ParserState {
  final List<_Token> tokens;
  int _idx = 0;

  _ParserState(this.tokens);

  bool get isEof => _idx >= tokens.length || tokens[_idx].type == _TokenType.eof;

  _Token peek() => _idx < tokens.length ? tokens[_idx] : const _Token(_TokenType.eof, '');

  _Token? peekNext() => _idx + 1 < tokens.length ? tokens[_idx + 1] : null;

  _Token consume() {
    final t = peek();
    if (!isEof) _idx++;
    return t;
  }
}
