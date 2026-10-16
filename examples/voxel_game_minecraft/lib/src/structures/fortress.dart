import 'package:voxel_engine/worldgen.dart';
import 'package:voxel_engine/core.dart';

/// Where the parts of a fortress lie: a hall of [length] running +x from
/// [start] at floor height [floor], centred on its site's [z]; the throne
/// room past its far end with the [core] in the middle of its floor; a side
/// room off each wall with a chest; and the blazes' spot at the hall's
/// [middle]. The structure ([fortress]) draws from it and the game
/// (`Structures`) finds the core and the blazes by it.
class FortressPlan {
  const FortressPlan._(this.start, this.floor, this.z, this.length);

  /// The plan of the fortress whose site is at ([x], [z]): [roll] is its
  /// roll (`StructureSite.roll`, or the generator's `hash(x, salt, z)`).
  factory FortressPlan.of(int x, int z, int Function(int salt) roll) {
    final length = shortest + roll(30) % (longest - shortest + 1);
    final floor = lowest + roll(31) % (highest - lowest + 1);
    return FortressPlan._(x - (length + 10) ~/ 2, floor, z, length);
  }

  /// The hall's length, at the shortest and the longest.
  static const int shortest = 40, longest = 60;

  /// The floor's height, at the lowest and the highest.
  static const int lowest = 50, highest = 70;

  /// How far it reaches from its site: half of the longest hall and its
  /// throne room.
  static const int radius = (longest + 10) ~/ 2;

  /// The world x of the hall's first cell.
  final int start;

  /// The world y of the floor.
  final int floor;

  /// The world z of the hall's middle line.
  final int z;

  /// The hall's length.
  final int length;

  /// The core's cell, the middle of the throne room's floor.
  IVec3 get core => IVec3(start + length + 5, floor, z);

  /// The cell over the hall's middle, where its blazes wake.
  IVec3 get middle => IVec3(start + length ~/ 2, floor + 1, z);
}

/// The underworld's fortress: a nether-brick hall 5 wide and 5 tall inside,
/// 40 to 60 long, at a height of 50 to 70 over the lava sea, with pillars
/// down to the rock every 8 blocks, arched windows on both sides and
/// glowstone in its ceiling; a side room (a chest each) off each wall; and a
/// throne room 9 x 9 and 7 tall past its far end, a lava moat sunk in its
/// floor ring and the sealed core in its middle ([FortressPlan]). The core
/// stays sealed until the lord is dead (`Structures`).
const CustomStructure fortress = CustomStructure(
  _draw,
  radius: FortressPlan.radius,
  blocks: {_brick, _glow, _lava, _chest, sealedCore},
);

/// The core as the fortress is built: unbreakable, swapped for [openCore]
/// when its lord dies.
const String sealedCore = 'sealed_core';

/// The core its lord's death leaves: mined, it gives the underworld heart.
const String openCore = 'fortress_core';

const String _brick = 'nether_brick', _glow = 'glowstone', _lava = 'lava', _chest = 'chest';

void _draw(StructureSite site) {
  final plan = FortressPlan.of(site.x, site.z, site.roll);
  void put(int x, int y, int z, String name) => site.put(x - site.x, y - site.y, z - site.z, name);
  // Down from under the floor to the rock, through air and lava.
  void pillar(int x, int z) {
    for (var y = plan.floor - 1; site.isOpen(x - site.x, y - site.y, z - site.z); y--) {
      put(x, y, z, _brick);
    }
  }

  final sx = plan.start, sy = plan.floor, sz = plan.z, len = plan.length;
  // The hall: walls at z +-3, floor and ceiling, the inside cleared.
  for (var x = 0; x <= len; x++) {
    for (var z = -3; z <= 3; z++) {
      for (var y = 0; y <= 6; y++) {
        final wall = z.abs() == 3 || y == 0 || y == 6;
        var name = wall ? _brick : 'air';
        if (wall && z.abs() == 3 && y >= 2 && y <= 4 && x % 6 == 3 && x > 2 && x < len - 2) name = 'air';
        if (wall && z.abs() == 3 && y == 3 && x % 6 == 0) name = _glow;
        if (y == 6 && z == 0 && x % 8 == 4) name = _glow;
        put(sx + x, sy + y, sz + z, name);
      }
    }
    if (x % 8 == 0) {
      pillar(sx + x, sz - 3);
      pillar(sx + x, sz + 3);
    }
  }
  _sideRoom(put, sx + len ~/ 3, sy, sz, 1);
  _sideRoom(put, sx + len * 2 ~/ 3, sy, sz, -1);
  // The throne room, its door from the hall.
  final core = plan.core;
  for (var x = -5; x <= 5; x++) {
    for (var z = -5; z <= 5; z++) {
      for (var y = 0; y <= 8; y++) {
        final wall = x.abs() == 5 || z.abs() == 5 || y == 0 || y == 8;
        var name = wall ? _brick : 'air';
        if (x == -5 && z.abs() <= 1 && y >= 1 && y <= 4) name = 'air';
        if (wall && y == 4 && x.abs() != 5 && z.abs() == 5 && x % 3 == 0) name = _glow;
        if (wall && y == 4 && x == 5 && z % 3 == 0) name = _glow;
        if (y == 0 && (z.abs() == 4 || x.abs() == 4) && !(x == -4 && z.abs() <= 1)) name = _lava;
        if (y == 8 && x % 3 == 0 && z % 3 == 0) name = _glow;
        if (y == 0 && x == 0 && z == 0) name = sealedCore;
        put(core.x + x, sy + y, core.z + z, name);
      }
      put(core.x + x, sy - 1, core.z + z, _brick);
      if (x.abs() == 5 && z.abs() == 5) pillar(core.x + x, core.z + z);
    }
  }
  // A dais behind the core, a glowstone on it.
  for (var z = -2; z <= 2; z++) {
    put(core.x + 3, sy + 1, core.z + z, _brick);
  }
  put(core.x + 3, sy + 2, core.z, _glow);
}

/// A room 5 x 5 inside off the hall's wall on [side] (+1 the +z wall, -1 the
/// -z), at [x] along it, its door through the wall and a chest at its back.
void _sideRoom(void Function(int x, int y, int z, String name) put, int x, int y, int hallZ, int side) {
  final zc = hallZ + side * 6;
  for (var dx = -3; dx <= 3; dx++) {
    for (var dz = -3; dz <= 3; dz++) {
      for (var dy = 0; dy <= 5; dy++) {
        final wall = dx.abs() == 3 || dz.abs() == 3 || dy == 0 || dy == 5;
        final door = zc + dz == hallZ + side * 3 && dx.abs() <= 1 && dy >= 1 && dy <= 3;
        put(x + dx, y + dy, zc + dz, wall && !door ? _brick : 'air');
      }
    }
  }
  put(x, y + 1, hallZ + side * 7, _chest);
  put(x, y + 4, zc, _glow);
}
