import 'dart:convert';
import 'dart:math' as math;

import 'package:vector_math/vector_math.dart';
import 'package:voxel_engine/content.dart';
import 'package:voxel_engine/core.dart';

import '../core/game_system.dart';
import '../core/voxel_game.dart';
import '../io/platform_io.dart';
import '../player/player_spec.dart';
import '../spec/voxel_game_spec.dart';
import 'world_info.dart';

/// What a save holds before a game starts from it: its seed, its edits and
/// the rest as JSON.
class SavedWorld {
  /// A save read from disk, its [edits] numbered as [dimensions] names them.
  const SavedWorld(this.seed, this.edits, this.state, {this.dimensions = const [VoxelGameSpec.mainDimension]});

  /// The world seed the save was made with (it wins over the spec's).
  final int seed;

  /// The world's edits, by the dimension's place in [dimensions].
  final EditsByDimension edits;

  /// The game's own state: clock, player, creatures kept.
  final Map<String, Object?> state;

  /// The id of each dimension [edits] numbers, in its order.
  final List<String> dimensions;

  /// [edits] numbered as [ids] (a game's `VoxelGameSpec.dimensionIds`)
  /// number the dimensions. Throws [StateError] for a dimension saved that
  /// [ids] lacks.
  EditsByDimension editsFor(List<String> ids) => {
    for (var i = 0; i < dimensions.length; i++) _indexIn(ids, dimensions[i]): edits[i] ?? <ChunkPos, Map<int, int>>{},
  };

  static int _indexIn(List<String> ids, String dimension) {
    final i = ids.indexOf(dimension);
    if (i < 0) throw StateError('the save holds dimension $dimension, which the game does not declare');
    return i;
  }
}

/// Saved worlds under one [directory], a folder per slot holding
/// `world.json` (what the world list shows: `WorldInfo`), `edits.bin` (the
/// edited cells of every dimension, `EditDeltaCodec`) and `game.json` (the
/// clock, the dimensions in the order `edits.bin` holds them, the crops
/// growing and what the stores hold in each, the creatures kept in every
/// dimension (`Mob.kept`: the tamed, owned by the player, and the
/// `MobSpec.persistent`, each with its home and its game's `Mob.data`,
/// `VoxelGame.mobRows`), the vehicles of every dimension, where each was
/// left (`VoxelGame.vehicleRows`), and the player: in which dimension, where,
/// looking where, health, hunger, experience, the effects on them, the bag,
/// what they wear, the spawn point, and the game's own state: each
/// `SavedSystem`'s under its key in `game`). A rider is not kept: the player
/// loads standing where saved.
///
/// A world [create]d and not yet played has only its `world.json`; a world
/// saved before there was one has only the other two, and [info] reads it
/// from them (its name is its slot, it plays as the game declares, when it
/// was made is not known) until its next [save] or [rename] writes one.
///
/// `game.json` is version 10. Older saves still load, each a branch on its
/// version: a version 1 save, from before the player had hunger, experience,
/// effects and armour, stands its player up fed, at level 0, wearing nothing;
/// a save before version 3 has no crops growing, and one before version 4
/// no stores (a store found in its world is looked into afresh); a save
/// before version 5 is of the main world alone, its crops and stores there,
/// its player in it, and its `edits.bin` of version 1, one dimension; a save
/// before version 6 keeps no creature, one before version 7 no vehicle, and
/// one before version 8 nothing of the game's own (its systems start as
/// made); a save before version 9 keeps creatures only where the player
/// is, each at home where it stands, with no game's data; and one before
/// version 10 marks a creature a boss as its species is (`Mob.boss`).
class WorldSaves {
  /// Saves under [directory]; [clock] says when a world is made and played.
  WorldSaves(this.directory, {this.clock = DateTime.now});

  /// Where the slots live.
  final Directory directory;

  /// Now.
  final DateTime Function() clock;

  /// The version of `game.json` [save] writes.
  static const stateVersion = 10;

  /// The edit file's layout for a game of [dimensions]: magic `VXK1`,
  /// version 2, every dimension; a version 1 file, of one dimension, still
  /// reads.
  static EditDeltaCodec codecFor(int dimensions) =>
      EditDeltaCodec(magic: 0x314B5856, version: 2, dimensions: dimensions, legacySingleDimensionVersion: 1);

  Directory _slot(String slot) {
    assert(slot.isNotEmpty && !slot.contains('/') && !slot.contains(r'\') && !slot.startsWith('.'));
    return Directory('${directory.path}/$slot');
  }

  File _state(String slot) => File('${_slot(slot).path}/game.json');

  File _info(String slot) => File('${_slot(slot).path}/world.json');

  /// Whether [slot] holds a saved game (a world made and never played holds
  /// none yet).
  bool exists(String slot) => _state(slot).existsSync();

  /// Whether [slot] is a world, played or not.
  bool contains(String slot) => _info(slot).existsSync() || exists(slot);

  /// Every slot that is a world.
  List<String> list() => !directory.existsSync()
      ? const []
      : [
          for (final d in directory.listSync().whereType<Directory>())
            if (d.uri.pathSegments.lastWhere((s) => s.isNotEmpty) case final slot
                when !slot.startsWith('.') && contains(slot))
              slot,
        ];

  /// Every world, the last played (or made) first.
  List<WorldInfo> worlds() => [for (final slot in list()) info(slot)]..sort((a, b) => b.touched.compareTo(a.touched));

  /// What [slot] says about its world; throws when it is not one.
  WorldInfo info(String slot) {
    final file = _info(slot);
    if (file.existsSync()) {
      return WorldInfo.fromJson(slot, jsonDecode(file.readAsStringSync()) as Map<String, Object?>, saved: exists(slot));
    }
    // Saved before worlds had a world.json: what game.json knows.
    final state = _state(slot);
    final s = jsonDecode(state.readAsStringSync()) as Map<String, Object?>;
    return WorldInfo(
      slot: slot,
      name: slot,
      seed: (s['seed']! as num).toInt(),
      saved: true,
      lastPlayed: state.lastModifiedSync(),
      playTime: Duration(microseconds: ((s['time']! as num) * 1e6).round()),
    );
  }

  /// Makes a world named [name] from [seed] (see [seedOf]), to be played as
  /// [mode] (null: as the game declares) with the game's [options]
  /// (`WorldInfo.options`), in a slot of its own: the name in lower case, a
  /// number after it when that slot is taken. Nothing but its `world.json`
  /// is written; its first [save] writes the rest.
  WorldInfo create(String name, {required int seed, WorldMode? mode, Map<String, String> options = const {}}) {
    final clean = name.trim();
    if (clean.isEmpty) throw ArgumentError.value(name, 'name', 'a world needs a name');
    final base = _slugOf(clean);
    var slot = base;
    for (var n = 2; _slot(slot).existsSync(); n++) {
      slot = '${base}_$n';
    }
    final info = WorldInfo(
      slot: slot,
      name: clean,
      seed: seed,
      saved: false,
      mode: mode,
      options: options,
      created: clock(),
    );
    _writeInfo(info);
    return info;
  }

  /// Names [slot]'s world [name]; its slot stays.
  WorldInfo rename(String slot, String name) {
    final clean = name.trim();
    if (clean.isEmpty) throw ArgumentError.value(name, 'name', 'a world needs a name');
    final info = this.info(slot).copyWith(name: clean);
    _writeInfo(info);
    return info;
  }

  /// The seed a player typed: a whole number is itself, any other text its
  /// FNV-1a hash (the same seed every run and on every platform, which
  /// `String.hashCode` is not), and nothing at all a seed drawn from [random].
  static int seedOf(String text, {math.Random? random}) {
    final t = text.trim();
    if (t.isEmpty) return (random ?? math.Random()).nextInt(1 << 31);
    if (RegExp(r'^-?\d{1,18}$').hasMatch(t)) return int.parse(t);
    var h = 0x811c9dc5;
    for (final c in utf8.encode(t)) {
      h = ((h ^ c) * 0x01000193) & 0xFFFFFFFF;
    }
    return h;
  }

  /// A slot for [name]: lower case, every run of characters a folder name
  /// might not hold one underscore.
  static String _slugOf(String name) {
    final slug = name.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    return slug.isEmpty ? 'world' : slug;
  }

  // Written beside and renamed over, so a crash mid-write keeps the old one.
  static void _writeAtomic(File file, String text) {
    File('${file.path}.tmp')
      ..writeAsStringSync(text)
      ..renameSync(file.path);
  }

  void _writeInfo(WorldInfo info) {
    _slot(info.slot).createSync(recursive: true);
    _writeAtomic(_info(info.slot), jsonEncode(info.toJson()));
  }

  /// Deletes [slot].
  void delete(String slot) {
    final d = _slot(slot);
    if (d.existsSync()) d.deleteSync(recursive: true);
  }

  /// Writes [game] to [slot], and its `world.json`: played now, for the
  /// game's time. A slot that was no world yet is named after itself and
  /// made now.
  void save(VoxelGame game, String slot) {
    final now = clock();
    final before = contains(slot) ? info(slot) : null;
    final d = _slot(slot)..createSync(recursive: true);
    final ids = game.spec.dimensionIds;
    final seed = game.world.generators.seed;
    File('${d.path}/edits.bin').writeAsBytesSync(codecFor(ids.length).encode(seed, game.world.edits));
    final p = game.player;
    final rules = game.blockRules;
    final state = <String, Object?>{
      'version': stateVersion,
      'seed': seed,
      'time': game.time,
      'timeOfDay': game.timeOfDay,
      'dimensions': ids,
      'growing': {
        for (var i = 0; i < ids.length; i++)
          ids[i]: [
            for (final e in rules.growingIn(i).entries) [e.key.x, e.key.y, e.key.z, e.value],
          ],
      },
      'stores': {
        for (var i = 0; i < ids.length; i++)
          ids[i]: [
            for (final e in rules.storesIn(i).entries) [e.key.x, e.key.y, e.key.z, e.value.toJson()],
          ],
      },
      'mobs': game.mobRows,
      'vehicles': game.vehicleRows,
      'player': {
        'dimension': game.dimension,
        'pos': [p.position.x, p.position.y, p.position.z],
        'spawn': [p.spawnPoint.x, p.spawnPoint.y, p.spawnPoint.z],
        'yaw': p.yaw,
        'pitch': p.pitch,
        'hp': p.hp,
        'slot': p.selectedSlot,
        'view': p.cameraMode.name,
        'inventory': p.inventory.toJson(),
        'hunger': p.hunger,
        'xp': p.xp,
        'level': p.level,
        'effects': p.effects.toJson(),
        'worn': {for (final e in p.worn.entries) e.key: e.value.toJson()},
      },
      'game': {for (final s in game.systems.whereType<SavedSystem>()) s.saveKey: s.save(game)},
    };
    _writeAtomic(_state(slot), jsonEncode(state));
    final played = Duration(microseconds: (game.time * 1e6).round());
    _writeInfo(
      before?.copyWith(saved: true, lastPlayed: now, playTime: played) ??
          WorldInfo(slot: slot, name: slot, seed: seed, saved: true, created: now, lastPlayed: now, playTime: played),
    );
  }

  /// Reads [slot]'s saved game; throws when it has none or it is unreadable.
  SavedWorld read(String slot) {
    final d = _slot(slot);
    final state = jsonDecode(_state(slot).readAsStringSync()) as Map<String, Object?>;
    // Before version 5, the main world alone.
    final dimensions = [
      for (final id in state['dimensions'] as List<Object?>? ?? const [VoxelGameSpec.mainDimension]) id! as String,
    ];
    final edits = File('${d.path}/edits.bin');
    final decoded = edits.existsSync() ? codecFor(dimensions.length).decode(edits.readAsBytesSync()) : null;
    final seed = (state['seed']! as num).toInt();
    return SavedWorld(seed, decoded?.edits ?? <int, Map<ChunkPos, Map<int, int>>>{}, state, dimensions: dimensions);
  }

  /// Puts [saved]'s clock, crops, stores, creatures, vehicles, player and the
  /// state of the game's systems back into [game] (its edits are handed to
  /// the world before it streams: see `VoxelGame.start`). A tamed creature is
  /// the local player's. Throws for a system's state saved under a key no
  /// system of [game]'s saves under.
  static void restore(VoxelGame game, SavedWorld saved) {
    final s = saved.state;
    game.time = (s['time']! as num).toDouble();
    game.timeOfDay = (s['timeOfDay']! as num).toDouble();
    final p = s['player'] as Map<String, Object?>?;
    if (p == null) return; // a network hello carries the world, not a player
    final version = (s['version']! as num).toInt();
    if (version < 1 || version > stateVersion) {
      throw StateError('game.json version $version: this kit reads 1 to $stateVersion');
    }
    final ids = game.spec.dimensionIds;
    if (version >= 5) {
      final d = SavedWorld._indexIn(ids, p['dimension']! as String);
      if (d != game.world.dimension) game.world.switchDimension(d);
    }
    Vector3 v(Object? o) {
      final l = [for (final e in o! as List<Object?>) (e! as num).toDouble()];
      return Vector3(l[0], l[1], l[2]);
    }

    game.player
      ..restore(v(p['pos']), v(p['spawn']))
      ..yaw = (p['yaw']! as num).toDouble()
      ..pitch = (p['pitch']! as num).toDouble()
      ..hp = (p['hp']! as num).toDouble()
      ..selectedSlot = (p['slot']! as num).toInt()
      ..cameraMode = CameraMode.values.byName(p['view']! as String);
    game.player.inventory.fromJson(p['inventory']! as List<Object?>, known: game.items.has);
    if (version >= 2) _restoreSurvival(game, p);
    // Health is 0 only in death: a player saved on the death screen loads on it.
    if (game.player.hp <= 0.0) game.player.kill();
    // Before version 5, one list each, of the main world.
    Map<String, Object?> byDimension(Object? o) => version >= 5 ? o! as Map<String, Object?> : {ids.first: o};
    if (version >= 3) {
      for (final g in byDimension(s['growing']).entries) {
        final growing = <IVec3, double>{};
        for (final e in g.value! as List<Object?>) {
          final n = [for (final v in e! as List<Object?>) v! as num];
          growing[IVec3(n[0].toInt(), n[1].toInt(), n[2].toInt())] = n[3].toDouble();
        }
        game.blockRules.restoreGrowing(growing, dimension: SavedWorld._indexIn(ids, g.key));
      }
    }
    if (version >= 4) {
      for (final k in byDimension(s['stores']).entries) {
        final stores = <IVec3, List<Object?>>{};
        for (final e in k.value! as List<Object?>) {
          final row = e! as List<Object?>;
          stores[IVec3((row[0]! as num).toInt(), (row[1]! as num).toInt(), (row[2]! as num).toInt())] =
              row[3]! as List<Object?>;
        }
        game.blockRules.restoreStores(stores, dimension: SavedWorld._indexIn(ids, k.key));
      }
    }
    if (version >= 6) _restoreMobs(game, s['mobs']! as Map<String, Object?>, version);
    if (version >= 7) {
      for (final e in (s['vehicles']! as Map<String, Object?>).entries) {
        game.restoreVehicles(e.key, [for (final r in e.value! as List<Object?>) r! as Map<String, Object?>]);
      }
    }
    if (version >= 8) _restoreSystems(game, s['game']! as Map<String, Object?>);
  }

  static void _restoreSystems(VoxelGame game, Map<String, Object?> state) {
    final byKey = {for (final s in game.systems.whereType<SavedSystem>()) s.saveKey: s};
    for (final e in state.entries) {
      final system = byKey[e.key];
      if (system == null) throw StateError('the save keeps game state ${e.key}, which no system of the game saves');
      system.restore(game, e.value);
    }
  }

  // Before version 9 a creature kept no home (it wandered about where it was
  // loaded) and no game's data, and only the player's dimension had any;
  // before version 10 it was a boss as its species is.
  static void _restoreMobs(VoxelGame game, Map<String, Object?> byDimension, int version) {
    Map<String, Object?> current(Map<String, Object?> row) => {
      ...row,
      if (version < 9) 'home': row['pos'],
      if (version < 9) 'data': <String, Object?>{},
      if (version < 10) 'boss': game.mobSpec(row['id']! as String).boss,
    };
    for (final e in byDimension.entries) {
      game.restoreMobs(e.key, [
        for (final row in (e.value! as List<Object?>).cast<Map<String, Object?>>()) current(row),
      ]);
    }
  }

  static void _restoreSurvival(VoxelGame game, Map<String, Object?> p) {
    game.player
      ..hunger = (p['hunger']! as num).toDouble()
      ..xp = (p['xp']! as num).toInt()
      ..level = (p['level']! as num).toInt();
    game.player.effects.fromJson(p['effects']! as Map<String, Object?>);
    for (final e in (p['worn']! as Map<String, Object?>).entries) {
      final stack = ItemStack.fromJson(e.value! as Map<String, Object?>);
      if (game.items.has(stack.id)) game.player.putOn(e.key, stack);
    }
  }
}
