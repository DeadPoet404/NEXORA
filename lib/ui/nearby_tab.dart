import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../mesh/transport.dart';
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
    final peersState = ref.watch(peersProvider);
    final peers = peersState.value ?? const <Peer>[];
    final transportStatus = ref.watch(transportStatusProvider).value;
    if (peersState.hasError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Could not load nearby peers: ${peersState.error}',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (peers.isEmpty) {
      final message = switch (transportStatus) {
        TransportStatus.bluetoothOff => 'Bluetooth is off. Turn it on to scan.',
        TransportStatus.permissionDenied =>
          'Bluetooth permission is required. Check the app permissions and retry.',
        TransportStatus.scanFailed =>
          'Bluetooth scanning failed. Retry from the banner above.',
        TransportStatus.unsupported =>
          'This device does not support Bluetooth Low Energy.',
        _ => 'Searching for LinkMesh devices… Keep both phones awake and nearby.',
      };
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                transportStatus == TransportStatus.running
                    ? Icons.bluetooth_searching
                    : Icons.bluetooth_disabled,
                size: 40,
              ),
              const SizedBox(height: 16),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              const Text(
                'Device IDs identify LinkMesh installations, not cryptographic identities.',
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
      PeerLinkState.discovered => (
          'Discovered · connecting when available',
          scheme.outline,
        ),
      PeerLinkState.disconnected => (
          'Disconnected · seen ${_seenAgo(peer.lastSeen)}',
          scheme.outline,
        ),
    };
    final nodeId = peer.nodeId;
    final trustRecord = trust.value;
    final trustLabel = trust.when(
      loading: () => 'Trust: loading',
      error: (_, _) => 'Trust status unavailable',
      data: (record) => switch (record?.status) {
        PeerTrustStatus.verified => 'QR fingerprint matched · messages plaintext',
        PeerTrustStatus.identityChanged => 'Identity changed · messaging restricted',
        PeerTrustStatus.blocked => 'Blocked · messaging restricted',
        _ => 'Identity not verified · messages plaintext',
      },
    );
    final details = [
      '$label · ${peer.rssi} dBm',
      trustLabel,
      if (peer.connectionError != null) peer.connectionError!,
    ].join('\n');
    return ListTile(
      leading: CircleAvatar(child: Icon(Icons.smartphone, color: color)),
      title: Text(peer.displayName),
      subtitle: Text(details),
      isThreeLine: peer.connectionError != null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SignalBars(
            bars: peer.bars,
            active: peer.state == PeerLinkState.connected,
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: trustRecord?.status == PeerTrustStatus.identityChanged
                ? 'Identity changed: QR verification locked'
                : trustRecord?.status == PeerTrustStatus.blocked
                    ? 'Peer blocked'
                    : 'Verify identity QR in person',
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
                      : trustRecord?.status == PeerTrustStatus.blocked
                          ? Icons.block
                          : Icons.qr_code_scanner,
              color: trustRecord?.status == PeerTrustStatus.verified
                  ? Colors.green
                  : trustRecord?.status == PeerTrustStatus.identityChanged ||
                          trustRecord?.status == PeerTrustStatus.blocked
                      ? scheme.error
                      : scheme.primary,
            ),
          ),
          if (nodeId != null)
            PopupMenuButton<String>(
              tooltip: 'Peer options',
              onSelected: (action) async {
                if (action != 'block') return;
                final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        icon: const Icon(Icons.block),
                        title: const Text('Block this peer?'),
                        content: Text(
                          'Messages from or to ${peer.displayName} will be '
                          'restricted on this device. This does not authenticate '
                          'the peer or turn off its BLE radio.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('Cancel'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Block peer'),
                          ),
                        ],
                      ),
                    ) ??
                    false;
                if (!confirmed || !context.mounted) return;
                try {
                  await ref.read(peerTrustRepositoryProvider).blockPeer(
                        nodeId,
                        nowMillis: DateTime.now().millisecondsSinceEpoch,
                      );
                  ref.invalidate(peerTrustRecordProvider(nodeId));
                } catch (error) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Could not block peer: $error')),
                  );
                }
              },
              itemBuilder: (context) => [
                if (trustRecord?.status != PeerTrustStatus.blocked)
                  const PopupMenuItem(
                    value: 'block',
                    child: Row(
                      children: [
                        Icon(Icons.block),
                        SizedBox(width: 8),
                        Text('Block peer'),
                      ],
                    ),
                  ),
                if (trustRecord?.status == PeerTrustStatus.blocked)
                  const PopupMenuItem(
                    enabled: false,
                    child: Text('Blocked · cannot be restored in this build'),
                  ),
              ],
            ),
        ],
      ),
      enabled: nodeId != null,
      onTap: nodeId == null
          ? null
          : () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) =>
                    ChatScreen(peerId: nodeId, initialName: peer.name),
              )),
    );
  }
}

String _seenAgo(DateTime lastSeen) {
  final age = DateTime.now().difference(lastSeen);
  if (age.inSeconds < 60) return 'just now';
  if (age.inMinutes < 60) return '${age.inMinutes}m ago';
  if (age.inHours < 24) return '${age.inHours}h ago';
  return '${age.inDays}d ago';
}
