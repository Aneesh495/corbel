import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import '../storage/checksum.dart';
import '../storage/directory.dart';

/// Network sync frame types.
enum SyncFrameType {
  fileRequest(1),
  fileHeader(2),
  chunkData(3),
  fileComplete(4),
  error(5);

  final int code;
  const SyncFrameType(this.code);

  static SyncFrameType fromCode(int code) {
    for (final t in SyncFrameType.values) {
      if (t.code == code) return t;
    }
    throw FormatException('Unknown sync frame code: $code');
  }
}

/// Metadata header describing a segment file being streamed over the wire.
class SegmentFileHeader {
  final String segmentName;
  final String fileName;
  final int fileSizeBytes;
  final int expectedCrc;

  const SegmentFileHeader({
    required this.segmentName,
    required this.fileName,
    required this.fileSizeBytes,
    required this.expectedCrc,
  });
}

/// Server node broadcasting and streaming segment files to cluster replicas.
class SegmentSyncServer {
  final Directory directory;
  final int port;
  ServerSocket? _serverSocket;
  bool _closed = false;

  SegmentSyncServer({
    required this.directory,
    this.port = 9300,
  });

  /// Starts listening for incoming replica sync connections.
  Future<void> start() async {
    _serverSocket = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    _serverSocket!.listen(_handleConnection);
  }

  void _handleConnection(Socket socket) {
    final buffer = <int>[];

    socket.listen(
      (data) async {
        buffer.addAll(data);
        while (buffer.length >= 4) {
          final frameLen = (buffer[0] << 24) | (buffer[1] << 16) | (buffer[2] << 8) | buffer[3];
          if (buffer.length < 4 + frameLen) break;

          final frameBytes = buffer.sublist(4, 4 + frameLen);
          buffer.removeRange(0, 4 + frameLen);
          await _processFrame(socket, frameBytes);
        }
      },
      onError: (err) => socket.destroy(),
      onDone: () => socket.destroy(),
    );
  }

  Future<void> _processFrame(Socket socket, List<int> frameBytes) async {
    final typeCode = frameBytes[0];
    final type = SyncFrameType.fromCode(typeCode);

    if (type == SyncFrameType.fileRequest) {
      final fileName = String.fromCharCodes(frameBytes.sublist(1));
      await _streamFile(socket, fileName);
    }
  }

  Future<void> _streamFile(Socket socket, String fileName) async {
    if (!directory.fileExists(fileName)) {
      _sendError(socket, 'File not found: $fileName');
      return;
    }

    final input = directory.openInput(fileName);
    try {
      final fileLen = input.length;
      final fileBytes = input.readBytes(fileLen);

      final crc = CRC32C();
      crc.update(fileBytes);

      // Send FileHeader frame
      final headerOut = BytesBuilder();
      headerOut.addByte(SyncFrameType.fileHeader.code);
      final fnBytes = fileName.codeUnits;
      headerOut.add([fnBytes.length >> 8, fnBytes.length & 0xFF]);
      headerOut.add(fnBytes);
      final lenBytes = ByteData(8)..setInt64(0, fileLen);
      headerOut.add(Uint8List.sublistView(lenBytes));
      final crcBytes = ByteData(4)..setUint32(0, crc.value);
      headerOut.add(Uint8List.sublistView(crcBytes));

      _sendFrame(socket, headerOut.toBytes());

      // Send chunk data frames (64 KB chunks)
      const chunkSize = 64 * 1024;
      var offset = 0;
      while (offset < fileBytes.length) {
        final end = mathMin(fileBytes.length, offset + chunkSize);
        final chunk = fileBytes.sublist(offset, end);

        final chunkOut = BytesBuilder();
        chunkOut.addByte(SyncFrameType.chunkData.code);
        chunkOut.add(chunk);
        _sendFrame(socket, chunkOut.toBytes());

        offset = end;
      }

      // Send FileComplete frame
      _sendFrame(socket, [SyncFrameType.fileComplete.code]);
    } finally {
      input.close();
    }
  }

  void _sendFrame(Socket socket, List<int> payload) {
    final len = payload.length;
    final header = [
      (len >> 24) & 0xFF,
      (len >> 16) & 0xFF,
      (len >> 8) & 0xFF,
      len & 0xFF,
    ];
    socket.add(header);
    socket.add(payload);
  }

  void _sendError(Socket socket, String message) {
    final bytes = [SyncFrameType.error.code, ...message.codeUnits];
    _sendFrame(socket, bytes);
  }

  int mathMin(int a, int b) => a < b ? a : b;

  /// Stops server and closes active socket.
  Future<void> close() async {
    if (!_closed) {
      await _serverSocket?.close();
      _closed = true;
    }
  }
}

/// Client replica fetching and verifying segment streams from cluster leader.
class SegmentSyncClient {
  final Directory targetDirectory;
  final String host;
  final int port;

  SegmentSyncClient({
    required this.targetDirectory,
    this.host = '127.0.0.1',
    this.port = 9300,
  });

  /// Requests and synchronizes [fileName] from remote leader.
  Future<bool> syncFile(String fileName) async {
    final socket = await Socket.connect(host, port);
    final completer = Completer<bool>();
    final buffer = <int>[];

    final fileContentBuilder = BytesBuilder();
    var expectedCrc = 0;

    // Send FileRequest frame
    final reqBytes = [SyncFrameType.fileRequest.code, ...fileName.codeUnits];
    final len = reqBytes.length;
    socket.add([
      (len >> 24) & 0xFF,
      (len >> 16) & 0xFF,
      (len >> 8) & 0xFF,
      len & 0xFF,
    ]);
    socket.add(reqBytes);

    socket.listen(
      (data) {
        buffer.addAll(data);
        while (buffer.length >= 4) {
          final frameLen = (buffer[0] << 24) | (buffer[1] << 16) | (buffer[2] << 8) | buffer[3];
          if (buffer.length < 4 + frameLen) break;

          final frameBytes = buffer.sublist(4, 4 + frameLen);
          buffer.removeRange(0, 4 + frameLen);

          final type = SyncFrameType.fromCode(frameBytes[0]);
          if (type == SyncFrameType.fileHeader) {
            final fnLen = (frameBytes[1] << 8) | frameBytes[2];
            final crcOffset = 3 + fnLen + 8;
            final bd = ByteData.sublistView(Uint8List.fromList(frameBytes.sublist(crcOffset, crcOffset + 4)));
            expectedCrc = bd.getUint32(0);
          } else if (type == SyncFrameType.chunkData) {
            fileContentBuilder.add(frameBytes.sublist(1));
          } else if (type == SyncFrameType.fileComplete) {
            final completeBytes = fileContentBuilder.toBytes();
            final actualCrc = CRC32C();
            actualCrc.update(completeBytes);

            if (actualCrc.value != expectedCrc) {
              completer.complete(false);
            } else {
              final out = targetDirectory.createOutput(fileName);
              try {
                out.writeBytes(completeBytes);
              } finally {
                out.close();
              }
              completer.complete(true);
            }
            socket.destroy();
          } else if (type == SyncFrameType.error) {
            completer.complete(false);
            socket.destroy();
          }
        }
      },
      onError: (err) {
        if (!completer.isCompleted) completer.complete(false);
        socket.destroy();
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete(false);
      },
    );

    return completer.future;
  }
}
