import 'dart:convert';
import 'dart:typed_data';
import '../../analysis/analyzer.dart';
import '../../core/document.dart';
import '../../core/schema.dart';
import '../../storage/directory.dart';
import '../../utils/bytes_ref.dart';
import 'docvalues/binary_doc_values.dart';
import 'docvalues/numeric_doc_values.dart';
import 'docvalues/sorted_set_doc_values.dart';
import 'fst/fst.dart';
import 'postings/posting.dart';
import 'postings/postings_writer.dart';
import 'segment_info.dart';
import 'stored_fields/stored_fields_writer.dart';

class _InvertedPostingBuilder {
  int freq = 0;
  final List<int> positions = [];
  final List<int> startOffsets = [];
  final List<int> endOffsets = [];

  void addOccurrence(int pos, int start, int end) {
    freq++;
    positions.add(pos);
    startOffsets.add(start);
    endOffsets.add(end);
  }
}

/// Accumulates documents in-memory and flushes an immutable segment to Directory storage.
class SegmentWriter {
  final String segmentName;
  final Schema schema;
  final Directory directory;
  final Map<String, Analyzer> _analyzers = {};

  int _docCount = 0;

  // Field Name -> Term -> Map of docId -> _InvertedPostingBuilder
  final Map<String, Map<String, Map<int, _InvertedPostingBuilder>>> _inverted = {};

  // Numeric DocValues: fieldName -> List of 64-bit int per doc
  final Map<String, List<int>> _numericDocValues = {};

  // Binary DocValues: fieldName -> List of Uint8List per doc
  final Map<String, List<Uint8List>> _binaryDocValues = {};

  // Sorted Set DocValues: fieldName -> List of List<String> per doc
  final Map<String, List<List<String>>> _sortedSetDocValues = {};

  // Stored fields accumulator
  final List<Map<String, dynamic>> _storedDocuments = [];

  SegmentWriter({
    required this.segmentName,
    required this.schema,
    required this.directory,
  }) {
    for (final fieldDef in schema.fields.values) {
      if (fieldDef.type == FieldType.text) {
        final analyzerName = fieldDef.analyzer ?? 'standard';
        _analyzers[fieldDef.name] = Analyzer.byName(analyzerName);
      }
    }
  }

  /// Number of documents added to this segment writer buffer.
  int get docCount => _docCount;

  /// Adds a document to the in-memory segment buffer.
  void addDocument(Document doc) {
    final docId = _docCount++;

    // 1. Process stored fields
    _storedDocuments.add(doc.toMap());

    // 2. Process each field for inverted index and DocValues
    for (final field in doc.fields) {
      final fieldDef = schema.getField(field.name);
      if (fieldDef == null) continue;

      // Inverted index processing
      if (fieldDef.isIndexed && field.value != null) {
        if (fieldDef.type == FieldType.text && field.value is String) {
          _indexTextField(fieldDef, docId, field.value as String);
        } else if (fieldDef.type == FieldType.string) {
          _indexStringField(fieldDef, docId, field.value.toString());
        }
      }

      // Columnar DocValues processing
      if (fieldDef.hasDocValues && field.value != null) {
        _accumulateDocValues(fieldDef, docId, field.value!);
      }
    }
  }

  void _indexTextField(FieldDefinition def, int docId, String text) {
    final fieldInverted = _inverted.putIfAbsent(def.name, () => {});
    final analyzer = _analyzers[def.name] ?? const StandardAnalyzer();
    final stream = analyzer.tokenStream(def.name, text);

    var currentPos = 0;
    while (stream.incrementToken()) {
      final token = stream.currentToken;
      currentPos += token.positionIncrement;

      final termPostings = fieldInverted.putIfAbsent(token.term, () => {});
      final builder = termPostings.putIfAbsent(docId, () => _InvertedPostingBuilder());

      builder.addOccurrence(currentPos, token.startOffset, token.endOffset);
    }
  }

  void _indexStringField(FieldDefinition def, int docId, String value) {
    final fieldInverted = _inverted.putIfAbsent(def.name, () => {});
    final termPostings = fieldInverted.putIfAbsent(value, () => {});
    final builder = termPostings.putIfAbsent(docId, () => _InvertedPostingBuilder());
    builder.addOccurrence(1, 0, value.length);
  }

  void _accumulateDocValues(FieldDefinition def, int docId, Object value) {
    switch (def.docValuesType) {
      case DocValuesType.numeric:
        final list = _numericDocValues.putIfAbsent(def.name, () => []);
        while (list.length < docId) {
          list.add(0);
        }
        if (value is int) {
          list.add(value);
        } else if (value is num) {
          // Store float64 as bit-cast integer
          final bd = ByteData(8)..setFloat64(0, value.toDouble());
          list.add(bd.getInt64(0));
        } else {
          list.add(0);
        }
        break;
      case DocValuesType.binary:
        final list = _binaryDocValues.putIfAbsent(def.name, () => []);
        while (list.length < docId) {
          list.add(Uint8List(0));
        }
        if (value is Uint8List) {
          list.add(value);
        } else if (value is Float32List) {
          list.add(Uint8List.sublistView(value));
        } else {
          list.add(Uint8List.fromList(utf8.encode(value.toString())));
        }
        break;
      case DocValuesType.sortedSet:
        final list = _sortedSetDocValues.putIfAbsent(def.name, () => []);
        while (list.length < docId) {
          list.add([]);
        }
        if (value is List<String>) {
          list.add(value);
        } else if (value is List) {
          list.add(value.map((e) => e.toString()).toList());
        } else {
          list.add([value.toString()]);
        }
        break;
      case DocValuesType.none:
        break;
    }
  }

  /// Flushes in-memory segment to directory files and returns immutable SegmentInfo.
  SegmentInfo flush() {
    var totalBytes = 0;

    // 1. Flush Stored Fields (.cbl_fdx and .cbl_fdt)
    final fdxOut = directory.createOutput('$segmentName.cbl_fdx');
    final fdtOut = directory.createOutput('$segmentName.cbl_fdt');
    final storedWriter = StoredFieldsWriter(indexOut: fdxOut, dataOut: fdtOut);
    for (final doc in _storedDocuments) {
      storedWriter.writeDocument(doc);
    }
    storedWriter.close();
    fdxOut.close();
    fdtOut.close();
    totalBytes += directory.fileLength('$segmentName.cbl_fdx');
    totalBytes += directory.fileLength('$segmentName.cbl_fdt');

    // 2. Flush Postings & FST Dictionaries per indexed field
    final posOut = directory.createOutput('$segmentName.cbl_pos');
    final fstOut = directory.createOutput('$segmentName.cbl_fst');
    final postingsWriter = PostingsWriter();

    // Map: fieldName -> FST
    for (final entry in _inverted.entries) {
      final fieldName = entry.key;
      final termMap = entry.value;

      final sortedTerms = termMap.keys.toList()..sort();
      final fstEntries = <MapEntry<String, int>>[];

      for (final term in sortedTerms) {
        final docMap = termMap[term]!;
        final postingsList = <Posting>[];

        final sortedDocIds = docMap.keys.toList()..sort();
        for (final dId in sortedDocIds) {
          final builder = docMap[dId]!;
          postingsList.add(Posting(
            docId: dId,
            freq: builder.freq,
            positions: builder.positions,
            startOffsets: builder.startOffsets,
            endOffsets: builder.endOffsets,
          ));
        }

        final postingOffset = postingsWriter.writePostingsList(posOut, postingsList);
        fstEntries.add(MapEntry(term, postingOffset));
      }

      final fst = Fst.fromSortedTerms(fstEntries);
      fstOut.writeString(fieldName);
      fst.serialize(fstOut);
    }
    fstOut.writeString(''); // Sentinel empty string ending fields
    posOut.close();
    fstOut.close();
    totalBytes += directory.fileLength('$segmentName.cbl_pos');
    totalBytes += directory.fileLength('$segmentName.cbl_fst');

    // 3. Flush Columnar DocValues (.cbl_dvs)
    final dvsOut = directory.createOutput('$segmentName.cbl_dvs');
    // Numeric DocValues
    dvsOut.writeVInt(_numericDocValues.length);
    for (final entry in _numericDocValues.entries) {
      dvsOut.writeString(entry.key);
      NumericDocValues.write(dvsOut, entry.value);
    }
    // Binary DocValues
    dvsOut.writeVInt(_binaryDocValues.length);
    for (final entry in _binaryDocValues.entries) {
      dvsOut.writeString(entry.key);
      BinaryDocValues.write(dvsOut, entry.value);
    }
    // Sorted Set DocValues
    dvsOut.writeVInt(_sortedSetDocValues.length);
    for (final entry in _sortedSetDocValues.entries) {
      dvsOut.writeString(entry.key);
      SortedSetDocValues.write(dvsOut, entry.value);
    }
    dvsOut.close();
    totalBytes += directory.fileLength('$segmentName.cbl_dvs');

    return SegmentInfo(
      name: segmentName,
      maxDoc: _docCount,
      delCount: 0,
      sizeInBytes: totalBytes,
      schema: schema,
    );
  }
}
