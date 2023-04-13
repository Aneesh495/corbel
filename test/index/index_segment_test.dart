import 'dart:typed_data';
import 'package:corbel/src/core/document.dart';
import 'package:corbel/src/core/schema.dart';
import 'package:corbel/src/index/deletion_vector.dart';
import 'package:corbel/src/index/docvalues/binary_doc_values.dart';
import 'package:corbel/src/index/docvalues/numeric_doc_values.dart';
import 'package:corbel/src/index/docvalues/sorted_set_doc_values.dart';
import 'package:corbel/src/index/merge_policy.dart';
import 'package:corbel/src/index/postings/posting.dart';
import 'package:corbel/src/index/postings/postings_reader.dart';
import 'package:corbel/src/index/postings/postings_writer.dart';
import 'package:corbel/src/index/segment_reader.dart';
import 'package:corbel/src/index/segment_writer.dart';
import 'package:corbel/src/storage/directory.dart';
import 'package:test/test.dart';

void main() {
  group('Postings Lists Tests', () {
    test('PostingsWriter and PostingsReader iteration and leapfrog advance', () {
      final dir = RAMDirectory();
      final out = dir.createOutput('test.pos');

      final postings = [
        const Posting(docId: 2, freq: 1, positions: [5], startOffsets: [10], endOffsets: [15]),
        const Posting(docId: 7, freq: 2, positions: [1, 9], startOffsets: [2, 20], endOffsets: [6, 25]),
        const Posting(docId: 18, freq: 1, positions: [4], startOffsets: [8], endOffsets: [12]),
        const Posting(docId: 25, freq: 3, positions: [2, 10, 15], startOffsets: [4, 25, 40], endOffsets: [8, 30, 45]),
      ];

      final writer = PostingsWriter(skipInterval: 2);
      final offset = writer.writePostingsList(out, postings);
      out.close();

      final inp = dir.openInput('test.pos');
      final reader = PostingsReader.open(inp, offset);

      expect(reader.docCount, equals(4));

      // Sequential iteration
      expect(reader.nextDoc(), equals(2));
      expect(reader.freq, equals(1));
      expect(reader.positions, equals([5]));

      expect(reader.nextDoc(), equals(7));
      expect(reader.freq, equals(2));
      expect(reader.positions, equals([1, 9]));

      // Leapfrog advance
      expect(reader.advance(20), equals(25));
      expect(reader.freq, equals(3));
      expect(reader.positions, equals([2, 10, 15]));

      expect(reader.nextDoc(), equals(PostingsReader.noMoreDocs));
    });
  });

  group('Columnar DocValues Tests', () {
    test('NumericDocValues GCD compression and random access', () {
      final dir = RAMDirectory();
      final out = dir.createOutput('test.dvs');

      // Values sharing GCD of 1000 (e.g. timestamps)
      final values = [10000, 12000, 15000, 18000, 25000, 100000];
      NumericDocValues.write(out, values);
      out.close();

      final inp = dir.openInput('test.dvs');
      final dvs = NumericDocValues.read(inp);

      expect(dvs.count, equals(values.length));
      for (var i = 0; i < values.length; i++) {
        expect(dvs.get(i), equals(values[i]));
      }
    });

    test('BinaryDocValues retrieval', () {
      final dir = RAMDirectory();
      final out = dir.createOutput('test_bin.dvs');

      final rawSlices = [
        Uint8List.fromList([1, 2, 3]),
        Uint8List.fromList([10, 20, 30, 40, 50]),
        Uint8List.fromList([99]),
      ];
      BinaryDocValues.write(out, rawSlices);
      out.close();

      final inp = dir.openInput('test_bin.dvs');
      final dvs = BinaryDocValues.read(inp);

      expect(dvs.count, equals(3));
      final ref0 = dvs.get(0);
      expect(ref0.bytes.sublist(ref0.offset, ref0.offset + ref0.length), equals([1, 2, 3]));
      final ref1 = dvs.get(1);
      expect(ref1.bytes.sublist(ref1.offset, ref1.offset + ref1.length), equals([10, 20, 30, 40, 50]));
      final ref2 = dvs.get(2);
      expect(ref2.bytes.sublist(ref2.offset, ref2.offset + ref2.length), equals([99]));
    });

    test('SortedSetDocValues categorical ordinals and dictionary lookup', () {
      final dir = RAMDirectory();
      final out = dir.createOutput('test_cat.dvs');

      final docTerms = [
        ['database', 'search'],
        ['distributed', 'search'],
        ['database', 'distributed'],
      ];
      SortedSetDocValues.write(out, docTerms);
      out.close();

      final inp = dir.openInput('test_cat.dvs');
      final dvs = SortedSetDocValues.read(inp);

      expect(dvs.dictionary, equals(['database', 'distributed', 'search']));
      expect(dvs.lookupOrd(0), equals('database'));
      expect(dvs.lookupOrd(1), equals('distributed'));
      expect(dvs.lookupOrd(2), equals('search'));

      expect(dvs.getOrds(0), equals([0, 2])); // database (0), search (2)
      expect(dvs.getOrds(1), equals([1, 2])); // distributed (1), search (2)
      expect(dvs.getOrds(2), equals([0, 1])); // database (0), distributed (1)
    });
  });

  group('Segment Lifecycle and Compaction Tests', () {
    test('SegmentWriter flushes segment files and SegmentReader executes queries', () {
      final dir = RAMDirectory();
      final schema = Schema(fields: {
        'title': FieldDefinition.text('title'),
        'category': FieldDefinition.string('category', docValues: true),
        'stars': FieldDefinition.int64('stars', docValues: true),
      });

      final writer = SegmentWriter(
        segmentName: '_0',
        schema: schema,
        directory: dir,
      );

      writer.addDocument(Document.fromMap('doc_1', {
        'title': 'High-performance distributed search',
        'category': 'systems',
        'stars': 1200,
      }));
      writer.addDocument(Document.fromMap('doc_2', {
        'title': 'Vector database and inverted index',
        'category': 'databases',
        'stars': 4500,
      }));
      writer.addDocument(Document.fromMap('doc_3', {
        'title': 'Distributed databases and consensus',
        'category': 'systems',
        'stars': 3200,
      }));

      final info = writer.flush();
      expect(info.name, equals('_0'));
      expect(info.maxDoc, equals(3));
      expect(info.numDocs, equals(3));

      // Open SegmentReader
      final reader = SegmentReader.open(info: info, directory: dir);
      expect(reader.numDocs, equals(3));

      // Verify postings for term 'distributed'
      final postings = reader.postings('title', 'distributed');
      expect(postings, isNotNull);
      expect(postings!.nextDoc(), equals(0)); // doc_1
      expect(postings.nextDoc(), equals(2)); // doc_3
      expect(postings.nextDoc(), equals(PostingsReader.noMoreDocs));

      // Verify DocValues
      final starsDvs = reader.getNumericDocValues('stars')!;
      expect(starsDvs.get(0), equals(1200));
      expect(starsDvs.get(1), equals(4500));
      expect(starsDvs.get(2), equals(3200));

      // Verify stored fields
      final doc2Map = reader.document(1);
      expect(doc2Map['_id'], equals('doc_2'));
      expect(doc2Map['category'], equals('databases'));

      reader.close();
    });

    test('SegmentMerger combines segments and purges soft-deleted tombstones', () {
      final dir = RAMDirectory();
      final schema = Schema(fields: {
        'title': FieldDefinition.text('title'),
      });

      // Segment 1
      final writer1 = SegmentWriter(segmentName: '_seg_a', schema: schema, directory: dir);
      writer1.addDocument(Document.fromMap('d1', {'title': 'Alpha'}));
      writer1.addDocument(Document.fromMap('d2', {'title': 'Beta'}));
      final info1 = writer1.flush();

      // Soft delete d1 in seg_a
      final del1 = DeletionVector();
      del1.delete(0); // d1 is deleted

      // Segment 2
      final writer2 = SegmentWriter(segmentName: '_seg_b', schema: schema, directory: dir);
      writer2.addDocument(Document.fromMap('d3', {'title': 'Gamma'}));
      final info2 = writer2.flush();

      // Merge
      final customMerger = SegmentMerger(
        directory: dir,
        schema: schema,
        spec: MergeSpec(
          mergedSegmentName: '_merged_0',
          segmentsToMerge: [info1, info2],
        ),
        deletionVectors: {'_seg_a': del1},
      );

      final mergedInfo = customMerger.execute();
      expect(mergedInfo.name, equals('_merged_0'));
      expect(mergedInfo.maxDoc, equals(2)); // d2 (Beta) and d3 (Gamma), d1 was purged!

      final mergedReader = SegmentReader.open(info: mergedInfo, directory: dir);
      expect(mergedReader.numDocs, equals(2));
      expect(mergedReader.document(0)['_id'], equals('d2'));
      expect(mergedReader.document(1)['_id'], equals('d3'));
      mergedReader.close();
    });
  });
}
