import 'dart:typed_data';
import 'package:test/test.dart';

import 'package:corbel/src/analysis/analyzer.dart';
import 'package:corbel/src/core/document.dart';
import 'package:corbel/src/core/schema.dart';
import 'package:corbel/src/index/segment_reader.dart';
import 'package:corbel/src/index/segment_writer.dart';
import 'package:corbel/src/query/boolean_query.dart';
import 'package:corbel/src/query/dismax_query.dart';
import 'package:corbel/src/query/fuzzy_query.dart';
import 'package:corbel/src/query/highlighter.dart';
import 'package:corbel/src/query/hybrid_query.dart';
import 'package:corbel/src/query/knn_vector_query.dart';
import 'package:corbel/src/query/optimizer.dart';
import 'package:corbel/src/query/phrase_query.dart';
import 'package:corbel/src/query/prefix_query.dart';
import 'package:corbel/src/query/query.dart';
import 'package:corbel/src/query/query_parser.dart';
import 'package:corbel/src/query/range_query.dart';
import 'package:corbel/src/query/scorer.dart';
import 'package:corbel/src/query/similarity.dart';
import 'package:corbel/src/query/term_query.dart';
import 'package:corbel/src/query/wand_scorer.dart';
import 'package:corbel/src/query/wildcard_query.dart';
import 'package:corbel/src/storage/directory.dart';

void main() {
  group('Query Engine Live Segment Tests', () {
    late RAMDirectory dir;
    late Schema schema;
    late SegmentReader reader;
    late IndexSearchContext searchContext;

    setUp(() {
      dir = RAMDirectory();
      schema = Schema(
        fields: {
          'title': FieldDefinition.text('title'),
          'body': FieldDefinition.text('body'),
          'tag': FieldDefinition.string('tag', docValues: true),
          'price': FieldDefinition.int64('price', docValues: true),
          'embedding': FieldDefinition.vector('embedding', dimension: 4, metric: VectorDistanceMetric.cosine),
        },
      );

      final writer = SegmentWriter(
        segmentName: '_query_seg_0',
        schema: schema,
        directory: dir,
      );

      // Doc 0
      writer.addDocument(Document.fromMap('doc_0', {
        'title': 'The quick brown fox',
        'body': 'Fox jumps over the lazy dog in the forest',
        'tag': 'wildlife',
        'price': 100,
        'embedding': Float32List.fromList([1.0, 0.0, 0.0, 0.0]),
      }));

      // Doc 1
      writer.addDocument(Document.fromMap('doc_1', {
        'title': 'Quick brown rabbit',
        'body': 'Rabbit hops quickly across the forest path',
        'tag': 'wildlife',
        'price': 150,
        'embedding': Float32List.fromList([0.9, 0.1, 0.0, 0.0]),
      }));

      // Doc 2
      writer.addDocument(Document.fromMap('doc_2', {
        'title': 'Lazy domestic dog',
        'body': 'Domestic dog rests comfortably on the porch',
        'tag': 'pets',
        'price': 200,
        'embedding': Float32List.fromList([0.0, 0.0, 1.0, 0.0]),
      }));

      // Doc 3
      writer.addDocument(Document.fromMap('doc_3', {
        'title': 'Database indexing engine',
        'body': 'Corbel is a fast embedded search engine with vector support',
        'tag': 'database',
        'price': 300,
        'embedding': Float32List.fromList([0.0, 0.0, 0.0, 1.0]),
      }));

      final info = writer.flush();
      reader = SegmentReader.open(info: info, directory: dir);
      searchContext = const IndexSearchContext(
        totalDocumentCount: 4,
        fieldDocCounts: {'title': 4, 'body': 4, 'tag': 4, 'price': 4},
      );
    });

    tearDown(() {
      reader.close();
    });

    test('TermQuery retrieves matching documents and scores them', () {
      final query = const TermQuery(field: 'title', term: 'quick');
      final weight = query.createWeight(searchContext);
      final scorer = weight.scorer(reader);

      expect(scorer, isNotNull);
      final matchedDocs = <int>[];
      var d = scorer!.nextDoc();
      while (d != Scorer.noMoreDocs) {
        matchedDocs.add(d);
        expect(scorer.score(), greaterThan(0.0));
        d = scorer.nextDoc();
      }

      // 'quick' appears in doc 0 ('The quick brown fox') and doc 1 ('Quick brown rabbit')
      expect(matchedDocs, equals([0, 1]));

      // Verify explain tree
      final exp = query.explain(reader, searchContext, 0);
      expect(exp.isMatch, isTrue);
      expect(exp.value, greaterThan(0.0));
    });

    test('BooleanQuery MUST, SHOULD, and MUST_NOT coordination', () {
      // Query: +title:quick -tag:pets
      final bq = const BooleanQuery(
        clauses: [
          BooleanClause(
            query: TermQuery(field: 'title', term: 'quick'),
            occur: Occur.must,
          ),
          BooleanClause(
            query: TermQuery(field: 'tag', term: 'pets'),
            occur: Occur.mustNot,
          ),
        ],
      );

      final weight = bq.createWeight(searchContext);
      final scorer = weight.scorer(reader);
      expect(scorer, isNotNull);

      final matched = <int>[];
      var d = scorer!.nextDoc();
      while (d != Scorer.noMoreDocs) {
        matched.add(d);
        d = scorer.nextDoc();
      }

      expect(matched, equals([0, 1]));
    });

    test('BooleanQuery SHOULD disjunction with minimumNumberShouldMatch', () {
      // Query: title:quick OR title:rabbit OR title:dog with minShouldMatch=2
      final bq = const BooleanQuery(
        clauses: [
          BooleanClause(
            query: TermQuery(field: 'title', term: 'quick'),
            occur: Occur.should,
          ),
          BooleanClause(
            query: TermQuery(field: 'title', term: 'rabbit'),
            occur: Occur.should,
          ),
          BooleanClause(
            query: TermQuery(field: 'title', term: 'dog'),
            occur: Occur.should,
          ),
        ],
        minimumNumberShouldMatch: 2,
      );

      final weight = bq.createWeight(searchContext);
      final scorer = weight.scorer(reader);
      expect(scorer, isNotNull);

      final matched = <int>[];
      var d = scorer!.nextDoc();
      while (d != Scorer.noMoreDocs) {
        matched.add(d);
        d = scorer.nextDoc();
      }

      // Doc 1 has both 'quick' and 'rabbit' in title
      expect(matched, equals([1]));
    });

    test('PhraseQuery exact matches consecutive terms', () {
      final pq = const PhraseQuery(
        field: 'title',
        terms: ['quick', 'brown'],
        slop: 0,
      );

      final weight = pq.createWeight(searchContext);
      final scorer = weight.scorer(reader);
      expect(scorer, isNotNull);

      final matched = <int>[];
      var d = scorer!.nextDoc();
      while (d != Scorer.noMoreDocs) {
        matched.add(d);
        d = scorer.nextDoc();
      }

      // 'quick brown' is in doc 0 and doc 1
      expect(matched, equals([0, 1]));
    });

    test('PrefixQuery expands terms matching prefix', () {
      final pq = const PrefixQuery(field: 'body', prefix: 'jump');
      final weight = pq.createWeight(searchContext);
      final scorer = weight.scorer(reader);
      expect(scorer, isNotNull);

      final matched = <int>[];
      var d = scorer!.nextDoc();
      while (d != Scorer.noMoreDocs) {
        matched.add(d);
        d = scorer.nextDoc();
      }

      expect(matched, equals([0])); // 'jumps'
    });

    test('WildcardQuery matches globs with ? and *', () {
      final wq = WildcardQuery(field: 'title', pattern: 'r*bit');
      final weight = wq.createWeight(searchContext);
      final scorer = weight.scorer(reader);
      expect(scorer, isNotNull);

      final matched = <int>[];
      var d = scorer!.nextDoc();
      while (d != Scorer.noMoreDocs) {
        matched.add(d);
        d = scorer.nextDoc();
      }

      expect(matched, equals([1])); // 'rabbit'
    });

    test('FuzzyQuery matches terms within Levenshtein edit distance', () {
      // 'rabit' (1 deletion from 'rabbit')
      final fq = const FuzzyQuery(field: 'title', term: 'rabit', maxEdits: 1);
      final weight = fq.createWeight(searchContext);
      final scorer = weight.scorer(reader);
      expect(scorer, isNotNull);

      final matched = <int>[];
      var d = scorer!.nextDoc();
      while (d != Scorer.noMoreDocs) {
        matched.add(d);
        d = scorer.nextDoc();
      }

      expect(matched, equals([1]));
    });

    test('NumericRangeQuery filters documents by numeric bounds', () {
      // price between 120 and 250 inclusive
      final nrq = const NumericRangeQuery(
        field: 'price',
        min: 120,
        max: 250,
        includeMin: true,
        includeMax: true,
      );

      final weight = nrq.createWeight(searchContext);
      final scorer = weight.scorer(reader);
      expect(scorer, isNotNull);

      final matched = <int>[];
      var d = scorer!.nextDoc();
      while (d != Scorer.noMoreDocs) {
        matched.add(d);
        d = scorer.nextDoc();
      }

      // doc 1 has 150, doc 2 has 200
      expect(matched, equals([1, 2]));
    });

    test('DisjunctionMaxQuery evaluates max score with tie breaker', () {
      final dismax = const DisjunctionMaxQuery(
        disjuncts: [
          TermQuery(field: 'title', term: 'fox'),
          TermQuery(field: 'body', term: 'fox'),
        ],
        tieBreakerMultiplier: 0.2,
      );

      final weight = dismax.createWeight(searchContext);
      final scorer = weight.scorer(reader);
      expect(scorer, isNotNull);

      final doc = scorer!.nextDoc();
      expect(doc, equals(0));
      expect(scorer.score(), greaterThan(0.0));
    });

    test('KnnVectorQuery executes vector ANN search over HNSW index', () {
      final target = Float32List.fromList([1.0, 0.0, 0.0, 0.0]);
      final knn = KnnVectorQuery(
        field: 'embedding',
        targetVector: target,
        k: 2,
      );

      final weight = knn.createWeight(searchContext);
      final scorer = weight.scorer(reader);
      expect(scorer, isNotNull);

      final matched = <int>[];
      var d = scorer!.nextDoc();
      while (d != Scorer.noMoreDocs) {
        matched.add(d);
        d = scorer.nextDoc();
      }

      expect(matched, containsAll([0, 1]));
    });

    test('HybridQuery fuses BM25 and vector search via RRF', () {
      final hybrid = HybridQuery(
        lexicalQuery: const TermQuery(field: 'title', term: 'fox'),
        vectorQuery: KnnVectorQuery(
          field: 'embedding',
          targetVector: Float32List.fromList([1.0, 0.0, 0.0, 0.0]),
          k: 2,
        ),
        fusionMode: HybridFusionMode.rrf,
      );

      final weight = hybrid.createWeight(searchContext);
      final scorer = weight.scorer(reader);
      expect(scorer, isNotNull);

      final matched = <int>[];
      var d = scorer!.nextDoc();
      while (d != Scorer.noMoreDocs) {
        matched.add(d);
        d = scorer.nextDoc();
      }

      expect(matched, contains(0));
    });
  });

  group('Similarity Ranking Model Tests', () {
    test('BM25Similarity calculates non-linear saturation', () {
      const bm25 = BM25Similarity(k1: 1.2, b: 0.75);
      final idf = bm25.computeIdf(10, 100);
      expect(idf, greaterThan(0.0));

      final score1 = bm25.score(freq: 1, docLength: 50, avgDocLength: 50, idf: idf);
      final score2 = bm25.score(freq: 5, docLength: 50, avgDocLength: 50, idf: idf);
      final score10 = bm25.score(freq: 50, docLength: 50, avgDocLength: 50, idf: idf);

      expect(score2, greaterThan(score1));
      // Saturation property: doubling frequency from 5 to 50 yields diminishing returns
      expect(score10, lessThan(score2 * 3.0));
    });

    test('ClassicTfIdfSimilarity computes square root TF and length norm', () {
      const tfidf = ClassicTfIdfSimilarity();
      final idf = tfidf.computeIdf(5, 50);
      final s = tfidf.score(freq: 4, docLength: 16, avgDocLength: 20, idf: idf);
      expect(s, equals(idf * 2.0 * 0.25));
    });
  });

  group('QueryParser Recursive Descent Syntax Tests', () {
    final parser = QueryParser(
      defaultField: 'body',
      analyzer: const StandardAnalyzer(),
    );

    test('parses simple term query', () {
      final q = parser.parse('database');
      expect(q, isA<TermQuery>());
      expect((q as TermQuery).field, equals('body'));
      expect(q.term, equals('database'));
    });

    test('parses explicit field term query', () {
      final q = parser.parse('title:corbel');
      expect(q, isA<TermQuery>());
      expect((q as TermQuery).field, equals('title'));
      expect(q.term, equals('corbel'));
    });

    test('parses quoted phrase query with slop', () {
      final q = parser.parse('"vector database"~3');
      expect(q, isA<PhraseQuery>());
      final pq = q as PhraseQuery;
      expect(pq.terms, equals(['vector', 'database']));
      expect(pq.slop, equals(3));
    });

    test('parses boolean AND, OR, NOT operations', () {
      final q = parser.parse('title:fast AND body:search OR tag:db');
      expect(q, isA<BooleanQuery>());
    });

    test('parses numeric range syntax', () {
      final q = parser.parse('price:[100 TO 500]');
      expect(q, isA<NumericRangeQuery>());
      final rq = q as NumericRangeQuery;
      expect(rq.min, equals(100));
      expect(rq.max, equals(500));
      expect(rq.includeMin, isTrue);
      expect(rq.includeMax, isTrue);
    });

    test('parses prefix, wildcard, and fuzzy syntax', () {
      final prefixQ = parser.parse('engin*');
      expect(prefixQ, isA<PrefixQuery>());

      final wildcardQ = parser.parse('eng?n*');
      expect(wildcardQ, isA<WildcardQuery>());

      final fuzzyQ = parser.parse('databse~1');
      expect(fuzzyQ, isA<FuzzyQuery>());
      expect((fuzzyQ as FuzzyQuery).maxEdits, equals(1));
    });
  });

  group('QueryOptimizer AST Optimization Tests', () {
    const optimizer = QueryOptimizer();

    test('flattens nested BooleanQueries with identical operators', () {
      const nested = BooleanQuery(
        clauses: [
          BooleanClause(query: TermQuery(field: 't', term: 'a'), occur: Occur.should),
          BooleanClause(
            query: BooleanQuery(
              clauses: [
                BooleanClause(query: TermQuery(field: 't', term: 'b'), occur: Occur.should),
                BooleanClause(query: TermQuery(field: 't', term: 'c'), occur: Occur.should),
              ],
            ),
            occur: Occur.should,
          ),
        ],
      );

      final opt = optimizer.optimize(nested);
      expect(opt, isA<BooleanQuery>());
      final bq = opt as BooleanQuery;
      expect(bq.clauses.length, equals(3));
    });

    test('detects contradictory MUST and MUST_NOT terms', () {
      const contradictory = BooleanQuery(
        clauses: [
          BooleanClause(query: TermQuery(field: 't', term: 'alpha'), occur: Occur.must),
          BooleanClause(query: TermQuery(field: 't', term: 'alpha'), occur: Occur.mustNot),
        ],
      );

      final opt = optimizer.optimize(contradictory);
      expect(opt, isA<BooleanQuery>());
      expect((opt as BooleanQuery).clauses.isEmpty, isTrue);
    });
  });

  group('Highlighter Snippet Tests', () {
    const highlighter = Highlighter(
      preTag: '<b>',
      postTag: '</b>',
      maxPassages: 2,
      maxPassageLength: 80,
    );

    test('wraps matched terms in HTML formatting tags', () {
      const text =
          'Corbel is a blazing fast embedded search engine. It supports vector search and lexical ranking.';
      final snippet = highlighter.highlight(text, {'corbel', 'vector'});

      expect(snippet, contains('<b>Corbel</b>'));
      expect(snippet, contains('<b>vector</b>'));
    });
  });

  group('WandScorer Dynamic Pruning Tests', () {
    test('WandScorer prunes documents below cumulative threshold', () {
      var doc1 = 10;
      final s1 = ConstantScoreScorer(
        nextDoc: () => doc1,
        advance: (t) => t <= 10 ? 10 : Scorer.noMoreDocs,
        docId: () => doc1,
        cost: () => 1.0,
        boost: 2.0,
      );
      var doc2 = 10;
      final s2 = ConstantScoreScorer(
        nextDoc: () => doc2,
        advance: (t) => t <= 10 ? 10 : Scorer.noMoreDocs,
        docId: () => doc2,
        cost: () => 1.0,
        boost: 3.0,
      );

      final wand = WandScorer(
        entries: [
          WandScorerEntry(scorer: s1, maxScore: 2.0),
          WandScorerEntry(scorer: s2, maxScore: 3.0),
        ],
        threshold: 4.0,
      );

      final match = wand.nextDoc();
      expect(match, equals(10));
      expect(wand.score(), equals(5.0));

      // Raise threshold above sum of all scorers: should return noMoreDocs
      wand.updateThreshold(10.0);
      expect(wand.advance(11), equals(Scorer.noMoreDocs));
    });
  });
}
