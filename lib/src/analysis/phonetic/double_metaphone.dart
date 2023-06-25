/// Result of a Double Metaphone encoding containing primary and alternate phonetic keys.
class DoubleMetaphoneResult {
  final String primary;
  final String alternate;

  const DoubleMetaphoneResult(this.primary, this.alternate);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DoubleMetaphoneResult &&
          primary == other.primary &&
          alternate == other.alternate;

  @override
  int get hashCode => Object.hash(primary, alternate);

  @override
  String toString() => 'DoubleMetaphone($primary, alt: $alternate)';
}

/// Double Metaphone phonetic encoding algorithm.
class DoubleMetaphone {
  static const int defaultMaxCodeLen = 4;

  /// Encodes [input] into primary and alternate phonetic representations.
  static DoubleMetaphoneResult encode(
    String input, [
    int maxCodeLen = defaultMaxCodeLen,
  ]) {
    var inStr = input.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z]'), '');
    if (inStr.isEmpty) {
      return const DoubleMetaphoneResult('', '');
    }

    // Handle initial silent letter combinations
    if (inStr.startsWith('GN') ||
        inStr.startsWith('KN') ||
        inStr.startsWith('PN') ||
        inStr.startsWith('WR') ||
        inStr.startsWith('PS')) {
      inStr = inStr.substring(1);
    }

    // Initial 'X' sounds like 'S'
    if (inStr.startsWith('X')) {
      inStr = 'S${inStr.substring(1)}';
    }

    final primary = StringBuffer();
    final alternate = StringBuffer();
    final len = inStr.length;

    for (var i = 0; i < len; i++) {
      if (primary.length >= maxCodeLen && alternate.length >= maxCodeLen) {
        break;
      }

      final ch = inStr[i];

      // Skip adjacent duplicate letters, except 'C'
      if (ch != 'C' && i > 0 && inStr[i - 1] == ch) {
        continue;
      }

      // Vowels at word start encode as 'A'
      if ('AEIOUY'.contains(ch)) {
        if (i == 0) {
          primary.write('A');
          alternate.write('A');
        }
        continue;
      }

      switch (ch) {
        case 'B':
          // Silent 'B' after 'M' at end
          if (i == len - 1 && i > 0 && inStr[i - 1] == 'M') break;
          primary.write('P');
          alternate.write('P');
          break;

        case 'C':
          // 'CH' -> 'X' (or 'K' in German / Greek origin like 'character')
          if (i + 1 < len && inStr[i + 1] == 'H') {
            if (i > 0 && inStr.startsWith('ARCH', i - 1)) {
              primary.write('K');
              alternate.write('X');
            } else {
              primary.write('X');
              alternate.write('K');
            }
            i++;
          }
          // 'CC'
          else if (i + 1 < len && inStr[i + 1] == 'C') {
            if (i + 2 < len && 'EIY'.contains(inStr[i + 2])) {
              primary.write('KS');
              alternate.write('KS');
              i += 2;
            } else {
              primary.write('K');
              alternate.write('K');
              i++;
            }
          }
          // 'CK', 'CG', 'CQ'
          else if (i + 1 < len && (inStr[i + 1] == 'K' || inStr[i + 1] == 'Q')) {
            primary.write('K');
            alternate.write('K');
            i++;
          }
          // Soft 'C' before 'E', 'I', 'Y'
          else if (i + 1 < len && 'EIY'.contains(inStr[i + 1])) {
            primary.write('S');
            alternate.write('S');
          } else {
            primary.write('K');
            alternate.write('K');
          }
          break;

        case 'D':
          // 'DG' before 'E', 'I', 'Y' -> 'J'
          if (i + 2 < len && inStr[i + 1] == 'G' && 'EIY'.contains(inStr[i + 2])) {
            primary.write('J');
            alternate.write('J');
            i += 2;
          } else {
            primary.write('T');
            alternate.write('T');
          }
          break;

        case 'F':
          primary.write('F');
          alternate.write('F');
          break;

        case 'G':
          // 'GH'
          if (i + 1 < len && inStr[i + 1] == 'H') {
            if (i > 0 && !'AEIOUY'.contains(inStr[i - 1])) {
              primary.write('K');
              alternate.write('K');
              i++;
            } else if (i == 0) {
              primary.write('K');
              alternate.write('K');
              i++;
            }
          }
          // 'GN' at end
          else if (i + 1 < len && inStr[i + 1] == 'N') {
            if (i + 1 == len - 1) {
              // Silent 'G' in 'sign'
              break;
            }
          }
          // Soft 'G' before 'E', 'I', 'Y'
          else if (i + 1 < len && 'EIY'.contains(inStr[i + 1])) {
            primary.write('J');
            alternate.write('K');
          } else {
            primary.write('K');
            alternate.write('K');
          }
          break;

        case 'H':
          if ((i == 0 || 'AEIOUY'.contains(inStr[i - 1])) &&
              (i + 1 < len && 'AEIOUY'.contains(inStr[i + 1]))) {
            primary.write('H');
            alternate.write('H');
          }
          break;

        case 'J':
          primary.write('J');
          alternate.write('A'); // Spanish origin alternate (e.g. 'San Jose')
          break;

        case 'K':
          primary.write('K');
          alternate.write('K');
          break;

        case 'L':
          primary.write('L');
          alternate.write('L');
          break;

        case 'M':
        case 'N':
          primary.write(ch);
          alternate.write(ch);
          break;

        case 'P':
          if (i + 1 < len && inStr[i + 1] == 'H') {
            primary.write('F');
            alternate.write('F');
            i++;
          } else {
            primary.write('P');
            alternate.write('P');
          }
          break;

        case 'Q':
          primary.write('K');
          alternate.write('K');
          break;

        case 'R':
          primary.write('R');
          alternate.write('R');
          break;

        case 'S':
          if (i + 1 < len && inStr[i + 1] == 'H') {
            primary.write('X');
            alternate.write('X');
            i++;
          } else {
            primary.write('S');
            alternate.write('S');
          }
          break;

        case 'T':
          if (i + 1 < len && inStr[i + 1] == 'H') {
            primary.write('0');
            alternate.write('T');
            i++;
          } else if (i + 2 < len &&
              inStr[i + 1] == 'I' &&
              (inStr[i + 2] == 'A' || inStr[i + 2] == 'O')) {
            primary.write('X');
            alternate.write('X');
            i += 2;
          } else {
            primary.write('T');
            alternate.write('T');
          }
          break;

        case 'V':
          primary.write('F');
          alternate.write('F');
          break;

        case 'W':
        case 'Y':
          if (i + 1 < len && 'AEIOUY'.contains(inStr[i + 1])) {
            primary.write(ch == 'W' ? 'A' : 'A');
            alternate.write(ch == 'W' ? 'F' : 'A');
          }
          break;

        case 'X':
          primary.write('KS');
          alternate.write('KS');
          break;

        case 'Z':
          primary.write('S');
          alternate.write('S');
          break;
      }
    }

    final pStr = primary.toString();
    final aStr = alternate.toString();

    return DoubleMetaphoneResult(
      pStr.length > maxCodeLen ? pStr.substring(0, maxCodeLen) : pStr,
      aStr.length > maxCodeLen ? aStr.substring(0, maxCodeLen) : aStr,
    );
  }
}
