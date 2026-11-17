# HYBRID-01 Signal protocol spike

A disposable Dart test package for source/API feasibility testing of
`MixinNetwork/libsignal_protocol_dart`, pinned to commit
`9c871c05629e60f23fed6e7cec863c8aaff696d9`.

## Requirements

- Dart SDK 3.4 or newer on your `PATH` (Flutter is not required).
- Git, for Pub to retrieve the pinned library source.
- Network access to GitHub and pub.dev during dependency resolution.

## Run everything

From the repository root:

**macOS / Linux / Git Bash**

```sh
bash tool/signal_protocol_spike/run.sh
```

**Windows PowerShell**

```powershell
.\tool\signal_protocol_spike\run.ps1
```

Both scripts print the Dart version, resolve dependencies, format the tests,
run them, then run static analysis. The test command on its own is:

```sh
cd tool/signal_protocol_spike
dart pub get
dart test
```

## What the tests cover

- Matching reciprocal numeric fingerprints and detecting a substituted key.
- Offline prekey session setup and ciphertext-only forwarding through a relay
  that has no session keys.
- Rejection of a modified packet and replay of the initial prekey packet.
- A reverse-direction encrypted receipt containing the original message ID.
- Identity pinning against a conflicting prekey bundle.
- Session, identity, and prekey state loaded after the test closes and reopens
  JSON-backed stores.

## Important limits

This is a feasibility spike, not production code, an independent cryptographic
audit, proof of interoperability with official Signal clients, or approval to
adopt the dependency. The candidate is GPL-3.0; review compatibility before
including it in a distributed app. The JSON adapter is test-only and writes
private key material in plaintext to a temporary directory. It has no Android
Keystore integration, secure-at-rest protection, atomic-write guarantees,
rollback protection, or process locking. Passing these tests does not prove
physical BLE behavior or production persistence.
