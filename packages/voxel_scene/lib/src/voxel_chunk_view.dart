import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart';
import 'package:voxel_engine/core.dart';

import 'merged_surface.dart';
import 'packed_surface.dart';
import 'terrain_geometry.dart';
import 'terrain_material.dart';
import 'vertex_rate.dart';
import 'view_region.dart';

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
///
/// [cull] hides the regions sight cannot reach from the camera through open
/// cells, by the [ChunkVisibility] each chunk's mesh carries
/// ([SectionOcclusion]). A hidden region's surfaces take [Node.layers] 0: the
/// colour and depth passes skip them, while they still cast into the shadow
/// map and leave its static cache alone, so a hill hidden behind the camera
/// still shades what is in view.
///
/// Regions come in two sizes: the [regionChunks] ones the view builds, and the
/// [settledRegionChunks] ones a quiet area settles into, one draw per surface
/// where its smaller regions drew several. A settled region is drawn either as
/// itself or as its [regionChunks] quadrants, never both and never neither:
///
/// * **It settles** once every one of its chunks has a mesh, none came,
///   changed or left for [settleAfter], none of its quadrants waits for
///   [rebuild], and none of its chunks lies within [settleClear] chunks of the
///   `near` that [rebuild] is given. Settling is optional work: it runs in
///   [rebuild] after the quadrants, in steps (copy a chunk, upload a part,
///   swap), each only when its predicted cost fits what the quadrants left of
///   the budget, never as a frame's forced first build, one settled region at
///   a time. Each lit surface draws in parts of at most
///   [PackedSurface.maxPartVertices] vertices, so a part uploads within the
///   budget and keeps 16-bit indices.
/// * **It splits** when one of its chunks comes, changes or leaves, or when it
///   comes within [settleClear] of `near`: its quadrants are rebuilt as any
///   region is, while it stays drawn, and replace it in the [rebuild] that has
///   built the last of them.
///
/// [pendingRegions] counts the quadrants a split waits for, never a settle.
class VoxelChunkView implements ChunkMeshSink {
  /// A view with an empty [root] named [rootName]. Add [root] to a scene.
  VoxelChunkView({
    String rootName = 'World',
    this.regionChunks = 2,
    this.settledRegionChunks = 4,
    this.settleAfter = const Duration(seconds: 2),
    this.settleClear = 2,
  }) : assert(regionChunks >= 1, 'a region holds at least one chunk'),
       assert(
         settledRegionChunks >= regionChunks && settledRegionChunks % regionChunks == 0,
         'a settled region is whole regions',
       ),
       assert(
         settledRegionChunks * ChunkSize.sizeX <= 255 && settledRegionChunks * ChunkSize.sizeZ <= 255,
         'a packed terrain vertex spans 256 m',
       ),
       assert(!settleAfter.isNegative, 'a quiet time is not negative'),
       assert(settleClear >= 0, 'a clear zone is not negative'),
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

  /// Chunks along each side of a settled region: a multiple of [regionChunks].
  /// Equal to it, nothing settles.
  final int settledRegionChunks;

  /// How long none of a settled region's chunks may have come, changed or
  /// left before it settles.
  final Duration settleAfter;

  /// Chunks around [rebuild]'s `near`, on either axis, in which no region
  /// settles and a settled one splits: the player's own edits then rebuild a
  /// [regionChunks] region in their frame, as they would with nothing settled.
  final int settleClear;

  /// At most this many settle steps a [rebuild], or as many as fit when null,
  /// so a test can stop a settle between two steps.
  @visibleForTesting
  int? settleStepLimit;

  /// Microseconds [rebuild] spends a frame by default: a quarter of a 120 Hz
  /// frame.
  static const int rebuildBudgetUsec = 2000;

  /// WebGL2 and Linux OpenGLES reject `VertexFormat.uint32x2` vertex streams,
  /// so those targets build regions with standard float32 `MeshGeometry`.
  static bool get _useFloatGeometry => kIsWeb || defaultTargetPlatform == TargetPlatform.linux;

  /// Each meshed chunk's surfaces.
  final Map<ChunkPos, _ViewChunk> _chunks = {};

  /// Each region with a node under [root], of either size.
  final Map<ViewRegionKey, ViewRegion> _regions = {};

  /// Regions of [regionChunks] whose chunks changed since they were last built.
  final Set<ChunkPos> _dirty = {};

  /// The search [cull] runs, over the visibility of the chunks kept here; a
  /// chunk with no mesh is crossed as open.
  late final SectionOcclusion _occlusion = SectionOcclusion((pos) => _chunks[pos]?.visibility);

  /// Whether [cull] has run: before it, every region draws.
  bool _culled = false;

  /// The corners of the chunks kept here, inclusive; null when a chunk came or
  /// left since they were last found.
  (ChunkPos, ChunkPos)? _span;

  /// What packing and building cost, in microseconds a vertex, as measured on
  /// the rebuilds so far; null before the first.
  double? _packUsPerVertex, _buildUsPerVertex;

  /// What a settle's copy of a chunk and upload of a part cost a vertex, as
  /// measured on the settles so far. Weighed by vertices: a settle is never
  /// forced, so a rate pushed up by a small part's fixed cost would never be
  /// measured again and would hold every settle back for good.
  final VertexRate _copyRate = VertexRate(), _uploadRate = VertexRate();

  /// The one clock settled regions' quiet time is read on.
  final Stopwatch _clock = Stopwatch()..start();

  /// When a chunk of each settled region last came, changed or left, in
  /// [_clock]'s microseconds, or last lay in the clear zone; a settled region
  /// with no chunk kept has no entry.
  final Map<ChunkPos, int> _changedAt = {};

  /// The settled regions splitting, each with the quadrants built since its
  /// split (null for one left with no chunk), out of [root] until the last.
  final Map<ChunkPos, Map<ChunkPos, ViewRegion?>> _splits = {};

  /// The settle under way, if any.
  _Settle? _settling;

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

  /// The settled region [pos] falls in, by floor division.
  ChunkPos _settledOf(ChunkPos pos) => (
    x: (pos.x - pos.x % settledRegionChunks) ~/ settledRegionChunks,
    z: (pos.z - pos.z % settledRegionChunks) ~/ settledRegionChunks,
  );

  /// The key of the settled region at [at].
  ViewRegionKey _settledKey(ChunkPos at) => (chunks: settledRegionChunks, at: at);

  /// The [regionChunks] regions the settled region at [at] is made of.
  Iterable<ChunkPos> _quadrants(ChunkPos at) sync* {
    final n = settledRegionChunks ~/ regionChunks;
    for (var dx = 0; dx < n; dx++) {
      for (var dz = 0; dz < n; dz++) {
        yield (x: at.x * n + dx, z: at.z * n + dz);
      }
    }
  }

  /// Whether a settled region larger than a region exists to settle into.
  // A settle copies and uploads packed surfaces, which the float32 fallback
  // never makes.
  bool get _settles => !_useFloatGeometry && settledRegionChunks > regionChunks;

  /// Keeps [surface] for chunk [pos] and marks its region to rebuild.
  @override
  void apply(ChunkPos pos, ChunkMeshResult surface) {
    if (_chunks[pos] == null) _span = null;
    _chunks[pos] = _ViewChunk(surface);
    _dirty.add(regionOf(pos));
    _occlusion.markChanged(pos);
    _changed(pos);
  }

  /// Drops chunk [pos] and marks its region to rebuild.
  @override
  void remove(ChunkPos pos) {
    if (_chunks.remove(pos) == null) return;
    _dirty.add(regionOf(pos));
    _occlusion.markChanged(pos);
    _span = null;
    _changed(pos);
  }

  /// Chunk [pos] came, changed or left: its settled region restarts its quiet
  /// time, drops a settle under way and splits if settled.
  void _changed(ChunkPos pos) {
    if (!_settles) return;
    final at = _settledOf(pos);
    if (_settling?.region.at == at) _settling = null;
    if (_regions.containsKey(_settledKey(at))) _split(at);
    if (_chunks.containsKey(pos) || _members(at, settledRegionChunks).isNotEmpty) {
      _changedAt[at] = _clock.elapsedMicroseconds;
    } else {
      _changedAt.remove(at);
    }
  }

  /// Starts splitting the settled region at [at], once: its quadrants are
  /// rebuilt while it stays drawn.
  void _split(ChunkPos at) {
    if (_splits.containsKey(at)) return;
    _splits[at] = {};
    _dirty.addAll(_quadrants(at));
  }

  /// Hides the regions sight cannot reach from [eye] through open cells, and
  /// shows the ones it can: a region draws when any of its chunks was reached.
  /// The search runs again only when [eye] entered another 16-tall section, or
  /// a chunk came, changed or left since the last one; otherwise this costs
  /// nothing. A region [rebuild] builds later takes the last search's result.
  /// Once a frame, after [rebuild]. True when the search ran.
  bool cull(Vector3 eye) {
    final camera = ChunkStreamer.chunkOfXZ(eye.x.floor(), eye.z.floor());
    final (lo, hi) = _span ??= _spanOfChunks();
    final min = (x: math.min(lo.x, camera.x), z: math.min(lo.z, camera.z));
    final max = (x: math.max(hi.x, camera.x), z: math.max(hi.z, camera.z));
    if (!_occlusion.update(camera, SectionOcclusion.sectionAt(eye.y), min: min, max: max)) return false;
    _culled = true;
    for (final region in _regions.values) {
      _show(region.node, _reached(region));
    }
    return true;
  }

  /// The corners of the chunks kept here; an empty view spans nothing, which
  /// [cull]'s window around the camera's chunk then covers.
  (ChunkPos, ChunkPos) _spanOfChunks() {
    var minX = 1 << 30, minZ = 1 << 30, maxX = -(1 << 30), maxZ = -(1 << 30);
    for (final pos in _chunks.keys) {
      minX = math.min(minX, pos.x);
      minZ = math.min(minZ, pos.z);
      maxX = math.max(maxX, pos.x);
      maxZ = math.max(maxZ, pos.z);
    }
    return ((x: minX, z: minZ), (x: maxX, z: maxZ));
  }

  /// Whether the last search reached a chunk of [region] that has a mesh.
  bool _reached(ViewRegion region) {
    final reached = _occlusion.reached;
    for (final pos in region.members) {
      if (_chunks.containsKey(pos) && reached.contains(pos)) return true;
    }
    return false;
  }

  /// Puts a region's node and its surfaces on the default layer when [shown],
  /// on none when not. Their [Node.visible] and shadow settings stay as built.
  static void _show(Node region, bool shown) {
    final layers = shown ? kRenderLayerDefault : 0;
    region.layers = layers;
    for (final surface in region.children) {
      surface.layers = layers;
    }
  }

  /// Splits the settled regions within [settleClear] of chunk [near]. Then
  /// builds the regions whose chunks changed, the nearest to [near] first,
  /// while the next one's predicted cost fits in what is left of [budgetUsec];
  /// the rest wait for the next call. The first region is built whatever it
  /// costs, so the view keeps up; a region left with no chunk drops its node and
  /// costs nothing. A split's quadrants replace it once the last is built. Then
  /// settles what the budget has room left for. Once a frame.
  void rebuild(ChunkPos near, {int budgetUsec = rebuildBudgetUsec}) {
    final watch = Stopwatch()..start();
    if (_settles) _clear(near);
    if (_dirty.isNotEmpty) _buildDirty(near, budgetUsec, watch);
    if (_settles) _settle(near, budgetUsec, watch);
  }

  void _buildDirty(ChunkPos near, int budgetUsec, Stopwatch watch) {
    final centre = regionOf(near);
    int d2(ChunkPos r) => (r.x - centre.x) * (r.x - centre.x) + (r.z - centre.z) * (r.z - centre.z);
    final order = _dirty.toList()..sort((a, b) => d2(a).compareTo(d2(b)));
    var built = 0;
    for (final region in order) {
      final members = _members(region, regionChunks);
      // A quadrant of a settled region splitting waits out of [root] for the others.
      final split = _splits[_settledOf((x: region.x * regionChunks, z: region.z * regionChunks))];
      if (members.isNotEmpty) {
        if (built > 0 && watch.elapsedMicroseconds + _predictUs(members) >= budgetUsec) continue;
        final made = _build(region, members);
        if (split != null) {
          split[region] = made;
        } else {
          _drop((chunks: regionChunks, at: region));
          _place(made);
        }
        built += 1;
      } else if (split != null) {
        split[region] = null;
      } else {
        _drop((chunks: regionChunks, at: region));
      }
      _dirty.remove(region);
    }
    final quadrants = (settledRegionChunks ~/ regionChunks) * (settledRegionChunks ~/ regionChunks);
    _splits.removeWhere((at, ready) {
      if (ready.length < quadrants) return false;
      _drop(_settledKey(at));
      for (final quadrant in ready.values) {
        if (quadrant != null) _place(quadrant);
      }
      return true;
    });
  }

  /// Removes the region keyed [key] from [root], if it is there.
  void _drop(ViewRegionKey key) {
    final old = _regions.remove(key);
    if (old != null) root.remove(old.node);
  }

  /// Whether the settled region at [at] holds a chunk within [settleClear] of
  /// [near] on both axes.
  bool _inClearZone(ChunkPos at, ChunkPos near) {
    final x0 = at.x * settledRegionChunks, z0 = at.z * settledRegionChunks;
    return near.x >= x0 - settleClear &&
        near.x < x0 + settledRegionChunks + settleClear &&
        near.z >= z0 - settleClear &&
        near.z < z0 + settledRegionChunks + settleClear;
  }

  /// Splits the settled regions in the clear zone around [near], drops a
  /// settle under way there, and restarts their quiet time, so one left
  /// behind settles [settleAfter] after it left the zone.
  void _clear(ChunkPos near) {
    final lo = _settledOf((x: near.x - settleClear, z: near.z - settleClear));
    final hi = _settledOf((x: near.x + settleClear, z: near.z + settleClear));
    final now = _clock.elapsedMicroseconds;
    for (var x = lo.x; x <= hi.x; x++) {
      for (var z = lo.z; z <= hi.z; z++) {
        final at = (x: x, z: z);
        if (_settling?.region.at == at) _settling = null;
        if (_regions.containsKey(_settledKey(at))) _split(at);
        if (_changedAt.containsKey(at)) _changedAt[at] = now;
      }
    }
  }

  /// Runs settle steps while the next one's predicted cost fits what is left
  /// of [budgetUsec]; a step predicted at or over the whole budget drops its
  /// settle, whose region stays in quadrants. When one settle ends, the next
  /// candidate starts, the nearest to [near] first.
  void _settle(ChunkPos near, int budgetUsec, Stopwatch watch) {
    var steps = 0;
    while (true) {
      if (watch.elapsedMicroseconds >= budgetUsec) return;
      final settle = _settling ??= _candidate(near, budgetUsec);
      if (settle == null) return;
      final cost = settle.predictUs(this);
      if (cost >= budgetUsec) {
        _settling = null;
        return;
      }
      if (watch.elapsedMicroseconds + cost >= budgetUsec) return;
      if (settleStepLimit case final limit? when steps >= limit) return;
      steps += 1;
      if (settle.step(this)) _settling = null;
    }
  }

  /// The settled region to settle next, the nearest to [near] first, planned:
  /// every one of its chunks has a mesh, quiet for [settleAfter], no quadrant
  /// waiting for a build, outside the clear zone, and no step of its plan
  /// predicted at or over [budgetUsec]. Null when none is.
  _Settle? _candidate(ChunkPos near, int budgetUsec) {
    if (_changedAt.isEmpty) return null;
    final now = _clock.elapsedMicroseconds, quiet = settleAfter.inMicroseconds;
    final centre = _settledOf(near);
    int d2(ChunkPos r) => (r.x - centre.x) * (r.x - centre.x) + (r.z - centre.z) * (r.z - centre.z);
    final whole = settledRegionChunks * settledRegionChunks;
    final ready = [
      for (final MapEntry(key: at, value: changed) in _changedAt.entries)
        if (now - changed >= quiet &&
            !_regions.containsKey(_settledKey(at)) &&
            !_inClearZone(at, near) &&
            !_quadrants(at).any(_dirty.contains))
          at,
    ]..sort((a, b) => d2(a).compareTo(d2(b)));
    for (final at in ready) {
      final members = _members(at, settledRegionChunks);
      if (members.length < whole) continue;
      final region = ViewRegion(at, settledRegionChunks, Node(name: 'settled_${at.x}_${at.z}'));
      final settle = _Settle.plan(this, region, members);
      if (settle.maxPredictUs(this) < budgetUsec) return settle;
    }
    return null;
  }

  /// The chunks with a mesh of the [side] × [side] region at [at] (in regions
  /// of that side), each with its offset in the region.
  List<(ChunkPos, _ViewChunk)> _members(ChunkPos at, int side) => [
    for (var dx = 0; dx < side; dx++)
      for (var dz = 0; dz < side; dz++)
        if (_chunks[(x: at.x * side + dx, z: at.z * side + dz)] case final c?) ((x: dx, z: dz), c),
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

  /// The [regionChunks] region at [region] built from [members], not placed.
  ViewRegion _build(ChunkPos region, List<(ChunkPos, _ViewChunk)> members) {
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
    final node = Node(name: 'region_${region.x}_${region.z}');
    final built = ViewRegion(region, regionChunks, node);
    node.position = built.position;
    List<(ChunkPos, PackedSurface)> lit(PackedSurface? Function(_ViewChunk) of) => [
      for (final (offset, c) in members)
        if (of(c) case final packed?) (offset, packed),
    ];
    final surfaces = useFloat
        ? [
            _mergeFloat(built, [for (final (offset, c) in members) (offset, c.rawMesh.solid)], matSolid),
            _mergeFloat(built, [for (final (offset, c) in members) (offset, c.rawMesh.cutout)], matCutout),
            _mergeGlow(built, [for (final (offset, c) in members) (offset, c.glow)]),
            _mergeFloat(built, [for (final (offset, c) in members) (offset, c.rawMesh.liquid)], matLiquid),
          ]
        : [
            _mergeLit(built, lit((c) => c.solid), matSolid),
            _mergeLit(built, lit((c) => c.cutout), matCutout),
            _mergeGlow(built, [for (final (offset, c) in members) (offset, c.glow)]),
            _mergeLit(built, lit((c) => c.liquid), matLiquid),
          ];
    for (final surface in surfaces) {
      if (surface != null) node.add(surface);
    }
    var vertices = 0;
    for (final (_, c) in members) {
      vertices += c.vertexCount;
    }
    if (vertices > 0) _buildUsPerVertex = _meanWith(_buildUsPerVertex, (watch.elapsedMicroseconds - packUs) / vertices);
    return built;
  }

  /// Adds [region]'s node under [root] in the last cull's state, keyed by its
  /// size and position.
  void _place(ViewRegion region) {
    assert(!_regions.containsKey(region.key), 'one node a region');
    _show(region.node, !_culled || _reached(region));
    root.add(region.node);
    _regions[region.key] = region;
  }

  /// One node drawing lit [parts] (each at its chunk's offset in [region], in
  /// chunks) in the packed terrain vertex on [material], or null when there are
  /// none.
  Node? _mergeLit(ViewRegion region, List<(ChunkPos, PackedSurface)> parts, TerrainMaterial material) {
    final m = PackedSurface.merge(parts);
    if (m == null) return null;
    return _litNode(region, m, material);
  }

  /// One node drawing [merged], in [region]'s frame, on [material].
  static Node _litNode(ViewRegion region, PackedSurface merged, TerrainMaterial material) =>
      Node(mesh: Mesh(TerrainGeometry(merged, region.bounds(merged.minY, merged.maxY)), material))..shadowStatic = true;

  /// One node drawing the glow [parts] on [matGlow], or null when they are all
  /// empty. Their colour keeps each block's variation baked in, which can pass
  /// 1.0 where the packed vertex stores 0..1, so they stay in the engine's vertex.
  Node? _mergeGlow(ViewRegion region, List<(ChunkPos, MeshSurface)> parts) => _mergeFloat(region, parts, matGlow);

  Node? _mergeFloat(ViewRegion region, List<(ChunkPos, MeshSurface)> parts, Material material) {
    final m = MergedSurface.of(parts);
    if (m == null) return null;
    final geometry = MeshGeometry.fromArrays(
      positions: m.positions,
      normals: m.normals,
      colors: m.colors,
      texCoords1: m.light, // (sky / 15, block / 15)
      indices: m.indices,
      bounds: region.bounds(m.minY, m.maxY),
      retainCpuData: false,
    );
    return Node(mesh: Mesh(geometry, material))..shadowStatic = true;
  }
}

/// A settled region on its way in: one step at a time, it copies each chunk's
/// lit surfaces into their parts, uploads each part and the glow, then swaps
/// the region in for its quadrants. Dropped, with what it built, when a chunk
/// of it comes, changes or leaves first, or when it enters the clear zone.
class _Settle {
  _Settle._(this.region, this.members, this._copies, this._uploads);

  /// Plans the settle of [region] from [members], every one of its chunks.
  /// They were drawn in their quadrants, so their lit surfaces are packed.
  factory _Settle.plan(VoxelChunkView view, ViewRegion region, List<(ChunkPos, _ViewChunk)> members) {
    final copies = List.generate(members.length, (_) => <(_Part, ChunkPos, PackedSurface)>[]);
    List<_Part> partsOf(PackedSurface? Function(_ViewChunk) of, TerrainMaterial material) {
      final lit = [
        for (var i = 0; i < members.length; i++)
          if (of(members[i].$2) case final s?) (i, members[i].$1, s),
      ];
      final parts = <_Part>[];
      var j = 0;
      for (final run in PackedSurface.split([for (final (_, offset, s) in lit) (offset, s)])) {
        final part = _Part(run, material);
        for (var k = 0; k < run.length; k++) {
          final (i, offset, s) = lit[j++];
          copies[i].add((part, offset, s));
        }
        parts.add(part);
      }
      return parts;
    }

    // The order a region the view builds draws in: the liquid last.
    final uploads = <_Part?>[
      ...partsOf((c) => c.solid, view.matSolid),
      ...partsOf((c) => c.cutout, view.matCutout),
      if (members.any((m) => m.$2.glow.vertexCount > 0)) null,
      ...partsOf((c) => c.liquid, view.matLiquid),
    ];
    return _Settle._(region, members, copies, uploads);
  }

  /// The region settling, its node out of [VoxelChunkView.root] until the swap.
  final ViewRegion region;

  /// Its chunks, each at its offset in [region].
  final List<(ChunkPos, _ViewChunk)> members;

  /// What each chunk's copy step moves: each of its lit surfaces into its part.
  final List<List<(_Part, ChunkPos, PackedSurface)>> _copies;

  /// The upload steps, in draw order: each lit part, null for the glow when
  /// there is any.
  final List<_Part?> _uploads;

  /// The next step: the copies, then the uploads, then the swap.
  int _next = 0;

  int get _steps => _copies.length + _uploads.length + 1;

  /// The vertices the glow step merges and uploads.
  int get _glowVertices {
    var n = 0;
    for (final (_, c) in members) {
      n += c.glow.vertexCount;
    }
    return n;
  }

  /// What step [i] should cost, by [view]'s rates.
  double _predictStepUs(VoxelChunkView view, int i) {
    final copy = view._copyRate.usPerVertex, upload = view._uploadRate.usPerVertex;
    if (i < _copies.length) return members[i].$2.litVertexCount * copy;
    final u = i - _copies.length;
    if (u < _uploads.length) {
      final part = _uploads[u];
      return part == null ? _glowVertices * (copy + upload) : part.vertexCount * upload;
    }
    return 0.0;
  }

  /// What the next step should cost.
  double predictUs(VoxelChunkView view) => _predictStepUs(view, _next);

  /// What the dearest step left should cost.
  double maxPredictUs(VoxelChunkView view) {
    var most = 0.0;
    for (var i = _next; i < _steps; i++) {
      most = math.max(most, _predictStepUs(view, i));
    }
    return most;
  }

  /// Runs the next step; true once the region is swapped in.
  bool step(VoxelChunkView view) {
    final i = _next++;
    final watch = Stopwatch()..start();
    if (i < _copies.length) {
      var vertices = 0;
      for (final (part, offset, s) in _copies[i]) {
        (part.merge ??= PackedSurfaceMerge(part.vertexCount, part.indexCount)).add(offset, s);
        vertices += s.vertexCount;
      }
      if (vertices > 0) view._copyRate.add(watch.elapsedMicroseconds, vertices);
      return false;
    }
    final u = i - _copies.length;
    if (u < _uploads.length) {
      final part = _uploads[u];
      if (part == null) {
        final glow = view._mergeGlow(region, [for (final (offset, c) in members) (offset, c.glow)]);
        if (glow != null) region.node.add(glow);
        return false;
      }
      final merge = part.merge;
      if (merge == null) throw StateError('a part uploads after its chunks are copied');
      region.node.add(VoxelChunkView._litNode(region, merge.finish(), part.material));
      part.merge = null;
      view._uploadRate.add(watch.elapsedMicroseconds, part.vertexCount);
      return false;
    }
    _swap(view);
    return true;
  }

  /// Puts [region] under [VoxelChunkView.root] in place of its quadrants.
  void _swap(VoxelChunkView view) {
    final o = region.origin;
    assert(
      members.every((m) => identical(view._chunks[(x: o.x + m.$1.x, z: o.z + m.$1.z)], m.$2)),
      'a settle swaps in the chunks it copied',
    );
    for (final quadrant in view._quadrants(region.at)) {
      final old = view._regions.remove((chunks: view.regionChunks, at: quadrant));
      if (old == null) throw StateError('a settled region swaps in for its built quadrants: $quadrant');
      view.root.remove(old.node);
    }
    region.node.position = region.position;
    view._place(region);
  }
}

/// One part of a settled region's lit surface on [material]: the chunks it
/// merges, at most [PackedSurface.maxPartVertices] vertices between them
/// unless one chunk alone passes it.
class _Part {
  _Part(List<(ChunkPos, PackedSurface)> members, this.material)
    : vertexCount = members.fold(0, (n, m) => n + m.$2.vertexCount),
      indexCount = members.fold(0, (n, m) => n + m.$2.indices.length);

  /// What it draws on.
  final TerrainMaterial material;

  /// The vertices of its chunks.
  final int vertexCount;

  /// The indices of its chunks.
  final int indexCount;

  /// The copy so far, from its first chunk's copy step until its upload.
  PackedSurfaceMerge? merge;
}

/// A chunk as [VoxelChunkView] keeps it: its mesh as the engine made it until a
/// rebuild first reads it ([pack]), then its lit surfaces packed and their
/// floats let go; the glow as the engine meshed it throughout.
class _ViewChunk {
  _ViewChunk(ChunkMeshResult mesh)
    : _mesh = mesh,
      glow = mesh.glow,
      visibility = mesh.visibility,
      litVertexCount = mesh.solid.vertexCount + mesh.cutout.vertexCount + mesh.liquid.vertexCount,
      vertexCount = mesh.solid.vertexCount + mesh.cutout.vertexCount + mesh.liquid.vertexCount + mesh.glow.vertexCount;

  /// The mesh whose lit surfaces are not packed yet; null once they are.
  ChunkMeshResult? _mesh;

  /// The raw unpacked mesh (retained when [_useFloatGeometry] is true).
  ChunkMeshResult get rawMesh => _mesh!;

  /// Drawn in the engine's vertex, never packed.
  final MeshSurface glow;

  /// Which faces of each section its open cells join, for [VoxelChunkView.cull].
  final ChunkVisibility visibility;

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
