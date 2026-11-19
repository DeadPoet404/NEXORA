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

## 2. Layout: deterministic rings, no force simulation

The first implementation adapted
[`graphview`](https://github.com/nabil6391/graphview) `^1.5.1` (MIT) for layout
only: `MeshLayout` called `FruchtermanReingoldAlgorithm.init/run`, kept its `Node`
objects alive between snapshots and asked for 140 iterations of
Fruchterman–Reingold on every topology change. That produced exactly the
behaviour the redesign had to remove:

- every snapshot re-ran a *stochastic* force simulation on the whole graph, so
  nodes never settled — the picture visibly drifted even when nothing changed;
- the only spacing term was the node diameter, so glow and label extents were
  ignored and clusters of four or more peers overlapped their labels;
- positional state lived inside a third-party widget's model, which made
  "keep existing peers where they are" impossible to guarantee.

`graphview` was therefore dropped. `lib/visualization/mesh_layout.dart` is now
plain Dart (`dart:math` + `dart:ui` only) and the dependency was removed from
`pubspec.yaml`, which also removes those packages' `material.dart` imports from
the build.

Alternatives that were considered and are still rejected:

| Candidate | Licence | Why not chosen |
| --- | --- | --- |
| `graphview` force layout | MIT | Re-runs a force sim per snapshot; drift; no collision with glow/label extents |
| `csu/netviz` | permissive text, no SPDX file | JavaScript demo, needs a WebView bridge |
| `helios51193/NetViz` | none declared | Python/Angular app, not a library, no licence |
| `graph-cn/flutter_graph_view` | Apache-2.0 | Its widget owns the paint loop, so hop animation needs its internals |
| `szktty/plough` | Apache-2.0 | Small community, `0.x`, codegen-heavy, first-render animation only |
| `theiskaa/force_graph` | MIT | Git-only dependency, renders its own nodes/links |

### How the layout works

```
local node            pinned to the canvas centre, radius 38 px (76 px diameter)
usable radius         shortestSide / 2 − edgePadding − labelSpace
first ring radius     max(localRadius + peerRadius + minNodeGap, min(150, usable × 0.55))
ring spacing          peerDiameter + minNodeGap = 44 + 26 = 70 px
slots per ring        floor(2π × radius / spacing)
```

- Peers are distributed **evenly** around each ring, starting at twelve o'clock
  and going clockwise, so the arrangement is identical on every device for the
  same peer set. There is no randomness, so two runs cannot disagree.
- Ring capacity comes from the circumference and the *real* spacing budget
  (node diameter plus a 26 px gap, which covers the glow and the label line).
  When a ring is full the next ring is added 70 px further out **instead of
  squeezing nodes closer**, so peers cannot overlap for any realistic count
  (tested up to eleven nodes; six rings hold well over sixty). Beyond that the
  last ring takes the remainder rather than dropping peers, and nodes would
  begin to overlap — a count that cannot occur on a phone's BLE mesh.
- Labels are laid out in screen space but clamped to the chord between two
  adjacent slots (`chord − 10`, clamped to 52…128 px) and ellipsised, so a label
  cannot run into its neighbour's.
- The layout is recomputed **only** when the topology changes or the canvas
  size changes — never per frame. Identical peer sets therefore produce
  bit-identical positions, which is what "frozen after settling" means here.
- Known peers keep their order (a stable `_order` list; only newcomers are
  sorted), so a peer's slot index does not depend on hash order. Because peers
  are evenly spaced, a joining or leaving peer changes the ring count and the
  remaining peers glide to their new angles over ~200 ms instead of jumping —
  the movement that must happen, animated, and nothing else moves.
- Positions are canvas pixels. Zoom and pan are a separate transform owned by
  the view, so gestures never feed back into the layout.

## 3. What was integrated

```
lib/visualization/topology.dart                 transport-agnostic model + mapping
lib/visualization/topology_source.dart          MeshTopologySource + live BLE adapter
lib/visualization/simulated_topology_source.dart development-only simulation
lib/visualization/mesh_style.dart               dark palette + phase colours
lib/visualization/mesh_layout.dart              deterministic radial layout
lib/visualization/mesh_network_view.dart        canvas, painters, animation, gestures
lib/visualization/topology_providers.dart       Riverpod wiring (auto-disposed)
lib/ui/network_tab.dart                         dark "Network" tab shell, legend, toggle
lib/ui/home_screen.dart                         tab added (4 tabs, named SOS index)
test/topology_test.dart                         model, source and layout tests
```

The BLE transport, `MeshRouter`, message stores, QR trust and security code are
untouched. The visualization never sends frames, never opens links and never
writes to the peer registry.

### Palette (`MeshPalette`)

| Token | Value | Used for |
| --- | --- | --- |
| `appBackground` | `#080D16` | Network tab background |
| `canvas` | `#0B1421` | canvas fill |
| `surface` | `#111D2C` | chips, pills, zoom controls |
| `accent` | `#20E0C1` teal | this device, live links, hops |
| `accentSecondary` | `#788BFF` violet | relayed hops, discovering |
| `connecting` | `#5CB8FF` | negotiating peers/links |
| `unavailable` | `#64748B` slate | static, de-emphasised peers |
| `warn` | `#F3B24B` amber | simulation pill and weak-signal ring only |
| `textPrimary` / `textSecondary` | `#E7F0FA` / `#8FA6BE` | labels |

Both the canvas and the legend read the same `meshPhaseColor()` switch, so they
cannot drift apart.

### Visual hierarchy and states

- **this device** — teal ring with a soft radial glow, an inner device indicator,
  and a slow breathing halo (2.8 s cycle, ±6 px). Fixed at the centre.
- **connected** — solid teal node, thin static glow, a restrained pulse that
  moves ±2 px on a 3.2 s cycle with a per-peer phase offset (nodes never march in
  step). Weak links (`bars <= 1`) switch the ring to amber.
- **connecting** — violet-blue ring plus a short arc that rotates once per 2.4 s;
  the node itself never moves.
- **discovering** — a static dotted ring, no motion.
- **unavailable** — outlined slate node with a static dotted ring and no glow.
- **links** — 1.0–1.25 px hairlines at 13–30 % opacity; live links get a very
  faint 4.5 px halo. `forming` is dashed, `observed`/`down` are finely dotted.
  A hop briefly brightens its link (decays in ~0.4 s) and never changes geometry.

### Animation budget

| Motion | Duration | Notes |
| --- | --- | --- |
| join | 420 ms fade + 0.85 → 1.0 scale | staggered 70 ms across a burst |
| link appear | 360 ms fade | staggered 50 ms |
| leave | 280 ms fade-out | node/link removed from the scene afterwards |
| node glide to new slot | ~200 ms exponential | only when the ring re-spaces |
| message particle | 700–1200 ms, distance-based | sender → receiver along a real link |
| link brighten | ~400 ms decay | one hop, one link |
| breathing / pulse / arc | 2.8 s / 3.2 s / 2.4 s | fixed cycles, no randomness |

Particles exist only for real `activity` events; they are created on the event,
travel once and are removed when their duration elapses. There is no permanent
traffic and no invented route: the particle only follows a link that is already
in the snapshot, so an event whose endpoints (or link) are not both on screen
produces no particle. Live events always run peer → this device; the simulation's
reversed hops travel the other way along the same star link.
A maximum of 12 particles is kept, so a burst cannot flood the canvas.

### Reduced motion and performance

- `MediaQuery.disableAnimations` freezes every decorative cycle (breathing,
  pulse, arc at phase 0), suppresses particles, and stops the `Ticker` entirely
  whenever no fade, glide or flash is in flight — the canvas then only repaints
  on real state changes.
- The painters read a mutable scene object and repaint through a single
  `ValueNotifier`; `build()` is not called per frame, and no `setState` runs in
  the ticker. Ambient backdrop, grid and glow are painted per paint but are
  cheap (no `MaskFilter`, no large blurs, no saveLayer).
- The layout is separate from painting: per frame the view only interpolates
  positions towards targets the layout already computed.

### Interaction

Pinch to zoom (0.6×–2.4×) and drag to pan inside the canvas, plus translucent
zoom-in/zoom-out/reset buttons in the top-right corner. The reset button returns
to 1× with no offset, so a lost network can always be recovered.

## 4. How the visualization gets its data

```
BLE discovery ─► MeshTransport.peers/peerChanges ─► LiveMeshTopologySource ─┬─► changes:  MeshTopologySnapshot
                                                                           │              │
MeshRouter.incomingMessages (sender ids) ──────────────────────────────────┤              ├─► MeshLayout (rings)
MeshRouter.sosAlerts        (sender ids) ──────────────────────────────────┤              │
                                                                           └─► activity: TopologyTransmission
                                                                                          │
SimulatedMeshTopologySource (debug only) ─────────────────────────────────────────────────┤
                                                                                          └─► MeshNetworkView (hop particles)
```

- `MeshTopologySnapshot` is immutable and contains only drawing data: node IDs,
  display labels, phases, signal bars and links. No message content, no
  coordinates, no keys.
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
header and warning copy, the amber `SIMULATED NETWORK` pill drawn over the
canvas, and `MeshTopologySnapshot.simulated`.

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
  so **nothing was executed here**. Local checks only: `git diff --check`
  (clean) and delimiter/string scans of the edited Dart files.
- On the maintainer's machine (Flutter 3.50.0, Android toolchain) for an earlier
  commit: debug APK built successfully, `flutter test` passed 55 tests, and
  `flutter analyze` reported 17 issues — 16 `deprecated_member_use` notices for
  `package:flutter/material.dart` imports plus one `unused_field` warning
  (`_incomingSenderIds`), since fixed. A later run of that suite showed two hop
  tests expecting 2 events and receiving 1; the cause was activity being carried
  *inside* topology snapshots built from a peer list that was never initialised,
  so the first hop erased the neighbour and every later hop from it was rejected.
  Activity is now its own stream, and regression tests cover bursts on one and
  two activity streams.
- `test/topology_test.dart` holds 25 tests: 8 live-source tests, the simulator
  group, and 9 layout tests. The five new layout tests assert determinism,
  zero drift on a re-published topology, pairwise non-overlap with a second ring,
  canvas-size responsiveness and chord-derived label widths. No existing
  assertion was weakened or removed.

Run on a machine with the SDK:

```sh
flutter pub get            # graphview is gone; nothing new to resolve
flutter analyze            # expect the same 16 material.dart infos
flutter test test/topology_test.dart -r expanded
flutter run --debug        # open the Network tab
```

## 8. Known limitations / next steps

- Widget-level tests for `MeshNetworkView` are not written yet; animation,
  gesture and reduced-motion behaviour are only covered by inspection.
- `Ticker`-driven visuals were never observed on a device from this
  environment: frame pacing, particle sharpness and glow softness still need a
  visual pass on hardware.
- Above roughly nine peers on a phone-sized canvas a second ring is used; on a
  short landscape canvas the outer ring can extend past the visible area and
  needs a pinch-out or pan. A future revision could auto-fit the initial scale to
  the layout `bounds`.
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

This project still has exactly 16 files importing that library — 13 under
`lib/ui/`, plus `lib/app.dart`, `lib/main.dart` and
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
3. Widgets from `graphview` are no longer embedded anywhere, so the network view
   itself has no cross-library Material surface left; the remaining risk is
   purely the app-wide `ThemeData`/localisations move.

Recommended route when it is scheduled as its own milestone: bump Flutter to the
3.50 line, `flutter pub add material_ui`, run
`dart fix --apply --code=migrate_design_widgets`, convert the localization
delegates, then `flutter analyze` and `flutter test`.
