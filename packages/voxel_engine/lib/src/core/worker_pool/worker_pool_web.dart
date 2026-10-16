import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;

import 'package:web/web.dart' as web;

class _QueuedJob<T> {
  _QueuedJob(this.run, this.completer);
  final T Function() run;
  final Completer<T> completer;

  void execute() {
    if (completer.isCompleted) return;
    try {
      completer.complete(run());
    } catch (e, st) {
      completer.completeError(e, st);
    }
  }
}

class _Worker {
  _Worker(this.worker);
  final web.Worker worker;
  int pending = 0;
}

/// A fixed pool of Web Workers with automatic fallback to time-sliced
/// main-thread batches when [workerScript] is null or fails to load.
class WorkerPool<TState> {
  /// Creates a pool of [workers] module Web Workers (defaulting to
  /// [defaultWorkers]).
  WorkerPool({
    required this.createState,
    this.workerScript,
    this.buildInitMessage,
    int? workers,
    this.name = 'worker',
    Object Function()? onDisposeError,
  }) : workers = workers ?? defaultWorkers,
       _onDisposeError = onDisposeError ?? (() => StateError('worker pool disposed'));

  /// Default worker count on web runtimes (capped at 8).
  static int get defaultWorkers {
    try {
      return math.min(8, workersFor(web.window.navigator.hardwareConcurrency.toInt()));
    } catch (_) {
      return 1;
    }
  }

  /// Two thirds of [cores], at least one.
  static int workersFor(int cores) => math.max(1, cores * 2 ~/ 3);

  /// Builds the fallback state on the main thread when [workerScript] is null
  /// or a worker fails to load.
  final TState Function() createState;

  /// Module worker script URL. If null, runs on the time-sliced fallback queue.
  final String? workerScript;

  /// Builds the initialization payload sent to each worker after its `'ready'`
  /// signal.
  final JSAny? Function()? buildInitMessage;

  /// Logical worker count.
  final int workers;

  /// Debug prefix for error messages.
  final String name;

  final Object Function() _onDisposeError;
  final List<_Worker> _workers = [];
  final Map<int, Completer<Object?>> _waiting = {};
  final Map<int, _Worker> _owner = {};
  int _nextId = 1;
  bool _disposed = false;

  TState? _fallbackState;
  final Queue<_QueuedJob<Object?>> _queue = Queue<_QueuedJob<Object?>>();
  Timer? _pumpTimer;

  /// Whether jobs are executing on the main-thread time-sliced fallback queue.
  bool get usesFallback => _fallbackState != null;

  /// Spawns the module workers and runs the `'ready'` -> `'init'` -> `'inited'`
  /// handshake, or initializes the main-thread fallback if [workerScript] is
  /// null or fails to load.
  Future<void> start() async {
    if (workerScript == null) {
      _fallbackState = createState();
      return;
    }

    final initializations = <Future<void>>[];
    for (var i = 0; i < workers; i++) {
      final options = web.WorkerOptions(type: 'module');
      final worker = web.Worker(workerScript!.toJS, options);
      final w = _Worker(worker);
      _workers.add(w);

      final ready = Completer<void>();
      final inited = Completer<void>();

      void onWorkerError() {
        w.worker.terminate();
        _workers.remove(w);
        final lost = [
          for (final e in _owner.entries)
            if (e.value == w) e.key,
        ];
        for (final id in lost) {
          _owner.remove(id);
          _waiting.remove(id)?.completeError(StateError('$name-$i exited with this job unfinished'));
        }
      }

      worker.onmessage = (web.MessageEvent event) {
        if (event.data.isA<JSString>()) {
          final msg = (event.data as JSString).toDart;
          if (msg == 'ready') {
            ready.complete();
            return;
          } else if (msg == 'inited') {
            inited.complete();
            return;
          }
        }

        final data = event.data as JSArray;
        final type = data.getProperty(0.toJS);

        if (type.isA<JSString>() && (type as JSString).toDart == 'init_error') {
          if (!inited.isCompleted) {
            final err = (data.getProperty(1.toJS) as JSString).toDart;
            final st = (data.getProperty(2.toJS) as JSString).toDart;
            final remoteError = RemoteError(err, st);
            inited.completeError(remoteError, remoteError.stackTrace);
          }
          return;
        }

        final id = (type as JSNumber).toDartInt;
        final result = data.getProperty(1.toJS);
        final err = data.getProperty(2.toJS);

        final c = _waiting.remove(id);
        _owner.remove(id);
        if (c == null) return;
        w.pending--;

        if (err != null && !err.isUndefinedOrNull) {
          final errMsg = (err as JSString).toDart;
          final stMsg = (data.getProperty(3.toJS) as JSString).toDart;
          final remoteError = RemoteError(errMsg, stMsg);
          c.completeError(remoteError, remoteError.stackTrace);
        } else {
          c.complete(result);
        }
      }.toJS;

      worker.onerror = (web.Event event) {
        if (!ready.isCompleted) {
          ready.completeError(Exception('Worker failed to load'));
        } else {
          onWorkerError();
        }
      }.toJS;

      initializations.add(() async {
        try {
          await ready.future;
          final payload = buildInitMessage != null ? buildInitMessage!() : null;
          final initMsg = ['init'.toJS, payload].jsify() as JSArray;
          worker.postMessage(initMsg);
          await inited.future;
        } catch (e) {
          if (e is RemoteError) {
            _terminateWorkers();
            rethrow;
          }
          if (!usesFallback) {
            _terminateWorkers();
            _fallbackState = createState();
          }
        }
      }());
    }
    await Future.wait(initializations);
  }

  void _terminateWorkers() {
    for (final w in _workers) {
      w.worker.terminate();
    }
    _workers.clear();
  }

  void _schedulePump() {
    if (_pumpTimer != null || _disposed || _queue.isEmpty) return;
    _pumpTimer = Timer(const Duration(milliseconds: 4), _pump);
  }

  void _pump() {
    _pumpTimer = null;
    if (_disposed || _queue.isEmpty) return;
    final sw = Stopwatch()..start();
    while (_queue.isNotEmpty && sw.elapsedMicroseconds < 8000) {
      final job = _queue.removeFirst();
      job.execute();
      if (_disposed) return;
    }
    if (_queue.isNotEmpty) {
      _schedulePump();
    }
  }

  _Worker _pick() {
    if (_workers.isEmpty) {
      throw StateError(_disposed ? 'worker pool disposed' : 'no $name alive');
    }
    _Worker best = _workers.first;
    for (final w in _workers) {
      if (w.pending < best.pending) best = w;
    }
    return best;
  }

  /// Schedules [run] on the 8ms/4ms time-sliced main-thread fallback queue.
  Future<T> enqueueFallback<T>(T Function(TState state) run) {
    final state = _fallbackState;
    if (_disposed || state == null) {
      throw StateError(_disposed ? 'worker pool disposed' : 'no $name alive');
    }
    final completer = Completer<T>();
    _queue.add(_QueuedJob<T>(() => run(state), completer));
    _schedulePump();
    return completer.future;
  }

  /// Dispatches [body] (with optional transferable `ArrayBuffer` list
  /// [transfer]) to the least-busy Web Worker.
  Future<T> requestJs<T>(JSArray body, [JSArray? transfer]) {
    final w = _pick();
    final id = _nextId++;
    final c = Completer<Object?>();
    _waiting[id] = c;
    w.pending++;
    _owner[id] = w;

    final msg = [id.toJS, ...body.toDart].jsify() as JSArray;
    if (transfer != null) {
      w.worker.postMessage(msg, transfer);
    } else {
      w.worker.postMessage(msg);
    }

    return c.future.then((v) => v as T);
  }

  /// Jobs sent and not yet answered.
  int get inflight => usesFallback ? _queue.length : _waiting.length;

  /// Terminates workers and cancels any waiting jobs with `onDisposeError()`.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _pumpTimer?.cancel();
    _pumpTimer = null;
    while (_queue.isNotEmpty) {
      final job = _queue.removeFirst();
      if (!job.completer.isCompleted) {
        job.completer.completeError(_onDisposeError());
      }
    }
    _terminateWorkers();
    for (final c in _waiting.values) {
      if (!c.isCompleted) c.completeError(_onDisposeError());
    }
    _waiting.clear();
    _owner.clear();
  }
}

/// Runs a generic worker message loop inside a `DedicatedWorkerGlobalScope`.
///
/// Signals `'ready'` immediately so the host [WorkerPool] can send its `'init'`
/// payload after asynchronous Wasm compilation completes.
void runWebWorker<TState>({
  required TState Function(JSAny? initData) init,
  required (JSAny? result, JSArray? transfer) Function(TState state, JSArray request) onRequest,
}) {
  final self = globalContext as web.DedicatedWorkerGlobalScope;
  TState? state;

  self.onmessage = (web.MessageEvent event) {
    final data = event.data as JSArray;
    final type = data.getProperty(0.toJS);
    if (type.isA<JSString>() && (type as JSString).toDart == 'init') {
      try {
        final initData = data.getProperty(1.toJS);
        state = init(initData);
        self.postMessage('inited'.toJS);
      } catch (e, st) {
        self.postMessage(['init_error'.toJS, e.toString().toJS, st.toString().toJS].jsify() as JSArray);
      }
      return;
    }

    final id = type as JSNumber;
    try {
      final (result, transfer) = onRequest(state as TState, data);
      final reply = [id, result].jsify() as JSArray;
      if (transfer != null) {
        self.postMessage(reply, transfer);
      } else {
        self.postMessage(reply);
      }
    } catch (e, st) {
      self.postMessage([id, null, e.toString().toJS, st.toString().toJS].jsify() as JSArray);
    }
  }.toJS;
  self.postMessage('ready'.toJS);
}
