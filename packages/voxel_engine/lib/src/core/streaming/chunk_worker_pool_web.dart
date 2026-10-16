import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import '../grid/voxel_block_table.dart';
import '../mesh/chunk_mesher.dart';
import 'chunk_streamer.dart';

/// Fills one chunk volume ([ChunkSize.volume] bytes of block ids) for chunk
/// ([cx], [cz]) of [dimension].
abstract interface class ChunkGenerator {
  /// The block volume of chunk ([cx], [cz]) in [dimension].
  Uint8List generateIn(int cx, int cz, int dimension);
}

/// Builds a [ChunkGenerator].
typedef ChunkGeneratorFactory = ChunkGenerator Function();

/// Everything a worker needs to build its own generator and mesher.
class ChunkWorkerConfig {
  /// A config used to construct the generator and mesher.
  ChunkWorkerConfig({required this.generator, required this.table, this.lighting = true});

  /// Builds each worker's generator.
  final ChunkGeneratorFactory generator;

  /// The block table each worker's mesher reads.
  final VoxelBlockTable table;

  /// False skips the light flood in every mesher ([ChunkMesher.lighting]).
  final bool lighting;
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

/// Web event-loop implementation of [ChunkWorkerPool] that runs chunk
/// generation and meshing in small time-sliced batches between browser frames.
class ChunkWorkerPool implements ChunkJobs {
  /// [workers] defaults to [defaultWorkers].
  ChunkWorkerPool(this.config, {int? workers}) : workers = workers ?? defaultWorkers;

  /// Default worker count on single-threaded web runtimes.
  static int get defaultWorkers => 1;

  /// Two thirds of [cores], at least one.
  static int workersFor(int cores) => math.max(1, cores * 2 ~/ 3);

  /// What every worker is built from.
  final ChunkWorkerConfig config;

  /// Logical worker count.
  final int workers;

  ChunkGenerator? _generator;
  ChunkMesher? _mesher;
  final Queue<_QueuedJob<Object?>> _queue = Queue<_QueuedJob<Object?>>();
  Timer? _pumpTimer;
  bool _disposed = false;

  /// Initializes the generator and mesher.
  Future<void> start() async {
    _generator = config.generator();
    _mesher = config.table.mesher(lighting: config.lighting);
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

  void _schedulePump() {
    if (_pumpTimer != null || _disposed || _queue.isEmpty) return;
    _pumpTimer = Timer(const Duration(milliseconds: 4), _pump);
  }

  void _pump() {
    _pumpTimer = null;
    if (_disposed || _queue.isEmpty) return;
    final sw = Stopwatch()..start();
    // Run up to 8ms of chunk jobs, then yield 4ms so requestAnimationFrame ticks.
    while (_queue.isNotEmpty && sw.elapsedMicroseconds < 8000) {
      final job = _queue.removeFirst();
      job.execute();
      if (_disposed) return;
    }
    if (_queue.isNotEmpty) {
      _schedulePump();
    }
  }

  @override
  Future<Uint8List> generate(int cx, int cz, [int dimension = 0]) =>
      _enqueue(() => _generator!.generateIn(cx, cz, dimension));

  @override
  Future<ChunkMeshResult> mesh(int cx, int cz, List<Uint8List?> ring) => _enqueue(() => _mesher!.build(cx, cz, ring));

  /// Jobs sent and not yet answered.
  int get inflight => _queue.length;

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
  }
}
