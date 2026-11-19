import 'dart:async';

import '../mesh/transport.dart';
import '../models/peer.dart';
import 'topology.dart';

/// Where the visualization gets its topology from.
///
/// Implementations are the only coupling point between the view and the app:
/// [LiveMeshTopologySource] reads real BLE discovery state, and
/// [SimulatedMeshTopologySource] (development only) fabricates a network. The
/// view itself never learns which one it was given, except through
/// [isSimulated] so it can label the screen honestly.
abstract class MeshTopologySource {
  /// True for development-only fabricated data.
  bool get isSimulated;

  /// Latest snapshot; valid immediately after construction.
  MeshTopologySnapshot get current;

  /// Broadcast stream of later snapshots.
  Stream<MeshTopologySnapshot> get changes;

  /// Stops timers and stream subscriptions.
  Future<void> dispose();
}

/// Topology built from the real transport's peer discovery.
///
/// This source does not start scanning, send anything, or change any peer's
/// state: it is a read-only projection of [MeshTransport.peers].
class LiveMeshTopologySource implements MeshTopologySource {
  LiveMeshTopologySource({
    required MeshTransport transport,
    required this.localNodeId,
    this.localName = 'This device',
    Stream<String>? incomingSenderIds,
  })  : _transport = transport,
        _incomingSenderIds = incomingSenderIds {
    _current = _project(transport.peers, const <TopologyTransmission>[]);
    _peerSub = transport.peerChanges.listen(
      (peers) => _publish(peers, const <TopologyTransmission>[]),
      onError: _emitError,
    );
    _activitySub = incomingSenderIds?.listen(
      _onIncomingHop,
      onError: _emitError,
    );
  }

  final MeshTransport _transport;
  final String localNodeId;
  final String localName;

  /// Sender IDs of messages that just arrived, used only to animate a hop.
  final Stream<String>? _incomingSenderIds;

  final _controller = StreamController<MeshTopologySnapshot>.broadcast();
  StreamSubscription<List<Peer>>? _peerSub;
  StreamSubscription<String>? _activitySub;

  MeshTopologySnapshot _current = const MeshTopologySnapshot.empty();
  List<Peer> _peers = const <Peer>[];
  int _revision = 0;
  int _hopSeq = 0;
  bool _disposed = false;

  @override
  bool get isSimulated => false;

  @override
  MeshTopologySnapshot get current => _current;

  @override
  Stream<MeshTopologySnapshot> get changes => _controller.stream;

  MeshTopologySnapshot _project(
    List<Peer> peers,
    List<TopologyTransmission> transmissions,
  ) =>
      topologyFromPeers(
        localNodeId: localNodeId,
        localName: localName,
        peers: peers,
        revision: ++_revision,
        transmissions: transmissions,
      );

  void _publish(List<Peer> peers, List<TopologyTransmission> transmissions) {
    if (_disposed) return;
    _peers = peers;
    _current = _project(peers, transmissions);
    if (!_controller.isClosed) _controller.add(_current);
  }

  /// Animates a hop when a message arrives from a known neighbour.
  ///
  /// The hop is drawn from that neighbour to this device. Messages that
  /// travelled through relays are attributed to the last neighbour seen, which
  /// is all the local stack can observe.
  void _onIncomingHop(String senderId) {
    if (_disposed || senderId.isEmpty || senderId == localNodeId) return;
    final known = _current.nodeById(senderId);
    if (known == null) return;
    final hop = TopologyTransmission(
      id: 'hop-${++_hopSeq}',
      sourceId: senderId,
      targetId: localNodeId,
    );
    _current = _project(_peers, <TopologyTransmission>[hop]);
    if (!_controller.isClosed) _controller.add(_current);
  }

  void _emitError(Object error, StackTrace stackTrace) {
    if (_disposed || _controller.isClosed) return;
    _controller.addError(error, stackTrace);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _peerSub?.cancel();
    await _activitySub?.cancel();
    _peerSub = null;
    _activitySub = null;
    await _controller.close();
  }

  /// Current transport state, for callers that want to explain an empty view.
  TransportStatus get transportStatus => _transport.status;
}
