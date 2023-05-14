import 'package:test/test.dart';

import 'package:corbel/src/aggregation/date_histogram.dart';
import 'package:corbel/src/aggregation/range_aggregation.dart';
import 'package:corbel/src/aggregation/stats_aggregation.dart';
import 'package:corbel/src/aggregation/t_digest.dart';
import 'package:corbel/src/aggregation/terms_aggregation.dart';
import 'package:corbel/src/core/document.dart';
import 'package:corbel/src/core/schema.dart';
import 'package:corbel/src/index/segment_reader.dart';
import 'package:corbel/src/index/segment_writer.dart';
import 'package:corbel/src/storage/directory.dart';

void main() {
  group('Live Segment Columnar Aggregations', () {
    late RAMDirectory dir;
    late Schema schema;
    late SegmentReader reader;

    setUp(() {
      dir = RAMDirectory();
      schema = Schema(
        fields: {
          'category': FieldDefinition.string('category', docValues: true),
          'price': FieldDefinition.int64('price', docValues: true),
          'created_at': FieldDefinition.int64('created_at', docValues: true),
        },
      );

      final writer = SegmentWriter(
        segmentName: '_agg_seg_0',
        schema: schema,
        directory: dir,
      );

      // Doc 0
      writer.addDocument(Document.fromMap('d0', {
        'category': 'electronics',
        'price': 100,
        'created_at': 1609459200000, // 2021-01-01T00:00:00Z
      }));

      // Doc 1
      writer.addDocument(Document.fromMap('d1', {
        'category': 'electronics',
        'price': 200,
        'created_at': 1609545600000, // 2021-01-02T00:00:00Z
      }));

      // Doc 2
      writer.addDocument(Document.fromMap('d2', {
        'category': 'books',
        'price': 50,
        'created_at': 1609632000000, // 2021-01-03T00:00:00Z
      }));

      // Doc 3
      writer.addDocument(Document.fromMap('d3', {
        'category': 'clothing',
        'price': 150,
        'created_at': 1609718400000, // 2021-01-04T00:00:00Z
      }));

      // Doc 4
      writer.addDocument(Document.fromMap('d4', {
        'category': 'electronics',
        'price': 300,
        'created_at': 1609804800000, // 2021-01-05T00:00:00Z
      }));

      final info = writer.flush();
      reader = SegmentReader.open(info: info, directory: dir);
    });

    tearDown(() {
      reader.close();
    });

    test('TermsAggregation groups by categories and returns top-k buckets', () {
      final termsAgg = const TermsAggregation(
        name: 'top_categories',
        field: 'category',
        size: 2,
      );

      final collector = termsAgg.newCollector(reader);
      for (var docId = 0; docId < reader.maxDoc; docId++) {
        collector.collect(docId);
      }

      final result = collector.buildResult() as TermsAggregationResult;
      final buckets = result.buckets;

      // electronics: 3, books: 1, clothing: 1. With size 2, electronics must be first.
      expect(buckets.length, equals(2));
      expect(buckets[0].key, equals('electronics'));
      expect(buckets[0].count, equals(3));

      final json = result.toJson();
      expect(json['buckets'], hasLength(2));
      expect(json['sum_other_doc_count'], equals(1));
    });

    test('RangeAggregation buckets prices into numeric intervals', () {
      final rangeAgg = const RangeAggregation(
        name: 'price_ranges',
        field: 'price',
        ranges: [
          RangeBucketSpec(key: 'cheap', to: 100),
          RangeBucketSpec(key: 'medium', from: 100, to: 250),
          RangeBucketSpec(key: 'expensive', from: 250),
        ],
      );

      final collector = rangeAgg.newCollector(reader);
      for (var docId = 0; docId < reader.maxDoc; docId++) {
        collector.collect(docId);
      }

      final result = collector.buildResult() as RangeAggregationResult;
      final json = result.toJson();
      final buckets = json['buckets'] as List;

      // cheap (< 100): doc 2 (50) -> 1
      // medium [100, 250): doc 0 (100), doc 1 (200), doc 3 (150) -> 3
      // expensive (>= 250): doc 4 (300) -> 1
      expect(buckets[0]['doc_count'], equals(1));
      expect(buckets[1]['doc_count'], equals(3));
      expect(buckets[2]['doc_count'], equals(1));
    });

    test('DateHistogramAggregation buckets timestamps by day intervals', () {
      final dateAgg = const DateHistogramAggregation(
        name: 'daily_orders',
        field: 'created_at',
        interval: Duration(days: 1),
      );

      final collector = dateAgg.newCollector(reader);
      for (var docId = 0; docId < reader.maxDoc; docId++) {
        collector.collect(docId);
      }

      final result = collector.buildResult() as DateHistogramResult;
      final json = result.toJson();
      final buckets = json['buckets'] as List;

      // 5 distinct days
      expect(buckets.length, equals(5));
      for (final b in buckets) {
        expect(b['doc_count'], equals(1));
      }
    });

    test('StatsAggregation calculates count, min, max, avg, and variance', () {
      final statsAgg = const StatsAggregation(
        name: 'price_stats',
        field: 'price',
      );

      final collector = statsAgg.newCollector(reader);
      for (var docId = 0; docId < reader.maxDoc; docId++) {
        collector.collect(docId);
      }

      final result = collector.buildResult() as StatsAggregationResult;

      // Prices: 100, 200, 50, 150, 300
      // Sum = 800, Count = 5, Avg = 160, Min = 50, Max = 300
      expect(result.count, equals(5));
      expect(result.min, equals(50.0));
      expect(result.max, equals(300.0));
      expect(result.sum, equals(800.0));
      expect(result.avg, equals(160.0));
      expect(result.variance, greaterThan(0.0));
    });
  });

  group('TDigest Streaming Percentiles Sketch Tests', () {
    test('accurately estimates percentiles across uniform distribution', () {
      final td = TDigest(delta: 100.0);
      for (var i = 1; i <= 1000; i++) {
        td.add(i.toDouble());
      }

      expect(td.min, equals(1.0));
      expect(td.max, equals(1000.0));

      final p50 = td.quantile(0.5);
      final p90 = td.quantile(0.9);
      final p99 = td.quantile(0.99);

      // In [1..1000], median is ~500, p90 is ~900, p99 is ~990
      expect(p50, closeTo(500.0, 20.0));
      expect(p90, closeTo(900.0, 20.0));
      expect(p99, closeTo(990.0, 15.0));
    });

    test('merging two independent TDigests maintains quantile accuracy', () {
      final td1 = TDigest(delta: 100.0);
      final td2 = TDigest(delta: 100.0);

      for (var i = 1; i <= 500; i++) {
        td1.add(i.toDouble());
      }
      for (var i = 501; i <= 1000; i++) {
        td2.add(i.toDouble());
      }

      td1.merge(td2);
      expect(td1.totalWeight, equals(1000.0));
      expect(td1.quantile(0.5), closeTo(500.0, 25.0));
    });
  });
}
