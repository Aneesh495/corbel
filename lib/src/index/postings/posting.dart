import 'dart:typed_data';

/// Inverted index posting entry for a single term occurrence within a document.
class Posting {
  /// Internal document ID (32-bit non-negative integer).
  final int docId;

  /// Term frequency within this document.
  final int freq;

  /// Sorted token positions of the term occurrences within document.
  final List<int> positions;

  /// Start character offsets for each occurrence (for highlighting).
  final List<int> startOffsets;

  /// End character offsets for each occurrence (for highlighting).
  final List<int> endOffsets;

  /// Optional arbitrary binary payload associated with occurrence.
  final Uint8List? payload;

  const Posting({
    required this.docId,
    required this.freq,
    this.positions = const [],
    this.startOffsets = const [],
    this.endOffsets = const [],
    this.payload,
  });

  @override
  String toString() =>
      'Posting(docId: $docId, freq: $freq, pos: ${positions.length})';
}
