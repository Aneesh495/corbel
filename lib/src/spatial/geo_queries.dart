import 'dart:typed_data';
import '../index/segment_reader.dart';
import '../query/explanation.dart';
import '../query/query.dart';
import '../query/scorer.dart';
import 'bkd_tree.dart';
import 'geo_distance.dart';
import 'geo_point.dart';
import 'geo_shapes.dart';

/// Calculation method for geodesic distance queries.
enum DistanceCalculation {
  haversine,
  vincenty,
}

/// Matches documents within [maxDistanceMeters] from a central [origin] point.
class GeoDistanceQuery extends Query {
  final String field;
  final GeoPoint origin;
  final double maxDistanceMeters;
  final DistanceCalculation calculation;

  const GeoDistanceQuery({
    required this.field,
    required this.origin,
    required this.maxDistanceMeters,
    this.calculation = DistanceCalculation.haversine,
    super.boost = 1.0,
  });

  @override
  Weight createWeight(IndexSearchContext context, {bool needsScores = true}) {
    return GeoDistanceWeight(
      query: this,
      field: field,
      origin: origin,
      maxDistanceMeters: maxDistanceMeters,
      calculation: calculation,
    );
  }

  @override
  String toString() =>
      'GeoDistanceQuery(field: $field, origin: $origin, radius: ${maxDistanceMeters}m)';
}

/// Weight binding [GeoDistanceQuery] to segment BKD-trees and DocValues.
class GeoDistanceWeight extends Weight {
  final String field;
  final GeoPoint origin;
  final double maxDistanceMeters;
  final DistanceCalculation calculation;

  const GeoDistanceWeight({
    required GeoDistanceQuery query,
    required this.field,
    required this.origin,
    required this.maxDistanceMeters,
    required this.calculation,
  }) : super(query);

  @override
  Scorer? scorer(SegmentReader segmentReader) {
    final circle = GeoCircle(center: origin, radiusMeters: maxDistanceMeters);
    final bbox = circle.toBoundingBox();

    final matchingDocs = <int>[];
    final distances = <int, double>{};

    final bkd = segmentReader.getBkdTree(field);
    if (bkd != null) {
      // 1. Fast pruning via BKD-Tree range query
      final candidates = bkd.queryRange(BkdBox(
        [bbox.bottom, bbox.left],
        [bbox.top, bbox.right],
      ));

      for (final docId in candidates) {
        if (!segmentReader.isLive(docId)) continue;
        final point = _extractPoint(segmentReader, docId);
        if (point == null) continue;

        final dist = _computeDistance(origin, point);
        if (dist <= maxDistanceMeters) {
          matchingDocs.add(docId);
          distances[docId] = dist;
        }
      }
    } else {
      // 2. Fallback scan over binary docvalues or stored fields
      for (var docId = 0; docId < segmentReader.maxDoc; docId++) {
        if (!segmentReader.isLive(docId)) continue;
        final point = _extractPoint(segmentReader, docId);
        if (point == null) continue;

        final dist = _computeDistance(origin, point);
        if (dist <= maxDistanceMeters) {
          matchingDocs.add(docId);
          distances[docId] = dist;
        }
      }
    }

    matchingDocs.sort();
    return _GeoDocScorer(
      docIds: matchingDocs,
      distances: distances,
      maxDistance: maxDistanceMeters,
      boost: query.boost,
    );
  }

  double _computeDistance(GeoPoint p1, GeoPoint p2) {
    return calculation == DistanceCalculation.vincenty
        ? GeoDistance.vincentyMeters(p1, p2)
        : GeoDistance.haversineMeters(p1, p2);
  }

  GeoPoint? _extractPoint(SegmentReader segmentReader, int docId) {
    final bdv = segmentReader.getBinaryDocValues(field);
    if (bdv != null) {
      final bytes = bdv.get(docId);
      if (bytes.length >= 16) {
        final bd = ByteData.sublistView(
          bytes.bytes,
          bytes.offset,
          bytes.offset + 16,
        );
        return GeoPoint(bd.getFloat64(0), bd.getFloat64(8));
      }
    }

    // Try stored fields
    try {
      final docMap = segmentReader.document(docId);
      final raw = docMap[field];
      if (raw is Map) {
        return GeoPoint.fromJson(Map<String, dynamic>.from(raw));
      }
    } catch (_) {}
    return null;
  }

  @override
  Explanation explain(SegmentReader segmentReader, int docId) {
    final point = _extractPoint(segmentReader, docId);
    if (point == null) {
      return Explanation.noMatch('No geo coordinate found for field "$field" in doc $docId');
    }

    final dist = _computeDistance(origin, point);
    if (dist > maxDistanceMeters) {
      return Explanation.noMatch(
          'Distance ${dist.toStringAsFixed(1)}m exceeds radius ${maxDistanceMeters}m');
    }

    final score = query.boost * (1.0 / (1.0 + dist / 1000.0));
    return Explanation.match(
      score,
      'GeoDistanceQuery match: distance ${dist.toStringAsFixed(1)}m from $origin',
    );
  }

  @override
  double cost() => 100.0;
}

/// Matches documents falling within an axis-aligned [GeoBoundingBox].
class GeoBoundingBoxQuery extends Query {
  final String field;
  final GeoBoundingBox boundingBox;

  const GeoBoundingBoxQuery({
    required this.field,
    required this.boundingBox,
    super.boost = 1.0,
  });

  @override
  Weight createWeight(IndexSearchContext context, {bool needsScores = true}) {
    return GeoBoundingBoxWeight(query: this, field: field, boundingBox: boundingBox);
  }

  @override
  String toString() => 'GeoBoundingBoxQuery(field: $field, box: $boundingBox)';
}

/// Weight binding [GeoBoundingBoxQuery] to BKD-tree or DocValues.
class GeoBoundingBoxWeight extends Weight {
  final String field;
  final GeoBoundingBox boundingBox;

  const GeoBoundingBoxWeight({
    required GeoBoundingBoxQuery query,
    required this.field,
    required this.boundingBox,
  }) : super(query);

  @override
  Scorer? scorer(SegmentReader segmentReader) {
    final matchingDocs = <int>[];

    final bkd = segmentReader.getBkdTree(field);
    if (bkd != null) {
      final candidates = bkd.queryRange(BkdBox(
        [boundingBox.bottom, boundingBox.left],
        [boundingBox.top, boundingBox.right],
      ));

      for (final docId in candidates) {
        if (!segmentReader.isLive(docId)) continue;
        matchingDocs.add(docId);
      }
    } else {
      for (var docId = 0; docId < segmentReader.maxDoc; docId++) {
        if (!segmentReader.isLive(docId)) continue;
        final point = _extractPoint(segmentReader, docId);
        if (point != null && boundingBox.containsPoint(point)) {
          matchingDocs.add(docId);
        }
      }
    }

    matchingDocs.sort();
    return _GeoDocScorer(
      docIds: matchingDocs,
      distances: const {},
      maxDistance: 1.0,
      boost: query.boost,
    );
  }

  GeoPoint? _extractPoint(SegmentReader segmentReader, int docId) {
    final bdv = segmentReader.getBinaryDocValues(field);
    if (bdv != null) {
      final bytes = bdv.get(docId);
      if (bytes.length >= 16) {
        final bd = ByteData.sublistView(
          bytes.bytes,
          bytes.offset,
          bytes.offset + 16,
        );
        return GeoPoint(bd.getFloat64(0), bd.getFloat64(8));
      }
    }

    try {
      final docMap = segmentReader.document(docId);
      final raw = docMap[field];
      if (raw is Map) {
        return GeoPoint.fromJson(Map<String, dynamic>.from(raw));
      }
    } catch (_) {}
    return null;
  }

  @override
  Explanation explain(SegmentReader segmentReader, int docId) {
    final point = _extractPoint(segmentReader, docId);
    if (point == null) {
      return Explanation.noMatch('No geo coordinate found in doc $docId');
    }
    if (!boundingBox.containsPoint(point)) {
      return Explanation.noMatch('Point $point outside bounding box $boundingBox');
    }
    return Explanation.match(query.boost, 'GeoBoundingBoxQuery match');
  }

  @override
  double cost() => 100.0;
}

/// Matches documents falling within an arbitrary [GeoPolygon].
class GeoPolygonQuery extends Query {
  final String field;
  final GeoPolygon polygon;

  const GeoPolygonQuery({
    required this.field,
    required this.polygon,
    super.boost = 1.0,
  });

  @override
  Weight createWeight(IndexSearchContext context, {bool needsScores = true}) {
    return GeoPolygonWeight(query: this, field: field, polygon: polygon);
  }

  @override
  String toString() => 'GeoPolygonQuery(field: $field)';
}

/// Weight binding [GeoPolygonQuery] to BKD-tree or DocValues.
class GeoPolygonWeight extends Weight {
  final String field;
  final GeoPolygon polygon;

  const GeoPolygonWeight({
    required GeoPolygonQuery query,
    required this.field,
    required this.polygon,
  }) : super(query);

  @override
  Scorer? scorer(SegmentReader segmentReader) {
    final matchingDocs = <int>[];
    final bbox = polygon.boundingBox;

    final bkd = segmentReader.getBkdTree(field);
    if (bkd != null) {
      final candidates = bkd.queryRange(BkdBox(
        [bbox.bottom, bbox.left],
        [bbox.top, bbox.right],
      ));

      for (final docId in candidates) {
        if (!segmentReader.isLive(docId)) continue;
        final point = _extractPoint(segmentReader, docId);
        if (point != null && polygon.containsPoint(point)) {
          matchingDocs.add(docId);
        }
      }
    } else {
      for (var docId = 0; docId < segmentReader.maxDoc; docId++) {
        if (!segmentReader.isLive(docId)) continue;
        final point = _extractPoint(segmentReader, docId);
        if (point != null && polygon.containsPoint(point)) {
          matchingDocs.add(docId);
        }
      }
    }

    matchingDocs.sort();
    return _GeoDocScorer(
      docIds: matchingDocs,
      distances: const {},
      maxDistance: 1.0,
      boost: query.boost,
    );
  }

  GeoPoint? _extractPoint(SegmentReader segmentReader, int docId) {
    final bdv = segmentReader.getBinaryDocValues(field);
    if (bdv != null) {
      final bytes = bdv.get(docId);
      if (bytes.length >= 16) {
        final bd = ByteData.sublistView(
          bytes.bytes,
          bytes.offset,
          bytes.offset + 16,
        );
        return GeoPoint(bd.getFloat64(0), bd.getFloat64(8));
      }
    }

    try {
      final docMap = segmentReader.document(docId);
      final raw = docMap[field];
      if (raw is Map) {
        return GeoPoint.fromJson(Map<String, dynamic>.from(raw));
      }
    } catch (_) {}
    return null;
  }

  @override
  Explanation explain(SegmentReader segmentReader, int docId) {
    final point = _extractPoint(segmentReader, docId);
    if (point == null) {
      return Explanation.noMatch('No geo coordinate found in doc $docId');
    }
    if (!polygon.containsPoint(point)) {
      return Explanation.noMatch('Point $point outside polygon boundary');
    }
    return Explanation.match(query.boost, 'GeoPolygonQuery match');
  }

  @override
  double cost() => 100.0;
}

class _GeoDocScorer extends Scorer {
  final List<int> docIds;
  final Map<int, double> distances;
  final double maxDistance;
  final double boost;
  int _index = -1;

  _GeoDocScorer({
    required this.docIds,
    required this.distances,
    required this.maxDistance,
    required this.boost,
  });

  @override
  int get docId => (_index >= 0 && _index < docIds.length)
      ? docIds[_index]
      : (_index >= docIds.length ? Scorer.noMoreDocs : -1);

  @override
  int nextDoc() {
    _index++;
    return docId;
  }

  @override
  int advance(int target) {
    while (_index + 1 < docIds.length && docIds[_index + 1] < target) {
      _index++;
    }
    _index++;
    return docId;
  }

  @override
  double score() {
    final id = docId;
    if (distances.containsKey(id)) {
      final dist = distances[id]!;
      // Proximity score decay: closer points receive higher score
      return boost * (1.0 / (1.0 + dist / 1000.0));
    }
    return boost;
  }

  @override
  double cost() => docIds.length.toDouble();
}
