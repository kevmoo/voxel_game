import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

class _Worker {
  _Worker(this.isolate, this.port);
  final Isolate isolate;
  final SendPort port;
  int pending = 0;
}

/// A fixed pool of isolates that dispatches each request to the least-busy
/// worker.
///
/// A job that throws on its worker fails its future with a [RemoteError]
/// carrying the worker's message and stack. A worker that dies fails every job
/// it held with a [StateError] and leaves the pool; the others keep working.
class WorkerPool<TState> {
  /// Creates a pool of [workers] isolates (defaulting to [defaultWorkers]).
  ///
  /// Both [createState] and [onRequest] are sent across [Isolate.spawn], so
  /// they must be top-level or static functions (or closures that capture only
  /// isolate-sendable state).
  WorkerPool({
    required this.createState,
    required this.onRequest,
    int? workers,
    this.name = 'worker',
    Object Function()? onDisposeError,
  }) : workers = workers ?? defaultWorkers,
       _onDisposeError = onDisposeError ?? (() => StateError('worker pool disposed'));

  /// [workersFor] this machine's cores.
  static int get defaultWorkers => workersFor(Platform.numberOfProcessors);

  /// Two thirds of [cores], at least one: 8 of an M2 Pro's 12, 5 of a
  /// Snapdragon 8 Gen 3's 8. Past that the fill time does not fall: the
  /// extra workers land on efficiency cores or share the others, slowing
  /// every job, and take the cores the UI and raster threads need.
  static int workersFor(int cores) => math.max(1, cores * 2 ~/ 3);

  /// Builds the per-worker state inside each spawned isolate.
  final TState Function() createState;

  /// Handles a single request list `[op, ...args]` inside a worker isolate.
  final Object? Function(TState state, List<Object?> request) onRequest;

  /// Isolates [start] spawns.
  final int workers;

  /// Debug prefix for spawned worker isolates and error messages.
  final String name;

  final Object Function() _onDisposeError;
  final List<_Worker> _workers = [];
  final Map<int, _Worker> _byIndex = {};
  final ReceivePort _inbox = ReceivePort();
  final ReceivePort _exits = ReceivePort();
  final Map<int, Completer<Object?>> _waiting = {};
  final Map<int, _Worker> _owner = {};
  int _nextId = 1;
  bool _disposed = false;

  /// Spawns the workers. Throws a [RemoteError] when a worker fails while
  /// running [createState].
  Future<void> start() async {
    _inbox.listen(_onReply);
    _exits.listen(_onExit);
    for (var i = 0; i < workers; i++) {
      final ready = ReceivePort();
      final isolate = await Isolate.spawn<_IsolateBoot<TState>>(
        _isolateMain<TState>,
        _IsolateBoot<TState>(ready.sendPort, _inbox.sendPort, createState, onRequest),
        paused: true,
        debugName: '$name-$i',
      );
      // Listeners go on before the worker runs a line, so a start-up failure
      // reaches [ready] as [error, stack] instead of leaving it waiting forever.
      isolate.addErrorListener(ready.sendPort);
      isolate.addOnExitListener(ready.sendPort, response: 'exit');
      isolate.resume(isolate.pauseCapability!);
      final first = await ready.first;
      ready.close();
      if (first is! SendPort) {
        isolate.kill(priority: Isolate.immediate);
        if (first is List<Object?>) {
          throw RemoteError(first[0] as String, first[1] as String);
        }
        throw StateError('$name-$i exited while starting');
      }
      final worker = _Worker(isolate, first);
      _byIndex[i] = worker;
      isolate.addOnExitListener(_exits.sendPort, response: i);
      _workers.add(worker);
    }
  }

  void _onReply(Object? message) {
    final list = message as List<Object?>;
    final id = list[0] as int;
    final c = _waiting.remove(id);
    _owner.remove(id)?.pending--;
    if (c == null) return;
    if (list.length == 4) {
      final err = RemoteError(list[2] as String, list[3] as String);
      c.completeError(err, err.stackTrace);
    } else {
      c.complete(list[1]);
    }
  }

  void _onExit(Object? message) {
    final index = message as int;
    final w = _byIndex.remove(index)!;
    _workers.remove(w);
    final lost = [
      for (final e in _owner.entries)
        if (e.value == w) e.key,
    ];
    for (final id in lost) {
      _owner.remove(id);
      _waiting.remove(id)!.completeError(StateError('$name-$index exited with this job unfinished'));
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

  /// Sends [body] to the least-busy worker and completes with its response.
  Future<T> request<T>(List<Object?> body) {
    final w = _pick();
    final id = _nextId++;
    final c = Completer<Object?>();
    _waiting[id] = c;
    w.pending++;
    _owner[id] = w;
    w.port.send([id, ...body]);
    return c.future.then((v) => v as T);
  }

  /// Jobs sent and not yet answered.
  int get inflight => _waiting.length;

  /// Kills the workers and fails any waiting jobs with `onDisposeError()`.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _exits.close();
    for (final w in _workers) {
      w.isolate.kill(priority: Isolate.immediate);
    }
    _workers.clear();
    _inbox.close();
    for (final c in _waiting.values) {
      if (!c.isCompleted) c.completeError(_onDisposeError());
    }
    _waiting.clear();
    _owner.clear();
  }
}

class _IsolateBoot<TState> {
  const _IsolateBoot(this.ready, this.out, this.createState, this.onRequest);
  final SendPort ready;
  final SendPort out;
  final TState Function() createState;
  final Object? Function(TState state, List<Object?> request) onRequest;
}

void _isolateMain<TState>(_IsolateBoot<TState> boot) {
  final state = boot.createState();
  final port = ReceivePort();
  boot.ready.send(port.sendPort);
  port.listen((message) {
    final list = message as List<Object?>;
    final id = list[0] as int;
    try {
      boot.out.send([id, boot.onRequest(state, list.sublist(1))]);
    } catch (e, st) {
      boot.out.send([id, null, e.toString(), st.toString()]);
    }
  });
}
