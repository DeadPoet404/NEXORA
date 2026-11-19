import 'dart:async';
import 'dart:math';

import 'topology.dart';
import 'topology_source.dart';

/// **Development-only** fabricated mesh network.
///
/// It exercises every visual state — peers joining and leaving, links forming
/// and breaking, weak signals and message hops — without any Bluetooth
/// activity. Nothing here talks to the transport, router or store, and no
/// snapshot it publishes is evidence of real device-to-device connectivity.
///
/// The class lives under `lib/visualization/` on purpose: it is a display
/// fixture, not a protocol implementation, and it is never used in release
/// builds (see `topology_providers.dart`).
class SimulatedMeshTopologySource implements MeshTopologySource {
  SimulatedMeshTopologySource({
    int seed = 11,
    this.interval = const Duration(milliseconds: 1500),
    this.autoAdvance = true,
    this.maxPeers = 6,
    List<String> peerNames = defaultPeerNames,
  })  : _random = Random(seed),
        _names = List<String>.of(peerNames) {
    _seedNetwork();
    _current = _build(_revision);
    if (autoAdvance) {
      _timer = Timer.periodic(interval, (_) => step());
    }
  }

  /// Node ID used for the simulated local device.
  static const localNodeId = 'sim-local';

  static const localLabel = 'This device (simulated)';

  static const defaultPeerNames = <String>[
    'Ama',
    'Kofi',
    'Esi',
    'Yaw',
    'Adjoa',
    'Kwame',
    'Akosua',
    'Kojo',
  ];

  final Duration interval;
  final bool autoAdvance;
  final int maxPeers;
  final Random _random;
  final List<String> _names;

  final _controller = StreamController<MeshTopologySnapshot>.broadcast();
  final _activity = StreamController<TopologyTransmission>.broadcast();
  final List<_SimPeer> _peers = <_SimPeer>[];
  final List<_SimLink> _relayLinks = <_SimLink>[];

  Timer? _timer;
  int _revision = 0;
  int _peerSeq = 0;
  int _nameCursor = 0;
  int _hopSeq = 0;
  bool _disposed = false;
  MeshTopologySnapshot _current = const MeshTopologySnapshot.empty();

  @override
  bool get isSimulated => true;

  @override
  MeshTopologySnapshot get current => _current;

  @override
  Stream<MeshTopologySnapshot> get changes => _controller.stream;

  @override
  Stream<TopologyTransmission> get activity => _activity.stream;

  /// Advances the simulation by one tick and publishes the result.
  ///
  /// Tests call this directly so they never depend on wall-clock timers.
  void step() {
    if (_disposed) return;
    _mutateTopology();
    _current = _build(++_revision);
    if (!_controller.isClosed) _controller.add(_current);
    // Hops are published separately so they never rewrite the topology.
    for (final hop in _pickHops()) {
      if (_activity.isClosed) return;
      _activity.add(hop);
    }
  }

  void _seedNetwork() {
    _addPeer(TopologyNodePhase.connected, bars: 4);
    _addPeer(TopologyNodePhase.connected, bars: 2);
    _addPeer(TopologyNodePhase.discovering);
    _relayLinks.add(_SimLink(_peers[0].id, _peers[1].id));
  }

  void _addPeer(TopologyNodePhase phase, {int bars = 0}) {
    _peers.add(_SimPeer(
      id: 'sim-peer-${++_peerSeq}',
      name: _names[_nameCursor++ % _names.length],
      phase: phase,
      bars: bars,
    ));
  }

  void _mutateTopology() {
    // Peers move between link states, so the picture is never static.
    for (final peer in _peers) {
      if (_random.nextDouble() < 0.22) {
        peer.phase = _nextPhase(peer.phase);
        peer.bars = peer.phase == TopologyNodePhase.connected
            ? 1 + _random.nextInt(4)
            : 0;
      }
    }

    // A new device comes into range.
    if (_peers.length < maxPeers && _random.nextDouble() < 0.3) {
      _addPeer(
        _random.nextBool()
            ? TopologyNodePhase.connected
            : TopologyNodePhase.discovering,
        bars: _random.nextInt(5),
      );
    }

    // A device leaves, or is dropped as stale.
    if (_peers.length > 1 && _random.nextDouble() < 0.16) {
      final removed = _peers.removeAt(_random.nextInt(_peers.length));
      _relayLinks.removeWhere((link) => link.touches(removed.id));
    }

    // Peer-to-peer relay links appear and disappear too. Real BLE links are
    // only local↔peer, so this deliberately shows more than the device can
    // observe; the screen is labelled accordingly.
    if (_peers.length >= 2 && _random.nextDouble() < 0.26) {
      final a = _peers[_random.nextInt(_peers.length)];
      final b = _peers[_random.nextInt(_peers.length)];
      if (a != b && !_relayLinks.any((link) => link.connects(a.id, b.id))) {
        _relayLinks.add(_SimLink(a.id, b.id));
      }
    } else if (_relayLinks.isNotEmpty && _random.nextDouble() < 0.2) {
      _relayLinks.removeAt(_random.nextInt(_relayLinks.length));
    }
  }

  TopologyNodePhase _nextPhase(TopologyNodePhase phase) => switch (phase) {
        TopologyNodePhase.local => TopologyNodePhase.local,
        TopologyNodePhase.connected => _random.nextBool()
            ? TopologyNodePhase.discovering
            : TopologyNodePhase.connecting,
        TopologyNodePhase.connecting => _random.nextDouble() < 0.65
            ? TopologyNodePhase.connected
            : TopologyNodePhase.unavailable,
        TopologyNodePhase.discovering => _random.nextDouble() < 0.6
            ? TopologyNodePhase.connecting
            : TopologyNodePhase.unavailable,
        TopologyNodePhase.unavailable => _random.nextDouble() < 0.5
            ? TopologyNodePhase.discovering
            : TopologyNodePhase.unavailable,
      };

  List<TopologyTransmission> _pickHops() {
    final usable = <TopologyLink>[
      for (final link in _composeLinks())
        if (link.state == TopologyLinkState.up) link,
    ];
    if (usable.isEmpty || _random.nextDouble() < 0.3) {
      return const <TopologyTransmission>[];
    }
    final link = usable[_random.nextInt(usable.length)];
    final reversed = _random.nextBool();
    return <TopologyTransmission>[
      TopologyTransmission(
        id: 'sim-hop-${++_hopSeq}',
        sourceId: reversed ? link.targetId : link.sourceId,
        targetId: reversed ? link.sourceId : link.targetId,
        relayed: !link.touches(localNodeId),
      ),
    ];
  }

  List<TopologyLink> _composeLinks() {
    final links = <TopologyLink>[
      for (final peer in _peers)
        TopologyLink(
          sourceId: localNodeId,
          targetId: peer.id,
          state: _linkState(peer.phase),
        ),
    ];
    for (final relay in _relayLinks) {
      final from = _peer(relay.a);
      final to = _peer(relay.b);
      if (from == null || to == null) continue;
      final bothConnected = from.phase == TopologyNodePhase.connected &&
          to.phase == TopologyNodePhase.connected;
      links.add(TopologyLink(
        sourceId: from.id,
        targetId: to.id,
        state: bothConnected ? TopologyLinkState.up : TopologyLinkState.down,
      ));
    }
    return links;
  }

  MeshTopologySnapshot _build(int revision) {
    final nodes = <TopologyNode>[
      const TopologyNode(
        id: localNodeId,
        label: localLabel,
        phase: TopologyNodePhase.local,
        signalBars: 4,
      ),
      for (final peer in _peers)
        TopologyNode(
          id: peer.id,
          label: peer.name,
          phase: peer.phase,
          signalBars: peer.bars,
        ),
    ];
    return MeshTopologySnapshot(
      localNodeId: localNodeId,
      nodes: List<TopologyNode>.unmodifiable(nodes),
      links: List<TopologyLink>.unmodifiable(_composeLinks()),
      revision: revision,
      simulated: true,
    );
  }

  TopologyLinkState _linkState(TopologyNodePhase phase) => switch (phase) {
        TopologyNodePhase.connected => TopologyLinkState.up,
        TopologyNodePhase.connecting => TopologyLinkState.forming,
        TopologyNodePhase.discovering => TopologyLinkState.observed,
        TopologyNodePhase.unavailable => TopologyLinkState.down,
        TopologyNodePhase.local => TopologyLinkState.up,
      };

  _SimPeer? _peer(String id) {
    for (final peer in _peers) {
      if (peer.id == id) return peer;
    }
    return null;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    await _controller.close();
    await _activity.close();
  }
}

class _SimPeer {
  _SimPeer({
    required this.id,
    required this.name,
    required this.phase,
    required this.bars,
  });

  final String id;
  final String name;
  TopologyNodePhase phase;
  int bars;
}

class _SimLink {
  _SimLink(this.a, this.b);

  final String a;
  final String b;

  bool touches(String id) => a == id || b == id;

  bool connects(String left, String right) =>
      (a == left && b == right) || (a == right && b == left);
}
