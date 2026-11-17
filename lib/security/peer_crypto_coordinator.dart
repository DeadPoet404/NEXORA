import 'dart:typed_data';

import 'backend_contracts.dart';
import 'peer_operation_queue.dart';

/// Serializes session and cipher operations through the same per-peer queue.
///
/// Future adapters should use this coordinator rather than calling their
/// mutable session store concurrently. This does not implement a cipher.
class PeerCryptoCoordinator {
  PeerCryptoCoordinator({
    required this.sessions,
    required this.cipher,
    PeerOperationQueue? operations,
  }) : operations = operations ?? PeerOperationQueue();

  final SessionManager sessions;
  final MessageCipher cipher;
  final PeerOperationQueue operations;

  Future<bool> hasSession(String peerId) =>
      operations.run(peerId, () => sessions.hasSession(peerId));

  Future<void> establishSession(PublishedPreKeyBundle bundle) =>
      operations.run(
        bundle.peerId,
        () => sessions.establishFromVerifiedBundle(bundle),
      );

  Future<EncryptedEnvelope> encrypt({
    required String peerId,
    required String senderKeyId,
    required String recipientKeyId,
    required Uint8List plaintext,
    required Uint8List authenticatedContext,
  }) =>
      operations.run(
        peerId,
        () => cipher.encryptForPeer(
          peerId: peerId,
          senderKeyId: senderKeyId,
          recipientKeyId: recipientKeyId,
          plaintext: plaintext,
          authenticatedContext: authenticatedContext,
        ),
      );

  Future<Uint8List> decrypt({
    required String peerId,
    required EncryptedEnvelope envelope,
    required Uint8List authenticatedContext,
  }) =>
      operations.run(
        peerId,
        () => cipher.decryptFromPeer(
          peerId: peerId,
          envelope: envelope,
          authenticatedContext: authenticatedContext,
        ),
      );
}
