import 'dart:math' as math;
import '../index_output.dart';
import 'buffer_pool_manager.dart';
import 'page_models.dart';

/// IndexOutput writing through a managed [BufferPoolManager] with dirty page tracking.
class PagedIndexOutput extends IndexOutput {
  final BufferPoolManager bufferPool;
  final String fileName;

  int _position = 0;
  int _length = 0;
  PageFrame? _currentFrame;
  int _currentPageNumber = -1;
  bool _closed = false;

  PagedIndexOutput({
    required this.bufferPool,
    required this.fileName,
  });

  @override
  int get position => _position;

  int get length => _length;

  @override
  void writeByte(int byte) {
    _checkNotClosed();
    super.writeByte(byte); // Updates CRC32C checksum

    final pageNum = _position ~/ bufferPool.pageSize;
    final pageOffset = _position % bufferPool.pageSize;

    _ensurePage(pageNum);
    _currentFrame!.data[pageOffset] = byte & 0xFF;
    _currentFrame!.isDirty = true;

    _position++;
    if (_position > _length) {
      _length = _position;
    }
  }

  @override
  void writeBytes(List<int> bytes, [int offset = 0, int? length]) {
    _checkNotClosed();
    final count = length ?? (bytes.length - offset);
    super.writeBytes(bytes, offset, count); // Updates CRC32C checksum

    var bytesWritten = 0;
    while (bytesWritten < count) {
      final pageNum = _position ~/ bufferPool.pageSize;
      final pageOffset = _position % bufferPool.pageSize;
      _ensurePage(pageNum);

      final spaceInCurrentPage = bufferPool.pageSize - pageOffset;
      final toWrite = math.min(count - bytesWritten, spaceInCurrentPage);

      _currentFrame!.data.setRange(
        pageOffset,
        pageOffset + toWrite,
        bytes.sublist(offset + bytesWritten, offset + bytesWritten + toWrite),
      );
      _currentFrame!.isDirty = true;

      _position += toWrite;
      bytesWritten += toWrite;
      if (_position > _length) {
        _length = _position;
      }
    }
  }

  void _ensurePage(int pageNumber) {
    if (_currentPageNumber == pageNumber && _currentFrame != null) {
      return;
    }

    if (_currentFrame != null && _currentFrame!.pageId != null) {
      bufferPool.unpinPage(_currentFrame!.pageId!, isDirty: true);
    }

    _currentPageNumber = pageNumber;
    _currentFrame = bufferPool.fetchPage(PageId(fileName, pageNumber));
  }

  /// Closes stream, unpinning active frame and flushing pages to disk.
  @override
  void close() {
    if (!_closed) {
      if (_currentFrame != null && _currentFrame!.pageId != null) {
        bufferPool.unpinPage(_currentFrame!.pageId!, isDirty: true);
        _currentFrame = null;
        _currentPageNumber = -1;
      }
      bufferPool.flushAllPages();
      _closed = true;
    }
  }

  void _checkNotClosed() {
    if (_closed) {
      throw StateError('PagedIndexOutput for $fileName is closed');
    }
  }
}
