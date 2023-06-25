import 'package:corbel/corbel.dart';
import 'package:test/test.dart';

void main() {
  group('Soundex Phonetic Tests', () {
    test('encodes names and matches sound-alike variations', () {
      // Smith and Smythe have identical Soundex codes: S530
      expect(Soundex.encode('Smith'), equals('S530'));
      expect(Soundex.encode('Smythe'), equals('S530'));

      // Robert and Rupert: R163
      expect(Soundex.encode('Robert'), equals('R163'));
      expect(Soundex.encode('Rupert'), equals('R163'));

      // Ashcraft: A261
      expect(Soundex.encode('Ashcraft'), equals('A261'));

      // Padding for short words
      expect(Soundex.encode('Lee'), equals('L000'));
      expect(Soundex.encode('Gutierrez'), equals('G362'));

      // Empty handling
      expect(Soundex.encode(''), equals(''));
      expect(Soundex.encode('1234'), equals(''));
    });
  });

  group('Metaphone Phonetic Tests', () {
    test('encodes English pronunciation rules accurately', () {
      // Silent letter drops: 'knight' and 'night' produce 'NT'
      expect(Metaphone.encode('knight'), equals('NT'));
      expect(Metaphone.encode('night'), equals('NT'));

      // 'gnome' -> 'NM'
      expect(Metaphone.encode('gnome'), equals('NM'));

      // Soft C in 'cinema' vs hard C in 'cat'
      expect(Metaphone.encode('cinema'), startsWith('S'));
      expect(Metaphone.encode('cat'), startsWith('K'));

      // 'phone' -> 'FN'
      expect(Metaphone.encode('phone'), equals('FN'));

      // 'theater' -> '0TR'
      expect(Metaphone.encode('theater'), equals('0TR'));

      // 'school' -> 'SKL'
      expect(Metaphone.encode('school'), equals('SKL'));
    });
  });

  group('Double Metaphone Tests', () {
    test('generates primary and alternate phonetic representations', () {
      final smith = DoubleMetaphone.encode('Smith');
      expect(smith.primary, equals('SM0'));
      expect(smith.alternate, equals('SMT'));

      final catherine = DoubleMetaphone.encode('Catherine');
      expect(catherine.primary, equals('K0RN'));

      final katherine = DoubleMetaphone.encode('Katherine');
      expect(katherine.primary, equals('K0RN'));

      // Spanish 'J' in Jose: primary 'J', alternate 'H'/'A'
      final jose = DoubleMetaphone.encode('Jose');
      expect(jose.primary, isNotEmpty);
      expect(jose.alternate, isNotEmpty);
    });
  });

  group('PhoneticFilter Token Stream Tests', () {
    test('emits phonetic aliases colocated at positionIncrement 0', () {
      final input = WhitespaceTokenizer('robert smith');
      final filter = PhoneticFilter(
        input,
        algorithm: PhoneticAlgorithm.soundex,
        replaceOriginal: false,
      );

      final tokens = <Token>[];
      while (filter.incrementToken()) {
        tokens.add(filter.currentToken);
      }

      // Should emit: 'robert' (pos 1), 'R163' (pos 0), 'smith' (pos 1), 'S530' (pos 0)
      expect(tokens.length, equals(4));

      expect(tokens[0].term, equals('robert'));
      expect(tokens[0].positionIncrement, equals(1));

      expect(tokens[1].term, equals('R163'));
      expect(tokens[1].positionIncrement, equals(0));

      expect(tokens[2].term, equals('smith'));
      expect(tokens[2].positionIncrement, equals(1));

      expect(tokens[3].term, equals('S530'));
      expect(tokens[3].positionIncrement, equals(0));
    });

    test('replaceOriginal replaces terms with phonetic codes', () {
      final input = WhitespaceTokenizer('knight phone');
      final filter = PhoneticFilter(
        input,
        algorithm: PhoneticAlgorithm.metaphone,
        replaceOriginal: true,
      );

      final terms = <String>[];
      while (filter.incrementToken()) {
        terms.add(filter.currentToken.term);
      }

      expect(terms, equals(['NT', 'FN']));
    });
  });
}
