import 'dart:convert';
import '../../storage/index_input.dart';
import '../../storage/index_output.dart';
import '../../utils/bytes_ref.dart';
import 'fst_builder.dart';
import 'fst_node.dart';

/// Minimal Deterministic Acyclic Finite State Transducer (FST) term dictionary.
/// Maps byte sequences (terms) to integer outputs (postings file offsets) with prefix and suffix sharing.
class Fst {
  final FstState root;

  Fst(this.root);

  /// Builds a minimal FST from a sequence of (BytesRef, int output) entries, sorting them lexicographically.
  factory Fst.fromSortedEntries(List<MapEntry<BytesRef, int>> entries) {
    final sorted = List<MapEntry<BytesRef, int>>.from(entries)
      ..sort((a, b) => a.key.compareTo(b.key));
    final builder = FstBuilder();
    for (final entry in sorted) {
      builder.add(entry.key, entry.value);
    }
    return Fst(builder.finish());
  }

  /// Factory helper from sorted string terms.
  factory Fst.fromSortedTerms(List<MapEntry<String, int>> terms) {
    final entries = terms
        .map((e) => MapEntry(BytesRef.fromString(e.key), e.value))
        .toList();
    return Fst.fromSortedEntries(entries);
  }

  /// Exact term lookup: returns output if term exists, null otherwise.
  int? get(BytesRef term) {
    var state = root;
    var accumulatedOutput = 0;

    for (var i = 0; i < term.length; i++) {
      final label = term[i];
      final arc = state.findArc(label);
      if (arc == null) return null;

      accumulatedOutput += arc.output;
      state = arc.target;
    }

    if (!state.isFinal) return null;
    return accumulatedOutput + state.finalOutput;
  }

  /// Exact string term lookup.
  int? getString(String term) => get(BytesRef.fromString(term));

  /// Finds all terms sharing the given prefix, returning matching terms and accumulated outputs.
  List<MapEntry<String, int>> prefixSearch(String prefix) {
    final prefixBytes = BytesRef.fromString(prefix);
    var state = root;
    var acc = 0;

    for (var i = 0; i < prefixBytes.length; i++) {
      final label = prefixBytes[i];
      final arc = state.findArc(label);
      if (arc == null) return [];
      acc += arc.output;
      state = arc.target;
    }

    final results = <MapEntry<String, int>>[];
    final currentBytes = <int>[...prefixBytes.bytes.sublist(0, prefixBytes.length)];

    void dfs(FstState s, int currentAcc) {
      if (s.isFinal) {
        final termStr = utf8.decode(currentBytes);
        results.add(MapEntry(termStr, currentAcc + s.finalOutput));
      }
      for (final arc in s.arcs) {
        currentBytes.add(arc.label);
        dfs(arc.target, currentAcc + arc.output);
        currentBytes.removeLast();
      }
    }

    dfs(state, acc);
    return results;
  }

  /// Fuzzy search returning terms within Levenshtein edit distance [maxEdits] (1 or 2).
  List<MapEntry<String, int>> fuzzySearch(String target, int maxEdits) {
    final results = <MapEntry<String, int>>[];
    final currentChars = <int>[];

    void dfs(FstState state, List<int> prevRow, int acc) {
      if (state.isFinal && prevRow.last <= maxEdits) {
        results.add(MapEntry(utf8.decode(currentChars), acc + state.finalOutput));
      }

      for (final arc in state.arcs) {
        final charCode = arc.label;
        final currRow = List<int>.filled(target.length + 1, 0);
        currRow[0] = prevRow[0] + 1;

        var minInRow = currRow[0];
        for (var col = 1; col <= target.length; col++) {
          final targetChar = target.codeUnitAt(col - 1);
          final cost = targetChar == charCode ? 0 : 1;
          final deletion = prevRow[col] + 1;
          final insertion = currRow[col - 1] + 1;
          final substitution = prevRow[col - 1] + cost;

          var m = deletion < insertion ? deletion : insertion;
          if (substitution < m) m = substitution;
          currRow[col] = m;

          if (m < minInRow) minInRow = m;
        }

        if (minInRow <= maxEdits) {
          currentChars.add(charCode);
          dfs(arc.target, currRow, acc + arc.output);
          currentChars.removeLast();
        }
      }
    }

    final initialRow = List<int>.generate(target.length + 1, (i) => i);
    dfs(root, initialRow, 0);
    return results;
  }

  /// Traverses all terms in the FST matching [predicate].
  List<MapEntry<String, int>> searchMatching(bool Function(String term) predicate) {
    final results = <MapEntry<String, int>>[];
    final currentBytes = <int>[];

    void dfs(FstState s, int acc) {
      if (s.isFinal) {
        final term = utf8.decode(currentBytes);
        if (predicate(term)) {
          results.add(MapEntry(term, acc + s.finalOutput));
        }
      }
      for (final arc in s.arcs) {
        currentBytes.add(arc.label);
        dfs(arc.target, acc + arc.output);
        currentBytes.removeLast();
      }
    }

    dfs(root, 0);
    return results;
  }

  /// Serializes FST into output stream.
  void serialize(IndexOutput out) {
    // Collect all reachable states in topological order
    final stateList = <FstState>[];
    final stateIdMap = <FstState, int>{};

    void visit(FstState s) {
      if (stateIdMap.containsKey(s)) return;
      stateIdMap[s] = stateList.length;
      stateList.add(s);
      for (final arc in s.arcs) {
        visit(arc.target);
      }
    }

    visit(root);

    out.writeVInt(stateList.length);
    for (final s in stateList) {
      out.writeByte(s.isFinal ? 1 : 0);
      out.writeVLong(s.finalOutput);
      out.writeVInt(s.arcs.length);
      for (final arc in s.arcs) {
        out.writeByte(arc.label);
        out.writeVLong(arc.output);
        out.writeVInt(stateIdMap[arc.target]!);
      }
    }
  }

  /// Deserializes FST from input stream.
  static Fst deserialize(IndexInput inp) {
    final count = inp.readVInt();
    final states = List<FstState>.generate(count, (_) => FstState());

    for (var i = 0; i < count; i++) {
      final s = states[i];
      s.isFinal = inp.readByte() == 1;
      s.finalOutput = inp.readVLong();
      final numArcs = inp.readVInt();
      for (var a = 0; a < numArcs; a++) {
        final label = inp.readByte();
        final output = inp.readVLong();
        final targetIdx = inp.readVInt();
        s.addArc(label, states[targetIdx], output);
      }
    }

    return Fst(states[0]);
  }
}
