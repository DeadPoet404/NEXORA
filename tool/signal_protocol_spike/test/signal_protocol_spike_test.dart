import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:test/test.dart';

import 'persistent_store.dart';

void main() {
  test('QR fingerprints match for peers and fail for a substituted key',
      () async {
    final alice = await SpikePeer.create('alice-device');
    final charlie = await SpikePeer.create('charlie-device');
    final mallory = await SpikePeer.create('mallory-device');
    final generator = NumericFingerprintGenerator(5200);

    final aliceView = generator.createFor(
      0,
      _bytes(alice.name),
      alice.publicIdentity,
      _bytes(charlie.name),
      charlie.publicIdentity,
    );
    final charlieView = generator.createFor(
      0,
      _bytes(charlie.name),
      charlie.publicIdentity,
      _bytes(alice.name),
      alice.publicIdentity,
    );
    final substitutedKeyView = generator.createFor(
      0,
      _bytes(alice.name),
      alice.publicIdentity,
      _bytes(charlie.name),
      mallory.publicIdentity,
    );

    expect(
      aliceView.displayableFingerprint.getDisplayText(),
      charlieView.displayableFingerprint.getDisplayText(),
    );
    expect(
      aliceView.scannableFingerprint
          .compareTo(charlieView.scannableFingerprint.fingerprints),
      isTrue,
    );
    expect(
      aliceView.scannableFingerprint
          .compareTo(substitutedKeyView.scannableFingerprint.fingerprints),
      isFalse,
    );
  });

  test('offline ciphertext relay, tamper/replay rejection, and receipt',
      () async {
    const messageId = 'spike-message-001';
    const body = 'HYBRID-01 private test phrase';
    final alice = await SpikePeer.create('alice-device');
    final charlie = await SpikePeer.create('charlie-device');
    final relay = await SpikePeer.create('bob-relay');

    final bundle = await charlie.publishPreKeyBundle();
    await alice.trust(charlie);
    await charlie.trust(alice);
    await SessionBuilder.fromSignalStore(alice.store, charlie.address)
        .processPreKeyBundle(bundle);

    final aliceCipher = SessionCipher.fromStore(alice.store, charlie.address);
    final firstPacket = await aliceCipher.encrypt(_bytes(jsonEncode({
      'message_id': messageId,
      'body': body,
    })));
    final serialized = firstPacket.serialize();

    expect(firstPacket.getType(), CiphertextMessage.prekeyType);
    expect(
      utf8.decode(serialized, allowMalformed: true),
      isNot(contains(body)),
    );

    // The relay receives/forwards bytes only; its separate store has no session.
    final relayedBytes = Uint8List.fromList(serialized);
    final relayCipher = SessionCipher.fromStore(relay.store, alice.address);
    await expectLater(
      relayCipher.decrypt(PreKeySignalMessage(relayedBytes)),
      throwsA(anything),
    );

    // Attempt tampering against a fresh recipient store so failure cannot
    // consume or otherwise affect Charlie's real one-time prekey.
    final tamperStore = InMemorySignalProtocolStore(
      charlie.identityKeyPair,
      charlie.registrationId,
    );
    await tamperStore.storePreKey(charlie.preKey!.id, charlie.preKey!);
    await tamperStore.storeSignedPreKey(
      charlie.signedPreKey!.id,
      charlie.signedPreKey!,
    );
    await tamperStore.saveIdentity(alice.address, alice.publicIdentity);
    final modified = Uint8List.fromList(serialized);
    modified[modified.length - 1] ^= 1;
    final tamperCipher = SessionCipher.fromStore(tamperStore, alice.address);
    await expectLater(
      Future<Uint8List>.sync(
        () => tamperCipher.decrypt(PreKeySignalMessage(modified)),
      ),
      throwsA(anything),
    );

    final charlieCipher = SessionCipher.fromStore(charlie.store, alice.address);
    final received = await charlieCipher.decrypt(
      PreKeySignalMessage(relayedBytes),
    );
    final decoded = jsonDecode(utf8.decode(received)) as Map<String, dynamic>;
    expect(decoded['message_id'], messageId);
    expect(decoded['body'], body);
    expect(await charlie.store.containsPreKey(charlie.preKey!.id), isFalse);

    await expectLater(
      charlieCipher.decrypt(PreKeySignalMessage(relayedBytes)),
      throwsA(anything),
      reason: 'the same initial packet must not be accepted a second time',
    );

    final receipt = await charlieCipher.encrypt(_bytes('DELIVERED:$messageId'));
    expect(receipt.getType(), CiphertextMessage.whisperType);
    final authenticatedReceipt = await aliceCipher.decryptFromSignal(
      SignalMessage.fromSerialized(receipt.serialize()),
    );
    expect(utf8.decode(authenticatedReceipt), 'DELIVERED:$messageId');
  });

  test('identity, prekeys, and sessions recover from serialized files',
      () async {
    final directory = await Directory.systemTemp.createTemp('hybrid01-spike-');
    addTearDown(() => directory.delete(recursive: true));
    final aliceFile = File('${directory.path}/alice.json');
    final charlieFile = File('${directory.path}/charlie.json');
    var alice = await SpikePeer.createPersistent('alice-device', aliceFile);
    var charlie = await SpikePeer.createPersistent('charlie-device', charlieFile);

    final bundle = await charlie.publishPreKeyBundle();
    final oneTimePreKeyId = charlie.preKey!.id;
    await alice.trust(charlie);
    await charlie.trust(alice);
    await SessionBuilder.fromSignalStore(alice.store, charlie.address)
        .processPreKeyBundle(bundle);
    final first = await SessionCipher.fromStore(alice.store, charlie.address)
        .encrypt(_bytes('persisted session survives reopening'));

    // Re-create both peer/store objects from the saved files.
    alice = await SpikePeer.reopen('alice-device', aliceFile);
    charlie = await SpikePeer.reopen('charlie-device', charlieFile);
    final charlieCipher = SessionCipher.fromStore(charlie.store, alice.address);
    final clear = await charlieCipher.decrypt(
      PreKeySignalMessage(first.serialize()),
    );
    expect(utf8.decode(clear), 'persisted session survives reopening');
    expect(await charlie.store.containsPreKey(oneTimePreKeyId), isFalse);

    final aliceCipher = SessionCipher.fromStore(alice.store, charlie.address);
    final receipt = await charlieCipher.encrypt(_bytes('DELIVERED:restart-001'));
    final returned = await aliceCipher.decryptFromSignal(
      SignalMessage.fromSerialized(receipt.serialize()),
    );
    expect(utf8.decode(returned), 'DELIVERED:restart-001');
  });

  test('a conflicting prekey identity is rejected after pinning', () async {
    final alice = await SpikePeer.create('alice-device');
    final charlie = await SpikePeer.create('charlie-device');
    final mallory = await SpikePeer.create('mallory-device');
    await alice.trust(charlie);
    final maliciousBundle = await mallory.publishPreKeyBundle();

    await expectLater(
      SessionBuilder.fromSignalStore(alice.store, charlie.address)
          .processPreKeyBundle(maliciousBundle),
      throwsA(isA<UntrustedIdentityException>()),
    );
  });
}

Uint8List _bytes(String value) => Uint8List.fromList(utf8.encode(value));

class SpikePeer {
  SpikePeer._(
    this.name,
    this.address,
    this.store,
    this.identityKeyPair,
    this.registrationId,
  );

  final String name;
  final SignalProtocolAddress address;
  final SignalProtocolStore store;
  final IdentityKeyPair identityKeyPair;
  final int registrationId;
  PreKeyRecord? preKey;
  SignedPreKeyRecord? signedPreKey;

  IdentityKey get publicIdentity => identityKeyPair.getPublicKey();

  static Future<SpikePeer> create(String name) async {
    final keyPair = generateIdentityKeyPair();
    final registrationId = generateRegistrationId(false);
    return SpikePeer._(
      name,
      SignalProtocolAddress(name, 1),
      InMemorySignalProtocolStore(keyPair, registrationId),
      keyPair,
      registrationId,
    );
  }

  static Future<SpikePeer> createPersistent(String name, File file) async {
    final identity = generateIdentityKeyPair();
    final registrationId = generateRegistrationId(false);
    final store = await JsonFileSignalStore.open(
      file,
      createIdentity: identity,
      createRegistrationId: registrationId,
    );
    return SpikePeer._(
      name,
      SignalProtocolAddress(name, 1),
      store,
      identity,
      registrationId,
    );
  }

  static Future<SpikePeer> reopen(String name, File file) async {
    final store = await JsonFileSignalStore.open(file);
    return SpikePeer._(
      name,
      SignalProtocolAddress(name, 1),
      store,
      await store.getIdentityKeyPair(),
      await store.getLocalRegistrationId(),
    );
  }

  Future<void> trust(SpikePeer peer) async {
    await store.saveIdentity(peer.address, peer.publicIdentity);
  }

  Future<PreKeyBundle> publishPreKeyBundle() async {
    preKey = generatePreKeys(1, 1).single;
    signedPreKey = generateSignedPreKey(identityKeyPair, 1);
    await store.storePreKey(preKey!.id, preKey!);
    await store.storeSignedPreKey(signedPreKey!.id, signedPreKey!);
    return PreKeyBundle(
      registrationId,
      1,
      preKey!.id,
      preKey!.getKeyPair().publicKey,
      signedPreKey!.id,
      signedPreKey!.getKeyPair().publicKey,
      signedPreKey!.signature,
      publicIdentity,
    );
  }
}
