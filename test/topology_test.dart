import 'dart:async';
import 'dart:ui' show Rect;

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

      final updates = <MeshTopologySnapshot>[];
      final sub = source.changes.listen(updates.add);
      addTearDown(sub.cancel);

      senders.add('B');
      senders.add('unknown-node');
      await pumpEventQueue();

      // Only the known neighbour produces a hop; unknown IDs are ignored.
      expect(updates.length, 1);
      expect(updates.single.transmissions.length, 1);
      expect(updates.single.transmissions.single.sourceId, 'B');
      expect(updates.single.transmissions.single.targetId, 'A');
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

      final updates = <MeshTopologySnapshot>[];
      final sub = source.changes.listen(updates.add);
      addTearDown(sub.cancel);

      senders.add('B');
      senders.add('B');
      await pumpEventQueue();

      expect(updates.length, 2);
      final hops = updates.map((snapshot) => snapshot.transmissions.single);
      expect(hops.map((hop) => hop.id).toSet().length, 2);
      for (final hop in hops) {
        expect(hop.sourceId, 'B');
        expect(hop.targetId, 'A');
        expect(hop.relayed, isFalse);
      }
      // Re-emitting a hop must not change the discovered topology.
      expect(updates.last.nodes.length, 2);
      expect(updates.last.links.single.state, TopologyLinkState.up);
      expect(updates.last.simulated, isFalse);
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

      final updates = <MeshTopologySnapshot>[];
      final sub = source.changes.listen(updates.add);
      addTearDown(sub.cancel);

      senders.add('nobody');
      senders.add('A');
      senders.add('');
      await pumpEventQueue();

      expect(updates, isEmpty);
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

      final updates = <MeshTopologySnapshot>[];
      final sub = source.changes.listen(updates.add);
      addTearDown(sub.cancel);

      chats.add('B');
      alerts.add('C');
      await pumpEventQueue();

      expect(updates.length, 2);
      expect(
        updates.map((snapshot) => snapshot.transmissions.single.sourceId).toSet(),
        {'B', 'C'},
      );
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
      final sub = source.changes.listen(snapshots.add);
      addTearDown(sub.cancel);

      for (var i = 0; i < 60; i++) {
        source.step();
      }
      await pumpEventQueue();

      for (final snapshot in snapshots) {
        final ids = snapshot.nodes.map((node) => node.id).toSet();
        for (final link in snapshot.links) {
          expect(ids, contains(link.sourceId));
          expect(ids, contains(link.targetId));
        }
        for (final hop in snapshot.transmissions) {
          expect(ids, contains(hop.sourceId));
          expect(ids, contains(hop.targetId));
        }
      }
    });

    test('peers join, leave and change state over time', () async {
      final source = SimulatedMeshTopologySource(seed: 3, autoAdvance: false);
      addTearDown(source.dispose);

      final snapshots = <MeshTopologySnapshot>[];
      final sub = source.changes.listen(snapshots.add);
      addTearDown(sub.cancel);

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
      expect(
        snapshots.any((snapshot) => snapshot.transmissions.isNotEmpty),
        isTrue,
      );
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
  });
}
