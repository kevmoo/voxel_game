import 'dart:ui';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:voxel_game/voxel_game.dart';
import 'package:web_crashlytics/web_crashlytics.dart';

import 'src/spec/game_spec.dart';
import 'src/spec/game_title.dart';
import 'src/ui/game_hud.dart';
import 'src/ui/title_vista.dart';

const _appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '0.1.0+1');
const _firebaseApiKey = String.fromEnvironment('FIREBASE_API_KEY');
const _compiler = identical(0, 0.0) ? 'dart2js' : 'dart2wasm';

/// The game on the kit: its title (the credits read off the bundled roadmap)
/// over a world of its own, orbited to the meadow's music; the worlds made
/// there in the app's support folder (`worlds/`, with `settings.json` beside
/// it); and the kit's HUD with the game's own pieces on it.
Future<void> main() async {
  if (_firebaseApiKey.isEmpty) {
    await _startGame();
    return;
  }

  final crashlytics = Crashlytics(
    app: const FirebaseAppConfig(
      appId: '1:915141274861:web:dc3515c255ed6f573930e4',
      projectId: 'j832-com',
      apiKey: _firebaseApiKey,
    ),
    options: const CrashlyticsOptions(appVersion: _appVersion),
  );

  crashlytics
    ..installGlobalErrorCapture()
    ..setCustomKey('compiler', _compiler)
    ..log('voxel_game_minecraft starting', attributes: {'compiler': _compiler, 'version': _appVersion})
    ..runGuarded(() async {
      WidgetsFlutterBinding.ensureInitialized();

      FlutterError.onError = (FlutterErrorDetails details) {
        FlutterError.presentError(details);
        crashlytics.recordError(
          details.exception,
          details.stack ?? StackTrace.current,
          attributes: {
            'mechanism': 'FlutterError.onError',
            if (details.context != null) 'flutter.context': details.context.toString(),
          },
        );
      };

      PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
        crashlytics.recordError(error, stack, attributes: {'mechanism': 'PlatformDispatcher.onError'});
        return true;
      };

      await _startGame();
    });
}

Future<void> _startGame() async {
  WidgetsFlutterBinding.ensureInitialized();
  final credits = creditsOf(await rootBundle.loadString(roadmapAsset));
  await runVoxelGame(
    gameSpec,
    title: 'Voxel Minecraft',
    menu: gameTitle(credits: credits, background: TitleVista.builder),
    hud: GameHud.builder,
  );
}
