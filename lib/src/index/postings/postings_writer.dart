import '../../storage/byte_buffer.dart';
import '../../storage/index_output.dart';
import '../../storage/vbyte.dart';
import 'posting.dart';

/// Single skip list pointer entry.
class SkipEntry {
  final int docId;
  final int offset;

  const SkipEntry(this.docId, this.offset);
}

/// Writer serializing postings lists with delta-gap encoding and skip lists.
class PostingsWriter {
  /// Skip interval: a skip entry is emitted every [skipInterval] documents.
  final int skipInterval;
  final bool storePositions;
  final bool storeOffsets;

  PostingsWriter({
    this.skipInterval = 16,
    this.storePositions = true,
    this.storeOffsets = true,
  });

  /// Writes a complete postings list into the provided IndexOutput, returning starting offset.
  int writePostingsList(IndexOutput out, List<Posting> postings) {
    final startOffset = out.position;
    final docCount = postings.length;

    VByteCodec.writeVInt(out, docCount);
    if (docCount == 0) return startOffset;

    // Build skip list if docCount > skipInterval
    final skipEntries = <SkipEntry>[];
    final postingsBuffer = ByteBufferWriter();

    var prevDocId = 0;
    for (var i = 0; i < docCount; i++) {
      if (i > 0 && (i % skipInterval) == 0) {
        skipEntries.add(SkipEntry(postings[i].docId, postingsBuffer.position));
      }

      final p = postings[i];
      final docGap = p.docId - prevDocId;
      VByteCodec.writeVInt(postingsBuffer, docGap);
      VByteCodec.writeVInt(postingsBuffer, p.freq);

      if (storePositions && p.positions.isNotEmpty) {
        var prevPos = 0;
        for (var j = 0; j < p.positions.length; j++) {
          final pos = p.positions[j];
          final posGap = pos - prevPos;
          VByteCodec.writeVInt(postingsBuffer, posGap);
          prevPos = pos;

          if (storeOffsets && j < p.startOffsets.length && j < p.endOffsets.length) {
            VByteCodec.writeVInt(postingsBuffer, p.startOffsets[j]);
            VByteCodec.writeVInt(postingsBuffer, p.endOffsets[j] - p.startOffsets[j]);
          }
        }
      }

      prevDocId = p.docId;
    }

    // Write skip list table
    VByteCodec.writeVInt(out, skipEntries.length);
    for (final skip in skipEntries) {
      VByteCodec.writeVInt(out, skip.docId);
      VByteCodec.writeVInt(out, skip.offset);
    }

    // Write raw postings byte buffer
    final rawPostings = postingsBuffer.toBytes();
    VByteCodec.writeVInt(out, rawPostings.length);
    out.writeBytes(rawPostings);

    return startOffset;
  }
}
