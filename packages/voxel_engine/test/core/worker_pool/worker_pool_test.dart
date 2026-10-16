import 'dart:isolate';

import 'package:test/test.dart';
import 'package:voxel_engine/core.dart';

int _createAdderState() => 10;

int _brokenState() => throw StateError('state init failed');

Object? _handleAdder(int base, List<Object?> req) {
  final op = req[0] as String;
  if (op == 'add') return base + (req[1] as int);
  if (op == 'throw') throw ArgumentError('bad request');
  if (op == 'kill') Isolate.current.kill(priority: Isolate.immediate);
  throw StateError('unknown op: $op');
}

void main() {
  test('WorkerPool dispatches requests and drains inflight', () async {
    final pool = WorkerPool<int>(createState: _createAdderState, onRequest: _handleAdder, workers: 2);
    await pool.start();
    addTearDown(pool.dispose);

    final results = await Future.wait([
      for (var i = 0; i < 6; i++) pool.request<int>(['add', i]),
    ]);
    expect(results, [10, 11, 12, 13, 14, 15]);
    expect(pool.inflight, 0);
  });

  test('WorkerPool propagates RemoteError and survives worker crash', () async {
    final pool = WorkerPool<int>(createState: _createAdderState, onRequest: _handleAdder, workers: 2);
    await pool.start();
    addTearDown(pool.dispose);

    await expectLater(pool.request<int>(['throw']), throwsA(isA<RemoteError>()));
    await expectLater(pool.request<int>(['kill']), throwsStateError);
    expect(await pool.request<int>(['add', 5]), 15);
  });

  test('WorkerPool start throws RemoteError when createState fails', () async {
    final pool = WorkerPool<int>(createState: _brokenState, onRequest: _handleAdder, workers: 1);
    await expectLater(pool.start(), throwsA(isA<RemoteError>()));
    pool.dispose();
  });
}
