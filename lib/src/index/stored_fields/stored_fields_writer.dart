import 'dart:convert';
import 'dart:typed_data';
import '../../storage/index_output.dart';

/// Block-compressed document stored fields writer.
class StoredFieldsWriter {
  final IndexOutput indexOut;
  final IndexOutput dataOut;
  final List<String> _currentBlock = [];
  int _docCount = 0;
  static const int docsPerBlock = 64;

  StoredFieldsWriter({
    required this.indexOut,
    required this.dataOut,
  });

  /// Writes a document's stored field payload (JSON string).
  void writeDocument(Map<String, dynamic> docFields) {
    final jsonStr = jsonEncode(docFields);
    _currentBlock.add(jsonStr);
    _docCount++;

    if (_currentBlock.length >= docsPerBlock) {
      _flushBlock();
    }
  }

  void _flushBlock() {
    if (_currentBlock.isEmpty) return;

    final blockOffset = dataOut.position;
    final blockBytes = <Uint8List>[];
    for (final str in _currentBlock) {
      final b = utf8.encode(str);
      blockBytes.add(b is Uint8List ? b : Uint8List.fromList(b));
    }

    // Write index pointers for each doc in block
    for (var i = 0; i < _currentBlock.length; i++) {
      indexOut.writeVLong(blockOffset);
      indexOut.writeVInt(i); // doc index inside block
    }

    // Write block data payload
    dataOut.writeVInt(_currentBlock.length);
    for (final bytes in blockBytes) {
      dataOut.writeVInt(bytes.length);
      dataOut.writeBytes(bytes);
    }

    _currentBlock.clear();
  }

  /// Flushes remaining documents and finalizes stored fields.
  void close() {
    _flushBlock();
  }
}
