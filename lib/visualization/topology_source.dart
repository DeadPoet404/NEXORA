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

  /// Message hops observed since construction, one event per received frame.
  ///
  /// Activity is deliberately separate from [changes]: a hop never rewrites
  /// [current] or emits a topology snapshot, so every event survives rapid
  /// bursts and message traffic cannot disturb peer discovery.
  Stream<TopologyTransmission> get activity;

  /// Stops timers and stream subscriptions.
  Future<void> dispose();
}

/// Topology built from the real transport's peer discovery.
///
/// This source does not start scanning, send anything, or change any peer's
/// state: it is a read-only projection of [MeshTransport.peers]. Its
/// [activityStreams] are read-only taps too — each event is the sender node ID
/// of a frame that just arrived, and is used only to animate a hop.
class LiveMeshTopologySource implements MeshTopologySource {
  LiveMeshTopologySource({
    required MeshTransport transport,
    required this.localNodeId,
    this.localName = 'This device',
    this.activityStreams = const <Stream<String>>[],
  }) : _transport = transport {
    // Seed from the transport's current peers: without this, the first hop
    // would rebuild the topology from an empty list and drop every peer.
    _peers = transport.peers;
    _current = _project(_peers);
    _peerSub = transport.peerChanges.listen(_publish, onError: _emitError);
    for (final stream in activityStreams) {
      _activitySubs.add(stream.listen(_onIncomingHop, onError: _emitError));
    }
  }

  /// Streams of sender node IDs for frames that just arrived. Each event only
  /// animates a hop; no message content passes through the visualization.
  final List<Stream<String>> activityStreams;

  final MeshTransport _transport;
  final String localNodeId;
  final String localName;

  final _controller = StreamController<MeshTopologySnapshot>.broadcast();
  final _activity = StreamController<TopologyTransmission>.broadcast();
  final _activitySubs = <StreamSubscription<String>>[];
  StreamSubscription<List<Peer>>? _peerSub;

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

  @override
  Stream<TopologyTransmission> get activity => _activity.stream;

  MeshTopologySnapshot _project(List<Peer> peers) => topologyFromPeers(
        localNodeId: localNodeId,
        localName: localName,
        peers: peers,
        revision: ++_revision,
      );

  void _publish(List<Peer> peers) {
    if (_disposed) return;
    _peers = peers;
    _current = _project(peers);
    if (!_controller.isClosed) _controller.add(_current);
  }

  /// Reports a hop when a message arrives from a known neighbour.
  ///
  /// The hop is drawn from that neighbour to this device. Messages that
  /// travelled through relays are attributed to the last neighbour seen, which
  /// is all the local stack can observe. Each accepted frame gets its own ID
  /// and its own event, so simultaneous messages are never coalesced.
  void _onIncomingHop(String senderId) {
    if (_disposed || senderId.isEmpty || senderId == localNodeId) return;
    // Unknown senders are ignored. This reads the topology snapshot, which
    // activity events never mutate, so the check cannot reject a later hop.
    if (_current.nodeById(senderId) == null) return;
    if (_activity.isClosed) return;
    _activity.add(TopologyTransmission(
      id: 'hop-${++_hopSeq}',
      sourceId: senderId,
      targetId: localNodeId,
    ));
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
    _peerSub = null;
    for (final subscription in _activitySubs) {
      await subscription.cancel();
    }
    _activitySubs.clear();
    await _controller.close();
    await _activity.close();
  }

  /// Current transport state, for callers that want to explain an empty view.
  TransportStatus get transportStatus => _transport.status;
}
