import 'dart:typed_data';
import '../directory.dart';
import 'page_models.dart';
import 'replacer.dart';

/// Performance statistics for the buffer pool manager.
class BufferPoolStats {
  final int hits;
  final int misses;
  final int evictions;
  final int flushes;
  final int poolSize;
  final int pageSize;

  const BufferPoolStats({
    required this.hits,
    required this.misses,
    required this.evictions,
    required this.flushes,
    required this.poolSize,
    required this.pageSize,
  });

  double get hitRatio =>
      (hits + misses) == 0 ? 0.0 : hits / (hits + misses);

  Map<String, dynamic> toJson() => {
        'hits': hits,
        'misses': misses,
        'evictions': evictions,
        'flushes': flushes,
        'hit_ratio': hitRatio,
        'pool_size': poolSize,
        'page_size': pageSize,
      };

  @override
  String toString() =>
      'BufferPoolStats(hits: $hits, misses: $misses, hitRatio: ${(hitRatio * 100).toStringAsFixed(1)}%, evictions: $evictions)';
}

/// Buffer pool manager mediating memory frames and disk files.
class BufferPoolManager {
  final Directory directory;
  final int poolSize;
  final int pageSize;
  final Replacer replacer;

  late final List<PageFrame> _frames;
  final Map<PageId, int> _pageTable = {};
  final List<int> _freeList = [];

  int _hits = 0;
  int _misses = 0;
  int _evictions = 0;
  int _flushes = 0;
  bool _closed = false;

  BufferPoolManager({
    required this.directory,
    this.poolSize = 64,
    this.pageSize = 4096,
    Replacer? replacer,
  }) : replacer = replacer ?? TwoQueueReplacer(poolSize) {
    _frames = List.generate(
      poolSize,
      (i) => PageFrame(frameId: i, pageSize: pageSize),
    );
    for (var i = 0; i < poolSize; i++) {
      _freeList.add(i);
    }
  }

  BufferPoolStats get stats => BufferPoolStats(
        hits: _hits,
        misses: _misses,
        evictions: _evictions,
        flushes: _flushes,
        poolSize: poolSize,
        pageSize: pageSize,
      );

  /// Fetches a page into memory and pins its frame.
  PageFrame fetchPage(PageId pageId) {
    _checkNotClosed();

    // 1. Check if page is already cached in memory
    final frameId = _pageTable[pageId];
    if (frameId != null) {
      _hits++;
      final frame = _frames[frameId];
      frame.pinCount++;
      replacer.recordAccess(frameId);
      replacer.pin(frameId);
      return frame;
    }

    _misses++;

    // 2. Obtain a free frame or select an eviction victim
    final targetFrameId = _allocateFrame();
    final frame = _frames[targetFrameId];

    // If frame held a previous page, clean it up
    if (frame.pageId != null) {
      if (frame.isDirty) {
        _writeFrameToDisk(frame);
      }
      _pageTable.remove(frame.pageId);
      frame.clear();
    }

    // 3. Bind frame to new page
    frame.reset(pageId);
    _readPageFromDisk(pageId, frame.data);

    _pageTable[pageId] = targetFrameId;
    replacer.pin(targetFrameId);
    return frame;
  }

  /// Decrements pin count and optionally marks the page frame dirty.
  void unpinPage(PageId pageId, {bool isDirty = false}) {
    _checkNotClosed();

    final frameId = _pageTable[pageId];
    if (frameId == null) return;

    final frame = _frames[frameId];
    if (isDirty) {
      frame.isDirty = true;
    }

    if (frame.pinCount > 0) {
      frame.pinCount--;
      if (frame.pinCount == 0) {
        replacer.unpin(frameId);
      }
    }
  }

  /// Flushes a specific page to storage if it is marked dirty.
  void flushPage(PageId pageId) {
    _checkNotClosed();

    final frameId = _pageTable[pageId];
    if (frameId == null) return;

    final frame = _frames[frameId];
    if (frame.isDirty) {
      _writeFrameToDisk(frame);
      frame.isDirty = false;
    }
  }

  /// Flushes all dirty cached pages across all files.
  void flushAllPages() {
    _checkNotClosed();

    for (final frame in _frames) {
      if (frame.pageId != null && frame.isDirty) {
        _writeFrameToDisk(frame);
        frame.isDirty = false;
      }
    }
  }

  int _allocateFrame() {
    if (_freeList.isNotEmpty) {
      return _freeList.removeLast();
    }

    final victimId = replacer.victim();
    if (victimId == null) {
      throw StateError(
          'Buffer pool exhausted: all $poolSize frames are currently pinned');
    }

    _evictions++;
    return victimId;
  }

  void _readPageFromDisk(PageId pageId, Uint8List buffer) {
    if (!directory.fileExists(pageId.fileName)) {
      return; // New empty page
    }

    final input = directory.openInput(pageId.fileName);
    try {
      final offset = pageId.pageNumber * pageSize;
      if (offset >= input.length) {
        return; // Empty trailing page
      }

      input.seek(offset);
      final bytesToRead = (offset + pageSize <= input.length)
          ? pageSize
          : (input.length - offset);

      final readData = input.readBytes(bytesToRead);
      buffer.setRange(0, bytesToRead, readData);
    } finally {
      input.close();
    }
  }

  void _writeFrameToDisk(PageFrame frame) {
    final pageId = frame.pageId;
    if (pageId == null) return;

    _flushes++;
    final fileName = pageId.fileName;
    final offset = pageId.pageNumber * pageSize;

    // Read full file content, patch page frame range, and rewrite
    Uint8List fullFile;
    if (directory.fileExists(fileName)) {
      final input = directory.openInput(fileName);
      try {
        final existing = input.readBytes(input.length);
        if (existing.length < offset + pageSize) {
          fullFile = Uint8List(offset + pageSize);
          fullFile.setRange(0, existing.length, existing);
        } else {
          fullFile = Uint8List.fromList(existing);
        }
      } finally {
        input.close();
      }
    } else {
      fullFile = Uint8List(offset + pageSize);
    }

    fullFile.setRange(offset, offset + pageSize, frame.data);

    final output = directory.createOutput(fileName);
    try {
      output.writeBytes(fullFile);
    } finally {
      output.close();
    }
  }

  /// Closes the buffer pool manager, writing out all pending dirty frames.
  void close() {
    if (!_closed) {
      flushAllPages();
      _closed = true;
    }
  }

  void _checkNotClosed() {
    if (_closed) {
      throw StateError('BufferPoolManager is closed');
    }
  }
}
