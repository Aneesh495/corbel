import 'package:corbel/src/analysis/tokenizers/cjk_tokenizer.dart';
import 'package:test/test.dart';

/// Bug 2: CJKTokenizer emitted redundant single-character unigram for the terminal
/// character of a multi-character CJK run, causing index bloat.
/// Resolution: Only emit unigrams for isolated standalone CJK characters.
void main() {
  group('Bug Regression: CJK Bi-gram Boundary De-duplication', () {
    test('terminal CJK characters in multi-character words do not emit duplicate unigrams', () {
      final tokenizer = CJKTokenizer('搜索引擎');
      final terms = tokenizer.toTermsList();
      expect(terms, equals(['搜索', '索引', '引擎']));
    });

    test('isolated single CJK character emits unigram', () {
      final tokenizer = CJKTokenizer('A 中 B');
      final terms = tokenizer.toTermsList();
      expect(terms, equals(['A', '中', 'B']));
    });
  });
}
