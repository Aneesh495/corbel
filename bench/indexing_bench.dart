import 'dart:math' as math;
import 'package:corbel/src/core/schema.dart';
import 'package:corbel/src/engine/corbel_engine.dart';
import 'package:corbel/src/storage/directory.dart';

void main() {
  print('========================================================');
  print('         CORBEL INDEXING MICRO-BENCHMARK SUITE          ');
  print('========================================================');

  final dir = RAMDirectory();
  final engine = CorbelEngine(baseDirectory: dir);
  final schema = Schema(
    fields: {
      'title': FieldDefinition.text('title'),
      'body': FieldDefinition.text('body'),
      'category': FieldDefinition.string('category', docValues: true),
      'price': FieldDefinition.int64('price', docValues: true),
    },
  );

  final index = engine.createIndex('bench_index', schema);
  const numDocs = 5000;
  final categories = ['electronics', 'books', 'apparel', 'home', 'garden'];
  final random = math.Random(42);

  print('Generating and indexing $numDocs synthetic documents...');
  final sw = Stopwatch()..start();

  for (var i = 0; i < numDocs; i++) {
    final cat = categories[i % categories.length];
    final price = 10 + random.nextInt(990);
    index.index({
      '_id': 'doc_$i',
      'title': 'High performance search product item $i with fast indexer',
      'body':
          'Document $i discusses information retrieval, roaring bitmaps, inverted indices, and distributed replication.',
      'category': cat,
      'price': price,
    });
  }

  index.commit();
  sw.stop();

  final elapsedMs = sw.elapsedMilliseconds;
  final throughput = (numDocs / (elapsedMs / 1000.0)).toStringAsFixed(1);

  print('Done!');
  print('Indexed $numDocs documents in ${elapsedMs}ms ($throughput docs/sec)');
  print('Stats: ${index.stats()}');

  engine.close();
}
