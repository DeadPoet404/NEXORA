import 'dart:math' as math;
import 'dart:ui';

import 'package:graphview/GraphView.dart';

import 'topology.dart';

/// Turns a [MeshTopologySnapshot] into node positions.
///
/// The force-directed layout itself comes from `package:graphview`
/// (`FruchtermanReingoldAlgorithm`); this class only adapts Nexora's topology
/// model to it and keeps node objects alive between snapshots so a peer
/// joining or leaving nudges the layout instead of reshuffling it.
///
/// Positions are the algorithm's own coordinate space. Fitting that space to
/// the screen (pan/zoom) is the view's job.
class MeshLayout {
  MeshLayout({
    this.localDiameter = 76,
    this.peerDiameter = 56,
    this.iterations = 140,
  });

  final double localDiameter;
  final double peerDiameter;

  /// Force-layout iterations per update. Low values keep the animation calm.
  final int iterations;

  final Map<String, Node> _nodes = <String, Node>{};
  Map<String, Offset> _centers = const <String, Offset>{};
  Rect _bounds = Rect.zero;
  MeshTopologySnapshot? _last;

  /// Node-centre positions keyed by mesh node ID.
  Map<String, Offset> get centers => _centers;

  /// Bounding box of all drawn nodes (including their radius).
  Rect get bounds => _bounds;

  double radiusFor(TopologyNode node) =>
      (node.isLocal ? localDiameter : peerDiameter) / 2;

  /// Recomputes positions if [topology] is a new snapshot.
  void update(MeshTopologySnapshot topology) {
    if (identical(_last, topology)) return;
    _last = topology;

    final ids = <String>{for (final node in topology.nodes) node.id};
    _nodes.removeWhere((id, _) => !ids.contains(id));

    for (final node in topology.nodes) {
      final diameter = node.isLocal ? localDiameter : peerDiameter;
      final existing = _nodes[node.id];
      if (existing != null) {
        existing.size = Size(diameter, diameter);
        continue;
      }
      _nodes[node.id] = Node.Id(node.id)
        ..size = Size(diameter, diameter)
        ..position = _seedPosition(topology, node);
    }

    if (_nodes.isEmpty) {
      _centers = const <String, Offset>{};
      _bounds = Rect.zero;
      return;
    }

    final graph = Graph();
    for (final node in _nodes.values) {
      graph.addNode(node);
    }
    for (final link in topology.links) {
      final from = _nodes[link.sourceId];
      final to = _nodes[link.targetId];
      if (from == null || to == null || identical(from, to)) continue;
      graph.addEdgeS(Edge(from, to));
    }

    if (graph.nodeCount() > 1) {
      final algorithm = FruchtermanReingoldAlgorithm(
        FruchtermanReingoldConfiguration(
          iterations: iterations,
          // Seeded positions are kept; randomising every update would make the
          // picture jump whenever a peer appears.
          shuffleNodes: false,
        ),
      );
      // graphview's documented lifecycle is init() → run(). init() also fills
      // the displacement map that run() indexes, so it must not be skipped.
      algorithm.init(graph);
      algorithm.run(graph, 0, 0);
    } else {
      // graphview's cluster packing needs at least two nodes; a lone device is
      // simply placed at the origin.
      _nodes.values.first.position = Offset.zero;
    }

    final centers = <String, Offset>{};
    for (final entry in _nodes.entries) {
      final node = entry.value;
      centers[entry.key] = node.position + Offset(node.width / 2, node.height / 2);
    }
    _centers = Map<String, Offset>.unmodifiable(centers);
    _bounds = _boundsOf(_centers);
  }

  /// Places a brand-new node at a stable spot near the local device so the
  /// force layout starts from something sensible.
  Offset _seedPosition(MeshTopologySnapshot topology, TopologyNode node) {
    if (node.isLocal) return const Offset(160, 160);
    final anchor = _centers[topology.localNodeId] ?? const Offset(160, 160);
    final hash = node.id.hashCode;
    final angle = (hash % 360) * math.pi / 180.0;
    final distance = 90.0 + (hash.abs() % 60);
    return anchor +
        Offset(math.cos(angle) * distance, math.sin(angle) * distance);
  }

  Rect _boundsOf(Map<String, Offset> centers) {
    var left = double.infinity;
    var top = double.infinity;
    var right = double.negativeInfinity;
    var bottom = double.negativeInfinity;
    for (final entry in centers.entries) {
      final node = _nodes[entry.key];
      final radius = node == null
          ? peerDiameter / 2
          : math.max(node.width, node.height) / 2;
      final center = entry.value;
      left = math.min(left, center.dx - radius);
      top = math.min(top, center.dy - radius);
      right = math.max(right, center.dx + radius);
      bottom = math.max(bottom, center.dy + radius);
    }
    if (left > right || top > bottom) return Rect.zero;
    return Rect.fromLTRB(left, top, right, bottom).inflate(14);
  }
}
