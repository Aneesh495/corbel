import '../index/segment_reader.dart';
import 'suggest_models.dart';
import 'symspell.dart';

/// Spell checker querying live FST term dictionaries directly from index segments.
class DirectSpellChecker {
  final int maxEdits;
  final int minPrefix;
  final int minDocFreq;

  const DirectSpellChecker({
    this.maxEdits = 2,
    this.minPrefix = 1,
    this.minDocFreq = 1,
  });

  /// Suggests alternate dictionary terms for [term] in [field] across [segmentReader].
  List<Suggestion> suggest(
    SegmentReader segmentReader,
    String field,
    String term, {
    int maxResults = 5,
  }) {
    final clean = term.toLowerCase().trim();
    if (clean.isEmpty) return const [];

    final fst = segmentReader.getFst(field);
    if (fst == null) return const [];

    // Query FST dictionary with Levenshtein automaton
    final fuzzyMatches = fst.fuzzySearch(clean, maxEdits);
    final candidates = <Suggestion>[];

    for (final matchEntry in fuzzyMatches) {
      final cand = matchEntry.key;
      if (cand == clean) continue; // Skip exact match

      // Verify prefix constraint
      if (minPrefix > 0) {
        final prefixLen = clean.length < minPrefix ? clean.length : minPrefix;
        if (!cand.startsWith(clean.substring(0, prefixLen))) {
          continue;
        }
      }

      final postings = segmentReader.postings(field, cand);
      final docFreq = postings?.docCount ?? 0;
      if (docFreq < minDocFreq) continue;

      final dist = SymSpell.damerauLevenshteinDistance(clean, cand, maxEdits);
      if (dist <= maxEdits) {
        final score = docFreq / (1.0 + dist);
        candidates.add(Suggestion(
          text: cand,
          score: score,
          distance: dist,
          frequency: docFreq,
        ));
      }
    }

    candidates.sort();
    return candidates.take(maxResults).toList();
  }

  /// Automatically generates a corrected "Did you mean" query string.
  String? didYouMean(
    SegmentReader segmentReader,
    String field,
    String rawQuery,
  ) {
    final tokens = rawQuery.trim().split(RegExp(r'\s+'));
    var changed = false;
    final corrected = <String>[];

    final fst = segmentReader.getFst(field);
    if (fst == null) return null;

    for (final token in tokens) {
      final clean = token.toLowerCase();
      // If term exists in FST dictionary, preserve it
      if (fst.getString(clean) != null) {
        corrected.add(token);
        continue;
      }

      // Find best candidate
      final suggestions = suggest(
        segmentReader,
        field,
        clean,
        maxResults: 1,
      );

      if (suggestions.isNotEmpty) {
        corrected.add(suggestions.first.text);
        changed = true;
      } else {
        corrected.add(token);
      }
    }

    return changed ? corrected.join(' ') : null;
  }
}
