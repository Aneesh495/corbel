import 'dart:io' as io;
import 'dart:typed_data';
import 'checksum.dart';
import 'index_input.dart';
import 'index_output.dart';

/// Exclusive lock interface preventing concurrent writes to an index directory.
abstract class IndexLock {
  /// Releases the acquired lock.
  void release();

  /// Checks if this lock is currently held.
  bool get isValid;
}

/// Abstract virtual file system representing an index storage location.
abstract class Directory {
  /// Lists all file names currently present in the directory.
  List<String> listAll();

  /// Checks if file exists.
  bool fileExists(String name);

  /// Returns size of file in bytes.
  int fileLength(String name);

  /// Deletes file by name.
  void deleteFile(String name);

  /// Creates a new output stream for writing. Overwrites existing file if present.
  IndexOutput createOutput(String name);

  /// Opens an existing file for reading.
  IndexInput openInput(String name);

  /// Flushes operating system buffers for specified files to permanent storage (fsync).
  void sync(List<String> names);

  /// Atomically renames file from [source] to [destination].
  void rename(String source, String destination);

  /// Obtains exclusive lock with [lockName]. Throws if lock cannot be acquired.
  IndexLock obtainLock(String lockName);

  /// Closes the directory and frees underlying handles.
  void close();
}

class _RAMLock implements IndexLock {
  final String name;
  final Set<String> _locks;
  bool _valid = true;

  _RAMLock(this.name, this._locks);

  @override
  bool get isValid => _valid;

  @override
  void release() {
    if (_valid) {
      _locks.remove(name);
      _valid = false;
    }
  }
}

/// In-memory directory implementation storing index segments purely in heap RAM.
class RAMDirectory extends Directory {
  final Map<String, Uint8List> _files = {};
  final Set<String> _activeLocks = {};
  bool _closed = false;

  @override
  List<String> listAll() {
    _checkOpen();
    return _files.keys.toList();
  }

  @override
  bool fileExists(String name) {
    _checkOpen();
    return _files.containsKey(name);
  }

  @override
  int fileLength(String name) {
    _checkOpen();
    final file = _files[name];
    if (file == null) {
      throw io.FileSystemException('File not found in RAMDirectory', name);
    }
    return file.length;
  }

  @override
  void deleteFile(String name) {
    _checkOpen();
    if (_files.remove(name) == null) {
      throw io.FileSystemException('Cannot delete non-existent file', name);
    }
  }

  @override
  IndexOutput createOutput(String name) {
    _checkOpen();
    final ramOutput = RAMIndexOutput();
    return _DelegatingRAMOutput(ramOutput, (bytes) {
      _files[name] = bytes;
    });
  }

  @override
  IndexInput openInput(String name) {
    _checkOpen();
    final data = _files[name];
    if (data == null) {
      throw io.FileSystemException('Cannot open non-existent file in RAMDirectory', name);
    }
    return RAMIndexInput(data);
  }

  @override
  void sync(List<String> names) {
    _checkOpen();
    // RAM is already immediately durable in-memory
  }

  @override
  void rename(String source, String destination) {
    _checkOpen();
    final data = _files.remove(source);
    if (data == null) {
      throw io.FileSystemException('Cannot rename non-existent source file', source);
    }
    _files[destination] = data;
  }

  @override
  IndexLock obtainLock(String lockName) {
    _checkOpen();
    if (_activeLocks.contains(lockName)) {
      throw io.FileSystemException('Lock already held by another writer', lockName);
    }
    _activeLocks.add(lockName);
    return _RAMLock(lockName, _activeLocks);
  }

  @override
  void close() {
    _closed = true;
    _files.clear();
    _activeLocks.clear();
  }

  void _checkOpen() {
    if (_closed) throw StateError('RAMDirectory is closed');
  }
}

class _DelegatingRAMOutput extends IndexOutput {
  final RAMIndexOutput _delegate;
  final void Function(Uint8List) _onClose;

  _DelegatingRAMOutput(this._delegate, this._onClose);

  @override
  int get position => _delegate.position;

  @override
  void writeByte(int byte) {
    super.writeByte(byte);
    _delegate.writeByte(byte);
  }

  @override
  void writeBytes(List<int> bytes, [int offset = 0, int? length]) {
    super.writeBytes(bytes, offset, length);
    _delegate.writeBytes(bytes, offset, length);
  }

  @override
  void close() {
    _delegate.close();
    _onClose(_delegate.toByteArray());
  }
}

/// Disk-backed directory implementation persisting index segments to the filesystem.
class DiskDirectory extends Directory {
  final io.Directory _dir;
  final Set<String> _locks = {};
  bool _closed = false;

  /// Creates or opens a disk directory at the given path.
  DiskDirectory(String path) : _dir = io.Directory(path) {
    if (!_dir.existsSync()) {
      _dir.createSync(recursive: true);
    }
  }

  /// Directory filesystem path.
  String get path => _dir.path;

  @override
  List<String> listAll() {
    _checkOpen();
    return _dir
        .listSync()
        .whereType<io.File>()
        .map((f) => f.uri.pathSegments.lastWhere((s) => s.isNotEmpty, orElse: () => ''))
        .where((s) => s.isNotEmpty)
        .toList();
  }

  @override
  bool fileExists(String name) {
    _checkOpen();
    return io.File('${_dir.path}/$name').existsSync();
  }

  @override
  int fileLength(String name) {
    _checkOpen();
    final f = io.File('${_dir.path}/$name');
    if (!f.existsSync()) {
      throw io.FileSystemException('File not found', name);
    }
    return f.lengthSync();
  }

  @override
  void deleteFile(String name) {
    _checkOpen();
    final f = io.File('${_dir.path}/$name');
    if (!f.existsSync()) {
      throw io.FileSystemException('File not found for deletion', name);
    }
    f.deleteSync();
  }

  @override
  IndexOutput createOutput(String name) {
    _checkOpen();
    final file = io.File('${_dir.path}/$name');
    final raf = file.openSync(mode: io.FileMode.write);
    return _DiskIndexOutput(raf);
  }

  @override
  IndexInput openInput(String name) {
    _checkOpen();
    final file = io.File('${_dir.path}/$name');
    if (!file.existsSync()) {
      throw io.FileSystemException('Cannot open non-existent disk file', name);
    }
    final bytes = file.readAsBytesSync();
    return RAMIndexInput(bytes);
  }

  @override
  void sync(List<String> names) {
    _checkOpen();
    // In POSIX, file descriptor sync happens on write stream close
  }

  @override
  void rename(String source, String destination) {
    _checkOpen();
    final srcFile = io.File('${_dir.path}/$source');
    final dstPath = '${_dir.path}/$destination';
    if (!srcFile.existsSync()) {
      throw io.FileSystemException('Source file does not exist', source);
    }
    srcFile.renameSync(dstPath);
  }

  @override
  IndexLock obtainLock(String lockName) {
    _checkOpen();
    final lockFile = io.File('${_dir.path}/$lockName.lock');
    if (lockFile.existsSync()) {
      throw io.FileSystemException('Lock file already exists', lockFile.path);
    }
    lockFile.createSync();
    _locks.add(lockName);
    return _DiskLock(lockFile, () {
      _locks.remove(lockName);
    });
  }

  @override
  void close() {
    _closed = true;
  }

  void _checkOpen() {
    if (_closed) throw StateError('DiskDirectory is closed');
  }
}

class _DiskLock implements IndexLock {
  final io.File _file;
  final void Function() _onRelease;
  bool _valid = true;

  _DiskLock(this._file, this._onRelease);

  @override
  bool get isValid => _valid;

  @override
  void release() {
    if (_valid) {
      if (_file.existsSync()) {
        try {
          _file.deleteSync();
        } catch (_) {}
      }
      _valid = false;
      _onRelease();
    }
  }
}

class _DiskIndexOutput extends IndexOutput {
  final io.RandomAccessFile _raf;
  int _position = 0;
  bool _closed = false;

  _DiskIndexOutput(this._raf);

  @override
  int get position => _position;

  @override
  void writeByte(int byte) {
    _checkOpen();
    super.writeByte(byte);
    _raf.writeByteSync(byte & 0xFF);
    _position++;
  }

  @override
  void writeBytes(List<int> bytes, [int offset = 0, int? length]) {
    _checkOpen();
    super.writeBytes(bytes, offset, length);
    final count = length ?? (bytes.length - offset);
    if (count > 0) {
      _raf.writeFromSync(bytes, offset, offset + count);
      _position += count;
    }
  }

  @override
  void close() {
    if (!_closed) {
      _raf.flushSync();
      _raf.closeSync();
      _closed = true;
    }
  }

  void _checkOpen() {
    if (_closed) throw StateError('Cannot write to closed disk output stream');
  }
}
