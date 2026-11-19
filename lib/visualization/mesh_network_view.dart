import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'mesh_layout.dart';
import 'mesh_style.dart';
import 'topology.dart';
import 'topology_source.dart';

/// Dark, animated view of the mesh network.
///
/// Positions come from [MeshLayout] (deterministic rings, computed only when the
/// topology or canvas size changes). Everything that moves is a short, bounded
/// transition or a decoration with a fixed cycle: no force simulation runs here.
///
/// The widget is driven only by a [MeshTopologySource], so it has no knowledge
/// of BLE, routing or storage, and simulated data is labelled on screen.
class MeshNetworkView extends StatefulWidget {
  const MeshNetworkView({
    super.key,
    required this.source,
    this.localDiameter = 84,
    this.peerDiameter = 44,
  });

  final MeshTopologySource source;

  /// Diameter of this device's node, in canvas pixels.
  final double localDiameter;

  /// Diameter of a peer node, in canvas pixels.
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

  Ticker? _ticker;
  StreamSubscription<MeshTopologySnapshot>? _sub;
  StreamSubscription<TopologyTransmission>? _activitySub;

  Duration _lastElapsed = Duration.zero;
  MeshTopologySnapshot _topology = const MeshTopologySnapshot.empty();
  Size _viewport = Size.zero;

  double _scale = 1;
  Offset _offset = Offset.zero;
  double _startScale = 1;
  Offset _startWorldFocal = Offset.zero;

  @override
  void initState() {
    super.initState();
    _topology = widget.source.current;
    _layout.update(_topology);
    _syncScene();
    _ticker = createTicker(_onTick);
    _listen(widget.source);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduce != _scene.reducedMotion) {
      _scene.reducedMotion = reduce;
      _frame.value = _scene.time;
    }
    _ensureTicking();
  }

  @override
  void didUpdateWidget(MeshNetworkView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.source, widget.source)) return;
    _sub?.cancel();
    _activitySub?.cancel();
    _scene.nodes.clear();
    _scene.links.clear();
    _scene.particles.clear();
    _scene.linkFlashes.clear();
    _scene.nodeFlashes.clear();
    _listen(widget.source);
    // didUpdateWidget is always followed by build(), so assignment is enough.
    _topology = widget.source.current;
    if (!_viewport.isEmpty) _layout.update(_topology, viewport: _viewport);
    _syncScene();
  }

  void _listen(MeshTopologySource source) {
    _sub = source.changes.listen(_onSnapshot, onError: _onSourceError);
    // Hops arrive on their own stream and never trigger a rebuild or relayout.
    _activitySub = source.activity.listen(_spawnHop, onError: _onSourceError);
  }

  void _onSourceError(Object error, StackTrace stackTrace) {
    // A transport error just means no new topology; the last snapshot stands.
  }

  @override
  void dispose() {
    _sub?.cancel();
    _sub = null;
    _activitySub?.cancel();
    _activitySub = null;
    _ticker?.stop();
    _ticker?.dispose();
    _ticker = null;
    _frame.dispose();
    super.dispose();
  }

  void _onSnapshot(MeshTopologySnapshot snapshot) {
    if (!mounted) return;
    _layout.update(snapshot, viewport: _viewport);
    setState(() {
      _topology = snapshot;
      _syncScene();
    });
  }

  /// Reconciles the animated scene with [_topology]. New nodes fade and scale
  /// in (staggered on first paint); missing ones fade out and are then dropped.
  void _syncScene() {
    final nodeIds = <String>{};
    var nodeOrder = 0;
    for (final node in _topology.nodes) {
      nodeIds.add(node.id);
      final existing = _scene.nodes[node.id];
      if (existing == null) {
        _scene.nodes[node.id] = _NodeVisual(
          node: node,
          position: _layout.centerOf(node.id) ?? _viewportCenter,
          enterAt: _scene.time + nodeOrder * 0.07,
          phaseSeed: _seedFor(node.id),
        );
      } else {
        existing.node = node;
        existing.removed = false;
        existing.leaveAt = 0;
        existing.leaveFrom = 1;
      }
      nodeOrder++;
    }
    for (final visual in _scene.nodes.values) {
      if (nodeIds.contains(visual.node.id) || visual.removed) continue;
      visual.removed = true;
      visual.leaveAt = _scene.time;
      visual.leaveFrom = visual.appearance;
    }

    final linkIds = <String>{};
    var linkOrder = 0;
    for (final link in _topology.links) {
      linkIds.add(link.id);
      final existing = _scene.links[link.id];
      if (existing == null) {
        _scene.links[link.id] = _LinkVisual(
          id: link.id,
          sourceId: link.sourceId,
          targetId: link.targetId,
          state: link.state,
          enterAt: _scene.time + 0.08 + linkOrder * 0.05,
        );
      } else {
        existing.state = link.state;
        existing.removed = false;
        existing.leaveAt = 0;
        existing.leaveFrom = 1;
      }
      linkOrder++;
    }
    for (final visual in _scene.links.values) {
      if (linkIds.contains(visual.id) || visual.removed) continue;
      visual.removed = true;
      visual.leaveAt = _scene.time;
      visual.leaveFrom = visual.appearance;
    }

    _ensureTicking();
  }

  /// Places existing nodes exactly on their layout targets.
  void _snapToLayout() {
    for (final entry in _scene.nodes.entries) {
      final target = _layout.centerOf(entry.key);
      if (target != null) entry.value.position = target;
    }
  }

  /// Turns a real hop event into a particle travelling from its sender to its
  /// receiver along the link that already exists, and briefly brightens that
  /// link. Live hops always run peer -> this device. Nothing is fabricated: if
  /// either endpoint or the link is not on screen, no animation is drawn.
  void _spawnHop(TopologyTransmission hop) {
    final from = _scene.nodes[hop.sourceId];
    final to = _scene.nodes[hop.targetId];
    if (from == null || to == null) return;
    final linkId = TopologyLink.linkIdBetween(hop.sourceId, hop.targetId);
    if (!_scene.links.containsKey(linkId)) return;

    final distance = (from.position - to.position).distance;
    final duration = _clamp(distance / 180, 0.7, 1.2);
    if (!_scene.reducedMotion) {
      if (_scene.particles.length >= 12) _scene.particles.removeAt(0);
      _scene.particles.add(_Particle(
        fromId: hop.sourceId,
        toId: hop.targetId,
        startAt: _scene.time,
        duration: duration,
        relayed: hop.relayed,
      ));
    }
    _scene.linkFlashes[linkId] = 1;
    _scene.nodeFlashes[hop.targetId] = 1;
    _ensureTicking();
    _frame.value = _scene.time;
  }

  Offset get _viewportCenter => _viewport.isEmpty
      ? const Offset(180, 220)
      : Offset(_viewport.width / 2, _viewport.height / 2);

  void _ensureTicking() {
    final ticker = _ticker;
    if (ticker == null || ticker.isActive) return;
    if (_scene.reducedMotion && !_hasTransientWork) return;
    _lastElapsed = Duration.zero;
    ticker.start();
  }

  void _stopTicker() {
    _ticker?.stop();
    _lastElapsed = Duration.zero;
  }

  /// True while something must animate: fades, position transitions, particles
  /// or flashes. When this is false and motion is reduced, the ticker stops.
  bool _hasTransientWork {
    for (final visual in _scene.nodes.values) {
      if (visual.appearance < 1 || visual.removed) return true;
      final target = _layout.centerOf(visual.node.id);
      if (target != null && (target - visual.position).distance > 0.4) {
        return true;
      }
    }
    for (final visual in _scene.links.values) {
      if (visual.appearance < 1 || visual.removed) return true;
    }
    return _scene.particles.isNotEmpty ||
        _scene.linkFlashes.isNotEmpty ||
        _scene.nodeFlashes.isNotEmpty;
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastElapsed).inMicroseconds / 1000000.0;
    _lastElapsed = elapsed;
    if (dt <= 0) return;
    // Clamp after a stall so nothing teleports.
    final step = math.min(dt, 0.05);
    _scene.time += step;
    final moveFactor = 1 - math.exp(-step * 10);

    for (final entry in _scene.nodes.entries.toList()) {
      final visual = entry.value;
      if (visual.removed) {
        final leftFor = _scene.time - visual.leaveAt;
        visual.appearance =
            _clamp(visual.leaveFrom * (1 - leftFor / 0.28), 0, 1);
        if (visual.appearance <= 0.01) {
          _scene.nodes.remove(entry.key);
          continue;
        }
      } else {
        final target = _layout.centerOf(entry.key);
        if (target != null) {
          final delta = target - visual.position;
          visual.position = delta.distance <= 0.4
              ? target
              : visual.position + delta * moveFactor;
        }
        final enteredFor = _scene.time - visual.enterAt;
        visual.appearance = enteredFor <= 0
            ? 0
            : _clamp(enteredFor / 0.42, 0, 1);
      }
    }

    for (final entry in _scene.links.entries.toList()) {
      final visual = entry.value;
      if (visual.removed) {
        final leftFor = _scene.time - visual.leaveAt;
        visual.appearance =
            _clamp(visual.leaveFrom * (1 - leftFor / 0.26), 0, 1);
        if (visual.appearance <= 0.01) _scene.links.remove(entry.key);
      } else {
        visual.appearance =
            _clamp((_scene.time - visual.enterAt) / 0.36, 0, 1);
      }
    }

    for (final particle in List<_Particle>.of(_scene.particles)) {
      if (_scene.time - particle.startAt >= particle.duration) {
        _scene.particles.remove(particle);
        _scene.nodeFlashes[particle.toId] = 1;
      }
    }

    for (final entry in _scene.linkFlashes.entries.toList()) {
      final next = entry.value - step * 2.4;
      if (next <= 0) {
        _scene.linkFlashes.remove(entry.key);
      } else {
        _scene.linkFlashes[entry.key] = next;
      }
    }
    for (final entry in _scene.nodeFlashes.entries.toList()) {
      final next = entry.value - step * 1.8;
      if (next <= 0) {
        _scene.nodeFlashes.remove(entry.key);
      } else {
        _scene.nodeFlashes[entry.key] = next;
      }
    }

    _frame.value = _scene.time;
    if (_scene.reducedMotion && !_hasTransientWork) _stopTicker();
  }

  void _onScaleStart(ScaleStartDetails details) {
    _startScale = _scale;
    _startWorldFocal = (details.localFocalPoint - _offset) / _scale;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final nextScale = _clamp(_startScale * details.scale, 0.6, 2.4);
    setState(() {
      _scale = nextScale;
      _offset = details.localFocalPoint - _startWorldFocal * nextScale;
    });
  }

  void _zoomBy(double factor) {
    final focal = _viewportCenter;
    final world = (focal - _offset) / _scale;
    final nextScale = _clamp(_scale * factor, 0.6, 2.4);
    setState(() {
      _scale = nextScale;
      _offset = focal - world * nextScale;
    });
  }

  void _resetView() {
    setState(() {
      _scale = 1;
      _offset = Offset.zero;
    });
  }

  @override
  Widget build(BuildContext context) {
    final simulated = widget.source.isSimulated || _topology.simulated;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        if (size != _viewport) {
          final firstMeasure = _viewport.isEmpty;
          _viewport = size;
          _layout.update(_topology, viewport: size);
          _syncScene();
          // Nothing has animated yet on the first measure: start from the final
          // positions instead of gliding in from the placeholder canvas size.
          if (firstMeasure && _scene.time == 0) _snapToLayout();
        }
        return Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _BackdropPainter(),
                size: Size.infinite,
              ),
            ),
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onScaleStart: _onScaleStart,
                onScaleUpdate: _onScaleUpdate,
                child: CustomPaint(
                  painter: _MeshNetworkPainter(
                    scene: _scene,
                    layout: _layout,
                    scale: _scale,
                    offset: _offset,
                    textScaler: MediaQuery.textScalerOf(context),
                    repaint: _frame,
                  ),
                  size: Size.infinite,
                ),
              ),
            ),
            if (simulated)
              const Positioned(top: 10, left: 10, child: _SimulatedPill()),
            Positioned(
              top: 10,
              right: 10,
              child: Column(
                children: [
                  _CanvasButton(
                    icon: Icons.add,
                    tooltip: 'Zoom in',
                    onPressed: () => _zoomBy(1.25),
                  ),
                  const SizedBox(height: 6),
                  _CanvasButton(
                    icon: Icons.remove,
                    tooltip: 'Zoom out',
                    onPressed: () => _zoomBy(0.8),
                  ),
                  const SizedBox(height: 6),
                  _CanvasButton(
                    icon: Icons.center_focus_strong,
                    tooltip: 'Reset view',
                    onPressed: _resetView,
                  ),
                ],
              ),
            ),
            Positioned(
              left: 12,
              bottom: 10,
              child: _StatusChip(
                label: '${_topology.nodes.length} nodes · '
                    '${_topology.activeLinkCount} links',
              ),
            ),
          ],
        );
      },
    );
  }
}

double _clamp(double value, double min, double max) =>
    value < min ? min : (value > max ? max : value);

/// Stable 0–1 value per node so pulses are offset instead of marching in step.
double _seedFor(String id) => (id.hashCode % 997) / 997;

class _SimulatedPill extends StatelessWidget {
  const _SimulatedPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: MeshPalette.warn.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: MeshPalette.warn.withValues(alpha: 0.34)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: const BoxDecoration(
              color: MeshPalette.warn,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          const Text(
            'SIMULATED NETWORK',
            style: TextStyle(
              fontSize: 9,
              letterSpacing: 1.1,
              fontWeight: FontWeight.w700,
              color: MeshPalette.warn,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: MeshPalette.surface.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: MeshPalette.hairline),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 10, color: MeshPalette.textSecondary),
      ),
    );
  }
}

class _CanvasButton extends StatelessWidget {
  const _CanvasButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: MeshPalette.surface.withValues(alpha: 0.70),
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          borderRadius: BorderRadius.circular(11),
          onTap: onPressed,
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: MeshPalette.hairline),
            ),
            child: Icon(icon, size: 17, color: MeshPalette.textSecondary),
          ),
        ),
      ),
    );
  }
}

/// Canvas fill: flat dark base, one restrained ambient gradient and a very
/// faint dot grid. Painted once per size change, not per animation frame.
class _BackdropPainter extends CustomPainter {

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = MeshPalette.canvas);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0, -0.45),
          radius: 1.1,
          colors: [
            MeshPalette.accent.withValues(alpha: 0.05),
            MeshPalette.accent.withValues(alpha: 0),
          ],
        ).createShader(rect),
    );

    const step = 34.0;
    final dot = Paint()..color = MeshPalette.gridDot;
    for (var y = step / 2; y < size.height; y += step) {
      for (var x = step / 2; x < size.width; x += step) {
        canvas.drawCircle(Offset(x, y), 0.9, dot);
      }
    }
  }

  @override
  bool shouldRepaint(_BackdropPainter oldDelegate) => false;
}

/// Mutable drawing state shared by the widget and its painter. The painter
/// reads it live, so per-frame work never rebuilds widgets or the topology.
class _MeshScene {
  final Map<String, _NodeVisual> nodes = <String, _NodeVisual>{};
  final Map<String, _LinkVisual> links = <String, _LinkVisual>{};
  final List<_Particle> particles = <_Particle>[];
  final Map<String, double> linkFlashes = <String, double>{};
  final Map<String, double> nodeFlashes = <String, double>{};

  double time = 0;
  bool reducedMotion = false;
}

class _NodeVisual {
  _NodeVisual({
    required this.node,
    required this.position,
    required this.enterAt,
    required this.phaseSeed,
  });

  TopologyNode node;
  Offset position;
  final double enterAt;
  final double phaseSeed;
  double appearance = 0;
  bool removed = false;
  double leaveAt = 0;
  double leaveFrom = 1;
}

class _LinkVisual {
  _LinkVisual({
    required this.id,
    required this.sourceId,
    required this.targetId,
    required this.state,
    required this.enterAt,
  });

  final String id;
  final String sourceId;
  final String targetId;
  TopologyLinkState state;
  final double enterAt;
  double appearance = 0;
  bool removed = false;
  double leaveAt = 0;
  double leaveFrom = 1;
}

class _Particle {
  _Particle({
    required this.fromId,
    required this.toId,
    required this.startAt,
    required this.duration,
    required this.relayed,
  });

  final String fromId;
  final String toId;
  final double startAt;
  final double duration;
  final bool relayed;
}

class _MeshNetworkPainter extends CustomPainter {
  _MeshNetworkPainter({
    required this.scene,
    required this.layout,
    required this.scale,
    required this.offset,
    required this.textScaler,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final _MeshScene scene;
  final MeshLayout layout;
  final double scale;
  final Offset offset;
  final TextScaler textScaler;

  /// Decorative motion is frozen when the platform asks for reduced motion.
  double get _t => scene.reducedMotion ? 0.0 : scene.time;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.scale(scale);
    _paintLinks(canvas);
    _paintParticles(canvas);
    _paintNodes(canvas);
    canvas.restore();
    _paintLabels(canvas, size);
  }

  void _paintLinks(Canvas canvas) {
    for (final link in scene.links.values) {
      final from = scene.nodes[link.sourceId];
      final to = scene.nodes[link.targetId];
      if (from == null || to == null) continue;
      final alpha = math.min(from.appearance, to.appearance) * link.appearance;
      if (alpha <= 0.02) continue;
      final start = from.position;
      final end = to.position;
      final flash = scene.linkFlashes[link.id] ?? 0;

      final (color, baseAlpha, width) = switch (link.state) {
        TopologyLinkState.up => (MeshPalette.accent, 0.30, 1.25),
        TopologyLinkState.forming => (MeshPalette.connecting, 0.26, 1.0),
        TopologyLinkState.observed => (MeshPalette.discovering, 0.15, 1.0),
        TopologyLinkState.down => (MeshPalette.unavailable, 0.13, 1.0),
      };
      final lineAlpha = _clamp(baseAlpha * alpha * (1 + flash * 1.5), 0, 1);
      final stroke = Paint()
        ..color = color.withValues(alpha: lineAlpha)
        ..strokeWidth = width + flash * 1.4
        ..strokeCap = StrokeCap.round;

      if (link.state == TopologyLinkState.up) {
        canvas.drawLine(start, end, stroke);
        // Restrained halo so live links read as illuminated, not neon.
        canvas.drawLine(
          start,
          end,
          Paint()
            ..color = color.withValues(
              alpha: _clamp(0.05 * alpha + flash * 0.10, 0, 1),
            )
            ..strokeWidth = 4.5
            ..strokeCap = StrokeCap.round,
        );
      } else {
        _paintDashed(canvas, start, end, stroke,
            dash: link.state == TopologyLinkState.forming ? 7 : 2.5,
            gap: link.state == TopologyLinkState.forming ? 6 : 6);
      }
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

  /// A particle for each real hop, travelling from sender to receiver.
  void _paintParticles(Canvas canvas) {
    for (final particle in scene.particles) {
      final from = scene.nodes[particle.fromId];
      final to = scene.nodes[particle.toId];
      if (from == null || to == null) continue;
      final progress =
          _clamp((scene.time - particle.startAt) / particle.duration, 0, 1);
      if (progress <= 0 || progress >= 1) continue;
      final head = Offset.lerp(from.position, to.position, progress);
      final tail = Offset.lerp(
        from.position,
        to.position,
        math.max(0.0, progress - 0.12),
      );
      if (head == null || tail == null) continue;
      // Fade in quickly and out at the end so nothing is left behind.
      final fade = math.min(1.0, math.min(progress * 8, (1 - progress) * 8));
      final color =
          particle.relayed ? MeshPalette.accentSecondary : MeshPalette.accent;
      canvas.drawLine(
        tail,
        head,
        Paint()
          ..color = color.withValues(alpha: 0.45 * fade)
          ..strokeWidth = 2.2
          ..strokeCap = StrokeCap.round,
      );
      canvas.drawCircle(
        head,
        8,
        Paint()..color = color.withValues(alpha: 0.12 * fade),
      );
      canvas.drawCircle(
        head,
        3,
        Paint()..color = color.withValues(alpha: fade),
      );
    }
  }

  void _paintNodes(Canvas canvas) {
    for (final visual in scene.nodes.values) {
      final alpha = visual.appearance;
      if (alpha <= 0.02) continue;
      final node = visual.node;
      final baseRadius = layout.radiusFor(node);
      // Gentle 0.85 → 1.0 scale-in on arrival.
      final radius = baseRadius * (0.85 + 0.15 * alpha);
      if (node.isLocal) {
        _paintLocalNode(canvas, visual, radius, alpha);
      } else {
        _paintPeerNode(canvas, visual, radius, alpha);
      }
    }
  }

  void _paintLocalNode(
    Canvas canvas,
    _NodeVisual visual,
    double radius,
    double alpha,
  ) {
    final center = visual.position;
    const color = MeshPalette.accent;
    final breathe = 0.5 + 0.5 * math.sin(2 * math.pi * _t / 2.8);

    canvas.drawCircle(
      center,
      radius * 2.6,
      Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: 0.22 * alpha),
            color.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: radius * 2.6)),
    );

    // Slow breathing ring (≈2.8 s cycle).
    canvas.drawCircle(
      center,
      radius + 9 + breathe * 6,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = color.withValues(alpha: (0.30 - breathe * 0.16) * alpha),
    );
    canvas.drawCircle(
      center,
      radius + 3,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = MeshPalette.hairline.withValues(alpha: 0.9 * alpha),
    );

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0xFF12403D), Color(0xFF0B1E2B)],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = color.withValues(alpha: 0.85 * alpha),
    );

    // Inner device indicator.
    canvas.drawCircle(
      center,
      radius * 0.44,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = color.withValues(alpha: 0.45 * alpha),
    );
    canvas.drawCircle(
      center,
      radius * 0.17,
      Paint()..color = color.withValues(alpha: 0.95 * alpha),
    );

    _paintArrivalFlash(canvas, visual, radius, alpha);
  }

  void _paintPeerNode(
    Canvas canvas,
    _NodeVisual visual,
    double radius,
    double alpha,
  ) {
    final node = visual.node;
    final center = visual.position;
    final color = meshPhaseColor(node.phase);
    final weak =
        node.phase == TopologyNodePhase.connected && node.signalBars <= 1;
    final accent = weak ? MeshPalette.warn : color;

    if (node.phase != TopologyNodePhase.unavailable) {
      canvas.drawCircle(
        center,
        radius * 2,
        Paint()
          ..shader = RadialGradient(
            colors: [
              color.withValues(alpha: 0.12 * alpha),
              color.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: center, radius: radius * 2)),
      );
    }

    switch (node.phase) {
      case TopologyNodePhase.connected:
      case TopologyNodePhase.local:
        final pulse =
            0.5 + 0.5 * math.sin(2 * math.pi * _t / 3.2 + visual.phaseSeed * 6.28);
        canvas.drawCircle(
          center,
          radius + 3 + pulse * 2,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.1
            ..color = accent.withValues(alpha: (0.10 + 0.16 * pulse) * alpha),
        );
      case TopologyNodePhase.connecting:
        // Rotating arc: the node itself stays put.
        final sweepStart = 2 * math.pi * _t / 2.4 + visual.phaseSeed * 6.28;
        canvas.drawCircle(
          center,
          radius + 6,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = color.withValues(alpha: 0.12 * alpha),
        );
        canvas.drawArc(
          Rect.fromCircle(center: center, radius: radius + 6),
          sweepStart,
          1.2,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.8
            ..strokeCap = StrokeCap.round
            ..color = color.withValues(alpha: 0.85 * alpha),
        );
      case TopologyNodePhase.discovering:
        _paintDottedRing(
          canvas,
          center,
          radius + 5,
          color.withValues(alpha: 0.28 * alpha),
        );
      case TopologyNodePhase.unavailable:
        _paintDottedRing(
          canvas,
          center,
          radius + 4,
          MeshPalette.unavailable.withValues(alpha: 0.18 * alpha),
        );
    }

    canvas.drawCircle(
      center,
      radius,
      Paint()..color = MeshPalette.nodeFill.withValues(alpha: 0.94 * alpha),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = node.phase == TopologyNodePhase.unavailable ? 1 : 1.4
        ..color = accent.withValues(
          alpha: switch (node.phase) {
            TopologyNodePhase.connected => 0.80,
            TopologyNodePhase.connecting => 0.60,
            TopologyNodePhase.discovering => 0.34,
            TopologyNodePhase.unavailable => 0.26,
            TopologyNodePhase.local => 0.80,
          } *
              alpha,
        ),
    );
    canvas.drawCircle(
      center,
      radius * 0.22,
      Paint()
        ..color = accent.withValues(
          alpha: switch (node.phase) {
            TopologyNodePhase.connected => 0.90,
            TopologyNodePhase.connecting => 0.60,
            TopologyNodePhase.discovering => 0.40,
            TopologyNodePhase.unavailable => 0.30,
            TopologyNodePhase.local => 0.90,
          } *
              alpha,
        ),
    );

    _paintArrivalFlash(canvas, visual, radius, alpha);
  }

  void _paintArrivalFlash(
    Canvas canvas,
    _NodeVisual visual,
    double radius,
    double alpha,
  ) {
    final flash = scene.nodeFlashes[visual.node.id];
    if (flash == null) return;
    canvas.drawCircle(
      visual.position,
      radius + 6 + (1 - flash) * 16,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = MeshPalette.accent.withValues(alpha: 0.5 * flash * alpha),
    );
  }

  void _paintDottedRing(
    Canvas canvas,
    Offset center,
    double radius,
    Color color,
  ) {
    final paint = Paint()..color = color;
    const dots = 10;
    for (var i = 0; i < dots; i++) {
      final angle = 2 * math.pi * i / dots;
      canvas.drawCircle(
        center + Offset(math.cos(angle), math.sin(angle)) * radius,
        1.2,
        paint,
      );
    }
  }

  void _paintLabels(Canvas canvas, Size size) {
    for (final visual in scene.nodes.values) {
      if (visual.appearance < 0.35) continue;
      final node = visual.node;
      final screen = offset + visual.position * scale;
      final radius = layout.radiusFor(node) * scale;
      if (screen.dy < -80 || screen.dy > size.height + 80) continue;
      if (screen.dx < -140 || screen.dx > size.width + 140) continue;

      final label = node.label.length > 18
          ? '${node.label.substring(0, 17)}…'
          : node.label;
      final maxWidth = math.max(44.0, layout.labelWidthFor(node.id) * scale);
      final painter = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: node.isLocal
                ? MeshPalette.textPrimary
                : MeshPalette.textSecondary,
            fontSize: node.isLocal ? 11.5 : 10.5,
            fontWeight: node.isLocal ? FontWeight.w700 : FontWeight.w500,
            letterSpacing: 0.2,
            shadows: const [
              Shadow(color: Color(0xCC060A12), blurRadius: 6),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
        textScaler: textScaler,
      )..layout(maxWidth: maxWidth);
      final maxLeft = math.max(4.0, size.width - painter.width - 4);
      final left =
          (screen.dx - painter.width / 2).clamp(4.0, maxLeft).toDouble();
      painter.paint(canvas, Offset(left, screen.dy + radius + 7));
    }
  }

  @override
  bool shouldRepaint(_MeshNetworkPainter oldDelegate) =>
      oldDelegate.scene != scene ||
      oldDelegate.scale != scale ||
      oldDelegate.offset != offset;
}
