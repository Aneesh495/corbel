import 'dart:convert';
import 'dart:io';

import 'package:corbel/src/core/schema.dart';
import 'package:corbel/src/engine/corbel_engine.dart';
import 'package:corbel/src/query/query_parser.dart';
import 'package:corbel/src/server/http_server.dart';
import 'package:corbel/src/storage/directory.dart';

void main(List<String> args) async {
  if (args.isEmpty) {
    _printUsage();
    return;
  }

  final command = args[0].toLowerCase();

  switch (command) {
    case 'server':
      await _runServer(args.sublist(1));
    case 'repl':
      await _runRepl(args.sublist(1));
    case 'search':
      await _runSearch(args.sublist(1));
    case 'version':
      stdout.writeln('Corbel Search Engine v1.0.0');
    case 'help':
    default:
      _printUsage();
  }
}

void _printUsage() {
  stdout.writeln('''
\x1B[1;36mCORBEL SEARCH ENGINE\x1B[0m - High-Performance Inverted & Vector Search Engine

Usage:
  corbel <command> [options]

Commands:
  \x1B[32mserver\x1B[0m   Start HTTP REST API and web dashboard
  \x1B[32mrepl\x1B[0m     Launch interactive search and index console
  \x1B[32msearch\x1B[0m   Execute one-shot query from command line
  \x1B[32mversion\x1B[0m  Show engine version information
  \x1B[32mhelp\x1B[0m     Show this help message

Examples:
  corbel server --port 9200 --dir ./data
  corbel repl
  corbel search my_index "title:database AND vector"
''');
}

Future<void> _runServer(List<String> args) async {
  var port = 9200;
  var dataDir = './corbel_data';

  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--port' && i + 1 < args.length) {
      port = int.tryParse(args[i + 1]) ?? 9200;
    } else if (args[i] == '--dir' && i + 1 < args.length) {
      dataDir = args[i + 1];
    }
  }

  final dir = DiskDirectory(dataDir);
  final engine = CorbelEngine(baseDirectory: dir);
  final server = CorbelHttpServer(engine: engine, port: port);

  await server.start();
  stdout.writeln('\x1B[1;32m[CORBEL]\x1B[0m HTTP server running on http://127.0.0.1:$port');
  stdout.writeln('\x1B[1;32m[CORBEL]\x1B[0m Web dashboard accessible at http://127.0.0.1:$port/_dashboard');

  ProcessSignal.sigint.watch().listen((_) async {
    stdout.writeln('\nShutting down Corbel server...');
    await server.close();
    engine.close();
    exit(0);
  });
}

Future<void> _runSearch(List<String> args) async {
  if (args.length < 2) {
    stdout.writeln('Usage: corbel search <index-name> "<query-string>"');
    return;
  }

  final indexName = args[0];
  final queryString = args[1];
  final dir = DiskDirectory('./corbel_data');
  final engine = CorbelEngine(baseDirectory: dir);

  final index = engine.getIndex(indexName);
  if (index == null) {
    stdout.writeln('Index "$indexName" not found in ./corbel_data');
    engine.close();
    return;
  }

  final topDocs = index.search(queryString, topN: 10);
  stdout.writeln('Found ${topDocs.totalHits} matching documents:');

  for (final hit in topDocs.scoreDocs) {
    final doc = index.doc(hit);
    stdout.writeln('  [${hit.id}] Score: ${hit.score.toStringAsFixed(4)} -> ${doc.toMap()}');
  }

  engine.close();
}

Future<void> _runRepl(List<String> args) async {
  stdout.writeln('\x1B[1;36m========================================================\x1B[0m');
  stdout.writeln('\x1B[1;36m         CORBEL INTERACTIVE SEARCH REPL v1.0.0          \x1B[0m');
  stdout.writeln('\x1B[1;36m========================================================\x1B[0m');
  stdout.writeln('Type ":help" for commands, or ":quit" to exit.\n');

  final dir = RAMDirectory();
  final engine = CorbelEngine(baseDirectory: dir);

  // Pre-seed a default test collection
  final schema = Schema(
    fields: {
      'title': FieldDefinition.text('title'),
      'body': FieldDefinition.text('body'),
      'category': FieldDefinition.string('category', docValues: true),
      'views': FieldDefinition.int64('views', docValues: true),
    },
  );
  final defaultIndex = engine.createIndex('default', schema);
  defaultIndex.bulkIndex([
    {
      '_id': 'doc_1',
      'title': 'High Performance Inverted Indexing in Dart',
      'body': 'Corbel utilizes SIMD distance kernels and roaring bitmaps.',
      'category': 'systems',
      'views': 1200,
    },
    {
      '_id': 'doc_2',
      'title': 'Vector Search with Hierarchical Navigable Small World Graphs',
      'body': 'HNSW graphs provide fast approximate nearest neighbor retrieval.',
      'category': 'ai',
      'views': 4500,
    },
    {
      '_id': 'doc_3',
      'title': 'Distributed Consensus using Raft Protocol',
      'body': 'Raft leader election and log replication ensure fault tolerance.',
      'category': 'systems',
      'views': 2300,
    },
  ]);
  defaultIndex.commit();

  var activeIndexName = 'default';

  while (true) {
    stdout.write('\x1B[1;33mcorbel($activeIndexName)>\x1B[0m ');
    final line = stdin.readLineSync();
    if (line == null) break;

    final input = line.trim();
    if (input.isEmpty) continue;

    if (input == ':quit' || input == ':exit' || input == ':q') {
      stdout.writeln('Exiting Corbel REPL.');
      break;
    }

    if (input == ':help') {
      stdout.writeln('''
Available REPL Commands:
  :indices                     List all active index collections
  :use <index>                 Switch active index
  :stats                       Show statistics of active index
  :index <json>                Index document JSON into active index
  :search <query>              Search active index
  :explain <query>             Show AST query plan and explanation
  :help                        Display this help menu
  :quit                        Exit REPL
''');
      continue;
    }

    if (input == ':indices') {
      final names = engine.listIndices();
      stdout.writeln('Active indices: ${names.join(", ")}');
      continue;
    }

    if (input.startsWith(':use ')) {
      final target = input.substring(5).trim();
      if (engine.getIndex(target) != null) {
        activeIndexName = target;
        stdout.writeln('Switched to index "$target".');
      } else {
        stdout.writeln('Index "$target" does not exist.');
      }
      continue;
    }

    if (input == ':stats') {
      final idx = engine.getIndex(activeIndexName);
      if (idx != null) {
        stdout.writeln(jsonEncode(idx.stats()));
      }
      continue;
    }

    if (input.startsWith(':index ')) {
      final jsonStr = input.substring(7).trim();
      try {
        final map = jsonDecode(jsonStr) as Map<String, dynamic>;
        final idx = engine.getIndex(activeIndexName)!;
        idx.index(map);
        idx.commit();
        stdout.writeln('\x1B[32m[OK]\x1B[0m Document indexed and committed successfully.');
      } catch (err) {
        stdout.writeln('\x1B[31m[ERROR]\x1B[0m Invalid JSON: $err');
      }
      continue;
    }

    if (input.startsWith(':explain ')) {
      final qStr = input.substring(9).trim();
      final idx = engine.getIndex(activeIndexName)!;
      final parser = QueryParser(
        defaultField: 'body',
        analyzer: idx.defaultAnalyzer,
      );
      final query = parser.parse(qStr);
      stdout.writeln('\x1B[1;36mAST Query Plan:\x1B[0m $query');
      continue;
    }

    // Default: execute query directly
    final qStr = input.startsWith(':search ') ? input.substring(8).trim() : input;
    final idx = engine.getIndex(activeIndexName)!;
    final topDocs = idx.search(qStr, topN: 10);

    stdout.writeln('\x1B[1;32mHits (${topDocs.totalHits}):\x1B[0m');
    if (topDocs.scoreDocs.isEmpty) {
      stdout.writeln('  No documents matched query.');
    } else {
      for (final hit in topDocs.scoreDocs) {
        final doc = idx.doc(hit);
        stdout.writeln('  \x1B[1m#${hit.id}\x1B[0m (Score: ${hit.score.toStringAsFixed(4)})');
        stdout.writeln('     Title: ${doc.getString("title") ?? "<empty>"}');
        stdout.writeln('     Body:  ${doc.getString("body") ?? "<empty>"}');
      }
    }
  }

  engine.close();
}
