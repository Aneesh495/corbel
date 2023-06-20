import 'dart:typed_data';

/// Unique identifier for a page in directory storage: (fileName, pageNumber).
class PageId {
  final String fileName;
  final int pageNumber;

  const PageId(this.fileName, this.pageNumber);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PageId &&
          runtimeType == other.runtimeType &&
          fileName == other.fileName &&
          pageNumber == other.pageNumber;

  @override
  int get hashCode => Object.hash(fileName, pageNumber);

  @override
  String toString() => '$fileName#$pageNumber';
}

/// A physical memory frame inside the buffer pool.
class PageFrame {
  final int frameId;
  final int pageSize;
  final Uint8List data;

  PageId? pageId;
  int pinCount = 0;
  bool isDirty = false;
  bool isReferenced = false;

  PageFrame({required this.frameId, required this.pageSize})
      : data = Uint8List(pageSize);

  /// Checks if this frame is currently pinned by active operations.
  bool get isPinned => pinCount > 0;

  /// Resets frame state for binding to a new page.
  void reset(PageId newPageId) {
    pageId = newPageId;
    pinCount = 1;
    isDirty = false;
    isReferenced = true;
    data.fillRange(0, pageSize, 0);
  }

  /// Clears frame contents when evicted.
  void clear() {
    pageId = null;
    pinCount = 0;
    isDirty = false;
    isReferenced = false;
  }
}
