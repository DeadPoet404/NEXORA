import 'peer_trust.dart';
import 'public_identity.dart';

/// Test/preview-only trust repository. Production must use a durable store.
class InMemoryPeerTrustRepository implements PeerTrustRepository {
  final _records = <String, PeerTrustRecord>{};

  @override
  Future<PeerTrustRecord?> getPeerTrust(String peerId) async =>
      _records[peerId];

  @override
  Future<PeerTrustRecord> observePeerIdentity(
    PublicIdentityMaterial identity, {
    required int nowMillis,
  }) async {
    final record = PeerTrustTransitions.observe(
      _records[identity.peerId],
      identity,
      nowMillis: nowMillis,
    );
    _records[identity.peerId] = record;
    return record;
  }

  @override
  Future<PeerTrustRecord> confirmQrIdentity(
    QrVerificationChallenge challenge, {
    required int nowMillis,
  }) async {
    final identity = challenge.identity;
    if (challenge.expectedPeerId != identity.peerId) {
      throw const PeerTrustException('QR peer ID does not match challenge');
    }
    final record = PeerTrustTransitions.confirm(
      _records[identity.peerId],
      identity,
      nowMillis: nowMillis,
    );
    _records[identity.peerId] = record;
    return record;
  }

  @override
  Future<PeerTrustRecord> blockPeer(
    String peerId, {
    required int nowMillis,
  }) async {
    final previous = _records[peerId];
    if (previous == null) {
      throw const PeerTrustException(
        'Cannot block a peer before an identity has been observed',
      );
    }
    final record = PeerTrustTransitions.block(previous, nowMillis: nowMillis);
    _records[peerId] = record;
    return record;
  }
}
