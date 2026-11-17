import 'dart:async';

import '../core/constants.dart';
import '../models/mesh_message.dart';
import '../models/stored_message.dart';

/// A message retained for later mesh forwarding.
class RelayQueueEntry {
  const RelayQueueEntry({
    required this.message,
    required this.enqueuedAtMillis,
    required this.expiresAtMillis,
  });

  final MeshMessage message;
  final int enqueuedAtMillis;
  final int expiresAtMillis;
}

/// Persistence for chat/SOS messages and the durable store-and-forward queue.
/// The router depends on this interface so it can be tested without a database.
abstract class MessageStore {
  /// Fires after any write.
  Stream<void> get changes;

  Future<StoredMessage?> get(String id);

  /// Inserts or replaces by message id.
  Future<void> save(StoredMessage message);

  /// Atomically advances an outgoing message to delivered and removes its
  /// durable relay entry only when the receipt peer is the intended recipient.
  Future<bool> completeOutgoingDelivery({
    required String messageId,
    required String recipientId,
    required int relayHops,
  });

  /// Marks an undelivered outgoing message expired and removes its relay entry.
  Future<void> expireOutgoingMessage(String messageId);

  /// Atomically stores a newly originated outgoing message and its relay queue
  /// entry, so a process death cannot leave a saved but unsendable message.
  Future<void> saveOutgoingAndEnqueueRelay({
    required StoredMessage storedMessage,
    required int enqueuedAtMillis,
    required int expiresAtMillis,
  });

  /// Adds a wire message to the durable relay queue, retaining the most recent
  /// [MeshConstants.relayBufferMaxSize] entries.
  Future<void> enqueueRelay({
    required MeshMessage message,
    required int enqueuedAtMillis,
    required int expiresAtMillis,
  });

  /// Removes expired entries and returns the remaining queue in oldest-first
  /// order. Implementations also trim the queue to the configured maximum.
  Future<List<RelayQueueEntry>> loadRelayQueue(int nowMillis);

  Future<void> removeRelay(String messageId);

  Future<List<StoredMessage>> conversation(String peerId);
  Future<List<ConversationSummary>> conversations();

  /// Latest SOS per sender, newest first.
  Future<List<StoredMessage>> sosAlerts();

  Future<String?> getSetting(String key);
  Future<void> setSetting(String key, String value);
}

/// In-memory store for tests and previews. Its relay queue survives router
/// recreation when the same store instance is reused; it does not model disk.
class InMemoryMessageStore implements MessageStore {
  final _messages = <String, StoredMessage>{};
  final _relayQueue = <String, RelayQueueEntry>{};
  final _settings = <String, String>{};
  final _changes = StreamController<void>.broadcast();

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<StoredMessage?> get(String id) async => _messages[id];

  @override
  Future<void> save(StoredMessage message) async {
    _messages[message.id] = message;
    _changes.add(null);
  }

  @override
  Future<bool> completeOutgoingDelivery({
    required String messageId,
    required String recipientId,
    required int relayHops,
  }) async {
    final stored = _messages[messageId];
    if (stored == null ||
        !stored.outgoing ||
        stored.message.receiverId != recipientId) {
      return false;
    }
    _messages[messageId] = stored.copyWith(
      status: DeliveryStatus.delivered,
      relayHops: relayHops,
    );
    _relayQueue.remove(messageId);
    _changes.add(null);
    return true;
  }

  @override
  Future<void> expireOutgoingMessage(String messageId) async {
    final stored = _messages[messageId];
    if (stored != null &&
        stored.outgoing &&
        stored.status != DeliveryStatus.delivered) {
      _messages[messageId] = stored.copyWith(status: DeliveryStatus.expired);
    }
    _relayQueue.remove(messageId);
    _changes.add(null);
  }

  @override
  Future<void> saveOutgoingAndEnqueueRelay({
    required StoredMessage storedMessage,
    required int enqueuedAtMillis,
    required int expiresAtMillis,
  }) async {
    _messages[storedMessage.id] = storedMessage;
    _putRelay(
      storedMessage.message,
      enqueuedAtMillis: enqueuedAtMillis,
      expiresAtMillis: expiresAtMillis,
    );
    _changes.add(null);
  }

  @override
  Future<void> enqueueRelay({
    required MeshMessage message,
    required int enqueuedAtMillis,
    required int expiresAtMillis,
  }) async {
    _putRelay(
      message,
      enqueuedAtMillis: enqueuedAtMillis,
      expiresAtMillis: expiresAtMillis,
    );
    _changes.add(null);
  }

  void _putRelay(
    MeshMessage message, {
    required int enqueuedAtMillis,
    required int expiresAtMillis,
  }) {
    _relayQueue.remove(message.id);
    _relayQueue[message.id] = RelayQueueEntry(
      message: message,
      enqueuedAtMillis: enqueuedAtMillis,
      expiresAtMillis: expiresAtMillis,
    );
    while (_relayQueue.length > MeshConstants.relayBufferMaxSize) {
      _relayQueue.remove(_relayQueue.keys.first);
    }
  }

  @override
  Future<List<RelayQueueEntry>> loadRelayQueue(int nowMillis) async {
    final expiredIds = _relayQueue.entries
        .where((entry) => entry.value.expiresAtMillis <= nowMillis)
        .map((entry) => entry.key)
        .toList();
    for (final id in expiredIds) {
      await expireOutgoingMessage(id);
    }
    while (_relayQueue.length > MeshConstants.relayBufferMaxSize) {
      _relayQueue.remove(_relayQueue.keys.first);
    }
    return _relayQueue.values.toList();
  }

  @override
  Future<void> removeRelay(String messageId) async {
    if (_relayQueue.remove(messageId) != null) _changes.add(null);
  }

  Iterable<StoredMessage> get _chats =>
      _messages.values.where((m) => m.message.type == MessageType.text);

  @override
  Future<List<StoredMessage>> conversation(String peerId) async =>
      _chats.where((m) => m.peerId == peerId).toList()
        ..sort((a, b) => a.message.timestamp.compareTo(b.message.timestamp));

  @override
  Future<List<ConversationSummary>> conversations() async {
    final latest = <String, StoredMessage>{};
    final names = <String, String>{};
    for (final m in _chats) {
      final current = latest[m.peerId];
      if (current == null || m.message.timestamp > current.message.timestamp) {
        latest[m.peerId] = m;
      }
      if (!m.outgoing) names[m.peerId] = m.message.senderName;
    }
    return latest.entries
        .map((e) => ConversationSummary(
              peerId: e.key,
              peerName: names[e.key] ?? '',
              lastMessage: e.value,
            ))
        .toList()
      ..sort((a, b) => b.lastMessage.message.timestamp
          .compareTo(a.lastMessage.message.timestamp));
  }

  @override
  Future<List<StoredMessage>> sosAlerts() async {
    final latest = <String, StoredMessage>{};
    for (final m in _messages.values) {
      if (m.message.type != MessageType.sos || m.outgoing) continue;
      final current = latest[m.message.senderId];
      if (current == null || m.message.timestamp > current.message.timestamp) {
        latest[m.message.senderId] = m;
      }
    }
    return latest.values.toList()
      ..sort((a, b) => b.message.timestamp.compareTo(a.message.timestamp));
  }

  @override
  Future<String?> getSetting(String key) async => _settings[key];

  @override
  Future<void> setSetting(String key, String value) async =>
      _settings[key] = value;
}
