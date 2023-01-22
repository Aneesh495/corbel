import 'dart:typed_data';
import 'package:corbel/corbel.dart';
import 'package:test/test.dart';

void main() {
  group('Schema and FieldDefinition Tests', () {
    test('standard schema defaults and field construction', () {
      final schema = Schema(fields: {
        'title': FieldDefinition.text('title', withPositions: true, withOffsets: true),
        'category': FieldDefinition.string('category', docValues: true),
        'views': FieldDefinition.int64('views'),
        'rating': FieldDefinition.float64('rating'),
        'embedding': FieldDefinition.vector('embedding', dimension: 4, metric: VectorDistanceMetric.cosine),
      });

      expect(schema.containsField('_id'), isTrue);
      expect(schema.containsField('title'), isTrue);
      expect(schema.containsField('category'), isTrue);
      expect(schema.containsField('views'), isTrue);
      expect(schema.containsField('rating'), isTrue);
      expect(schema.containsField('embedding'), isTrue);

      final titleDef = schema.getField('title')!;
      expect(titleDef.isIndexed, isTrue);
      expect(titleDef.hasPositions, isTrue);
      expect(titleDef.hasOffsets, isTrue);
      expect(titleDef.hasFreqs, isTrue);
      expect(titleDef.hasDocValues, isFalse);

      final catDef = schema.getField('category')!;
      expect(catDef.isIndexed, isTrue);
      expect(catDef.hasDocValues, isTrue);
      expect(catDef.docValuesType, equals(DocValuesType.sortedSet));

      final embDef = schema.getField('embedding')!;
      expect(embDef.type, equals(FieldType.vector));
      expect(embDef.vectorDimension, equals(4));
      expect(embDef.vectorMetric, equals(VectorDistanceMetric.cosine));
    });

    test('schema JSON round-trip serialization', () {
      final original = Schema(
        idFieldName: 'custom_id',
        fields: {
          'summary': FieldDefinition.text('summary', analyzer: 'english'),
          'price': FieldDefinition.float64('price'),
          'vector': FieldDefinition.vector('vector', dimension: 128, metric: VectorDistanceMetric.dotProduct),
        },
      );

      final json = original.toJson();
      final restored = Schema.fromJson(json);

      expect(restored.idFieldName, equals('custom_id'));
      expect(restored.containsField('summary'), isTrue);
      expect(restored.getField('summary')!.analyzer, equals('english'));
      expect(restored.getField('price')!.type, equals(FieldType.float64));
      expect(restored.getField('vector')!.vectorDimension, equals(128));
      expect(restored.getField('vector')!.vectorMetric, equals(VectorDistanceMetric.dotProduct));
    });

    test('schema validation accepts conforming data', () {
      final schema = Schema(fields: {
        'title': FieldDefinition.text('title'),
        'views': FieldDefinition.int64('views'),
        'score': FieldDefinition.float64('score'),
        'embedding': FieldDefinition.vector('embedding', dimension: 3),
      });

      final validData = <String, dynamic>{
        'title': 'High-performance retrieval engine',
        'views': 42000,
        'score': 98.6,
        'embedding': [0.1, 0.2, 0.3],
      };

      expect(() => schema.validate(validData), returnsNormally);
    });

    test('schema validation throws on vector dimension mismatch', () {
      final schema = Schema(fields: {
        'embedding': FieldDefinition.vector('embedding', dimension: 4),
      });

      final invalidData = <String, dynamic>{
        'embedding': [1.0, 2.0, 3.0], // 3 elements instead of 4
      };

      expect(
        () => schema.validate(invalidData),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('dimension mismatch: expected 4, got 3'),
        )),
      );
    });

    test('schema validation throws on invalid type', () {
      final schema = Schema(fields: {
        'views': FieldDefinition.int64('views'),
      });

      final invalidData = <String, dynamic>{
        'views': 'forty-two',
      };

      expect(
        () => schema.validate(invalidData),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains("expects int, got String"),
        )),
      );
    });
  });

  group('Document and Field Model Tests', () {
    test('document typed accessors and map conversion', () {
      final vec = Float32List.fromList([0.5, 0.25, 0.125]);
      final rawBytes = Uint8List.fromList([1, 2, 3, 4]);

      final doc = Document(id: 'doc_101', fields: [
        Field.text('title', 'Distributed Search'),
        Field.string('tag', 'systems'),
        Field.int64('stars', 1500),
        Field.float64('latency_ms', 1.42),
        Field.boolean('is_active', true),
        Field.date('created_at', 1700000000000),
        Field.vector('dense_vec', vec),
        Field.binary('payload', rawBytes),
      ]);

      expect(doc.id, equals('doc_101'));
      expect(doc.getString('title'), equals('Distributed Search'));
      expect(doc.getString('tag'), equals('systems'));
      expect(doc.getInt('stars'), equals(1500));
      expect(doc.getDouble('latency_ms'), closeTo(1.42, 0.001));
      expect(doc.getInt('created_at'), equals(1700000000000));
      expect(doc.getVector('dense_vec'), equals(vec));
      expect(doc.getBinary('payload'), equals(rawBytes));

      final map = doc.toMap();
      expect(map['_id'], equals('doc_101'));
      expect(map['title'], equals('Distributed Search'));
      expect(map['stars'], equals(1500));
      expect(map['dense_vec'], equals([0.5, 0.25, 0.125]));
    });

    test('document fromMap dynamic type inference', () {
      final doc = Document.fromMap('doc_202', {
        'title': 'Corbel Kernel',
        'count': 100,
        'rate': 3.14,
        'enabled': false,
        'embedding': [0.1, 0.2, 0.3, 0.4],
      });

      expect(doc.id, equals('doc_202'));
      expect(doc.getString('title'), equals('Corbel Kernel'));
      expect(doc.getInt('count'), equals(100));
      expect(doc.getDouble('rate'), closeTo(3.14, 0.001));
      expect(doc.getField('enabled')?.value, equals(false));
      expect(doc.getVector('embedding')?.length, equals(4));
    });
  });

  group('Exception Hierarchy Tests', () {
    test('exceptions provide informative strings', () {
      final corrupt = CorbelCorruptIndexException('Segment CRC mismatch');
      expect(corrupt.toString(), contains('CorbelException: Segment CRC mismatch'));

      final parse = CorbelParseException('Unexpected token', position: 14);
      expect(parse.toString(), contains('CorbelParseException at offset 14: Unexpected token'));

      final notFound = CorbelNotFoundException('Index does not exist');
      expect(notFound.toString(), contains('CorbelException: Index does not exist'));
    });
  });
}
