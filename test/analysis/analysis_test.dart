import 'package:corbel/src/analysis/analyzer.dart';
import 'package:corbel/src/analysis/filters/ascii_folding_filter.dart';
import 'package:corbel/src/analysis/filters/length_filter.dart';
import 'package:corbel/src/analysis/filters/lowercase_filter.dart';
import 'package:corbel/src/analysis/filters/porter_stemmer.dart';
import 'package:corbel/src/analysis/filters/shingle_filter.dart';
import 'package:corbel/src/analysis/filters/stemmer_filter.dart';
import 'package:corbel/src/analysis/filters/stop_filter.dart';
import 'package:corbel/src/analysis/filters/synonym_filter.dart';
import 'package:corbel/src/analysis/tokenizers/cjk_tokenizer.dart';
import 'package:corbel/src/analysis/tokenizers/code_tokenizer.dart';
import 'package:corbel/src/analysis/tokenizers/ngram_tokenizer.dart';
import 'package:corbel/src/analysis/tokenizers/pattern_tokenizer.dart';
import 'package:corbel/src/analysis/tokenizers/standard_tokenizer.dart';
import 'package:corbel/src/analysis/tokenizers/whitespace_tokenizer.dart';
import 'package:test/test.dart';

void main() {
  group('Tokenizer Tests', () {
    test('StandardTokenizer splits on punctuation and records offsets', () {
      final tokenizer = StandardTokenizer('Fast, distributed inverted-index!');
      final tokens = tokenizer.toList();

      expect(tokens.map((t) => t.term).toList(),
          equals(['Fast', 'distributed', 'inverted', 'index']));
      expect(tokens[0].startOffset, equals(0));
      expect(tokens[0].endOffset, equals(4));
      expect(tokens[1].startOffset, equals(6));
      expect(tokens[1].endOffset, equals(17));
    });

    test('WhitespaceTokenizer preserves punctuation symbols', () {
      final tokenizer = WhitespaceTokenizer('git commit -m "feat(core): test"');
      final tokens = tokenizer.toList();

      expect(tokens.map((t) => t.term).toList(),
          equals(['git', 'commit', '-m', '"feat(core):', 'test"']));
    });

    test('PatternTokenizer splits based on regex delimiter', () {
      final tokenizer = PatternTokenizer('alpha;beta::gamma;delta', RegExp(r'[:;]+'));
      final tokens = tokenizer.toList();

      expect(tokens.map((t) => t.term).toList(),
          equals(['alpha', 'beta', 'gamma', 'delta']));
    });

    test('NGramTokenizer generates correct n-gram sliding window', () {
      final tokenizer = NGramTokenizer('corbel', minGram: 2, maxGram: 3);
      final terms = tokenizer.toTermsList();

      expect(terms, containsAll(['co', 'cor', 'or', 'orb', 'rb', 'rbe', 'be', 'bel', 'el']));
    });

    test('CJKTokenizer generates overlapping bi-grams for CJK scripts', () {
      final tokenizer = CJKTokenizer('搜索引擎 search');
      final terms = tokenizer.toTermsList();

      // '搜索', '索引', '引擎', 'search'
      expect(terms, equals(['搜索', '索引', '引擎', 'search']));
    });

    test('CodeTokenizer decomposes camelCase and snake_case identifiers', () {
      final tokenizer = CodeTokenizer('RoaringBitmap_IndexWriter');
      final terms = tokenizer.toTermsList();

      expect(terms, containsAll(['RoaringBitmap_IndexWriter', 'Roaring', 'Bitmap', 'Index', 'Writer']));
    });
  });

  group('Filter Tests', () {
    test('LowerCaseFilter converts terms to lowercase', () {
      final stream = LowerCaseFilter(StandardTokenizer('CORBEL Inverted Index'));
      expect(stream.toTermsList(), equals(['corbel', 'inverted', 'index']));
    });

    test('AsciiFoldingFilter removes diacritics', () {
      final stream = AsciiFoldingFilter(StandardTokenizer('café résumé münchen'));
      expect(stream.toTermsList(), equals(['cafe', 'resume', 'munchen']));
    });

    test('StopFilter removes stopwords and adjusts position increment', () {
      final stream = StopFilter(LowerCaseFilter(StandardTokenizer('the engine of search')));
      final tokens = stream.toList();

      expect(tokens.map((t) => t.term).toList(), equals(['engine', 'search']));
      expect(tokens[0].positionIncrement, equals(2)); // skipped 'the'
      expect(tokens[1].positionIncrement, equals(2)); // skipped 'of'
    });

    test('PorterStemmer reduces words to linguistic roots', () {
      expect(PorterStemmer.stem('running'), equals('run'));
      expect(PorterStemmer.stem('retrieval'), equals('retriev'));
      expect(PorterStemmer.stem('connections'), equals('connect'));
      expect(PorterStemmer.stem('relational'), equals('relat'));
      expect(PorterStemmer.stem('distributed'), equals('distribut'));

      final stream = StemmerFilter(StandardTokenizer('connecting distributed databases'));
      expect(stream.toTermsList(), equals(['connect', 'distribut', 'databas']));
    });

    test('SynonymFilter emits colocated synonyms with positionIncrement 0', () {
      final stream = SynonymFilter(
        StandardTokenizer('fast search'),
        {
          'fast': ['quick', 'rapid'],
        },
      );
      final tokens = stream.toList();

      expect(tokens.length, equals(4));
      expect(tokens[0].term, equals('fast'));
      expect(tokens[0].positionIncrement, equals(1));
      expect(tokens[1].term, equals('quick'));
      expect(tokens[1].positionIncrement, equals(0));
      expect(tokens[2].term, equals('rapid'));
      expect(tokens[2].positionIncrement, equals(0));
      expect(tokens[3].term, equals('search'));
      expect(tokens[3].positionIncrement, equals(1));
    });

    test('LengthFilter prunes tokens outside length bounds', () {
      final stream = LengthFilter(
        StandardTokenizer('a quick brown fox jumps over the lazy dog'),
        min: 4,
        max: 5,
      );
      expect(stream.toTermsList(), equals(['quick', 'brown', 'jumps', 'over', 'lazy']));
    });

    test('ShingleFilter generates word n-gram shingles', () {
      final stream = ShingleFilter(
        StandardTokenizer('high throughput vector search'),
        minShingleSize: 2,
        maxShingleSize: 2,
        outputUnigrams: true,
      );
      final terms = stream.toTermsList();

      expect(terms, containsAll([
        'high', 'high throughput',
        'throughput', 'throughput vector',
        'vector', 'vector search',
        'search',
      ]));
    });
  });

  group('Analyzer Pipeline Tests', () {
    test('StandardAnalyzer pipeline', () {
      const analyzer = StandardAnalyzer();
      final stream = analyzer.tokenStream('body', 'The FAST Distributed Search Engine!');
      expect(stream.toTermsList(), equals(['fast', 'distributed', 'search', 'engine']));
    });

    test('EnglishAnalyzer pipeline with stemming and ascii folding', () {
      const analyzer = EnglishAnalyzer();
      final stream = analyzer.tokenStream('body', 'The CAFÉ provides high-speed connections');
      expect(stream.toTermsList(), equals(['cafe', 'provid', 'high', 'speed', 'connect']));
    });

    test('CodeAnalyzer pipeline', () {
      const analyzer = CodeAnalyzer();
      final stream = analyzer.tokenStream('code', 'class HttpConnectionPoolManager {}');
      final terms = stream.toTermsList();

      expect(terms, containsAll(['class', 'httpconnectionpoolmanager', 'http', 'connection', 'pool', 'manager']));
    });
  });
}
