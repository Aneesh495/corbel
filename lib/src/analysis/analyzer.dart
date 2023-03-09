import 'filters/ascii_folding_filter.dart';
import 'filters/length_filter.dart';
import 'filters/lowercase_filter.dart';
import 'filters/stemmer_filter.dart';
import 'filters/stop_filter.dart';
import 'token_stream.dart';
import 'tokenizers/code_tokenizer.dart';
import 'tokenizers/standard_tokenizer.dart';
import 'tokenizers/whitespace_tokenizer.dart';

/// Abstract text analysis pipeline converting raw text into an analyzed TokenStream.
abstract class Analyzer {
  const Analyzer();

  /// Creates a TokenStream analyzing the given text string.
  TokenStream tokenStream(String fieldName, String text);

  /// Resolves built-in analyzer by identifier.
  static Analyzer byName(String name) {
    switch (name.toLowerCase()) {
      case 'standard':
        return const StandardAnalyzer();
      case 'english':
        return const EnglishAnalyzer();
      case 'code':
        return const CodeAnalyzer();
      case 'whitespace':
        return const WhitespaceAnalyzer();
      default:
        throw ArgumentError('Unknown analyzer: $name');
    }
  }
}

/// Standard analyzer: StandardTokenizer -> LowerCaseFilter -> StopFilter.
class StandardAnalyzer extends Analyzer {
  final Set<String>? stopWords;

  const StandardAnalyzer([this.stopWords]);

  @override
  TokenStream tokenStream(String fieldName, String text) {
    var stream = StandardTokenizer(text) as TokenStream;
    stream = LowerCaseFilter(stream);
    stream = StopFilter(stream, stopWords);
    return stream;
  }
}

/// English analyzer: StandardTokenizer -> LowerCaseFilter -> AsciiFoldingFilter -> StopFilter -> StemmerFilter.
class EnglishAnalyzer extends Analyzer {
  final Set<String>? stopWords;

  const EnglishAnalyzer([this.stopWords]);

  @override
  TokenStream tokenStream(String fieldName, String text) {
    var stream = StandardTokenizer(text) as TokenStream;
    stream = LowerCaseFilter(stream);
    stream = AsciiFoldingFilter(stream);
    stream = StopFilter(stream, stopWords);
    stream = StemmerFilter(stream);
    return stream;
  }
}

/// Code analyzer: CodeTokenizer -> LowerCaseFilter -> LengthFilter(min: 2).
class CodeAnalyzer extends Analyzer {
  final bool emitOriginal;

  const CodeAnalyzer({this.emitOriginal = true});

  @override
  TokenStream tokenStream(String fieldName, String text) {
    var stream = CodeTokenizer(text, emitOriginal: emitOriginal) as TokenStream;
    stream = LowerCaseFilter(stream);
    stream = LengthFilter(stream, min: 2, max: 128);
    return stream;
  }
}

/// Whitespace analyzer: WhitespaceTokenizer -> LowerCaseFilter.
class WhitespaceAnalyzer extends Analyzer {
  const WhitespaceAnalyzer();

  @override
  TokenStream tokenStream(String fieldName, String text) {
    var stream = WhitespaceTokenizer(text) as TokenStream;
    stream = LowerCaseFilter(stream);
    return stream;
  }
}

/// Custom analyzer composed of a custom tokenizer factory and sequential token filters.
class CustomAnalyzer extends Analyzer {
  final TokenStream Function(String text) tokenizerFactory;
  final List<TokenStream Function(TokenStream input)> filterFactories;

  const CustomAnalyzer({
    required this.tokenizerFactory,
    this.filterFactories = const [],
  });

  @override
  TokenStream tokenStream(String fieldName, String text) {
    var stream = tokenizerFactory(text);
    for (final filterFactory in filterFactories) {
      stream = filterFactory(stream);
    }
    return stream;
  }
}
