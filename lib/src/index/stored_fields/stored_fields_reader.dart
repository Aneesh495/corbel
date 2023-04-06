import 'dart:convert';
import '../../storage/index_input.dart';

/// Block-compressed document stored fields reader providing O(1) document retrieval.
class StoredFieldsReader {
  final IndexInput indexIn;
  final IndexInput dataIn;
  final int docCount;

  final List<int> _blockOffsets;
  final List<int> _docIndices;

  StoredFieldsReader._({
    required this.indexIn,
    required this.dataIn,
    required this.docCount,
    required List<int> blockOffsets,
    required List<int> docIndices,
  })  : _blockOffsets = blockOffsets,
        _docIndices = docIndices;

  /// Opens stored fields reader from index and data streams.
  factory StoredFieldsReader.open({
    required IndexInput indexIn,
    required IndexInput dataIn,
    required int docCount,
  }) {
    final blockOffsets = List<int>.filled(docCount, 0);
    final docIndices = List<int>.filled(docCount, 0);

    for (var i = 0; i < docCount; i++) {
      blockOffsets[i] = indexIn.readVLong();
      docIndices[i] = indexIn.readVInt();
    }

    return StoredFieldsReader._(
      indexIn: indexIn,
      dataIn: dataIn,
      docCount: docCount,
      blockOffsets: blockOffsets,
      docIndices: docIndices,
    );
  }

  /// Retrieves document JSON map for [docId].
  Map<String, dynamic> getDocument(int docId) {
    if (docId < 0 || docId >= docCount) {
      throw RangeError.index(docId, this, 'docId', 'Document ID out of bounds', docCount);
    }

    final blockOffset = _blockOffsets[docId];
    final docIdxInBlock = _docIndices[docId];

    final input = dataIn.clone();
    input.seek(blockOffset);

    final numDocsInBlock = input.readVInt();
    for (var i = 0; i < numDocsInBlock; i++) {
      final len = input.readVInt();
      if (i == docIdxInBlock) {
        final bytes = input.readBytes(len);
        final jsonStr = utf8.decode(bytes);
        return jsonDecode(jsonStr) as Map<String, dynamic>;
      } else {
        input.seek(input.position + len);
      }
    }

    throw StateError('Failed to locate docId $docId in stored fields block');
  }

  /// Closes underlying streams.
  void close() {
    indexIn.close();
    dataIn.close();
  }
}
