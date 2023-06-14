import 'dart:typed_data';
import '../aggregation/terms_aggregation.dart';
import '../index/segment_reader.dart';
import 'geo_distance.dart';
import 'geo_point.dart';

/// Range specification for a concentric geo distance bucket.
class GeoDistanceRange {
  final String? key;
  final double? from;
  final double? to;

  const GeoDistanceRange({this.key, this.from, this.to});

  String get effectiveKey {
    if (key != null) return key!;
    final lower = from != null ? from!.toStringAsFixed(1) : '0.0';
    final upper = to != null ? to!.toStringAsFixed(1) : '*';
    return '$lower-$upper';
  }

  bool matches(double distanceMeters) {
    if (from != null && distanceMeters < from!) return false;
    if (to != null && distanceMeters >= to!) return false;
    return true;
  }

  Map<String, dynamic> toJson() => {
        'key': effectiveKey,
        if (from != null) 'from': from,
        if (to != null) 'to': to,
      };
}

/// Bucket recording document count within a geo distance range.
class GeoDistanceBucket {
  final String key;
  final double? from;
  final double? to;
  int count;

  GeoDistanceBucket({
    required this.key,
    this.from,
    this.to,
    required this.count,
  });

  Map<String, dynamic> toJson() => {
        'key': key,
        if (from != null) 'from': from,
        if (to != null) 'to': to,
        'doc_count': count,
      };
}

/// Concentric distance ring aggregation bucketing points relative to an origin.
class GeoDistanceAggregation extends Aggregation {
  final String field;
  final GeoPoint origin;
  final List<GeoDistanceRange> ranges;
  final DistanceUnit unit;

  const GeoDistanceAggregation({
    required super.name,
    required this.field,
    required this.origin,
    required this.ranges,
    this.unit = DistanceUnit.meters,
  });

  @override
  AggregationCollector newCollector(SegmentReader segmentReader) {
    return _GeoDistanceCollector(
      name: name,
      field: field,
      origin: origin,
      ranges: ranges,
      unit: unit,
      segmentReader: segmentReader,
    );
  }
}

class _GeoDistanceCollector extends AggregationCollector {
  final String field;
  final GeoPoint origin;
  final List<GeoDistanceRange> ranges;
  final DistanceUnit unit;
  final SegmentReader segmentReader;
  final List<int> _counts;

  _GeoDistanceCollector({
    required super.name,
    required this.field,
    required this.origin,
    required this.ranges,
    required this.unit,
    required this.segmentReader,
  }) : _counts = List.filled(ranges.length, 0);

  @override
  void collect(int docId) {
    final point = _extractPoint(docId);
    if (point == null) return;

    final distMeters = GeoDistance.haversineMeters(origin, point);
    final distInUnit = unit.fromMeters(distMeters);

    for (var i = 0; i < ranges.length; i++) {
      if (ranges[i].matches(distInUnit)) {
        _counts[i]++;
      }
    }
  }

  GeoPoint? _extractPoint(int docId) {
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
  AggregationResult buildResult() {
    final buckets = <GeoDistanceBucket>[];
    for (var i = 0; i < ranges.length; i++) {
      final r = ranges[i];
      buckets.add(GeoDistanceBucket(
        key: r.effectiveKey,
        from: r.from,
        to: r.to,
        count: _counts[i],
      ));
    }
    return GeoDistanceResult(name: name, buckets: buckets);
  }
}

/// Result of a [GeoDistanceAggregation].
class GeoDistanceResult extends AggregationResult {
  final List<GeoDistanceBucket> buckets;

  const GeoDistanceResult({
    required super.name,
    required this.buckets,
  });

  @override
  AggregationResult mergeWith(AggregationResult other) {
    if (other is! GeoDistanceResult) return this;

    final merged = <String, GeoDistanceBucket>{};
    for (final b in buckets) {
      merged[b.key] = GeoDistanceBucket(
        key: b.key,
        from: b.from,
        to: b.to,
        count: b.count,
      );
    }

    for (final b in other.buckets) {
      if (merged.containsKey(b.key)) {
        merged[b.key]!.count += b.count;
      } else {
        merged[b.key] = GeoDistanceBucket(
          key: b.key,
          from: b.from,
          to: b.to,
          count: b.count,
        );
      }
    }

    return GeoDistanceResult(name: name, buckets: merged.values.toList());
  }

  @override
  Map<String, dynamic> toJson() => {
        'name': name,
        'buckets': buckets.map((b) => b.toJson()).toList(),
      };
}

/// Single bucket for a geohash grid cell.
class GeoHashBucket implements Comparable<GeoHashBucket> {
  final String key;
  int count;

  GeoHashBucket({required this.key, required this.count});

  @override
  int compareTo(GeoHashBucket other) {
    final cmp = count.compareTo(other.count);
    if (cmp != 0) return cmp;
    return other.key.compareTo(key);
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'doc_count': count,
      };
}

/// Aggregates documents into a spatial grid using Geohash cell prefixes.
class GeoHashGridAggregation extends Aggregation {
  final String field;
  final int precision;
  final int size;

  const GeoHashGridAggregation({
    required super.name,
    required this.field,
    this.precision = 5,
    this.size = 10,
  }) : assert(precision >= 1 && precision <= 12, 'Precision must be between 1 and 12');

  @override
  AggregationCollector newCollector(SegmentReader segmentReader) {
    return _GeoHashGridCollector(
      name: name,
      field: field,
      precision: precision,
      size: size,
      segmentReader: segmentReader,
    );
  }
}

class _GeoHashGridCollector extends AggregationCollector {
  final String field;
  final int precision;
  final int size;
  final SegmentReader segmentReader;
  final Map<String, int> _counts = {};

  _GeoHashGridCollector({
    required super.name,
    required this.field,
    required this.precision,
    required this.size,
    required this.segmentReader,
  });

  @override
  void collect(int docId) {
    final point = _extractPoint(docId);
    if (point == null) return;

    final geohash = point.toGeohash(precision);
    _counts[geohash] = (_counts[geohash] ?? 0) + 1;
  }

  GeoPoint? _extractPoint(int docId) {
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
  AggregationResult buildResult() {
    final buckets = _counts.entries
        .map((e) => GeoHashBucket(key: e.key, count: e.value))
        .toList()
      ..sort((a, b) => b.compareTo(a));

    final topK = buckets.take(size).toList();
    return GeoHashGridResult(name: name, buckets: topK);
  }
}

/// Result of a [GeoHashGridAggregation].
class GeoHashGridResult extends AggregationResult {
  final List<GeoHashBucket> buckets;

  const GeoHashGridResult({
    required super.name,
    required this.buckets,
  });

  @override
  AggregationResult mergeWith(AggregationResult other) {
    if (other is! GeoHashGridResult) return this;

    final merged = <String, int>{};
    for (final b in buckets) {
      merged[b.key] = (merged[b.key] ?? 0) + b.count;
    }
    for (final b in other.buckets) {
      merged[b.key] = (merged[b.key] ?? 0) + b.count;
    }

    final sorted = merged.entries
        .map((e) => GeoHashBucket(key: e.key, count: e.value))
        .toList()
      ..sort((a, b) => b.compareTo(a));

    return GeoHashGridResult(name: name, buckets: sorted);
  }

  @override
  Map<String, dynamic> toJson() => {
        'name': name,
        'buckets': buckets.map((b) => b.toJson()).toList(),
      };
}
