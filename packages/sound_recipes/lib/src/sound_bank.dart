import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import 'stock_sounds.dart';
import 'wav.dart';

/// Something that plays named sounds. The kit talks to this, so a game can
/// run silent (tests, servers) or swap the engine.
abstract interface class SoundPlayer {
  /// Plays [name] at [volumeDb] (0 full, -6 half), at [pitch] times its speed
  /// (with a little random variation so repeats do not drone).
  void play(String name, {double volumeDb = 0.0, double pitch = 1.0});
}

/// Plays nothing and remembers what it was asked to play: for tests.
class SilentSounds implements SoundPlayer {
  /// Every name asked for, in order.
  final List<String> played = [];

  @override
  void play(String name, {double volumeDb = 0.0, double pitch = 1.0}) => played.add(name);
}

/// Named sounds through SoLoud: each [recipes] entry rendered to WAV bytes at
/// [init] (no files), plus [assets] (a name to one or more takes, a random one
/// played each time).
class SoundBank implements SoundPlayer {
  /// A bank of [recipes] (the stock set when omitted) and [assets].
  SoundBank({Map<String, SoundRecipe>? recipes, this.assets = const {}}) : recipes = recipes ?? StockSounds.all;

  /// Synthesised sounds by name.
  final Map<String, SoundRecipe> recipes;

  /// Recorded sounds by name: asset paths, one take picked per play.
  final Map<String, List<String>> assets;

  final Map<String, List<AudioSource>> _sources = {};
  final math.Random _rng = math.Random();
  bool _ready = false;

  /// Nothing plays while set.
  bool muted = false;

  /// Whether the audio device is open and the sounds loaded.
  bool get ready => _ready;

  /// Opens the audio device and loads every sound; false when the platform
  /// has no audio (the bank then stays silent).
  Future<bool> init() async {
    if (_ready) return true;
    try {
      await SoLoud.instance.init();
      for (final e in recipes.entries) {
        _sources[e.key] = [await SoLoud.instance.loadMem('${e.key}.wav', renderWav(e.value))];
      }
      for (final e in assets.entries) {
        _sources[e.key] = [for (final path in e.value) await SoLoud.instance.loadAsset(path)];
      }
      _ready = true;
    } catch (e) {
      debugPrint('[sound_recipes] audio unavailable: $e');
    }
    return _ready;
  }

  /// Whether [name] is in the bank.
  bool has(String name) => _sources.containsKey(name) || recipes.containsKey(name) || assets.containsKey(name);

  /// The master volume, linear 0..1.
  void setVolume(double volume) {
    if (_ready) SoLoud.instance.setGlobalVolume(volume);
  }

  @override
  void play(String name, {double volumeDb = 0.0, double pitch = 1.0}) {
    if (!_ready || muted) return;
    final takes = _sources[name];
    if (takes == null || takes.isEmpty) return;
    final volume = math.pow(10.0, volumeDb / 20.0).toDouble().clamp(0.0, 1.0);
    try {
      final handle = SoLoud.instance.play(takes[_rng.nextInt(takes.length)], volume: volume, paused: true);
      SoLoud.instance.setRelativePlaySpeed(handle, pitch * (0.92 + _rng.nextDouble() * 0.16));
      SoLoud.instance.setPause(handle, false);
    } catch (e) {
      debugPrint('[sound_recipes] $e');
    }
  }

  /// Closes the audio device.
  void dispose() {
    if (_ready) SoLoud.instance.deinit();
    _ready = false;
  }
}

/// Where the music playing comes from.
enum MusicOrigin {
  /// An audio file the app bundles.
  asset,

  /// A recipe, synthesised because the app bundles no file for the mood.
  recipe,
}

/// Background music chosen by mood: [tracks] maps a mood to an asset path; a
/// change of mood crossfades the two over [crossfade] seconds. A mood whose
/// asset the app does not bundle (or that has none) plays its entry in
/// [recipes] instead, synthesised once off the main isolate, so a game can
/// ship with placeholder music and drop real files in later. Needs an
/// initialised [SoundBank] (the audio device).
class MusicDirector {
  /// A director over [tracks], falling back to [recipes], at [gain].
  MusicDirector(this.tracks, {this.recipes = const {}, this.gain = 0.45, this.crossfade = 3.0});

  /// Mood to asset path.
  final Map<String, String> tracks;

  /// Mood to a synthesised track, played when the mood's asset is not bundled.
  final Map<String, SoundRecipe> recipes;

  /// Seconds a change of track fades over.
  final double crossfade;

  final Map<String, AudioSource> _loaded = {};
  Set<String>? _bundled;
  SoundHandle? _active;
  String? _mood;
  MusicOrigin? _origin;
  int _generation = 0;

  /// The mood playing, or null.
  String? get mood => _mood;

  /// Where the track playing comes from; null in silence or before it starts.
  MusicOrigin? get origin => _origin;

  /// The music's loudness, linear; [setGain] also applies it to the track
  /// playing.
  double gain;

  /// Sets [gain] and applies it to the track playing now.
  void setGain(double value) {
    gain = value;
    final h = _active;
    if (h == null) return;
    try {
      if (SoLoud.instance.isInitialized && SoLoud.instance.getIsValidVoiceHandle(h)) {
        SoLoud.instance.setVolume(h, value);
      }
    } catch (_) {}
  }

  /// Whether a track is a live voice on the audio device.
  bool get isPlaying {
    final h = _active;
    if (h == null) return false;
    try {
      return SoLoud.instance.isInitialized && SoLoud.instance.getIsValidVoiceHandle(h);
    } catch (_) {
      return false;
    }
  }

  /// Plays the track of [mood] (null: silence), fading the old one out.
  Future<void> setMood(String? mood) async {
    if (mood == _mood) return;
    _mood = mood;
    final gen = ++_generation;
    final SoLoud soloud;
    try {
      soloud = SoLoud.instance;
      if (!soloud.isInitialized) return;
    } catch (_) {
      return;
    }
    final fade = Duration(milliseconds: (crossfade * 1000).toInt());
    final old = _active;
    if (old != null && soloud.getIsValidVoiceHandle(old)) {
      soloud.fadeVolume(old, 0.0, fade);
      soloud.scheduleStop(old, fade + const Duration(milliseconds: 50));
    }
    _active = null;
    _origin = null;
    if (mood == null) return;
    final bundled = _bundled ??= (await AssetManifest.loadFromAssetBundle(rootBundle)).listAssets().toSet();
    final path = tracks[mood];
    final recipe = recipes[mood];
    final MusicOrigin origin;
    if (path != null && bundled.contains(path)) {
      origin = MusicOrigin.asset;
    } else if (recipe != null) {
      origin = MusicOrigin.recipe;
    } else if (path == null) {
      return; // a mood with no music
    } else {
      throw StateError('music for $mood: $path is not bundled and there is no recipe for it');
    }
    try {
      final key = origin == MusicOrigin.asset ? path! : 'recipe:$mood';
      var source = _loaded[key];
      if (source == null) {
        source = origin == MusicOrigin.asset
            ? await soloud.loadAsset(key, mode: LoadMode.disk)
            : await soloud.loadMem('$mood.wav', await compute(renderWav, recipe!));
        _loaded[key] = source;
      }
      if (gen != _generation) return; // a newer mood won while this one loaded
      final h = soloud.play(source, volume: 0.0, looping: true);
      soloud.fadeVolume(h, gain, fade);
      _active = h;
      _origin = origin;
    } catch (e) {
      debugPrint('[sound_recipes] music: $e');
    }
  }
}
