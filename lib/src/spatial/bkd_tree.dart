import 'dart:math' as math;
import 'dart:typed_data';
import '../storage/index_input.dart';
import '../storage/index_output.dart';

/// A multidimensional point entry containing a document ID and k-dimensional values.
class BkdPoint {
  final int docId;
  final Float64List values;

  BkdPoint(this.docId, List<double> values)
      : values = Float64List.fromList(values);

  int get numDimensions => values.length;

  double operator [](int dimension) => values[dimension];

  @override
  String toString() => 'BkdPoint(docId: $docId, values: $values)';
}

/// Represents an axis-aligned multidimensional bounding box.
class BkdBox {
  final Float64List minValues;
  final Float64List maxValues;

  BkdBox(List<double> min, List<double> max)
      : assert(min.length == max.length, 'Dimension count must match'),
        minValues = Float64List.fromList(min),
        maxValues = Float64List.fromList(max);

  int get numDimensions => minValues.length;

  /// Checks if this box fully contains another box.
  bool containsBox(BkdBox other) {
    for (var d = 0; d < numDimensions; d++) {
      if (other.minValues[d] < minValues[d] || other.maxValues[d] > maxValues[d]) {
        return false;
      }
    }
    return true;
  }

  /// Checks if this box intersects another box.
  bool intersectsBox(BkdBox other) {
    for (var d = 0; d < numDimensions; d++) {
      if (minValues[d] > other.maxValues[d] || maxValues[d] < other.minValues[d]) {
        return false;
      }
    }
    return true;
  }

  /// Checks if this box contains a point.
  bool containsPoint(BkdPoint point) {
    for (var d = 0; d < numDimensions; d++) {
      final v = point.values[d];
      if (v < minValues[d] || v > maxValues[d]) {
        return false;
      }
    }
    return true;
  }

  /// Clones this bounding box.
  BkdBox copy() => BkdBox(List.of(minValues), List.of(maxValues));
}

/// Base node in the Block KD-Tree.
abstract class BkdNode {
  final BkdBox bounds;
  final int count;

  BkdNode({required this.bounds, required this.count});

  bool get isLeaf;
}

/// Internal KD split node.
class BkdInternalNode extends BkdNode {
  final int splitDim;
  final double splitValue;
  final BkdNode left;
  final BkdNode right;

  BkdInternalNode({
    required super.bounds,
    required super.count,
    required this.splitDim,
    required this.splitValue,
    required this.left,
    required this.right,
  });

  @override
  bool get isLeaf => false;
}

/// Leaf block node containing concrete point entries.
class BkdLeafNode extends BkdNode {
  final List<BkdPoint> points;

  BkdLeafNode({
    required super.bounds,
    required this.points,
  }) : super(count: points.length);

  @override
  bool get isLeaf => true;
}

/// Block KD-Tree (BKD-Tree) for multi-dimensional spatial range queries and k-NN search.
class BkdTree {
  final int numDimensions;
  final int maxPointsInLeaf;
  final BkdNode? root;
  final int totalPoints;

  BkdTree({
    required this.numDimensions,
    required this.maxPointsInLeaf,
    required this.root,
    required this.totalPoints,
  });

  /// Builds a BKD-Tree from an iterable of points.
  factory BkdTree.build(
    List<BkdPoint> points, {
    int maxPointsInLeaf = 512,
  }) {
    if (points.isEmpty) {
      return BkdTree(
        numDimensions: 0,
        maxPointsInLeaf: maxPointsInLeaf,
        root: null,
        totalPoints: 0,
      );
    }

    final numDimensions = points.first.numDimensions;
    final mutablePoints = List<BkdPoint>.from(points);
    final bounds = _calculateBounds(mutablePoints, numDimensions);

    final root = _buildRecursive(
      mutablePoints,
      0,
      mutablePoints.length,
      bounds,
      0,
      numDimensions,
      maxPointsInLeaf,
    );

    return BkdTree(
      numDimensions: numDimensions,
      maxPointsInLeaf: maxPointsInLeaf,
      root: root,
      totalPoints: points.length,
    );
  }

  static BkdBox _calculateBounds(List<BkdPoint> points, int numDimensions) {
    final mins = List.filled(numDimensions, double.infinity);
    final maxs = List.filled(numDimensions, -double.infinity);

    for (final p in points) {
      for (var d = 0; d < numDimensions; d++) {
        final v = p.values[d];
        if (v < mins[d]) mins[d] = v;
        if (v > maxs[d]) maxs[d] = v;
      }
    }

    return BkdBox(mins, maxs);
  }

  static BkdNode _buildRecursive(
    List<BkdPoint> points,
    int from,
    int to,
    BkdBox bounds,
    int depth,
    int numDimensions,
    int maxPointsInLeaf,
  ) {
    final count = to - from;
    if (count <= maxPointsInLeaf) {
      final leafPoints = List<BkdPoint>.generate(
        count,
        (i) => points[from + i],
      );
      return BkdLeafNode(bounds: bounds, points: leafPoints);
    }

    // Determine the dimension with the largest coordinate span
    var maxSpan = -1.0;
    var splitDim = 0;
    for (var d = 0; d < numDimensions; d++) {
      final span = bounds.maxValues[d] - bounds.minValues[d];
      if (span > maxSpan) {
        maxSpan = span;
        splitDim = d;
      }
    }

    // Partition points around the median in splitDim
    final mid = from + (count ~/ 2);
    _quickSelect(points, from, to - 1, mid, splitDim);
    final splitVal = points[mid].values[splitDim];

    // Compute left bounds
    final leftMaxs = List.of(bounds.maxValues);
    leftMaxs[splitDim] = splitVal;
    final leftBounds = BkdBox(bounds.minValues, leftMaxs);

    // Compute right bounds
    final rightMins = List.of(bounds.minValues);
    rightMins[splitDim] = splitVal;
    final rightBounds = BkdBox(rightMins, bounds.maxValues);

    final leftChild = _buildRecursive(
      points,
      from,
      mid,
      leftBounds,
      depth + 1,
      numDimensions,
      maxPointsInLeaf,
    );

    final rightChild = _buildRecursive(
      points,
      mid,
      to,
      rightBounds,
      depth + 1,
      numDimensions,
      maxPointsInLeaf,
    );

    return BkdInternalNode(
      bounds: bounds,
      count: count,
      splitDim: splitDim,
      splitValue: splitVal,
      left: leftChild,
      right: rightChild,
    );
  }

  /// Partitions the array slice so that points[k] is at its sorted position along [dim].
  static void _quickSelect(
    List<BkdPoint> list,
    int left,
    int right,
    int k,
    int dim,
  ) {
    while (left < right) {
      final pivotIndex = _partition(list, left, right, dim);
      if (pivotIndex == k) {
        return;
      } else if (pivotIndex < k) {
        left = pivotIndex + 1;
      } else {
        right = pivotIndex - 1;
      }
    }
  }

  static int _partition(List<BkdPoint> list, int left, int right, int dim) {
    final pivot = list[right].values[dim];
    var i = left;
    for (var j = left; j < right; j++) {
      if (list[j].values[dim] <= pivot) {
        final tmp = list[i];
        list[i] = list[j];
        list[j] = tmp;
        i++;
      }
    }
    final tmp = list[i];
    list[i] = list[right];
    list[right] = tmp;
    return i;
  }

  /// Searches the tree for all document IDs falling within [queryBox].
  List<int> queryRange(BkdBox queryBox) {
    final results = <int>[];
    if (root == null) return results;

    _queryRecursive(root!, queryBox, results);
    return results;
  }

  void _queryRecursive(BkdNode node, BkdBox queryBox, List<int> results) {
    // 1. If node bounds do not intersect query box, prune subtree completely
    if (!node.bounds.intersectsBox(queryBox)) {
      return;
    }

    // 2. If node bounds are fully contained within query box, accept all points
    if (queryBox.containsBox(node.bounds)) {
      _collectAll(node, results);
      return;
    }

    // 3. Otherwise descend
    if (node is BkdInternalNode) {
      _queryRecursive(node.left, queryBox, results);
      _queryRecursive(node.right, queryBox, results);
    } else if (node is BkdLeafNode) {
      for (final p in node.points) {
        if (queryBox.containsPoint(p)) {
          results.add(p.docId);
        }
      }
    }
  }

  void _collectAll(BkdNode node, List<int> results) {
    if (node is BkdLeafNode) {
      for (final p in node.points) {
        results.add(p.docId);
      }
    } else if (node is BkdInternalNode) {
      _collectAll(node.left, results);
      _collectAll(node.right, results);
    }
  }

  /// Finds the [k] nearest points to [target] using Euclidean distance in index coordinates.
  List<BkdPoint> queryNearest(List<double> target, int k) {
    if (root == null || k <= 0) return const [];

    final targetPoint = BkdPoint(-1, target);
    final heap = <_DistancePair>[];

    _knnRecursive(root!, targetPoint, k, heap);
    heap.sort((a, b) => a.distance.compareTo(b.distance));
    return heap.map((e) => e.point).toList();
  }

  void _knnRecursive(
    BkdNode node,
    BkdPoint target,
    int k,
    List<_DistancePair> heap,
  ) {
    final minDistToBox = _minDistanceToBox(target, node.bounds);
    if (heap.length == k && minDistToBox >= heap.last.distance) {
      return; // Pruned
    }

    if (node is BkdLeafNode) {
      for (final p in node.points) {
        final dist = _euclideanDistance(target, p);
        if (heap.length < k) {
          heap.add(_DistancePair(p, dist));
          heap.sort((a, b) => a.distance.compareTo(b.distance));
        } else if (dist < heap.last.distance) {
          heap.removeLast();
          heap.add(_DistancePair(p, dist));
          heap.sort((a, b) => a.distance.compareTo(b.distance));
        }
      }
    } else if (node is BkdInternalNode) {
      final distLeft = _minDistanceToBox(target, node.left.bounds);
      final distRight = _minDistanceToBox(target, node.right.bounds);

      if (distLeft < distRight) {
        _knnRecursive(node.left, target, k, heap);
        _knnRecursive(node.right, target, k, heap);
      } else {
        _knnRecursive(node.right, target, k, heap);
        _knnRecursive(node.left, target, k, heap);
      }
    }
  }

  static double _euclideanDistance(BkdPoint a, BkdPoint b) {
    var sum = 0.0;
    for (var d = 0; d < a.numDimensions; d++) {
      final diff = a.values[d] - b.values[d];
      sum += diff * diff;
    }
    return math.sqrt(sum);
  }

  static double _minDistanceToBox(BkdPoint p, BkdBox box) {
    var sum = 0.0;
    for (var d = 0; d < p.numDimensions; d++) {
      final v = p.values[d];
      final min = box.minValues[d];
      final max = box.maxValues[d];
      if (v < min) {
        final diff = min - v;
        sum += diff * diff;
      } else if (v > max) {
        final diff = v - max;
        sum += diff * diff;
      }
    }
    return math.sqrt(sum);
  }

  /// Serializes the BKD tree to [output].
  void writeTo(IndexOutput output) {
    output.writeVInt(numDimensions);
    output.writeVInt(maxPointsInLeaf);
    output.writeVInt(totalPoints);

    if (root == null) {
      output.writeByte(0); // empty marker
      return;
    }

    output.writeByte(1); // non-empty
    _serializeNode(root!, output);
  }

  static void _serializeNode(BkdNode node, IndexOutput output) {
    // Write node bounds
    for (var d = 0; d < node.bounds.numDimensions; d++) {
      output.writeFloat64(node.bounds.minValues[d]);
      output.writeFloat64(node.bounds.maxValues[d]);
    }

    if (node is BkdLeafNode) {
      output.writeByte(0); // Leaf flag
      output.writeVInt(node.points.length);
      for (final p in node.points) {
        output.writeVInt(p.docId);
        for (var d = 0; d < p.numDimensions; d++) {
          output.writeFloat64(p.values[d]);
        }
      }
    } else if (node is BkdInternalNode) {
      output.writeByte(1); // Internal flag
      output.writeVInt(node.splitDim);
      output.writeFloat64(node.splitValue);
      _serializeNode(node.left, output);
      _serializeNode(node.right, output);
    }
  }

  /// Deserializes a BKD tree from [input].
  static BkdTree readFrom(IndexInput input) {
    final numDimensions = input.readVInt();
    final maxPointsInLeaf = input.readVInt();
    final totalPoints = input.readVInt();

    final hasRoot = input.readByte() == 1;
    if (!hasRoot) {
      return BkdTree(
        numDimensions: numDimensions,
        maxPointsInLeaf: maxPointsInLeaf,
        root: null,
        totalPoints: totalPoints,
      );
    }

    final root = _deserializeNode(input, numDimensions);
    return BkdTree(
      numDimensions: numDimensions,
      maxPointsInLeaf: maxPointsInLeaf,
      root: root,
      totalPoints: totalPoints,
    );
  }

  static BkdNode _deserializeNode(IndexInput input, int numDimensions) {
    final mins = <double>[];
    final maxs = <double>[];
    for (var d = 0; d < numDimensions; d++) {
      mins.add(input.readFloat64());
      maxs.add(input.readFloat64());
    }
    final bounds = BkdBox(mins, maxs);

    final isInternal = input.readByte() == 1;
    if (isInternal) {
      final splitDim = input.readVInt();
      final splitValue = input.readFloat64();
      final left = _deserializeNode(input, numDimensions);
      final right = _deserializeNode(input, numDimensions);
      return BkdInternalNode(
        bounds: bounds,
        count: left.count + right.count,
        splitDim: splitDim,
        splitValue: splitValue,
        left: left,
        right: right,
      );
    } else {
      final count = input.readVInt();
      final points = <BkdPoint>[];
      for (var i = 0; i < count; i++) {
        final docId = input.readVInt();
        final vals = <double>[];
        for (var d = 0; d < numDimensions; d++) {
          vals.add(input.readFloat64());
        }
        points.add(BkdPoint(docId, vals));
      }
      return BkdLeafNode(bounds: bounds, points: points);
    }
  }
}

class _DistancePair {
  final BkdPoint point;
  final double distance;
  _DistancePair(this.point, this.distance);
}
