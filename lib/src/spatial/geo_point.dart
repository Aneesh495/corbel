import 'dart:math' as math;

/// Represents a geographic coordinate pair in decimal degrees.
///
/// Latitude ranges from -90.0 to +90.0 inclusive.
/// Longitude ranges from -180.0 to +180.0 inclusive.
class GeoPoint {
  final double lat;
  final double lon;

  const GeoPoint(this.lat, this.lon)
      : assert(lat >= -90.0 && lat <= 90.0, 'Latitude must be between -90 and 90'),
        assert(lon >= -180.0 && lon <= 180.0, 'Longitude must be between -180 and 180');

  /// Creates a GeoPoint from radians.
  factory GeoPoint.fromRadians(double latRad, double lonRad) {
    return GeoPoint(latRad * 180.0 / math.pi, lonRad * 180.0 / math.pi);
  }

  /// Latitude in radians.
  double get latRadians => lat * math.pi / 180.0;

  /// Longitude in radians.
  double get lonRadians => lon * math.pi / 180.0;

  /// Base32 character set for geohash encoding.
  static const String _base32 = '0123456789bcdefghjkmnpqrstuvwxyz';

  /// Encodes this coordinate into a geohash string of the given [precision].
  String toGeohash([int precision = 12]) {
    final buffer = StringBuffer();
    double minLat = -90.0;
    double maxLat = 90.0;
    double minLon = -180.0;
    double maxLon = 180.0;

    var isEven = true;
    var bit = 0;
    var ch = 0;

    while (buffer.length < precision) {
      if (isEven) {
        final mid = (minLon + maxLon) / 2.0;
        if (lon >= mid) {
          ch |= 1 << (4 - bit);
          minLon = mid;
        } else {
          maxLon = mid;
        }
      } else {
        final mid = (minLat + maxLat) / 2.0;
        if (lat >= mid) {
          ch |= 1 << (4 - bit);
          minLat = mid;
        } else {
          maxLat = mid;
        }
      }

      isEven = !isEven;
      if (bit < 4) {
        bit++;
      } else {
        buffer.write(_base32[ch]);
        bit = 0;
        ch = 0;
      }
    }

    return buffer.toString();
  }

  /// Decodes a geohash string into its center [GeoPoint].
  static GeoPoint fromGeohash(String geohash) {
    final lower = geohash.toLowerCase();
    double minLat = -90.0;
    double maxLat = 90.0;
    double minLon = -180.0;
    double maxLon = 180.0;

    var isEven = true;

    for (var i = 0; i < lower.length; i++) {
      final c = lower[i];
      final cd = _base32.indexOf(c);
      if (cd == -1) {
        throw FormatException('Invalid geohash character: $c');
      }

      for (var mask = 16; mask > 0; mask >>= 1) {
        if (isEven) {
          final mid = (minLon + maxLon) / 2.0;
          if ((cd & mask) != 0) {
            minLon = mid;
          } else {
            maxLon = mid;
          }
        } else {
          final mid = (minLat + maxLat) / 2.0;
          if ((cd & mask) != 0) {
            minLat = mid;
          } else {
            maxLat = mid;
          }
        }
        isEven = !isEven;
      }
    }

    return GeoPoint((minLat + maxLat) / 2.0, (minLon + maxLon) / 2.0);
  }

  Map<String, dynamic> toJson() => {'lat': lat, 'lon': lon};

  factory GeoPoint.fromJson(Map<String, dynamic> json) {
    return GeoPoint(
      (json['lat'] as num).toDouble(),
      (json['lon'] as num).toDouble(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GeoPoint &&
          runtimeType == other.runtimeType &&
          lat == other.lat &&
          lon == other.lon;

  @override
  int get hashCode => Object.hash(lat, lon);

  @override
  String toString() => 'GeoPoint($lat, $lon)';
}
