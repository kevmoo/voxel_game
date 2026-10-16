import 'dart:convert';

import '../io/platform_io.dart';
import 'game_settings.dart';

/// The player's [GameSettings] in one JSON [file], kept between runs:
/// `VoxelGameWidget` keeps it as `settings.json` beside the `worlds` folder.
class SettingsStore {
  /// Settings kept in [file].
  SettingsStore(this.file);

  /// Where they are kept.
  final File file;

  /// The settings kept, or [defaults] before any were (no file yet). Throws
  /// for a file that is unreadable, of another version, or out of range.
  GameSettings read(GameSettings defaults) {
    if (!file.existsSync()) return defaults;
    return GameSettings.fromJson(jsonDecode(file.readAsStringSync()) as Map<String, Object?>);
  }

  /// Keeps [settings], written beside and renamed over, so a crash mid-write
  /// keeps the last ones.
  void write(GameSettings settings) {
    file.parent.createSync(recursive: true);
    final tmp = File('${file.path}.tmp')..writeAsStringSync(jsonEncode(settings.toJson()));
    tmp.renameSync(file.path);
  }
}
