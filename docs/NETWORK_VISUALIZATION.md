# Network visualization

**Status:** development milestone. The visualization is integrated and unit-tested
by source inspection only: this working environment has no `flutter`, `dart` or
Android toolchain, so **no build, analyzer run, widget test or device check was
performed here**. Nothing in this milestone changes the transport, router,
storage or security behaviour, and none of it makes messaging encrypted or
proves that offline phone-to-phone messaging works.

## 1. What "NetViz" turned out to be

There is no Flutter or Dart project called NetViz. The only actively updated
repository with that name is [`csu/netviz`](https://github.com/csu/netviz)
(JavaScript, 9 stars, last push 2026-11-09): a single-page D3/force-graph demo
(`index.html`, `netviz.js`, `netviz.css`, plus jQuery) that streams graph data
from logs over Socket.IO. It has no packaging, no release, no CI, no tests and no
Flutter binding; embedding it would mean a WebView plus a JavaScript bridge. It
was therefore **not** used, and no unrelated project was silently substituted.

## 2. Selected package

**[`graphview`](https://github.com/nabil6391/graphview) — `^1.5.1`**
(published on [pub.dev](https://pub.dev/packages/graphview), 518 likes, verified
publisher `nabilmh.com`, published 2025-10-17, MIT licence, `LICENSE` copyright
Nabil Mosharraf).

Why it is suitable:

- MIT licence, compatible with this non-commercial showcase and with the
  upstream attribution requirements in [`UPSTREAM.md`](../UPSTREAM.md).
- Pure Dart/Flutter, no platform channels, no WebView, no JavaScript.
- Ships a force-directed layout (`FruchtermanReingoldAlgorithm`,
  Fruchterman–Reingold with clustering) — the part that is genuinely hard to get
  right — under a small, stable API (`Graph`, `Node`, `Edge`, `Algorithm`).
- One transitive dependency (`collection`) and a wide SDK range
  (`sdk: >=2.17.0 <4.0.0`), so it fits this project's `sdk: ^3.12.0`.
- Maintained in 2026 (commit `b9572aa`, 2026-04-24) and used by 470+ GitHub
  stars' worth of projects.

Alternatives considered and rejected:

| Candidate | Licence | Why not chosen |
| --- | --- | --- |
| `csu/netviz` | permissive text, no SPDX file | JavaScript demo, needs a WebView bridge |
| `helios51193/NetViz` | none declared | Python/Angular app, not a library, no licence |
| `graph-cn/flutter_graph_view` | Apache-2.0 | Heavier widget (isolates, theming, its own render pipeline); its widget owns the paint loop, so message-hop animation would need its internals |
| `szktty/plough` | Apache-2.0 | Small community (5 stars), `0.x`, freezed/json dependencies, animation aimed at first render rather than live traffic |
| `theiskaa/force_graph` | MIT | Git-only dependency (not published to pub.dev), 2 stars, renders its own nodes/links |
| Hand-written force layout | n/a | Would rebuild functionality that `graphview` already provides |

`graphview` is used **for layout only**. Its widget (`GraphView.builder`) owns
painting and zoom, which would make per-frame message-hop animation and custom
peer states awkward, so `MeshLayout` calls the documented
`init(graph) → run(graph, 0, 0)` lifecycle and Nexora paints its own animated
layer on top. That keeps the package surface to three API calls and keeps the
visual language consistent with the existing app.

## 3. What was integrated

```
lib/visualization/topology.dart                 transport-agnostic model + mapping
lib/visualization/topology_source.dart          MeshTopologySource + live BLE adapter
lib/visualization/simulated_topology_source.dart development-only simulation
lib/visualization/mesh_layout.dart              graphview force layout adapter
lib/visualization/mesh_network_view.dart        animated widget + painter + gestures
lib/visualization/topology_providers.dart       Riverpod wiring (auto-disposed)
lib/ui/network_tab.dart                         new "Network" tab
lib/ui/home_screen.dart                         tab added (4 tabs, named SOS index)
pubspec.yaml                                    graphview: ^1.5.1
test/topology_test.dart                         unit tests for model, sources, layout
```

The BLE transport, `MeshRouter`, message stores, QR trust and security code are
untouched. The visualization never sends frames, never opens links and never
writes to the peer registry.

Visual states drawn:

- this device — filled primary node with a pulsing halo, always the anchor;
- connected — solid link with drifting pulses, green node;
- connecting — dashed link, tertiary node;
- discovering — dotted link, secondary node (observed, no usable link);
- unavailable — faint broken link, outline node, fades out when the peer is
  forgotten;
- weak link — node ring switches to the error colour when `bars <= 1`;
- message hop — a packet with a short trail travelling along the link, plus a
  ring flash on the receiving node.

Nodes and links fade in and out, positions are smoothed towards the layout
target every frame, and the view is responsive: it fits the network to whatever
space the tab gives it, and pinch/drag pans and zooms (with a "centre" button).

## 4. How the visualization gets its data

```
BLE discovery ─► MeshTransport.peers/peerChanges ─► LiveMeshTopologySource ─┬─► changes:  MeshTopologySnapshot
                                                                           │              │
MeshRouter.incomingMessages (sender ids) ──────────────────────────────────┤              ├─► MeshLayout (graphview)
MeshRouter.sosAlerts        (sender ids) ──────────────────────────────────┤              │
                                                                           └─► activity: TopologyTransmission
                                                                                          │
SimulatedMeshTopologySource (debug only) ─────────────────────────────────────────────────┤
                                                                                          └─► MeshNetworkView (hop packets)
```

- `MeshTopologySnapshot` is immutable and contains only drawing data: node IDs,
  display labels, phases, signal bars, links and hop events. No message content,
  no coordinates, no keys.
- `MeshTopologySource` is the single seam. A future transport (Wi-Fi Direct,
  LoRa) or a recorded replay can implement it without touching the view.
- `LiveMeshTopologySource` is a read-only projection of `MeshTransport.peers`.
  Its `activityStreams` (chat messages and SOS alerts, mapped to sender IDs)
  exist **only** to trigger a hop animation. SOS is a separate stream in the
  router, so leaving it out silently drops those hops.
- Topology and activity are **two independent streams**. `changes` is state
  (latest snapshot only, idempotent); `activity` is an event log with one event
  per accepted frame. A hop therefore never re-emits a snapshot, never re-runs
  the layout, and can never discard peer discovery. Hop IDs are unique per
  event, so two messages from the same neighbour animate as two hops, an event
  from an unknown sender (or from this device itself) is ignored, and a burst of
  simultaneous frames is neither coalesced nor dropped.
- Nothing in this path can delay, reorder or drop traffic; streams are observed
  passively.

## 5. Enabling the simulation

Debug builds open the **Network** tab on the labelled simulation; the switch in
the tab header toggles between *Development simulation* and *Live Bluetooth
discovery*. Release builds never construct the simulation — the switch is
compiled out (`kDebugMode`) and `topologySourceProvider` can then only return
the live source.

The simulation is also usable directly, e.g. in a test or a scratch screen:

```dart
final source = SimulatedMeshTopologySource(seed: 3, autoAdvance: false);
source.step();               // deterministic tick, no timers
debugPrint(source.current.nodes.length.toString());
await source.dispose();
```

It is labelled three ways so it cannot be mistaken for a real radio: the tab
copy, the amber `SIMULATED NETWORK` pill drawn over the canvas, and
`MeshTopologySnapshot.simulated`.

## 6. Simulated versus genuinely implemented

Genuinely implemented and reading real state:

- mapping of real `PeerLinkState`/RSSI to visual phases and signal bars;
- live update when the transport reports peers appearing or disappearing;
- hop animation when the router reports an arriving message;
- the layout, animation, gestures and responsive fitting.

Simulated only:

- peer names, join/leave timing and every topology change in the demo;
- peer-to-peer (**relayed**) links — the local Android BLE stack only knows its
  own neighbours, so relay paths between two other phones are not observable and
  are never invented for live data;
- all message movement in the simulation.

Still not claimed:

- no end-to-end encryption, no authenticated identity, no verified receipts —
  messages remain plaintext, as described in
  [`SECURITY_DESIGN.md`](SECURITY_DESIGN.md);
- no device-to-device Bluetooth verification of any kind;
- the view cannot show true multi-hop routes from live data (see above).

## 7. Checks performed

- This working environment has no `flutter`, `dart`, `java`, `gradle` or `adb`,
  so **nothing was executed here**. The only local checks are `git diff --check`
  (clean) and a delimiter/string sanity scan of the edited Dart files.
- On the maintainer's machine (Flutter 3.50.0, Android toolchain) for the
  previous commit: debug APK built successfully, `flutter test` passed 55 tests,
  and `flutter analyze` reported 17 issues — 16 `deprecated_member_use` notices
  for `package:flutter/material.dart` imports plus one
  `unused_field` warning (`_incomingSenderIds`). That warning is fixed by this
  change. A later run of that suite showed two hop tests expecting 2 events and
  receiving 1; the cause was activity being carried *inside* topology snapshots
  built from a peer list that was never initialised, so the first hop erased the
  neighbour and every later hop from it was rejected. Activity is now its own
  stream, and regression tests cover bursts on one and two activity streams.

Run on a machine with the SDK:

```sh
flutter pub get            # resolves graphview 1.5.1 and refreshes pubspec.lock
flutter analyze
flutter test
flutter run --debug        # open the Network tab
```

`pubspec.lock` in this commit predates the new dependency; `flutter pub get`
(or any `flutter build`) refreshes it. The lock file was deliberately not
hand-edited, because a fabricated checksum would break resolution.

## 8. Known limitations / next steps

- `pubspec.lock` needs a real `flutter pub get`; first build may also need the
  usual Gradle downloads.
- Widget-level tests for `MeshNetworkView` are not written yet; the animation and
  painter are only covered indirectly by the layout tests.
- Live links are drawn as a star around this device, which is all BLE can
  observe. Showing real relay paths would need routing metadata that the
  protocol does not currently expose (and that metadata would be a privacy
  decision, not a UI one).
- Node labels come from display names and node IDs, which are self-declared;
  they are not identity proofs and are not verified by the QR flow in this view.
- Only hops that arrive are animated. Outgoing frames are not observable through
  the router's public API, so they never produce an animation yet.

## 9. `package:flutter/material.dart` deprecation notices

Flutter 3.50 (with Dart 3.14) formally deprecates the in-framework Material and
Cupertino libraries in favour of the standalone `material_ui` and `cupertino_ui`
packages, which reached 1.0 in Flutter 3.47. The analyzer emits one
`deprecated_member_use` info **per importing file**:

```
info • 'package:flutter/material.dart' is deprecated and shouldn't be used.
       Use package:material_ui/material_ui.dart instead. This feature was
       deprecated after v3.47.0-0.0.pre. • lib/app.dart:1:1 • deprecated_member_use
```

This project has exactly 16 files importing that library — 13 under `lib/ui/`,
plus `lib/app.dart`, `lib/main.dart` and
`lib/visualization/mesh_network_view.dart` — which matches the 16 notices
reported. They are an expected SDK transition notice, **not** a defect in this
codebase, and the deprecated import still works on 3.50.

A migration is deliberately out of scope for the visualization milestone because
it is not an import rename:

1. `material_ui` is a separate copy of Material, not a re-export, so its
   `Theme`, `ThemeData` and `MaterialLocalizations` are different types. Every
   file, `lib/app.dart`'s `ThemeData` and the test files must move together.
2. It adds a dependency and raises the Flutter floor from `>=3.44.0` to
   `>=3.47` (3.50 for a warning-free analyze), which changes the build
   requirements for every contributor.
3. `graphview` still imports `package:flutter/material.dart`; embedding legacy
   widgets inside a migrated app needs `MaterialUiCompatibilityBridge`, and the
   bridge does not reconcile type mismatches. This view only uses `graphview`'s
   layout algorithm (no widgets, no `Theme.of`), so the exposure is small but
   must be verified on a real build.

Recommended route when it is scheduled as its own milestone: bump Flutter to the
3.50 line, `flutter pub add material_ui`, run
`dart fix --apply --code=migrate_design_widgets`, convert the localization
delegates, then `flutter analyze` and `flutter test` — with the `graphview`
interaction checked on device.
