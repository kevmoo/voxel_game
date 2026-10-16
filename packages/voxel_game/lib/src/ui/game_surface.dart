import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gamepads/gamepads.dart';

import '../core/voxel_game.dart';
import '../input/input_device.dart';
import '../input/voxel_action.dart';
import '../spec/touch_controls_spec.dart';
import 'death_menu.dart';
import 'default_hud.dart';
import 'focus_bridge.dart';
import 'game_screen.dart';
import 'inventory_screen.dart';
import 'pause_menu.dart';
import 'screen_focus.dart';
import 'settings_menu.dart';
import 'touch_controls.dart';

/// Builds an overlay over the running game. It is called when the widget
/// builds (the game starts, a screen opens or closes), not every frame: a
/// piece that shows the game's state watches it through a `HudSelector` (or
/// listens to [VoxelGame.frames]). It sits behind a [RepaintBoundary], and it
/// is hit-tested like any widget: every pointer also reaches the game's own
/// `Listener` around it, so a piece that takes a finger for itself calls
/// `InputMap.claimTouch` as it lands (as [DefaultHud]'s hotbar does), and a
/// piece that only shows something sits in an [IgnorePointer].
typedef HudBuilder = Widget Function(BuildContext context, VoxelGame game);

/// A loaded game on screen: [world] under the touch controls, the HUD and the
/// open screen ([VoxelGame.screen], each [GameScreen] as its widget), all
/// inside the one `Listener` that hands every pointer to [VoxelGame.input],
/// and a `Focus` that hands it the keys — the kit's actions' and the game's
/// own ([VoxelGame.actions] reads the keys and pad buttons it records).
///
/// It is the arbiter of the pointer: the first press while the game does not
/// want the pointer takes it (and is nothing else), a press while a screen is
/// open is the screen's alone, a screen opening frees the pointer and lets go
/// of everything held, and one closing takes the pointer back.
///
/// While a screen is open, the keys and pad presses that work it go to the
/// screen and not to [VoxelGame.input] (a [FocusBridge]): the arrows, the
/// dpad and the left stick move the focus, Enter, Space and A press what it
/// is on, Esc and B back out. Each screen sits in a [ScreenFocus], so it
/// opens with a focus and draws it. Backing out is a press of
/// [VoxelAction.pause], which the step's arbiter reads as it reads the key, so
/// the bag closes, the settings go back to the game menu and the death screen
/// stays; a screen that backs out its own way handles [DismissIntent] itself.
/// Every other key and button still reaches the game, so the inventory key
/// closes the bag and a game's action key its screen.
///
/// `VoxelGameWidget` mounts it with a `SceneView` as [world] once the game has
/// loaded; a test (or a game drawing the world its own way) mounts it over any
/// widget.
class GameSurface extends StatefulWidget {
  /// [game] over [world], with [hud] ([DefaultHud] when null) and, when
  /// [touchControls] is given, the kit's [TouchControls] between the two;
  /// [onQuit] is the game menu's Quit.
  const GameSurface({super.key, required this.game, required this.world, this.hud, this.touchControls, this.onQuit});

  /// The game.
  final VoxelGame game;

  /// What shows the world, under everything else.
  final Widget world;

  /// The overlay; the default HUD when null.
  final HudBuilder? hud;

  /// The controls a finger plays with, or null for none.
  final TouchControlsSpec? touchControls;

  /// The game menu's Quit ([PauseMenu]), or null for a menu with none.
  final VoidCallback? onQuit;

  @override
  State<GameSurface> createState() => _GameSurfaceState();
}

class _GameSurfaceState extends State<GameSurface> {
  final FocusNode _focus = FocusNode(debugLabel: 'GameSurface');
  late final FocusBridge _bridge = FocusBridge(_focus);

  @override
  void initState() {
    super.initState();
    widget.game.screen.addListener(_screenChanged);
    widget.game.input.interceptPad = _padOnScreen;
  }

  @override
  void didUpdateWidget(GameSurface old) {
    super.didUpdateWidget(old);
    if (identical(old.game, widget.game)) return;
    old.game.screen.removeListener(_screenChanged);
    old.game.input.interceptPad = null;
    widget.game.screen.addListener(_screenChanged);
    widget.game.input.interceptPad = _padOnScreen;
    _bridge.reset();
  }

  @override
  void dispose() {
    widget.game.screen.removeListener(_screenChanged);
    widget.game.input.interceptPad = null;
    _bridge.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _screenChanged() {
    final input = widget.game.input;
    _bridge.reset();
    // Opening also lets go of everything held: an on-screen button taken off
    // the screen gets no lift, and a switched-on sneak would still be on when
    // the player came back.
    if (widget.game.screen.value != null) {
      input
        ..release()
        ..releaseKeys();
      widget.game.actions.releaseHeld();
    } else {
      input.capture();
      // The screen's focus goes with it: the keys come back to the game.
      _focus.requestFocus();
    }
    setState(() {});
  }

  bool _padOnScreen(NormalizedGamepadEvent event) => widget.game.screen.value != null && _bridge.onPad(event);

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final input = widget.game.input;
    if (widget.game.screen.value != null && _bridge.onKey(event) == KeyEventResult.handled) {
      input.lastDevice = InputDevice.keyboardMouse;
      return KeyEventResult.handled;
    }
    if (widget.game.screen.value == null &&
        input.wantCapture &&
        !input.isCaptured &&
        event is KeyDownEvent &&
        event.physicalKey != PhysicalKeyboardKey.escape) {
      input.capture();
    }
    return input.onKey(node, event);
  }

  void _onPointerDown(PointerDownEvent e) {
    final game = widget.game;
    // A press on a screen leaves the focus where the screen has it.
    if (game.screen.value != null) return;
    _focus.requestFocus();
    if (!game.input.isCaptured) {
      game.input.capture();
      return;
    }
    game.input.onPointerDown(e);
  }

  @override
  Widget build(BuildContext context) {
    final game = widget.game;
    final screen = game.screen.value;
    return Actions(
      actions: {DismissIntent: CallbackAction<DismissIntent>(onInvoke: (_) => game.input.tap(VoxelAction.pause))},
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Listener(
          onPointerDown: _onPointerDown,
          onPointerUp: game.input.onPointerUp,
          onPointerCancel: game.input.onPointerCancel,
          onPointerMove: game.input.onPointerMove,
          onPointerSignal: game.input.onPointerSignal,
          child: Stack(
            fit: StackFit.expand,
            children: [
              widget.world,
              // Under the HUD, so where the hotbar and the stick's zone overlap
              // on a narrow screen, the slot wins.
              if (widget.touchControls case final touch?) TouchControls(game, touch),
              RepaintBoundary(child: (widget.hud ?? DefaultHud.builder)(context, game)),
              // Keyed by the screen, so one replacing another is built afresh:
              // a stack on the bag's cursor goes back before the next opens.
              if (screen != null)
                KeyedSubtree(
                  key: ValueKey(screen),
                  child: ScreenFocus(child: _screen(context, screen)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _screen(BuildContext context, GameScreen screen) {
    final game = widget.game;
    return switch (screen) {
      BagScreen(:final station) => InventoryScreen(game: game, station: station, onClose: game.closeScreen),
      StorageScreen(:final cell) => InventoryScreen(
        game: game,
        station: game.world.blockNameAt(cell),
        storage: game.openStorage!,
        onClose: game.closeScreen,
      ),
      PauseScreen() => PauseMenu(game, onQuit: widget.onQuit),
      SettingsScreen() => SettingsMenu(game),
      DeathScreen() => DeathMenu(game),
      DeclaredScreen(:final id) => game.spec.screens[id]!.build(context, game),
    };
  }
}
