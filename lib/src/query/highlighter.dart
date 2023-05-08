import 'dart:math' as math;
import '../analysis/analyzer.dart';

/// Positional snippet highlighter extracting relevance-scored passages with HTML tags.
class Highlighter {
  final String preTag;
  final String postTag;
  final int maxPassages;
  final int maxPassageLength;
  final Analyzer? analyzer;

  const Highlighter({
    this.preTag = '<em>',
    this.postTag = '</em>',
    this.maxPassages = 3,
    this.maxPassageLength = 150,
    this.analyzer,
  });

  /// Highlights occurrences of [terms] within source [text].
  String highlight(String text, Set<String> terms) {
    if (text.isEmpty || terms.isEmpty) return text;

    final lowerTerms = terms.map((t) => t.toLowerCase()).toSet();
    final termOccurrences = _findOccurrences(text, lowerTerms);

    if (termOccurrences.isEmpty) {
      // If no match found, return leading snippet truncated to maxPassageLength
      if (text.length <= maxPassageLength) return text;
      return '${text.substring(0, maxPassageLength)}...';
    }

    final passages = _extractCandidatePassages(text, termOccurrences, lowerTerms);
    if (passages.isEmpty) return text;

    // Sort passages by score descending, pick top maxPassages
    passages.sort((a, b) => b.score.compareTo(a.score));
    final selected = passages.take(maxPassages).toList();

    // Re-sort selected passages by start offset in the original document
    selected.sort((a, b) => a.startOffset.compareTo(b.startOffset));

    final buf = StringBuffer();
    for (var i = 0; i < selected.length; i++) {
      if (i > 0) buf.write(' ... ');
      buf.write(_renderPassage(text, selected[i]));
    }

    return buf.toString();
  }

  List<_TermOccurrence> _findOccurrences(String text, Set<String> lowerTerms) {
    final occurrences = <_TermOccurrence>[];

    if (analyzer != null) {
      final stream = analyzer!.tokenStream('', text);
      while (stream.incrementToken()) {
        final token = stream.currentToken;
        if (lowerTerms.contains(token.term.toLowerCase())) {
          occurrences.add(_TermOccurrence(
            term: token.term.toLowerCase(),
            startOffset: token.startOffset,
            endOffset: token.endOffset,
          ));
        }
      }
    } else {
      // Substring fallback
      for (final term in lowerTerms) {
        var start = 0;
        final lowerText = text.toLowerCase();
        while (start < lowerText.length) {
          final idx = lowerText.indexOf(term, start);
          if (idx == -1) break;

          // Boundary verification
          final isStartWord = idx == 0 || !_isWordChar(lowerText.codeUnitAt(idx - 1));
          final endIdx = idx + term.length;
          final isEndWord = endIdx >= lowerText.length || !_isWordChar(lowerText.codeUnitAt(endIdx));

          if (isStartWord && isEndWord) {
            occurrences.add(_TermOccurrence(
              term: term,
              startOffset: idx,
              endOffset: endIdx,
            ));
          }
          start = idx + math.max(1, term.length);
        }
      }
      occurrences.sort((a, b) => a.startOffset.compareTo(b.startOffset));
    }

    return occurrences;
  }

  List<_Passage> _extractCandidatePassages(
    String text,
    List<_TermOccurrence> occurrences,
    Set<String> allTerms,
  ) {
    final passages = <_Passage>[];

    for (var i = 0; i < occurrences.length; i++) {
      final occ = occurrences[i];

      // Expand window around occurrence
      final halfLength = maxPassageLength ~/ 2;
      var rawStart = math.max(0, occ.startOffset - halfLength);
      var rawEnd = math.min(text.length, occ.endOffset + halfLength);

      // Snap to sentence or whitespace boundaries
      final start = _snapToBoundaryLeft(text, rawStart);
      final end = _snapToBoundaryRight(text, rawEnd);

      // Collect occurrences that fall strictly within this passage window
      final contained = occurrences
          .where((o) => o.startOffset >= start && o.endOffset <= end)
          .toList();

      final distinctMatched = contained.map((o) => o.term).toSet().length;
      final totalFreq = contained.length;

      // Passage score incorporates distinct terms and total match frequency
      final score = (distinctMatched * 10.0) + totalFreq;

      passages.add(_Passage(
        startOffset: start,
        endOffset: end,
        score: score,
        occurrences: contained,
      ));
    }

    return _mergeOverlappingPassages(passages);
  }

  List<_Passage> _mergeOverlappingPassages(List<_Passage> candidates) {
    if (candidates.length <= 1) return candidates;

    candidates.sort((a, b) => a.startOffset.compareTo(b.startOffset));
    final merged = <_Passage>[candidates.first];

    for (var i = 1; i < candidates.length; i++) {
      final prev = merged.last;
      final curr = candidates[i];

      if (curr.startOffset <= prev.endOffset) {
        // Merge passages
        final newEnd = math.max(prev.endOffset, curr.endOffset);
        final combinedOccurrences = {...prev.occurrences, ...curr.occurrences}
            .toList()
          ..sort((a, b) => a.startOffset.compareTo(b.startOffset));
        final newScore = prev.score + curr.score;

        merged[merged.length - 1] = _Passage(
          startOffset: prev.startOffset,
          endOffset: newEnd,
          score: newScore,
          occurrences: combinedOccurrences,
        );
      } else {
        merged.add(curr);
      }
    }

    return merged;
  }

  String _renderPassage(String text, _Passage passage) {
    final buf = StringBuffer();
    var cursor = passage.startOffset;

    for (final occ in passage.occurrences) {
      if (occ.startOffset < cursor) continue; // Skip redundant overlap

      buf.write(text.substring(cursor, occ.startOffset));
      buf.write(preTag);
      buf.write(text.substring(occ.startOffset, occ.endOffset));
      buf.write(postTag);
      cursor = occ.endOffset;
    }

    if (cursor < passage.endOffset) {
      buf.write(text.substring(cursor, passage.endOffset));
    }

    return buf.toString().trim();
  }

  int _snapToBoundaryLeft(String text, int target) {
    if (target <= 0) return 0;
    for (var i = target; i >= math.max(0, target - 25); i--) {
      final ch = text[i];
      if (ch == '.' || ch == '!' || ch == '?' || ch == '\n') {
        return math.min(text.length, i + 1);
      }
      if (ch == ' ' && i < target) {
        return i + 1;
      }
    }
    return target;
  }

  int _snapToBoundaryRight(String text, int target) {
    if (target >= text.length) return text.length;
    for (var i = target; i < math.min(text.length, target + 25); i++) {
      final ch = text[i];
      if (ch == '.' || ch == '!' || ch == '?' || ch == '\n' || ch == ' ') {
        return i;
      }
    }
    return target;
  }

  bool _isWordChar(int codeUnit) {
    return (codeUnit >= 65 && codeUnit <= 90) ||
        (codeUnit >= 97 && codeUnit <= 122) ||
        (codeUnit >= 48 && codeUnit <= 57) ||
        codeUnit == 95;
  }
}

class _TermOccurrence {
  final String term;
  final int startOffset;
  final int endOffset;

  const _TermOccurrence({
    required this.term,
    required this.startOffset,
    required this.endOffset,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _TermOccurrence &&
          runtimeType == other.runtimeType &&
          startOffset == other.startOffset &&
          endOffset == other.endOffset;

  @override
  int get hashCode => startOffset.hashCode ^ endOffset.hashCode;
}

class _Passage {
  final int startOffset;
  final int endOffset;
  final double score;
  final List<_TermOccurrence> occurrences;

  const _Passage({
    required this.startOffset,
    required this.endOffset,
    required this.score,
    required this.occurrences,
  });
}
