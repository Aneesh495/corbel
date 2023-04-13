import '../core/schema.dart';
import '../storage/directory.dart';
import '../storage/index_input.dart';
import '../storage/vbyte.dart';
import '../vector/vector_index.dart';
import 'deletion_vector.dart';
import 'docvalues/binary_doc_values.dart';
import 'docvalues/numeric_doc_values.dart';
import 'docvalues/sorted_set_doc_values.dart';
import 'fst/fst.dart';
import 'postings/postings_reader.dart';
import 'segment_info.dart';
import 'stored_fields/stored_fields_reader.dart';

/// Thread-safe reader executing queries over an immutable segment.
class SegmentReader {
  final SegmentInfo info;
  final Directory directory;
  final DeletionVector deletionVector;

  final Map<String, Fst> _fieldFsts = {};
  IndexInput? _posInput;
  StoredFieldsReader? _storedFieldsReader;

  final Map<String, NumericDocValues> _numericDocValues = {};
  final Map<String, BinaryDocValues> _binaryDocValues = {};
  final Map<String, SortedSetDocValues> _sortedSetDocValues = {};
  final Map<String, VectorIndex> _vectorIndices = {};

  bool _closed = false;

  SegmentReader._({
    required this.info,
    required this.directory,
    required this.deletionVector,
  });

  /// Opens a segment reader for the specified SegmentInfo.
  static SegmentReader open({
    required SegmentInfo info,
    required Directory directory,
    DeletionVector? deletionVector,
  }) {
    final reader = SegmentReader._(
      info: info,
      directory: directory,
      deletionVector: deletionVector ?? DeletionVector(),
    );
    reader._init();
    return reader;
  }

  void _init() {
    final segName = info.name;

    // 1. Load FST Dictionaries (.cbl_fst)
    if (directory.fileExists('$segName.cbl_fst')) {
      final fstInput = directory.openInput('$segName.cbl_fst');
      try {
        while (fstInput.remaining > 0) {
          final fieldName = fstInput.readString();
          if (fieldName.isEmpty) break; // Sentinel
          final fst = Fst.deserialize(fstInput);
          _fieldFsts[fieldName] = fst;
        }
      } finally {
        fstInput.close();
      }
    }

    // 2. Open Postings Input (.cbl_pos)
    if (directory.fileExists('$segName.cbl_pos')) {
      _posInput = directory.openInput('$segName.cbl_pos');
    }

    // 3. Open Stored Fields Reader (.cbl_fdx and .cbl_fdt)
    if (directory.fileExists('$segName.cbl_fdx') &&
        directory.fileExists('$segName.cbl_fdt')) {
      final fdxIn = directory.openInput('$segName.cbl_fdx');
      final fdtIn = directory.openInput('$segName.cbl_fdt');
      _storedFieldsReader = StoredFieldsReader.open(
        indexIn: fdxIn,
        dataIn: fdtIn,
        docCount: info.maxDoc,
      );
    }

    // 4. Load Columnar DocValues (.cbl_dvs)
    if (directory.fileExists('$segName.cbl_dvs')) {
      final dvsIn = directory.openInput('$segName.cbl_dvs');
      try {
        // Numeric DocValues
        final numNumeric = dvsIn.readVInt();
        for (var i = 0; i < numNumeric; i++) {
          final name = dvsIn.readString();
          _numericDocValues[name] = NumericDocValues.read(dvsIn);
        }
        // Binary DocValues
        final numBinary = dvsIn.readVInt();
        for (var i = 0; i < numBinary; i++) {
          final name = dvsIn.readString();
          _binaryDocValues[name] = BinaryDocValues.read(dvsIn);
        }
        // Sorted Set DocValues
        final numSortedSet = dvsIn.readVInt();
        for (var i = 0; i < numSortedSet; i++) {
          final name = dvsIn.readString();
          _sortedSetDocValues[name] = SortedSetDocValues.read(dvsIn);
        }
      } finally {
        dvsIn.close();
      }
    }

    // 5. Load Vector Indices (.cbl_hns) if present
    if (directory.fileExists('$segName.cbl_hns')) {
      final hnsIn = directory.openInput('$segName.cbl_hns');
      try {
        final numVectorFields = hnsIn.readVInt();
        for (var i = 0; i < numVectorFields; i++) {
          final vIndex = VectorIndex.load(hnsIn);
          _vectorIndices[vIndex.fieldName] = vIndex;
        }
      } finally {
        hnsIn.close();
      }
    }
  }

  /// Number of live, non-deleted documents in this segment.
  int get numDocs => info.maxDoc - deletionVector.numDeletions;

  /// Maximum internal document ID in this segment.
  int get maxDoc => info.maxDoc;

  /// Checks if [docId] is live (not deleted).
  bool isLive(int docId) => !deletionVector.isDeleted(docId);

  /// Retrieves postings reader for a given field and term. Returns null if term not found.
  PostingsReader? postings(String field, String term) {
    _checkOpen();
    final fst = _fieldFsts[field];
    if (fst == null) return null;

    final offset = fst.getString(term);
    if (offset == null || _posInput == null) return null;

    final inputClone = _posInput!.clone();
    return PostingsReader.open(inputClone, offset);
  }

  /// Retrieves FST dictionary for given field, or null if field not indexed.
  Fst? getFst(String field) => _fieldFsts[field];

  /// Retrieves columnar NumericDocValues for given field.
  NumericDocValues? getNumericDocValues(String field) =>
      _numericDocValues[field];

  /// Retrieves columnar BinaryDocValues for given field.
  BinaryDocValues? getBinaryDocValues(String field) => _binaryDocValues[field];

  /// Retrieves columnar SortedSetDocValues for given field.
  SortedSetDocValues? getSortedSetDocValues(String field) =>
      _sortedSetDocValues[field];

  /// Retrieves HNSW vector index for given field.
  VectorIndex? getVectorIndex(String field) => _vectorIndices[field];

  /// Retrieves stored fields document JSON map for [docId].
  Map<String, dynamic> document(int docId) {
    _checkOpen();
    if (_storedFieldsReader == null) {
      throw StateError('Stored fields reader not initialized for segment ${info.name}');
    }
    return _storedFieldsReader!.getDocument(docId);
  }

  /// Closes all open segment files.
  void close() {
    if (!_closed) {
      _posInput?.close();
      _storedFieldsReader?.close();
      _closed = true;
    }
  }

  void _checkOpen() {
    if (_closed) throw StateError('SegmentReader for ${info.name} is closed');
  }
}
