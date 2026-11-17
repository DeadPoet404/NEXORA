import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/message_store.dart';
import '../data/peer_registry.dart';
import '../mesh/mesh_router.dart';
import '../mesh/transport.dart';
import '../models/node_identity.dart';
import '../models/peer.dart';
import '../models/stored_message.dart';
import '../security/backend_contracts.dart';
import '../security/peer_trust.dart';
import '../services/alert_service.dart';
import '../services/identity_service.dart';
import '../services/mesh_bridge.dart';
import '../services/mesh_controller.dart';
import '../services/sos_service.dart';

// Services are created in main() and injected via overrides.
final storeProvider = Provider<MessageStore>((_) => throw UnimplementedError());
final peerTrustRepositoryProvider =
    Provider<PeerTrustRepository>((_) => throw UnimplementedError());
final peerRegistryProvider =
    Provider<PeerRegistry>((_) => throw UnimplementedError());
final localIdentityProvider =
    Provider<LocalIdentityProvider>((_) => throw UnimplementedError());
final peerTrustServiceProvider = Provider<PeerTrustService>(
  (ref) => PeerTrustService(repository: ref.watch(peerTrustRepositoryProvider)),
);
final peerTrustRecordProvider =
    StreamProvider.family<PeerTrustRecord?, String>((ref, peerId) {
  final repository = ref.watch(peerTrustRepositoryProvider);
  final store = ref.watch(storeProvider);
  return _watchPeerTrust(repository, store.changes, peerId);
});
final transportProvider =
    Provider<MeshTransport>((_) => throw UnimplementedError());
final routerProvider = Provider<MeshRouter>((_) => throw UnimplementedError());
final identityServiceProvider =
    Provider<IdentityService>((_) => throw UnimplementedError());
final sosServiceProvider =
    Provider<SosService>((_) => throw UnimplementedError());
final bridgeProvider = Provider<MeshBridge>((_) => throw UnimplementedError());
final alertServiceProvider =
    Provider<AlertService>((_) => throw UnimplementedError());
final meshControllerProvider =
    Provider<MeshController>((_) => throw UnimplementedError());

/// Emits the current value first, then every change.
Stream<T> _seeded<T>(T current, Stream<T> changes) async* {
  yield current;
  yield* changes;
}

/// Re-runs [query] whenever the store changes.
Stream<T> _watchStore<T>(MessageStore store, Future<T> Function() query) async* {
  yield await query();
  await for (final _ in store.changes) {
    yield await query();
  }
}

Stream<PeerTrustRecord?> _watchPeerTrust(
  PeerTrustRepository repository,
  Stream<void> changes,
  String peerId,
) async* {
  yield await repository.getPeerTrust(peerId);
  await for (final _ in changes) {
    yield await repository.getPeerTrust(peerId);
  }
}

Stream<List<Peer>> _watchMergedPeers(
  MeshTransport transport,
  PeerRegistry registry,
  Stream<void> storeChanges,
) async* {
  final updates = StreamController<List<Peer>>();
  var livePeers = transport.peers;

  Future<void> emit() async {
    final remembered = await registry.knownPeers();
    final peers = mergePeerViews(
      remembered: remembered,
      live: livePeers,
    );
    if (!updates.isClosed) updates.add(peers);
  }

  final peerSub = transport.peerChanges.listen((peers) {
    livePeers = peers;
    unawaited(emit());
  }, onError: updates.addError);
  final storeSub = storeChanges.listen((_) => unawaited(emit()),
      onError: updates.addError);
  try {
    await emit();
    yield* updates.stream;
  } finally {
    await peerSub.cancel();
    await storeSub.cancel();
    await updates.close();
  }
}

final identityProvider = StreamProvider<NodeIdentity>((ref) {
  final service = ref.watch(identityServiceProvider);
  return _seeded(service.current, service.changes);
});

final transportStatusProvider = StreamProvider<TransportStatus>((ref) {
  final transport = ref.watch(transportProvider);
  return _seeded(transport.status, transport.statusChanges);
});

final peersProvider = StreamProvider<List<Peer>>((ref) {
  final transport = ref.watch(transportProvider);
  final registry = ref.watch(peerRegistryProvider);
  final store = ref.watch(storeProvider);
  return _watchMergedPeers(transport, registry, store.changes);
});

final conversationsProvider = StreamProvider<List<ConversationSummary>>((ref) {
  final store = ref.watch(storeProvider);
  return _watchStore(store, store.conversations);
});

final conversationProvider =
    StreamProvider.family<List<StoredMessage>, String>((ref, peerId) {
  final store = ref.watch(storeProvider);
  return _watchStore(store, () => store.conversation(peerId));
});

final sosAlertsProvider = StreamProvider<List<StoredMessage>>((ref) {
  final store = ref.watch(storeProvider);
  return _watchStore(store, store.sosAlerts);
});

final sosActiveProvider = StreamProvider<bool>((ref) {
  final sos = ref.watch(sosServiceProvider);
  return _seeded(sos.isActive, sos.activeChanges);
});

/// Best display name for a node: live peer name, else the name it last used
/// in a message, else a short id.
String nameFor(String nodeId, List<Peer> peers, [String? fallback]) {
  for (final p in peers) {
    if (p.nodeId == nodeId && (p.name?.isNotEmpty ?? false)) return p.name!;
  }
  if (fallback != null && fallback.isNotEmpty) return fallback;
  return nodeId.length > 8 ? nodeId.substring(0, 8) : nodeId;
}
