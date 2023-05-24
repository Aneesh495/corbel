import 'dart:async';
import 'dart:isolate';

/// Message sent to worker isolate to execute a computation.
class _WorkerTask<T> {
  final int id;
  final FutureOr<T> Function() computation;
  final SendPort replyPort;

  _WorkerTask(this.id, this.computation, this.replyPort);
}

/// Message received from worker isolate with computation result or error.
class _WorkerResponse<T> {
  final int id;
  final T? result;
  final Object? error;
  final StackTrace? stackTrace;

  _WorkerResponse(this.id, {this.result, this.error, this.stackTrace});
}

/// Single managed background isolate worker.
class _IsolateWorker {
  final Isolate isolate;
  final SendPort taskPort;
  final ReceivePort responsePort;
  bool isBusy = false;

  _IsolateWorker({
    required this.isolate,
    required this.taskPort,
    required this.responsePort,
  });
}

/// Isolate worker pool for multi-core parallel segment search and background indexing.
class IsolateWorkerPool {
  final int size;
  final List<_IsolateWorker> _workers = [];
  final List<void Function()> _queue = [];
  int _taskIdSeq = 0;
  bool _closed = false;

  IsolateWorkerPool._(this.size);

  /// Spawns a new worker pool with [size] background isolates (defaults to 4).
  static Future<IsolateWorkerPool> create({int size = 4}) async {
    final pool = IsolateWorkerPool._(size);
    for (var i = 0; i < size; i++) {
      final worker = await pool._spawnWorker();
      pool._workers.add(worker);
    }
    return pool;
  }

  Future<_IsolateWorker> _spawnWorker() async {
    final initPort = ReceivePort();
    final isolate = await Isolate.spawn(_workerEntry, initPort.sendPort);
    final taskPort = await initPort.first as SendPort;
    final responsePort = ReceivePort();

    return _IsolateWorker(
      isolate: isolate,
      taskPort: taskPort,
      responsePort: responsePort,
    );
  }

  static void _workerEntry(SendPort sendPort) {
    final commandPort = ReceivePort();
    sendPort.send(commandPort.sendPort);

    commandPort.listen((message) async {
      if (message is _WorkerTask) {
        try {
          final res = await message.computation();
          message.replyPort.send(_WorkerResponse(message.id, result: res));
        } catch (err, stack) {
          message.replyPort.send(_WorkerResponse<dynamic>(message.id, error: err, stackTrace: stack));
        }
      } else if (message == 'shutdown') {
        commandPort.close();
      }
    });
  }

  /// Dispatches a closure computation to the next available worker isolate.
  Future<T> submit<T>(FutureOr<T> Function() computation) {
    _checkOpen();
    final completer = Completer<T>();
    final taskId = _taskIdSeq++;

    void schedule() {
      final worker = _workers.firstWhere(
        (w) => !w.isBusy,
        orElse: () => _workers.first,
      );

      worker.isBusy = true;
      final replyPort = ReceivePort();

      StreamSubscription<dynamic>? sub;
      sub = replyPort.listen((response) {
        if (response is _WorkerResponse) {
          if (response.id == taskId) {
            sub?.cancel();
            replyPort.close();
            worker.isBusy = false;

            if (response.error != null) {
              completer.completeError(response.error!, response.stackTrace);
            } else {
              completer.complete(response.result as T);
            }

            // Process next queued task
            if (_queue.isNotEmpty) {
              final nextTask = _queue.removeAt(0);
              nextTask();
            }
          }
        }
      });

      worker.taskPort.send(_WorkerTask(taskId, computation, replyPort.sendPort));
    }

    final hasIdleWorker = _workers.any((w) => !w.isBusy);
    if (hasIdleWorker) {
      schedule();
    } else {
      _queue.add(schedule);
    }

    return completer.future;
  }

  /// Concurrently executes a transformation across [items] in parallel over worker isolates.
  Future<List<O>> parallelMap<I, O>(
    List<I> items,
    FutureOr<O> Function(I item) transform,
  ) async {
    final futures = items.map((item) => submit(() => transform(item)));
    return Future.wait(futures);
  }

  /// Shuts down all background isolates and cleans up ports.
  void close() {
    if (!_closed) {
      for (final w in _workers) {
        w.taskPort.send('shutdown');
        w.isolate.kill(priority: Isolate.immediate);
        w.responsePort.close();
      }
      _workers.clear();
      _queue.clear();
      _closed = true;
    }
  }

  void _checkOpen() {
    if (_closed) throw StateError('IsolateWorkerPool is closed');
  }
}
