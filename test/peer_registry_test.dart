import 'package:flutter_test/flutter_test.dart';
import 'package:linkmesh/data/message_store.dart';
import 'package:linkmesh/data/peer_registry.dart';
import 'package:linkmesh/models/peer.dart';
import 'package:linkmesh/services/identity_service.dart';

void main() {
  final recent = DateTime.utc(2026, 11, 16, 12);

  test('mesh node ID persists across identity reload and rename', () async {
    final store = InMemoryMessageStore();
    final first = await IdentityService.load(store);
    await first.rename('Renamed');
    final second = await IdentityService.load(store);

    expect(second.current.id, first.current.id);
    expect(second.current.name, 'Renamed');
    expect(second.current.id, isNotEmpty);
  });

  Peer live(String address, {
    String? id,
    PeerLinkState state = PeerLinkState.discovered,
    int rssi = -60,
    DateTime? lastSeen,
  }) =>
      Peer(
        address: address,
        nodeId: id,
        name: id == null ? null : 'Phone',
        state: state,
        rssi: rssi,
        lastSeen: lastSeen ?? recent,
      );

  test('stable node IDs deduplicate rotating BLE addresses', () {
    final merged = mergePeerViews(
      remembered: [
        KnownPeer(
          peerId: 'mesh-node-1',
          displayName: 'Phone',
          lastSeen: recent.subtract(const Duration(days: 1)),
        ),
      ],
      live: [
        live('address-a', id: 'mesh-node-1', rssi: -70),
        live('address-b', id: 'mesh-node-1', rssi: -45),
      ],
    );

    expect(merged, hasLength(1));
    expect(merged.single.nodeId, 'mesh-node-1');
    expect(merged.single.address, 'address-b');
    expect(merged.single.state, PeerLinkState.discovered);
  });

  test('connected address wins over stale and duplicate observations', () {
    final merged = mergePeerViews(
      remembered: [
        KnownPeer(
          peerId: 'node',
          displayName: 'Persisted name',
          lastSeen: recent.subtract(const Duration(hours: 1)),
        ),
      ],
      live: [
        live('weak-address', id: 'node', state: PeerLinkState.disconnected),
        live('connected-address', id: 'node', state: PeerLinkState.connected),
      ],
    );

    expect(merged, hasLength(1));
    expect(merged.single.address, 'connected-address');
    expect(merged.single.state, PeerLinkState.connected);
  });

  test('unidentified advertisements deduplicate by address only', () {
    final merged = mergePeerViews(
      remembered: const [],
      live: [live('address-a'), live('address-a'), live('address-b')],
    );

    expect(merged, hasLength(2));
    expect(merged.every((peer) => peer.nodeId == null), isTrue);
  });
}
