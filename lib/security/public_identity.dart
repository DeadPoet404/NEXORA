import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Public identity material supplied by a reviewed identity backend.
///
/// This type computes a display fingerprint only. It does not create keys,
/// authenticate a peer, or encrypt messages.
class PublicIdentityMaterial {
  PublicIdentityMaterial({
    required this.peerId,
    required this.displayName,
    required this.keyId,
    required this.algorithm,
    required List<int> publicKey,
  }) : _publicKey = Uint8List.fromList(publicKey) {
    if (peerId.isEmpty || peerId.length > 128) {
      throw ArgumentError.value(peerId, 'peerId', 'Must be 1–128 characters');
    }
    if (keyId.isEmpty || keyId.length > 128) {
      throw ArgumentError.value(keyId, 'keyId', 'Must be 1–128 characters');
    }
    if (algorithm.isEmpty || algorithm.length > 64) {
      throw ArgumentError.value(
        algorithm,
        'algorithm',
        'Must be 1–64 characters',
      );
    }
    if (_publicKey.isEmpty || _publicKey.length > 4096) {
      throw ArgumentError.value(
        _publicKey.length,
        'publicKey',
        'Must be 1–4096 bytes',
      );
    }
  }

  final String peerId;
  final String displayName;
  final String keyId;
  final String algorithm;
  final Uint8List _publicKey;

  /// Return a copy so consumers cannot mutate the identity after validation.
  Uint8List get publicKey => Uint8List.fromList(_publicKey);

  /// SHA-256 display fingerprint bound to the peer ID, algorithm and key ID.
  ///
  /// The fingerprint is only useful after an out-of-band verification step.
  /// It is not a signature and is not proof that BLE messages came from this
  /// identity.
  String get fingerprint {
    final canonical = [
      'NEXORA-IDENTITY-QR-V1',
      peerId,
      algorithm,
      keyId,
      base64Url.encode(_publicKey),
    ].join('\u0000');
    return sha256.convert(utf8.encode(canonical)).toString();
  }

  bool matches(PublicIdentityMaterial other) =>
      peerId == other.peerId &&
      keyId == other.keyId &&
      algorithm == other.algorithm &&
      fingerprint == other.fingerprint;
}

/// Versioned QR data format for sharing a public identity key in person.
class IdentityQrPayload {
  const IdentityQrPayload({
    required this.identity,
    required this.version,
  });

  static const currentVersion = 1;
  static const _format = 'nexora.identity';
  static const maxEncodedLength = 8192;

  final PublicIdentityMaterial identity;
  final int version;

  factory IdentityQrPayload.fromIdentity(PublicIdentityMaterial identity) =>
      IdentityQrPayload(identity: identity, version: currentVersion);

  String encode() => jsonEncode({
        'format': _format,
        'version': version,
        'peer_id': identity.peerId,
        'display_name': identity.displayName,
        'key_id': identity.keyId,
        'algorithm': identity.algorithm,
        'public_key': base64Url.encode(identity.publicKey),
        'fingerprint': identity.fingerprint,
      });

  static IdentityQrPayload decode(String encoded) {
    if (encoded.isEmpty || encoded.length > maxEncodedLength) {
      throw const FormatException('Identity QR has an invalid size');
    }

    final Object? value;
    try {
      value = jsonDecode(encoded);
    } on FormatException {
      throw const FormatException('Identity QR is not valid JSON');
    }
    if (value is! Map<String, dynamic> ||
        value['format'] != _format ||
        value['version'] != currentVersion) {
      throw const FormatException('Unsupported identity QR format/version');
    }

    try {
      final publicKeyEncoded = value['public_key'] as String;
      if (publicKeyEncoded.length > 5500) {
        throw const FormatException('Public key is too large');
      }
      final identity = PublicIdentityMaterial(
        peerId: value['peer_id'] as String,
        displayName: value['display_name'] as String? ?? '',
        keyId: value['key_id'] as String,
        algorithm: value['algorithm'] as String,
        publicKey: base64Url.decode(base64Url.normalize(publicKeyEncoded)),
      );
      if (value['fingerprint'] != identity.fingerprint) {
        throw const FormatException('Identity QR fingerprint mismatch');
      }
      return IdentityQrPayload(identity: identity, version: currentVersion);
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('Identity QR fields are invalid');
    }
  }
}
