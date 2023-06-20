import 'dart:math' as math;
import 'dart:typed_data';
import '../index_input.dart';
import 'buffer_pool_manager.dart';
import 'page_models.dart';

/// IndexInput reading through a managed [BufferPoolManager] with automatic page lifecycle.
class PagedIndexInput extends IndexInput {
  final BufferPoolManager bufferPool;
  final String fileName;
  final int _fileLength;

  int _position = 0;
  PageFrame? _currentFrame;
  int _currentPageNumber = -1;

  PagedIndexInput({
    required this.bufferPool,
    required this.fileName,
    required int fileLength,
  }) : _fileLength = fileLength;

  @override
  int get position => _position;

  @override
  int get length => _fileLength;

  @override
  int readByte() {
    if (_position >= _fileLength) {
      throw StateError('Attempt to read past end of file $fileName: pos=$_position, len=$_fileLength');
    }

    final pageNum = _position ~/ bufferPool.pageSize;
    final pageOffset = _position % bufferPool.pageSize;

    _ensurePage(pageNum);
    final b = _currentFrame!.data[pageOffset];
    _position++;
    return b;
  }

  @override
  Uint8List readBytes(int count) {
    if (_position + count > _fileLength) {
      throw StateError('Read past end of file $fileName: need $count, remain $remaining');
    }

    final buffer = Uint8List(count);
    var bytesRead = 0;

    while (bytesRead < count) {
      final pageNum = _position ~/ bufferPool.pageSize;
      final pageOffset = _position % bufferPool.pageSize;
      _ensurePage(pageNum);

      final bytesInCurrentPage = bufferPool.pageSize - pageOffset;
      final toRead = math.min(count - bytesRead, bytesInCurrentPage);

      buffer.setRange(
        bytesRead,
        bytesRead + toRead,
        _currentFrame!.data.sublist(pageOffset, pageOffset + toRead),
      );

      _position += toRead;
      bytesRead += toRead;
    }

    return buffer;
  }

  @override
  void seek(int targetPosition) {
    if (targetPosition < 0 || targetPosition > _fileLength) {
      throw RangeError('Seek out of bounds: $targetPosition (file length: $_fileLength)');
    }
    _position = targetPosition;
  }

  void _ensurePage(int pageNumber) {
    if (_currentPageNumber == pageNumber && _currentFrame != null) {
      return;
    }

    // Unpin previous frame
    if (_currentFrame != null && _currentFrame!.pageId != null) {
      bufferPool.unpinPage(_currentFrame!.pageId!, isDirty: false);
    }

    _currentPageNumber = pageNumber;
    _currentFrame = bufferPool.fetchPage(PageId(fileName, pageNumber));
  }

  @override
  IndexInput slice(String description, int offset, int count) {
    if (offset < 0 || count < 0 || offset + count > _fileLength) {
      throw RangeError('Slice range [$offset, ${offset + count}) exceeds stream length $_fileLength');
    }
    return _PagedSliceInput(
      parent: this,
      baseOffset: offset,
      sliceLength: count,
    );
  }

  @override
  IndexInput clone() {
    return PagedIndexInput(
      bufferPool: bufferPool,
      fileName: fileName,
      fileLength: _fileLength,
    )..seek(_position);
  }

  @override
  void close() {
    if (_currentFrame != null && _currentFrame!.pageId != null) {
      bufferPool.unpinPage(_currentFrame!.pageId!, isDirty: false);
      _currentFrame = null;
      _currentPageNumber = -1;
    }
  }
}

class _PagedSliceInput extends IndexInput {
  final PagedIndexInput parent;
  final int baseOffset;
  final int sliceLength;
  int _slicePos = 0;

  _PagedSliceInput({
    required this.parent,
    required this.baseOffset,
    required this.sliceLength,
  });

  @override
  int get position => _slicePos;

  @override
  int get length => sliceLength;

  @override
  int readByte() {
    if (_slicePos >= sliceLength) {
      throw StateError('Attempt to read past end of slice');
    }
    parent.seek(baseOffset + _slicePos);
    final b = parent.readByte();
    _slicePos++;
    return b;
  }

  @override
  Uint8List readBytes(int count) {
    if (_slicePos + count > sliceLength) {
      throw StateError('Read past end of slice: need $count, remain ${sliceLength - _slicePos}');
    }
    parent.seek(baseOffset + _slicePos);
    final data = parent.readBytes(count);
    _slicePos += count;
    return data;
  }

  @override
  void seek(int targetPosition) {
    if (targetPosition < 0 || targetPosition > sliceLength) {
      throw RangeError('Seek out of slice bounds: $targetPosition');
    }
    _slicePos = targetPosition;
  }

  @override
  IndexInput slice(String description, int offset, int count) {
    if (offset < 0 || count < 0 || offset + count > sliceLength) {
      throw RangeError('Nested slice out of bounds');
    }
    return _PagedSliceInput(
      parent: parent,
      baseOffset: baseOffset + offset,
      sliceLength: count,
    );
  }

  @override
  IndexInput clone() {
    return _PagedSliceInput(
      parent: parent.clone() as PagedIndexInput,
      baseOffset: baseOffset,
      sliceLength: sliceLength,
    )..seek(_slicePos);
  }

  @override
  void close() {}
}
