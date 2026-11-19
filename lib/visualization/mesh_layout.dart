import 'dart:math' as math;
import 'dart:ui';

import 'topology.dart';

/// Deterministic radial layout for the mesh view.
///
/// The local device is pinned to the centre of the canvas and peers are spread
/// equally around it on one or more concentric rings. Ring capacity comes from
/// the real node diameter plus a minimum gap, so two nodes can never overlap;
/// when a ring is full the next ring is used instead of squeezing nodes closer
/// together.
///
/// There is no force simulation, no randomness and no per-frame solving, which
/// is what previously made nodes drift and clump. Positions are recomputed only
/// when the topology or the canvas size changes, and a peer that was already on
/// screen keeps its slot when other peers join or leave.
///
/// Positions are canvas pixels at the current viewport size; zoom and pan are a
/// separate transform owned by the view.
class MeshLayout {
  MeshLayout({
    this.localDiameter = 84,
    this.peerDiameter = 44,
    this.edgePadding = 18,
    this.labelSpace = 22,
    this.minNodeGap = 26,
  });

  /// Diameter of this device's node.
  final double localDiameter;

  /// Diameter of a peer node.
  final double peerDiameter;

  /// Room kept between the outermost ring and the canvas edge.
  final double edgePadding;

  /// Room reserved under the outermost ring for its labels.
  final double labelSpace;

  /// Smallest gap between two node boundaries.
  final double minNodeGap;

  /// Stable peer order. Known peers keep their index, so a joining peer never
  /// reshuffles the rings that already exist.
  final List<String> _order = <String>[];

  final Map<String, Offset> _centers = <String, Offset>{};
  final Map<String, double> _labelWidths = <String, double>{};
  final Map<String, double> _radii = <String, double>{};
  Size _viewport = Size.zero;
  Rect _bounds = Rect.zero;
  MeshTopologySnapshot? _last;

  /// Node-centre positions keyed by mesh node ID.
  ///
  /// Returns a copy; use [centerOf] in per-frame code to avoid allocating.
  Map<String, Offset> get centers => Map<String, Offset>.unmodifiable(_centers);

  /// Position of one node, or null if it is not laid out.
  Offset? centerOf(String nodeId) => _centers[nodeId];

  /// Bounding box of all drawn nodes, including their radius.
  Rect get bounds => _bounds;

  /// Radius the painter should use for [node].
  double radiusFor(TopologyNode node) =>
      (node.isLocal ? localDiameter : peerDiameter) / 2;

  /// Widest label that still fits between neighbouring ring slots.
  double labelWidthFor(String nodeId) => _labelWidths[nodeId] ?? 128;

  /// Recomputes positions when the topology or the canvas size changes.
  void update(
    MeshTopologySnapshot topology, {
    Size viewport = const Size(360, 440),
  }) {
    if (identical(_last, topology) && viewport == _viewport) return;
    _last = topology;
    _viewport = viewport;
    _relayout(topology);
  }

  void _relayout(MeshTopologySnapshot topology) {
    final center = Offset(_viewport.width / 2, _viewport.height / 2);
    final localNode = topology.localNode;
    final peers = <TopologyNode>[
      for (final node in topology.nodes)
        if (!node.isLocal) node,
    ];

    // Keep known peers in place; sort only the newcomers so the same peer set
    // always produces the same arrangement.
    final incoming = <String>{for (final peer in peers) peer.id};
    _order.removeWhere((id) => !incoming.contains(id));
    _order.addAll(<String>[
      for (final peer in peers)
        if (!_order.contains(peer.id)) peer.id,
    ]..sort());

    _centers.clear();
    _labelWidths.clear();
    _radii.clear();

    if (localNode != null) {
      _centers[localNode.id] = center;
      _radii[localNode.id] = localDiameter / 2;
      _labelWidths[localNode.id] = 132;
    }
    if (peers.isEmpty) {
      _bounds = _boundsOf();
      return;
    }

    final localRadius = localDiameter / 2;
    final peerRadius = peerDiameter / 2;
    // Start close on a short canvas and further out on a large one, but never
    // so close that the local glow touches the first ring.
    final usable = math.max(
      0.0,
      _viewport.shortestSide / 2 - edgePadding - labelSpace,
    );
    final firstRing = math.max(
      localRadius + peerRadius + minNodeGap,
      math.min(150.0, usable * 0.55),
    );
    final ringStep = peerDiameter + minNodeGap;
    final rings = _buildRings(
      firstRing: firstRing,
      step: ringStep,
      spacing: ringStep,
      peerCount: _order.length,
    );

    var cursor = 0;
    for (var i = 0; i < rings.length; i++) {
      if (cursor >= _order.length) break;
      final ring = rings[i];
      final remaining = _order.length - cursor;
      final isLastRing = i == rings.length - 1;
      // The last ring takes whatever is left; that only happens when the peer
      // count exceeds the capacity of every ring we are willing to draw.
      final count = isLastRing ? remaining : math.min(ring.capacity, remaining);
      if (count <= 0) continue;

      final chord = count > 1
          ? 2 * ring.radius * math.sin(math.pi / count)
          : ring.radius;
      for (var slot = 0; slot < count; slot++) {
        final id = _order[cursor + slot];
        // Start at the top and go clockwise so the first peer sits at twelve
        // o'clock on every device.
        final angle = -math.pi / 2 + (2 * math.pi * slot) / count;
        _centers[id] =
            center + Offset(math.cos(angle), math.sin(angle)) * ring.radius;
        _radii[id] = peerRadius;
        _labelWidths[id] = math.max(52.0, math.min(128.0, chord - 10));
      }
      cursor += count;
    }

    _bounds = _boundsOf();
  }

  /// Builds the smallest set of rings that can hold [peerCount] peers, each ring
  /// carrying as many evenly spaced slots as its circumference allows.
  List<_Ring> _buildRings({
    required double firstRing,
    required double step,
    required double spacing,
    required int peerCount,
  }) {
    final rings = <_Ring>[];
    var radius = firstRing;
    var capacity = 0;
    // Six rings hold well over a hundred peers; the cap just bounds the loop.
    while (rings.length < 6) {
      final slots = math.max(1, (2 * math.pi * radius / spacing).floor());
      rings.add(_Ring(radius, slots));
      capacity += slots;
      if (capacity >= peerCount) break;
      radius += step;
    }
    return rings;
  }

  Rect _boundsOf() {
    if (_centers.isEmpty) return Rect.zero;
    var left = double.infinity;
    var top = double.infinity;
    var right = double.negativeInfinity;
    var bottom = double.negativeInfinity;
    for (final entry in _centers.entries) {
      final radius = _radii[entry.key] ?? peerDiameter / 2;
      final center = entry.value;
      left = math.min(left, center.dx - radius);
      top = math.min(top, center.dy - radius);
      right = math.max(right, center.dx + radius);
      bottom = math.max(bottom, center.dy + radius);
    }
    if (left > right || top > bottom) return Rect.zero;
    final rect = Rect.fromLTRB(left, top, right, bottom).inflate(10);
    return Rect.fromLTRB(
      rect.left,
      rect.top,
      math.max(rect.right, rect.left + 1),
      math.max(rect.bottom, rect.top + 1),
    );
  }
}

class _Ring {
  const _Ring(this.radius, this.capacity);

  final double radius;
  final int capacity;
}
