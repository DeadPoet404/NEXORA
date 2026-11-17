import '../models/peer.dart';

/// Stable installation-scoped peer record; BLE addresses are only observations.
class KnownPeer {
  const KnownPeer({
    required this.peerId,
    required this.displayName,
    required this.lastSeen,
  });

  final String peerId;
  final String displayName;
  final DateTime lastSeen;

  Peer asDisconnectedPeer() => Peer(
        address: peerId,
        nodeId: peerId,
        name: displayName,
        state: PeerLinkState.disconnected,
        rssi: -100,
        lastSeen: lastSeen,
      );
}

/// Persistent directory of peers whose LinkMesh node IDs were read over GATT.
/// Merge current transport observations over persisted peers, deduplicating by
/// stable mesh node ID (not the rotating BLE address).
List<Peer> mergePeerViews({
  required Iterable<KnownPeer> remembered,
  required Iterable<Peer> live,
}) {
  final byNodeId = <String, Peer>{
    for (final known in remembered) known.peerId: known.asDisconnectedPeer(),
  };
  final addressOnly = <String, Peer>{};
  for (final peer in live) {
    final id = peer.nodeId;
    if (id == null) {
      final previous = addressOnly[peer.address];
      if (previous == null || _isBetterLivePeer(peer, previous)) {
        addressOnly[peer.address] = peer;
      }
      continue;
    }
    final previous = byNodeId[id];
    if (previous == null || _isBetterLivePeer(peer, previous)) {
      byNodeId[id] = peer;
    }
  }
  final merged = [...byNodeId.values, ...addressOnly.values]
    ..sort((a, b) {
      final byState = a.state.index.compareTo(b.state.index);
      if (byState != 0) return byState;
      final byRssi = b.rssi.compareTo(a.rssi);
      return byRssi != 0 ? byRssi : b.lastSeen.compareTo(a.lastSeen);
    });
  return merged;
}

bool _isBetterLivePeer(Peer candidate, Peer current) {
  if (candidate.state.index != current.state.index) {
    return candidate.state.index < current.state.index;
  }
  if (candidate.rssi != current.rssi) return candidate.rssi > current.rssi;
  return candidate.lastSeen.isAfter(current.lastSeen);
}

abstract interface class PeerRegistry {
  Future<void> rememberPeer({
    required String peerId,
    required String displayName,
    required int lastSeenMillis,
  });

  Future<List<KnownPeer>> knownPeers();
}
