import 'package:voxel_engine/voxel_engine.dart';
import 'package:voxel_game/src/spec/structure_loot.dart';

import '../structures/fortress.dart';

/// The world: biomes by climate, each with its ground, trees and plants; dark
/// stone in the deep and ores veining it, from diamond near the bottom to coal
/// all through; caves with lava at their floor; and the structures, each on a
/// grid of its own, tried in order.
const WorldGenSpec overworld = WorldGenSpec(
  bedrock: 'bedrock',
  biomes: [
    Biome(
      'mountain',
      top: 'stone',
      climate: Climate.highlands,
      covers: [Cover('snow', minHeight: 101), Cover('gravel', perMille: 250)],
      trees: [TreeSpec.spruce(log: 'spruce_log', leaves: 'spruce_leaves', minHeight: 11, maxHeight: 15, belowY: 96)],
      treeChance: 20,
      precipitation: Precipitation.snow,
    ),
    Biome(
      'snow',
      top: 'snow',
      under: 'dirt',
      climate: Climate.cold,
      trees: [TreeSpec.spruce(log: 'spruce_log', leaves: 'spruce_leaves')],
      treeChance: 37,
      ice: 'ice',
      precipitation: Precipitation.snow,
    ),
    Biome(
      'desert',
      top: 'sand',
      under: 'sandstone',
      climate: Climate.hotDry,
      trees: [TreeSpec.palm(log: 'jungle_log', leaves: 'oak_leaves')],
      treeChance: 8,
      plants: [Plant('cactus', perMille: 12, height: 2, maxHeight: 3), Plant('dead_bush', perMille: 28)],
      precipitation: Precipitation.none,
    ),
    // A swamp is low and flat, two blocks over the sea, with pools of water over mud and reeds by them.
    Biome(
      'swamp',
      top: 'grass',
      under: 'dirt',
      climate: Climate(minTemperature: 0.1, minHumidity: 0.42, maxHeight: 52),
      covers: [Cover('mud', perMille: 400, patch: 2), Cover('clay', perMille: 143)],
      pools: Pools(bed: 'mud'),
      flats: Flats(),
      trees: [TreeSpec(TreeShape.willow, log: 'oak_log', leaves: 'oak_leaves', minHeight: 9, maxHeight: 11)],
      treeChance: 27,
      plants: [
        Plant('reeds', perMille: 550, byWater: true),
        Plant('tall_grass', perMille: 278),
        Plant('mushroom', perMille: 40),
      ],
    ),
    Biome(
      'jungle',
      top: 'grass',
      under: 'dirt',
      climate: Climate.hotWet,
      trees: [
        TreeSpec(
          TreeShape.jungle,
          log: 'jungle_log',
          leaves: 'oak_leaves',
          vines: 'vines',
          minHeight: 16,
          maxHeight: 22,
        ),
      ],
      treeChance: 47,
      plants: [
        Plant('fern', perMille: 292),
        Plant('tall_grass', perMille: 90),
        Plant('melon', perMille: 12, spread: 2),
      ],
    ),
    Biome(
      'forest',
      top: 'grass',
      under: 'dirt',
      climate: Climate.wet,
      trees: [
        TreeSpec.oak(log: 'oak_log', leaves: 'oak_leaves', weight: 7),
        TreeSpec(TreeShape.bigOak, log: 'oak_log', leaves: 'oak_leaves', minHeight: 14, maxHeight: 18, weight: 3),
      ],
      treeChance: 92,
      plants: [Plant('tall_grass', perMille: 185), Plant('mushroom', perMille: 25), Plant('flower_red', perMille: 20)],
    ),
    Biome(
      'plains',
      top: 'grass',
      under: 'dirt',
      trees: [TreeSpec.oak(log: 'oak_log', leaves: 'oak_leaves')],
      treeChance: 20,
      plants: [
        Plant('tall_grass', perMille: 144),
        Plant('flower_yellow', perMille: 22),
        Plant('flower_red', perMille: 18),
      ],
    ),
  ],
  ocean: Biome(
    'ocean',
    top: 'sand',
    under: 'dirt',
    covers: [Cover('gravel', perMille: 200), Cover('clay', perMille: 143)],
  ),
  beach: Biome(
    'beach',
    top: 'sand',
    under: 'sandstone',
    trees: [TreeSpec.palm(log: 'jungle_log', leaves: 'oak_leaves')],
    treeChance: 30,
  ),
  // Where it is colder still the shore is snow, and the sea freezes over.
  shores: [
    Biome(
      'frozen_shore',
      top: 'snow',
      under: 'dirt',
      climate: Climate(maxTemperature: -0.4),
      ice: 'ice',
      precipitation: Precipitation.snow,
    ),
  ],
  strata: [Stratum('dark_stone', belowY: 22)],
  // Shares of the vein cells, deepest first: what an ore leaves to the next is what the next may take.
  ores: [
    Ore('diamond_ore', share: 0.006, belowY: 14),
    Ore('gold_ore', share: 0.014, belowY: 32),
    Ore('iron_ore', share: 0.032, belowY: 64),
    Ore('redstone_ore', share: 0.019, belowY: 30),
    Ore('coal_ore', share: 0.039),
  ],
  caves: CaveSpec(lava: 'lava'),
  structures: [
    StructureSpec('village', _village, chance: 0.18, biomes: ['plains', 'forest']),
    StructureSpec('temple', _temple, chance: 0.55, regionChunks: 4, biomes: ['desert']),
    StructureSpec('dungeon', dungeonStructure, chance: 0.45),
    StructureSpec('tower', _tower, chance: 0.3),
    StructureSpec(
      'mine',
      mineStructure,
      chance: 0.3,
      regionChunks: 5,
      biomes: ['mountain', 'snow', 'forest', 'plains'],
    ),
    StructureSpec('ruins', _ruins, chance: 0.5, regionChunks: 4, biomes: ['plains', 'forest']),
    StructureSpec('well', _well, chance: 0.3, regionChunks: 4, biomes: ['plains']),
    StructureSpec('camp', _camp, chance: 0.07),
  ],
);

/// The underworld, a world of its own from the same seed: one great cave
/// between a bedrock floor at 7 and roof at 100, a lava sea up to 28, soul
/// sand in patches on its floors, glowstone hanging from its ceilings and
/// quartz in its walls; and its fortresses, one in 60 % of the regions of 8
/// chunks square, wherever a floor stands over the sea.
const WorldGenSpec underworld = WorldGenSpec(
  cavern: CavernSpec(floor: 7, roof: 100, hangs: [Plant('glowstone', perMille: 43, maxHeight: 2)]),
  stone: 'hellstone',
  water: 'lava',
  seaLevel: 28,
  bedrock: 'bedrock',
  caves: CaveSpec.none,
  biomes: [
    Biome(
      'underworld',
      top: 'hellstone',
      covers: [Cover('soul_sand', perMille: 250, patch: 4)],
      precipitation: Precipitation.none,
    ),
  ],
  ores: [Ore('nether_quartz_ore', share: 0.065)],
  structures: [StructureSpec('fortress', fortress, chance: 0.6, regionChunks: 8)],
);

/// What a structure's chests hold. A dungeon's, a tower's and a temple's may
/// also hold a weapon with a bonus to its damage.
const Map<String, StructureLoot> structureLootTable = {
  'temple': StructureLoot(
    LootTable([
      LootEntry('gold_ingot', 2, 6, 1.0),
      LootEntry('diamond', 1, 2, 0.6),
      LootEntry('health_potion', 1, 2, 0.7),
      LootEntry('regen_potion', 1, 1, 0.4),
      LootEntry('strength_potion', 1, 1, 0.3),
      LootEntry('magic_dust', 1, 3, 0.5),
      LootEntry('ancient_blade', 1, 1, 0.1),
    ]),
    bonus: _weapons,
  ),
  'mine': StructureLoot(
    LootTable([
      LootEntry('iron_ingot', 2, 5, 0.9),
      LootEntry('coal', 4, 10, 1.0),
      LootEntry('torch', 3, 8, 0.9),
      LootEntry('bread', 1, 3, 0.7),
      LootEntry('raw_gold', 1, 2, 0.3),
      LootEntry('iron_pickaxe', 1, 1, 0.15),
    ]),
  ),
  'ruins': StructureLoot(
    LootTable([
      LootEntry('wheat_seeds', 2, 6, 0.8),
      LootEntry('bone', 1, 4, 0.9),
      LootEntry('cobblestone', 4, 12, 1.0),
      LootEntry('speed_potion', 1, 1, 0.2),
      LootEntry('antidote', 1, 1, 0.15),
      LootEntry('string', 1, 3, 0.4),
    ]),
  ),
  'well': StructureLoot(
    LootTable([
      LootEntry('raw_fish', 1, 3, 0.9),
      LootEntry('raw_salmon', 1, 1, 0.4),
      LootEntry('glass_bottle', 1, 3, 0.8),
      LootEntry('bucket', 1, 1, 0.2),
    ]),
  ),
  'fortress': StructureLoot(
    LootTable([
      LootEntry('quartz', 3, 8, 1.0),
      LootEntry('gold_ingot', 2, 5, 0.8),
      LootEntry('health_potion', 1, 2, 0.7),
      LootEntry('resistance_potion', 1, 1, 0.4),
      LootEntry('blaze_rod', 1, 3, 0.6),
      LootEntry('glowstone_dust', 2, 6, 0.5),
      LootEntry('diamond', 1, 1, 0.25),
    ]),
  ),
  'dungeon': StructureLoot(_dungeonLoot, bonus: _weapons),
  'tower': StructureLoot(_dungeonLoot, bonus: _weapons),
  'village': StructureLoot(
    LootTable([
      LootEntry('bread', 2, 5, 1.0),
      LootEntry('wheat', 3, 8, 0.8),
      LootEntry('wheat_seeds', 2, 6, 0.7),
      LootEntry('gold_ingot', 1, 2, 0.5),
      LootEntry('leather', 1, 3, 0.5),
      LootEntry('torch', 2, 6, 0.6),
      LootEntry('iron_ingot', 1, 2, 0.3),
    ]),
  ),
  'camp': StructureLoot(
    LootTable([
      LootEntry('apple', 1, 4, 0.9),
      LootEntry('bread', 1, 3, 0.7),
      LootEntry('arrow', 4, 10, 0.7),
      LootEntry('leather', 1, 3, 0.6),
      LootEntry('torch', 2, 6, 0.6),
      LootEntry('coal', 2, 6, 0.5),
    ]),
  ),
};

const LootTable _dungeonLoot = LootTable([
  LootEntry('iron_ingot', 2, 5, 0.8),
  LootEntry('arrow', 6, 14, 0.8),
  LootEntry('gold_ingot', 1, 3, 0.5),
  LootEntry('diamond', 1, 1, 0.3),
  LootEntry('health_potion', 1, 2, 0.6),
  LootEntry('magic_dust', 1, 3, 0.7),
  LootEntry('gem_shard', 1, 2, 0.4),
  LootEntry('glider', 1, 1, 0.15),
]);

/// The weapons a chest may hold with a bonus: 45 % of the time, one of these
/// at +1 to +6.
const LootBonus _weapons = LootBonus([
  'stone_sword',
  'iron_sword',
  'iron_dagger',
  'bow',
  'longbow',
  'staff',
  'diamond_sword',
  'crystal_staff',
]);

// The stock structures, built of the game's blocks.
const _village = Village(
  floor: 'cobblestone',
  walls: 'oak_planks',
  corners: 'oak_log',
  roof: 'oak_planks',
  path: 'gravel',
  wellRim: 'stone_bricks',
  water: 'water',
  roofRim: 'oak_slab',
  window: 'glass',
  chest: 'chest',
  bed: 'bed',
  torch: 'torch',
  workbench: 'crafting_table',
  furnace: 'furnace',
  light: 'lamp',
  farm: VillageFarm(soil: 'dirt', tilled: 'farmland', crop: 'wheat_2', fence: 'oak_fence', torch: 'torch'),
);
// A desert temple: two chests in a chamber under a step pyramid, and a plate in its floor over TNT.
const _temple = Temple(stone: 'sandstone', chest: 'chest', light: 'lamp', plate: 'pressure_plate', trap: 'tnt');

/// The dungeon, whose spawners and last room `Structures` finds.
const Dungeon dungeonStructure = Dungeon(
  walls: 'stone_bricks',
  mossy: 'mossy_stone_bricks',
  ladder: 'ladder',
  light: 'lamp',
  spawner: 'spawner',
  chest: 'chest',
  relic: 'bone_block',
  treasure: 'gold_ore',
);
const _tower = Tower(
  walls: 'stone_bricks',
  mossy: 'mossy_stone_bricks',
  floor: 'oak_planks',
  ladder: 'ladder',
  chest: 'chest',
  light: 'lamp',
);

/// The mine, whose spawner `Structures` finds.
const Mine mineStructure = Mine(
  frame: 'cobblestone',
  posts: 'oak_fence',
  roof: 'oak_planks',
  ladder: 'ladder',
  beams: 'oak_log',
  walls: 'cobblestone',
  rail: 'rail_ew',
  light: 'torch',
  chest: 'chest',
  spawner: 'spawner',
  veins: {'gold_ore': 5, 'iron_ore': 13},
);
const _ruins = Ruins(
  floor: 'cobblestone',
  ground: 'grass',
  walls: 'stone_bricks',
  mossy: 'mossy_stone_bricks',
  plants: ['tall_grass', 'flower_red'],
  chest: 'chest',
);
const _well = Well(rim: 'cobblestone', water: 'water', posts: 'oak_fence', roof: 'oak_planks');
const _camp = Camp(cloth: 'oak_planks', poles: 'oak_log', chest: 'chest', light: 'lamp');
