import 'dart:typed_data';
import '../../utils/bytes_ref.dart';

/// Single outgoing transition arc in an FST state.
class FstArc {
  /// Transition byte label (0 to 255).
  final int label;

  /// Target state node.
  FstState target;

  /// Numeric output associated with traversing this arc.
  int output;

  FstArc({
    required this.label,
    required this.target,
    this.output = 0,
  });

  FstArc clone() => FstArc(
        label: label,
        target: target,
        output: output,
      );
}

/// Uncompiled mutable state node during online FST construction.
class FstState {
  /// Whether this state is a valid accepting state for a term.
  bool isFinal = false;

  /// Output value emitted if the term terminates at this state.
  int finalOutput = 0;

  /// Sorted outgoing transition arcs keyed by label byte.
  final List<FstArc> arcs = [];

  /// Finds outgoing arc for label, or null if none.
  FstArc? findArc(int label) {
    for (var i = 0; i < arcs.length; i++) {
      if (arcs[i].label == label) return arcs[i];
    }
    return null;
  }

  /// Adds or updates outgoing arc.
  void addArc(int label, FstState target, int output) {
    arcs.removeWhere((a) => a.label == label);
    arcs.add(FstArc(label: label, target: target, output: output));
    arcs.sort((a, b) => a.label.compareTo(b.label));
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! FstState) return false;
    if (isFinal != other.isFinal || finalOutput != other.finalOutput) {
      return false;
    }
    if (arcs.length != other.arcs.length) return false;
    for (var i = 0; i < arcs.length; i++) {
      final a = arcs[i];
      final b = other.arcs[i];
      if (a.label != b.label ||
          a.output != b.output ||
          !identical(a.target, b.target)) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode {
    var hash = Object.hash(isFinal, finalOutput, arcs.length);
    for (var i = 0; i < arcs.length; i++) {
      hash ^= Object.hash(arcs[i].label, arcs[i].output, identityHashCode(arcs[i].target));
    }
    return hash;
  }
}
