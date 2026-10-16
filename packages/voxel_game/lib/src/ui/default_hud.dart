import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:vector_math/vector_math.dart' show Vector3;

import '../core/voxel_game.dart';
import '../input/input_device.dart';
import '../input/voxel_action.dart';
import '../mobs/mob.dart';
import '../net/remote_player.dart';
import 'damage_numbers.dart';
import 'hud_bar.dart';
import 'hud_selector.dart';
import 'item_icon.dart';
import 'notices.dart';

/// One status effect as the HUD shows it.
typedef _EffectChip = ({String id, int power, int seconds});

/// The kit's HUD: a crosshair that turns red on a creature in reach, a ring
/// around it filling as the aimed block is mined, the hotbar with counts and
/// what is left of a worn tool, health, and "click to play" while the mouse is
/// free and no screen is open (the death screen is one: `DeathMenu`). Pass
/// your own `HudBuilder` to replace it, or build on its pieces.
///
/// **Over the world**, projected through the frame's camera
/// (`VoxelGame.camera`): a health bar over each creature hurt in the last
/// [barSeconds] or under the crosshair, and the damage each hit dealt
/// (`VoxelGame.damageNumbers`), rising and fading; a critical blow's in
/// yellow, ending in `!`; over each other player of a networked game within
/// [nameRange], alive and in the player's dimension, its name
/// (`RemotePlayer.name`). While the camera is in a
/// liquid the screen is washed in its colour (`LiquidSpec.tint`); while a
/// boss lives (`MobSpec.boss`) the nearest one's health is a bar at the top;
/// with `GameSettings.showFps` the rate the world is drawn at (`FrameStats.fps`)
/// is at the top left.
///
/// **What the spec declares, it shows, and nothing else**: the hunger beside
/// the hearts only with `PlayerSpec.hunger`, the experience bar and level only
/// with `PlayerSpec.xp`, the status effects (top left, each with its time
/// left) only when `VoxelGameSpec.effects` names some. Armour shows over the
/// hearts while the player has any. A game's own [bars] (stamina, mana) sit
/// under the hearts, over the experience.
///
/// At the right, `VoxelGame.notices`: what the game told the player
/// (`VoxelGame.notify`), and under it what went into the bag (`+5 Dirt`),
/// each line fading out after a few seconds.
///
/// It is built once; each piece that changes is a [HudSelector] on
/// [VoxelGame.frames], rebuilt only when the value it reads changes.
///
/// **The hotbar is a finger's too**, unless the game declared no
/// `VoxelGameSpec.touchControls`. A tap on a slot picks it; a hold on the slot
/// in hand drops one of what it holds, after the spec's `dropHold`; and while
/// the last device was a finger, a `⋯` after the last slot opens the bag. Each
/// slot claims the finger that lands on it (`InputMap.claimTouch`), so that
/// finger is never also a tap on the world. A mouse over the hotbar is still
/// the world's: only a touch picks a slot. Every other piece is behind an
/// [IgnorePointer], so a touch there reaches whatever is under the HUD.
class DefaultHud extends StatelessWidget {
  /// The HUD of [game], with the game's own [bars].
  const DefaultHud(this.game, {this.bars = const [], super.key});

  /// A `HudBuilder` of this HUD.
  static Widget builder(BuildContext context, VoxelGame game) => DefaultHud(game);

  /// The game shown.
  final VoxelGame game;

  /// The game's own bars, in this order under the hearts.
  final List<HudBar> bars;

  /// How wide a bar of [bars] is drawn, its label beside it.
  static const double barWidth = 160.0;

  /// Seconds a creature's bar stays up after it is hurt.
  static const double barSeconds = 4.0;

  /// Metres past which a creature shows no bar.
  static const double barRange = 40.0;

  /// Metres within which another player's name shows over it.
  static const double nameRange = 32.0;

  static const _shadow = [Shadow(offset: Offset(1, 1), blurRadius: 2)];

  static Color _color(double r, double g, double b) =>
      Color.fromARGB(255, (r * 255).round(), (g * 255).round(), (b * 255).round());

  @override
  Widget build(BuildContext context) {
    final p = game.player;
    final inv = p.inventory;
    final frames = game.frames;
    final touch = game.spec.touchControls;
    assert(touch == null || touch.dropHold > Duration.zero, 'TouchControlsSpec.dropHold must be positive');
    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          child: Stack(
            fit: StackFit.expand,
            children: [
              HudSelector(
                frames: frames,
                select: () => game.eyeLiquid?.id,
                builder: (context, id) {
                  if (id == null) return const SizedBox.shrink();
                  final t = game.blocks[game.blocks.indexOf(id)];
                  final tint = game.liquid(t.liquid!).tint;
                  return tint > 0.0
                      ? ColoredBox(color: _color(t.r, t.g, t.b).withValues(alpha: tint))
                      : const SizedBox.shrink();
                },
              ),
              HudSelector(
                frames: frames,
                select: _marksShown,
                builder: (context, shown) =>
                    shown ? RepaintBoundary(child: CustomPaint(painter: _WorldMarks(game))) : const SizedBox.shrink(),
              ),
              HudSelector(
                frames: frames,
                select: () => p.hurtFlash,
                builder: (context, flash) => flash > 0.0
                    ? ColoredBox(color: Colors.red.withValues(alpha: 0.35 * flash))
                    : const SizedBox.shrink(),
              ),
              Center(
                child: HudSelector(
                  frames: frames,
                  select: () => p.aimedMob != null,
                  builder: (context, onCreature) =>
                      Icon(Icons.add, color: onCreature ? Colors.redAccent : Colors.white70, size: 22),
                ),
              ),
              Center(
                child: HudSelector(
                  frames: frames,
                  select: () => p.mineProgress,
                  builder: (context, progress) => progress > 0.0
                      ? SizedBox(
                          width: 34,
                          height: 34,
                          child: CircularProgressIndicator(
                            value: progress,
                            strokeWidth: 3,
                            color: Colors.white.withValues(alpha: 0.9),
                            backgroundColor: Colors.black26,
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ),
              Align(
                alignment: Alignment.topCenter,
                child: Padding(padding: const EdgeInsets.only(top: 12), child: _bossBar()),
              ),
              HudSelector(
                frames: frames,
                select: () => (
                  hidden: game.input.isCaptured || game.screen.value != null,
                  touch: game.input.lastDevice == InputDevice.touch,
                ),
                builder: (context, s) => s.hidden
                    ? const SizedBox.shrink()
                    : Center(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 80),
                          child: Text(
                            s.touch ? 'Tap to play' : 'Click to play  -  WASD move, Space jump, mouse look, left mine, right place, V view, E bag, Esc menu',
                            style: const TextStyle(fontSize: 14, shadows: _shadow),
                          ),
                        ),
                      ),
              ),
              Align(
                alignment: const Alignment(1, -0.3),
                child: Padding(padding: const EdgeInsets.only(right: 16), child: _notices()),
              ),
              Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      HudSelector(
                        frames: frames,
                        select: () => game.settings.value.showFps ? game.stats.fps.round() : null,
                        builder: (context, fps) => fps == null
                            ? const SizedBox.shrink()
                            : Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Text(
                                  'FPS $fps',
                                  style: const TextStyle(fontSize: 13, color: Color(0xE6FFFF99), shadows: _shadow),
                                ),
                              ),
                      ),
                      if (game.spec.effects.isNotEmpty) _effects(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                IgnorePointer(child: _bars()),
                const SizedBox(height: 6),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < inv.hotbarSize; i++)
                      HudSelector(
                        frames: frames,
                        select: () =>
                            (id: inv.idAt(i), count: inv.countAt(i), uses: inv.durAt(i), selected: i == p.selectedSlot),
                        builder: (context, slot) {
                          final face = _slot(slot.id, slot.count, slot.uses, selected: slot.selected);
                          if (touch == null) return face;
                          return _touchable(
                            onTap: () => game.input.touchDigit(i),
                            onHold: slot.selected
                                ? (after: touch.dropHold, run: () => game.input.touchPress(VoxelAction.drop))
                                : null,
                            child: face,
                          );
                        },
                      ),
                    if (touch != null)
                      HudSelector(
                        frames: frames,
                        select: () => game.input.lastDevice == InputDevice.touch,
                        builder: (context, fingers) => fingers
                            ? _touchable(
                                onTap: () => game.input.touchPress(VoxelAction.inventory),
                                child: _box(
                                  selected: false,
                                  child: const Icon(Icons.more_horiz, color: Colors.white, size: 24),
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                  ],
                ),
                IgnorePointer(
                  child: HudSelector(
                    frames: frames,
                    select: () => inv.isEmptySlot(p.selectedSlot) ? null : game.items[p.heldItem].name,
                    builder: (context, name) => name == null
                        ? const SizedBox.shrink()
                        : Text(name, style: const TextStyle(fontSize: 13, shadows: _shadow)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Armour over the hearts, hunger beside them, the game's [bars] and the
  /// experience bar under them: each only as declared.
  Widget _bars() {
    final p = game.player;
    final frames = game.frames;
    final hunger = game.spec.player.hunger;
    final xp = game.spec.player.xp;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HudSelector(
          frames: frames,
          select: () => p.armor,
          builder: (context, armor) => armor > 0.0
              ? _icons(armor, armor, full: Icons.shield, half: Icons.shield_outlined, color: Colors.blueGrey.shade100)
              : const SizedBox.shrink(),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            HudSelector(
              frames: frames,
              select: () => (hp: p.hp, max: p.maxHp),
              builder: (context, s) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < (s.max / 2).ceil(); i++)
                    Icon(
                      s.hp >= (i + 1) * 2
                          ? Icons.favorite
                          : (s.hp > i * 2 ? Icons.heart_broken : Icons.favorite_border),
                      color: Colors.redAccent,
                      size: 18,
                    ),
                ],
              ),
            ),
            if (hunger != null) ...[
              const SizedBox(width: 12),
              HudSelector(
                frames: frames,
                select: () => p.hunger.ceil(),
                builder: (context, food) => _icons(
                  food.toDouble(),
                  hunger.max,
                  full: Icons.restaurant,
                  half: Icons.restaurant,
                  color: Colors.orange.shade300,
                ),
              ),
            ],
          ],
        ),
        for (final bar in bars) _gameBar(bar),
        if (xp != null)
          HudSelector(
            frames: frames,
            select: () => (level: p.level, fill: p.xp / xp.toNext(p.level)),
            builder: (context, s) => SizedBox(
              width: 360,
              height: 16,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    height: 5,
                    child: LinearProgressIndicator(
                      value: s.fill,
                      color: Colors.lightGreenAccent.shade400,
                      backgroundColor: Colors.black54,
                    ),
                  ),
                  if (s.level > 0)
                    Text(
                      '${s.level}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: Colors.lightGreenAccent.shade400,
                        shadows: _shadow,
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// One of the game's [bars]: its label, then the bar.
  Widget _gameBar(HudBar bar) => HudSelector(
    frames: game.frames,
    select: () {
      final fill = bar.fill(game);
      if (!(fill >= 0.0 && fill <= 1.0)) throw StateError('the bar ${bar.label} is filled to $fill, not 0..1');
      return (fill * 100).round();
    },
    builder: (context, percent) => Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            bar.label,
            style: TextStyle(fontSize: 12, color: bar.color, shadows: _shadow),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: barWidth,
            height: 6,
            child: LinearProgressIndicator(value: percent / 100, color: bar.color, backgroundColor: Colors.black54),
          ),
        ],
      ),
    ),
  );

  /// [of] in icons of two points each, as many as [max] fills: [full] for two,
  /// a faded [half] for one, an outline of [full] for none.
  static Widget _icons(double of, double max, {required IconData full, required IconData half, required Color color}) =>
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < (max / 2).ceil(); i++)
            Icon(
              of >= (i + 1) * 2 ? full : half,
              color: of >= (i + 1) * 2 ? color : (of > i * 2 ? color.withValues(alpha: 0.5) : Colors.white24),
              size: 18,
            ),
        ],
      );

  /// The status effects on the player, a row each: its colour, its name, its
  /// power past the first and its time left.
  Widget _effects() => HudSelector<List<_EffectChip>>(
    frames: game.frames,
    select: () => [
      for (final e in game.player.effects.rows.entries)
        (id: e.key, power: e.value.power.round(), seconds: e.value.time.ceil()),
    ],
    equals: listEquals<_EffectChip>,
    builder: (context, rows) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final r in rows)
          Builder(
            builder: (context) {
              final t = game.player.effects.typeOf(r.id);
              final color = _color(t.r, t.g, t.b);
              return Container(
                margin: const EdgeInsets.only(bottom: 4),
                padding: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  border: Border(left: BorderSide(color: color, width: 5)),
                ),
                child: Padding(
                  padding: const EdgeInsets.only(left: 7, top: 2, bottom: 2),
                  child: Text(
                    '${t.name}${r.power > 1 ? ' ${r.power}' : ''}  ${_clock(r.seconds)}',
                    style: TextStyle(fontSize: 13, color: t.bad ? color : Colors.white, shadows: _shadow),
                  ),
                ),
              );
            },
          ),
      ],
    ),
  );

  /// The feed over the pickups, newest at the bottom of each.
  Widget _notices() {
    final notices = game.notices;
    Widget lines(List<NoticeLine> lines, {required Color color}) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final n in lines)
          AnimatedOpacity(
            key: ValueKey(n.id),
            opacity: n.fading ? 0.0 : 1.0,
            duration: Duration(milliseconds: (Notices.fadeSeconds * 1000).round()),
            child: Container(
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              color: Colors.black45,
              child: Text(
                n.text,
                style: TextStyle(fontSize: 15, color: color, shadows: _shadow),
              ),
            ),
          ),
      ],
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        HudSelector<List<NoticeLine>>(
          frames: game.frames,
          select: () => notices.feed,
          equals: listEquals<NoticeLine>,
          builder: (context, feed) => lines(feed, color: Colors.white),
        ),
        const SizedBox(height: 8),
        HudSelector<List<NoticeLine>>(
          frames: game.frames,
          select: () => notices.pickups,
          equals: listEquals<NoticeLine>,
          builder: (context, pickups) => lines(pickups, color: const Color(0xFFFFFFBF)),
        ),
      ],
    );
  }

  /// [seconds] as `m:ss`, or `Ns` under a minute.
  static String _clock(int seconds) =>
      seconds < 60 ? '${seconds}s' : '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

  /// [child] answering a finger: [onTap] on a tap, and [onHold]'s `run` once
  /// the finger has stayed its `after` (when given). The finger is claimed as
  /// it lands, so the world never reads it; a mouse passes through to the
  /// world.
  Widget _touchable({
    required VoidCallback onTap,
    ({Duration after, VoidCallback run})? onHold,
    required Widget child,
  }) {
    const touch = {PointerDeviceKind.touch};
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) {
        if (e.kind == PointerDeviceKind.touch) game.input.claimTouch(e.pointer);
      },
      child: RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: {
          TapGestureRecognizer: GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
            () => TapGestureRecognizer(supportedDevices: touch),
            (r) => r.onTap = onTap,
          ),
          if (onHold != null)
            LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
              () => LongPressGestureRecognizer(duration: onHold.after, supportedDevices: touch),
              (r) => r.onLongPress = onHold.run,
            ),
        },
        child: child,
      ),
    );
  }

  /// A hotbar slot holding [count] of item [id] (`''` for an empty one), a
  /// worn one with [uses] left (`Inventory.durAt`) showing a bar under it.
  Widget _slot(String id, int count, int uses, {required bool selected}) => _box(
    selected: selected,
    child: id.isEmpty
        ? null
        : Stack(
            children: [
              Center(child: ItemIcon(game.itemModel(id), size: 32)),
              if (count > 1)
                Positioned(
                  right: 3,
                  bottom: 1,
                  child: Text('$count', style: const TextStyle(fontSize: 12, shadows: _shadow)),
                ),
              if (_wear(id, uses) case final left?)
                Positioned(
                  left: 5,
                  right: 5,
                  bottom: 4,
                  height: 4,
                  child: ColoredBox(
                    color: Colors.black87,
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: left,
                      child: ColoredBox(color: Color.lerp(Colors.red, Colors.greenAccent.shade400, left)!),
                    ),
                  ),
                ),
            ],
          ),
  );

  /// What is left of item [id] with [uses] left, 0..1, or null for one that
  /// never wears or is not worn yet.
  double? _wear(String id, int uses) {
    final full = game.items[id].durability;
    return full > 0 && uses < full ? uses / full : null;
  }

  /// Whether anything is projected over the world: a creature's bar, a
  /// damage number or another player's name. Nothing is painted, and nothing
  /// repaints, while not.
  bool _marksShown() =>
      game.damageNumbers.shown.isNotEmpty ||
      game.mobs.any((m) => _WorldMarks.barred(game, m)) ||
      game.remotePlayers.any((r) => _WorldMarks.named(game, r));

  /// The nearest boss's name and health, at the top, while one lives.
  Widget _bossBar() => HudSelector(
    frames: game.frames,
    select: () {
      final b = game.boss;
      return b == null ? null : (name: b.spec.name, hp: b.hp.ceil(), max: b.maxHp);
    },
    builder: (context, b) => b == null
        ? const SizedBox.shrink()
        : FractionallySizedBox(
            widthFactor: 0.45,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${b.name}   ${b.hp} / ${b.max.ceil()}',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, shadows: _shadow),
                ),
                const SizedBox(height: 3),
                SizedBox(
                  height: 10,
                  child: LinearProgressIndicator(
                    value: (b.hp / b.max).clamp(0.0, 1.0),
                    color: const Color(0xFFB31A80),
                    backgroundColor: Colors.black54,
                  ),
                ),
              ],
            ),
          ),
  );

  /// The square every hotbar cell is drawn in, lit while [selected].
  static Widget _box({required bool selected, Widget? child}) => Container(
    width: 44,
    height: 44,
    margin: const EdgeInsets.all(2),
    decoration: BoxDecoration(
      color: Colors.black45,
      border: Border.all(color: selected ? Colors.white : Colors.white24, width: selected ? 3 : 1),
    ),
    child: child,
  );
}

/// What the HUD projects from the world through the frame's camera: a bar
/// over each creature [barred], the [DamageNumbers], and the name over each
/// other player [named]. Repaints every frame it is shown, never rebuilds.
class _WorldMarks extends CustomPainter {
  _WorldMarks(this.game) : super(repaint: game.frames);

  final VoxelGame game;

  /// A critical blow's number: yellow, and a quarter bigger.
  static const _critColor = Color(0xFFFFE633);

  /// Whether [mob] shows its bar: alive, in [DefaultHud.barRange], and hurt
  /// in the last [DefaultHud.barSeconds] or under the crosshair.
  static bool barred(VoxelGame game, Mob mob) =>
      !mob.isDead &&
      (mob.sinceHurt < DefaultHud.barSeconds || identical(game.player.aimedMob, mob)) &&
      mob.position.distanceTo(game.player.position) < DefaultHud.barRange;

  /// Whether [player]'s name shows: alive, in the local player's dimension
  /// and within [DefaultHud.nameRange].
  static bool named(VoxelGame game, RemotePlayer player) =>
      !player.isDead &&
      player.dimension == game.world.dimension &&
      player.position.distanceTo(game.player.position) < DefaultHud.nameRange;

  @override
  void paint(Canvas canvas, Size size) {
    final camera = game.camera();
    final eye = camera.position;
    final back = Paint()..color = const Color(0xB3000000);
    for (final m in game.mobs) {
      if (!barred(game, m)) continue;
      final top = m.drawnPosition + Vector3(0, m.height + 0.35, 0);
      final at = camera.worldToScreen(top, size);
      if (at == null) continue;
      final w = (480.0 / math.max(top.distanceTo(eye), 4.0)).clamp(28.0, 90.0);
      final h = math.max(4.0, w * 0.12);
      final left = (m.hp / m.maxHp).clamp(0.0, 1.0);
      canvas
        ..drawRect(Rect.fromCenter(center: at, width: w, height: h), back)
        ..drawRect(
          Rect.fromLTWH(at.dx - w * 0.48, at.dy - h * 0.33, w * 0.96 * left, h * 0.66),
          Paint()..color = Color.lerp(Colors.redAccent, Colors.greenAccent.shade400, left)!,
        );
    }
    for (final n in game.damageNumbers.shown) {
      final from = n.at + Vector3(0, DamageNumbers.risenAt(n.age), 0);
      final at = camera.worldToScreen(from, size);
      if (at == null) continue;
      final fontSize = (156.0 / math.max(from.distanceTo(eye), 3.0)).clamp(12.0, 34.0);
      final a = DamageNumbers.opacityAt(n.age);
      final text = TextPainter(
        text: TextSpan(
          text: DamageNumbers.label(n.amount, crit: n.crit),
          style: TextStyle(
            fontSize: n.crit ? fontSize * 1.25 : fontSize,
            fontWeight: FontWeight.bold,
            color: (n.crit ? _critColor : Colors.white).withValues(alpha: a),
            shadows: [
              Shadow(
                color: Colors.black.withValues(alpha: a),
                offset: const Offset(1, 1),
                blurRadius: 2,
              ),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(canvas, at - Offset(text.width / 2, text.height / 2));
      text.dispose();
    }
    final plate = Paint()..color = const Color(0x66000000);
    for (final r in game.remotePlayers) {
      if (!named(game, r)) continue;
      final top = r.drawnPosition + Vector3(0, r.height + 0.45, 0);
      final at = camera.worldToScreen(top, size);
      if (at == null) continue;
      final text = TextPainter(
        text: TextSpan(
          text: r.name,
          style: TextStyle(
            fontSize: (110.0 / math.max(top.distanceTo(eye), 5.0)).clamp(11.0, 18.0),
            color: Colors.white,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final box = Rect.fromCenter(center: at, width: text.width + 8, height: text.height + 2);
      canvas.drawRect(box, plate);
      text.paint(canvas, box.topLeft + const Offset(4, 1));
      text.dispose();
    }
  }

  @override
  bool shouldRepaint(_WorldMarks old) => !identical(old.game, game);
}
