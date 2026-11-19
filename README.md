# HYBRID-01 (Android baseline)

An experimental, non-commercial showcase of offline messaging over Bluetooth Low Energy (BLE). The Android app is based on the LinkMesh project; its routing and transport code are retained as the starting point while HYBRID-01 is developed incrementally.

**Current phase:** the Android baseline built, existing simulated routing tests passed, and source/test analysis reported no issues on the user's machine. A SQLite-backed relay queue and simulated router-restart recovery test have been added in this workspace; these latest changes still need to be synced and tested. Physical SQLite restart recovery and BLE behavior need device verification.

## What is included

- Flutter/Dart app, BLE transport, mesh router, and SQLite message store.
- Android application and native foreground-service integration.
- Unit tests for routing through an in-memory simulated network.
- An animated mesh-network view (Network tab) with a clearly labelled
  development simulation; see
  [docs/NETWORK_VISUALIZATION.md](docs/NETWORK_VISUALIZATION.md).

The network view draws this device, the peers it has discovered, and the links
between them, using the MIT-licensed `graphview` package for force-directed
layout. In debug builds the tab starts on a fabricated network so the visuals
can be developed without phones; a switch moves it to live Bluetooth discovery,
and release builds cannot show the simulation. The visualization only observes
peer discovery and incoming-message events, so it cannot make routing
multi-hop-aware and it does not change transport behaviour.

This checkout intentionally omits LinkMesh's iOS/macOS projects and web preview. The relay queue is designed to be stored in SQLite and restored when the router starts; the automated restart test reuses an in-memory store, so it validates router recovery but not process-death durability of the SQLite adapter. Physical app-restart recovery and BLE relay still need device verification. The current protocol does not provide end-to-end encryption or authenticated receipts; see the [security design proposal](docs/SECURITY_DESIGN.md) for the planned threat model and acceptance checks.

## Android setup

Requires Flutter 3.44 or newer, the Android SDK/toolchain, and the JDK supported by the selected Flutter/Android Gradle toolchain. The Android platform scaffold is incomplete in the upstream checkout and must be generated once:

```sh
flutter create . --platforms android --org com.linkmesh --project-name linkmesh
flutter pub get
flutter test
flutter build apk --debug
```

Then install on two physical Android phones and verify direct BLE discovery, connection, message delivery, and acknowledgement. An emulator or the in-memory tests cannot verify BLE radio behavior. Check the generated `minSdk` and target SDK rather than assuming a particular Android version is supported.

## Upstream attribution

This baseline is derived from **LinkMesh** by `litu173`. See [`UPSTREAM.md`](UPSTREAM.md) for the source repository, exact commit, scope of the import, and permission/attribution notes. Preserve upstream attribution and dependency licence notices when modifying or distributing the showcase.
