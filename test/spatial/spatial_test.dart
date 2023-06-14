import 'dart:math' as math;
import 'package:corbel/corbel.dart';
import 'package:test/test.dart';

void main() {
  group('Geospatial Core Tests', () {
    test('GeoPoint coordinate validation and geohash round-trip', () {
      final sf = const GeoPoint(37.7749, -122.4194);
      expect(sf.lat, closeTo(37.7749, 1e-4));
      expect(sf.lon, closeTo(-122.4194, 1e-4));

      // Test radian conversions
      expect(sf.latRadians, closeTo(37.7749 * math.pi / 180.0, 1e-6));
      expect(sf.lonRadians, closeTo(-122.4194 * math.pi / 180.0, 1e-6));

      // Geohash encoding and decoding
      final geohash = sf.toGeohash(8);
      expect(geohash.length, equals(8));
      final decoded = GeoPoint.fromGeohash(geohash);
      expect(decoded.lat, closeTo(sf.lat, 0.01));
      expect(decoded.lon, closeTo(sf.lon, 0.01));

      // JSON serialization
      final json = sf.toJson();
      final fromJson = GeoPoint.fromJson(json);
      expect(fromJson, equals(sf));

      // Out of bounds validation
      expect(() => GeoPoint(95.0, 0.0), throwsA(isA<AssertionError>()));
      expect(() => GeoPoint(0.0, -185.0), throwsA(isA<AssertionError>()));
    });

    test('GeoDistance Haversine and Vincenty geodesic distance', () {
      final london = const GeoPoint(51.5074, -0.1278);
      final paris = const GeoPoint(48.8566, 2.3522);

      // Distance London to Paris is approx 343.5 km
      final distHaversine = GeoDistance.haversineMeters(london, paris);
      final distVincenty = GeoDistance.vincentyMeters(london, paris);

      expect(distHaversine / 1000.0, closeTo(343.5, 5.0));
      expect(distVincenty / 1000.0, closeTo(343.5, 5.0));

      // Vincenty should be within 0.5% of Haversine for typical distances
      final relativeDiff = (distVincenty - distHaversine).abs() / distHaversine;
      expect(relativeDiff, lessThan(0.01));

      // Distance unit conversions
      expect(DistanceUnit.kilometers.toMeters(10.0), equals(10000.0));
      expect(DistanceUnit.kilometers.fromMeters(10000.0), equals(10.0));
      expect(DistanceUnit.miles.toMeters(1.0), closeTo(1609.344, 1e-3));
    });

    test('GeoBoundingBox containment and dateline crossing', () {
      final bbox = GeoBoundingBox.fromBounds(
        top: 40.0,
        left: -125.0,
        bottom: 30.0,
        right: -115.0,
      );

      expect(bbox.containsPoint(const GeoPoint(35.0, -120.0)), isTrue);
      expect(bbox.containsPoint(const GeoPoint(25.0, -120.0)), isFalse);
      expect(bbox.containsPoint(const GeoPoint(35.0, -110.0)), isFalse);
      expect(bbox.crossesDateLine, isFalse);

      // Dateline crossing box (e.g. Fiji/Pacific 170 deg E to 170 deg W)
      final pacificBox = GeoBoundingBox.fromBounds(
        top: 10.0,
        left: 170.0,
        bottom: -10.0,
        right: -170.0,
      );
      expect(pacificBox.crossesDateLine, isTrue);
      expect(pacificBox.containsPoint(const GeoPoint(0.0, 175.0)), isTrue);
      expect(pacificBox.containsPoint(const GeoPoint(0.0, -175.0)), isTrue);
      expect(pacificBox.containsPoint(const GeoPoint(0.0, 100.0)), isFalse);
    });

    test('GeoPolygon ray-casting containment with holes', () {
      // Exterior triangle around (0,0), (10,0), (5,10)
      final exterior = [
        const GeoPoint(0.0, 0.0),
        const GeoPoint(0.0, 10.0),
        const GeoPoint(10.0, 5.0),
      ];

      // Interior hole around (2,4) to (4,6)
      final hole = [
        const GeoPoint(2.0, 4.0),
        const GeoPoint(2.0, 6.0),
        const GeoPoint(4.0, 5.0),
      ];

      final polygon = GeoPolygon(exteriorRing: exterior, holes: [hole]);

      // Point inside exterior, outside hole
      expect(polygon.containsPoint(const GeoPoint(1.0, 5.0)), isTrue);

      // Point inside hole should be rejected
      expect(polygon.containsPoint(const GeoPoint(2.5, 5.0)), isFalse);

      // Point outside exterior
      expect(polygon.containsPoint(const GeoPoint(15.0, 15.0)), isFalse);
    });
  });

  group('Block KD-Tree (BKD-Tree) Tests', () {
    test('BKD-Tree multi-dimensional range query and k-NN search', () {
      final points = <BkdPoint>[];
      final random = math.Random(42);

      // Generate 500 2D random spatial points
      for (var i = 0; i < 500; i++) {
        final lat = 30.0 + random.nextDouble() * 20.0; // [30, 50]
        final lon = -120.0 + random.nextDouble() * 40.0; // [-120, -80]
        points.add(BkdPoint(i, [lat, lon]));
      }

      final bkd = BkdTree.build(points, maxPointsInLeaf: 32);
      expect(bkd.totalPoints, equals(500));
      expect(bkd.numDimensions, equals(2));

      // Test Range Query: [35, 45] x [-110, -90]
      final queryBox = BkdBox([35.0, -110.0], [45.0, -90.0]);
      final bkdMatches = bkd.queryRange(queryBox);

      // Brute-force reference scan
      final referenceMatches = <int>[];
      for (final p in points) {
        if (queryBox.containsPoint(p)) {
          referenceMatches.add(p.docId);
        }
      }

      expect(bkdMatches.toSet(), equals(referenceMatches.toSet()));

      // Test k-NN search
      final target = [40.0, -100.0];
      final knnResults = bkd.queryNearest(target, 5);
      expect(knnResults.length, equals(5));

      // Verify results are sorted by distance
      var lastDist = -1.0;
      for (final p in knnResults) {
        final dLat = p[0] - target[0];
        final dLon = p[1] - target[1];
        final dist = math.sqrt(dLat * dLat + dLon * dLon);
        expect(dist, greaterThanOrEqualTo(lastDist));
        lastDist = dist;
      }
    });

    test('BKD-Tree binary serialization and deserialization round-trip', () {
      final dir = RAMDirectory();
      final points = [
        BkdPoint(0, [12.5, 80.2]),
        BkdPoint(1, [-45.1, 170.8]),
        BkdPoint(2, [55.3, -3.1]),
        BkdPoint(3, [0.0, 0.0]),
      ];

      final originalBkd = BkdTree.build(points, maxPointsInLeaf: 2);
      final out = dir.createOutput('test.cbl_bkd');
      originalBkd.writeTo(out);
      out.close();

      final input = dir.openInput('test.cbl_bkd');
      final loadedBkd = BkdTree.readFrom(input);
      input.close();

      expect(loadedBkd.totalPoints, equals(4));
      expect(loadedBkd.numDimensions, equals(2));

      final box = BkdBox([-50.0, -10.0], [60.0, 90.0]);
      expect(loadedBkd.queryRange(box).toSet(), equals(originalBkd.queryRange(box).toSet()));
    });
  });

  group('Live Segment Spatial Queries and Aggregations', () {
    late Directory dir;
    late Schema schema;
    late SegmentReader segmentReader;

    setUp(() {
      dir = RAMDirectory();
      schema = Schema(
        idFieldName: 'id',
        fields: {
          'id': FieldDefinition.string('id'),
          'name': FieldDefinition.text('name'),
          'location': FieldDefinition.geoPoint('location'),
        },
      );

      final writer = SegmentWriter(
        segmentName: '_geo_seg_0',
        schema: schema,
        directory: dir,
      );

      // Doc 0: New York
      writer.addDocument(Document(
        id: 'doc0',
        fields: [
          Field.string('id', 'doc0'),
          Field.text('name', 'Empire State Building New York'),
          Field.geoPoint('location', const GeoPoint(40.7484, -73.9857)),
        ],
      ));

      // Doc 1: Brooklyn (approx 8 km from Empire State)
      writer.addDocument(Document(
        id: 'doc1',
        fields: [
          Field.string('id', 'doc1'),
          Field.text('name', 'Brooklyn Bridge New York'),
          Field.geoPoint('location', const GeoPoint(40.7061, -73.9969)),
        ],
      ));

      // Doc 2: Philadelphia (approx 130 km from Empire State)
      writer.addDocument(Document(
        id: 'doc2',
        fields: [
          Field.string('id', 'doc2'),
          Field.text('name', 'Liberty Bell Philadelphia'),
          Field.geoPoint('location', const GeoPoint(39.9496, -75.1503)),
        ],
      ));

      // Doc 3: San Francisco (approx 4100 km from Empire State)
      writer.addDocument(Document(
        id: 'doc3',
        fields: [
          Field.string('id', 'doc3'),
          Field.text('name', 'Golden Gate Bridge San Francisco'),
          Field.geoPoint('location', const GeoPoint(37.8199, -122.4783)),
        ],
      ));

      final segInfo = writer.flush();
      segmentReader = SegmentReader.open(info: segInfo, directory: dir);
    });

    tearDown(() {
      segmentReader.close();
      dir.close();
    });

    test('GeoDistanceQuery matches within radius and scores by proximity', () {
      final nyCenter = const GeoPoint(40.7484, -73.9857);

      // Search within 15 km: should match Empire State (doc 0) and Brooklyn (doc 1)
      final query15km = GeoDistanceQuery(
        field: 'location',
        origin: nyCenter,
        maxDistanceMeters: 15000.0,
      );

      final searchCtx = const IndexSearchContext(totalDocumentCount: 4);
      final weight = query15km.createWeight(searchCtx);
      final scorer = weight.scorer(segmentReader);

      expect(scorer, isNotNull);
      final matches = <int>[];
      final scores = <double>[];
      while (scorer!.nextDoc() != Scorer.noMoreDocs) {
        matches.add(scorer.docId);
        scores.add(scorer.score());
      }

      expect(matches, equals([0, 1]));
      // Empire State is at origin, so score should be higher than Brooklyn
      expect(scores[0], greaterThan(scores[1]));

      // Search within 200 km: should also match Philadelphia (doc 2)
      final query200km = GeoDistanceQuery(
        field: 'location',
        origin: nyCenter,
        maxDistanceMeters: 200000.0,
      );
      final scorer200 = query200km.createWeight(searchCtx).scorer(segmentReader)!;
      final matches200 = <int>[];
      while (scorer200.nextDoc() != Scorer.noMoreDocs) {
        matches200.add(scorer200.docId);
      }
      expect(matches200, equals([0, 1, 2]));
    });

    test('GeoBoundingBoxQuery filters documents within coordinate box', () {
      // Bounding box covering greater New York area
      final nyBox = GeoBoundingBox.fromBounds(
        top: 40.85,
        left: -74.15,
        bottom: 40.65,
        right: -73.85,
      );

      final query = GeoBoundingBoxQuery(field: 'location', boundingBox: nyBox);
      final searchCtx = const IndexSearchContext(totalDocumentCount: 4);
      final scorer = query.createWeight(searchCtx).scorer(segmentReader)!;

      final matches = <int>[];
      while (scorer.nextDoc() != Scorer.noMoreDocs) {
        matches.add(scorer.docId);
      }

      expect(matches, equals([0, 1]));
    });

    test('GeoDistanceAggregation groups documents into concentric rings', () {
      final nyCenter = const GeoPoint(40.7484, -73.9857);
      final agg = GeoDistanceAggregation(
        name: 'rings_from_ny',
        field: 'location',
        origin: nyCenter,
        unit: DistanceUnit.kilometers,
        ranges: [
          const GeoDistanceRange(key: 'metro', from: 0.0, to: 20.0),
          const GeoDistanceRange(key: 'regional', from: 20.0, to: 200.0),
          const GeoDistanceRange(key: 'cross_country', from: 200.0, to: 5000.0),
        ],
      );

      final collector = agg.newCollector(segmentReader);
      for (var i = 0; i < 4; i++) {
        collector.collect(i);
      }

      final result = collector.buildResult() as GeoDistanceResult;
      final bucketMap = {for (final b in result.buckets) b.key: b.count};

      expect(bucketMap['metro'], equals(2)); // Doc 0 and 1
      expect(bucketMap['regional'], equals(1)); // Doc 2 (Philadelphia)
      expect(bucketMap['cross_country'], equals(1)); // Doc 3 (SF)
    });

    test('GeoHashGridAggregation clusters points by geohash cells', () {
      final agg = const GeoHashGridAggregation(
        name: 'geo_grid',
        field: 'location',
        precision: 4,
        size: 5,
      );

      final collector = agg.newCollector(segmentReader);
      for (var i = 0; i < 4; i++) {
        collector.collect(i);
      }

      final result = collector.buildResult() as GeoHashGridResult;
      expect(result.buckets, isNotEmpty);
      final totalCounts = result.buckets.fold<int>(0, (sum, b) => sum + b.count);
      expect(totalCounts, equals(4));
    });
  });
}
