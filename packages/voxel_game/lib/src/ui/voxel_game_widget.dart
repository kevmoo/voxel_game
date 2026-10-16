import 'dart:async';
import 'dart:ui' show AppExitType;

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding, Ticker;
import 'package:flutter/services.dart' show DeviceOrientation, ServicesBinding, SystemChrome, SystemUiMode;
import 'package:flutter_scene/scene.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sound_recipes/sound_recipes.dart';
import 'package:voxel_scene/voxel_scene.dart';

import '../audio/game_music.dart';
import '../core/voxel_game.dart';
import '../io/platform_io.dart';
import '../loop/frame_driver.dart';
import '../settings/game_settings.dart';
import '../settings/settings_store.dart';
import '../spec/title_spec.dart';
import '../spec/voxel_game_spec.dart';
import 'default_hud.dart';
import 'game_screen.dart';
import 'game_surface.dart';
import 'loading_screen.dart';
import 'loading_stage.dart';
import 'voxel_game_home.dart';
import '../world/world_info.dart';
import '../world/world_save.dart';

/// Loads the renderer and runs [spec] full screen: the one call a game's
/// `main` needs.
///
/// ```dart
/// void main() => runVoxelGame(myGame);
/// ```
///
/// A [loading] screen ([LoadingScreen] when null) shows until the window
/// around the player has filled and the renderer has compiled what it draws.
///
/// A phone or tablet plays it in landscape, either way round, and never
/// upright: the HUD, the touch controls and the 3D view are laid out for a
/// wide viewport. The status and navigation bars hide and come back on a
/// swipe. A game's runners should say the same, so the launch screen does
/// not show upright before `main` runs (the example's `AndroidManifest.xml`
/// and `Info.plist`). A desktop window is sized by its window manager and
/// ignores both.
///
/// With [saveSlot] the world is kept in that slot of the app's support
/// folder (`worlds/<slot>`): loaded when it exists, saved every minute and
/// when the widget goes away. With [hostPort] others can join the game on
/// that port; with [join] (`'192.168.0.10'`, or `'host:port'`) this game
/// joins one instead.
///
/// The player's settings (`GameSettings`) are kept in the same folder,
/// `settings.json` beside `worlds`, whether or not the world is.
///
/// On a desktop the game menu's Quit saves the world and closes the app; a
/// phone or tablet has no Quit, as its apps are left from the system.
///
/// With [menu] the game opens on its title instead (`VoxelGameHome`), and the
/// player picks, makes, hosts or joins the world there: [saveSlot],
/// [hostPort] and [join] are then the title's to choose, and passing one
/// throws. The game menu's Quit saves the world and goes back to the title;
/// the title's Quit, on a desktop, closes the app.
Future<void> runVoxelGame(
  VoxelGameSpec spec, {
  String title = 'Voxel game',
  TitleSpec? menu,
  HudBuilder? hud,
  LoadingBuilder? loading,
  String? saveSlot,
  int? hostPort,
  String? join,
}) async {
  if (menu != null && (saveSlot != null || hostPort != null || join != null)) {
    throw ArgumentError('with a menu the title picks the world: no saveSlot, hostPort or join');
  }
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  await VoxelGameWidget.loadResources();
  final VoidCallback? closeApp = kIsWeb
      ? null
      : switch (defaultTargetPlatform) {
          TargetPlatform.macOS ||
          TargetPlatform.windows ||
          TargetPlatform.linux => () => ServicesBinding.instance.exitApplication(AppExitType.required),
          TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.fuchsia => null,
        };
  runApp(
    MaterialApp(
      title: title,
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: Scaffold(
        body: menu == null
            ? VoxelGameWidget(
                spec: spec,
                hud: hud,
                loading: loading,
                saveSlot: saveSlot,
                hostPort: hostPort,
                join: join,
                onQuit: closeApp,
              )
            : VoxelGameHome(
                spec: spec,
                menu: menu,
                saves: await VoxelGameWidget.defaultSaves(),
                settings: await VoxelGameWidget.defaultSettings(),
                hud: hud,
                loading: loading,
                onQuit: closeApp,
              ),
      ),
    ),
  );
}

/// A running [VoxelGameSpec]: the 3D view, the controls (keyboard, mouse with
/// pointer lock, gamepad) and a HUD. Click to play, Escape to free the mouse.
///
/// A loading screen covers the game until it can be shown without a stall
/// ([LoadingStage]): the game runs undrawn until the window around the player
/// has filled ([VoxelGame.filled]), then the renderer encodes every chunk and
/// body once, offscreen (`Scene.warmUp`), so the pipelines Impeller compiles on
/// first use are compiled behind it. A first run after an install or a build
/// otherwise stopped its first frames for ~0.6 s (phone) to ~0.8 s (Mac).
///
/// Call [loadResources] once before the first one is built (`runVoxelGame`
/// does).
class VoxelGameWidget extends StatefulWidget {
  /// A game of [spec] with [hud] over it ([DefaultHud] when null) and
  /// [loading] before it ([LoadingScreen] when null); [onReady] receives the
  /// game once it runs.
  const VoxelGameWidget({
    super.key,
    required this.spec,
    this.hud,
    this.loading,
    this.onReady,
    this.saveSlot,
    this.saves,
    this.settings,
    this.autosave = const Duration(minutes: 1),
    this.hostPort,
    this.join,
    this.joinOptions = const {},
    this.onQuit,
    this.onNetError,
  });

  /// Called, in place of a crash, when the network says no: a [join] that
  /// reaches no host or hears no hello in 15 s, a [hostPort] already taken.
  /// The game is gone by then: whoever built this widget takes it down.
  final ValueChanged<Object>? onNetError;

  /// The game menu's Quit, called once the world is saved (when it is kept
  /// in a [saveSlot]); null for a menu with no Quit.
  final VoidCallback? onQuit;

  /// Host the game on this port, or null for a game nobody joins.
  final int? hostPort;

  /// Join the game at this address (`host` or `host:port`, port 7777 by
  /// default) instead of starting one; its world is the host's and is never
  /// saved here.
  final String? join;

  /// The game's own choices a [join] plays with (`VoxelGame.options`).
  final Map<String, String> joinOptions;

  /// The game.
  final VoxelGameSpec spec;

  /// The overlay; the default HUD when null.
  final HudBuilder? hud;

  /// What shows until the game is; the default loading screen when null.
  final LoadingBuilder? loading;

  /// Called once the game has started: it runs from then on, behind the
  /// loading screen until its window has filled.
  final void Function(VoxelGame game)? onReady;

  /// The save slot the world lives in, or null for a world never saved. A
  /// slot that is a world (`WorldSaves.contains`) is played with its seed and
  /// mode (`WorldInfo.applyTo`), saved or not yet, and is the game's
  /// `VoxelGame.worldInfo`.
  final String? saveSlot;

  /// Where the slots are; the app support folder's `worlds` when null.
  final WorldSaves? saves;

  /// Where the player's settings are kept, read before the game starts and
  /// written as they change; [defaultSettings] when null.
  final SettingsStore? settings;

  /// How often the world is saved while it runs.
  final Duration autosave;

  /// The app's default saves: `<application support>/worlds`.
  static Future<WorldSaves> defaultSaves() async =>
      WorldSaves(Directory(kIsWeb ? '/web/worlds' : '${(await getApplicationSupportDirectory()).path}/worlds'));

  /// The app's default settings: `<application support>/settings.json`,
  /// beside [defaultSaves]' folder.
  static Future<SettingsStore> defaultSettings() async => SettingsStore(
    File(kIsWeb ? '/web/settings.json' : '${(await getApplicationSupportDirectory()).path}/settings.json'),
  );

  /// Loads flutter_scene's static resources and the terrain shader.
  static Future<void> loadResources() async {
    await Scene.initializeStaticResources();
    await TerrainMaterial.loadLibrary();
  }

  @override
  State<VoxelGameWidget> createState() => _VoxelGameWidgetState();
}

class _VoxelGameWidgetState extends State<VoxelGameWidget> with SingleTickerProviderStateMixin {
  VoxelGame? _game;
  LoadingStage _stage = LoadingStage.starting;

  // Drives the game in the SceneView's place while the loading screen is up.
  late final Ticker _loadingTicker;
  Duration _lastLoadingTick = Duration.zero;
  bool _disposed = false;

  // The game's frames, from the tickers while the window shows and from a
  // timer while it is hidden, so a covered window keeps its world stepping.
  FrameDriver? _driver;

  WorldSaves? _saves;
  Timer? _autosave;
  SoundBank? _bank;
  GameMusic? _music;
  void Function()? _playTrack;
  SettingsStore? _settingsStore;
  Timer? _settingsWrite;

  @override
  void initState() {
    super.initState();
    _loadingTicker = createTicker(_loadingTick);
    _start();
  }

  Future<void> _start() async {
    final store = _settingsStore = widget.settings ?? await VoxelGameWidget.defaultSettings();
    final defaults = GameSettings.of(widget.spec);
    final settings = store.read(
      kIsWeb && defaults.renderDistance > 3 ? defaults.copyWith(renderDistance: 3) : defaults,
    );
    final VoxelGame game;
    try {
      game = await _open(settings);
    } on SocketException catch (e) {
      if (widget.onNetError == null) rethrow;
      return _netFailed(e);
    } on TimeoutException catch (e) {
      if (widget.onNetError == null) rethrow;
      return _netFailed(e);
    }
    if (_disposed) {
      game.dispose();
      return;
    }
    SchedulerBinding.instance.addTimingsCallback(game.stats.addTimings);
    game.settings.addListener(_settingsChanged);
    game.input.attachDevices();
    setState(() {
      _game = game;
      _stage = LoadingStage.filling;
    });
    _driver = FrameDriver((dt) => _tick(game, dt));
    _loadingTicker.start();
    unawaited(_startAudio(game));
    if (widget.saveSlot != null && widget.join == null) _autosave = Timer.periodic(widget.autosave, (_) => _save());
    widget.onReady?.call(game);
  }

  // The game this widget runs: joined, or started from its slot (with the
  // slot's seed and mode, when it is a world) and hosted when asked.
  Future<VoxelGame> _open(GameSettings settings) async {
    final join = widget.join;
    if (join != null) {
      final parts = join.split(':');
      return VoxelGame.joinGame(
        widget.spec,
        parts[0],
        port: parts.length > 1 ? int.parse(parts[1]) : 7777,
        settings: settings,
        options: widget.joinOptions,
      );
    }
    var spec = widget.spec;
    SavedWorld? saved;
    WorldInfo? info;
    if (widget.saveSlot case final slot?) {
      final saves = _saves = widget.saves ?? await VoxelGameWidget.defaultSaves();
      if (saves.contains(slot)) spec = (info = saves.info(slot)).applyTo(spec);
      if (saves.exists(slot)) saved = saves.read(slot);
    }
    final game = await VoxelGame.start(spec, save: saved, settings: settings, info: info);
    if (widget.hostPort case final port?) {
      try {
        await game.host(port: port);
      } catch (_) {
        game.dispose();
        rethrow;
      }
    }
    return game;
  }

  void _netFailed(Object error) {
    if (!_disposed) widget.onNetError!(error);
  }

  // Silent where the platform has no audio device: the bank plays nothing
  // and the music asks for its tracks unheard.
  Future<void> _startAudio(VoxelGame game) async {
    final sound = widget.spec.sounds;
    if (!sound.enabled) return;
    final bank = SoundBank(recipes: {...StockSounds.all, ...sound.recipes}, assets: sound.assets);
    await bank.init();
    if (_disposed) return bank.dispose();
    _bank = bank;
    game.sounds = bank;
    final spec = sound.music;
    if (spec == null) return;
    final music = _music = GameMusic(spec, game.settings.value);
    _playTrack = () => music.play(game.musicTrack.value);
    game.musicTrack.addListener(_playTrack!);
    _playTrack!();
  }

  // The music takes a change at once; the file, once a slider has come to
  // rest, so a drag writes it once and not on every step it passes.
  void _settingsChanged() {
    final settings = _game!.settings.value;
    _music?.follow(settings);
    _settingsWrite?.cancel();
    _settingsWrite = Timer(const Duration(milliseconds: 500), () => _settingsStore!.write(settings));
  }

  void _quit() {
    _save();
    widget.onQuit!();
  }

  void _save() {
    final game = _game, saves = _saves, slot = widget.saveSlot;
    if (game == null || saves == null || slot == null || !game.ready || !game.authority) return;
    saves.save(game, slot);
  }

  // The game runs while it loads, undrawn: the world streams around the
  // player, and the steps run, so a client keeps up with its host.
  void _loadingTick(Duration elapsed) {
    final game = _game!;
    final dt = (elapsed - _lastLoadingTick).inMicroseconds / 1e6;
    _lastLoadingTick = elapsed;
    _driver!.tickerFrame(dt);
    if (_stage == LoadingStage.filling && game.filled) unawaited(_warmUp(game));
  }

  // Encodes one offscreen frame of every render item, the ones behind the
  // camera too, so each pipeline the window draws with is compiled here and
  // not in a frame shown. The loading ticker keeps the game running until the
  // SceneView takes it over.
  Future<void> _warmUp(VoxelGame game) async {
    setState(() => _stage = LoadingStage.warming);
    // Draw the stage before the compile holds the UI thread.
    await SchedulerBinding.instance.endOfFrame;
    if (_disposed) return;
    await game.scene!.warmUp([RenderView(camera: game.camera())], includeOffscreen: true);
    if (_disposed) return;
    game.warmedUp = true;
    _loadingTicker.stop();
    setState(() => _stage = LoadingStage.playing);
  }

  @override
  void dispose() {
    _loadingTicker.dispose();
    _driver?.dispose();
    _autosave?.cancel();
    final unwritten = _settingsWrite?.isActive ?? false;
    _settingsWrite?.cancel();
    if (unwritten) _settingsStore!.write(_game!.settings.value);
    final playTrack = _playTrack;
    if (playTrack != null) _game!.musicTrack.removeListener(playTrack);
    _music?.close();
    _bank?.dispose();
    _save();
    _disposed = true;
    final game = _game;
    if (game != null) SchedulerBinding.instance.removeTimingsCallback(game.stats.addTimings);
    _game?.dispose();
    super.dispose();
  }

  void _tick(VoxelGame game, double dt) {
    final input = game.input;
    game.gameplay =
        _stage == LoadingStage.playing && (input.wantCapture || game.playWithoutCapture) && game.screen.value == null;
    game.frame(dt);
    // After the frame, whose steps are out of gameplay once the pointer is
    // lost: a pause pressed as it went cannot close the menu it opens here.
    if (input.captureLost) {
      input.captureLost = false;
      input.releaseKeys();
      game.actions.releaseHeld();
      // Focus left the window mid-play: the game menu is up when it comes back.
      if (_stage == LoadingStage.playing && game.screen.value == null) game.openScreen(const PauseScreen());
    }
  }

  @override
  Widget build(BuildContext context) {
    _game?.fitPixelRatio(MediaQuery.devicePixelRatioOf(context));
    if (_stage != LoadingStage.playing) return (widget.loading ?? LoadingScreen.builder)(context, _stage, _game);
    final game = _game!;
    return GameSurface(
      game: game,
      world: SceneView(
        game.scene!,
        cameraBuilder: (elapsed) => game.camera(),
        onTick: (elapsed, dt) => _driver!.tickerFrame(dt),
      ),
      hud: widget.hud,
      touchControls: game.spec.touchControls,
      onQuit: widget.onQuit == null ? null : _quit,
    );
  }
}
