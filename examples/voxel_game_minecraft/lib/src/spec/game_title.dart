import 'package:flutter/widgets.dart';
import 'package:voxel_game/voxel_game.dart';

import 'platform_version.dart';

/// The title the game opens on: Play (the world list), Multiplayer (host a
/// world on 7777, or join one), Settings, the [credits] and, on a desktop,
/// Quit. A new world is made with two choices of the game's own, kept in
/// its `world.json`: the class its player plays ([classOption]) and whether
/// it is a playground ([playgroundOption]). The menu sits on [background] (the
/// app's `TitleVista`), the kit's dusk when null, and plays the meadow's track
/// ([titleTrack]).
TitleSpec gameTitle({required List<String> credits, WidgetBuilder? background}) => TitleSpec(
  name: 'Voxel Minecraft',
  tagline: 'a Minecraft clone built on voxel_game',
  worldOptions: const [classOption, playgroundOption],
  credits: credits,
  background: background,
  music: titleTrack,
);

/// The track the title plays, one of the game's (`gameSounds`).
const String titleTrack = 'meadow';

/// The class a new world's player plays, the warrior until another is
/// picked; a player joining a hosted world picks its own (`playerClasses`).
const WorldOption classOption = WorldOption(
  'class',
  label: 'Class',
  choices: {'warrior': 'Warrior', 'ranger': 'Ranger', 'mage': 'Mage', 'rogue': 'Rogue'},
  join: true,
);

/// Whether a new world is an open world or a playground, every feature laid
/// out around its spawn.
const WorldOption playgroundOption = WorldOption(
  'playground',
  label: 'Kind',
  choices: {'open': 'Open world', 'playground': 'Playground'},
);

/// Where the roadmap is bundled (`pubspec.yaml`'s assets), for [creditsOf].
const String roadmapAsset = 'ROADMAP.md';

/// The credits of a game whose roadmap is [roadmap]: what it is built on, its
/// sounds and its lineage, then every stage of the roadmap ([stagesOf]).
List<String> creditsOf(String roadmap) => creditsAround(stagesOf(roadmap));

/// The credits around [stages], a line each.
List<String> creditsAround(List<String> stages) => [
  'VOXEL MINECRAFT',
  '',
  'a Minecraft clone built on voxel_game, made to be played',
  '',
  'Engine',
  'the voxel kit: voxel_game over voxel_scene, voxel_engine and sound_recipes',
  'Flutter + flutter_scene 0.23 (Flutter GPU / Impeller), Dart $dartRuntimeVersion',
  'Dart for the game, a pool of isolates for chunk generation and meshing',
  '',
  'Fonts',
  'the system fallback font (no font files)',
  '',
  'Music and sound',
  'music synthesised by sound_recipes (StockMusic), footsteps from Dawnforge (the 2D game)',
  'every other sound procedural, rendered in Dart, all played through SoLoud',
  '',
  'Lineage',
  'the Godot POC (GDScript + C#), ported file by file; before it, the dev_3d_spike probe',
  '',
  'Stages',
  ...stages,
  '',
  '',
  'Thanks for playing.',
  '',
  'Esc closes',
];

/// Every `| N | title ...` row of [roadmap]'s stage table, as
/// "Stage N — title": the bold lead when the row has one, else the stage cell
/// cut at its first sentence.
List<String> stagesOf(String roadmap) {
  final row = RegExp(r'^\|\s*(\d+[ab]?)\s*\|\s*(.+?)\s*\|');
  final bold = RegExp(r'^\*\*(.+?)\*\*');
  final out = <String>[];
  for (final line in roadmap.split('\n')) {
    final m = row.firstMatch(line);
    if (m == null) continue;
    final cell = m.group(2)!;
    final b = bold.firstMatch(cell);
    var title = b != null ? b.group(1)! : cell.split('. ').first.split(' (').first;
    if (title.endsWith('.')) title = title.substring(0, title.length - 1);
    out.add('Stage ${m.group(1)} — $title');
  }
  return out;
}
