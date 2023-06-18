import 'dart:math' as math;
import 'suggest_models.dart';

class _Entry {
  final String text;
  final double weight;
  final Map<String, dynamic>? payload;
  _Entry(this.text, this.weight, this.payload);
}

class _TrieNode implements Comparable<_TrieNode> {
  final Map<int, _TrieNode> children = {};
  final List<_Entry> terminals = [];
  double maxWeight = 0.0;

  void updateMaxWeight(double weight) {
    if (weight > maxWeight) {
      maxWeight = weight;
    }
  }

  @override
  int compareTo(_TrieNode other) => other.maxWeight.compareTo(maxWeight);
}

/// In-memory completion suggester for fast prefix autocomplete and fuzzy suggestions.
class CompletionSuggester {
  final _TrieNode _root = _TrieNode();
  int _entryCount = 0;

  int get entryCount => _entryCount;

  /// Inserts a completion surface form with an associated relevance [weight] and optional [payload].
  void add(String text, double weight, [Map<String, dynamic>? payload]) {
    final clean = text.trim();
    if (clean.isEmpty) return;

    var current = _root;
    current.updateMaxWeight(weight);

    for (var i = 0; i < clean.length; i++) {
      final codeUnit = clean.codeUnitAt(i);
      current = current.children.putIfAbsent(codeUnit, () => _TrieNode());
      current.updateMaxWeight(weight);
    }

    current.terminals.add(_Entry(clean, weight, payload));
    _entryCount++;
  }

  /// Suggests completions matching the given [prefix].
  List<Suggestion> suggest(
    String prefix, [
    CompletionOptions options = const CompletionOptions(),
  ]) {
    final cleanPrefix = prefix.trim();
    if (cleanPrefix.isEmpty) return const [];

    if (options.fuzzy) {
      return _fuzzySuggest(cleanPrefix, options);
    } else {
      return _exactPrefixSuggest(cleanPrefix, options);
    }
  }

  List<Suggestion> _exactPrefixSuggest(
    String prefix,
    CompletionOptions options,
  ) {
    var current = _root;
    for (var i = 0; i < prefix.length; i++) {
      final codeUnit = prefix.codeUnitAt(i);
      final next = current.children[codeUnit];
      if (next == null) return const [];
      current = next;
    }

    // Branch-and-bound traversal collecting top-k terminals
    final candidates = <_Entry>[];
    _collectSubtree(current, candidates);

    candidates.sort((a, b) => b.weight.compareTo(a.weight));
    final topK = candidates.take(options.maxResults);

    return topK
        .map((e) => Suggestion(
              text: e.text,
              score: e.weight,
              payload: e.payload,
              distance: 0,
            ))
        .toList();
  }

  void _collectSubtree(_TrieNode node, List<_Entry> results) {
    results.addAll(node.terminals);
    for (final child in node.children.values) {
      _collectSubtree(child, results);
    }
  }

  List<Suggestion> _fuzzySuggest(
    String prefix,
    CompletionOptions options,
  ) {
    final results = <Suggestion>[];
    final fixedPrefixLen = math.min(options.prefixLength, prefix.length);
    final fixedPart = prefix.substring(0, fixedPrefixLen);

    // Navigate fixed prefix
    var current = _root;
    for (var i = 0; i < fixedPart.length; i++) {
      final codeUnit = fixedPart.codeUnitAt(i);
      final next = current.children[codeUnit];
      if (next == null) return const [];
      current = next;
    }

    // Levenshtein automata exploration for remaining query suffix
    final suffix = prefix.substring(fixedPrefixLen);
    final initialRow = List<int>.generate(suffix.length + 1, (i) => i);

    _fuzzySearchNode(
      node: current,
      currentWord: fixedPart,
      suffix: suffix,
      previousRow: initialRow,
      maxEdits: options.maxEdits,
      transpositions: options.transpositions,
      options: options,
      results: results,
    );

    results.sort();
    final seen = <String>{};
    final unique = <Suggestion>[];
    for (final s in results) {
      if (seen.add(s.text)) {
        unique.add(s);
        if (unique.length >= options.maxResults) break;
      }
    }

    return unique;
  }

  void _fuzzySearchNode({
    required _TrieNode node,
    required String currentWord,
    required String suffix,
    required List<int> previousRow,
    required int maxEdits,
    required bool transpositions,
    required CompletionOptions options,
    required List<Suggestion> results,
  }) {
    // If the edit distance at the end of the query suffix is <= maxEdits,
    // all completions under this subtree are valid suggestions!
    if (previousRow.last <= maxEdits) {
      final subtreeEntries = <_Entry>[];
      _collectSubtree(node, subtreeEntries);
      for (final e in subtreeEntries) {
        results.add(Suggestion(
          text: e.text,
          score: e.weight * (1.0 / (1.0 + previousRow.last)),
          payload: e.payload,
          distance: previousRow.last,
        ));
      }
    }

    // Check if any value in currentRow <= maxEdits, otherwise prune branch
    final minDistanceInRow =
        previousRow.reduce((a, b) => math.min(a, b));
    if (minDistanceInRow > maxEdits) {
      return;
    }

    for (final entry in node.children.entries) {
      final charCode = entry.key;
      final child = entry.value;
      final charStr = String.fromCharCode(charCode);

      final currentRow = List<int>.filled(suffix.length + 1, 0);
      currentRow[0] = previousRow[0] + 1;

      for (var col = 1; col <= suffix.length; col++) {
        final insertCost = currentRow[col - 1] + 1;
        final deleteCost = previousRow[col] + 1;
        final replaceCost =
            previousRow[col - 1] + (suffix.codeUnitAt(col - 1) == charCode ? 0 : 1);

        var cost = math.min(insertCost, math.min(deleteCost, replaceCost));
        currentRow[col] = cost;
      }

      _fuzzySearchNode(
        node: child,
        currentWord: currentWord + charStr,
        suffix: suffix,
        previousRow: currentRow,
        maxEdits: maxEdits,
        transpositions: transpositions,
        options: options,
        results: results,
      );
    }
  }
}
