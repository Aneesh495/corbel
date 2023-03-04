import '../token.dart';
import '../token_stream.dart';

/// Base class for token filters transforming or filtering tokens from an input TokenStream.
abstract class TokenFilter extends TokenStream {
  /// Upstream token stream input.
  final TokenStream input;

  TokenFilter(this.input);

  @override
  void reset() {
    input.reset();
  }

  @override
  void close() {
    input.close();
  }
}
