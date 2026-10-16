import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import 'audio_device.dart';
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
  AudioDevice? _device;
  bool _ready = false;

  /// Nothing plays while set.
  bool muted = false;

  /// Whether the audio device is open and the sounds loaded.
  bool get ready => _ready;

  /// Takes a hold of [AudioDevice.instance] and loads every sound; false
  /// when the platform has no audio (the bank then stays silent).
  Future<bool> init() async {
    if (_ready) return true;
    final device = AudioDevice.instance;
    if (!await device.acquire()) return false;
    _device = device;
    for (final e in recipes.entries) {
      _sources[e.key] = [await SoLoud.instance.loadMem('${e.key}.wav', renderWav(e.value))];
    }
    for (final e in assets.entries) {
      _sources[e.key] = [for (final path in e.value) await SoLoud.instance.loadAsset(path)];
    }
    _ready = true;
    return true;
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
    final handle = SoLoud.instance.play(takes[_rng.nextInt(takes.length)], volume: volume, paused: true);
    if (handle.id == 0) return; // every voice is busy: SoLoud drops the sound
    SoLoud.instance.setRelativePlaySpeed(handle, pitch * (0.92 + _rng.nextDouble() * 0.16));
    SoLoud.instance.setPause(handle, false);
  }

  /// Frees the bank's sounds and lets go of the audio device, which closes
  /// once no one else holds it.
  void dispose() {
    final device = _device;
    _device = null;
    _ready = false;
    if (device == null) return;
    // Freed on the device before the release is queued: disposeSource drops
    // the native sound before its first await.
    for (final takes in _sources.values) {
      for (final source in takes) {
        unawaited(SoLoud.instance.disposeSource(source));
      }
    }
    _sources.clear();
    unawaited(device.release());
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
/// initialised [SoundBank] (a hold of the [AudioDevice]).
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
    if (h != null && SoLoud.instance.isInitialized && SoLoud.instance.getIsValidVoiceHandle(h)) {
      SoLoud.instance.setVolume(h, value);
    }
  }

  /// Whether a track is a live voice on the audio device.
  bool get isPlaying {
    final h = _active;
    return h != null && SoLoud.instance.isInitialized && SoLoud.instance.getIsValidVoiceHandle(h);
  }

  /// Plays the track of [mood] (null: silence), fading the old one out.
  Future<void> setMood(String? mood) async {
    if (mood == _mood) return;
    _mood = mood;
    final gen = ++_generation;
    // The device first: SoLoud.instance loads the native library, which a
    // platform without one (a test on Linux) cannot.
    if (!AudioDevice.instance.isOpen) return;
    final soloud = SoLoud.instance;
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
    final key = origin == MusicOrigin.asset ? path! : 'recipe:$mood';
    var source = _loaded[key];
    if (source == null) {
      try {
        source = origin == MusicOrigin.asset
            ? await soloud.loadAsset(key, mode: LoadMode.disk)
            : await soloud.loadMem('$mood.wav', await compute(renderWav, recipe!));
      } on SoLoudNotInitializedException {
        // The device closed under the load, which its owner does only after
        // silencing the music: a newer mood has won.
        if (gen == _generation) rethrow;
        return;
      }
      _loaded[key] = source;
    }
    if (gen != _generation) return; // a newer mood won while this one loaded
    final h = soloud.play(source, volume: 0.0, looping: true);
    if (h.id == 0) return; // every voice is busy: SoLoud drops the track
    soloud.fadeVolume(h, gain, fade);
    _active = h;
    _origin = origin;
  }
}
