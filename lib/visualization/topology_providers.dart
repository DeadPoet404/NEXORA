import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'simulated_topology_source.dart';
import 'topology_source.dart';

/// Builds the topology source the network view draws.
///
/// [simulated] must be true only for development builds; the UI hides that
/// switch in release builds, so a shipped app can only ever show real BLE
/// discovery state. The provider is auto-disposed so leaving the tab stops the
/// simulation timer or the transport subscription.
final topologySourceProvider =
    Provider.autoDispose.family<MeshTopologySource, bool>((ref, simulated) {
  final MeshTopologySource source;
  if (simulated) {
    source = SimulatedMeshTopologySource();
  } else {
    final transport = ref.watch(transportProvider);
    final identity = ref.watch(identityServiceProvider).current;
    final router = ref.watch(routerProvider);
    source = LiveMeshTopologySource(
      transport: transport,
      localNodeId: identity.id,
      localName: identity.name,
      // Read-only taps into the router's public stream: hops are animated, but
      // nothing about routing or message handling changes.
      incomingSenderIds: router.incomingMessages.map((m) => m.message.senderId),
    );
  }
  ref.onDispose(() => unawaited(source.dispose()));
  return source;
});
