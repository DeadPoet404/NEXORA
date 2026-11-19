import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'mesh_layout.dart';
import 'topology.dart';
import 'topology_source.dart';

/// Animated, pannable view of the mesh network.
///
/// Layout comes from `package:graphview` (see [MeshLayout]); the motion,
/// message hops, states and gestures are drawn here. The widget is driven only
/// by a [MeshTopologySource], so it has no knowledge of BLE, routing or
/// storage, and simulated data is labelled on screen.
class MeshNetworkView extends StatefulWidget {
  const MeshNetworkView({
    super.key,
    required this.source,
    this.localDiameter = 76,
    this.peerDiameter = 56,
  });

  final MeshTopologySource source;

  /// Diameter of this device's node, in layout units.
  final double localDiameter;

  /// Diameter of a peer node, in layout units.
  final double peerDiameter;

  @override
  State<MeshNetworkView> createState() => _MeshNetworkViewState();
}

class _MeshNetworkViewState extends State<MeshNetworkView>
    with SingleTickerProviderStateMixin {
  late final MeshLayout _layout = MeshLayout(
    localDiameter: widget.localDiameter,
    peerDiameter: widget.peerDiameter,
  );

  final _scene = _MeshScene();
  final _frame = ValueNotifier<double>(0);
  final _seenHops = <String>{};

  Ticker? _ticker;
  StreamSubscription<MeshTopologySnapshot>? _sub;
  Duration _lastElapsed = Duration.zero;
  MeshTopologySnapshot _topology = const MeshTopologySnapshot.empty();

  Size _viewport = Size.zero;
  Rect? _fitBounds;
  double _scale = 1;
  Offset _offset = Offset.zero;
  bool _userAdjusted = false;

  double _startScale = 1;
  Offset _startWorldFocal = Offset.zero;

  @override
  void initState() {
    super.initState();
    _scene.localRadius = widget.localDiameter / 2;
    _scene.peerRadius = widget.peerDiameter / 2;
    _topology = widget.source.current;
    _layout.update(_topology);
    _syncScene();
    _ticker = createTicker(_onTick)..start();
    _listen(widget.source);
  }

  @override
  void didUpdateWidget(MeshNetworkView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.source, widget.source)) return;
    _sub?.cancel();
    _seenHops.clear();
    _scene.nodes.clear();
    _scene.links.clear();
    _scene.packets.clear();
    _scene.flashes.clear();
    _fitBounds = null;
    _userAdjusted = false;
    _listen(widget.source);
    // didUpdateWidget is always followed by build(), so the fields can be
    // assigned directly here.
    _topology = widget.source.current;
    _layout.update(_topology);
    _syncScene();
    _fitToViewport();
  }

  void _listen(MeshTopologySource source) {
    _sub = source.changes.listen(_onSnapshot, onError: _onSourceError);
  }

  void _onSourceError(Object error, StackTrace stackTrace) {
    // A transport error just means no new topology; the last snapshot stands.
  }

  @override
  void dispose() {
    _sub?.cancel();
    _sub = null;
    _ticker?.stop();
    _ticker?.dispose();
    _ticker = null;
    _frame.dispose();
    super.dispose();
  }

  void _onSnapshot(MeshTopologySnapshot snapshot) {
    if (!mounted) return;
    _layout.update(snapshot);
    setState(() {
      _topology = snapshot;
      _syncScene();
    });
    if (!_userAdjusted) _fitToViewport();
  }

  /// Reconciles the animated scene with [_topology]: new nodes and links fade
  /// in, missing ones fade out but stay until they have finished.
  void _syncScene() {
    final nodeIds = <String>{};
    for (final node in _topology.nodes) {
      nodeIds.add(node.id);
      final existing = _scene.nodes[node.id];
      if (existing == null) {
        _scene.nodes[node.id] = _NodeVisual(
          node: node,
          position: _layout.centers[node.id] ?? Offset.zero,
        );
      } else {
        existing.node = node;
        existing.removed = false;
      }
    }
    for (final visual in _scene.nodes.values) {
      if (!nodeIds.contains(visual.node.id)) visual.removed = true;
    }

    final linkIds = <String>{};
    for (final link in _topology.links) {
      linkIds.add(link.id);
      final existing = _scene.links[link.id];
      if (existing == null) {
        _scene.links[link.id] = _LinkVisual(
          id: link.id,
          sourceId: link.sourceId,
          targetId: link.targetId,
          state: link.state,
        );
      } else {
        existing.state = link.state;
        existing.removed = false;
      }
    }
    for (final visual in _scene.links.values) {
      if (!linkIds.contains(visual.id)) visual.removed = true;
    }

    for (final hop in _topology.transmissions) {
      if (_seenHops.add(hop.id)) _spawnHop(hop);
    }
    if (_seenHops.length > 256) _seenHops.clear();
  }

  void _spawnHop(TopologyTransmission hop) {
    if (!_scene.links.containsKey(
      TopologyLink.linkIdBetween(hop.sourceId, hop.targetId),
    )) {
      return;
    }
    if (!_scene.nodes.containsKey(hop.sourceId) ||
        !_scene.nodes.containsKey(hop.targetId)) {
      return;
    }
    if (_scene.packets.length >= 24) _scene.packets.removeAt(0);
    _scene.packets.add(_Packet(
      sourceId: hop.sourceId,
      targetId: hop.targetId,
      relayed: hop.relayed,
    ));
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastElapsed).inMicroseconds / 1000000.0;
    _lastElapsed = elapsed;
    if (dt <= 0) return;
    // Clamp after a stall so nothing teleports.
    final step = math.min(dt, 0.05);
    _scene.time += step;
    final smoothing = 1 - math.exp(-step * 7);
    final appearStep = math.min(1.0, step * 3.2);

    for (final entry in _scene.nodes.entries.toList()) {
      final visual = entry.value;
      if (!visual.removed) {
        final target = _layout.centers[entry.key];
        if (target != null) {
          visual.position =
              Offset.lerp(visual.position, target, smoothing) ?? visual.position;
        }
      }
      final goal = visual.removed ? 0.0 : 1.0;
      visual.appearance += (goal - visual.appearance) * appearStep;
      if (visual.removed && visual.appearance < 0.02) {
        _scene.nodes.remove(entry.key);
      }
    }

    for (final entry in _scene.links.entries.toList()) {
      final link = entry.value;
      final goal = link.removed ? 0.0 : 1.0;
      link.appearance += (goal - link.appearance) * appearStep;
      if (link.removed && link.appearance < 0.02) {
        _scene.links.remove(entry.key);
      }
    }

    for (final packet in List<_Packet>.of(_scene.packets)) {
      packet.progress += step / _Packet.travelSeconds;
      if (packet.progress >= 1) {
        _scene.packets.remove(packet);
        _scene.flashes[packet.targetId] = 1;
      }
    }

    for (final entry in _scene.flashes.entries.toList()) {
      final value = entry.value - step * 2.0;
      if (value <= 0) {
        _scene.flashes.remove(entry.key);
      } else {
        _scene.flashes[entry.key] = value;
      }
    }

    _frame.value = _scene.time;
  }

  void _fitToViewport([Size? size]) {
    final viewport = size ?? _viewport;
    if (viewport.isEmpty) return;
    final bounds = _layout.bounds;
    if (bounds.isEmpty || bounds.width <= 0 || bounds.height <= 0) return;

    // Fitting only grows: a peer joining should not rescale the whole picture.
    final previous = _fitBounds;
    final fit = previous == null ? bounds : previous.expandToInclude(bounds);
    _fitBounds = fit;

    const padding = 46.0;
    final availableWidth = math.max(1.0, viewport.width - padding * 2);
    final availableHeight = math.max(1.0, viewport.height - padding * 2);
    final scale = math
        .min(availableWidth / fit.width, availableHeight / fit.height)
        .clamp(0.35, 1.9)
        .toDouble();
    _scale = scale;
    _offset =
        Offset(viewport.width / 2, viewport.height / 2) - fit.center * scale;
  }

  void _resetView() {
    setState(() {
      _userAdjusted = false;
      _fitBounds = null;
      _fitToViewport();
    });
  }

  void _onScaleStart(ScaleStartDetails details) {
    _startScale = _scale;
    _startWorldFocal = _scale == 0
        ? details.localFocalPoint
        : (details.localFocalPoint - _offset) / _scale;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final nextScale = (_startScale * details.scale).clamp(0.3, 4.0).toDouble();
    setState(() {
      _scale = nextScale;
      _offset = details.localFocalPoint - _startWorldFocal * nextScale;
      _userAdjusted = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final simulated = widget.source.isSimulated || _topology.simulated;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        if (size != _viewport) {
          _viewport = size;
          if (!_userAdjusted) _fitToViewport(size);
        }
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onScaleStart: _onScaleStart,
                onScaleUpdate: _onScaleUpdate,
                child: CustomPaint(
                  painter: _MeshNetworkPainter(
                    scene: _scene,
                    scale: _scale,
                    offset: _offset,
                    scheme: scheme,
                    textScaler: MediaQuery.textScalerOf(context),
                    repaint: _frame,
                  ),
                  size: Size.infinite,
                ),
              ),
            ),
            if (simulated)
              const Positioned(top: 12, left: 12, child: _SimulatedPill()),
            Positioned(
              top: 6,
              right: 6,
              child: IconButton(
                tooltip: 'Centre network',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.center_focus_strong, size: 20),
                onPressed: _resetView,
              ),
            ),
            Positioned(
              left: 14,
              bottom: 8,
              child: Text(
                '${_topology.nodes.length} nodes · '
                '${_topology.activeLinkCount} links',
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SimulatedPill extends StatelessWidget {
  const _SimulatedPill();

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final foreground = dark ? Colors.amber.shade200 : Colors.amber.shade900;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: dark ? 0.16 : 0.22),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.amber.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.science_outlined, size: 13, color: foreground),
          const SizedBox(width: 6),
          Text(
            'SIMULATED NETWORK',
            style: TextStyle(
              fontSize: 10,
              letterSpacing: 1.0,
              fontWeight: FontWeight.w700,
              color: foreground,
            ),
          ),
        ],
      ),
    );
  }
}

/// Colour used for a node phase, shared with the on-screen legend so the two
/// cannot drift apart.
Color meshPhaseColor(TopologyNodePhase phase, ColorScheme scheme) =>
    switch (phase) {
      TopologyNodePhase.local => scheme.primary,
      TopologyNodePhase.connected => const Color(0xFF2FB67C),
      TopologyNodePhase.connecting => scheme.tertiary,
      TopologyNodePhase.discovering => scheme.secondary,
      TopologyNodePhase.unavailable => scheme.outline,
    };

/// Mutable drawing state shared by the widget and its painter. The painter
/// reads it live, which keeps per-frame work off the widget rebuild path.
class _MeshScene {
  final Map<String, _NodeVisual> nodes = <String, _NodeVisual>{};
  final Map<String, _LinkVisual> links = <String, _LinkVisual>{};
  final List<_Packet> packets = <_Packet>[];
  final Map<String, double> flashes = <String, double>{};

  double time = 0;
  double localRadius = 38;
  double peerRadius = 28;

  double radiusOf(_NodeVisual visual) =>
      (visual.node.isLocal ? localRadius : peerRadius) *
      (0.6 + 0.4 * visual.appearance);
}

class _NodeVisual {
  _NodeVisual({required this.node, required this.position});

  TopologyNode node;
  Offset position;
  double appearance = 0;
  bool removed = false;
}

class _LinkVisual {
  _LinkVisual({
    required this.id,
    required this.sourceId,
    required this.targetId,
    required this.state,
  });

  final String id;
  final String sourceId;
  final String targetId;
  TopologyLinkState state;
  double appearance = 0;
  bool removed = false;
}

class _Packet {
  _Packet({
    required this.sourceId,
    required this.targetId,
    this.relayed = false,
  });

  static const travelSeconds = 1.3;

  final String sourceId;
  final String targetId;
  final bool relayed;
  double progress = 0;
}

class _MeshNetworkPainter extends CustomPainter {
  _MeshNetworkPainter({
    required this.scene,
    required this.scale,
    required this.offset,
    required this.scheme,
    required this.textScaler,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final _MeshScene scene;
  final double scale;
  final Offset offset;
  final ColorScheme scheme;
  final TextScaler textScaler;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.scale(scale);
    _paintLinks(canvas);
    _paintPackets(canvas);
    _paintNodes(canvas);
    canvas.restore();
    _paintLabels(canvas, size);
  }

  Color _phaseColor(TopologyNode node) => meshPhaseColor(node.phase, scheme);

  void _paintLinks(Canvas canvas) {
    for (final link in scene.links.values) {
      final from = scene.nodes[link.sourceId];
      final to = scene.nodes[link.targetId];
      if (from == null || to == null) continue;
      final alpha =
          math.min(from.appearance, to.appearance) * link.appearance;
      if (alpha <= 0.02) continue;
      final start = from.position;
      final end = to.position;

      switch (link.state) {
        case TopologyLinkState.up:
          final color = meshPhaseColor(TopologyNodePhase.connected, scheme)
              .withValues(alpha: 0.5 * alpha);
          canvas.drawLine(
            start,
            end,
            Paint()
              ..color = color
              ..strokeWidth = 2
              ..strokeCap = StrokeCap.round,
          );
          _paintFlow(canvas, start, end, alpha);
        case TopologyLinkState.forming:
          _paintDashed(
            canvas,
            start,
            end,
            Paint()
              ..color = scheme.tertiary.withValues(alpha: 0.45 * alpha)
              ..strokeWidth = 1.6,
            dash: 7,
            gap: 5,
          );
        case TopologyLinkState.observed:
          _paintDashed(
            canvas,
            start,
            end,
            Paint()
              ..color = scheme.secondary.withValues(alpha: 0.3 * alpha)
              ..strokeWidth = 1.2,
            dash: 2,
            gap: 6,
          );
        case TopologyLinkState.down:
          _paintDashed(
            canvas,
            start,
            end,
            Paint()
              ..color = scheme.outline.withValues(alpha: 0.22 * alpha)
              ..strokeWidth = 1.2,
            dash: 3,
            gap: 5,
          );
      }
    }
  }

  /// Small pulses drifting along a live link; this is decoration, not real
  /// traffic measurement.
  void _paintFlow(Canvas canvas, Offset start, Offset end, double alpha) {
    final delta = end - start;
    final distance = delta.distance;
    if (distance < 1) return;
    final direction = delta / distance;
    final paint = Paint()
      ..color = meshPhaseColor(TopologyNodePhase.connected, scheme)
          .withValues(alpha: 0.85 * alpha)
      ..style = PaintingStyle.fill;
    for (var i = 0; i < 2; i++) {
      final t = ((scene.time * 0.35) + i * 0.5) % 1.0;
      final point = start + direction * (distance * t);
      canvas.drawCircle(point, 1.9, paint);
    }
  }

  void _paintDashed(
    Canvas canvas,
    Offset from,
    Offset to,
    Paint paint, {
    required double dash,
    required double gap,
  }) {
    final delta = to - from;
    final distance = delta.distance;
    if (distance <= 0.01) return;
    final direction = delta / distance;
    var travelled = 0.0;
    while (travelled < distance) {
      final segmentEnd = math.min(travelled + dash, distance);
      canvas.drawLine(
        from + direction * travelled,
        from + direction * segmentEnd,
        paint,
      );
      travelled = segmentEnd + gap;
    }
  }

  void _paintPackets(Canvas canvas) {
    for (final packet in scene.packets) {
      final from = scene.nodes[packet.sourceId];
      final to = scene.nodes[packet.targetId];
      if (from == null || to == null) continue;
      final t = packet.progress.clamp(0.0, 1.0).toDouble();
      final color = packet.relayed ? scheme.tertiary : scheme.primary;
      final head = Offset.lerp(from.position, to.position, t);
      final tail = Offset.lerp(
        from.position,
        to.position,
        math.max(0.0, t - 0.14),
      );
      if (head == null || tail == null) continue;
      canvas.drawLine(
        tail,
        head,
        Paint()
          ..color = color.withValues(alpha: 0.55)
          ..strokeWidth = 2.4
          ..strokeCap = StrokeCap.round,
      );
      canvas.drawCircle(
        head,
        7,
        Paint()..color = color.withValues(alpha: 0.2),
      );
      canvas.drawCircle(head, 2.8, Paint()..color = color);
    }
  }

  void _paintNodes(Canvas canvas) {
    for (final visual in scene.nodes.values) {
      final alpha = visual.appearance;
      if (alpha <= 0.02) continue;
      final node = visual.node;
      final radius = scene.radiusOf(visual);
      final center = visual.position;
      if (radius <= 0.5) continue;
      final color = _phaseColor(node);

      canvas.drawCircle(
        center,
        radius * 1.9,
        Paint()
          ..shader = RadialGradient(
            colors: [
              color.withValues(alpha: 0.3 * alpha),
              color.withValues(alpha: 0),
            ],
          ).createShader(
            Rect.fromCircle(center: center, radius: radius * 1.9),
          ),
      );

      if (node.isLocal) {
        final pulse = 0.5 + 0.5 * math.sin(scene.time * 2.2);
        canvas.drawCircle(
          center,
          radius + 6 + pulse * 7,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4
            ..color = color.withValues(alpha: (0.55 - pulse * 0.35) * alpha),
        );
      }

      final flash = scene.flashes[node.id];
      if (flash != null) {
        canvas.drawCircle(
          center,
          radius + 4 + (1 - flash) * 16,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6
            ..color = scheme.primary.withValues(alpha: flash * 0.7),
        );
      }

      canvas.drawCircle(
        center,
        radius,
        Paint()..color = color.withValues(alpha: 0.92 * alpha),
      );

      final weak = node.phase == TopologyNodePhase.connected &&
          node.signalBars <= 1;
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = weak ? 2.2 : 1.6
          ..color = weak
              ? scheme.error.withValues(alpha: 0.9 * alpha)
              : scheme.surface.withValues(alpha: 0.85 * alpha),
      );

      canvas.drawCircle(
        center,
        radius * 0.3,
        Paint()..color = Colors.white.withValues(alpha: 0.85 * alpha),
      );
    }
  }

  void _paintLabels(Canvas canvas, Size size) {
    for (final visual in scene.nodes.values) {
      if (visual.appearance < 0.35) continue;
      final node = visual.node;
      final screen = offset + visual.position * scale;
      final radius = scene.radiusOf(visual) * scale;
      if (screen.dy < -80 || screen.dy > size.height + 80) continue;
      if (screen.dx < -120 || screen.dx > size.width + 120) continue;

      final label = node.label.length > 16
          ? '${node.label.substring(0, 15)}…'
          : node.label;
      final painter = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: node.isLocal ? scheme.onSurface : scheme.onSurfaceVariant,
            fontSize: 11.5,
            fontWeight: node.isLocal ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
        textScaler: textScaler,
      )..layout(maxWidth: 140);
      final maxLeft = math.max(4.0, size.width - painter.width - 4);
      final left =
          (screen.dx - painter.width / 2).clamp(4.0, maxLeft).toDouble();
      painter.paint(
        canvas,
        Offset(left, screen.dy + radius + 5),
      );
    }
  }

  @override
  bool shouldRepaint(_MeshNetworkPainter oldDelegate) =>
      oldDelegate.scene != scene ||
      oldDelegate.scale != scale ||
      oldDelegate.offset != offset ||
      oldDelegate.scheme != scheme;
}
