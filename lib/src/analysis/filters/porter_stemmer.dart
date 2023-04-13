/// Complete Porter Stemming algorithm implementation.
/// Reference: M.F. Porter, 1980, An algorithm for suffix stripping, Program, 14(3) pp 130-137.
class PorterStemmer {
  /// Stems an English word to its root morphological form.
  static String stem(String word) {
    if (word.length <= 2) return word;
    var b = word.toLowerCase();

    b = _step1a(b);
    b = _step1b(b);
    b = _step1c(b);
    b = _step2(b);
    b = _step3(b);
    b = _step4(b);
    b = _step5a(b);
    b = _step5b(b);

    return b;
  }

  static String _step1a(String b) {
    if (b.endsWith('sses')) return b.substring(0, b.length - 2);
    if (b.endsWith('ies')) return b.substring(0, b.length - 2);
    if (b.endsWith('ss')) return b;
    if (b.endsWith('s')) return b.substring(0, b.length - 1);
    return b;
  }

  static String _step1b(String b) {
    if (b.endsWith('eed')) {
      final stem = b.substring(0, b.length - 3);
      if (_measure(stem) > 0) return '${stem}ee';
      return b;
    }
    if (b.endsWith('ed')) {
      final stem = b.substring(0, b.length - 2);
      if (_hasVowel(stem)) return _step1b2(stem);
      return b;
    }
    if (b.endsWith('ing')) {
      final stem = b.substring(0, b.length - 3);
      if (_hasVowel(stem)) return _step1b2(stem);
      return b;
    }
    return b;
  }

  static String _step1b2(String stem) {
    if (stem.endsWith('at') || stem.endsWith('bl') || stem.endsWith('iz')) {
      return '${stem}e';
    }
    if (_doubleConsonant(stem) &&
        !stem.endsWith('l') &&
        !stem.endsWith('s') &&
        !stem.endsWith('z')) {
      return stem.substring(0, stem.length - 1);
    }
    if (_measure(stem) == 1 && _cvc(stem)) {
      return '${stem}e';
    }
    return stem;
  }

  static String _step1c(String b) {
    if (b.endsWith('y')) {
      final stem = b.substring(0, b.length - 1);
      if (_hasVowel(stem)) return '${stem}i';
    }
    return b;
  }

  static String _step2(String b) {
    const pairs = {
      'ational': 'ate',
      'tional': 'tion',
      'enci': 'ence',
      'anci': 'ance',
      'izer': 'ize',
      'bli': 'ble',
      'alli': 'al',
      'entli': 'ent',
      'eli': 'e',
      'ousli': 'ous',
      'ization': 'ize',
      'ation': 'ate',
      'ator': 'ate',
      'alism': 'al',
      'iveness': 'ive',
      'fulness': 'ful',
      'ousness': 'ous',
      'aliti': 'al',
      'iviti': 'ive',
      'biliti': 'ble',
    };

    for (final entry in pairs.entries) {
      if (b.endsWith(entry.key)) {
        final stem = b.substring(0, b.length - entry.key.length);
        if (_measure(stem) > 0) return stem + entry.value;
        return b;
      }
    }
    return b;
  }

  static String _step3(String b) {
    const pairs = {
      'icate': 'ic',
      'ative': '',
      'alize': 'al',
      'iciti': 'ic',
      'ical': 'ic',
      'ful': '',
      'ness': '',
    };

    for (final entry in pairs.entries) {
      if (b.endsWith(entry.key)) {
        final stem = b.substring(0, b.length - entry.key.length);
        if (_measure(stem) > 0) return stem + entry.value;
        return b;
      }
    }
    return b;
  }

  static String _step4(String b) {
    const suffixes = [
      'al', 'ance', 'ence', 'er', 'ic', 'able', 'ible', 'ant', 'ement',
      'ment', 'ent', 'ou', 'ism', 'ate', 'iti', 'ous', 'ive', 'ize'
    ];

    for (final suffix in suffixes) {
      if (b.endsWith(suffix)) {
        final stem = b.substring(0, b.length - suffix.length);
        if (_measure(stem) > 1) return stem;
        return b;
      }
    }

    if (b.endsWith('ion')) {
      final stem = b.substring(0, b.length - 3);
      if (_measure(stem) > 1 && (stem.endsWith('s') || stem.endsWith('t'))) {
        return stem;
      }
    }
    return b;
  }

  static String _step5a(String b) {
    if (b.endsWith('e')) {
      final stem = b.substring(0, b.length - 1);
      final m = _measure(stem);
      if (m > 1 || (m == 1 && !_cvc(stem))) return stem;
    }
    return b;
  }

  static String _step5b(String b) {
    if (_measure(b) > 1 && _doubleConsonant(b) && b.endsWith('l')) {
      return b.substring(0, b.length - 1);
    }
    return b;
  }

  static bool _isConsonant(String s, int i) {
    final c = s[i];
    if (c == 'a' || c == 'e' || c == 'i' || c == 'o' || c == 'u') return false;
    if (c == 'y') return i == 0 ? true : !_isConsonant(s, i - 1);
    return true;
  }

  static int _measure(String s) {
    var count = 0;
    var i = 0;
    final len = s.length;

    while (i < len && _isConsonant(s, i)) {
      i++;
    }
    while (i < len) {
      while (i < len && !_isConsonant(s, i)) {
        i++;
      }
      if (i >= len) break;
      count++;
      while (i < len && _isConsonant(s, i)) {
        i++;
      }
    }
    return count;
  }

  static bool _hasVowel(String s) {
    for (var i = 0; i < s.length; i++) {
      if (!_isConsonant(s, i)) return true;
    }
    return false;
  }

  static bool _doubleConsonant(String s) {
    if (s.length < 2) return false;
    final last = s[s.length - 1];
    final secondLast = s[s.length - 2];
    return last == secondLast && _isConsonant(s, s.length - 1);
  }

  static bool _cvc(String s) {
    final len = s.length;
    if (len < 3) return false;
    final c1 = _isConsonant(s, len - 3);
    final v = !_isConsonant(s, len - 2);
    final c2 = _isConsonant(s, len - 1);
    final last = s[len - 1];
    return c1 && v && c2 && last != 'w' && last != 'x' && last != 'y';
  }
}
