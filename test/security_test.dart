import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linkmesh/security/in_memory_peer_trust_repository.dart';
import 'package:linkmesh/security/peer_operation_queue.dart';
import 'package:linkmesh/security/peer_trust.dart';
import 'package:linkmesh/security/public_identity.dart';

void main() {
  PublicIdentityMaterial identity({String key = 'key-A', String peer = 'peer-1'}) =>
      PublicIdentityMaterial(
        peerId: peer,
        displayName: 'Peer',
        keyId: key,
        algorithm: 'test-only',
        publicKey: key.codeUnits,
      );

  group('identity QR payload', () {
    test('round trips public identity and checks the fingerprint', () {
      final original = identity();
      final decoded = IdentityQrPayload.decode(
        IdentityQrPayload.fromIdentity(original).encode(),
      );
      expect(decoded.identity.peerId, original.peerId);
      expect(decoded.identity.publicKey, original.publicKey);
      expect(decoded.identity.fingerprint, original.fingerprint);
    });

    test('rejects a tampered fingerprint', () {
      final payload = IdentityQrPayload.fromIdentity(identity()).encode();
      final tampered = payload.replaceFirst(RegExp(r'"fingerprint":"[^"]+"'),
          '"fingerprint":"${List.filled(64, '0').join()}"');
      expect(() => IdentityQrPayload.decode(tampered), throwsFormatException);
    });
  });

  group('peer trust state machine', () {
    late InMemoryPeerTrustRepository repository;
    late PeerTrustService service;
    setUp(() {
      repository = InMemoryPeerTrustRepository();
      service = PeerTrustService(
        repository: repository,
        clock: () => DateTime.fromMillisecondsSinceEpoch(100),
      );
    });

    test('first observation is never automatic trust; exact QR needs action', () async {
      final observed = await service.observe(identity());
      expect(observed.status, PeerTrustStatus.unverified);
      final challenge = await service.prepareVerification(
        expectedPeerId: 'peer-1',
        scannedQr: IdentityQrPayload.fromIdentity(identity()).encode(),
      );
      expect((await repository.getPeerTrust('peer-1'))?.status,
          PeerTrustStatus.unverified);
      final verified = await service.confirmVerification(challenge);
      expect(verified.status, PeerTrustStatus.verified);
      expect(verified.pinnedFingerprint, identity().fingerprint);
    });

    test('QR verification is linked to the discovered mesh peer ID', () async {
      final challenge = await service.prepareVerification(
        expectedPeerId: 'peer-1',
        scannedQr: IdentityQrPayload.fromIdentity(identity()).encode(),
      );
      expect((await repository.getPeerTrust('peer-1')), isNull);
      final pinned = await service.confirmVerification(challenge);
      expect(pinned.peerId, 'peer-1');
      expect(pinned.status, PeerTrustStatus.verified);
    });

    test('different observed key is identity-changed and QR cannot reset it', () async {
      await service.observe(identity());
      final first = await service.prepareVerification(
        expectedPeerId: 'peer-1',
        scannedQr: IdentityQrPayload.fromIdentity(identity()).encode(),
      );
      await service.confirmVerification(first);
      final changed = await service.observe(identity(key: 'key-B'));
      expect(changed.status, PeerTrustStatus.identityChanged);
      expect(await service.isMessagingRestricted('peer-1'), isTrue);
      expect((await service.observe(identity())).status,
          PeerTrustStatus.identityChanged);
      await expectLater(
        service.prepareVerification(
          expectedPeerId: 'peer-1',
          scannedQr: IdentityQrPayload.fromIdentity(identity(key: 'key-B')).encode(),
        ),
        throwsA(isA<PeerTrustException>()),
      );
      expect((await repository.getPeerTrust('peer-1'))?.pinnedFingerprint,
          identity().fingerprint);
    });

    test('QR for a different selected peer is rejected', () async {
      await expectLater(
        service.prepareVerification(
          expectedPeerId: 'peer-1',
          scannedQr: IdentityQrPayload.fromIdentity(identity(peer: 'peer-2')).encode(),
        ),
        throwsA(isA<PeerTrustException>()),
      );
    });

    test('an unobserved discovered peer can be blocked without fake key data',
        () async {
      final blocked = await repository.blockPeer('peer-1', nowMillis: 100);
      expect(blocked.status, PeerTrustStatus.blocked);
      expect(blocked.observedPublicKey, isNull);
      expect(await service.isMessagingRestricted('peer-1'), isTrue);
    });

    test('blocking persists and prevents QR verification', () async {
      await service.observe(identity());
      await repository.blockPeer('peer-1', nowMillis: 200);
      await expectLater(
        service.prepareVerification(
          expectedPeerId: 'peer-1',
          scannedQr: IdentityQrPayload.fromIdentity(identity()).encode(),
        ),
        throwsA(isA<PeerTrustException>()),
      );
      expect((await repository.getPeerTrust('peer-1'))?.status,
          PeerTrustStatus.blocked);
    });
  });

  group('per-peer operation queue', () {
    test('serializes same-peer actions, isolates peers, and recovers after error', () async {
      final queue = PeerOperationQueue();
      final firstGate = Completer<void>();
      final events = <String>[];
      final first = queue.run('a', () async {
        events.add('a-start');
        await firstGate.future;
        events.add('a-end');
      });
      final second = queue.run('a', () async => events.add('a-second'));
      await queue.run('b', () async => events.add('b-independent'));
      expect(events, ['a-start', 'b-independent']);
      firstGate.complete();
      await Future.wait([first, second]);
      expect(events, ['a-start', 'b-independent', 'a-end', 'a-second']);

      await expectLater(
        queue.run<void>('a', () => throw StateError('expected failure')),
        throwsStateError,
      );
      expect(await queue.run('a', () async => 42), 42);
    });
  });
}
