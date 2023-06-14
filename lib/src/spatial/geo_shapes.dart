import 'dart:math' as math;
import 'geo_point.dart';
import 'geo_distance.dart';

/// Represents an axis-aligned geographic bounding box defined by
/// its northwest (top-left) and southeast (bottom-right) corners.
class GeoBoundingBox {
  final GeoPoint topLeft;
  final GeoPoint bottomRight;

  const GeoBoundingBox({
    required this.topLeft,
    required this.bottomRight,
  });

  /// Creates a bounding box from coordinate boundaries.
  factory GeoBoundingBox.fromBounds({
    required double top,
    required double left,
    required double bottom,
    required double right,
  }) {
    return GeoBoundingBox(
      topLeft: GeoPoint(top, left),
      bottomRight: GeoPoint(bottom, right),
    );
  }

  double get top => topLeft.lat;
  double get left => topLeft.lon;
  double get bottom => bottomRight.lat;
  double get right => bottomRight.lon;

  /// Returns true if this bounding box crosses the International Date Line.
  bool get crossesDateLine => left > right;

  /// Tests whether the given point lies inside or on the boundary of this box.
  bool containsPoint(GeoPoint point) {
    if (point.lat > top || point.lat < bottom) {
      return false;
    }

    if (crossesDateLine) {
      return point.lon >= left || point.lon <= right;
    } else {
      return point.lon >= left && point.lon <= right;
    }
  }

  /// Tests whether this bounding box intersects another bounding box.
  bool intersects(GeoBoundingBox other) {
    // Check latitude overlap
    if (bottom > other.top || top < other.bottom) {
      return false;
    }

    // Check longitude overlap considering antimeridian
    if (!crossesDateLine && !other.crossesDateLine) {
      return !(left > other.right || right < other.left);
    }

    // At least one box crosses the dateline: decompose into disjoint intervals
    final intervalsA = crossesDateLine
        ? [
            [left, 180.0],
            [-180.0, right],
          ]
        : [
            [left, right],
          ];

    final intervalsB = other.crossesDateLine
        ? [
            [other.left, 180.0],
            [-180.0, other.right],
          ]
        : [
            [other.left, other.right],
          ];

    for (final a in intervalsA) {
      for (final b in intervalsB) {
        if (!(a[0] > b[1] || a[1] < b[0])) {
          return true;
        }
      }
    }

    return false;
  }

  /// Calculates the center of this bounding box.
  GeoPoint get center {
    final lat = (top + bottom) / 2.0;
    double lon;
    if (crossesDateLine) {
      lon = (left + right + 360.0) / 2.0;
      if (lon > 180.0) lon -= 360.0;
    } else {
      lon = (left + right) / 2.0;
    }
    return GeoPoint(lat, lon);
  }

  Map<String, dynamic> toJson() => {
        'top_left': topLeft.toJson(),
        'bottom_right': bottomRight.toJson(),
      };

  factory GeoBoundingBox.fromJson(Map<String, dynamic> json) => GeoBoundingBox(
        topLeft: GeoPoint.fromJson(json['top_left'] as Map<String, dynamic>),
        bottomRight:
            GeoPoint.fromJson(json['bottom_right'] as Map<String, dynamic>),
      );

  @override
  String toString() => 'GeoBoundingBox(top: $top, left: $left, bottom: $bottom, right: $right)';
}

/// Represents a circular geographic region centered at [center] with [radiusMeters].
class GeoCircle {
  final GeoPoint center;
  final double radiusMeters;

  const GeoCircle({required this.center, required this.radiusMeters});

  /// Tests whether [point] is within this circle using Haversine distance.
  bool containsPoint(GeoPoint point) {
    return GeoDistance.haversineMeters(center, point) <= radiusMeters;
  }

  /// Computes a bounding box enclosing this circle.
  GeoBoundingBox toBoundingBox() {
    final dLat = (radiusMeters / GeoDistance.earthRadiusMeters) * 180.0 / math.pi;
    final top = math.min(90.0, center.lat + dLat);
    final bottom = math.max(-90.0, center.lat - dLat);

    final cosLat = math.cos(center.latRadians);
    double left;
    double right;

    if (cosLat > 1e-6) {
      final dLon = (radiusMeters / (GeoDistance.earthRadiusMeters * cosLat)) *
          180.0 /
          math.pi;
      left = center.lon - dLon;
      right = center.lon + dLon;

      if (left < -180.0) left += 360.0;
      if (right > 180.0) right -= 360.0;
    } else {
      // Near poles, envelope covers full longitude span
      left = -180.0;
      right = 180.0;
    }

    return GeoBoundingBox(
      topLeft: GeoPoint(top, left),
      bottomRight: GeoPoint(bottom, right),
    );
  }
}

/// Represents a geographic polygon consisting of an exterior linear ring
/// and optional interior hole rings.
class GeoPolygon {
  final List<GeoPoint> exteriorRing;
  final List<List<GeoPoint>> holes;
  late final GeoBoundingBox _bbox;

  GeoPolygon({
    required this.exteriorRing,
    this.holes = const [],
  }) : assert(exteriorRing.length >= 3, 'Exterior ring must have at least 3 vertices') {
    _bbox = _calculateBoundingBox(exteriorRing);
  }

  GeoBoundingBox get boundingBox => _bbox;

  static GeoBoundingBox _calculateBoundingBox(List<GeoPoint> points) {
    var minLat = double.infinity;
    var maxLat = -double.infinity;
    var minLon = double.infinity;
    var maxLon = -double.infinity;

    for (final p in points) {
      if (p.lat < minLat) minLat = p.lat;
      if (p.lat > maxLat) maxLat = p.lat;
      if (p.lon < minLon) minLon = p.lon;
      if (p.lon > maxLon) maxLon = p.lon;
    }

    return GeoBoundingBox(
      topLeft: GeoPoint(maxLat, minLon),
      bottomRight: GeoPoint(minLat, maxLon),
    );
  }

  /// Tests whether [point] is inside this polygon using the Jordan curve theorem
  /// (ray-casting algorithm), verifying it is within the exterior ring and outside all holes.
  bool containsPoint(GeoPoint point) {
    // Fast bounding box reject
    if (!_bbox.containsPoint(point)) {
      return false;
    }

    if (!_pointInRing(point, exteriorRing)) {
      return false;
    }

    // Verify point is not inside any hole
    for (final hole in holes) {
      if (_pointInRing(point, hole)) {
        return false;
      }
    }

    return true;
  }

  /// Ray-casting algorithm on a closed or unclosed polygon ring.
  static bool _pointInRing(GeoPoint point, List<GeoPoint> ring) {
    var inside = false;
    final n = ring.length;
    var j = n - 1;

    for (var i = 0; i < n; i++) {
      final pi = ring[i];
      final pj = ring[j];

      final intersect = ((pi.lat > point.lat) != (pj.lat > point.lat)) &&
          (point.lon <
              (pj.lon - pi.lon) * (point.lat - pi.lat) / (pj.lat - pi.lat) +
                  pi.lon);

      if (intersect) {
        inside = !inside;
      }
      j = i;
    }

    return inside;
  }
}
