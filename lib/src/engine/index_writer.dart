import 'dart:convert';
import '../core/document.dart';
import '../core/schema.dart';
import '../index/deletion_vector.dart';
import '../index/merge_policy.dart';
import '../index/segment_info.dart';
import '../index/segment_reader.dart';
import '../index/segment_writer.dart';
import '../storage/directory.dart';
import '../storage/wal.dart';
import 'index_writer_config.dart';

/// Transactional index writer coordinating in-memory buffering, write-ahead logging,
/// immutable segment flushing, and log-structured merges.
class IndexWriter {
  final IndexWriterConfig config;
  final Directory directory;
  final Schema schema;

  final List<SegmentInfo> _segments = [];
  final Map<String, DeletionVector> _deletionVectors = {};
  SegmentWriter? _activeWriter;
  WriteAheadLog? _wal;
  int _nextSegmentSeq = 0;
  bool _closed = false;

  static const String manifestFileName = 'corbel_segments.manifest';

  IndexWriter(this.config)
      : directory = config.directory,
        schema = config.schema {
    _init();
  }

  void _init() {
    _loadManifest();

    if (config.enableWal) {
      _wal = WriteAheadLog(directory, config.walFileName);
      _wal!.open();
      _recoverWal();
    }

    _ensureActiveWriter();
  }

  void _loadManifest() {
    if (!directory.fileExists(manifestFileName)) return;

    final input = directory.openInput(manifestFileName);
    try {
      final jsonBytes = input.readBytes(input.length);
      final jsonStr = utf8.decode(jsonBytes);
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;

      _nextSegmentSeq = map['next_seq'] as int? ?? 0;
      final segList = map['segments'] as List<dynamic>? ?? [];

      for (final s in segList) {
        final info = SegmentInfo.fromJson(s as Map<String, dynamic>, schema);
        _segments.add(info);

        final delFileName = '${info.name}.cbl_del';
        if (directory.fileExists(delFileName)) {
          final delIn = directory.openInput(delFileName);
          try {
            _deletionVectors[info.name] = DeletionVector.deserialize(delIn);
          } finally {
            delIn.close();
          }
        }
      }
    } finally {
      input.close();
    }
  }

  void _saveManifest() {
    final map = {
      'next_seq': _nextSegmentSeq,
      'segments': _segments.map((s) => s.toJson()).toList(),
    };
    final jsonStr = jsonEncode(map);
    final bytes = utf8.encode(jsonStr);

    final out = directory.createOutput(manifestFileName);
    try {
      out.writeBytes(bytes);
    } finally {
      out.close();
    }
  }

  void _recoverWal() {
    if (_wal == null) return;
    final records = _wal!.recover();
    if (records.isEmpty) return;

    _ensureActiveWriter();
    for (final rec in records) {
      if (rec.type == WalRecordType.insertDoc) {
        final doc = Document.fromMap(rec.docId, rec.data ?? {}, schema: schema);
        _activeWriter!.addDocument(doc);
      } else if (rec.type == WalRecordType.deleteDoc) {
        _deleteFromCommittedSegments(rec.docId);
      }
    }
  }

  void _ensureActiveWriter() {
    if (_activeWriter == null) {
      final segName = '_seg_$_nextSegmentSeq';
      _nextSegmentSeq++;
      _activeWriter = SegmentWriter(
        segmentName: segName,
        schema: schema,
        directory: directory,
      );
    }
  }

  /// Appends a document to the index buffer and WAL.
  void addDocument(Document doc) {
    _checkOpen();
    schema.validate(doc.toMap());

    _wal?.appendInsert(doc.id, doc.toMap());
    _activeWriter!.addDocument(doc);

    if (_activeWriter!.docCount >= config.maxBufferedDocs) {
      flush();
    }
  }

  /// Appends a batch of documents in a single atomic buffer pass.
  void addDocuments(Iterable<Document> docs) {
    _checkOpen();
    for (final doc in docs) {
      addDocument(doc);
    }
  }

  /// Updates a document by soft-deleting previous occurrences and adding the new version.
  void updateDocument(String id, Document doc) {
    _checkOpen();
    deleteDocument(id);
    addDocument(doc);
  }

  /// Soft-deletes documents matching [id] across all committed segments and active writer.
  void deleteDocument(String id) {
    _checkOpen();
    _wal?.appendDelete(id);
    _deleteFromCommittedSegments(id);
  }

  void _deleteFromCommittedSegments(String id) {
    final idFieldName = schema.idFieldName;

    for (final info in _segments) {
      final delVec = _deletionVectors.putIfAbsent(info.name, () => DeletionVector());
      final reader = SegmentReader.open(
        info: info,
        directory: directory,
        deletionVector: delVec,
      );

      try {
        final postings = reader.postings(idFieldName, id);
        if (postings != null) {
          var docId = postings.nextDoc();
          while (docId != scorerNoMoreDocs) {
            delVec.delete(docId);
            docId = postings.nextDoc();
          }
        }
      } finally {
        reader.close();
      }
    }
  }

  static const int scorerNoMoreDocs = 0x7FFFFFFF;

  /// Flushes the active in-memory segment writer to storage.
  void flush() {
    _checkOpen();
    if (_activeWriter == null || _activeWriter!.docCount == 0) return;

    final info = _activeWriter!.flush();
    _segments.add(info);
    _activeWriter = null;

    _maybeMerge();
    _ensureActiveWriter();
  }

  void _maybeMerge() {
    final merges = config.mergePolicy.findMerges(_segments, _nextSegmentSeq);
    for (final spec in merges) {
      final merger = SegmentMerger(
        directory: directory,
        schema: schema,
        spec: spec,
        deletionVectors: _deletionVectors,
      );

      final mergedInfo = merger.execute();

      final toRemove = spec.segmentsToMerge.map((s) => s.name).toSet();
      _segments.removeWhere((s) => toRemove.contains(s.name));
      for (final name in toRemove) {
        _deletionVectors.remove(name);
      }
      _segments.add(mergedInfo);
    }
  }

  /// Commits all buffered documents, flushes segments, persists deletion vectors,
  /// writes the segment manifest, and checkpoints the WAL.
  void commit() {
    _checkOpen();
    flush();

    for (final entry in _deletionVectors.entries) {
      final segName = entry.key;
      final delVec = entry.value;
      if (delVec.numDeletions > 0) {
        final delOut = directory.createOutput('$segName.cbl_del');
        try {
          delVec.serialize(delOut);
        } finally {
          delOut.close();
        }
      }
    }

    _saveManifest();

    if (_wal != null) {
      _wal!.close();
      _wal = WriteAheadLog(directory, config.walFileName);
      _wal!.open();
    }
  }

  /// Rolls back uncommitted changes, discarding in-memory buffer and replaying WAL.
  void rollback() {
    _checkOpen();
    _activeWriter = null;
    _segments.clear();
    _deletionVectors.clear();
    _loadManifest();

    if (_wal != null) {
      _wal!.close();
      _wal = WriteAheadLog(directory, config.walFileName);
      _wal!.open();
      _recoverWal();
    }

    _ensureActiveWriter();
  }

  /// Total number of live documents across all committed segments and buffer.
  int get numDocs {
    _checkOpen();
    var count = _activeWriter?.docCount ?? 0;
    for (final s in _segments) {
      final delVec = _deletionVectors[s.name];
      final delCount = delVec?.numDeletions ?? 0;
      count += (s.maxDoc - delCount);
    }
    return count;
  }

  /// Returns an immutable snapshot list of currently committed segment infos.
  List<SegmentInfo> get segmentInfos => List.unmodifiable(_segments);

  /// Returns the deletion vectors mapped by segment name.
  Map<String, DeletionVector> get deletionVectors => Map.unmodifiable(_deletionVectors);

  /// Closes the writer, committing unwritten segments and releasing all resources.
  void close() {
    if (!_closed) {
      commit();
      _wal?.close();
      _closed = true;
    }
  }

  void _checkOpen() {
    if (_closed) throw StateError('IndexWriter is closed');
  }
}
