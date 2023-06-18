import 'dart:math' as math;
import 'suggest_models.dart';

/// Verbosity levels for SymSpell candidate filtering.
enum SuggestVerbosity {
  /// Top candidate with lowest edit distance and highest frequency.
  top,

  /// All candidates with the minimum edit distance found.
  closest,

  /// All candidates within maxEditDistance.
  all,
}

/// High-throughput spell checker implementing the Symmetric Delete (SymSpell) algorithm.
class SymSpell {
  final int maxDictionaryEditDistance;
  final int prefixLength;
  final int countThreshold;

  // Dictionary words: word -> frequency
  final Map<String, int> _words = {};

  // Deletion index: deleteKey -> list of original dictionary words
  final Map<String, List<String>> _deletes = {};

  int _maxDictionaryWordLength = 0;

  SymSpell({
    this.maxDictionaryEditDistance = 2,
    this.prefixLength = 7,
    this.countThreshold = 1,
  });

  int get wordCount => _words.length;
  int get entryCount => _deletes.length;

  /// Loads a word with its observed corpus [frequency].
  bool createDictionaryEntry(String word, int frequency) {
    if (frequency < countThreshold) return false;

    final lower = word.toLowerCase().trim();
    if (lower.isEmpty) return false;

    if (_words.containsKey(lower)) {
      _words[lower] = _words[lower]! + frequency;
      return false;
    }

    _words[lower] = frequency;
    if (lower.length > _maxDictionaryWordLength) {
      _maxDictionaryWordLength = lower.length;
    }

    // Generate deletes and register in index
    final deletes = _editsPrefix(lower);
    for (final del in deletes) {
      _deletes.putIfAbsent(del, () => []).add(lower);
    }

    return true;
  }

  /// Finds spelling suggestions for [input] within [maxEditDistance].
  List<Suggestion> lookup(
    String input, {
    SuggestVerbosity verbosity = SuggestVerbosity.closest,
    int maxEditDistance = 2,
  }) {
    final clean = input.toLowerCase().trim();
    if (clean.isEmpty) return const [];

    if (maxEditDistance > maxDictionaryEditDistance) {
      throw ArgumentError(
          'maxEditDistance cannot exceed maxDictionaryEditDistance ($maxDictionaryEditDistance)');
    }

    final suggestions = <Suggestion>[];

    // Check exact match in dictionary
    if (_words.containsKey(clean)) {
      final exactFreq = _words[clean]!;
      suggestions.add(Suggestion(
        text: clean,
        score: exactFreq.toDouble(),
        distance: 0,
        frequency: exactFreq,
      ));
      if (verbosity == SuggestVerbosity.top) {
        return suggestions;
      }
    }

    // Length check filter
    if (clean.length - maxEditDistance > _maxDictionaryWordLength) {
      return suggestions;
    }

    final candidates = <String>{};
    final inputDeletes = _editsPrefix(clean);

    for (final del in inputDeletes) {
      final matches = _deletes[del];
      if (matches != null) {
        candidates.addAll(matches);
      }
    }

    // Direct check if clean input itself is a delete key
    final directMatches = _deletes[clean];
    if (directMatches != null) {
      candidates.addAll(directMatches);
    }

    var minDistanceFound = maxEditDistance + 1;
    final scoredCandidates = <Suggestion>[];

    for (final cand in candidates) {
      if (cand == clean) continue; // Already added as exact match

      // Fast length difference check
      if ((cand.length - clean.length).abs() > maxEditDistance) {
        continue;
      }

      final dist = damerauLevenshteinDistance(clean, cand, maxEditDistance);
      if (dist <= maxEditDistance) {
        final freq = _words[cand] ?? 0;
        final score = freq / (1.0 + dist * 1000.0);

        if (dist < minDistanceFound) {
          minDistanceFound = dist;
        }

        scoredCandidates.add(Suggestion(
          text: cand,
          score: score,
          distance: dist,
          frequency: freq,
        ));
      }
    }

    // Apply verbosity filter
    List<Suggestion> filtered;
    if (verbosity == SuggestVerbosity.top) {
      if (scoredCandidates.isEmpty) return suggestions;
      scoredCandidates.sort();
      return [scoredCandidates.first];
    } else if (verbosity == SuggestVerbosity.closest) {
      filtered = scoredCandidates
          .where((s) => s.distance <= minDistanceFound)
          .toList();
    } else {
      filtered = scoredCandidates;
    }

    filtered.addAll(suggestions);
    filtered.sort();
    return filtered;
  }

  /// Multi-word compound sentence spelling correction.
  List<Suggestion> lookupCompound(String sentence, {int maxEditDistance = 2}) {
    final tokens = sentence.toLowerCase().trim().split(RegExp(r'\s+'));
    if (tokens.isEmpty) return const [];

    final correctedTokens = <String>[];
    var totalDistance = 0;
    var totalFreq = 0;

    for (final token in tokens) {
      final suggestions = lookup(
        token,
        verbosity: SuggestVerbosity.top,
        maxEditDistance: maxEditDistance,
      );

      if (suggestions.isNotEmpty) {
        final best = suggestions.first;
        correctedTokens.add(best.text);
        totalDistance += best.distance;
        totalFreq += best.frequency;
      } else {
        correctedTokens.add(token);
      }
    }

    final correctedText = correctedTokens.join(' ');
    final score = totalFreq / (1.0 + totalDistance * 1000.0);

    return [
      Suggestion(
        text: correctedText,
        score: score,
        distance: totalDistance,
        frequency: totalFreq,
      )
    ];
  }

  Set<String> _editsPrefix(String key) {
    final result = <String>{};
    if (key.length <= maxDictionaryEditDistance) {
      result.add('');
    }
    if (key.length > prefixLength) {
      key = key.substring(0, prefixLength);
    }
    result.add(key);
    _edits(key, 0, result);
    return result;
  }

  void _edits(String word, int editDistance, Set<String> deleteWords) {
    editDistance++;
    if (word.isEmpty) return;

    for (var i = 0; i < word.length; i++) {
      final del = word.substring(0, i) + word.substring(i + 1);
      if (deleteWords.add(del)) {
        if (editDistance < maxDictionaryEditDistance) {
          _edits(del, editDistance, deleteWords);
        }
      }
    }
  }

  /// Calculates the Damerau-Levenshtein distance (optimal string alignment) between two strings
  /// bounded by [maxDistance].
  static int damerauLevenshteinDistance(
    String s1,
    String s2,
    int maxDistance,
  ) {
    if (s1 == s2) return 0;
    if (s1.isEmpty) return s2.length <= maxDistance ? s2.length : maxDistance + 1;
    if (s2.isEmpty) return s1.length <= maxDistance ? s1.length : maxDistance + 1;

    final len1 = s1.length;
    final len2 = s2.length;

    if ((len1 - len2).abs() > maxDistance) {
      return maxDistance + 1;
    }

    final d = List.generate(
      len1 + 1,
      (i) => List.filled(len2 + 1, 0),
    );

    for (var i = 0; i <= len1; i++) {
      d[i][0] = i;
    }
    for (var j = 0; j <= len2; j++) {
      d[0][j] = j;
    }

    for (var i = 1; i <= len1; i++) {
      final c1 = s1.codeUnitAt(i - 1);
      for (var j = 1; j <= len2; j++) {
        final c2 = s2.codeUnitAt(j - 1);
        final cost = (c1 == c2) ? 0 : 1;

        var min = math.min(d[i - 1][j] + 1, d[i][j - 1] + 1);
        min = math.min(min, d[i - 1][j - 1] + cost);

        // Transposition
        if (i > 1 &&
            j > 1 &&
            c1 == s2.codeUnitAt(j - 2) &&
            s1.codeUnitAt(i - 2) == c2) {
          min = math.min(min, d[i - 2][j - 2] + cost);
        }

        d[i][j] = min;
      }
    }

    return d[len1][len2] <= maxDistance ? d[len1][len2] : maxDistance + 1;
  }
}
