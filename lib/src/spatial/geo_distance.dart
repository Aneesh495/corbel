import 'dart:math' as math;
import 'geo_point.dart';

/// Supported distance units for geospatial radius and filtering.
enum DistanceUnit {
  meters(1.0),
  kilometers(1000.0),
  miles(1609.344),
  nauticalMiles(1852.0),
  feet(0.3048);

  final double toMetersFactor;
  const DistanceUnit(this.toMetersFactor);

  /// Converts a value in this unit to meters.
  double toMeters(double value) => value * toMetersFactor;

  /// Converts a value in meters to this unit.
  double fromMeters(double meters) => meters / toMetersFactor;
}

/// Geodesic distance calculation algorithms over Earth geometries.
class GeoDistance {
  /// Mean Earth radius in meters according to IUGG (WGS-84).
  static const double earthRadiusMeters = 6371008.8;

  /// WGS-84 equatorial semi-major axis in meters.
  static const double wgs84A = 6378137.0;

  /// WGS-84 polar semi-minor axis in meters.
  static const double wgs84B = 6356752.314245;

  /// WGS-84 flattening ratio f = (a - b) / a.
  static const double wgs84F = 1.0 / 298.257223563;

  /// Computes the great-circle distance in meters between two coordinates
  /// using the Haversine formula.
  static double haversineMeters(GeoPoint p1, GeoPoint p2) {
    final dLat = (p2.lat - p1.lat) * math.pi / 180.0;
    final dLon = (p2.lon - p1.lon) * math.pi / 180.0;

    final lat1 = p1.latRadians;
    final lat2 = p2.latRadians;

    final sinDLat = math.sin(dLat / 2.0);
    final sinDLon = math.sin(dLon / 2.0);

    final a = sinDLat * sinDLat +
        sinDLon * sinDLon * math.cos(lat1) * math.cos(lat2);

    final c = 2.0 * math.atan2(math.sqrt(a), math.sqrt(math.max(0.0, 1.0 - a)));
    return earthRadiusMeters * c;
  }

  /// Computes geodesic distance in meters using Vincenty's inverse formula
  /// on the WGS-84 ellipsoid. Falls back to Haversine if antipodal or non-convergent.
  static double vincentyMeters(GeoPoint p1, GeoPoint p2, {int maxIterations = 100}) {
    if (p1 == p2) return 0.0;

    final phi1 = p1.latRadians;
    final lambda1 = p1.lonRadians;
    final phi2 = p2.latRadians;
    final lambda2 = p2.lonRadians;

    final u1 = math.atan((1.0 - wgs84F) * math.tan(phi1));
    final u2 = math.atan((1.0 - wgs84F) * math.tan(phi2));
    final sinU1 = math.sin(u1);
    final cosU1 = math.cos(u1);
    final sinU2 = math.sin(u2);
    final cosU2 = math.cos(u2);

    var lambda = lambda2 - lambda1;
    var lambdaPrev = 0.0;
    var iter = 0;

    double sinSigma = 0.0;
    double cosSigma = 0.0;
    double sigma = 0.0;
    double sinAlpha = 0.0;
    double cos2Alpha = 0.0;
    double cos2SigmaM = 0.0;

    do {
      final sinLambda = math.sin(lambda);
      final cosLambda = math.cos(lambda);

      sinSigma = math.sqrt(
        (cosU2 * sinLambda) * (cosU2 * sinLambda) +
            (cosU1 * sinU2 - sinU1 * cosU2 * cosLambda) *
                (cosU1 * sinU2 - sinU1 * cosU2 * cosLambda),
      );

      if (sinSigma == 0.0) return 0.0; // Coincident points

      cosSigma = sinU1 * sinU2 + cosU1 * cosU2 * cosLambda;
      sigma = math.atan2(sinSigma, cosSigma);

      sinAlpha = cosU1 * cosU2 * sinLambda / sinSigma;
      cos2Alpha = 1.0 - sinAlpha * sinAlpha;

      cos2SigmaM = (cos2Alpha == 0.0)
          ? 0.0
          : cosSigma - 2.0 * sinU1 * sinU2 / cos2Alpha;

      final c = wgs84F / 16.0 * cos2Alpha * (4.0 + wgs84F * (4.0 - 3.0 * cos2Alpha));
      lambdaPrev = lambda;
      lambda = (lambda2 - lambda1) +
          (1.0 - c) *
              wgs84F *
              sinAlpha *
              (sigma +
                  c *
                      sinSigma *
                      (cos2SigmaM +
                          c *
                              cosSigma *
                              (-1.0 + 2.0 * cos2SigmaM * cos2SigmaM)));

      iter++;
    } while ((lambda - lambdaPrev).abs() > 1e-12 && iter < maxIterations);

    // Fall back to Haversine if Vincenty does not converge (e.g. nearly antipodal points)
    if (iter >= maxIterations) {
      return haversineMeters(p1, p2);
    }

    final uSq = cos2Alpha * (wgs84A * wgs84A - wgs84B * wgs84B) / (wgs84B * wgs84B);
    final aCoeff = 1.0 +
        uSq / 16384.0 * (4096.0 + uSq * (-768.0 + uSq * (320.0 - 175.0 * uSq)));
    final bCoeff =
        uSq / 1024.0 * (256.0 + uSq * (-128.0 + uSq * (74.0 - 47.0 * uSq)));
    final deltaSigma = bCoeff *
        sinSigma *
        (cos2SigmaM +
            bCoeff /
                4.0 *
                (cosSigma * (-1.0 + 2.0 * cos2SigmaM * cos2SigmaM) -
                    bCoeff /
                        6.0 *
                        cos2SigmaM *
                        (-3.0 + 4.0 * sinSigma * sinSigma) *
                        (-3.0 + 4.0 * cos2SigmaM * cos2SigmaM)));

    return wgs84B * aCoeff * (sigma - deltaSigma);
  }
}
