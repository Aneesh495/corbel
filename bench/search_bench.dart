import 'package:corbel/src/core/schema.dart';
import 'package:corbel/src/engine/corbel_engine.dart';
import 'package:corbel/src/storage/directory.dart';

void main() {
  print('========================================================');
  print('          CORBEL SEARCH MICRO-BENCHMARK SUITE           ');
  print('========================================================');

  final dir = RAMDirectory();
  final engine = CorbelEngine(baseDirectory: dir);
  final schema = Schema(
    fields: {
      'title': FieldDefinition.text('title'),
      'body': FieldDefinition.text('body'),
    },
  );

  final index = engine.createIndex('search_bench', schema);
  const numDocs = 2000;

  for (var i = 0; i < numDocs; i++) {
    index.index({
      '_id': 'doc_$i',
      'title': 'Distributed inverted index node $i',
      'body': 'Corbel combines vector similarity and BM25 term weighting.',
    });
  }
  index.commit();

  const numQueries = 10000;
  final queries = [
    'title:distributed',
    'body:similarity',
    'title:inverted AND body:vector',
    '"inverted index"~2',
  ];

  print('Executing $numQueries queries across $numDocs indexed documents...');
  final sw = Stopwatch()..start();

  for (var q = 0; q < numQueries; q++) {
    final queryStr = queries[q % queries.length];
    final res = index.search(queryStr, topN: 10);
    assert(res.totalHits > 0);
  }

  sw.stop();
  final elapsedMs = sw.elapsedMilliseconds;
  final qps = (numQueries / (elapsedMs / 1000.0)).toStringAsFixed(1);

  print('Done!');
  print('Executed $numQueries queries in ${elapsedMs}ms ($qps QPS)');

  engine.close();
}
