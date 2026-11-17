import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

/// Minimal JSON-backed test adapter. Never use for production: private key
/// records are stored without encryption or rollback/atomicity protection.
class JsonFileSignalStore extends SignalProtocolStore {
  JsonFileSignalStore._(this.file, this.identityKeyPair, this._state);

  final File file;
  final IdentityKeyPair identityKeyPair;
  Map<String, dynamic> _state;

  int get _registrationId => _state['registration_id'] as int;

  static Future<JsonFileSignalStore> open(
    File file, {
    IdentityKeyPair? createIdentity,
    int? createRegistrationId,
  }) async {
    if (await file.exists()) {
      final decoded = jsonDecode(await file.readAsString()) as Map;
      final state = Map<String, dynamic>.from(decoded);
      return JsonFileSignalStore._(
        file,
        IdentityKeyPair.fromSerialized(_decode(state['identity'] as String)),
        state,
      );
    }
    if (createIdentity == null || createRegistrationId == null) {
      throw StateError('No serialized store at ${file.path}');
    }

    final state = <String, dynamic>{
      'identity': base64Encode(createIdentity.serialize()),
      'registration_id': createRegistrationId,
      'prekeys': <String, String>{},
      'signed_prekeys': <String, String>{},
      'sessions': <String, String>{},
      'identities': <String, String>{},
    };
    final store = JsonFileSignalStore._(file, createIdentity, state);
    await store._persist();
    return store;
  }

  static Uint8List _decode(String value) => Uint8List.fromList(base64Decode(value));

  String _address(SignalProtocolAddress address) =>
      '${address.getName()}#${address.getDeviceId()}';

  Map<String, String> _bucket(String key) =>
      Map<String, String>.from(_state[key] as Map);

  Future<void> _save(String bucket, String key, Uint8List bytes) async {
    final values = _bucket(bucket)..[key] = base64Encode(bytes);
    _state[bucket] = values;
    await _persist();
  }

  Future<void> _delete(String bucket, String key) async {
    final values = _bucket(bucket)..remove(key);
    _state[bucket] = values;
    await _persist();
  }

  Future<void> _persist() => file.writeAsString(jsonEncode(_state), flush: true);

  @override
  Future<IdentityKeyPair> getIdentityKeyPair() async => identityKeyPair;

  @override
  Future<int> getLocalRegistrationId() async => _registrationId;

  @override
  Future<bool> saveIdentity(
    SignalProtocolAddress address,
    IdentityKey? identityKey,
  ) async {
    if (identityKey == null) return false;
    final prior = await getIdentity(address);
    await _save('identities', _address(address), identityKey.serialize());
    return prior != null && prior != identityKey;
  }

  @override
  Future<bool> isTrustedIdentity(
    SignalProtocolAddress address,
    IdentityKey? identityKey,
    Direction direction,
  ) async {
    final prior = await getIdentity(address);
    return identityKey != null && (prior == null || prior == identityKey);
  }

  @override
  Future<IdentityKey?> getIdentity(SignalProtocolAddress address) async {
    final value = _bucket('identities')[_address(address)];
    return value == null ? null : IdentityKey.fromBytes(_decode(value), 0);
  }

  @override
  Future<bool> containsSession(SignalProtocolAddress address) async =>
      _bucket('sessions').containsKey(_address(address));

  @override
  Future<SessionRecord> loadSession(SignalProtocolAddress address) async {
    final value = _bucket('sessions')[_address(address)];
    return value == null
        ? SessionRecord()
        : SessionRecord.fromSerialized(_decode(value));
  }

  @override
  Future<void> storeSession(
    SignalProtocolAddress address,
    SessionRecord record,
  ) => _save('sessions', _address(address), record.serialize());

  @override
  Future<void> deleteSession(SignalProtocolAddress address) =>
      _delete('sessions', _address(address));

  @override
  Future<void> deleteAllSessions(String name) async {
    final sessions = _bucket('sessions')
      ..removeWhere((key, _) => key.startsWith('$name#'));
    _state['sessions'] = sessions;
    await _persist();
  }

  @override
  Future<List<int>> getSubDeviceSessions(String name) async =>
      _bucket('sessions').keys
          .where((key) => key.startsWith('$name#'))
          .map((key) => int.parse(key.split('#').last))
          .toList();

  @override
  Future<bool> containsPreKey(int preKeyId) async =>
      _bucket('prekeys').containsKey('$preKeyId');

  @override
  Future<PreKeyRecord> loadPreKey(int preKeyId) async {
    final value = _bucket('prekeys')['$preKeyId'];
    if (value == null) throw InvalidKeyIdException('No prekey $preKeyId');
    return PreKeyRecord.fromBuffer(_decode(value));
  }

  @override
  Future<void> storePreKey(int preKeyId, PreKeyRecord record) =>
      _save('prekeys', '$preKeyId', record.serialize());

  @override
  Future<void> removePreKey(int preKeyId) => _delete('prekeys', '$preKeyId');

  @override
  Future<SignedPreKeyRecord> loadSignedPreKey(int signedPreKeyId) async {
    final value = _bucket('signed_prekeys')['$signedPreKeyId'];
    if (value == null) {
      throw InvalidKeyIdException('No signed prekey $signedPreKeyId');
    }
    return SignedPreKeyRecord.fromSerialized(_decode(value));
  }

  @override
  Future<List<SignedPreKeyRecord>> loadSignedPreKeys() async =>
      _bucket('signed_prekeys')
          .values
          .map((value) => SignedPreKeyRecord.fromSerialized(_decode(value)))
          .toList();

  @override
  Future<void> storeSignedPreKey(
    int signedPreKeyId,
    SignedPreKeyRecord record,
  ) => _save('signed_prekeys', '$signedPreKeyId', record.serialize());

  @override
  Future<bool> containsSignedPreKey(int signedPreKeyId) async =>
      _bucket('signed_prekeys').containsKey('$signedPreKeyId');

  @override
  Future<void> removeSignedPreKey(int signedPreKeyId) =>
      _delete('signed_prekeys', '$signedPreKeyId');
}
