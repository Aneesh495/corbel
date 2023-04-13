import 'dart:typed_data';
import '../../storage/byte_buffer.dart';
import '../../storage/index_input.dart';
import '../../storage/vbyte.dart';
import 'postings_writer.dart';

/// Reader iterating through a postings list with leapfrog skip list acceleration.
class PostingsReader {
  /// Sentinel document ID returned when the postings list is exhausted.
  static const int noMoreDocs = 0x7FFFFFFF;

  final int docCount;
  final List<SkipEntry> _skipList;
  final ByteBufferReader _reader;
  final bool storePositions;
  final bool storeOffsets;

  /// Returns the skip list associated with this postings list.
  List<SkipEntry> get skipList => _skipList;

  int _currentDocId = -1;
  int _currentFreq = 0;
  List<int> _currentPositions = const [];
  List<int> _currentStartOffsets = const [];
  List<int> _currentEndOffsets = const [];
  int _docIndex = -1;

  PostingsReader._({
    required this.docCount,
    required List<SkipEntry> skipList,
    required ByteBufferReader reader,
    required this.storePositions,
    required this.storeOffsets,
  })  : _skipList = skipList,
        _reader = reader;

  /// Initializes a PostingsReader positioned at [offset] in [input].
  factory PostingsReader.open(
    IndexInput input,
    int offset, {
    bool storePositions = true,
    bool storeOffsets = true,
  }) {
    input.seek(offset);
    final docCount = input.readVInt();
    if (docCount == 0) {
      return PostingsReader._(
        docCount: 0,
        skipList: const [],
        reader: ByteBufferReader(Uint8List(0)),
        storePositions: storePositions,
        storeOffsets: storeOffsets,
      );
    }

    // Read skip list
    final numSkips = input.readVInt();
    final skipList = <SkipEntry>[];
    for (var i = 0; i < numSkips; i++) {
      final docId = input.readVInt();
      final skipOffset = input.readVInt();
      skipList.add(SkipEntry(docId, skipOffset));
    }

    final dataLen = input.readVInt();
    final rawData = input.readBytes(dataLen);

    return PostingsReader._(
      docCount: docCount,
      skipList: skipList,
      reader: ByteBufferReader(rawData),
      storePositions: storePositions,
      storeOffsets: storeOffsets,
    );
  }

  /// Current document ID.
  int get docId => _currentDocId;

  /// Current term frequency.
  int get freq => _currentFreq;

  /// Positions of term within current document.
  List<int> get positions => _currentPositions;

  /// Start offsets of term occurrences within current document.
  List<int> get startOffsets => _currentStartOffsets;

  /// End offsets of term occurrences within current document.
  List<int> get endOffsets => _currentEndOffsets;

  /// Advances to next document in postings list. Returns [noMoreDocs] if exhausted.
  int nextDoc() {
    _docIndex++;
    if (_docIndex >= docCount) {
      _currentDocId = noMoreDocs;
      return noMoreDocs;
    }

    final docGap = VByteCodec.readVInt(_reader);
    if (_docIndex == 0) {
      _currentDocId = docGap;
    } else {
      _currentDocId += docGap;
    }

    _currentFreq = VByteCodec.readVInt(_reader);

    if (storePositions && _currentFreq > 0) {
      final posList = List<int>.filled(_currentFreq, 0);
      final startList = storeOffsets ? List<int>.filled(_currentFreq, 0) : const <int>[];
      final endList = storeOffsets ? List<int>.filled(_currentFreq, 0) : const <int>[];

      var prevPos = 0;
      for (var i = 0; i < _currentFreq; i++) {
        final posGap = VByteCodec.readVInt(_reader);
        prevPos += posGap;
        posList[i] = prevPos;

        if (storeOffsets) {
          final start = VByteCodec.readVInt(_reader);
          final len = VByteCodec.readVInt(_reader);
          startList[i] = start;
          endList[i] = start + len;
        }
      }
      _currentPositions = posList;
      _currentStartOffsets = startList;
      _currentEndOffsets = endList;
    } else {
      _currentPositions = const [];
      _currentStartOffsets = const [];
      _currentEndOffsets = const [];
    }

    return _currentDocId;
  }

  /// Leaps forward to the first document with docId >= [target].
  int advance(int target) {
    if (_currentDocId >= target) return _currentDocId;

    // Sequential step through documents until >= target
    while (nextDoc() < target) {
      if (_currentDocId == noMoreDocs) break;
    }

    return _currentDocId;
  }
}
