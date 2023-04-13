import '../token.dart';
import 'token_filter.dart';

/// Converts alphabetic, numeric, and symbolic Unicode characters into ASCII equivalents.
class AsciiFoldingFilter extends TokenFilter {
  Token? _current;

  AsciiFoldingFilter(super.input);

  @override
  bool incrementToken() {
    if (input.incrementToken()) {
      final t = input.currentToken;
      final folded = _foldToAscii(t.term);
      _current = t.copyWith(term: folded);
      return true;
    }
    _current = null;
    return false;
  }

  @override
  Token get currentToken {
    if (_current == null) {
      throw StateError('No active token in AsciiFoldingFilter');
    }
    return _current!;
  }

  @override
  void reset() {
    super.reset();
    _current = null;
  }

  static String _foldToAscii(String input) {
    final buffer = StringBuffer();
    for (var i = 0; i < input.length; i++) {
      final code = input.codeUnitAt(i);
      if (code < 128) {
        buffer.writeCharCode(code);
      } else {
        buffer.write(_foldChar(code));
      }
    }
    return buffer.toString();
  }

  static String _foldChar(int code) {
    switch (code) {
      // Latin-1 Letters
      case 0x00C0: case 0x00C1: case 0x00C2: case 0x00C3: case 0x00C4: case 0x00C5: return 'A';
      case 0x00E0: case 0x00E1: case 0x00E2: case 0x00E3: case 0x00E4: case 0x00E5: return 'a';
      case 0x00C6: return 'AE';
      case 0x00E6: return 'ae';
      case 0x00C7: return 'C';
      case 0x00E7: return 'c';
      case 0x00C8: case 0x00C9: case 0x00CA: case 0x00CB: return 'E';
      case 0x00E8: case 0x00E9: case 0x00EA: case 0x00EB: return 'e';
      case 0x00CC: case 0x00CD: case 0x00CE: case 0x00CF: return 'I';
      case 0x00EC: case 0x00ED: case 0x00EE: case 0x00EF: return 'i';
      case 0x00D1: return 'N';
      case 0x00F1: return 'n';
      case 0x00D2: case 0x00D3: case 0x00D4: case 0x00D5: case 0x00D6: case 0x00D8: return 'O';
      case 0x00F2: case 0x00F3: case 0x00F4: case 0x00F5: case 0x00F6: case 0x00F8: return 'o';
      case 0x00D9: case 0x00DA: case 0x00DB: case 0x00DC: return 'U';
      case 0x00F9: case 0x00FA: case 0x00FB: case 0x00FC: return 'u';
      case 0x00DD: return 'Y';
      case 0x00FD: case 0x00FF: return 'y';
      case 0x00DF: return 'ss';
      default: return String.fromCharCode(code);
    }
  }
}
