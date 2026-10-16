import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../grid/voxel_block_table.dart';
import '../mesh/chunk_mesher.dart';
import '../occlusion/chunk_visibility.dart';
import '../worker_pool/worker_pool_io.dart';
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

  /// The worker script. Unused on IO.
  final String? workerScript;

  /// Initialization data passed to the worker.
  final Object? workerInitData;
}

typedef _ChunkWorkerState = (ChunkGenerator generator, ChunkMesher mesher);

_ChunkWorkerState Function() _createChunkWorkerState(ChunkWorkerConfig config) =>
    () => (config.generator(), config.table.mesher(lighting: config.lighting));

Object? _handleChunkRequest(_ChunkWorkerState state, List<Object?> req) {
  final (generator, mesher) = state;
  final kind = req[0] as String;
  if (kind == 'gen') {
    final blocks = generator.generateIn(req[1] as int, req[2] as int, req[3] as int);
    return TransferableTypedData.fromList([blocks]);
  }
  if (kind != 'mesh') throw ArgumentError.value(kind, 'kind', 'unknown chunk job');
  final ring = (req[3] as List<Object?>).cast<Uint8List?>();
  List<Object?> pack(MeshSurface s) => [
    TransferableTypedData.fromList([s.positions]),
    TransferableTypedData.fromList([s.normals]),
    TransferableTypedData.fromList([s.colors]),
    TransferableTypedData.fromList([s.light]),
    TransferableTypedData.fromList([s.indices]),
  ];
  // The transferables copy the mesher's arrays: the result needs no copy of its own.
  return mesher.buildWith(
    req[1] as int,
    req[2] as int,
    ring,
    (r) => [
      ...pack(r.solid),
      ...pack(r.liquid),
      ...pack(r.cutout),
      ...pack(r.glow),
      TransferableTypedData.fromList([r.sky]),
      TransferableTypedData.fromList([r.block]),
      Uint16List.fromList(r.visibility.masks),
      r.aoVerts,
      r.ms,
    ],
  );
}

/// A fixed pool of isolates running chunk generation and meshing. Requests
/// are answered by futures; each goes to the least busy worker.
///
/// A job that throws on its worker fails its future with a [RemoteError]
/// carrying the worker's message and stack. A worker that dies fails every job
/// it held with a [StateError] and leaves the pool; the others keep working.
class ChunkWorkerPool implements ChunkJobs {
  /// [workers] defaults to [defaultWorkers].
  ChunkWorkerPool(this.config, {int? workers})
    : _pool = WorkerPool<_ChunkWorkerState>(
        createState: _createChunkWorkerState(config),
        onRequest: _handleChunkRequest,
        workers: workers,
        name: 'chunk-worker',
        onDisposeError: () => const ChunkJobCancelled('worker pool disposed'),
      );

  /// [workersFor] this machine's cores.
  static int get defaultWorkers => WorkerPool.defaultWorkers;

  /// Two thirds of [cores], at least one.
  static int workersFor(int cores) => WorkerPool.workersFor(cores);

  /// What every worker is built from.
  final ChunkWorkerConfig config;

  final WorkerPool<_ChunkWorkerState> _pool;

  /// Isolates [start] spawns.
  int get workers => _pool.workers;

  /// Spawns the workers. Throws a [RemoteError] when a worker fails while
  /// building its generator or mesher.
  Future<void> start() => _pool.start();

  /// The job carries the dimension it was dispatched for, so a result that
  /// lands after a dimension switch still holds what it was asked for.
  @override
  Future<Uint8List> generate(int cx, int cz, [int dimension = 0]) async {
    final t = await _pool.request<TransferableTypedData>(['gen', cx, cz, dimension]);
    return t.materialize().asUint8List();
  }

  /// [ring] is the chunk and its eight neighbours, in the order
  /// c, nx, px, nz, pz, nxnz, pxnz, nxpz, pxpz; a missing neighbour is null.
  @override
  Future<ChunkMeshResult> mesh(int cx, int cz, List<Uint8List?> ring) async {
    final reply = await _pool.request<List<Object?>>(['mesh', cx, cz, ring]);
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
      visibility: ChunkVisibility(reply[22] as Uint16List),
      aoVerts: reply[23] as int,
      ms: reply[24] as double,
    );
  }

  /// Jobs sent and not yet answered.
  int get inflight => _pool.inflight;

  /// Kills the workers. Jobs still waiting fail with [ChunkJobCancelled].
  void dispose() => _pool.dispose();
}
