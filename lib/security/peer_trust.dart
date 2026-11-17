import 'public_identity.dart';

/// These states describe QR key verification, not BLE link availability.
enum PeerTrustStatus { unverified, verified, identityChanged, blocked }

class PeerTrustRecord {
  PeerTrustRecord({
    required this.peerId,
    this.observedKeyId,
    this.observedAlgorithm,
    this.observedFingerprint,
    List<int>? observedPublicKey,
    required this.status,
    required this.updatedAtMillis,
    this.pinnedKeyId,
    this.pinnedAlgorithm,
    this.pinnedFingerprint,
    List<int>? pinnedPublicKey,
  })  : observedPublicKey = observedPublicKey == null
            ? null
            : List<int>.unmodifiable(observedPublicKey),
        pinnedPublicKey = pinnedPublicKey == null
            ? null
            : List<int>.unmodifiable(pinnedPublicKey);

  final String peerId;
  final String? observedKeyId;
  final String? observedAlgorithm;
  final String? observedFingerprint;
  final List<int>? observedPublicKey;
  final String? pinnedKeyId;
  final String? pinnedAlgorithm;
  final String? pinnedFingerprint;
  final List<int>? pinnedPublicKey;
  final PeerTrustStatus status;
  final int updatedAtMillis;

  bool observedMatches(PublicIdentityMaterial identity) =>
      peerId == identity.peerId &&
      observedKeyId == identity.keyId &&
      observedAlgorithm == identity.algorithm &&
      observedFingerprint == identity.fingerprint;

  bool pinnedMatches(PublicIdentityMaterial identity) =>
      pinnedKeyId == identity.keyId &&
      pinnedAlgorithm == identity.algorithm &&
      pinnedFingerprint == identity.fingerprint;
}

/// Persistence boundary for peer key observations and explicit QR trust.
///
/// [confirmQrIdentity] must be atomic: it either pins the exact scanned key and
/// marks it verified, or leaves the previous trust record unchanged.
abstract interface class PeerTrustRepository {
  Stream<void> get trustChanges;

  Future<PeerTrustRecord?> getPeerTrust(String peerId);

  /// Record a key observed from a peer; this never marks it verified.
  Future<PeerTrustRecord> observePeerIdentity(
    PublicIdentityMaterial identity, {
    required int nowMillis,
  });

  /// Pin a key only after the user has scanned and explicitly confirmed its QR.
  Future<PeerTrustRecord> confirmQrIdentity(
    QrVerificationChallenge challenge, {
    required int nowMillis,
  });

  Future<PeerTrustRecord> blockPeer(
    String peerId, {
    required int nowMillis,
  });
}

class QrVerificationChallenge {
  const QrVerificationChallenge._({
    required this.expectedPeerId,
    required this.identity,
  });

  final String expectedPeerId;
  final PublicIdentityMaterial identity;
}

class PeerTrustException implements Exception {
  const PeerTrustException(this.message);
  final String message;

  @override
  String toString() => 'PeerTrustException: $message';
}

/// Coordinates QR verification without implementing cryptography.
class PeerTrustTransitions {
  const PeerTrustTransitions._();

  static PeerTrustRecord observe(
    PeerTrustRecord? previous,
    PublicIdentityMaterial identity, {
    required int nowMillis,
  }) {
    final sameAsPinned = previous != null &&
        previous.pinnedFingerprint != null &&
        previous.pinnedMatches(identity);
    final status = switch (previous?.status) {
      PeerTrustStatus.blocked => PeerTrustStatus.blocked,
      PeerTrustStatus.identityChanged => PeerTrustStatus.identityChanged,
      _ when previous?.pinnedFingerprint == null => PeerTrustStatus.unverified,
      _ when sameAsPinned => PeerTrustStatus.verified,
      _ => PeerTrustStatus.identityChanged,
    };
    return PeerTrustRecord(
      peerId: identity.peerId,
      observedKeyId: identity.keyId,
      observedAlgorithm: identity.algorithm,
      observedFingerprint: identity.fingerprint,
      observedPublicKey: identity.publicKey,
      pinnedKeyId: previous?.pinnedKeyId,
      pinnedAlgorithm: previous?.pinnedAlgorithm,
      pinnedFingerprint: previous?.pinnedFingerprint,
      pinnedPublicKey: previous?.pinnedPublicKey,
      status: status,
      updatedAtMillis: nowMillis,
    );
  }

  static PeerTrustRecord confirm(
    PeerTrustRecord? previous,
    PublicIdentityMaterial identity, {
    required int nowMillis,
  }) {
    if (previous?.status == PeerTrustStatus.blocked) {
      throw const PeerTrustException('This peer is blocked');
    }
    if (previous?.status == PeerTrustStatus.identityChanged) {
      throw const PeerTrustException(
        'Changed identity cannot be accepted by QR confirmation',
      );
    }
    if (previous != null && !previous.observedMatches(identity)) {
      throw const PeerTrustException(
        'Scanned QR does not match the last observed key',
      );
    }
    if (previous?.pinnedFingerprint != null &&
        !previous!.pinnedMatches(identity)) {
      throw const PeerTrustException(
        'A different key is already pinned for this peer',
      );
    }
    return PeerTrustRecord(
      peerId: identity.peerId,
      observedKeyId: identity.keyId,
      observedAlgorithm: identity.algorithm,
      observedFingerprint: identity.fingerprint,
      observedPublicKey: identity.publicKey,
      pinnedKeyId: identity.keyId,
      pinnedAlgorithm: identity.algorithm,
      pinnedFingerprint: identity.fingerprint,
      pinnedPublicKey: identity.publicKey,
      status: PeerTrustStatus.verified,
      updatedAtMillis: nowMillis,
    );
  }

  static PeerTrustRecord block(
    PeerTrustRecord? previous, {
    required String peerId,
    required int nowMillis,
  }) =>
      PeerTrustRecord(
        peerId: peerId,
        observedKeyId: previous?.observedKeyId,
        observedAlgorithm: previous?.observedAlgorithm,
        observedFingerprint: previous?.observedFingerprint,
        observedPublicKey: previous?.observedPublicKey,
        pinnedKeyId: previous?.pinnedKeyId,
        pinnedAlgorithm: previous?.pinnedAlgorithm,
        pinnedFingerprint: previous?.pinnedFingerprint,
        pinnedPublicKey: previous?.pinnedPublicKey,
        status: PeerTrustStatus.blocked,
        updatedAtMillis: nowMillis,
      );
}

abstract interface class PeerMessagingPolicy {
  Stream<void> get trustChanges;
  Future<bool> isMessagingRestricted(String peerId);
}

class PeerTrustService implements PeerMessagingPolicy {
  PeerTrustService({
    required this.repository,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final PeerTrustRepository repository;
  final DateTime Function() _clock;

  @override
  Stream<void> get trustChanges => repository.trustChanges;

  @override
  Future<bool> isMessagingRestricted(String peerId) async {
    final status = (await repository.getPeerTrust(peerId))?.status;
    return status == PeerTrustStatus.blocked ||
        status == PeerTrustStatus.identityChanged;
  }

  Future<void> requireMessagingAllowed(String peerId) async {
    final record = await repository.getPeerTrust(peerId);
    if (record?.status == PeerTrustStatus.blocked) {
      throw const PeerTrustException('Messaging is blocked for this peer');
    }
    if (record?.status == PeerTrustStatus.identityChanged) {
      throw const PeerTrustException(
        'Messaging is restricted because this peer identity changed',
      );
    }
  }

  Future<PeerTrustRecord> observe(PublicIdentityMaterial identity) =>
      repository.observePeerIdentity(
        identity,
        nowMillis: _clock().millisecondsSinceEpoch,
      );

  /// Decode and validate scanned QR data. This does not change trust state.
  Future<QrVerificationChallenge> prepareVerification({
    required String expectedPeerId,
    required String scannedQr,
  }) async {
    final payload = IdentityQrPayload.decode(scannedQr);
    final identity = payload.identity;
    if (identity.peerId != expectedPeerId) {
      throw const PeerTrustException(
        'QR belongs to a different peer than the selected BLE device',
      );
    }

    final current = await repository.getPeerTrust(expectedPeerId);
    if (current?.status == PeerTrustStatus.blocked) {
      throw const PeerTrustException('This peer is blocked');
    }
    if (current?.status == PeerTrustStatus.identityChanged) {
      throw const PeerTrustException(
        'Peer identity changed; verification is locked pending review',
      );
    }
    if (current != null &&
        current.status == PeerTrustStatus.unverified &&
        !current.observedMatches(identity)) {
      throw const PeerTrustException(
        'Scanned QR does not match the observed peer identity',
      );
    }
    if (current?.status == PeerTrustStatus.verified &&
        !current!.pinnedMatches(identity)) {
      throw const PeerTrustException(
        'Scanned QR key differs from the pinned identity',
      );
    }
    return QrVerificationChallenge._(
      expectedPeerId: expectedPeerId,
      identity: identity,
    );
  }

  /// Call only after the user has compared the displayed fingerprint in person.
  Future<PeerTrustRecord> confirmVerification(
    QrVerificationChallenge challenge,
  ) =>
      repository.confirmQrIdentity(
        challenge,
        nowMillis: _clock().millisecondsSinceEpoch,
      );
}
