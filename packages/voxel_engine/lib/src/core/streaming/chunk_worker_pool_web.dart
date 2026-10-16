import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../grid/voxel_block_table.dart';
import '../mesh/chunk_mesher.dart';
import 'chunk_streamer.dart';

/// Fills one chunk volume ([ChunkSize.volume] bytes of block ids) for chunk
/// ([cx], [cz]) of [dimension]. Runs on a worker: it must be pure in
/// (seed, position) and touch nothing outside itself.
abstract interface class ChunkGenerator {
  /// The block volume of chunk ([cx], [cz]) in [dimension].
  Uint8List generateIn(int cx, int cz, int dimension);
}

/// Builds a [ChunkGenerator] inside a worker. It is sent to the
/// worker, so it must capture only sendable values.
typedef ChunkGeneratorFactory = ChunkGenerator Function();

/// Everything a worker isolate needs to build its own generator and mesher.
class ChunkWorkerConfig {
  /// A config sent to every worker; all of it must be sendable to an isolate.
  ChunkWorkerConfig({
    required this.generator,
    required this.table,
    this.lighting = true,
    this.workerScript,
    this.workerInitData,
  });

  /// Builds each worker's generator.
  final ChunkGeneratorFactory generator;

  /// The block table each worker's mesher reads.
  final VoxelBlockTable table;

  /// False skips the light flood in every mesher ([ChunkMesher.lighting]).
  final bool lighting;

  /// The worker script URL. If null, falls back to the main thread.
  final String? workerScript;

  /// Initialization data passed to the worker.
  final Object? workerInitData;
}

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

/// A fixed pool of workers running chunk generation and meshing.
/// Automatically falls back to time-sliced main-thread batches if `workerScript` is null.
class ChunkWorkerPool implements ChunkJobs {
  /// [workers] defaults to [defaultWorkers].
  ChunkWorkerPool(this.config, {int? workers}) : workers = workers ?? defaultWorkers;

  /// Default worker count on web runtimes.
  static int get defaultWorkers {
    try {
      return math.min(8, workersFor(web.window.navigator.hardwareConcurrency.toInt()));
    } catch (_) {
      return 1;
    }
  }

  /// Two thirds of [cores], at least one.
  static int workersFor(int cores) => math.max(1, cores * 2 ~/ 3);

  /// What every worker is built from.
  final ChunkWorkerConfig config;

  /// Logical worker count.
  final int workers;

  final List<_Worker> _workers = [];
  final Map<int, Completer<Object?>> _waiting = {};
  final Map<int, _Worker> _owner = {};
  int _nextId = 1;
  bool _disposed = false;

  ChunkGenerator? _generator;
  ChunkMesher? _mesher;
  final Queue<_QueuedJob<Object?>> _queue = Queue<_QueuedJob<Object?>>();
  Timer? _pumpTimer;

  bool get _useFallback => _generator != null;

  /// Spawns the workers, or falls back to time-sliced main thread if [workerScript]
  /// is null or worker initialization fails.
  Future<void> start() async {
    if (config.workerScript == null) {
      _generator = config.generator();
      _mesher = config.table.mesher(lighting: config.lighting);
      return;
    }

    final initializations = <Future<void>>[];
    for (var i = 0; i < workers; i++) {
      final options = web.WorkerOptions(type: 'module');
      final worker = web.Worker(config.workerScript!.toJS, options);
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
          _waiting.remove(id)?.completeError(StateError('chunk-worker-$i exited with this job unfinished'));
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
            inited.completeError(RemoteError(err, st));
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
          c.completeError(RemoteError(errMsg, stMsg));
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
          final initMsg =
              [
                    'init',
                    config.table.palette,
                    config.table.shapes,
                    config.table.opaque,
                    config.table.emission,
                    config.lighting,
                    config.workerInitData,
                  ].jsify()
                  as JSArray;
          worker.postMessage(initMsg);
          await inited.future;
        } catch (e) {
          if (e is RemoteError) {
            _terminateWorkers();
            throw e;
          }
          if (!_useFallback) {
            _terminateWorkers();
            _generator = config.generator();
            _mesher = config.table.mesher(lighting: config.lighting);
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
    if (_workers.isEmpty) throw StateError(_disposed ? 'worker pool disposed' : 'no chunk worker alive');
    _Worker best = _workers.first;
    for (final w in _workers) {
      if (w.pending < best.pending) best = w;
    }
    return best;
  }

  Future<T> _enqueue<T>(T Function() run) {
    if (_disposed || _generator == null || _mesher == null) {
      throw StateError(_disposed ? 'worker pool disposed' : 'no chunk worker alive');
    }
    final completer = Completer<T>();
    _queue.add(_QueuedJob<T>(run, completer));
    _schedulePump();
    return completer.future;
  }

  Future<T> _request<T>(JSArray body, [JSArray? transfer]) {
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

  @override
  Future<Uint8List> generate(int cx, int cz, [int dimension = 0]) async {
    if (_useFallback) {
      return _enqueue(() => _generator!.generateIn(cx, cz, dimension));
    }

    final result = await _request<JSUint8Array>(['gen', cx, cz, dimension].jsify() as JSArray);
    return result.toDart;
  }

  @override
  Future<ChunkMeshResult> mesh(int cx, int cz, List<Uint8List?> ring) async {
    if (_useFallback) {
      return _enqueue(() => _mesher!.build(cx, cz, ring));
    }

    final jsRing = <JSUint8Array?>[];
    final transferArgs = <JSAny>[];
    for (final r in ring) {
      if (r != null) {
        final j = r.toJS;
        jsRing.add(j);
        transferArgs.add(j.getProperty('buffer'.toJS) as JSAny);
      } else {
        jsRing.add(null);
      }
    }

    final reply = await _request<JSArray>(
      ['mesh'.toJS, cx.toJS, cz.toJS, jsRing.jsify()].jsify() as JSArray,
      transferArgs.jsify() as JSArray,
    );

    JSTypedArray bytes(int at) => reply.getProperty(at.toJS) as JSTypedArray;
    MeshSurface surface(int at) => MeshSurface(
      (bytes(at) as JSFloat32Array).toDart,
      (bytes(at + 1) as JSFloat32Array).toDart,
      (bytes(at + 2) as JSFloat32Array).toDart,
      (bytes(at + 3) as JSFloat32Array).toDart,
      (bytes(at + 4) as JSInt32Array).toDart,
    );

    return ChunkMeshResult(
      surface(0),
      surface(5),
      surface(10),
      surface(15),
      sky: (bytes(20) as JSUint8Array).toDart,
      block: (bytes(21) as JSUint8Array).toDart,
      aoVerts: (reply.getProperty(22.toJS) as JSNumber).toDartInt,
      ms: (reply.getProperty(23.toJS) as JSNumber).toDartDouble,
    );
  }

  /// Jobs sent and not yet answered.
  int get inflight => _useFallback ? _queue.length : _waiting.length;

  /// Cancels any waiting jobs with [ChunkJobCancelled].
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _pumpTimer?.cancel();
    _pumpTimer = null;
    while (_queue.isNotEmpty) {
      final job = _queue.removeFirst();
      if (!job.completer.isCompleted) {
        job.completer.completeError(const ChunkJobCancelled('worker pool disposed'));
      }
    }
    _terminateWorkers();
    for (final c in _waiting.values) {
      if (!c.isCompleted) c.completeError(const ChunkJobCancelled('worker pool disposed'));
    }
    _waiting.clear();
    _owner.clear();
  }
}

/// Runs the worker loop in a DedicatedWorkerGlobalScope.
void runChunkWorker(ChunkWorkerConfig Function(JSAny? initData) init) {
  final self = globalContext as web.DedicatedWorkerGlobalScope;
  ChunkGenerator? generator;
  ChunkMesher? mesher;

  self.onmessage = (web.MessageEvent event) {
    final data = event.data as JSArray;
    final type = data.getProperty(0.toJS);
    if (type.isA<JSString>() && (type as JSString).toDart == 'init') {
      try {
        final palette = data.getProperty(1.toJS) as JSFloat32Array;
        final shapes = data.getProperty(2.toJS) as JSUint8Array;
        final opaque = data.getProperty(3.toJS) as JSUint8Array;
        final emission = data.getProperty(4.toJS) as JSUint8Array;
        final lighting = (data.getProperty(5.toJS) as JSBoolean).toDart;
        final initData = data.getProperty(6.toJS);

        final config = init(initData);
        generator = config.generator();
        mesher = ChunkMesher(
          palette: palette.toDart,
          shape: shapes.toDart,
          opaque: opaque.toDart,
          emission: emission.toDart,
          lighting: lighting,
        );
        self.postMessage('inited'.toJS);
      } catch (e, st) {
        self.postMessage(['init_error'.toJS, e.toString().toJS, st.toString().toJS].jsify() as JSArray);
      }
      return;
    }

    final id = type as JSNumber;
    final kind = (data.getProperty(1.toJS) as JSString).toDart;
    try {
      if (kind == 'gen') {
        final cx = (data.getProperty(2.toJS) as JSNumber).toDartInt;
        final cz = (data.getProperty(3.toJS) as JSNumber).toDartInt;
        final dimension = (data.getProperty(4.toJS) as JSNumber).toDartInt;
        final blocks = generator!.generateIn(cx, cz, dimension);
        final jsBlocks = blocks.toJS;
        final transfer = [jsBlocks.getProperty('buffer'.toJS)].jsify() as JSArray;
        self.postMessage([id, jsBlocks].jsify() as JSArray, transfer);
      } else if (kind == 'mesh') {
        final cx = (data.getProperty(2.toJS) as JSNumber).toDartInt;
        final cz = (data.getProperty(3.toJS) as JSNumber).toDartInt;
        final ringJs = data.getProperty(4.toJS) as JSArray;
        final ring = <Uint8List?>[];
        for (var i = 0; i < ringJs.length; i++) {
          final el = ringJs.getProperty(i.toJS);
          ring.add(el.isUndefinedOrNull ? null : (el as JSUint8Array).toDart);
        }

        final r = mesher!.buildWith(cx, cz, ring, (r) {
          final transferArgs = <JSAny>[];
          JSArray pack(MeshSurface s) {
            final p = s.positions.toJS;
            final n = s.normals.toJS;
            final c = s.colors.toJS;
            final l = s.light.toJS;
            final idx = s.indices.toJS;
            transferArgs.addAll([
              p.getProperty('buffer'.toJS) as JSAny,
              n.getProperty('buffer'.toJS) as JSAny,
              c.getProperty('buffer'.toJS) as JSAny,
              l.getProperty('buffer'.toJS) as JSAny,
              idx.getProperty('buffer'.toJS) as JSAny,
            ]);
            return [p, n, c, l, idx].jsify() as JSArray;
          }

          final sky = r.sky.toJS;
          final block = r.block.toJS;

          final reply = [
            ...pack(r.solid).toDart,
            ...pack(r.liquid).toDart,
            ...pack(r.cutout).toDart,
            ...pack(r.glow).toDart,
            sky,
            block,
            r.aoVerts,
            r.ms,
          ];

          transferArgs.addAll([sky.getProperty('buffer'.toJS) as JSAny, block.getProperty('buffer'.toJS) as JSAny]);

          return [reply.jsify() as JSArray, transferArgs.jsify() as JSArray];
        });

        final reply = r[0];
        final transfer = r[1];
        self.postMessage([id, reply].jsify() as JSArray, transfer);
      }
    } catch (e, st) {
      self.postMessage([id, null, e.toString().toJS, st.toString().toJS].jsify() as JSArray);
    }
  }.toJS;
  self.postMessage('ready'.toJS);
}
