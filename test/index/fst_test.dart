import 'package:corbel/src/index/fst/fst.dart';
import 'package:corbel/src/storage/directory.dart';
import 'package:corbel/src/utils/bytes_ref.dart';
import 'package:test/test.dart';

void main() {
  group('Finite State Transducer (FST) Tests', () {
    test('exact lookups across shared prefixes and suffixes', () {
      final terms = [
        const MapEntry('cat', 10),
        const MapEntry('cats', 20),
        const MapEntry('dog', 30),
        const MapEntry('dogs', 40),
        const MapEntry('stop', 50),
        const MapEntry('tap', 60),
        const MapEntry('taps', 70),
        const MapEntry('top', 80),
      ];

      final fst = Fst.fromSortedTerms(terms);

      for (final entry in terms) {
        expect(fst.getString(entry.key), equals(entry.value),
            reason: 'Failed lookup for ${entry.key}');
      }

      // Non-existent terms return null
      expect(fst.getString('ca'), isNull);
      expect(fst.getString('category'), isNull);
      expect(fst.getString('wolf'), isNull);
      expect(fst.getString('to'), isNull);
    });

    test('prefix search returns all matching descendants', () {
      final terms = [
        const MapEntry('database', 1),
        const MapEntry('datagram', 2),
        const MapEntry('dataset', 3),
        const MapEntry('date', 4),
        const MapEntry('document', 5),
      ];

      final fst = Fst.fromSortedTerms(terms);
      final matches = fst.prefixSearch('data');

      expect(matches.map((m) => m.key).toList(),
          equals(['database', 'datagram', 'dataset']));
      expect(matches.map((m) => m.value).toList(), equals([1, 2, 3]));

      final emptyMatches = fst.prefixSearch('query');
      expect(emptyMatches, isEmpty);
    });

    test('fuzzy search with Levenshtein edit distance', () {
      final terms = [
        const MapEntry('corbel', 100),
        const MapEntry('core', 200),
        const MapEntry('cortex', 300),
        const MapEntry('sorbel', 400),
      ];

      final fst = Fst.fromSortedTerms(terms);

      // Distance 1 search for 'corbel'
      final d1Matches = fst.fuzzySearch('corbel', 1);
      final d1Keys = d1Matches.map((m) => m.key).toList();
      expect(d1Keys, contains('corbel'));
      expect(d1Keys, contains('sorbel')); // substitution s -> c

      // Distance 2 search for 'corbel'
      final d2Matches = fst.fuzzySearch('corbel', 2);
      final d2Keys = d2Matches.map((m) => m.key).toList();
      expect(d2Keys, containsAll(['corbel', 'sorbel', 'core']));
    });

    test('FST serialization and deserialization round-trip', () {
      final terms = [
        const MapEntry('boolean', 11),
        const MapEntry('btree', 22),
        const MapEntry('inverted', 33),
        const MapEntry('index', 44),
        const MapEntry('vector', 55),
      ];

      final originalFst = Fst.fromSortedTerms(terms);

      final dir = RAMDirectory();
      final out = dir.createOutput('terms.fst');
      originalFst.serialize(out);
      out.close();

      final inp = dir.openInput('terms.fst');
      final restoredFst = Fst.deserialize(inp);
      inp.close();

      for (final entry in terms) {
        expect(restoredFst.getString(entry.key), equals(entry.value));
      }
      expect(restoredFst.getString('missing'), isNull);
    });
  });
}
