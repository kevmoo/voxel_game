import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import '../grid/voxel_block_table.dart';
import '../mesh/chunk_mesher.dart';
import '../worker_pool/worker_pool_web.dart';
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

typedef _ChunkWorkerState = (ChunkGenerator generator, ChunkMesher mesher);

/// A fixed pool of workers running chunk generation and meshing.
/// Automatically falls back to time-sliced main-thread batches if `workerScript` is null.
class ChunkWorkerPool implements ChunkJobs {
  /// [workers] defaults to [defaultWorkers].
  ChunkWorkerPool(this.config, {int? workers})
    : _pool = WorkerPool<_ChunkWorkerState>(
        createState: () => (config.generator(), config.table.mesher(lighting: config.lighting)),
        workerScript: config.workerScript,
        buildInitMessage: () => [
          config.table.palette,
          config.table.shapes,
          config.table.opaque,
          config.table.emission,
          config.lighting,
          config.workerInitData,
        ].jsify(),
        workers: workers,
        name: 'chunk-worker',
        onDisposeError: () => const ChunkJobCancelled('worker pool disposed'),
      );

  /// Default worker count on web runtimes.
  static int get defaultWorkers => WorkerPool.defaultWorkers;

  /// Two thirds of [cores], at least one.
  static int workersFor(int cores) => WorkerPool.workersFor(cores);

  /// What every worker is built from.
  final ChunkWorkerConfig config;

  final WorkerPool<_ChunkWorkerState> _pool;

  /// Logical worker count.
  int get workers => _pool.workers;

  /// Spawns the workers, or falls back to time-sliced main thread if [workerScript]
  /// is null or worker initialization fails.
  Future<void> start() => _pool.start();

  @override
  Future<Uint8List> generate(int cx, int cz, [int dimension = 0]) async {
    if (_pool.usesFallback) {
      return _pool.enqueueFallback((state) => state.$1.generateIn(cx, cz, dimension));
    }

    final result = await _pool.requestJs<JSUint8Array>(['gen', cx, cz, dimension].jsify() as JSArray);
    return result.toDart;
  }

  @override
  Future<ChunkMeshResult> mesh(int cx, int cz, List<Uint8List?> ring) async {
    if (_pool.usesFallback) {
      return _pool.enqueueFallback((state) => state.$2.build(cx, cz, ring));
    }

    final jsRing = <JSUint8Array?>[for (final r in ring) r?.toJS];

    final reply = await _pool.requestJs<JSArray>(['mesh'.toJS, cx.toJS, cz.toJS, jsRing.jsify()].jsify() as JSArray);

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
  int get inflight => _pool.inflight;

  /// Cancels any waiting jobs with [ChunkJobCancelled].
  void dispose() => _pool.dispose();
}

/// Runs the chunk worker loop in a `DedicatedWorkerGlobalScope`.
void runChunkWorker(ChunkWorkerConfig Function(JSAny? initData) init) {
  runWebWorker<_ChunkWorkerState>(
    init: (payload) {
      final data = payload as JSArray;
      final palette = data.getProperty(0.toJS) as JSFloat32Array;
      final shapes = data.getProperty(1.toJS) as JSUint8Array;
      final opaque = data.getProperty(2.toJS) as JSUint8Array;
      final emission = data.getProperty(3.toJS) as JSUint8Array;
      final lighting = (data.getProperty(4.toJS) as JSBoolean).toDart;
      final initData = data.getProperty(5.toJS);

      final config = init(initData);
      final generator = config.generator();
      final mesher = ChunkMesher(
        palette: palette.toDart,
        shape: shapes.toDart,
        opaque: opaque.toDart,
        emission: emission.toDart,
        lighting: lighting,
      );
      return (generator, mesher);
    },
    onRequest: (state, data) {
      final (generator, mesher) = state;
      final kind = (data.getProperty(1.toJS) as JSString).toDart;
      if (kind == 'gen') {
        final cx = (data.getProperty(2.toJS) as JSNumber).toDartInt;
        final cz = (data.getProperty(3.toJS) as JSNumber).toDartInt;
        final dimension = (data.getProperty(4.toJS) as JSNumber).toDartInt;
        final blocks = generator.generateIn(cx, cz, dimension);
        final jsBlocks = blocks.toJS;
        final transfer = [jsBlocks.getProperty('buffer'.toJS)].jsify() as JSArray;
        return (jsBlocks, transfer);
      }
      if (kind != 'mesh') {
        throw ArgumentError.value(kind, 'kind', 'unknown chunk job');
      }
      final cx = (data.getProperty(2.toJS) as JSNumber).toDartInt;
      final cz = (data.getProperty(3.toJS) as JSNumber).toDartInt;
      final ringJs = data.getProperty(4.toJS) as JSArray;
      final ring = <Uint8List?>[];
      for (var i = 0; i < ringJs.length; i++) {
        final el = ringJs.getProperty(i.toJS);
        ring.add(el.isUndefinedOrNull ? null : (el as JSUint8Array).toDart);
      }

      return mesher.buildWith(cx, cz, ring, (r) {
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

        return (reply.jsify() as JSArray, transferArgs.jsify() as JSArray);
      });
    },
  );
}
