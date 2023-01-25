/// High-performance binary heap priority queue and bounded top-k collector.

/// Callback comparing two elements: returns negative if a < b, positive if a > b, zero if equal.
typedef PriorityComparator<T> = int Function(T a, T b);

/// Min-heap or max-heap depending on the comparator.
/// By default, smallest elements according to comparator are placed at the root.
class PriorityQueue<T> {
  final PriorityComparator<T> _comparator;
  final List<T> _heap = [];

  /// Constructs a priority queue with an explicit comparator.
  PriorityQueue(this._comparator);

  /// Number of elements currently in the priority queue.
  int get length => _heap.length;

  /// Whether the priority queue contains zero elements.
  bool get isEmpty => _heap.isEmpty;

  /// Whether the priority queue contains one or more elements.
  bool get isNotEmpty => _heap.isNotEmpty;

  /// Retrieves the top element (root of heap) without removing it.
  /// Throws StateError if queue is empty.
  T get top {
    if (_heap.isEmpty) {
      throw StateError('Cannot inspect top element of empty PriorityQueue');
    }
    return _heap[0];
  }

  /// Adds an element to the heap.
  void add(T element) {
    _heap.add(element);
    _siftUp(_heap.length - 1);
  }

  /// Removes and returns the top element of the heap.
  /// Throws StateError if queue is empty.
  T pop() {
    if (_heap.isEmpty) {
      throw StateError('Cannot pop from empty PriorityQueue');
    }
    final result = _heap[0];
    final last = _heap.removeLast();
    if (_heap.isNotEmpty) {
      _heap[0] = last;
      _siftDown(0);
    }
    return result;
  }

  /// Empties the priority queue.
  void clear() {
    _heap.clear();
  }

  /// Returns elements sorted according to the comparator.
  List<T> toSortedList() {
    final copy = List<T>.from(_heap);
    copy.sort(_comparator);
    return copy;
  }

  void _siftUp(int index) {
    var current = index;
    while (current > 0) {
      final parent = (current - 1) >> 1;
      if (_comparator(_heap[current], _heap[parent]) < 0) {
        final tmp = _heap[current];
        _heap[current] = _heap[parent];
        _heap[parent] = tmp;
        current = parent;
      } else {
        break;
      }
    }
  }

  void _siftDown(int index) {
    var current = index;
    final size = _heap.length;
    while (true) {
      var smallest = current;
      final left = (current << 1) + 1;
      final right = left + 1;

      if (left < size && _comparator(_heap[left], _heap[smallest]) < 0) {
        smallest = left;
      }
      if (right < size && _comparator(_heap[right], _heap[smallest]) < 0) {
        smallest = right;
      }

      if (smallest != current) {
        final tmp = _heap[current];
        _heap[current] = _heap[smallest];
        _heap[smallest] = tmp;
        current = smallest;
      } else {
        break;
      }
    }
  }
}

/// Bounded priority queue maintaining at most K top elements without unbounded allocations.
/// Designed specifically for search hit collectors (e.g. TopDocsCollector).
///
/// If comparator defines a min-heap (smaller score is at top), then keeping the largest scores
/// means evicting the root whenever heap is full and a new candidate exceeds root.
class BoundedPriorityQueue<T> {
  /// Maximum capacity of this bounded queue.
  final int capacity;

  final PriorityComparator<T> _comparator;
  late final List<T?> _heap;
  int _size = 0;

  /// Creates a bounded priority queue with fixed capacity and comparator.
  BoundedPriorityQueue(this.capacity, this._comparator) {
    if (capacity <= 0) {
      throw ArgumentError.value(capacity, 'capacity', 'Must be strictly positive');
    }
    _heap = List<T?>.filled(capacity + 1, null);
  }

  /// Number of elements currently stored.
  int get length => _size;

  /// Capacity limit.
  int get maxSize => capacity;

  /// Checks if queue is empty.
  bool get isEmpty => _size == 0;

  /// Checks if queue is not empty.
  bool get isNotEmpty => _size > 0;

  /// Retrieves the weakest element in the bounded collection.
  /// Throws StateError if queue is empty.
  T get top {
    if (_size == 0) {
      throw StateError('Cannot inspect top element of empty BoundedPriorityQueue');
    }
    return _heap[1]!;
  }

  /// Inserts candidate element.
  /// If the queue is not yet full, adds element directly.
  /// If queue is full and element is strictly superior to top (weakest),
  /// replaces top and sifts down, returning the evicted element.
  /// Otherwise, if element is inferior, returns element without modifying queue.
  T? insertWithOverflow(T element) {
    if (_size < capacity) {
      _size++;
      _heap[_size] = element;
      _upHeap(_size);
      return null;
    } else if (_size > 0 && _comparator(element, _heap[1]!) > 0) {
      final evicted = _heap[1];
      _heap[1] = element;
      _downHeap(1);
      return evicted;
    } else {
      return element;
    }
  }

  /// Removes and returns the top element.
  T pop() {
    if (_size == 0) {
      throw StateError('Cannot pop from empty BoundedPriorityQueue');
    }
    final result = _heap[1]!;
    _heap[1] = _heap[_size];
    _heap[_size] = null;
    _size--;
    if (_size > 0) {
      _downHeap(1);
    }
    return result;
  }

  /// Empties the queue.
  void clear() {
    for (var i = 1; i <= _size; i++) {
      _heap[i] = null;
    }
    _size = 0;
  }

  /// Returns all stored elements sorted in descending order (highest score first).
  List<T> drainToListDescending() {
    final list = <T>[];
    while (_size > 0) {
      list.add(pop());
    }
    // Since heap was min-heap, pop() extracts ascending order; reverse for descending
    return list.reversed.toList();
  }

  void _upHeap(int start) {
    var i = start;
    final node = _heap[i]!;
    var j = i >> 1;
    while (j > 0 && _comparator(node, _heap[j]!) < 0) {
      _heap[i] = _heap[j];
      i = j;
      j = j >> 1;
    }
    _heap[i] = node;
  }

  void _downHeap(int start) {
    var i = start;
    final node = _heap[i]!;
    var j = i << 1;
    var k = j + 1;
    if (k <= _size && _comparator(_heap[k]!, _heap[j]!) < 0) {
      j = k;
    }
    while (j <= _size && _comparator(_heap[j]!, node) < 0) {
      _heap[i] = _heap[j];
      i = j;
      j = i << 1;
      k = j + 1;
      if (k <= _size && _comparator(_heap[k]!, _heap[j]!) < 0) {
        j = k;
      }
    }
    _heap[i] = node;
  }
}
