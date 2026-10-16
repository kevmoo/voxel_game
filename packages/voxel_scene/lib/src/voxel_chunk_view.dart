import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart';
import 'package:voxel_engine/core.dart';

import 'merged_surface.dart';
import 'packed_surface.dart';
import 'terrain_geometry.dart';
import 'terrain_material.dart';

/// voxel_core's chunks drawn with flutter_scene: the [ChunkMeshSink] a
/// [ChunkStreamer] hands finished meshes to. Chunks are drawn in regions of
/// [regionChunks] × [regionChunks]: one [Node] per region under [root], one
/// child per non-empty surface on its material. The three lit surfaces draw in
/// [TerrainGeometry]'s 16-byte packed vertex; the glow in the engine's own, its
/// light in the second UV set.
///
/// A region is one draw per surface where a chunk was one each, because
/// flutter_scene batches only draws of the identical geometry. The price is
/// that a chunk's mesh or removal rebuilds its region's geometry from the
/// surfaces of its chunks, which the view keeps: the lit ones packed the first
/// time a rebuild reads them, so a later rebuild moves words and never packs
/// again.
///
/// [apply] and [remove] only mark a region to rebuild; [rebuild], once a frame,
/// builds them within a time budget, so the chunks a streamer hands over
/// together are drawn over a few frames instead of in one long one, and a
/// region is built once however many of its chunks changed. Nothing is drawn
/// before [rebuild] runs.
class VoxelChunkView implements ChunkMeshSink {
  /// A view with an empty [root] named [rootName]. Add [root] to a scene.
  VoxelChunkView({String rootName = 'World', this.regionChunks = 2})
    : assert(regionChunks >= 1, 'a region holds at least one chunk'),
      assert(
        regionChunks * ChunkSize.sizeX <= 255 && regionChunks * ChunkSize.sizeZ <= 255,
        'a packed terrain vertex spans 256 m',
      ),
      root = Node(name: rootName) {
    // The three lit surfaces share the terrain shader's light term fed by
    // [setSkyIntensity]; specular 0 turns off sky reflections (the dielectric F0
    // would add ~0.04 of the sky to every face).
    matSolid = TerrainMaterial()
      ..roughnessFactor = 1.0
      ..metallicFactor = 0.0
      ..specular = 0.0
      ..vertexColorWeight = 1.0;
    matCutout = TerrainMaterial()
      ..roughnessFactor = 1.0
      ..metallicFactor = 0.0
      ..specular = 0.0
      ..doubleSided = true
      ..vertexColorWeight = 1.0;
    matLiquid = TerrainMaterial()
      ..roughnessFactor = 0.15
      ..metallicFactor = 0.1
      ..alphaMode = AlphaMode.blend
      ..doubleSided = true
      ..vertexColorWeight = 1.0;
    // Unlit, so a lamp's faces keep their colour at night.
    matGlow = UnlitMaterial()..vertexColorWeight = 1.0;
  }

  /// The parent of every chunk node.
  final Node root;

  /// Draws [ChunkMeshResult.solid]: rough, no specular.
  late final TerrainMaterial matSolid;

  /// Draws [ChunkMeshResult.cutout]: as [matSolid], double-sided.
  late final TerrainMaterial matCutout;

  /// Draws [ChunkMeshResult.liquid]: blended, double-sided, a little glossy.
  late final TerrainMaterial matLiquid;

  /// Draws [ChunkMeshResult.glow]: unlit vertex colour.
  late final UnlitMaterial matGlow;

  /// Chunks along each side of a region.
  final int regionChunks;

  /// Microseconds [rebuild] spends a frame by default: a quarter of a 120 Hz
  /// frame.
  static const int rebuildBudgetUsec = 2000;

  /// WebGL2 and Linux OpenGLES reject `VertexFormat.uint32x2` vertex streams,
  /// so those targets build regions with standard float32 `MeshGeometry`.
  static bool get _useFloatGeometry => kIsWeb || defaultTargetPlatform == TargetPlatform.linux;

  /// Each meshed chunk's surfaces.
  final Map<ChunkPos, _ViewChunk> _chunks = {};

  /// Each region's node under [root], keyed by the region's position.
  final Map<ChunkPos, Node> _regions = {};

  /// Regions whose chunks changed since they were last built.
  final Set<ChunkPos> _dirty = {};

  /// What packing and building cost, in microseconds a vertex, as measured on
  /// the rebuilds so far; null before the first.
  double? _packUsPerVertex, _buildUsPerVertex;

  /// Chunks with a mesh in the view, drawn or waiting for [rebuild].
  int get chunkCount => _chunks.length;

  /// Regions with a node under [root].
  int get regionCount => _regions.length;

  /// Regions waiting for [rebuild].
  int get pendingRegions => _dirty.length;

  /// How much of the baked skylight shows (1.0 noon, 0.35 night, 0.0 none),
  /// read by the three lit materials when they bind.
  void setSkyIntensity(double value) {
    matSolid.skyIntensity = value;
    matCutout.skyIntensity = value;
    matLiquid.skyIntensity = value;
  }

  /// The region [pos] falls in, by floor division.
  ChunkPos regionOf(ChunkPos pos) =>
      (x: (pos.x - pos.x % regionChunks) ~/ regionChunks, z: (pos.z - pos.z % regionChunks) ~/ regionChunks);

  /// Keeps [surface] for chunk [pos] and marks its region to rebuild.
  @override
  void apply(ChunkPos pos, ChunkMeshResult surface) {
    _chunks[pos] = _ViewChunk(surface);
    _dirty.add(regionOf(pos));
  }

  /// Drops chunk [pos] and marks its region to rebuild.
  @override
  void remove(ChunkPos pos) {
    if (_chunks.remove(pos) != null) _dirty.add(regionOf(pos));
  }

  /// Builds the regions whose chunks changed, the nearest to chunk [near] first,
  /// while the next one's predicted cost fits in what is left of [budgetUsec];
  /// the rest wait for the next call. The first region is built whatever it
  /// costs, so the view keeps up; a region left with no chunk drops its node and
  /// costs nothing. Once a frame.
  void rebuild(ChunkPos near, {int budgetUsec = rebuildBudgetUsec}) {
    if (_dirty.isEmpty) return;
    final watch = Stopwatch()..start();
    final centre = regionOf(near);
    int d2(ChunkPos r) => (r.x - centre.x) * (r.x - centre.x) + (r.z - centre.z) * (r.z - centre.z);
    final order = _dirty.toList()..sort((a, b) => d2(a).compareTo(d2(b)));
    var built = 0;
    for (final region in order) {
      final members = _members(region);
      if (members.isNotEmpty) {
        if (built > 0 && watch.elapsedMicroseconds + _predictUs(members) >= budgetUsec) continue;
        _build(region, members);
        built += 1;
      } else {
        final old = _regions.remove(region);
        if (old != null) root.remove(old);
      }
      _dirty.remove(region);
    }
  }

  /// The chunks of [region] with a mesh, each with its offset in the region.
  List<(ChunkPos, _ViewChunk)> _members(ChunkPos region) => [
    for (var dx = 0; dx < regionChunks; dx++)
      for (var dz = 0; dz < regionChunks; dz++)
        if (_chunks[(x: region.x * regionChunks + dx, z: region.z * regionChunks + dz)] case final c?)
          ((x: dx, z: dz), c),
  ];

  /// What building a region of [members] should cost, by the rates measured so far.
  double _predictUs(List<(ChunkPos, _ViewChunk)> members) {
    var toPack = 0, all = 0;
    for (final (_, c) in members) {
      if (!c.packed) toPack += c.litVertexCount;
      all += c.vertexCount;
    }
    return toPack * (_packUsPerVertex ?? 0.0) + all * (_buildUsPerVertex ?? 0.0);
  }

  /// A rate after a sample of it: the sample alone at first, then a running mean.
  static double _meanWith(double? rate, double sample) => rate == null ? sample : rate + (sample - rate) * 0.2;

  void _build(ChunkPos region, List<(ChunkPos, _ViewChunk)> members) {
    final watch = Stopwatch()..start();
    final useFloat = _useFloatGeometry;
    var packed = 0;
    if (!useFloat) {
      for (final (_, c) in members) {
        if (c.packed) continue;
        packed += c.litVertexCount;
        c.pack();
      }
    }
    final packUs = watch.elapsedMicroseconds;
    if (packed > 0) _packUsPerVertex = _meanWith(_packUsPerVertex, packUs / packed);
    final old = _regions.remove(region);
    if (old != null) root.remove(old);
    final node = Node(name: 'region_${region.x}_${region.z}')
      ..position = Vector3(
        region.x * regionChunks * ChunkSize.sizeX.toDouble(),
        0,
        region.z * regionChunks * ChunkSize.sizeZ.toDouble(),
      );
    List<(ChunkPos, PackedSurface)> lit(PackedSurface? Function(_ViewChunk) of) => [
      for (final (offset, c) in members)
        if (of(c) case final packed?) (offset, packed),
    ];
    final surfaces = useFloat
        ? [
            _mergeFloat([for (final (offset, c) in members) (offset, c.rawMesh.solid)], matSolid),
            _mergeFloat([for (final (offset, c) in members) (offset, c.rawMesh.cutout)], matCutout),
            _mergeGlow([for (final (offset, c) in members) (offset, c.glow)]),
            _mergeFloat([for (final (offset, c) in members) (offset, c.rawMesh.liquid)], matLiquid),
          ]
        : [
            _mergeLit(lit((c) => c.solid), matSolid),
            _mergeLit(lit((c) => c.cutout), matCutout),
            _mergeGlow([for (final (offset, c) in members) (offset, c.glow)]),
            _mergeLit(lit((c) => c.liquid), matLiquid),
          ];
    for (final surface in surfaces) {
      if (surface != null) node.add(surface);
    }
    root.add(node);
    _regions[region] = node;
    var vertices = 0;
    for (final (_, c) in members) {
      vertices += c.vertexCount;
    }
    if (vertices > 0) _buildUsPerVertex = _meanWith(_buildUsPerVertex, (watch.elapsedMicroseconds - packUs) / vertices);
  }

  /// The region's box in its own frame, from the heights its vertices span.
  Aabb3 _bounds(double minY, double maxY) => Aabb3.minMax(
    Vector3(0, minY, 0),
    Vector3(regionChunks * ChunkSize.sizeX.toDouble(), maxY, regionChunks * ChunkSize.sizeZ.toDouble()),
  );

  /// One node drawing lit [parts] (each at its chunk's offset in the region, in
  /// chunks) in the packed terrain vertex on [material], or null when there are
  /// none.
  Node? _mergeLit(List<(ChunkPos, PackedSurface)> parts, TerrainMaterial material) {
    final m = PackedSurface.merge(parts);
    if (m == null) return null;
    return Node(mesh: Mesh(TerrainGeometry(m, _bounds(m.minY, m.maxY)), material))..shadowStatic = true;
  }

  /// One node drawing the glow [parts] on [matGlow], or null when they are all
  /// empty. Their colour keeps each block's variation baked in, which can pass
  /// 1.0 where the packed vertex stores 0..1, so they stay in the engine's vertex.
  Node? _mergeGlow(List<(ChunkPos, MeshSurface)> parts) => _mergeFloat(parts, matGlow);

  Node? _mergeFloat(List<(ChunkPos, MeshSurface)> parts, Material material) {
    final m = MergedSurface.of(parts);
    if (m == null) return null;
    final geometry = MeshGeometry.fromArrays(
      positions: m.positions,
      normals: m.normals,
      colors: m.colors,
      texCoords1: m.light, // (sky / 15, block / 15)
      indices: m.indices,
      bounds: _bounds(m.minY, m.maxY),
      retainCpuData: false,
    );
    return Node(mesh: Mesh(geometry, material))..shadowStatic = true;
  }
}

/// A chunk as [VoxelChunkView] keeps it: its mesh as the engine made it until a
/// rebuild first reads it ([pack]), then its lit surfaces packed and their
/// floats let go; the glow as the engine meshed it throughout.
class _ViewChunk {
  _ViewChunk(ChunkMeshResult mesh)
    : _mesh = mesh,
      glow = mesh.glow,
      litVertexCount = mesh.solid.vertexCount + mesh.cutout.vertexCount + mesh.liquid.vertexCount,
      vertexCount = mesh.solid.vertexCount + mesh.cutout.vertexCount + mesh.liquid.vertexCount + mesh.glow.vertexCount;

  /// The mesh whose lit surfaces are not packed yet; null once they are.
  ChunkMeshResult? _mesh;

  /// The raw unpacked mesh (retained when [_useFloatGeometry] is true).
  ChunkMeshResult get rawMesh => _mesh!;

  /// Drawn in the engine's vertex, never packed.
  final MeshSurface glow;

  /// Vertices of the solid, cutout and liquid surfaces.
  final int litVertexCount;

  /// Vertices of every surface, the glow's included.
  final int vertexCount;

  PackedSurface? _solid, _cutout, _liquid;

  /// Whether the lit surfaces are packed.
  bool get packed => _mesh == null;

  /// The packed solid surface, null when empty.
  PackedSurface? get solid => _read(_solid);

  /// The packed cutout surface, null when empty.
  PackedSurface? get cutout => _read(_cutout);

  /// The packed liquid surface, null when empty.
  PackedSurface? get liquid => _read(_liquid);

  PackedSurface? _read(PackedSurface? surface) {
    assert(packed, 'a chunk is packed before its region reads it');
    return surface;
  }

  /// Packs the lit surfaces, once.
  void pack() {
    final mesh = _mesh;
    if (mesh == null) throw StateError('a chunk is packed once');
    _solid = PackedSurface.of(mesh.solid);
    _cutout = PackedSurface.of(mesh.cutout);
    _liquid = PackedSurface.of(mesh.liquid);
    _mesh = null;
  }
}
