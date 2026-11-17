import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/peer.dart';
import '../security/peer_trust.dart';
import '../state/providers.dart';
import 'chat_screen.dart';
import 'verify_peer_qr_screen.dart';
import 'widgets/signal_bars.dart';

class NearbyTab extends ConsumerWidget {
  const NearbyTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final peers = ref.watch(peersProvider).value ?? const <Peer>[];
    if (peers.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: 32,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              SizedBox(height: 16),
              Text(
                'Looking for nearby LinkMesh devices…\n'
                'Keep the app open on both phones, within ~30 m.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    return ListView.separated(
      itemCount: peers.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) => _PeerTile(peer: peers[i]),
    );
  }
}

class _PeerTile extends ConsumerWidget {
  const _PeerTile({required this.peer});

  final Peer peer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final trust = peer.nodeId == null
        ? const AsyncValue<PeerTrustRecord?>.data(null)
        : ref.watch(peerTrustRecordProvider(peer.nodeId!));
    final (label, color) = switch (peer.state) {
      PeerLinkState.connected => peer.quality == SignalQuality.weak
          ? ('Weak signal', scheme.error)
          : ('Connected', Colors.green),
      PeerLinkState.connecting => ('Connecting…', scheme.outline),
      PeerLinkState.discovered => ('In range', scheme.outline),
      PeerLinkState.disconnected => ('Disconnected', scheme.outline),
    };
    final nodeId = peer.nodeId;
    final trustRecord = trust.value;
    final trustLabel = trust.when(
      loading: () => 'Trust: loading',
      error: (_, _) => 'Trust status unavailable',
      data: (record) => switch (record?.status) {
        PeerTrustStatus.verified => 'Identity verified',
        PeerTrustStatus.identityChanged => 'Identity changed · locked',
        PeerTrustStatus.blocked => 'Blocked',
        _ => 'Identity not verified',
      },
    );
    return ListTile(
      leading: CircleAvatar(child: Icon(Icons.smartphone, color: color)),
      title: Text(peer.displayName),
      subtitle: Text('$label · ${peer.rssi} dBm\n$trustLabel'),
      isThreeLine: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SignalBars(
            bars: peer.bars,
            active: peer.state == PeerLinkState.connected,
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: trustRecord?.status == PeerTrustStatus.identityChanged
                ? 'Identity changed: QR verification locked'
                : 'Verify identity QR',
            onPressed: nodeId == null ||
                    trustRecord?.status == PeerTrustStatus.identityChanged ||
                    trustRecord?.status == PeerTrustStatus.blocked
                ? null
                : () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => VerifyPeerQrScreen(peerId: nodeId),
                    )),
            icon: Icon(
              trustRecord?.status == PeerTrustStatus.verified
                  ? Icons.verified_user
                  : trustRecord?.status == PeerTrustStatus.identityChanged
                      ? Icons.gpp_bad
                      : Icons.qr_code_scanner,
              color: trustRecord?.status == PeerTrustStatus.verified
                  ? Colors.green
                  : trustRecord?.status == PeerTrustStatus.identityChanged
                      ? scheme.error
                      : scheme.primary,
            ),
          ),
          Icon(
            Icons.chat_bubble_outline,
            color: nodeId == null ? scheme.outlineVariant : scheme.primary,
          ),
        ],
      ),
      // A peer is chattable once we've read its node id.
      enabled: nodeId != null,
      onTap: nodeId == null
          ? null
          : () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) =>
                    ChatScreen(peerId: nodeId, initialName: peer.name),
              )),
    );
  }
}
