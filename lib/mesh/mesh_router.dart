import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../core/constants.dart';
import '../data/message_store.dart';
import '../models/mesh_message.dart';
import '../models/node_identity.dart';
import '../models/stored_message.dart';
import '../security/peer_trust.dart';
import 'seen_cache.dart';
import 'transport.dart';

/// Flood-based mesh routing.
///
/// Every node rebroadcasts messages not addressed to it until `max_hops` is
/// spent, suppressing duplicates by message id. Recent messages are retained
/// in the persistent relay queue and replayed to newly linked peers, so queued
/// messages survive process restarts as well as broken links.
///
/// Delivery status for our own messages:
/// * sent      – a neighbour accepted the frame
/// * relayed   – we heard a neighbour forward it (hop_count > 0 echo)
/// * delivered – the recipient's ack came back
class MeshRouter {
  MeshRouter({
    required this.transport,
    required this.store,
    required this.identity,
    required this.messagingPolicy,
    DateTime Function()? clock,
  })  : _now = clock ?? DateTime.now,
        _seen = SeenCache(
          ttl: MeshConstants.seenTtl,
          maxEntries: MeshConstants.seenMaxEntries,
          clock: clock,
        );

  final MeshTransport transport;
  final MessageStore store;
  final PeerMessagingPolicy messagingPolicy;
  final DateTime Function() _now;
  final SeenCache _seen;
  final _uuid = const Uuid();

  /// Updated when the user renames themselves.
  NodeIdentity identity;

  // Insertion-ordered so the oldest entries are pruned first.
  final _buffer = <String, _Buffered>{};
  final _processing = <String>{};
  final _subscriptions = <StreamSubscription<Object?>>[];
  Future<void> _ready = Future.value();
  bool _started = false;
  final _sosAlerts = StreamController<StoredMessage>.broadcast();
  final _incoming = StreamController<StoredMessage>.broadcast();

  /// Fires for each new SOS received from another node.
  Stream<StoredMessage> get sosAlerts => _sosAlerts.stream;

  /// Fires for each new chat message addressed to this node.
  Stream<StoredMessage> get incomingMessages => _incoming.stream;

  void start() {
    if (_started) return;
    _started = true;
    _ready = _restoreBuffer();
    _subscriptions
      ..add(transport.incoming.listen(
        (bytes) => unawaited(_handleFrameSafely(bytes)),
      ))
      ..add(transport.peerLinked.listen(
        (peerId) => unawaited(_flushSafely(peerId)),
      ));
  }

  Future<void> _restoreBuffer() async {
    final entries = await store.loadRelayQueue(_now().millisecondsSinceEpoch);
    for (final entry in entries) {
      _buffer[entry.message.id] = _Buffered(
        entry.message,
        DateTime.fromMillisecondsSinceEpoch(entry.expiresAtMillis),
      );
      _seen.add(entry.message.id);
    }
  }

  Future<void> dispose() async {
    await _ready;
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
    await _sosAlerts.close();
    await _incoming.close();
  }

  Future<StoredMessage> sendText(String peerId, String text) =>
      _originate(MessageType.text, peerId, text);

  Future<StoredMessage> sendSos(String text, {double? lat, double? lng}) =>
      _originate(
        MessageType.sos,
        MeshConstants.broadcastId,
        text,
        lat: lat,
        lng: lng,
      );

  Future<StoredMessage> _originate(
    MessageType type,
    String receiverId,
    String content, {
    double? lat,
    double? lng,
  }) async {
    await _ready;
    if (utf8.encode(content).length > MeshConstants.maxContentBytes) {
      throw ArgumentError('Message content is too large for a BLE frame');
    }
    if (receiverId != MeshConstants.broadcastId) {
      await _requireMessagingAllowed(receiverId);
    }
    final message = MeshMessage(
      id: _uuid.v4(),
      type: type,
      senderId: identity.id,
      senderName: identity.name,
      receiverId: receiverId,
      timestamp: _now().millisecondsSinceEpoch,
      content: content,
      lat: lat,
      lng: lng,
    );
    _seen.add(message.id);
    await _prune();
    final enqueuedAt = _now();
    final expiresAt = enqueuedAt.add(MeshConstants.relayBufferTtl);
    await store.saveOutgoingAndEnqueueRelay(
      storedMessage: StoredMessage(message: message, outgoing: true),
      enqueuedAtMillis: enqueuedAt.millisecondsSinceEpoch,
      expiresAtMillis: expiresAt.millisecondsSinceEpoch,
    );
    _cacheRelay(message, expiresAt);
    try {
      if (await _broadcast(message) > 0) {
        await _advance(message.id, DeliveryStatus.sent);
      }
    } catch (error, stackTrace) {
      // The durable outbox write already succeeded. Keep it queued for a
      // reconnect rather than telling the user that the message was lost.
      Zone.current.print('LinkMesh: message ${message.id} remains queued: '
          '$error\n$stackTrace');
    }
    return (await store.get(message.id))!;
  }

  Future<void> _handleFrameSafely(Uint8List bytes) async {
    try {
      await _onFrame(bytes);
    } catch (error, stackTrace) {
      // Stream callbacks have no caller to receive asynchronous failures.
      // Keep the exception visible in diagnostics rather than creating an
      // unhandled zone error that can terminate unrelated message handling.
      Zone.current.print('LinkMesh: inbound frame failed: $error\n$stackTrace');
    }
  }

  Future<void> _onFrame(Uint8List bytes) async {
    await _ready;
    final message = MeshMessage.tryDecode(bytes);
    if (message == null) return;

    if (message.senderId == identity.id) {
      // Our own message coming back: proof a neighbour relayed it.
      if (message.hopCount > 0 && message.type != MessageType.ack) {
        await _advance(message.id, DeliveryStatus.relayed);
      }
      return;
    }
    if (await messagingPolicy.isMessagingRestricted(message.senderId)) return;

    // Reserve synchronously before the first await so concurrent copies cannot
    // process together; only remember the ID after durable side effects succeed.
    if (_seen.contains(message.id) || !_processing.add(message.id)) return;
    try {
      final existing = await store.get(message.id);
      final forMe = message.receiverId == identity.id;
      if (existing != null) {
        if (!_sameMessageBody(existing.message, message)) {
          _seen.add(message.id);
          return;
        }
        if (message.type == MessageType.text && forMe && !existing.outgoing) {
          await _ensureAck(message);
        } else if (!forMe || message.type == MessageType.sos) {
          await _relay(message);
        }
        _seen.add(message.id);
        return;
      }

      switch (message.type) {
        case MessageType.text:
          if (forMe) {
            final stored = StoredMessage(
              message: message,
              outgoing: false,
              relayHops: message.hopCount,
            );
            await store.save(stored);
            _incoming.add(stored);
            await _ensureAck(message);
          } else {
            await _relay(message);
          }
        case MessageType.ack:
          if (forMe) {
            await _onAck(message);
          } else {
            final refId = message.refId;
            final relayedMessage = refId == null ? null : _buffer[refId];
            if (relayedMessage != null &&
                relayedMessage.message.receiverId == message.senderId) {
              await _forgetRelay(refId);
            }
            await _relay(message);
          }
        case MessageType.sos:
          final stored = StoredMessage(
            message: message,
            outgoing: false,
            relayHops: message.hopCount,
          );
          await store.save(stored);
          _sosAlerts.add(stored);
          await _relay(message);
      }
      _seen.add(message.id);
    } finally {
      _processing.remove(message.id);
    }
  }

  Future<void> _relay(MeshMessage message) async {
    if (!message.canRelay) return;
    final forwarded = message.relayed();
    await _remember(forwarded);
    await _broadcast(forwarded);
  }

  bool _sameMessageBody(MeshMessage a, MeshMessage b) =>
      a.id == b.id &&
      a.type == b.type &&
      a.senderId == b.senderId &&
      a.senderName == b.senderName &&
      a.receiverId == b.receiverId &&
      a.timestamp == b.timestamp &&
      a.content == b.content &&
      a.maxHops == b.maxHops &&
      a.refId == b.refId &&
      a.lat == b.lat &&
      a.lng == b.lng;

  Future<void> _ensureAck(MeshMessage original) async {
    await _prune();
    final hasQueuedAck = _buffer.values.any((entry) =>
        entry.message.type == MessageType.ack &&
        entry.message.refId == original.id);
    if (!hasQueuedAck) await _sendAck(original);
  }

  Future<void> _sendAck(MeshMessage original) async {
    final ack = MeshMessage(
      id: _uuid.v4(),
      type: MessageType.ack,
      senderId: identity.id,
      senderName: identity.name,
      receiverId: original.senderId,
      timestamp: _now().millisecondsSinceEpoch,
      content: '${original.hopCount}',
      refId: original.id,
      maxHops: original.maxHops,
    );
    _seen.add(ack.id);
    await _remember(ack);
    await _broadcast(ack);
  }

  Future<void> _onAck(MeshMessage ack) async {
    final refId = ack.refId;
    if (refId == null) return;
    await _serializeStatusWrite(refId, () async {
      final accepted = await store.completeOutgoingDelivery(
        messageId: refId,
        recipientId: ack.senderId,
        relayHops: int.tryParse(ack.content) ?? 0,
      );
      if (accepted) _buffer.remove(refId);
    });
  }

  /// Moves an outgoing message's status forward, never backward, serializing
  /// competing sent/relayed/ack updates so a delayed write cannot regress it.
  Future<void> _advance(
    String id,
    DeliveryStatus status, {
    int? relayHops,
  }) =>
      _serializeStatusWrite(id, () async {
        final stored = await store.get(id);
        if (stored == null || !stored.outgoing) return;
        final nextStatus = stored.status.index >= status.index
            ? stored.status
            : status;
        await store.save(stored.copyWith(
          status: nextStatus,
          relayHops: relayHops ?? stored.relayHops,
        ));
      });

  Future<void> _serializeStatusWrite(
    String id,
    Future<void> Function() update,
  ) async {
    final previous = _statusWrites[id] ?? Future<void>.value();
    late final Future<void> next;
    next = previous.catchError((_) {}).then((_) => update());
    _statusWrites[id] = next;
    try {
      await next;
    } finally {
      if (identical(_statusWrites[id], next)) _statusWrites.remove(id);
    }
  }

  final _statusWrites = <String, Future<void>>{};

  Future<void> _remember(MeshMessage message) async {
    await _prune();
    final now = _now();
    final expiresAt = now.add(MeshConstants.relayBufferTtl);
    await store.enqueueRelay(
      message: message,
      enqueuedAtMillis: now.millisecondsSinceEpoch,
      expiresAtMillis: expiresAt.millisecondsSinceEpoch,
    );
    _cacheRelay(message, expiresAt);
  }

  void _cacheRelay(MeshMessage message, DateTime expiresAt) {
    _buffer.remove(message.id);
    _buffer[message.id] = _Buffered(message, expiresAt);
    while (_buffer.length > MeshConstants.relayBufferMaxSize) {
      _buffer.remove(_buffer.keys.first);
    }
  }

  Future<void> _forgetRelay(String? messageId) async {
    if (messageId == null) return;
    _buffer.remove(messageId);
    await store.removeRelay(messageId);
  }

  Future<void> _prune() async {
    final now = _now();
    final expiredIds = _buffer.entries
        .where((entry) => !entry.value.expiresAt.isAfter(now))
        .map((entry) => entry.key)
        .toList();
    for (final id in expiredIds) {
      await _serializeStatusWrite(id, () => store.expireOutgoingMessage(id));
      _buffer.remove(id);
    }
  }

  Future<void> _flushSafely(String nodeId) async {
    try {
      await _flushTo(nodeId);
    } catch (error, stackTrace) {
      Zone.current.print('LinkMesh: queued delivery to $nodeId failed: '
          '$error\n$stackTrace');
    }
  }

  Future<void> _flushTo(String nodeId) async {
    await _ready;
    if (await messagingPolicy.isMessagingRestricted(nodeId)) return;
    await _prune();
    for (final entry in _buffer.values.toList()) {
      final message = entry.message;
      if (message.senderId == nodeId) continue;
      if (message.senderId == identity.id &&
          message.type == MessageType.text &&
          await messagingPolicy.isMessagingRestricted(message.receiverId)) {
        continue;
      }
      final ok = await transport.sendTo(nodeId, message.encode());
      if (ok && message.senderId == identity.id) {
        await _advance(message.id, DeliveryStatus.sent);
      }
    }
  }

  Future<void> _requireMessagingAllowed(String peerId) async {
    if (await messagingPolicy.isMessagingRestricted(peerId)) {
      throw PeerTrustException('Messaging is restricted for peer $peerId');
    }
  }

  Future<int> _broadcast(MeshMessage message) async {
    if (message.senderId == identity.id &&
        message.type == MessageType.text &&
        await messagingPolicy.isMessagingRestricted(message.receiverId)) {
      return 0;
    }
    final excluded = <String>{};
    for (final peer in transport.peers) {
      final peerId = peer.nodeId;
      if (peerId != null &&
          await messagingPolicy.isMessagingRestricted(peerId)) {
        excluded.add(peerId);
      }
    }
    return transport.broadcast(
      message.encode(),
      excludeNodeIds: excluded,
    );
  }
}

class _Buffered {
  _Buffered(this.message, this.expiresAt);
  final MeshMessage message;
  final DateTime expiresAt;
}
