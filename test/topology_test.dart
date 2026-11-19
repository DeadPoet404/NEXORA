import 'dart:async';
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:linkmesh/models/peer.dart';
import 'package:linkmesh/visualization/mesh_layout.dart';
import 'package:linkmesh/visualization/simulated_topology_source.dart';
import 'package:linkmesh/visualization/topology.dart';
import 'package:linkmesh/visualization/topology_source.dart';

import 'fake_network.dart';

Peer _peer(
  String nodeId,
  PeerLinkState state, {
  int rssi = -60,
  String? name,
}) =>
    Peer(
      address: 'address-$nodeId',
      nodeId: nodeId,
      name: name,
      state: state,
      rssi: rssi,
      lastSeen: DateTime.utc(2026, 1, 1),
    );

void main() {
  group('topologyFromPeers', () {
    test('maps real BLE link states to visual phases', () {
      final topology = topologyFromPeers(
        localNodeId: 'local',
        localName: '  Ama  ',
        peers: [
          _peer('peer-1', PeerLinkState.connected, rssi: -55, name: 'Kofi'),
          _peer('peer-2', PeerLinkState.connecting),
          _peer('peer-3', PeerLinkState.discovered),
          _peer('peer-4', PeerLinkState.disconnected),
        ],
      );

      expect(topology.simulated, isFalse);
      expect(topology.localNode?.phase, TopologyNodePhase.local);
      expect(topology.localNode?.label, 'Ama');
      expect(
        topology.nodes.map((node) => node.id).toList(),
        ['local', 'peer-1', 'peer-2', 'peer-3', 'peer-4'],
      );
      expect(topology.nodeById('peer-1')?.label, 'Kofi');
      expect(topology.nodeById('peer-1')?.phase, TopologyNodePhase.connected);
      expect(topology.nodeById('peer-1')?.signalBars, 4);
      expect(topology.nodeById('peer-2')?.phase, TopologyNodePhase.connecting);
      expect(topology.nodeById('peer-3')?.phase, TopologyNodePhase.discovering);
      expect(
          topology.nodeById('peer-4')?.phase, TopologyNodePhase.unavailable);
      expect(topology.nodeById('peer-3')?.signalBars, 0);

      expect(topology.links.length, 4);
      expect(topology.links.first.sourceId, 'local');
      expect(topology.links.first.targetId, 'peer-1');
      expect(topology.links.first.state, TopologyLinkState.up);
      expect(topology.links[1].state, TopologyLinkState.forming);
      expect(topology.links[2].state, TopologyLinkState.observed);
      expect(topology.links[3].state, TopologyLinkState.down);
      expect(topology.connectedCount, 1);
      expect(topology.activeLinkCount, 1);
    });

    test('skips peers that have only an ephemeral address', () {
      final topology = topologyFromPeers(
        localNodeId: 'local',
        localName: 'Ama',
        peers: [
          Peer(
            address: 'AA:BB:CC:DD:EE:FF',
            state: PeerLinkState.discovered,
            rssi: -70,
            lastSeen: DateTime.utc(2026, 1, 1),
          ),
        ],
      );
      expect(topology.nodes.length, 1);
      expect(topology.links, isEmpty);
    });

    test('deduplicates a peer seen under two addresses', () {
      final topology = topologyFromPeers(
        localNodeId: 'local',
        localName: 'Ama',
        peers: [
          _peer('peer-1', PeerLinkState.connecting, rssi: -80),
          _peer('peer-1', PeerLinkState.connected, rssi: -55),
        ],
      );
      expect(topology.nodes.length, 2);
      expect(topology.links.length, 1);
      expect(topology.nodeById('peer-1')?.phase, TopologyNodePhase.connecting);
    });

    test('link ids are stable regardless of endpoint order', () {
      expect(
        TopologyLink.linkIdBetween('b', 'a'),
        TopologyLink.linkIdBetween('a', 'b'),
      );
    });
  });

  group('LiveMeshTopologySource', () {
    test('projects transport peers and labels itself as real', () async {
      final network = FakeNetwork();
      final node = network.addNode('A');
      network.addNode('B');
      network.link('A', 'B');

      final source = LiveMeshTopologySource(
        transport: node.transport,
        localNodeId: 'A',
        localName: 'Ama',
      );
      addTearDown(source.dispose);

      expect(source.isSimulated, isFalse);
      expect(
        source.current.nodes.map((peer) => peer.id).toList(),
        ['A', 'B'],
      );
      expect(source.current.links.single.state, TopologyLinkState.up);
      expect(source.transportStatus.name, 'running');
    });

    test('animates a hop for an arriving message from a known neighbour',
        () async {
      final network = FakeNetwork();
      final node = network.addNode('A');
      network.addNode('B');
      network.link('A', 'B');

      final senders = StreamController<String>();
      addTearDown(senders.close);
      final source = LiveMeshTopologySource(
        transport: node.transport,
        localNodeId: 'A',
        activityStreams: [senders.stream],
      );
      addTearDown(source.dispose);
      final recorder = _Recorder(source);
      addTearDown(recorder.dispose);
      final topologyBefore = source.current;

      senders.add('B');
      senders.add('unknown-node');
      await pumpEventQueue();

      // Only the known neighbour produces a hop; unknown IDs are ignored.
      expect(recorder.hops.length, 1);
      expect(recorder.hops.single.sourceId, 'B');
      expect(recorder.hops.single.targetId, 'A');
      expect(recorder.hops.single.relayed, isFalse);
      // Activity must never re-emit or replace the topology.
      expect(recorder.snapshots, isEmpty);
      expect(identical(source.current, topologyBefore), isTrue);
    });

    test('repeated messages each produce their own hop', () async {
      final network = FakeNetwork();
      final node = network.addNode('A');
      network.addNode('B');
      network.link('A', 'B');

      final senders = StreamController<String>();
      addTearDown(senders.close);
      final source = LiveMeshTopologySource(
        transport: node.transport,
        localNodeId: 'A',
        activityStreams: [senders.stream],
      );
      addTearDown(source.dispose);
      final recorder = _Recorder(source);
      addTearDown(recorder.dispose);
      final topologyBefore = source.current;

      senders.add('B');
      senders.add('B');
      await pumpEventQueue();

      expect(recorder.hops.length, 2);
      expect(recorder.hops.map((hop) => hop.id).toSet().length, 2);
      for (final hop in recorder.hops) {
        expect(hop.sourceId, 'B');
        expect(hop.targetId, 'A');
      }
      expect(recorder.snapshots, isEmpty);
      expect(identical(source.current, topologyBefore), isTrue);
    });

    test('ignores unknown senders and this device\'s own node id', () async {
      final network = FakeNetwork();
      final node = network.addNode('A');
      network.addNode('B');
      network.link('A', 'B');

      final senders = StreamController<String>();
      addTearDown(senders.close);
      final source = LiveMeshTopologySource(
        transport: node.transport,
        localNodeId: 'A',
        activityStreams: [senders.stream],
      );
      addTearDown(source.dispose);
      final recorder = _Recorder(source);
      addTearDown(recorder.dispose);

      senders.add('nobody');
      senders.add('A');
      senders.add('');
      await pumpEventQueue();

      expect(recorder.hops, isEmpty);
      expect(recorder.snapshots, isEmpty);
    });

    test('watches every activity stream', () async {
      final network = FakeNetwork();
      final node = network.addNode('A');
      network.addNode('B');
      network.addNode('C');
      network.link('A', 'B');
      network.link('A', 'C');

      // Chat messages and SOS alerts are separate router streams.
      final chats = StreamController<String>();
      final alerts = StreamController<String>();
      addTearDown(chats.close);
      addTearDown(alerts.close);
      final source = LiveMeshTopologySource(
        transport: node.transport,
        localNodeId: 'A',
        activityStreams: [chats.stream, alerts.stream],
      );
      addTearDown(source.dispose);
      final recorder = _Recorder(source);
      addTearDown(recorder.dispose);

      chats.add('B');
      alerts.add('C');
      await pumpEventQueue();

      expect(recorder.hops.length, 2);
      expect(
        recorder.hops.map((hop) => hop.sourceId).toSet(),
        {'B', 'C'},
      );
      expect(recorder.hops.map((hop) => hop.id).toSet().length, 2);
      expect(recorder.snapshots, isEmpty);
    });

    test('keeps every discovered peer while hops arrive', () async {
      final network = FakeNetwork();
      final node = network.addNode('A');
      network.addNode('B');
      network.link('A', 'B');

      final senders = StreamController<String>();
      addTearDown(senders.close);
      final source = LiveMeshTopologySource(
        transport: node.transport,
        localNodeId: 'A',
        activityStreams: [senders.stream],
      );
      addTearDown(source.dispose);
      final recorder = _Recorder(source);
      addTearDown(recorder.dispose);

      senders.add('B');
      await pumpEventQueue();

      // Regression: a hop used to rebuild the snapshot from an empty peer list,
      // which dropped the neighbour and then suppressed every later hop.
      expect(
        source.current.nodes.map((peer) => peer.id).toList(),
        ['A', 'B'],
      );
      expect(source.current.links.single.state, TopologyLinkState.up);
    });

    test('delivers a rapid burst from one stream without coalescing',
        () async {
      final network = FakeNetwork();
      final node = network.addNode('A');
      network.addNode('B');
      network.link('A', 'B');

      final senders = StreamController<String>();
      addTearDown(senders.close);
      final source = LiveMeshTopologySource(
        transport: node.transport,
        localNodeId: 'A',
        activityStreams: [senders.stream],
      );
      addTearDown(source.dispose);
      final recorder = _Recorder(source);
      addTearDown(recorder.dispose);
      final topologyBefore = source.current;

      // Eight frames arrive back to back, with no await between them.
      for (var i = 0; i < 8; i++) {
        senders.add('B');
      }
      await pumpEventQueue();

      expect(recorder.hops.length, 8);
      expect(recorder.hops.map((hop) => hop.id).toSet().length, 8);
      expect(recorder.hops.every((hop) => hop.sourceId == 'B'), isTrue);
      expect(recorder.snapshots, isEmpty);
      expect(identical(source.current, topologyBefore), isTrue);
    });

    test('delivers a rapid burst interleaved across activity streams',
        () async {
      final network = FakeNetwork();
      final node = network.addNode('A');
      network.addNode('B');
      network.addNode('C');
      network.link('A', 'B');
      network.link('A', 'C');

      final chats = StreamController<String>();
      final alerts = StreamController<String>();
      addTearDown(chats.close);
      addTearDown(alerts.close);
      final source = LiveMeshTopologySource(
        transport: node.transport,
        localNodeId: 'A',
        activityStreams: [chats.stream, alerts.stream],
      );
      addTearDown(source.dispose);
      final recorder = _Recorder(source);
      addTearDown(recorder.dispose);
      final topologyBefore = source.current;

      for (var i = 0; i < 4; i++) {
        chats.add('B');
        alerts.add('C');
      }
      await pumpEventQueue();

      expect(recorder.hops.length, 8);
      expect(recorder.hops.map((hop) => hop.id).toSet().length, 8);
      expect(recorder.hops.where((hop) => hop.sourceId == 'B').length, 4);
      expect(recorder.hops.where((hop) => hop.sourceId == 'C').length, 4);
      expect(recorder.snapshots, isEmpty);
      expect(identical(source.current, topologyBefore), isTrue);
      expect(source.current.nodes.length, 3);
    });
  });

  group('SimulatedMeshTopologySource', () {
    test('is labelled as simulated and always keeps this device', () async {
      final source = SimulatedMeshTopologySource(seed: 5, autoAdvance: false);
      addTearDown(source.dispose);

      final snapshots = <MeshTopologySnapshot>[];
      final sub = source.changes.listen(snapshots.add);
      addTearDown(sub.cancel);

      for (var i = 0; i < 40; i++) {
        source.step();
      }
      await pumpEventQueue();

      expect(source.isSimulated, isTrue);
      expect(snapshots.length, 40);
      expect(source.current.simulated, isTrue);
      expect(source.current.localNode?.phase, TopologyNodePhase.local);
      expect(source.current.nodes.first.id, SimulatedMeshTopologySource.localNodeId);
      for (final snapshot in snapshots) {
        expect(snapshot.localNode, isNotNull);
        expect(snapshot.simulated, isTrue);
      }
    });

    test('only references nodes that exist in the same snapshot', () async {
      final source = SimulatedMeshTopologySource(seed: 3, autoAdvance: false);
      addTearDown(source.dispose);

      final snapshots = <MeshTopologySnapshot>[];
      final hops = <TopologyTransmission>[];
      final sub = source.changes.listen(snapshots.add);
      addTearDown(sub.cancel);
      final hopSub = source.activity.listen(hops.add);
      addTearDown(hopSub.cancel);

      for (var i = 0; i < 60; i++) {
        source.step();
      }
      await pumpEventQueue();

      expect(hops, isNotEmpty);
      for (final snapshot in snapshots) {
        final ids = snapshot.nodes.map((node) => node.id).toSet();
        for (final link in snapshot.links) {
          expect(ids, contains(link.sourceId));
          expect(ids, contains(link.targetId));
        }
      }
      // Hops travel separately; every endpoint must still be a real node.
      final knownIds = <String>{
        for (final snapshot in snapshots)
          for (final node in snapshot.nodes) node.id,
      };
      for (final hop in hops) {
        expect(knownIds, contains(hop.sourceId));
        expect(knownIds, contains(hop.targetId));
      }
    });

    test('peers join, leave and change state over time', () async {
      final source = SimulatedMeshTopologySource(seed: 3, autoAdvance: false);
      addTearDown(source.dispose);

      final snapshots = <MeshTopologySnapshot>[];
      final activity = <TopologyTransmission>[];
      final sub = source.changes.listen(snapshots.add);
      addTearDown(sub.cancel);
      final hopSub = source.activity.listen(activity.add);
      addTearDown(hopSub.cancel);

      for (var i = 0; i < 60; i++) {
        source.step();
      }
      await pumpEventQueue();

      final counts = snapshots.map((s) => s.nodes.length).toList();
      final allIds = <String>{};
      for (final snapshot in snapshots) {
        allIds.addAll(snapshot.nodes.map((node) => node.id));
      }
      final phases = <TopologyNodePhase>{};
      final linkStates = <TopologyLinkState>{};
      for (final snapshot in snapshots) {
        phases.addAll(snapshot.nodes.map((node) => node.phase));
        linkStates.addAll(snapshot.links.map((link) => link.state));
      }

      // More distinct IDs than any single snapshot proves churn, not growth.
      expect(allIds.length, greaterThan(counts.reduce((a, b) => a > b ? a : b)));
      expect(phases.length, greaterThan(2));
      expect(linkStates, contains(TopologyLinkState.up));
      expect(activity, isNotEmpty);
    });

    test('dispose closes the stream and is idempotent', () async {
      final source = SimulatedMeshTopologySource(seed: 2, autoAdvance: false);
      final done = expectLater(source.changes, emitsDone);
      await source.dispose();
      await done;
      // A second dispose, or a stray tick, must not throw.
      await source.dispose();
      source.step();
    });
  });

  group('MeshLayout', () {
    test('handles an empty topology', () {
      final layout = MeshLayout();
      layout.update(const MeshTopologySnapshot.empty());
      expect(layout.centers, isEmpty);
      expect(layout.bounds, Rect.zero);
    });

    test('centres a lone device without peers', () {
      final layout = MeshLayout();
      layout.update(const MeshTopologySnapshot(
        localNodeId: 'local',
        nodes: [
          TopologyNode(
            id: 'local',
            label: 'This device',
            phase: TopologyNodePhase.local,
          ),
        ],
        links: [],
      ));
      expect(layout.centers.length, 1);
      expect(layout.centers['local'], isNotNull);
      expect(layout.bounds.width, greaterThan(0));
      expect(layout.bounds.height, greaterThan(0));
    });

    test('positions a star of peers inside its bounds', () {
      final layout = MeshLayout();
      layout.update(const MeshTopologySnapshot(
        localNodeId: 'local',
        nodes: [
          TopologyNode(
            id: 'local',
            label: 'This device',
            phase: TopologyNodePhase.local,
          ),
          TopologyNode(
            id: 'p1',
            label: 'Kofi',
            phase: TopologyNodePhase.connected,
            signalBars: 3,
          ),
          TopologyNode(
            id: 'p2',
            label: 'Ama',
            phase: TopologyNodePhase.discovering,
          ),
          TopologyNode(
            id: 'p3',
            label: 'Esi',
            phase: TopologyNodePhase.unavailable,
          ),
        ],
        links: [
          TopologyLink(
            sourceId: 'local',
            targetId: 'p1',
            state: TopologyLinkState.up,
          ),
          TopologyLink(
            sourceId: 'local',
            targetId: 'p2',
            state: TopologyLinkState.observed,
          ),
          TopologyLink(
            sourceId: 'local',
            targetId: 'p3',
            state: TopologyLinkState.down,
          ),
        ],
      ));

      expect(layout.centers.length, 4);
      expect(layout.bounds.width, greaterThan(0));
      expect(layout.bounds.height, greaterThan(0));
      for (final center in layout.centers.values) {
        expect(center.dx.isFinite, isTrue);
        expect(center.dy.isFinite, isTrue);
        expect(layout.bounds.inflate(1).contains(center), isTrue);
      }
    });

    test('keeps positions when only one peer joins', () {
      final layout = MeshLayout();
      layout.update(const MeshTopologySnapshot(
        localNodeId: 'local',
        nodes: [
          TopologyNode(
            id: 'local',
            label: 'This device',
            phase: TopologyNodePhase.local,
          ),
          TopologyNode(
            id: 'p1',
            label: 'Kofi',
            phase: TopologyNodePhase.connected,
          ),
        ],
        links: [
          TopologyLink(
            sourceId: 'local',
            targetId: 'p1',
            state: TopologyLinkState.up,
          ),
        ],
      ));
      final before = layout.centers['p1'];
      layout.update(const MeshTopologySnapshot(
        localNodeId: 'local',
        revision: 1,
        nodes: [
          TopologyNode(
            id: 'local',
            label: 'This device',
            phase: TopologyNodePhase.local,
          ),
          TopologyNode(
            id: 'p1',
            label: 'Kofi',
            phase: TopologyNodePhase.connected,
          ),
          TopologyNode(
            id: 'p2',
            label: 'Ama',
            phase: TopologyNodePhase.connecting,
          ),
        ],
        links: [
          TopologyLink(
            sourceId: 'local',
            targetId: 'p1',
            state: TopologyLinkState.up,
          ),
          TopologyLink(
            sourceId: 'local',
            targetId: 'p2',
            state: TopologyLinkState.forming,
          ),
        ],
      ));
      expect(layout.centers.length, 3);
      expect(before, isNotNull);
      expect(layout.centers['p1'], isNotNull);
    });

    test('produces the same arrangement for the same peer set', () {
      final first = MeshLayout();
      final second = MeshLayout();
      first.update(_ringSnapshot(6));
      second.update(_ringSnapshot(6));

      expect(first.centers.keys.toSet(), second.centers.keys.toSet());
      for (final entry in first.centers.entries) {
        final other = second.centers[entry.key]!;
        expect(other.dx, closeTo(entry.value.dx, 1e-9));
        expect(other.dy, closeTo(entry.value.dy, 1e-9));
      }
    });

    test('does not drift when the same peers are published again', () {
      final layout = MeshLayout();
      layout.update(_ringSnapshot(5));
      final before = Map<String, Offset>.of(layout.centers);

      // New snapshot instance, new revision, identical peer set: no movement.
      layout.update(_ringSnapshot(5, revision: 9));

      expect(layout.centers, before);
    });

    test('never overlaps peers, adding a ring instead of squeezing', () {
      final layout = MeshLayout();
      const viewport = Size(360, 520);
      final topology = _ringSnapshot(10);
      layout.update(topology, viewport: viewport);

      final centers = layout.centers;
      final nodes = <String, TopologyNode>{
        for (final node in topology.nodes) node.id: node,
      };
      final ids = centers.keys.toList();
      expect(ids.length, 11);
      for (var i = 0; i < ids.length; i++) {
        for (var j = i + 1; j < ids.length; j++) {
          final a = centers[ids[i]]!;
          final b = centers[ids[j]]!;
          final minimum = layout.radiusFor(nodes[ids[i]]!) +
              layout.radiusFor(nodes[ids[j]]!);
          expect((a - b).distance, greaterThanOrEqualTo(minimum - 0.5));
        }
      }

      // Ten peers cannot fit on one phone-sized ring, so a second ring is used.
      final middle = Offset(viewport.width / 2, viewport.height / 2);
      final peerRadii = <double>{
        for (final entry in centers.entries)
          if (entry.key != 'local') (entry.value - middle).distance,
      };
      expect(peerRadii.length, greaterThan(1));
    });

    test('spreads peers further out on a larger canvas', () {
      final small = MeshLayout();
      final large = MeshLayout();
      const smallViewport = Size(320, 400);
      const largeViewport = Size(900, 700);
      small.update(_ringSnapshot(4), viewport: smallViewport);
      large.update(_ringSnapshot(4), viewport: largeViewport);

      double peerDistance(MeshLayout layout, Size viewport) =>
          (layout.centers['peer-0']! -
                  Offset(viewport.width / 2, viewport.height / 2))
              .distance;

      expect(
        peerDistance(large, largeViewport),
        greaterThan(peerDistance(small, smallViewport)),
      );
    });

    test('derives label width from the ring chord', () {
      final layout = MeshLayout();
      layout.update(_ringSnapshot(5));

      expect(layout.labelWidthFor('local'), 132);
      for (final id in layout.centers.keys) {
        expect(layout.labelWidthFor(id), greaterThanOrEqualTo(52));
        expect(layout.labelWidthFor(id), lessThanOrEqualTo(132));
      }
      // Five peers leave less room per slot than the centred local label gets.
      expect(layout.labelWidthFor('peer-0'), lessThan(132));
    });
  });
}

/// A phone-sized-ish mesh with a local node and [peerCount] connected peers.
MeshTopologySnapshot _ringSnapshot(int peerCount, {int revision = 1}) {
  return MeshTopologySnapshot(
    localNodeId: 'local',
    revision: revision,
    nodes: [
      const TopologyNode(
        id: 'local',
        label: 'This device',
        phase: TopologyNodePhase.local,
      ),
      for (var i = 0; i < peerCount; i++)
        TopologyNode(
          id: 'peer-$i',
          label: 'Peer $i',
          phase: TopologyNodePhase.connected,
          signalBars: 3,
        ),
    ],
    links: [
      for (var i = 0; i < peerCount; i++)
        TopologyLink(
          sourceId: 'local',
          targetId: 'peer-$i',
          state: TopologyLinkState.up,
        ),
    ],
  );
}

/// Collects the two independent streams of a [MeshTopologySource] so a test can
/// assert that hops arrive without any topology snapshot being emitted.
class _Recorder {
  _Recorder(MeshTopologySource source) {
    _hopSub = source.activity.listen(hops.add);
    _snapshotSub = source.changes.listen(snapshots.add);
  }

  final hops = <TopologyTransmission>[];
  final snapshots = <MeshTopologySnapshot>[];

  late final StreamSubscription<TopologyTransmission> _hopSub;
  late final StreamSubscription<MeshTopologySnapshot> _snapshotSub;

  Future<void> dispose() async {
    await _hopSub.cancel();
    await _snapshotSub.cancel();
  }
}
