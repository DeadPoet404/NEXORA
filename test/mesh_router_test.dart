import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:linkmesh/core/constants.dart';
import 'package:linkmesh/models/mesh_message.dart';
import 'package:linkmesh/models/stored_message.dart';
import 'package:linkmesh/security/peer_trust.dart';
import 'package:linkmesh/security/public_identity.dart';

import 'fake_network.dart';

void main() {
  Future<StoredMessage> statusOf(TestNode node, String id) async =>
      (await node.store.get(id))!;

  test('1. two devices communicate directly', () async {
    final net = FakeNetwork();
    final a = net.addNode('A');
    final b = net.addNode('B');
    net.link('A', 'B');

    final sent = await a.router.sendText('B', 'hello');
    await settle();

    final received = await b.store.conversation('A');
    expect(received, hasLength(1));
    expect(received.single.message.content, 'hello');
    expect(received.single.relayHops, 0);

    final status = await statusOf(a, sent.id);
    expect(status.status, DeliveryStatus.delivered);
    expect(status.relayHops, 0);
  });

  test('2. three devices relay through the middle node', () async {
    final net = FakeNetwork();
    final a = net.addNode('A');
    final b = net.addNode('B');
    final c = net.addNode('C');
    net.chain(['A', 'B', 'C']);

    final sent = await a.router.sendText('C', 'over the hill');
    await settle();

    final received = await c.store.conversation('A');
    expect(received.single.message.content, 'over the hill');
    expect(received.single.relayHops, 1);

    final status = await statusOf(a, sent.id);
    expect(status.status, DeliveryStatus.delivered);
    expect(status.relayHops, 1, reason: 'shown as "via 1 device"');

    // The relay doesn't keep other people's chats.
    expect(await b.store.conversations(), isEmpty);
  });

  test('3. middle device drops, message continues when link returns',
      () async {
    final net = FakeNetwork();
    final a = net.addNode('A');
    net.addNode('B');
    final c = net.addNode('C');
    net.chain(['A', 'B', 'C']);
    net.unlink('B', 'C');

    final sent = await a.router.sendText('C', 'are you there?');
    await settle();

    expect(await c.store.conversation('A'), isEmpty);
    expect(
      (await statusOf(a, sent.id)).status,
      DeliveryStatus.relayed,
      reason: 'A heard B forward it',
    );

    net.link('B', 'C'); // B replays its relay buffer to C
    await settle();

    expect(await c.store.conversation('A'), hasLength(1));
    expect((await statusOf(a, sent.id)).status, DeliveryStatus.delivered);
  });

  test('relay queue survives router restart and resumes forwarding', () async {
    final net = FakeNetwork();
    final a = net.addNode('A');
    final b = net.addNode('B');
    final c = net.addNode('C');
    net.link('A', 'B'); // C is not reachable yet.

    final sent = await a.router.sendText('C', 'survives relay restart');
    await settle();

    expect(await c.store.conversation('A'), isEmpty);
    expect(await b.store.conversations(), isEmpty,
        reason: 'a relay must not add the message to its chat history');
    final queuedBeforeRestart = await b.store
        .loadRelayQueue(DateTime.now().millisecondsSinceEpoch);
    expect(
      queuedBeforeRestart.map((entry) => entry.message.id),
      contains(sent.id),
    );

    await net.restartNode('B');
    net.link('B', 'C');
    await settle();

    expect((await c.store.conversation('A')).single.message.content,
        'survives relay restart');
    expect((await statusOf(a, sent.id)).status, DeliveryStatus.delivered);
  });

  test('a failed recipient store write can be retried without losing the frame',
      () async {
    final net = FakeNetwork();
    final a = net.addNode('A');
    final recipientStore = FailOnceIncomingStore();
    final b = net.addNode('B', store: recipientStore);

    // Queue before connecting so only the reconnect flush sends the first
    // attempt; otherwise the initial broadcast can race with that flush.
    final sent = await a.router.sendText('B', 'retry after disk failure');
    net.link('A', 'B');
    await recipientStore.firstIncomingTextFailure.future
        .timeout(const Duration(seconds: 2));
    // Let the failed frame handler release its in-flight reservation before
    // replaying, so the test exercises a completed failure, not a race.
    await settle(Duration.zero);
    expect(await b.store.conversation('A'), isEmpty);

    await a.transport.broadcast(sent.message.encode());
    await recipientStore.firstIncomingTextSaved.future
        .timeout(const Duration(seconds: 2));
    await settle();
    expect((await b.store.conversation('A')).single.message.content,
        'retry after disk failure');
    expect((await statusOf(a, sent.id)).status, DeliveryStatus.delivered);
  });

  test('3b. sender with no peers queues, then sends on first link', () async {
    final net = FakeNetwork();
    final a = net.addNode('A');
    final b = net.addNode('B');

    final sent = await a.router.sendText('B', 'queued');
    expect(sent.status, DeliveryStatus.pending);

    net.link('A', 'B');
    await settle();

    expect(await b.store.conversation('A'), hasLength(1));
    expect((await statusOf(a, sent.id)).status, DeliveryStatus.delivered);
  });

  test('4. dense mesh delivers exactly once, no broadcast storm', () async {
    final net = FakeNetwork();
    final ids = ['A', 'B', 'C', 'D', 'E'];
    for (final id in ids) {
      net.addNode(id);
    }
    for (final x in ids) {
      for (final y in ids) {
        if (x != y) net.link(x, y);
      }
    }
    final sent = await net.nodes['A']!.router.sendText('E', 'once');
    await settle();

    final e = net.nodes['E']!;
    expect(e.store.saves[sent.id], 1, reason: 'stored once despite 4 copies');
    // Each node forwards a given message at most once.
    expect(net.framesDelivered, lessThan(ids.length * ids.length * 2));
    expect(
      (await statusOf(net.nodes['A']!, sent.id)).status,
      DeliveryStatus.delivered,
    );
  });

  test('blocked peers cannot be messaged and receive no relayed frames',
      () async {
    final net = FakeNetwork();
    final a = net.addNode('A');
    final b = net.addNode('B');
    net.link('A', 'B');
    await a.trustRepository.blockPeer(
      'B',
      nowMillis: DateTime.now().millisecondsSinceEpoch,
    );

    await expectLater(
      a.router.sendText('B', 'blocked'),
      throwsA(isA<PeerTrustException>()),
    );
    expect(await a.store.conversations(), isEmpty);
    await a.router.sendSos('public alert');
    await settle();
    expect(await b.store.sosAlerts(), isEmpty,
        reason: 'broadcast routing excludes a blocked BLE neighbour');
  });

  test('changed QR-pinned identities immediately block outgoing messages',
      () async {
    final net = FakeNetwork();
    final a = net.addNode('A');
    net.addNode('B');
    final service = PeerTrustService(repository: a.trustRepository);
    final oldIdentity = PublicIdentityMaterial(
      peerId: 'B',
      displayName: 'B',
      keyId: 'key-1',
      algorithm: 'test-only',
      publicKey: [1, 2, 3],
    );
    await service.observe(oldIdentity);
    final challenge = await service.prepareVerification(
      expectedPeerId: 'B',
      scannedQr: IdentityQrPayload.fromIdentity(oldIdentity).encode(),
    );
    await service.confirmVerification(challenge);
    await service.observe(PublicIdentityMaterial(
      peerId: 'B',
      displayName: 'B',
      keyId: 'key-2',
      algorithm: 'test-only',
      publicKey: [4, 5, 6],
    ));

    await expectLater(
      a.router.sendText('B', 'must be blocked'),
      throwsA(isA<PeerTrustException>()),
    );
    expect(await a.store.conversations(), isEmpty);
  });

  test('an ACK from the wrong peer cannot mark a message delivered',
      () async {
    final net = FakeNetwork();
    final a = net.addNode('A');
    final c = net.addNode('C');
    net.addNode('B'); // Intended recipient is deliberately offline.
    net.link('A', 'C');

    final sent = await a.router.sendText('B', 'must not be forged');
    final forgedAck = MeshMessage(
      id: 'forged-ack',
      type: MessageType.ack,
      senderId: 'C',
      senderName: 'C',
      receiverId: 'A',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      content: '0',
      refId: sent.id,
    );
    await c.transport.broadcast(forgedAck.encode());
    await settle();

    expect((await statusOf(a, sent.id)).status,
        isNot(DeliveryStatus.delivered));
  });

  test('5. high latency links still deliver', () async {
    final net = FakeNetwork(latency: const Duration(milliseconds: 150));
    final a = net.addNode('A');
    net.addNode('B');
    net.addNode('C');
    final d = net.addNode('D');
    net.chain(['A', 'B', 'C', 'D']);

    final sent = await a.router.sendText('D', 'slow');
    await settle(const Duration(milliseconds: 300));
    expect(await d.store.conversation('A'), isEmpty, reason: 'still in flight');

    await settle(const Duration(seconds: 1));
    expect((await d.store.conversation('A')).single.relayHops, 2);
    expect((await statusOf(a, sent.id)).status, DeliveryStatus.delivered);
  });

  test('max_hops bounds how far a message travels', () async {
    final net = FakeNetwork();
    final ids = List.generate(8, (i) => 'N$i');
    for (final id in ids) {
      net.addNode(id);
    }
    net.chain(ids);
    final origin = net.nodes['N0']!;

    // N0 -> N6 takes 5 relays (N1..N5): exactly the default budget.
    final reachable = await origin.router.sendText('N6', 'edge');
    // N0 -> N7 would take 6.
    final tooFar = await origin.router.sendText('N7', 'beyond');
    await settle(const Duration(milliseconds: 200));

    expect((await net.nodes['N6']!.store.conversation('N0')).single.relayHops,
        5);
    expect(await net.nodes['N7']!.store.conversation('N0'), isEmpty);
    expect((await statusOf(origin, reachable.id)).status,
        DeliveryStatus.delivered);
    expect((await statusOf(origin, tooFar.id)).status,
        isNot(DeliveryStatus.delivered));
  });

  test('SOS reaches every node and raises an alert', () async {
    final net = FakeNetwork();
    for (final id in ['A', 'B', 'C']) {
      net.addNode(id);
    }
    net.chain(['A', 'B', 'C']);
    final alerts = <String>[];
    net.nodes['C']!.router.sosAlerts.listen((m) => alerts.add(m.message.id));

    final sos = await net.nodes['A']!.router
        .sendSos('help', lat: 12.5, lng: 77.25);
    await settle();

    for (final id in ['B', 'C']) {
      final list = await net.nodes[id]!.store.sosAlerts();
      expect(list.single.message.content, 'help');
      expect(list.single.message.lat, 12.5);
    }
    expect(alerts, [sos.id]);
    expect(await net.nodes['A']!.store.sosAlerts(), isEmpty,
        reason: 'own SOS is not an alert');
  });

  test('incoming message event fires once per message, for recipient only',
      () async {
    final net = FakeNetwork();
    for (final id in ['A', 'B', 'C']) {
      net.addNode(id);
    }
    // Triangle: C hears the message both directly and via B.
    net
      ..link('A', 'B')
      ..link('B', 'C')
      ..link('A', 'C');
    final atC = <String>[];
    final atB = <String>[];
    net.nodes['C']!.router.incomingMessages
        .listen((m) => atC.add(m.message.content));
    net.nodes['B']!.router.incomingMessages
        .listen((m) => atB.add(m.message.content));

    await net.nodes['A']!.router.sendText('C', 'ding');
    await settle();

    expect(atC, ['ding'], reason: 'one chime, not one per copy');
    expect(atB, isEmpty, reason: 'relays do not notify');
  });

  test('malformed frames are ignored', () async {
    final net = FakeNetwork();
    final a = net.addNode('A');
    final b = net.addNode('B');
    net.link('A', 'B');

    await a.transport.broadcast(Uint8List.fromList([1, 2, 3]));
    await a.transport.broadcast(
      Uint8List.fromList(utf8.encode('{"id":"x","type":"bogus"}')),
    );
    await settle();

    expect(await b.store.conversations(), isEmpty);
  });

  test('oversized and invalid-hop frames are rejected before routing', () {
    final oversized = Uint8List(MeshConstants.maxFrameBytes + 1);
    expect(MeshMessage.tryDecode(oversized), isNull);
    final invalid = MeshMessage(
      id: 'invalid-hop',
      type: MessageType.text,
      senderId: 'A',
      senderName: 'Alice',
      receiverId: 'B',
      timestamp: 1,
      content: 'x',
      hopCount: -1,
    );
    expect(MeshMessage.tryDecode(invalid.encode()), isNull);
  });

  test('message JSON round-trips with spec field names', () {
    const m = MeshMessage(
      id: 'm1',
      type: MessageType.text,
      senderId: 'A',
      senderName: 'Alice',
      receiverId: 'B',
      timestamp: 1234567890,
      content: 'hi',
    );
    final json = m.toJson();
    expect(json.keys, containsAll([
      'id', 'sender_id', 'receiver_id', 'timestamp', 'content', //
      'hop_count', 'max_hops',
    ]));
    final decoded = MeshMessage.tryDecode(m.encode())!;
    expect(decoded.toJson(), json);
  });
}
