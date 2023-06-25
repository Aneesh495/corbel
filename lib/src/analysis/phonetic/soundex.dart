/// American Soundex phonetic encoding algorithm.
/// Maps English words and proper names to a 4-character phonetic code (e.g. S530).
class Soundex {
  static const String _soundexCode = '01230120022455012623010202';
  //                                  ABCDEFGHIJKLMNOPQRSTUVWXYZ

  /// Encodes [input] into its 4-character Soundex code.
  static String encode(String input) {
    final clean = input.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z]'), '');
    if (clean.isEmpty) return '';

    final buffer = StringBuffer()..write(clean[0]);
    var lastCode = _getCharSoundexCode(clean[0]);

    for (var i = 1; i < clean.length && buffer.length < 4; i++) {
      final ch = clean[i];
      // H and W are completely ignored and do not separate duplicate codes
      if (ch == 'H' || ch == 'W') continue;

      final code = _getCharSoundexCode(ch);
      if (code != '0' && code != lastCode) {
        buffer.write(code);
      }
      lastCode = code;
    }

    // Pad with zeros to 4 characters
    while (buffer.length < 4) {
      buffer.write('0');
    }

    return buffer.toString();
  }

  static String _getCharSoundexCode(String char) {
    final index = char.codeUnitAt(0) - 65; // 'A' = 65
    if (index >= 0 && index < _soundexCode.length) {
      return _soundexCode[index];
    }
    return '0';
  }
}
