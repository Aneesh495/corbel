import 'dart:typed_data';
import 'package:test/test.dart';

import 'package:corbel/src/core/document.dart';
import 'package:corbel/src/core/schema.dart';
import 'package:corbel/src/index/segment_reader.dart';
import 'package:corbel/src/index/segment_writer.dart';
import 'package:corbel/src/query/knn_vector_query.dart';
import 'package:corbel/src/query/query.dart';
import 'package:corbel/src/storage/directory.dart';

void main() {
  group('Bug Regression: KnnVectorScorer NeighborPair distance vs similarity', () {
    test('KnnVectorScorer correctly accesses distance on NeighborPair without NoSuchMethodError', () {
      final dir = RAMDirectory();
      final schema = Schema(
        fields: {
          'vec': FieldDefinition.vector('vec', dimension: 2, metric: VectorDistanceMetric.l2),
        },
      );

      final writer = SegmentWriter(segmentName: '_bug04_seg', schema: schema, directory: dir);
      writer.addDocument(Document.fromMap('d0', {'vec': Float32List.fromList([1.0, 1.0])}));
      writer.addDocument(Document.fromMap('d1', {'vec': Float32List.fromList([2.0, 2.0])}));
      final info = writer.flush();

      final reader = SegmentReader.open(info: info, directory: dir);
      final query = KnnVectorQuery(
        field: 'vec',
        targetVector: Float32List.fromList([1.0, 1.0]),
        k: 1,
      );

      final weight = query.createWeight(const IndexSearchContext(totalDocumentCount: 2));
      final scorer = weight.scorer(reader);
      expect(scorer, isNotNull);

      final doc = scorer!.nextDoc();
      expect(doc, equals(0));
      // Scorer.score() must compute similarity from distance without throwing NoSuchMethodError
      final score = scorer.score();
      expect(score, greaterThan(0.0));
      expect(score, lessThanOrEqualTo(1.0));

      reader.close();
    });
  });
}
