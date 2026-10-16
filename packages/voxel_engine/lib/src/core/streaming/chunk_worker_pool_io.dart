import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../grid/voxel_block_table.dart';
import '../mesh/chunk_mesher.dart';
import 'chunk_streamer.dart';

/// Fills one chunk volume ([ChunkSize.volume] bytes of block ids) for chunk
/// ([cx], [cz]) of [dimension]. Runs on a worker isolate: it must be pure in
/// (seed, position) and touch nothing outside itself.
abstract interface class ChunkGenerator {
  /// The block volume of chunk ([cx], [cz]) in [dimension].
  Uint8List generateIn(int cx, int cz, int dimension);
}

/// Builds a [ChunkGenerator] inside a worker isolate. It is sent to the
/// isolate, so it must capture only sendable values: make it in a static or
/// top-level function, never in an instance method whose `this` holds scene
/// objects.
typedef ChunkGeneratorFactory = ChunkGenerator Function();

/// Everything a worker isolate needs to build its own generator and mesher.
class ChunkWorkerConfig {
  /// A config sent to every worker; all of it must be sendable to an isolate.
  ChunkWorkerConfig({required this.generator, required this.table, this.lighting = true});

  /// Builds each worker's generator.
  final ChunkGeneratorFactory generator;

  /// The block table each worker's mesher reads.
  final VoxelBlockTable table;

  /// False skips the light flood in every mesher ([ChunkMesher.lighting]).
  final bool lighting;
}

class _Worker {
  _Worker(this.isolate, this.port);
  final Isolate isolate;
  final SendPort port;
  int pending = 0;
}

/// A fixed pool of isolates running chunk generation and meshing. Requests
/// are answered by futures; each goes to the least busy worker.
///
/// A job that throws on its worker fails its future with a [RemoteError]
/// carrying the worker's message and stack. A worker that dies fails every job
/// it held with a [StateError] and leaves the pool; the others keep working.
class ChunkWorkerPool implements ChunkJobs {
  /// [workers] defaults to [defaultWorkers].
  ChunkWorkerPool(this.config, {int? workers}) : workers = workers ?? defaultWorkers;

  /// [workersFor] this machine's cores.
  static int get defaultWorkers => workersFor(Platform.numberOfProcessors);

  /// Two thirds of [cores], at least one: 8 of an M2 Pro's 12, 5 of a
  /// Snapdragon 8 Gen 3's 8. Past that the fill time does not fall: the
  /// extra workers land on efficiency cores or share the others, slowing
  /// every job, and take the cores the UI and raster threads need.
  static int workersFor(int cores) => math.max(1, cores * 2 ~/ 3);

  /// What every worker is built from.
  final ChunkWorkerConfig config;

  /// Isolates [start] spawns.
  final int workers;
  final List<_Worker> _workers = [];
  final Map<int, _Worker> _byIndex = {};
  final ReceivePort _inbox = ReceivePort();
  final ReceivePort _exits = ReceivePort();
  final Map<int, Completer<Object?>> _waiting = {};
  final Map<int, _Worker> _owner = {};
  int _nextId = 1;
  bool _disposed = false;

  /// Spawns the workers. Throws a [RemoteError] when a worker fails while
  /// building its generator or mesher.
  Future<void> start() async {
    _inbox.listen(_onReply);
    _exits.listen(_onExit);
    for (var i = 0; i < workers; i++) {
      final ready = ReceivePort();
      final isolate = await Isolate.spawn(
        _workerMain,
        [ready.sendPort, _inbox.sendPort, config],
        paused: true,
        debugName: 'chunk-worker-$i',
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
        if (first is List<Object?>) throw RemoteError(first[0] as String, first[1] as String);
        throw StateError('chunk-worker-$i exited while starting');
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
      c.completeError(RemoteError(list[2] as String, list[3] as String));
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
      _waiting.remove(id)!.completeError(StateError('chunk-worker-$index exited with this job unfinished'));
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

  Future<T> _request<T>(List<Object?> body) {
    final w = _pick();
    final id = _nextId++;
    final c = Completer<Object?>();
    _waiting[id] = c;
    w.pending++;
    _owner[id] = w;
    w.port.send([id, ...body]);
    return c.future.then((v) => v as T);
  }

  /// The job carries the dimension it was dispatched for, so a result that
  /// lands after a dimension switch still holds what it was asked for.
  @override
  Future<Uint8List> generate(int cx, int cz, [int dimension = 0]) async {
    final t = await _request<TransferableTypedData>(['gen', cx, cz, dimension]);
    return t.materialize().asUint8List();
  }

  /// [ring] is the chunk and its eight neighbours, in the order
  /// c, nx, px, nz, pz, nxnz, pxnz, nxpz, pxpz; a missing neighbour is null.
  @override
  Future<ChunkMeshResult> mesh(int cx, int cz, List<Uint8List?> ring) async {
    final reply = await _request<List<Object?>>(['mesh', cx, cz, ring]);
    ByteBuffer bytes(int at) => (reply[at] as TransferableTypedData).materialize();
    MeshSurface surface(int at) => MeshSurface(
      bytes(at).asFloat32List(),
      bytes(at + 1).asFloat32List(),
      bytes(at + 2).asFloat32List(),
      bytes(at + 3).asFloat32List(),
      bytes(at + 4).asInt32List(),
    );

    return ChunkMeshResult(
      surface(0),
      surface(5),
      surface(10),
      surface(15),
      sky: bytes(20).asUint8List(),
      block: bytes(21).asUint8List(),
      aoVerts: reply[22] as int,
      ms: reply[23] as double,
    );
  }

  /// Jobs sent and not yet answered.
  int get inflight => _waiting.length;

  /// Kills the workers. Jobs still waiting fail with [ChunkJobCancelled].
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
      if (!c.isCompleted) c.completeError(const ChunkJobCancelled('worker pool disposed'));
    }
    _waiting.clear();
    _owner.clear();
  }
}

void _workerMain(List<Object?> args) {
  final ready = args[0] as SendPort;
  final out = args[1] as SendPort;
  final config = args[2] as ChunkWorkerConfig;
  final generator = config.generator();
  final mesher = config.table.mesher(lighting: config.lighting);
  final port = ReceivePort();
  ready.send(port.sendPort);
  port.listen((message) {
    final list = message as List<Object?>;
    final id = list[0] as int;
    try {
      out.send([id, _run(generator, mesher, list)]);
    } catch (e, st) {
      out.send([id, null, e.toString(), st.toString()]);
    }
  });
}

Object? _run(ChunkGenerator generator, ChunkMesher mesher, List<Object?> list) {
  final kind = list[1] as String;
  if (kind == 'gen') {
    final blocks = generator.generateIn(list[2] as int, list[3] as int, list[4] as int);
    return TransferableTypedData.fromList([blocks]);
  }
  if (kind != 'mesh') throw ArgumentError.value(kind, 'kind', 'unknown chunk job');
  final ring = (list[4] as List<Object?>).cast<Uint8List?>();
  List<Object?> pack(MeshSurface s) => [
    TransferableTypedData.fromList([s.positions]),
    TransferableTypedData.fromList([s.normals]),
    TransferableTypedData.fromList([s.colors]),
    TransferableTypedData.fromList([s.light]),
    TransferableTypedData.fromList([s.indices]),
  ];
  // The transferables copy the mesher's arrays: the result needs no copy of its own.
  return mesher.buildWith(
    list[2] as int,
    list[3] as int,
    ring,
    (r) => [
      ...pack(r.solid),
      ...pack(r.liquid),
      ...pack(r.cutout),
      ...pack(r.glow),
      TransferableTypedData.fromList([r.sky]),
      TransferableTypedData.fromList([r.block]),
      r.aoVerts,
      r.ms,
    ],
  );
}
