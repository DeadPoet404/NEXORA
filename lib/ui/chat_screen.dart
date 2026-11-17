import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/peer.dart';
import '../security/peer_trust.dart';
import '../services/alert_service.dart';
import '../state/providers.dart';
import 'widgets/message_bubble.dart';
import 'widgets/plaintext_security_notice.dart';
import 'widgets/signal_bars.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.peerId, this.initialName});

  final String peerId;
  final String? initialName;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _input = TextEditingController();
  late final AlertService _alerts;

  @override
  void initState() {
    super.initState();
    // While this chat is open, new messages from this peer just chime.
    _alerts = ref.read(alertServiceProvider)..openChatPeer = widget.peerId;
    ref.read(bridgeProvider).cancelMessageNotification(widget.peerId);
  }

  @override
  void dispose() {
    if (_alerts.openChatPeer == widget.peerId) _alerts.openChatPeer = null;
    _input.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    try {
      await ref.read(routerProvider).sendText(widget.peerId, text);
      if (_input.text.trim() == text) _input.clear();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Message was not queued: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final peers = ref.watch(peersProvider).value ?? const <Peer>[];
    final messages = ref.watch(conversationProvider(widget.peerId));
    final trustState = ref.watch(peerTrustRecordProvider(widget.peerId));
    final trustRecord = trustState.value;
    final restricted = trustState.isLoading ||
        trustState.hasError ||
        trustRecord?.status == PeerTrustStatus.blocked ||
        trustRecord?.status == PeerTrustStatus.identityChanged;
    final peer = peers.where((p) => p.nodeId == widget.peerId).firstOrNull;
    final name = nameFor(widget.peerId, peers, widget.initialName);
    final trustLabel = trustState.when(
      loading: () => 'Checking peer status',
      error: (error, _) => 'Peer status unavailable: $error',
      data: (record) => switch (record?.status) {
        PeerTrustStatus.verified => 'QR fingerprint matched · messages plaintext',
        PeerTrustStatus.identityChanged => 'Identity changed · messaging blocked',
        PeerTrustStatus.blocked => 'Blocked · messaging blocked',
        _ => 'Not QR verified · plaintext',
      },
    );

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name),
            Text(
              '${switch (peer?.quality) {
                SignalQuality.connected => 'Connected directly',
                SignalQuality.weak => 'Weak signal',
                _ => 'Not in direct range · will relay via mesh',
              }} · $trustLabel',
              style: Theme.of(context).textTheme.labelSmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: [
          if (peer != null)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: SignalBars(
                bars: peer.bars,
                active: peer.state == PeerLinkState.connected,
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          const PlaintextSecurityNotice(),
          if (restricted)
            Material(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  trustState.hasError
                      ? 'Peer trust status could not be checked. Sending is disabled.'
                      : trustRecord?.status == PeerTrustStatus.blocked
                          ? 'This peer is blocked. Messages are disabled.'
                          : trustRecord?.status == PeerTrustStatus.identityChanged
                              ? 'Peer identity changed. Messaging is restricted pending review.'
                              : 'Checking peer trust state…',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          Expanded(
            child: messages.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Could not load: $e')),
              data: (list) => list.isEmpty
                  ? const Center(child: Text('No messages yet. Say hello.'))
                  : ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: list.length,
                      itemBuilder: (_, i) =>
                          MessageBubble(message: list[list.length - 1 - i]),
                    ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      enabled: !restricted,
                      minLines: 1,
                      maxLines: 4,
                      maxLength: 500,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: restricted ? 'Messaging unavailable' : 'Message',
                        counterText: '',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(24)),
                        ),
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton.filled(
                    onPressed: restricted ? null : _send,
                    icon: const Icon(Icons.send),
                    tooltip: 'Send',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
