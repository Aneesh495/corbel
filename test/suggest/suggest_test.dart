import 'package:corbel/corbel.dart';
import 'package:test/test.dart';

void main() {
  group('Completion Suggester Tests', () {
    test('exact prefix autocomplete orders by weight descending', () {
      final suggester = CompletionSuggester();

      suggester.add('search engine', 10.0, {'type': 'system'});
      suggester.add('search algorithm', 5.0, {'type': 'algo'});
      suggester.add('searching', 2.0);
      suggester.add('sorting algorithm', 8.0);
      suggester.add('scalable database', 12.0);

      expect(suggester.entryCount, equals(5));

      final results = suggester.suggest('sea', const CompletionOptions(maxResults: 3));
      expect(results.length, equals(3));
      expect(results[0].text, equals('search engine'));
      expect(results[0].score, equals(10.0));
      expect(results[0].payload, equals({'type': 'system'}));
      expect(results[1].text, equals('search algorithm'));
      expect(results[2].text, equals('searching'));

      final nonExistent = suggester.suggest('xyz');
      expect(nonExistent, isEmpty);
    });

    test('fuzzy prefix autocomplete matches across typos', () {
      final suggester = CompletionSuggester();

      suggester.add('distributed systems', 20.0);
      suggester.add('database index', 15.0);
      suggester.add('data compression', 10.0);

      // Query "databae" with typo 'e' for 's'
      final results = suggester.suggest(
        'databae',
        const CompletionOptions(
          maxResults: 2,
          fuzzy: true,
          maxEdits: 1,
          prefixLength: 3,
        ),
      );

      expect(results, isNotEmpty);
      expect(results.first.text, equals('database index'));
      expect(results.first.distance, equals(1));
    });
  });

  group('SymSpell Spelling Correction Tests', () {
    late SymSpell symSpell;

    setUp(() {
      symSpell = SymSpell(maxDictionaryEditDistance: 2, prefixLength: 7);
      symSpell.createDictionaryEntry('database', 1000);
      symSpell.createDictionaryEntry('data', 2000);
      symSpell.createDictionaryEntry('algorithm', 800);
      symSpell.createDictionaryEntry('quick', 500);
      symSpell.createDictionaryEntry('brown', 400);
      symSpell.createDictionaryEntry('fox', 600);
      symSpell.createDictionaryEntry('jumps', 300);
    });

    test('Damerau-Levenshtein calculates insertions, deletions, substitutions, and transpositions', () {
      // Identical strings
      expect(SymSpell.damerauLevenshteinDistance('hello', 'hello', 2), equals(0));

      // 1 deletion
      expect(SymSpell.damerauLevenshteinDistance('data', 'dat', 2), equals(1));

      // 1 insertion
      expect(SymSpell.damerauLevenshteinDistance('dat', 'data', 2), equals(1));

      // 1 substitution
      expect(SymSpell.damerauLevenshteinDistance('data', 'date', 2), equals(1));

      // 1 adjacent transposition (Damerau distance = 1, regular Levenshtein = 2)
      expect(SymSpell.damerauLevenshteinDistance('quikc', 'quick', 2), equals(1));

      // Beyond max distance
      expect(SymSpell.damerauLevenshteinDistance('data', 'completely_different', 2), equals(3));
    });

    test('single word lookup corrects typos and ranks by frequency', () {
      // Typo with transposition: "quikc" -> "quick"
      final results1 = symSpell.lookup('quikc', verbosity: SuggestVerbosity.top);
      expect(results1, isNotEmpty);
      expect(results1.first.text, equals('quick'));
      expect(results1.first.distance, equals(1));

      // Typo with missing char: "databae" -> "database"
      final results2 = symSpell.lookup('databae', verbosity: SuggestVerbosity.closest);
      expect(results2, isNotEmpty);
      expect(results2.first.text, equals('database'));

      // Exact match returns distance 0
      final exact = symSpell.lookup('data', verbosity: SuggestVerbosity.top);
      expect(exact.first.text, equals('data'));
      expect(exact.first.distance, equals(0));
    });

    test('lookupCompound corrects multi-word sentence', () {
      // "quikc brwon fxo" -> "quick brown fox"
      final compound = symSpell.lookupCompound('quikc brwon fxo');
      expect(compound, isNotEmpty);
      expect(compound.first.text, equals('quick brown fox'));
      expect(compound.first.distance, equals(3)); // 1 edit per word
    });
  });

  group('DirectSpellChecker Live Segment Tests', () {
    late Directory dir;
    late Schema schema;
    late SegmentReader segmentReader;

    setUp(() {
      dir = RAMDirectory();
      schema = Schema(
        idFieldName: 'id',
        fields: {
          'id': FieldDefinition.string('id'),
          'body': FieldDefinition.text('body'),
        },
      );

      final writer = SegmentWriter(
        segmentName: '_suggest_seg_0',
        schema: schema,
        directory: dir,
      );

      writer.addDocument(Document(
        id: '1',
        fields: [
          Field.string('id', '1'),
          Field.text('body', 'distributed consensus algorithms using raft protocol'),
        ],
      ));

      writer.addDocument(Document(
        id: '2',
        fields: [
          Field.string('id', '2'),
          Field.text('body', 'high throughput distributed database storage engine'),
        ],
      ));

      writer.addDocument(Document(
        id: '3',
        fields: [
          Field.string('id', '3'),
          Field.text('body', 'database replication across cluster nodes'),
        ],
      ));

      final segInfo = writer.flush();
      segmentReader = SegmentReader.open(info: segInfo, directory: dir);
    });

    tearDown(() {
      segmentReader.close();
      dir.close();
    });

    test('suggests alternate words from live FST term dictionary', () {
      const checker = DirectSpellChecker(maxEdits: 2, minPrefix: 1);

      // Typo: "distribted" (missing 'u') -> "distributed"
      final suggestions = checker.suggest(
        segmentReader,
        'body',
        'distribted',
        maxResults: 3,
      );

      expect(suggestions, isNotEmpty);
      expect(suggestions.first.text, equals('distributed'));
      expect(suggestions.first.distance, equals(1));
      expect(suggestions.first.frequency, equals(2)); // Present in doc 1 and 2
    });

    test('didYouMean rewrites misspelled query string', () {
      const checker = DirectSpellChecker(maxEdits: 2, minPrefix: 1);

      // "distribted databaes" -> "distributed database"
      final corrected = checker.didYouMean(
        segmentReader,
        'body',
        'distribted databaes',
      );

      expect(corrected, equals('distributed database'));

      // If query is already correctly spelled, didYouMean returns null
      final noChange = checker.didYouMean(
        segmentReader,
        'body',
        'distributed database',
      );
      expect(noChange, isNull);
    });
  });
}
