import 'dart:js_interop';

import 'package:voxel_engine/core.dart';
import 'package:voxel_engine/worldgen.dart';
import 'package:voxel_game_minecraft/src/spec/world_table.dart';

void main() {
  runChunkWorker((initData) {
    final map = initData.dartify() as Map<Object?, Object?>;
    final seed = (map['seed'] as num).toInt();
    final idsData = map['ids'] as Map<Object?, Object?>;
    final ids = idsData.map((k, v) => MapEntry(k as String, (v as num).toInt()));

    const dummyDef = VoxelBlockDef(shape: BlockShape.cube, solid: false, opaque: false, r: 0, g: 0, b: 0);
    return ChunkWorkerConfig(
      generator: () => DimensionGenerator([overworld, underworld], ids, seed),
      table: VoxelBlockTable(const [dummyDef]),
    );
  });
}
