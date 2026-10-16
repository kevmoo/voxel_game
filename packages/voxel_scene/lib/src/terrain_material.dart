import 'dart:typed_data';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_scene/scene.dart';
// The engine's own gpu shim: Material.bind is typed against it, and only it
// resolves to the same RenderPass / Shader types for both the analyzer and the build
// (package:flutter_gpu directly analyzes as a different type; the public
// flutter_scene/gpu.dart has no RenderPass).
// ignore: implementation_imports
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;

/// The lit voxel terrain surfaces. A [PhysicallyBasedMaterial] whose fragment
/// shader is `shaders/terrain.frag`: the standard lit shader with the voxel light
/// term folded into the albedo, so the engine keeps binding and evaluating the
/// sun, its cascaded shadows, the ambient and the sky-coloured fog exactly as the
/// stock material does (a raw `ShaderMaterial` gets none of them). The only extra
/// input is the `TerrainInfo` block: [skyIntensity] and [emissionMix].
///
/// The shader bundle is an asset of this package compiled by
/// `tool/build_shaders.dart`; [loadLibrary] must finish before a material that
/// draws is constructed, and before a `VoxelChunkView` meshes a lit surface (its
/// geometry runs the bundle's vertex shaders). A material built without it (unit
/// tests, which never draw) stays a stock PBR material.
class TerrainMaterial extends PhysicallyBasedMaterial {
  /// A terrain material; without [loadLibrary] it draws as stock PBR.
  TerrainMaterial({this.emissionMix = 0.5}) {
    final lib = _library;
    if (lib == null) return;
    _full = _TerrainTier(lib, 'Terrain');
    _lean = _TerrainTier(lib, 'TerrainLean');
    setFragmentShader(_full!.base);
    setRadianceCubeFragmentShader(_full!.cube);
  }

  /// A package asset, so its key carries the package name.
  static const String asset = 'packages/voxel_scene/assets/shaders/terrain.shaderbundle';
  static gpu.ShaderLibrary? _library;

  /// The bundle entries a terrain material draws with: the lit fragment shader
  /// in two lighting tiers (full, lean) by two radiance layouts (2D, cube) by
  /// shadows (bound, none), and the packed vertex's colour and depth shaders.
  static const List<String> entries = [
    'TerrainFragment',
    'TerrainCubeFragment',
    'TerrainNoShadowFragment',
    'TerrainNoShadowCubeFragment',
    'TerrainLeanFragment',
    'TerrainLeanCubeFragment',
    'TerrainLeanNoShadowFragment',
    'TerrainLeanNoShadowCubeFragment',
    'TerrainVertex',
    'TerrainDepthVertex',
  ];

  /// [loadLibrary] has finished.
  static bool get loaded => _library != null;

  /// The bundle's shader [name]; [loadLibrary] must have finished.
  static gpu.Shader shader(String name) {
    final lib = _library;
    if (lib == null) throw StateError('TerrainMaterial.loadLibrary has not finished; $name is in its bundle');
    return lib[name]!;
  }

  /// Loads the terrain shader bundle once. Throws when the bundle holds no
  /// shader this Flutter engine can read: a bundle is tied to the engine that
  /// compiled it.
  static Future<void> loadLibrary() async {
    if (_library != null) return;
    if (kIsWeb || defaultTargetPlatform == TargetPlatform.linux) return;
    final lib = await gpu.loadShaderLibraryAsync(asset);
    for (final name in entries) {
      if (lib == null || lib[name] == null) {
        throw Exception(
          '$asset holds no $name this engine can read; recompile it with '
          '`dart tool/build_shaders.dart` from packages/voxel_scene (a bundle is tied to the Flutter engine that built it)',
        );
      }
    }
    _library = lib;
  }

  /// How much of the baked skylight shows: 1.0 noon, 0.35 night, 0.0 none.
  double skyIntensity = 1.0;

  /// The share of the lit albedo added back as emission, so a torch-lit wall
  /// reads at night when the sun and the ambient are almost off.
  double emissionMix;

  // The full lighting tier and its lean twin, each in four entries: the
  // radiance layouts (2D, cube) by shadows (bound, none). Null without the bundle.
  _TerrainTier? _full;
  _TerrainTier? _lean;
  final Float32List _info = Float32List(4);

  // The engine resolves its own materials' no-shadow and lean twins by name from
  // its bundle only, so the terrain hands its own in through the members the
  // encoder asks: the no-shadow twins here, which also decide whether the
  // shadow_map sampler is bound, and the lean ones in fragmentShaderForLighting.
  @override
  gpu.Shader? get noShadowFragmentShader => _full?.noShadow;

  @override
  gpu.Shader? get noShadowRadianceCubeFragmentShader => _full?.noShadowCube;

  /// The lean twin is picked as `Material.usesLeanVariant` picks the engine's:
  /// every lighting feature it compiles out is off for the frame (a warm-up's
  /// forced tier included), and the environment has no parallax box. The lean
  /// entries keep the full ones' binding interface, so nothing else changes.
  @override
  gpu.Shader fragmentShaderForLighting(Lighting lighting) {
    final lean = _lean;
    // ignore: invalid_use_of_internal_member
    if (lean == null || !lighting.allowsLeanShading) return super.fragmentShaderForLighting(lighting);
    final env = drawEnvironment(lighting);
    if (env.parallaxBoxCenter != null && env.parallaxBoxHalfExtents != null) {
      return super.fragmentShaderForLighting(lighting);
    }
    // ignore: invalid_use_of_internal_member
    final cube = usesRadianceCubeVariant(lighting);
    // ignore: invalid_use_of_internal_member
    final noShadow = usesNoShadowVariant(lighting);
    return cube ? (noShadow ? lean.noShadowCube : lean.cube) : (noShadow ? lean.noShadow : lean.base);
  }

  @override
  void bind(gpu.RenderPass pass, TransientWriter transientsBuffer, Lighting lighting) {
    super.bind(pass, transientsBuffer, lighting);
    if (_full == null) return;
    _info[0] = skyIntensity;
    _info[1] = emissionMix;
    // The block on the shader the pipeline was built with: every twin declares it.
    final drawn = fragmentShaderForLighting(lighting);
    pass.bindUniform(drawn.getUniformSlot('TerrainInfo'), transientsBuffer.emplace(ByteData.sublistView(_info)));
  }
}

/// One lighting tier of the terrain's fragment shader, as four bundle entries:
/// `<prefix>Fragment`, `<prefix>CubeFragment`, `<prefix>NoShadowFragment` and
/// `<prefix>NoShadowCubeFragment`.
class _TerrainTier {
  _TerrainTier(gpu.ShaderLibrary lib, String prefix)
    : base = lib['${prefix}Fragment']!,
      cube = lib['${prefix}CubeFragment']!,
      noShadow = lib['${prefix}NoShadowFragment']!,
      noShadowCube = lib['${prefix}NoShadowCubeFragment']!;

  final gpu.Shader base;
  final gpu.Shader cube;
  final gpu.Shader noShadow;
  final gpu.Shader noShadowCube;
}
