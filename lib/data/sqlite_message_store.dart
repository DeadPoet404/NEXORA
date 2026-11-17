import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../core/constants.dart';
import '../models/mesh_message.dart';
import '../models/stored_message.dart';
import '../security/peer_trust.dart';
import '../security/public_identity.dart';
import 'message_store.dart';

class SqliteMessageStore implements MessageStore, PeerTrustRepository {
  SqliteMessageStore._(this._db);

  final Database _db;
  final _changes = StreamController<void>.broadcast();

  static Future<SqliteMessageStore> open() async {
    final path = p.join(await getDatabasesPath(), 'linkmesh.db');
    final db = await openDatabase(
      path,
      version: 3,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE messages (
            id TEXT PRIMARY KEY,
            type TEXT NOT NULL,
            sender_id TEXT NOT NULL,
            sender_name TEXT NOT NULL,
            receiver_id TEXT NOT NULL,
            peer_id TEXT NOT NULL,
            timestamp INTEGER NOT NULL,
            content TEXT NOT NULL,
            hop_count INTEGER NOT NULL,
            max_hops INTEGER NOT NULL,
            ref_id TEXT,
            lat REAL,
            lng REAL,
            outgoing INTEGER NOT NULL,
            status INTEGER NOT NULL,
            relay_hops INTEGER NOT NULL
          )''');
        await db.execute(
          'CREATE INDEX idx_messages_peer ON messages(type, peer_id, timestamp)',
        );
        await db.execute(
          'CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
        );
        await _createRelayQueue(db);
        await _createPeerTrustTable(db);
      },
      onUpgrade: (db, oldVersion, _) async {
        if (oldVersion < 2) await _createRelayQueue(db);
        if (oldVersion < 3) await _createPeerTrustTable(db);
      },
    );
    return SqliteMessageStore._(db);
  }

  static Future<void> _createRelayQueue(DatabaseExecutor db) => db.execute('''
    CREATE TABLE relay_queue (
      id TEXT PRIMARY KEY,
      message_json TEXT NOT NULL,
      enqueued_at INTEGER NOT NULL,
      expires_at INTEGER NOT NULL
    )
  ''');

  static Future<void> _createPeerTrustTable(DatabaseExecutor db) =>
      db.execute('''
    CREATE TABLE peer_trust (
      peer_id TEXT PRIMARY KEY,
      state TEXT NOT NULL,
      observed_key_id TEXT NOT NULL,
      observed_algorithm TEXT NOT NULL,
      observed_fingerprint TEXT NOT NULL,
      observed_public_key BLOB NOT NULL,
      pinned_key_id TEXT,
      pinned_algorithm TEXT,
      pinned_fingerprint TEXT,
      pinned_public_key BLOB,
      updated_at INTEGER NOT NULL
    )
  ''');

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<StoredMessage?> get(String id) async {
    final rows = await _db.query('messages', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  @override
  Future<void> save(StoredMessage stored) async {
    await _writeStored(_db, stored);
    _changes.add(null);
  }

  Future<void> _writeStored(DatabaseExecutor db, StoredMessage stored) async {
    final m = stored.message;
    await db.insert(
      'messages',
      {
        'id': m.id,
        'type': m.type.name,
        'sender_id': m.senderId,
        'sender_name': m.senderName,
        'receiver_id': m.receiverId,
        'peer_id': stored.peerId,
        'timestamp': m.timestamp,
        'content': m.content,
        'hop_count': m.hopCount,
        'max_hops': m.maxHops,
        'ref_id': m.refId,
        'lat': m.lat,
        'lng': m.lng,
        'outgoing': stored.outgoing ? 1 : 0,
        'status': stored.status.index,
        'relay_hops': stored.relayHops,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> saveOutgoingAndEnqueueRelay({
    required StoredMessage storedMessage,
    required int enqueuedAtMillis,
    required int expiresAtMillis,
  }) async {
    await _db.transaction((txn) async {
      await _writeStored(txn, storedMessage);
      await _writeRelay(
        txn,
        message: storedMessage.message,
        enqueuedAtMillis: enqueuedAtMillis,
        expiresAtMillis: expiresAtMillis,
      );
      await _trimRelayQueue(txn);
    });
    _changes.add(null);
  }

  @override
  Future<void> enqueueRelay({
    required MeshMessage message,
    required int enqueuedAtMillis,
    required int expiresAtMillis,
  }) async {
    await _db.transaction((txn) async {
      await _writeRelay(
        txn,
        message: message,
        enqueuedAtMillis: enqueuedAtMillis,
        expiresAtMillis: expiresAtMillis,
      );
      await _trimRelayQueue(txn);
    });
    _changes.add(null);
  }

  Future<void> _writeRelay(
    DatabaseExecutor db, {
    required MeshMessage message,
    required int enqueuedAtMillis,
    required int expiresAtMillis,
  }) async {
    await db.insert(
      'relay_queue',
      {
        'id': message.id,
        'message_json': jsonEncode(message.toJson()),
        'enqueued_at': enqueuedAtMillis,
        'expires_at': expiresAtMillis,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<List<RelayQueueEntry>> loadRelayQueue(int nowMillis) async {
    return _db.transaction((txn) async {
      await txn.delete(
        'relay_queue',
        where: 'expires_at <= ?',
        whereArgs: [nowMillis],
      );
      await _trimRelayQueue(txn);
      final rows = await txn.query(
        'relay_queue',
        columns: ['message_json', 'enqueued_at', 'expires_at'],
        orderBy: 'enqueued_at ASC, rowid ASC',
      );
      return rows.map((row) {
        final json = jsonDecode(row['message_json']! as String)
            as Map<String, Object?>;
        return RelayQueueEntry(
          message: MeshMessage.fromJson(json),
          enqueuedAtMillis: row['enqueued_at']! as int,
          expiresAtMillis: row['expires_at']! as int,
        );
      }).toList();
    });
  }

  Future<void> _trimRelayQueue(DatabaseExecutor db) => db.execute('''
    DELETE FROM relay_queue
    WHERE id NOT IN (
      SELECT id FROM relay_queue
      ORDER BY enqueued_at DESC, rowid DESC
      LIMIT ?
    )
  ''', [MeshConstants.relayBufferMaxSize]);

  @override
  Future<void> removeRelay(String messageId) async {
    final removed = await _db.delete(
      'relay_queue',
      where: 'id = ?',
      whereArgs: [messageId],
    );
    if (removed > 0) _changes.add(null);
  }

  @override
  Future<List<StoredMessage>> conversation(String peerId) async {
    final rows = await _db.query(
      'messages',
      where: 'type = ? AND peer_id = ?',
      whereArgs: [MessageType.text.name, peerId],
      orderBy: 'timestamp ASC',
    );
    return rows.map(_fromRow).toList();
  }

  @override
  Future<List<ConversationSummary>> conversations() async {
    // Latest message per peer, plus the most recent name they used.
    final rows = await _db.rawQuery('''
      SELECT m.*,
        (SELECT sender_name FROM messages n
           WHERE n.type = m.type AND n.peer_id = m.peer_id AND n.outgoing = 0
           ORDER BY n.timestamp DESC LIMIT 1) AS peer_name
      FROM messages m
      WHERE m.type = ? AND m.timestamp = (
        SELECT MAX(timestamp) FROM messages x
        WHERE x.type = m.type AND x.peer_id = m.peer_id)
      GROUP BY m.peer_id
      ORDER BY m.timestamp DESC
    ''', [MessageType.text.name]);
    return rows
        .map((r) => ConversationSummary(
              peerId: r['peer_id']! as String,
              peerName: (r['peer_name'] as String?) ?? '',
              lastMessage: _fromRow(r),
            ))
        .toList();
  }

  @override
  Future<List<StoredMessage>> sosAlerts() async {
    final rows = await _db.rawQuery('''
      SELECT m.* FROM messages m
      WHERE m.type = ? AND m.outgoing = 0 AND m.timestamp = (
        SELECT MAX(timestamp) FROM messages x
        WHERE x.type = m.type AND x.outgoing = 0 AND x.sender_id = m.sender_id)
      GROUP BY m.sender_id
      ORDER BY m.timestamp DESC
    ''', [MessageType.sos.name]);
    return rows.map(_fromRow).toList();
  }

  @override
  Future<PeerTrustRecord?> getPeerTrust(String peerId) async {
    final rows = await _db.query(
      'peer_trust',
      where: 'peer_id = ?',
      whereArgs: [peerId],
    );
    return rows.isEmpty ? null : _peerTrustFromRow(rows.single);
  }

  @override
  Future<PeerTrustRecord> observePeerIdentity(
    PublicIdentityMaterial identity, {
    required int nowMillis,
  }) =>
      _db.transaction((txn) async {
        final rows = await txn.query(
          'peer_trust',
          where: 'peer_id = ?',
          whereArgs: [identity.peerId],
        );
        final previous = rows.isEmpty ? null : _peerTrustFromRow(rows.single);
        final updated = PeerTrustTransitions.observe(
          previous,
          identity,
          nowMillis: nowMillis,
        );
        await _writePeerTrust(txn, updated);
        return updated;
      });

  @override
  Future<PeerTrustRecord> confirmQrIdentity(
    QrVerificationChallenge challenge, {
    required int nowMillis,
  }) =>
      _db.transaction((txn) async {
        final identity = challenge.identity;
        if (challenge.expectedPeerId != identity.peerId) {
          throw const PeerTrustException('QR peer ID does not match challenge');
        }
        final rows = await txn.query(
          'peer_trust',
          where: 'peer_id = ?',
          whereArgs: [identity.peerId],
        );
        final previous = rows.isEmpty ? null : _peerTrustFromRow(rows.single);
        final verified = PeerTrustTransitions.confirm(
          previous,
          identity,
          nowMillis: nowMillis,
        );
        await _writePeerTrust(txn, verified);
        return verified;
      });

  @override
  Future<PeerTrustRecord> blockPeer(
    String peerId, {
    required int nowMillis,
  }) =>
      _db.transaction((txn) async {
        final rows = await txn.query(
          'peer_trust',
          where: 'peer_id = ?',
          whereArgs: [peerId],
        );
        if (rows.isEmpty) {
          throw const PeerTrustException(
            'Cannot block a peer before an identity has been observed',
          );
        }
        final previous = _peerTrustFromRow(rows.single);
        final blocked = PeerTrustTransitions.block(
          previous,
          nowMillis: nowMillis,
        );
        await _writePeerTrust(txn, blocked);
        return blocked;
      });

  Future<void> _writePeerTrust(
    DatabaseExecutor db,
    PeerTrustRecord record,
  ) =>
      db.insert(
        'peer_trust',
        {
          'peer_id': record.peerId,
          'state': record.status.name,
          'observed_key_id': record.observedKeyId,
          'observed_algorithm': record.observedAlgorithm,
          'observed_fingerprint': record.observedFingerprint,
          'observed_public_key': Uint8List.fromList(record.observedPublicKey),
          'pinned_key_id': record.pinnedKeyId,
          'pinned_algorithm': record.pinnedAlgorithm,
          'pinned_fingerprint': record.pinnedFingerprint,
          'pinned_public_key': record.pinnedPublicKey == null
              ? null
              : Uint8List.fromList(record.pinnedPublicKey!),
          'updated_at': record.updatedAtMillis,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  PeerTrustRecord _peerTrustFromRow(Map<String, Object?> row) =>
      PeerTrustRecord(
        peerId: row['peer_id']! as String,
        observedKeyId: row['observed_key_id']! as String,
        observedAlgorithm: row['observed_algorithm']! as String,
        observedFingerprint: row['observed_fingerprint']! as String,
        observedPublicKey: row['observed_public_key']! as Uint8List,
        pinnedKeyId: row['pinned_key_id'] as String?,
        pinnedAlgorithm: row['pinned_algorithm'] as String?,
        pinnedFingerprint: row['pinned_fingerprint'] as String?,
        pinnedPublicKey: row['pinned_public_key'] as Uint8List?,
        status: PeerTrustStatus.values.byName(row['state']! as String),
        updatedAtMillis: row['updated_at']! as int,
      );

  @override
  Future<String?> getSetting(String key) async {
    final rows =
        await _db.query('settings', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value']! as String;
  }

  @override
  Future<void> setSetting(String key, String value) => _db.insert(
        'settings',
        {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  StoredMessage _fromRow(Map<String, Object?> r) => StoredMessage(
        message: MeshMessage(
          id: r['id']! as String,
          type: MessageType.values.byName(r['type']! as String),
          senderId: r['sender_id']! as String,
          senderName: r['sender_name']! as String,
          receiverId: r['receiver_id']! as String,
          timestamp: r['timestamp']! as int,
          content: r['content']! as String,
          hopCount: r['hop_count']! as int,
          maxHops: r['max_hops']! as int,
          refId: r['ref_id'] as String?,
          lat: (r['lat'] as num?)?.toDouble(),
          lng: (r['lng'] as num?)?.toDouble(),
        ),
        outgoing: r['outgoing'] == 1,
        status: DeliveryStatus.values[r['status']! as int],
        relayHops: r['relay_hops']! as int,
      );
}
