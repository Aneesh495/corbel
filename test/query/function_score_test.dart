import 'dart:math' as math;
import 'dart:typed_data';
import 'package:corbel/corbel.dart';
import 'package:test/test.dart';

void main() {
  group('Score Functions', () {
    late RAMDirectory dir;
    late Schema schema;
    late SegmentReader reader;

    setUp(() {
      dir = RAMDirectory();
      schema = Schema(
        fields: {
          'views': FieldDefinition.int64('views', docValues: true),
          'timestamp': FieldDefinition.int64('timestamp', docValues: true),
        },
      );
      final writer = SegmentWriter(
        segmentName: '_fn_seg',
        schema: schema,
        directory: dir,
      );
      writer.addDocument(Document.fromMap('doc_0', {
        'views': 100,
        'timestamp': 1000,
      }));
      final info = writer.flush();
      reader = SegmentReader.open(info: info, directory: dir);
    });

    tearDown(() {
      reader.close();
    });

    test('FieldValueFactorFunction calculates modifiers correctly', () {
      // None modifier: factor 2.0 -> 100 * 2.0 = 200.0
      final fnNone = FieldValueFactorFunction(field: 'views', factor: 2.0);
      expect(fnNone.score(reader, 0, 1.0), equals(200.0));

      // Log1p modifier: log10(100 * 1.0 + 1.0) = log10(101) ~ 2.00432
      final fnLog1p = FieldValueFactorFunction(
        field: 'views',
        modifier: Modifier.log1p,
      );
      expect(
        fnLog1p.score(reader, 0, 1.0),
        closeTo(math.log(101.0) / math.ln10, 1e-4),
      );

      // Sqrt modifier: sqrt(100) = 10.0
      final fnSqrt = FieldValueFactorFunction(
        field: 'views',
        modifier: Modifier.sqrt,
      );
      expect(fnSqrt.score(reader, 0, 1.0), equals(10.0));

      // Missing field fallback
      final fnMissing = FieldValueFactorFunction(
        field: 'unknown',
        missing: 5.0,
        factor: 3.0,
      );
      expect(fnMissing.score(reader, 0, 1.0), equals(15.0));
    });

    test('DecayFunction calculates Gauss, Exponential, and Linear decay curves', () {
      // At origin, decay score must be exactly 1.0
      final fnGaussOrigin = DecayFunction(
        field: 'timestamp',
        origin: 1000.0,
        scale: 100.0,
        decay: 0.5,
        decayType: DecayType.gauss,
      );
      expect(fnGaussOrigin.score(reader, 0, 1.0), equals(1.0));

      // At distance = scale, decay score must be exactly equal to decay parameter (0.5)
      final fnGaussScale = DecayFunction(
        field: 'timestamp',
        origin: 900.0, // distance = 1000 - 900 = 100 = scale
        scale: 100.0,
        decay: 0.5,
        decayType: DecayType.gauss,
      );
      expect(fnGaussScale.score(reader, 0, 1.0), closeTo(0.5, 1e-4));

      final fnExpScale = DecayFunction(
        field: 'timestamp',
        origin: 900.0,
        scale: 100.0,
        decay: 0.5,
        decayType: DecayType.exponential,
      );
      expect(fnExpScale.score(reader, 0, 1.0), closeTo(0.5, 1e-4));

      final fnLinearScale = DecayFunction(
        field: 'timestamp',
        origin: 900.0,
        scale: 100.0,
        decay: 0.5,
        decayType: DecayType.linear,
      );
      expect(fnLinearScale.score(reader, 0, 1.0), closeTo(0.5, 1e-4));
    });
  });

  group('FunctionScoreQuery Live Segment Tests', () {
    late RAMDirectory dir;
    late Schema schema;
    late SegmentReader reader;
    late IndexSearchContext searchContext;

    setUp(() {
      dir = RAMDirectory();
      schema = Schema(
        fields: {
          'title': FieldDefinition.text('title'),
          'popularity': FieldDefinition.int64('popularity', docValues: true),
        },
      );
      final writer = SegmentWriter(
        segmentName: '_fsq_seg',
        schema: schema,
        directory: dir,
      );
      writer.addDocument(Document.fromMap('d1', {
        'title': 'neural networks deep learning',
        'popularity': 10,
      }));
      writer.addDocument(Document.fromMap('d2', {
        'title': 'deep learning optimization',
        'popularity': 100,
      }));
      final info = writer.flush();
      reader = SegmentReader.open(info: info, directory: dir);
      searchContext = const IndexSearchContext(
        totalDocumentCount: 2,
        fieldDocCounts: {'title': 2, 'popularity': 2},
      );
    });

    tearDown(() {
      reader.close();
    });

    test('BoostMode.multiply scales base relevance score', () {
      final baseQuery = const TermQuery(field: 'title', term: 'neural');
      final fnQuery = FunctionScoreQuery(
        query: baseQuery,
        functions: [
          FieldValueFactorFunction(field: 'popularity', factor: 0.1),
        ],
        boostMode: BoostMode.multiply,
      );

      final weight = fnQuery.createWeight(searchContext);
      final scorer = weight.scorer(reader);
      expect(scorer, isNotNull);

      expect(scorer!.nextDoc(), equals(0));
      expect(scorer.score(), greaterThan(0.0));
      expect(scorer.nextDoc(), equals(Scorer.noMoreDocs));
    });

    test('minScore prunes low-scoring matches', () {
      final baseQuery = const TermQuery(field: 'title', term: 'deep');

      // Both d1 and d2 match 'deep'.
      // Set high minScore threshold to prune d1 (pop 10) while retaining d2 (pop 100)
      final fnQuery = FunctionScoreQuery(
        query: baseQuery,
        functions: [
          FieldValueFactorFunction(field: 'popularity', factor: 1.0),
        ],
        boostMode: BoostMode.replace, // Score becomes exactly popularity
        minScore: 50.0,
      );

      final weight = fnQuery.createWeight(searchContext);
      final scorer = weight.scorer(reader);
      expect(scorer, isNotNull);

      // doc 0 (d1 with pop 10) should be skipped/pruned, doc 1 (d2 with pop 100) matches
      expect(scorer!.nextDoc(), equals(1));
      expect(scorer.score(), equals(100.0));
      expect(scorer.nextDoc(), equals(Scorer.noMoreDocs));
    });

    test('maxBoost clamps function multiplier', () {
      final baseQuery = const TermQuery(field: 'title', term: 'deep');

      final fnQuery = FunctionScoreQuery(
        query: baseQuery,
        functions: [
          FieldValueFactorFunction(field: 'popularity', factor: 1.0),
        ],
        scoreMode: ScoreMode.first,
        boostMode: BoostMode.replace,
        maxBoost: 25.0, // Should clamp d2's score of 100 down to 25
      );

      final weight = fnQuery.createWeight(searchContext);
      final scorer = weight.scorer(reader);
      expect(scorer, isNotNull);

      expect(scorer!.nextDoc(), equals(0));
      expect(scorer.score(), equals(10.0)); // 10 < 25, unchanged

      expect(scorer.nextDoc(), equals(1));
      expect(scorer.score(), equals(25.0)); // 100 clamped to 25
      expect(scorer.nextDoc(), equals(Scorer.noMoreDocs));
    });
  });

  group('Learning to Rank (LTR) Models', () {
    test('LinearLtrModel predicts and serializes cleanly', () {
      final model = const LinearLtrModel(
        weights: [0.5, 2.0, -1.0],
        bias: 0.1,
      );

      final features = FeatureVector(
        docId: 42,
        values: Float64List.fromList([1.0, 3.0, 2.0]),
        featureNames: ['bm25', 'recency', 'spam_score'],
      );

      // Score = 0.1 + (0.5 * 1.0) + (2.0 * 3.0) + (-1.0 * 2.0) = 0.1 + 0.5 + 6.0 - 2.0 = 4.6
      expect(model.predict(features), closeTo(4.6, 1e-5));

      final json = model.toJson();
      final restored = LinearLtrModel.fromJson(json);
      expect(restored.predict(features), closeTo(4.6, 1e-5));
    });

    test('GbdtModel evaluates decision tree splits and serializes', () {
      // Tree 1: if feature 0 <= 0.5 -> leaf 1.0, else leaf 5.0
      final tree1 = const TreeNode.split(
        featureIndex: 0,
        threshold: 0.5,
        left: TreeNode.leaf(1.0),
        right: TreeNode.leaf(5.0),
      );

      // Tree 2: if feature 1 <= 10.0 -> leaf -0.5, else leaf 2.0
      final tree2 = const TreeNode.split(
        featureIndex: 1,
        threshold: 10.0,
        left: TreeNode.leaf(-0.5),
        right: TreeNode.leaf(2.0),
      );

      final model = GbdtModel(
        trees: [tree1, tree2],
        learningRate: 0.1,
        baseScore: 1.0,
      );

      final featA = FeatureVector(
        docId: 1,
        values: Float64List.fromList([0.2, 5.0]),
        featureNames: ['bm25', 'clicks'],
      );
      // featA: tree1 -> 1.0; tree2 -> -0.5
      // Total = 1.0 + 0.1 * (1.0 - 0.5) = 1.05
      expect(model.predict(featA), closeTo(1.05, 1e-5));

      final featB = FeatureVector(
        docId: 2,
        values: Float64List.fromList([0.8, 15.0]),
        featureNames: ['bm25', 'clicks'],
      );
      // featB: tree1 -> 5.0; tree2 -> 2.0
      // Total = 1.0 + 0.1 * (5.0 + 2.0) = 1.70
      expect(model.predict(featB), closeTo(1.70, 1e-5));

      final serialized = model.serialize();
      final deserialized = GbdtModel.deserialize(serialized);
      expect(deserialized.predict(featA), closeTo(1.05, 1e-5));
      expect(deserialized.predict(featB), closeTo(1.70, 1e-5));
    });

    test('LtrReranker inverts ordering of retrieved candidates based on learned features', () {
      final candidates = [
        const ScoreDoc(docId: 10, score: 9.5, segmentIndex: 0, id: 'doc_10'), // Originally ranked #1
        const ScoreDoc(docId: 20, score: 8.0, segmentIndex: 0, id: 'doc_20'), // Originally ranked #2
      ];

      // Give doc 20 high quality signal and doc 10 low quality signal
      final feat10 = FeatureVector(
        docId: 10,
        values: Float64List.fromList([9.5, 0.1]),
        featureNames: ['bm25', 'quality'],
      );
      final feat20 = FeatureVector(
        docId: 20,
        values: Float64List.fromList([8.0, 5.0]),
        featureNames: ['bm25', 'quality'],
      );

      final model = const LinearLtrModel(
        weights: [0.1, 2.0], // Heavily weights quality feature
        bias: 0.0,
      );

      final reranker = LtrReranker(
        model: model,
        featureNames: ['bm25', 'quality'],
      );

      final reranked = reranker.rerank(candidates, [feat10, feat20]);

      // Doc 10 score: 0.1 * 9.5 + 2.0 * 0.1 = 0.95 + 0.2 = 1.15
      // Doc 20 score: 0.1 * 8.0 + 2.0 * 5.0 = 0.80 + 10.0 = 10.80
      // Doc 20 should now be ranked #1
      expect(reranked.length, equals(2));
      expect(reranked.first.originalDoc.docId, equals(20));
      expect(reranked.first.rerankScore, closeTo(10.80, 1e-4));
      expect(reranked.last.originalDoc.docId, equals(10));
      expect(reranked.last.rerankScore, closeTo(1.15, 1e-4));
    });
  });
}
