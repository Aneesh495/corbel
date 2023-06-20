/// Abstract eviction policy contract for selecting victim frames in the buffer pool.
abstract class Replacer {
  /// Records a read or write access to [frameId].
  void recordAccess(int frameId);

  /// Pins [frameId] preventing it from being chosen as an eviction victim.
  void pin(int frameId);

  /// Unpins [frameId] making it eligible for eviction.
  void unpin(int frameId);

  /// Selects a frame to evict. Returns frame ID, or null if all frames are pinned.
  int? victim();

  /// Number of frames currently eligible for eviction.
  int get size;
}

/// CLOCK (Second-Chance) replacement algorithm.
class ClockReplacer implements Replacer {
  final int numFrames;
  final List<bool> _referenced;
  final List<bool> _inReplacer;
  int _clockHand = 0;
  int _size = 0;

  ClockReplacer(this.numFrames)
      : _referenced = List.filled(numFrames, false),
        _inReplacer = List.filled(numFrames, false);

  @override
  int get size => _size;

  @override
  void recordAccess(int frameId) {
    if (frameId >= 0 && frameId < numFrames) {
      _referenced[frameId] = true;
    }
  }

  @override
  void pin(int frameId) {
    if (frameId >= 0 && frameId < numFrames) {
      if (_inReplacer[frameId]) {
        _inReplacer[frameId] = false;
        _size--;
      }
    }
  }

  @override
  void unpin(int frameId) {
    if (frameId >= 0 && frameId < numFrames) {
      if (!_inReplacer[frameId]) {
        _inReplacer[frameId] = true;
        _referenced[frameId] = false;
        _size++;
      }
    }
  }

  @override
  int? victim() {
    if (_size == 0) return null;

    final start = _clockHand;
    var scanned = 0;

    while (scanned < numFrames * 2) {
      final frameId = _clockHand;
      _clockHand = (_clockHand + 1) % numFrames;
      scanned++;

      if (_inReplacer[frameId]) {
        if (_referenced[frameId]) {
          // Second chance: clear reference bit and continue
          _referenced[frameId] = false;
        } else {
          // Evict victim
          _inReplacer[frameId] = false;
          _size--;
          return frameId;
        }
      }
    }

    // Fallback: evict first available unpinned frame
    for (var i = 0; i < numFrames; i++) {
      final idx = (start + i) % numFrames;
      if (_inReplacer[idx]) {
        _inReplacer[idx] = false;
        _size--;
        return idx;
      }
    }

    return null;
  }
}

/// 2-Queue (2Q) replacement algorithm.
/// Divides frames into a FIFO queue (A1in) for first-touch pages and an LRU queue (Am)
/// for frequently re-referenced pages, completely eliminating sequential scan cache pollution.
class TwoQueueReplacer implements Replacer {
  final int numFrames;
  final Set<int> _a1in = {}; // FIFO queue for first-touch frames
  final List<int> _am = []; // LRU list for frequently accessed frames
  final Set<int> _eligible = {}; // Unpinned frames eligible for eviction

  TwoQueueReplacer(this.numFrames);

  @override
  int get size => _eligible.length;

  @override
  void recordAccess(int frameId) {
    if (_am.contains(frameId)) {
      // Move to MRU position in Am
      _am.remove(frameId);
      _am.add(frameId);
    } else if (_a1in.contains(frameId)) {
      // Promote from A1in to Am on second reference
      _a1in.remove(frameId);
      _am.add(frameId);
    }
  }

  @override
  void pin(int frameId) {
    _eligible.remove(frameId);
  }

  @override
  void unpin(int frameId) {
    _eligible.add(frameId);
    if (!_a1in.contains(frameId) && !_am.contains(frameId)) {
      _a1in.add(frameId);
    }
  }

  @override
  int? victim() {
    if (_eligible.isEmpty) return null;

    // 1. First attempt eviction from FIFO A1in queue
    for (final frameId in _a1in) {
      if (_eligible.contains(frameId)) {
        _a1in.remove(frameId);
        _eligible.remove(frameId);
        return frameId;
      }
    }

    // 2. Otherwise evict LRU frame from Am
    for (var i = 0; i < _am.length; i++) {
      final frameId = _am[i];
      if (_eligible.contains(frameId)) {
        _am.removeAt(i);
        _eligible.remove(frameId);
        return frameId;
      }
    }

    // Fallback: evict any eligible frame
    final victim = _eligible.first;
    _eligible.remove(victim);
    _a1in.remove(victim);
    _am.remove(victim);
    return victim;
  }
}
