/// Lawrence Philips' Metaphone phonetic encoding algorithm.
class Metaphone {
  static const int defaultMaxCodeLen = 6;
  static const String _vowels = 'AEIOU';
  static const String _frontVowels = 'EIY';
  static const String _varsonVowels = 'CSPTG';

  /// Encodes [text] into its Metaphone phonetic key.
  static String encode(String text, [int maxCodeLen = defaultMaxCodeLen]) {
    var inStr = text.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z]'), '');
    if (inStr.isEmpty) return '';

    // Handle silent initial letter pairs: KN, GN, PN, AE, WR
    if (inStr.startsWith('KN') ||
        inStr.startsWith('GN') ||
        inStr.startsWith('PN') ||
        inStr.startsWith('AE') ||
        inStr.startsWith('WR')) {
      inStr = inStr.substring(1);
    }

    // Initial 'X' sounds like 'S'
    if (inStr.startsWith('X')) {
      inStr = 'S${inStr.substring(1)}';
    }

    // Initial 'WH' sounds like 'W'
    if (inStr.startsWith('WH')) {
      inStr = 'W${inStr.substring(2)}';
    }

    final out = StringBuffer();
    final len = inStr.length;

    for (var i = 0; i < len && out.length < maxCodeLen; i++) {
      final ch = inStr[i];

      // Drop adjacent duplicate characters, except 'C'
      if (ch != 'C' && i > 0 && inStr[i - 1] == ch) {
        continue;
      }

      // Initial vowel remains, intermediate vowels dropped
      if (_vowels.contains(ch)) {
        if (i == 0) {
          out.write(ch);
        }
        continue;
      }

      switch (ch) {
        case 'B':
          // Silent 'B' at end after 'M' (e.g. dumb, thumb)
          if (i == len - 1 && i > 0 && inStr[i - 1] == 'M') {
            break;
          }
          out.write('B');
          break;

        case 'C':
          // 'SCH' -> 'K' (e.g. school, scheme)
          if (i > 0 && inStr[i - 1] == 'S' && i + 1 < len && inStr[i + 1] == 'H') {
            out.write('K');
            i++;
          }
          // 'CH' -> 'X'
          else if (i + 1 < len && inStr[i + 1] == 'H') {
            out.write('X');
            i++;
          }
          // 'CIA' -> 'X'
          else if (i + 2 < len && inStr[i + 1] == 'I' && inStr[i + 2] == 'A') {
            out.write('X');
            i += 2;
          }
          // Soft 'C' before 'E', 'I', 'Y' -> 'S'
          else if (i + 1 < len && _frontVowels.contains(inStr[i + 1])) {
            out.write('S');
          }
          // Otherwise hard 'C' -> 'K'
          else {
            out.write('K');
          }
          break;

        case 'D':
          // 'DG' before 'E', 'I', 'Y' -> 'J'
          if (i + 2 < len &&
              inStr[i + 1] == 'G' &&
              _frontVowels.contains(inStr[i + 2])) {
            out.write('J');
            i += 2;
          } else {
            out.write('T');
          }
          break;

        case 'G':
          // Silent 'G' before 'H' not at start or before vowel
          if (i + 1 < len && inStr[i + 1] == 'H') {
            if (i + 2 < len && !_vowels.contains(inStr[i + 2])) {
              i++;
              break;
            }
          }
          // Silent 'G' before 'N' at end (e.g. sign, foreign)
          if (i + 1 < len && inStr[i + 1] == 'N') {
            if (i + 1 == len - 1 ||
                (i + 2 < len && inStr[i + 2] == 'E' && i + 2 == len - 1)) {
              break;
            }
          }
          // Soft 'G' before 'E', 'I', 'Y' -> 'J'
          if (i + 1 < len && _frontVowels.contains(inStr[i + 1])) {
            out.write('J');
          } else {
            out.write('K');
          }
          break;

        case 'H':
          // 'H' is silent after vowel and not followed by vowel
          if (i > 0 && _vowels.contains(inStr[i - 1])) {
            if (i + 1 == len || !_vowels.contains(inStr[i + 1])) {
              break;
            }
          }
          // 'H' after consonant is usually modifier (handled in C, D, G, P, S, T)
          if (i > 0 && _varsonVowels.contains(inStr[i - 1])) {
            break;
          }
          out.write('H');
          break;

        case 'F':
        case 'J':
        case 'L':
        case 'M':
        case 'N':
        case 'R':
          out.write(ch);
          break;

        case 'K':
          // Silent after 'C'
          if (i > 0 && inStr[i - 1] == 'C') {
            break;
          }
          out.write('K');
          break;

        case 'P':
          // 'PH' -> 'F'
          if (i + 1 < len && inStr[i + 1] == 'H') {
            out.write('F');
            i++;
          } else {
            out.write('P');
          }
          break;

        case 'Q':
          out.write('K');
          break;

        case 'S':
          // 'SH' -> 'X'
          if (i + 1 < len && inStr[i + 1] == 'H') {
            out.write('X');
            i++;
          }
          // 'SIO' / 'SIA' -> 'X'
          else if (i + 2 < len &&
              inStr[i + 1] == 'I' &&
              (inStr[i + 2] == 'O' || inStr[i + 2] == 'A')) {
            out.write('X');
            i += 2;
          } else {
            out.write('S');
          }
          break;

        case 'T':
          // 'TIA' / 'TIO' -> 'X'
          if (i + 2 < len &&
              inStr[i + 1] == 'I' &&
              (inStr[i + 2] == 'A' || inStr[i + 2] == 'O')) {
            out.write('X');
            i += 2;
          }
          // 'TH' -> '0'
          else if (i + 1 < len && inStr[i + 1] == 'H') {
            out.write('0');
            i++;
          }
          // 'TCH' -> silent 'T' (e.g. watch)
          else if (i + 2 < len && inStr[i + 1] == 'C' && inStr[i + 2] == 'H') {
            break;
          } else {
            out.write('T');
          }
          break;

        case 'V':
          out.write('F');
          break;

        case 'W':
        case 'Y':
          // 'W' and 'Y' followed by vowel
          if (i + 1 < len && _vowels.contains(inStr[i + 1])) {
            out.write(ch);
          }
          break;

        case 'X':
          out.write('KS');
          break;

        case 'Z':
          out.write('S');
          break;
      }
    }

    return out.toString();
  }
}
