import 'dart:convert';

/// Consistent hashing ring using virtual nodes for uniform data distribution
/// across dynamic cluster nodes.
class ConsistentHashRing<T> {
  final int virtualNodesPerNode;
  final List<int> _ringKeys = [];
  final Map<int, T> _ring = {};
  final Set<T> _nodes = {};

  ConsistentHashRing({this.virtualNodesPerNode = 100});

  /// All physical nodes currently registered in the ring.
  Set<T> get nodes => Set.unmodifiable(_nodes);

  /// Number of physical nodes in the ring.
  int get nodeCount => _nodes.length;

  /// Adds a physical node to the ring, allocating virtual token points.
  void addNode(T node) {
    if (_nodes.add(node)) {
      for (var i = 0; i < virtualNodesPerNode; i++) {
        final token = _hash('$node#vnode$i');
        _ring[token] = node;
        _ringKeys.add(token);
      }
      _ringKeys.sort();
    }
  }

  /// Removes a physical node from the ring and cleans up its virtual tokens.
  void removeNode(T node) {
    if (_nodes.remove(node)) {
      for (var i = 0; i < virtualNodesPerNode; i++) {
        final token = _hash('$node#vnode$i');
        _ring.remove(token);
        _ringKeys.remove(token);
      }
    }
  }

  /// Finds the primary node responsible for the given [key].
  T? getNode(String key) {
    if (_ringKeys.isEmpty) return null;

    final hash = _hash(key);
    final idx = _binarySearch(hash);
    final targetToken = _ringKeys[idx % _ringKeys.length];
    return _ring[targetToken];
  }

  /// Finds [count] distinct physical nodes (primary + replicas) responsible for [key].
  List<T> getNodes(String key, int count) {
    if (_ringKeys.isEmpty || count <= 0) return const [];
    if (count >= _nodes.length) return _nodes.toList();

    final hash = _hash(key);
    var idx = _binarySearch(hash);
    final distinctNodes = <T>[];
    final seen = <T>{};

    for (var i = 0; i < _ringKeys.length; i++) {
      final token = _ringKeys[(idx + i) % _ringKeys.length];
      final node = _ring[token];
      if (node != null && seen.add(node)) {
        distinctNodes.add(node);
        if (distinctNodes.length == count) break;
      }
    }

    return distinctNodes;
  }

  int _binarySearch(int hash) {
    var low = 0;
    var high = _ringKeys.length - 1;

    if (hash > _ringKeys[high] || hash <= _ringKeys[0]) {
      return 0;
    }

    while (low <= high) {
      final mid = low + ((high - low) >> 1);
      final midVal = _ringKeys[mid];

      if (midVal >= hash) {
        if (mid == 0 || _ringKeys[mid - 1] < hash) {
          return mid;
        }
        high = mid - 1;
      } else {
        low = mid + 1;
      }
    }

    return 0;
  }

  /// Murmur3 32-bit hash algorithm implementation for uniform key distribution.
  static int _hash(String key) {
    final bytes = utf8.encode(key);
    const int c1 = 0xcc9e2d51;
    const int c2 = 0x1b873593;
    var h1 = 0;

    final len = bytes.length;
    final nblocks = len >> 2;

    for (var i = 0; i < nblocks; i++) {
      final index = i << 2;
      var k1 = bytes[index] |
          (bytes[index + 1] << 8) |
          (bytes[index + 2] << 16) |
          (bytes[index + 3] << 24);

      k1 = (k1 * c1) & 0xFFFFFFFF;
      k1 = ((k1 << 15) | (k1 >>> 17)) & 0xFFFFFFFF;
      k1 = (k1 * c2) & 0xFFFFFFFF;

      h1 ^= k1;
      h1 = ((h1 << 13) | (h1 >>> 19)) & 0xFFFFFFFF;
      h1 = ((h1 * 5) + 0xe6546b64) & 0xFFFFFFFF;
    }

    var k1 = 0;
    final tail = nblocks << 2;
    switch (len & 3) {
      case 3:
        k1 ^= bytes[tail + 2] << 16;
        continue c2case;
      c2case:
      case 2:
        k1 ^= bytes[tail + 1] << 8;
        continue c1case;
      c1case:
      case 1:
        k1 ^= bytes[tail];
        k1 = (k1 * c1) & 0xFFFFFFFF;
        k1 = ((k1 << 15) | (k1 >>> 17)) & 0xFFFFFFFF;
        k1 = (k1 * c2) & 0xFFFFFFFF;
        h1 ^= k1;
    }

    h1 ^= len;
    h1 ^= h1 >>> 16;
    h1 = (h1 * 0x85ebca6b) & 0xFFFFFFFF;
    h1 ^= h1 >>> 13;
    h1 = (h1 * 0xc2b2ae35) & 0xFFFFFFFF;
    h1 ^= h1 >>> 16;

    return h1;
  }
}
