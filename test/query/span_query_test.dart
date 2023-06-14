import 'package:corbel/corbel.dart';
import 'package:test/test.dart';

void main() {
  group('Span Query Subsystem Tests', () {
    late Directory dir;
    late Schema schema;
    late SegmentReader segmentReader;

    setUp(() {
      dir = RAMDirectory();
      schema = Schema(
        idFieldName: 'id',
        fields: {
          'id': FieldDefinition.string('id'),
          'text': const FieldDefinition(
            name: 'text',
            type: FieldType.text,
            analyzer: 'whitespace',
            indexOptions: IndexOptions.docsAndFreqsAndPositions,
            stored: true,
          ),
        },
      );

      final writer = SegmentWriter(
        segmentName: '_span_seg_0',
        schema: schema,
        directory: dir,
      );

      // Doc 0: "the quick brown fox jumps over the lazy dog"
      // Positions:
      // the: 1, 7
      // quick: 2
      // brown: 3
      // fox: 4
      // jumps: 5
      // over: 6
      // lazy: 8
      // dog: 9
      writer.addDocument(Document(
        id: 'doc0',
        fields: [
          Field.string('id', 'doc0'),
          Field.text('text', 'the quick brown fox jumps over the lazy dog'),
        ],
      ));

      // Doc 1: "the dog was jumped over by the quick fox"
      // Positions:
      // the: 1, 7
      // dog: 2
      // was: 3
      // jumped: 4
      // over: 5
      // by: 6
      // quick: 8
      // fox: 9
      writer.addDocument(Document(
        id: 'doc1',
        fields: [
          Field.string('id', 'doc1'),
          Field.text('text', 'the dog was jumped over by the quick fox'),
        ],
      ));

      // Doc 2: "money in the financial bank near the river bank"
      // Positions:
      // money: 1
      // in: 2
      // the: 3, 7
      // financial: 4
      // bank: 5, 9
      // near: 6
      // river: 8
      writer.addDocument(Document(
        id: 'doc2',
        fields: [
          Field.string('id', 'doc2'),
          Field.text('text', 'money in the financial bank near the river bank'),
        ],
      ));

      // Doc 3: "river bank with weeping willows"
      // Positions:
      // river: 1
      // bank: 2
      // with: 3
      // weeping: 4
      // willows: 5
      writer.addDocument(Document(
        id: 'doc3',
        fields: [
          Field.string('id', 'doc3'),
          Field.text('text', 'river bank with weeping willows'),
        ],
      ));

      final segInfo = writer.flush();
      segmentReader = SegmentReader.open(info: segInfo, directory: dir);
    });

    tearDown(() {
      segmentReader.close();
      dir.close();
    });

    final searchCtx = const IndexSearchContext(totalDocumentCount: 4);

    test('SpanTermQuery retrieves matching documents and positions', () {
      const q = SpanTermQuery(field: 'text', term: 'quick');
      final weight = q.createWeight(searchCtx);
      final spans = weight.getSpans(segmentReader);

      expect(spans, isNotNull);
      expect(spans!.nextDoc(), equals(0));
      expect(spans.nextStartPosition(), equals(2));
      expect(spans.startPosition(), equals(2));
      expect(spans.endPosition(), equals(3));
      expect(spans.width(), equals(1));
      expect(spans.nextStartPosition(), equals(Spans.noMorePositions));

      expect(spans.nextDoc(), equals(1));
      expect(spans.nextStartPosition(), equals(8));
      expect(spans.startPosition(), equals(8));
      expect(spans.endPosition(), equals(9));
      expect(spans.nextStartPosition(), equals(Spans.noMorePositions));

      expect(spans.nextDoc(), equals(Scorer.noMoreDocs));
    });

    test('SpanNearQuery ordered matches within slop', () {
      // "quick" and "fox" with slop 1, inOrder: true
      // In doc 0: quick at 2, brown at 3, fox at 4 -> span [2, 4], distance = (4 - 2) - (1 + 1) = 0 <= 1 (match!)
      // In doc 1: quick at 8, fox at 9 -> span [8, 9], distance = (9 - 8) - (1 + 1) = -1 <= 1 (match!)
      const q = SpanNearQuery(
        clauses: [
          SpanTermQuery(field: 'text', term: 'quick'),
          SpanTermQuery(field: 'text', term: 'fox'),
        ],
        slop: 1,
        inOrder: true,
      );

      final weight = q.createWeight(searchCtx);
      final spans = weight.getSpans(segmentReader)!;

      expect(spans.nextDoc(), equals(0));
      expect(spans.nextStartPosition(), equals(2));
      expect(spans.endPosition(), equals(5));

      expect(spans.nextDoc(), equals(1));
      expect(spans.nextStartPosition(), equals(8));
      expect(spans.endPosition(), equals(10));

      expect(spans.nextDoc(), equals(Scorer.noMoreDocs));
    });

    test('SpanNearQuery ordered enforces sequence', () {
      // "fox" followed by "quick" inOrder: true -> neither doc0 nor doc1 has fox before quick
      const q = SpanNearQuery(
        clauses: [
          SpanTermQuery(field: 'text', term: 'fox'),
          SpanTermQuery(field: 'text', term: 'quick'),
        ],
        slop: 5,
        inOrder: true,
      );

      final weight = q.createWeight(searchCtx);
      final spans = weight.getSpans(segmentReader)!;
      expect(spans.nextDoc(), equals(Scorer.noMoreDocs));

      // But unordered (inOrder: false) should match both doc0 and doc1!
      const qUnordered = SpanNearQuery(
        clauses: [
          SpanTermQuery(field: 'text', term: 'fox'),
          SpanTermQuery(field: 'text', term: 'quick'),
        ],
        slop: 5,
        inOrder: false,
      );

      final spansUnordered = qUnordered.createWeight(searchCtx).getSpans(segmentReader)!;
      expect(spansUnordered.nextDoc(), equals(0));
      expect(spansUnordered.nextDoc(), equals(1));
      expect(spansUnordered.nextDoc(), equals(Scorer.noMoreDocs));
    });

    test('SpanOrQuery disjunction of terms in document', () {
      const q = SpanOrQuery(
        clauses: [
          SpanTermQuery(field: 'text', term: 'brown'),
          SpanTermQuery(field: 'text', term: 'lazy'),
        ],
      );

      final weight = q.createWeight(searchCtx);
      final spans = weight.getSpans(segmentReader)!;

      // In Doc 0: brown at 3, lazy at 8
      expect(spans.nextDoc(), equals(0));
      expect(spans.nextStartPosition(), equals(3));
      expect(spans.nextStartPosition(), equals(8));
      expect(spans.nextStartPosition(), equals(Spans.noMorePositions));

      // Neither doc1, doc2, nor doc3 have brown or lazy
      expect(spans.nextDoc(), equals(Scorer.noMoreDocs));
    });

    test('SpanNotQuery excludes spans overlapping with or near exclusion term', () {
      // Include: "bank"
      // Exclude: "river" with pre: 1, post: 0
      // In doc 2: bank occurs at 5 ("financial bank") and at 9 ("river bank").
      // "river" is at 8, so "river bank" at 9 is excluded. "financial bank" at 5 should survive!
      // In doc 3: "river bank" only -> bank at 2 is preceded by river at 1 -> completely excluded!
      const q = SpanNotQuery(
        include: SpanTermQuery(field: 'text', term: 'bank'),
        exclude: SpanTermQuery(field: 'text', term: 'river'),
        pre: 1,
        post: 0,
      );

      final weight = q.createWeight(searchCtx);
      final spans = weight.getSpans(segmentReader)!;

      expect(spans.nextDoc(), equals(2));
      expect(spans.nextStartPosition(), equals(5));
      expect(spans.nextStartPosition(), equals(Spans.noMorePositions));

      // Doc 3 should be completely filtered out
      expect(spans.nextDoc(), equals(Scorer.noMoreDocs));
    });

    test('SpanFirstQuery filters spans past the prefix position cutoff', () {
      // Find "the" within the first 2 token positions
      // In doc 0: "the" is at 1 and 7 -> match [1, 2] (within end: 2)
      // In doc 1: "the" is at 1 and 7 -> match [1, 2] (within end: 2)
      // In doc 2: "the" is at 3 and 7 -> end is 4 and 8 > 2 -> no match!
      const q = SpanFirstQuery(
        match: SpanTermQuery(field: 'text', term: 'the'),
        end: 2,
      );

      final weight = q.createWeight(searchCtx);
      final spans = weight.getSpans(segmentReader)!;

      expect(spans.nextDoc(), equals(0));
      expect(spans.nextStartPosition(), equals(1));
      expect(spans.nextStartPosition(), equals(Spans.noMorePositions));

      expect(spans.nextDoc(), equals(1));
      expect(spans.nextStartPosition(), equals(1));
      expect(spans.nextStartPosition(), equals(Spans.noMorePositions));

      expect(spans.nextDoc(), equals(Scorer.noMoreDocs));
    });

    test('SpanScorer assigns higher score to tighter spans', () {
      const q = SpanNearQuery(
        clauses: [
          SpanTermQuery(field: 'text', term: 'quick'),
          SpanTermQuery(field: 'text', term: 'fox'),
        ],
        slop: 3,
        inOrder: true,
      );

      final scorer = q.createWeight(searchCtx).scorer(segmentReader)!;

      expect(scorer.nextDoc(), equals(0)); // quick brown fox (width 2)
      final scoreDoc0 = scorer.score();

      expect(scorer.nextDoc(), equals(1)); // quick fox (width 1, adjacent)
      final scoreDoc1 = scorer.score();

      // Adjacent span in doc1 is tighter than separated span in doc0, so doc1 should score higher
      expect(scoreDoc1, greaterThan(scoreDoc0));
    });
  });
}
