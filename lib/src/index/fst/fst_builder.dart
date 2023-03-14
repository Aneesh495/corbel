import 'dart:math' as math;
import '../../utils/bytes_ref.dart';
import 'fst_node.dart';

/// Online linear-time builder constructing minimal acyclic finite state transducers
/// from sorted sequence of (BytesRef, int output) entries.
class FstBuilder {
  final List<FstState> _frontier = [FstState()];
  final Map<FstState, FstState> _dedupCache = {};
  BytesRef _lastTerm = BytesRef.empty;

  /// Adds a sorted term and its associated output (e.g. postings file offset).
  /// Terms must be strictly greater than preceding terms in lexicographical order.
  void add(BytesRef term, int output) {
    if (_lastTerm.length > 0 && term.compareTo(_lastTerm) <= 0) {
      throw ArgumentError('Terms must be added in strictly sorted order: got $term after $_lastTerm');
    }

    // Determine length of common prefix with previous term
    final prefixLen = _commonPrefixLength(_lastTerm, term);

    // Freeze and deduplicate frontier states beyond the common prefix
    _freezeTail(prefixLen);

    // Ensure frontier has enough states for new term
    while (_frontier.length <= term.length) {
      _frontier.add(FstState());
    }

    // Connect new suffix states along the frontier
    for (var i = prefixLen; i < term.length; i++) {
      final label = term[i];
      _frontier[i].addArc(label, _frontier[i + 1], 0);
    }

    // Mark final state
    final lastState = _frontier[term.length];
    lastState.isFinal = true;

    // Push output along common prefix
    _pushOutput(prefixLen, term, output);

    _lastTerm = term.deepCopy();
  }

  void _pushOutput(int prefixLen, BytesRef term, int output) {
    var remainingOutput = output;

    for (var i = 0; i < prefixLen; i++) {
      final label = term[i];
      final arc = _frontier[i].findArc(label)!;
      final existingOutput = arc.output;

      if (existingOutput == remainingOutput) {
        remainingOutput = 0;
        break;
      }

      final common = math.min(existingOutput, remainingOutput);
      final wordDiff = remainingOutput - common;
      final arcDiff = existingOutput - common;

      arc.output = common;

      // Push arcDiff down into existing subtree of arc.target
      if (arcDiff > 0) {
        _propagateOutput(arc.target, arcDiff);
      }

      remainingOutput = wordDiff;
    }

    if (prefixLen < term.length) {
      final label = term[prefixLen];
      final arc = _frontier[prefixLen].findArc(label)!;
      arc.output = remainingOutput;
    } else {
      _frontier[term.length].finalOutput += remainingOutput;
    }
  }

  void _propagateOutput(FstState state, int diff) {
    if (state.isFinal) {
      state.finalOutput += diff;
    }
    for (final arc in state.arcs) {
      arc.output += diff;
    }
  }

  void _freezeTail(int prefixLen) {
    for (var i = _frontier.length - 1; i > prefixLen; i--) {
      final state = _frontier[i];
      final compiled = _compileState(state);
      _frontier[i - 1].findArc(_lastTerm[i - 1])?.target = compiled;
      _frontier.removeLast();
    }
  }

  FstState _compileState(FstState state) {
    final existing = _dedupCache[state];
    if (existing != null) {
      return existing;
    }
    _dedupCache[state] = state;
    return state;
  }

  /// Finalizes construction and returns compiled minimal root state.
  FstState finish() {
    _freezeTail(0);
    return _compileState(_frontier[0]);
  }

  int _commonPrefixLength(BytesRef a, BytesRef b) {
    final minLen = math.min(a.length, b.length);
    for (var i = 0; i < minLen; i++) {
      if (a[i] != b[i]) return i;
    }
    return minLen;
  }
}
