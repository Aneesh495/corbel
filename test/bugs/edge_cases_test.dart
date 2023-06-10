import 'dart:typed_data';
import 'package:test/test.dart';

import 'package:corbel/src/analysis/analyzer.dart';
import 'package:corbel/src/core/document.dart';
import 'package:corbel/src/core/schema.dart';
import 'package:corbel/src/index/deletion_vector.dart';
import 'package:corbel/src/index/postings/postings_reader.dart';
import 'package:corbel/src/query/boolean_query.dart';
import 'package:corbel/src/query/query_parser.dart';
import 'package:corbel/src/vector/distance.dart';

void main() {
  group('Edge Cases and Boundary Conditions', () {
    test('QueryParser handles whitespace and empty input gracefully', () {
      final parser = QueryParser(defaultField: 'f', analyzer: const StandardAnalyzer());
      final emptyResult = parser.parse('');
      expect(emptyResult, isA<BooleanQuery>());
      expect((emptyResult as BooleanQuery).clauses, isEmpty);

      final whitespaceResult = parser.parse('   \t\n  ');
      expect(whitespaceResult, isA<BooleanQuery>());
      expect((whitespaceResult as BooleanQuery).clauses, isEmpty);
    });

    test('DeletionVector handles single element boundaries', () {
      final del = DeletionVector();
      expect(del.isDeleted(0), isFalse);
      expect(del.delete(0), isTrue);
      expect(del.isDeleted(0), isTrue);
      expect(del.delete(0), isFalse); // Already deleted
      expect(del.numDeletions, equals(1));
    });

    test('VectorDistance throws ArgumentError on mismatched dimensions', () {
      final v1 = Float32List.fromList([1.0, 2.0]);
      final v2 = Float32List.fromList([1.0, 2.0, 3.0]);

      expect(() => VectorDistance.dotProduct(v1, v2), throwsArgumentError);
      expect(() => VectorDistance.squaredEuclidean(v1, v2), throwsArgumentError);
      expect(() => VectorDistance.cosineSimilarity(v1, v2), throwsArgumentError);
      expect(() => VectorDistance.manhattan(v1, v2), throwsArgumentError);
    });

    test('PostingsReader sentinel exhaustion behaves consistently', () {
      expect(PostingsReader.noMoreDocs, equals(0x7FFFFFFF));
    });

    test('Document model handles null fields gracefully', () {
      final doc = Document(id: 'null_doc');
      expect(doc.getString('non_existent'), isNull);
      expect(doc.getInt('non_existent'), isNull);
      expect(doc.getDouble('non_existent'), isNull);
      expect(doc.getVector('non_existent'), isNull);
    });
  });
}
