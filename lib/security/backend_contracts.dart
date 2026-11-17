import 'dart:typed_data';

import 'public_identity.dart';

/// Opaque encrypted wire payload. This app currently has no implementation.
class EncryptedEnvelope {
  EncryptedEnvelope({
    required this.version,
    required this.senderKeyId,
    required this.recipientKeyId,
    required List<int> ciphertext,
  }) : ciphertext = Uint8List.fromList(ciphertext);

  final int version;
  final String senderKeyId;
  final String recipientKeyId;
  final Uint8List ciphertext;
}

/// Backend seam for application-managed key material.
///
/// Implementations must use platform-backed protection; raw secret bytes must
/// never be written to the message database or logs.
abstract interface class SecureKeyStore {
  Future<void> writeSecret(String handle, Uint8List secret);
  Future<Uint8List?> readSecret(String handle);
  Future<void> deleteSecret(String handle);
}

/// Persistent identity-key lifecycle. No first-seen identity is trusted here.
abstract interface class LocalIdentityProvider {
  Future<PublicIdentityMaterial?> currentPublicIdentity();
}

/// Explicitly unconfigured adapter used until a reviewed key backend exists.
class UnconfiguredLocalIdentityProvider implements LocalIdentityProvider {
  const UnconfiguredLocalIdentityProvider();

  @override
  Future<PublicIdentityMaterial?> currentPublicIdentity() async => null;
}

abstract interface class IdentityKeyManager {
  Future<PublicIdentityMaterial> loadOrCreateLocalIdentity();
  Future<PublicIdentityMaterial?> loadPeerIdentity(String peerId);
  Future<void> pinVerifiedPeer(PublicIdentityMaterial identity);
  Future<void> rejectChangedPeerKey(String peerId);
}

class PublishedPreKeyBundle {
  PublishedPreKeyBundle({
    required this.peerId,
    required this.identityKeyId,
    required this.signedPreKeyId,
    required List<int> identityPublicKey,
    required List<int> signedPreKey,
    required List<int> signedPreKeySignature,
    this.oneTimePreKeyId,
    List<int>? oneTimePreKey,
  })  : identityPublicKey = Uint8List.fromList(identityPublicKey),
        signedPreKey = Uint8List.fromList(signedPreKey),
        signedPreKeySignature = Uint8List.fromList(signedPreKeySignature),
        oneTimePreKey = oneTimePreKey == null
            ? null
            : Uint8List.fromList(oneTimePreKey);

  final String peerId;
  final String identityKeyId;
  final String signedPreKeyId;
  final String? oneTimePreKeyId;
  final Uint8List identityPublicKey;
  final Uint8List signedPreKey;
  final Uint8List signedPreKeySignature;
  final Uint8List? oneTimePreKey;
}

/// Prekey publishing, rotation, consumption, and low-watermark management.
abstract interface class PreKeyManager {
  Future<PublishedPreKeyBundle> publishBundle();
  Future<void> consumeOneTimePreKey(String preKeyId);
  Future<void> replenishIfNeeded();
}

/// Session lifecycle for a single remote peer.
abstract interface class SessionManager {
  Future<bool> hasSession(String peerId);
  Future<void> establishFromVerifiedBundle(PublishedPreKeyBundle bundle);
  Future<void> deleteSession(String peerId);
}

/// Message protection boundary. Do not add a plaintext fallback implementation.
abstract interface class MessageCipher {
  Future<EncryptedEnvelope> encryptForPeer({
    required String peerId,
    required String senderKeyId,
    required String recipientKeyId,
    required Uint8List plaintext,
    required Uint8List authenticatedContext,
  });

  Future<Uint8List> decryptFromPeer({
    required String peerId,
    required EncryptedEnvelope envelope,
    required Uint8List authenticatedContext,
  });
}

class MissingPreKeyException implements Exception {
  const MissingPreKeyException(this.peerId, this.preKeyId);

  final String peerId;
  final String preKeyId;

  @override
  String toString() => 'Missing prekey $preKeyId for peer $peerId';
}

/// Marker for the current app behavior; deliberately not a cipher mode.
enum MessageProtectionStatus { plaintextDevelopmentOnly }
