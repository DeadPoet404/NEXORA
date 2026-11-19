import '../models/peer.dart';

/// Visual lifecycle state of a node in the mesh visualization.
///
/// This is a presentation concern. It deliberately does not expose
/// [PeerLinkState] or any transport type, so a future Wi-Fi Direct or LoRa
/// transport can feed the same view without changing it.
enum TopologyNodePhase {
  /// This device, drawn as the anchor of the view.
  local,

  /// Peer with a usable link; messages can be exchanged now.
  connected,

  /// Peer whose link is being established.
  connecting,

  /// Peer that has been observed but has no usable link yet.
  discovering,

  /// Known peer that is no longer reachable.
  unavailable,
}

/// A single device in the drawn mesh.
class TopologyNode {
  const TopologyNode({
    required this.id,
    required this.label,
    required this.phase,
    this.signalBars = 0,
  });

  /// Mesh node ID (installation-scoped routing key), never a BLE address.
  final String id;

  /// Short label for the node. Not an identity proof.
  final String label;

  final TopologyNodePhase phase;

  /// 0–4 signal bars, mirroring [Peer.bars]; 0 when there is no usable link.
  final int signalBars;

  bool get isLocal => phase == TopologyNodePhase.local;
}

/// Visual state of a connection between two nodes.
enum TopologyLinkState {
  /// Usable link; traffic can flow now.
  up,

  /// Link is being negotiated.
  forming,

  /// Neighbour observed, no link yet.
  observed,

  /// Link existed and is now unusable.
  down,
}

/// A connection between two nodes.
///
/// Links are undirected for drawing. [id] is derived from the endpoint pair so
/// the view can keep a stable animation for a link while it changes state.
class TopologyLink {
  const TopologyLink({
    required this.sourceId,
    required this.targetId,
    required this.state,
  });

  final String sourceId;
  final String targetId;
  final TopologyLinkState state;

  String get id => linkIdBetween(sourceId, targetId);

  bool touches(String nodeId) => sourceId == nodeId || targetId == nodeId;

  static String linkIdBetween(String a, String b) =>
      a.compareTo(b) <= 0 ? '$a|$b' : '$b|$a';
}

/// One message hop the view can animate along a link.
///
/// It only says that a frame moved between two nodes; it carries no message
/// content and implies nothing about encryption or delivery.
class TopologyTransmission {
  const TopologyTransmission({
    required this.id,
    required this.sourceId,
    required this.targetId,
    this.relayed = false,
  });

  final String id;
  final String sourceId;
  final String targetId;

  /// True when the hop was a relay rather than an end-to-end exchange.
  final bool relayed;
}

/// Immutable view of the mesh at one moment.
///
/// The visualization consumes only this type, so it never touches BLE,
/// routing or storage code. Message hops are *not* part of the snapshot: they
/// travel on `MeshTopologySource.activity`, so an arriving message can never
/// alter the discovered topology.
class MeshTopologySnapshot {
  const MeshTopologySnapshot({
    required this.localNodeId,
    required this.nodes,
    required this.links,
    this.revision = 0,
    this.simulated = false,
  });

  /// Empty placeholder used before the first snapshot arrives.
  const MeshTopologySnapshot.empty()
      : localNodeId = '',
        nodes = const <TopologyNode>[],
        links = const <TopologyLink>[],
        revision = -1,
        simulated = false;

  final String localNodeId;
  final List<TopologyNode> nodes;
  final List<TopologyLink> links;

  final int revision;

  /// True only for development simulations. The view labels these loudly so a
  /// simulated picture is never mistaken for real Bluetooth activity.
  final bool simulated;

  TopologyNode? get localNode {
    for (final node in nodes) {
      if (node.id == localNodeId) return node;
    }
    return null;
  }

  TopologyNode? nodeById(String id) {
    for (final node in nodes) {
      if (node.id == id) return node;
    }
    return null;
  }

  int get connectedCount => nodes
      .where((node) => node.phase == TopologyNodePhase.connected)
      .length;

  int get activeLinkCount =>
      links.where((link) => link.state == TopologyLinkState.up).length;
}

/// Maps a transport link state to the phase the view understands.
TopologyNodePhase topoNodePhaseFor(PeerLinkState state) => switch (state) {
      PeerLinkState.connected => TopologyNodePhase.connected,
      PeerLinkState.connecting => TopologyNodePhase.connecting,
      PeerLinkState.discovered => TopologyNodePhase.discovering,
      PeerLinkState.disconnected => TopologyNodePhase.unavailable,
    };

/// Maps a transport link state to the drawn connection state.
TopologyLinkState topoLinkStateFor(PeerLinkState state) => switch (state) {
      PeerLinkState.connected => TopologyLinkState.up,
      PeerLinkState.connecting => TopologyLinkState.forming,
      PeerLinkState.discovered => TopologyLinkState.observed,
      PeerLinkState.disconnected => TopologyLinkState.down,
    };

/// Builds the drawn topology from real BLE discovery state.
///
/// Honest limitation: the local BLE stack only knows its own neighbours, so
/// this produces a star of local↔peer links. Relay paths between two peers are
/// not observable from here and are therefore not invented.
MeshTopologySnapshot topologyFromPeers({
  required String localNodeId,
  required String localName,
  required Iterable<Peer> peers,
  int revision = 0,
}) {
  final nodes = <TopologyNode>[];
  final links = <TopologyLink>[];
  final trimmedName = localName.trim();
  if (localNodeId.isNotEmpty) {
    nodes.add(TopologyNode(
      id: localNodeId,
      label: trimmedName.isEmpty ? 'This device' : trimmedName,
      phase: TopologyNodePhase.local,
    ));
  }

  final seen = <String>{localNodeId};
  for (final peer in peers) {
    final peerId = peer.nodeId;
    // Peers without a node ID have only an ephemeral BLE address that cannot
    // be routed to, so they are not drawn as mesh nodes.
    if (peerId == null || peerId.isEmpty || !seen.add(peerId)) continue;
    final connected = peer.state == PeerLinkState.connected;
    nodes.add(TopologyNode(
      id: peerId,
      label: peer.displayName,
      phase: topoNodePhaseFor(peer.state),
      signalBars: connected ? peer.bars : 0,
    ));
    if (localNodeId.isNotEmpty) {
      links.add(TopologyLink(
        sourceId: localNodeId,
        targetId: peerId,
        state: topoLinkStateFor(peer.state),
      ));
    }
  }

  return MeshTopologySnapshot(
    localNodeId: localNodeId,
    nodes: List<TopologyNode>.unmodifiable(nodes),
    links: List<TopologyLink>.unmodifiable(links),
    revision: revision,
  );
}
