import 'dart:async';
import 'dart:typed_data';

import 'package:linkmesh/data/message_store.dart';
import 'package:linkmesh/mesh/mesh_router.dart';
import 'package:linkmesh/mesh/transport.dart';
import 'package:linkmesh/models/node_identity.dart';
import 'package:linkmesh/models/peer.dart';
import 'package:linkmesh/models/stored_message.dart';
import 'package:linkmesh/security/in_memory_peer_trust_repository.dart';
import 'package:linkmesh/security/peer_trust.dart';

/// Simulated radio neighbourhood: nodes only hear nodes they're linked to.
class FakeNetwork {
  FakeNetwork({this.latency = Duration.zero});

  final Duration latency;
  final nodes = <String, TestNode>{};
  final _links = <String>{};
  int framesDelivered = 0;

  TestNode addNode(String id, {CountingStore? store}) {
    final transport = FakeTransport(id, this);
    final nodeStore = store ?? CountingStore();
    final trustRepository = InMemoryPeerTrustRepository();
    final trust = PeerTrustService(repository: trustRepository);
    final router = MeshRouter(
      transport: transport,
      store: nodeStore,
      identity: NodeIdentity(id: id, name: id),
      messagingPolicy: trust,
    )..start();
    return nodes[id] = TestNode(
      id,
      transport,
      nodeStore,
      router,
      trustRepository,
    );
  }

  /// Recreates a node's router while keeping its transport and store. The
  /// in-memory store verifies router restoration logic, not disk durability.
  Future<TestNode> restartNode(String id) async {
    final previous = nodes[id]!;
    await previous.router.dispose();
    final trust = PeerTrustService(repository: previous.trustRepository);
    final router = MeshRouter(
      transport: previous.transport,
      store: previous.store,
      identity: NodeIdentity(id: id, name: id),
      messagingPolicy: trust,
    )..start();
    return nodes[id] = TestNode(
      id,
      previous.transport,
      previous.store,
      router,
      previous.trustRepository,
    );
  }

  static String _key(String a, String b) =>
      a.compareTo(b) < 0 ? '$a|$b' : '$b|$a';

  bool linked(String a, String b) => _links.contains(_key(a, b));

  void link(String a, String b) {
    if (!_links.add(_key(a, b))) return;
    nodes[a]!.transport._linked.add(b);
    nodes[b]!.transport._linked.add(a);
  }

  void unlink(String a, String b) => _links.remove(_key(a, b));

  /// Links consecutive ids into a line: a - b - c ...
  void chain(List<String> ids) {
    for (var i = 0; i + 1 < ids.length; i++) {
      link(ids[i], ids[i + 1]);
    }
  }

  Iterable<String> neighbours(String id) =>
      nodes.keys.where((other) => other != id && linked(id, other));

  void _deliver(String from, String to, Uint8List frame) {
    Future<void>.delayed(latency, () {
      if (!linked(from, to)) return; // link dropped while in flight
      framesDelivered++;
      nodes[to]!.transport._incoming.add(frame);
    });
  }
}

class TestNode {
  TestNode(
    this.id,
    this.transport,
    this.store,
    this.router,
    this.trustRepository,
  );

  final String id;
  final FakeTransport transport;
  final CountingStore store;
  final MeshRouter router;
  final InMemoryPeerTrustRepository trustRepository;
}

class CountingStore extends InMemoryMessageStore {
  final saves = <String, int>{};

  @override
  Future<void> save(StoredMessage message) {
    saves.update(message.id, (n) => n + 1, ifAbsent: () => 1);
    return super.save(message);
  }
}

class FailOnceIncomingStore extends CountingStore {
  bool failNextIncomingText = true;

  @override
  Future<void> save(StoredMessage message) {
    if (failNextIncomingText &&
        !message.outgoing &&
        message.message.type.name == 'text') {
      failNextIncomingText = false;
      return Future<void>.error(StateError('simulated disk interruption'));
    }
    return super.save(message);
  }
}

class FakeTransport implements MeshTransport {
  FakeTransport(this.id, this.network);

  final String id;
  final FakeNetwork network;
  final _incoming = StreamController<Uint8List>.broadcast();
  final _linked = StreamController<String>.broadcast();

  @override
  TransportStatus get status => TransportStatus.running;

  @override
  Stream<TransportStatus> get statusChanges => const Stream.empty();

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  List<Peer> get peers => network.neighbours(id)
      .map((peerId) => Peer(
            address: peerId,
            nodeId: peerId,
            name: peerId,
            state: PeerLinkState.connected,
            rssi: -50,
            lastSeen: DateTime.now(),
          ))
      .toList();

  @override
  Stream<List<Peer>> get peerChanges => const Stream.empty();

  @override
  Stream<String> get peerLinked => _linked.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> retryDiscovery() async {}

  @override
  Future<void> stop() async {}

  @override
  void setBackground(bool background) {}

  @override
  Future<int> broadcast(
    Uint8List frame, {
    Set<String> excludeNodeIds = const {},
  }) async {
    final targets = network
        .neighbours(id)
        .where((peerId) => !excludeNodeIds.contains(peerId))
        .toList();
    for (final t in targets) {
      network._deliver(id, t, frame);
    }
    return targets.length;
  }

  @override
  Future<bool> sendTo(String nodeId, Uint8List frame) async {
    if (!network.linked(id, nodeId)) return false;
    network._deliver(id, nodeId, frame);
    return true;
  }
}

/// Lets queued deliveries and async handlers run.
Future<void> settle([Duration d = const Duration(milliseconds: 50)]) =>
    Future<void>.delayed(d);
