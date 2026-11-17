import 'dart:async';
import 'dart:io';

import 'package:ble_peripheral/ble_peripheral.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    hide CharacteristicProperties;

import '../core/constants.dart';
import '../data/peer_registry.dart';
import '../mesh/chunker.dart';
import '../mesh/transport.dart';
import '../models/node_identity.dart';
import '../models/peer.dart';
import '../security/peer_trust.dart';

/// BLE link layer. Every node plays both roles at once:
///
/// * **Peripheral** (ble_peripheral): advertises the LinkMesh service and runs
///   a GATT server with an *inbox* characteristic that neighbours write
///   frames into, plus an *identity* characteristic they read.
/// * **Central** (flutter_blue_plus): scans for the service on a duty cycle,
///   connects to the strongest peers and writes frames into their inbox.
///
/// So each direction of a link is a separate GATT connection: A sends to B
/// over A's connection to B. Frames larger than the MTU are chunked.
class BleTransport implements MeshTransport {
  BleTransport({
    required NodeIdentity Function() identity,
    required this.peerRegistry,
    required this.messagingPolicy,
  }) : _identity = identity; // ignore: prefer_initializing_formals

  /// flutter_blue_plus requires a license declaration. `nonprofit` covers
  /// personal, nonprofit and educational use; for-profit use needs a paid
  /// commercial license (see the flutter_blue_plus LICENSE file).
  static const fbpLicense = License.nonprofit;

  final NodeIdentity Function() _identity;
  final PeerRegistry peerRegistry;
  final PeerMessagingPolicy messagingPolicy;
  final _service = Guid(BleConstants.serviceUuid);
  final _inboxUuid = Guid(BleConstants.inboxCharUuid);
  final _identityUuid = Guid(BleConstants.identityCharUuid);

  final _links = <String, _Link>{};
  final _reassembler = Reassembler();

  final _statusCtrl = StreamController<TransportStatus>.broadcast();
  final _incomingCtrl = StreamController<Uint8List>.broadcast();
  final _peersCtrl = StreamController<List<Peer>>.broadcast();
  final _linkedCtrl = StreamController<String>.broadcast();

  TransportStatus _status = TransportStatus.idle;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  StreamSubscription<void>? _trustSub;
  StreamSubscription<List<ScanResult>>? _scanSub;
  Timer? _scanTimer;
  Timer? _maintenanceTimer;
  bool _peripheralInitialized = false;
  bool _serviceAdded = false;
  String? _peripheralError;
  var _peripheralPoweredOn = Completer<void>();
  bool _online = false;
  bool _background = false;

  @override
  TransportStatus get status => _status;

  @override
  Stream<TransportStatus> get statusChanges => _statusCtrl.stream;

  @override
  Stream<Uint8List> get incoming => _incomingCtrl.stream;

  @override
  Stream<List<Peer>> get peerChanges => _peersCtrl.stream;

  @override
  Stream<String> get peerLinked => _linkedCtrl.stream;

  @override
  List<Peer> get peers => mergePeerViews(
        remembered: const [],
        live: _links.values
            .where((link) => !link.ignored)
            .map((link) => link.toPeer()),
      );

  @override
  Future<void> start() async {
    if (_adapterSub != null) return;
    _trustSub ??= messagingPolicy.trustChanges.listen((_) {
      unawaited(_disconnectRestrictedLinks());
    });
    try {
      if (!await FlutterBluePlus.isSupported) {
        _setStatus(TransportStatus.unsupported);
        return;
      }
    } catch (error) {
      _setStatus(_isPermissionError(error)
          ? TransportStatus.permissionDenied
          : TransportStatus.unsupported);
      return;
    }
    _adapterSub = FlutterBluePlus.adapterState.listen(
      (state) {
        if (state == BluetoothAdapterState.on) {
          unawaited(_goOnline());
        } else if (state == BluetoothAdapterState.off) {
          unawaited(_goOffline());
          _setStatus(TransportStatus.bluetoothOff);
        } else if (state.name == 'unauthorized') {
          unawaited(_goOffline());
          _setStatus(TransportStatus.permissionDenied);
        } else if (state.name == 'unavailable') {
          unawaited(_goOffline());
          _setStatus(TransportStatus.unsupported);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        _setStatus(_isPermissionError(error)
            ? TransportStatus.permissionDenied
            : TransportStatus.scanFailed);
      },
    );
  }

  @override
  Future<void> retryDiscovery() async {
    if (!_online) {
      await start();
      return;
    }
    await _restartScan();
  }

  @override
  Future<void> stop() async {
    await _adapterSub?.cancel();
    _adapterSub = null;
    await _trustSub?.cancel();
    _trustSub = null;
    await _goOffline();
    _setStatus(TransportStatus.idle);
  }

  Future<void> _goOnline() async {
    if (_online) return;
    _online = true;
    _peripheralError = null;
    try {
      await _startPeripheral();
    } catch (e) {
      // Some phones can't advertise. We can still send, but nobody can
      // write to us, so this node is send-only.
      _peripheralError = e.toString();
      debugPrint('LinkMesh: peripheral role unavailable: $e');
    }
    if (!_online) return;
    _scanSub = FlutterBluePlus.onScanResults.listen(
      _onScanResults,
      onError: (Object error, StackTrace stackTrace) {
        _setStatus(_isPermissionError(error)
            ? TransportStatus.permissionDenied
            : TransportStatus.scanFailed);
      },
    );
    _scheduleScanning();
    _maintenanceTimer =
        Timer.periodic(const Duration(seconds: 5), (_) => _maintain());
    _setStatus(_peripheralError == null
        ? TransportStatus.running
        : TransportStatus.receiveUnavailable);
  }

  Future<void> _goOffline() async {
    if (!_online) return;
    _online = false;
    _scanTimer?.cancel();
    _maintenanceTimer?.cancel();
    await _scanSub?.cancel();
    _scanSub = null;
    try {
      await FlutterBluePlus.stopScan();
      await BlePeripheral.stopAdvertising();
    } catch (_) {}
    for (final link in _links.values) {
      await link.connectionSub?.cancel();
      try {
        await link.device.disconnect();
      } catch (_) {}
    }
    _links.clear();
    _emitPeers();
  }

  // ---------------------------------------------------------------------------
  // Peripheral role

  /// Apple's peripheral manager powers on asynchronously and silently
  /// ignores services and advertising requested before that. It also drops
  /// published services whenever Bluetooth turns off.
  static final _isApple = Platform.isIOS || Platform.isMacOS;

  Future<void> _startPeripheral() async {
    if (!_peripheralInitialized) {
      BlePeripheral.setBleStateChangeCallback(_onPeripheralState);
      BlePeripheral.setWriteRequestCallback(_onWriteRequest);
      BlePeripheral.setReadRequestCallback(_onReadRequest);
      await BlePeripheral.initialize();
      _peripheralInitialized = true;
    }
    if (_isApple) {
      if (!_peripheralPoweredOn.isCompleted) {
        await _peripheralPoweredOn.future
            .timeout(const Duration(seconds: 15));
      }
      // Services don't survive a Bluetooth off/on cycle on Apple.
      await BlePeripheral.clearServices();
      _serviceAdded = false;
    }
    if (!_serviceAdded) {
      await BlePeripheral.addService(
        BleService(
          uuid: BleConstants.serviceUuid,
          primary: true,
          characteristics: [
            BleCharacteristic(
              uuid: BleConstants.inboxCharUuid,
              properties: [CharacteristicProperties.write.index],
              permissions: [AttributePermissions.writeable.index],
              value: null,
            ),
            BleCharacteristic(
              uuid: BleConstants.identityCharUuid,
              properties: [CharacteristicProperties.read.index],
              permissions: [AttributePermissions.readable.index],
              value: null,
            ),
          ],
        ),
      );
      _serviceAdded = true;
    }
    // No localName: a 128-bit UUID plus a name overflows the 31-byte legacy
    // advertisement. Peers read our name from the identity characteristic.
    await BlePeripheral.startAdvertising(services: [BleConstants.serviceUuid]);
    debugPrint('LinkMesh: advertising LinkMesh service');
  }

  // A Bluetooth off/on cycle also goes through _goOffline/_goOnline (via the
  // adapter state), which waits here again and republishes the service.
  void _onPeripheralState(bool poweredOn) {
    debugPrint('LinkMesh: peripheral powered on: $poweredOn');
    if (poweredOn) {
      if (!_peripheralPoweredOn.isCompleted) _peripheralPoweredOn.complete();
    } else if (_peripheralPoweredOn.isCompleted) {
      _peripheralPoweredOn = Completer();
    }
  }



  WriteRequestResult? _onWriteRequest(
    String deviceId,
    String characteristicId,
    int offset,
    Uint8List? value,
  ) {
    if (value == null || !_sameUuid(characteristicId, _inboxUuid)) return null;
    final frame = _reassembler.add(deviceId, value);
    if (frame != null) _incomingCtrl.add(frame);
    return null;
  }

  ReadRequestResult? _onReadRequest(
    String deviceId,
    String characteristicId,
    int offset,
    Uint8List? value,
  ) {
    if (!_sameUuid(characteristicId, _identityUuid)) return null;
    final bytes = _identity().encode();
    return ReadRequestResult(
      value: offset < bytes.length ? bytes.sublist(offset) : Uint8List(0),
    );
  }

  bool _sameUuid(String raw, Guid guid) {
    try {
      return Guid(raw) == guid;
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Central role

  @override
  void setBackground(bool background) {
    if (background == _background) return;
    _background = background;
    if (_online) _scheduleScanning();
  }

  /// Foreground: short low-latency scans on a duty cycle, for quick
  /// discovery. Background: one continuous low-power scan, which the radio
  /// duty-cycles in hardware and which keeps working when the CPU sleeps.
  /// Receiving doesn't depend on scanning at all: peers write into our GATT
  /// server, which stays up as long as the process lives.
  void _scheduleScanning() {
    _scanTimer?.cancel();
    if (_background) {
      // Android may demote scans running over 30 min; restart periodically.
      _scanTimer = Timer.periodic(
        const Duration(minutes: 25),
        (_) => _restartScan(),
      );
    } else {
      _scanTimer = Timer.periodic(BleConstants.scanPeriod, (_) => _scanOnce());
    }
    unawaited(_restartScan());
  }

  Future<void> _restartScan() async {
    try {
      if (FlutterBluePlus.isScanningNow) await FlutterBluePlus.stopScan();
    } catch (_) {}
    await _scanOnce();
  }

  Future<void> _scanOnce() async {
    if (!_online || FlutterBluePlus.isScanningNow) return;
    try {
      if (_background) {
        await FlutterBluePlus.startScan(
          withServices: [_service],
          androidScanMode: AndroidScanMode.lowPower,
          // Keep reporting devices we've already seen, so peers that drop
          // and come back get reconnected.
          continuousUpdates: true,
        );
      } else {
        await FlutterBluePlus.startScan(
          withServices: [_service],
          timeout: BleConstants.scanWindow,
          androidScanMode: AndroidScanMode.lowLatency,
          continuousUpdates: true,
        );
      }
      if (_status == TransportStatus.permissionDenied ||
          _status == TransportStatus.scanFailed) {
        _setStatus(_peripheralError == null
            ? TransportStatus.running
            : TransportStatus.receiveUnavailable);
      }
    } catch (e) {
      debugPrint('LinkMesh: scan failed: $e');
      _setStatus(_isPermissionError(e)
          ? TransportStatus.permissionDenied
          : TransportStatus.scanFailed);
    }
  }

  bool _isPermissionError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('permission') || text.contains('unauthoriz');
  }


  void _onScanResults(List<ScanResult> results) {
    final now = DateTime.now();
    final sorted = [...results]..sort((a, b) => b.rssi.compareTo(a.rssi));
    for (final r in sorted) {
      final link = _links.putIfAbsent(
        r.device.remoteId.str,
        () => _Link(r.device),
      );
      link
        ..rssi = r.rssi
        ..lastSeen = now;
      if (link.nodeId != null &&
          now.difference(link.lastRegistryWrite) >=
              const Duration(minutes: 1)) {
        unawaited(_rememberPeer(link));
      }
      unawaited(_maybeConnect(link));
    }
    _emitPeers();
  }

  Future<void> _maybeConnect(_Link link) async {
    if (!_online || link.ignored || link.messagingRestricted) return;
    if (link.state == PeerLinkState.connected ||
        link.state == PeerLinkState.connecting) {
      return;
    }
    if (link.rssi < BleConstants.minConnectRssi) return;
    if (DateTime.now().isBefore(link.nextAttempt)) return;
    final active = _links.values.where((l) =>
        l.state == PeerLinkState.connected ||
        l.state == PeerLinkState.connecting);
    if (active.length >= BleConstants.maxOutboundLinks) return;

    // Claim the slot synchronously so concurrent scan callbacks don't race.
    link
      ..state = PeerLinkState.connecting
      ..connectionError = null
      ..sawConnectedState = false
      ..droppedDuringConnect = false;
    link.connectionSub ??= link.device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.connected) {
        link.sawConnectedState = true;
      } else if (state == BluetoothConnectionState.disconnected &&
          link.sawConnectedState) {
        if (link.state == PeerLinkState.connected) {
          _onDisconnected(link);
        } else if (link.state == PeerLinkState.connecting) {
          link.droppedDuringConnect = true;
        }
      }
    });
    _emitPeers();
    try {
      await link.device.connect(
        license: fbpLicense,
        timeout: BleConstants.connectTimeout,
        mtu: BleConstants.requestedMtu,
      );
      final services = await link.device.discoverServices();
      final service = services.where((s) => s.uuid == _service).firstOrNull;
      final inbox = service?.characteristics
          .where((c) => c.uuid == _inboxUuid)
          .firstOrNull;
      final identityChar = service?.characteristics
          .where((c) => c.uuid == _identityUuid)
          .firstOrNull;
      if (inbox == null || identityChar == null) {
        throw StateError('LinkMesh service incomplete');
      }
      final identity = NodeIdentity.tryDecode(await identityChar.read());
      if (identity == null) throw StateError('Unreadable identity');
      if (link.droppedDuringConnect) {
        throw StateError('BLE link disconnected during service discovery');
      }
      if (!_online || !identical(_links[link.device.remoteId.str], link)) {
        await link.device.disconnect();
        return;
      }
      if (await messagingPolicy.isMessagingRestricted(identity.id)) {
        await link.device.disconnect();
        await link.connectionSub?.cancel();
        link
          ..connectionSub = null
          ..nodeId = identity.id
          ..name = identity.name
          ..inbox = null
          ..state = PeerLinkState.disconnected
          ..messagingRestricted = true
          ..connectionError = 'Blocked or changed identity; messaging restricted'
          ..nextAttempt = DateTime.now().add(BleConstants.peerStaleAfter);
        _emitPeers();
        return;
      }

      final isSelf = identity.id == _identity().id;
      final isDuplicate = _links.values.any((l) =>
          l != link &&
          l.nodeId == identity.id &&
          l.state == PeerLinkState.connected);
      if (isSelf || isDuplicate) {
        await link.device.disconnect();
        await link.connectionSub?.cancel();
        link
          ..connectionSub = null
          ..ignored = isSelf
          ..nodeId = identity.id
          ..name = identity.name
          ..state = PeerLinkState.disconnected
          ..connectionError = null
          // An alias may become the live connection as soon as the canonical
          // address disconnects; _onDisconnected will expedite its retry.
          ..nextAttempt = DateTime.now().add(BleConstants.peerStaleAfter);
        _emitPeers();
        return;
      }

      link
        ..nodeId = identity.id
        ..name = identity.name
        ..inbox = inbox
        ..state = PeerLinkState.connected
        ..connectionError = null;
      unawaited(_rememberPeer(link));
      _emitPeers();
      _linkedCtrl.add(identity.id);
    } catch (e) {
      debugPrint('LinkMesh: connect to ${link.device.remoteId} failed: $e');
      await link.connectionSub?.cancel();
      link
        ..connectionSub = null
        ..state = PeerLinkState.disconnected
        ..inbox = null
        ..connectionError = _displayConnectionError(e)
        ..nextAttempt = DateTime.now().add(BleConstants.reconnectBackoff);
      try {
        await link.device.disconnect();
      } catch (_) {}
      _emitPeers();
    }
  }

  void _onDisconnected(_Link link) {
    unawaited(link.connectionSub?.cancel());
    final retryAt = DateTime.now().add(const Duration(seconds: 3));
    link
      ..connectionSub = null
      ..inbox = null
      ..state = PeerLinkState.disconnected
      ..connectionError = 'Connection interrupted; retrying nearby scan'
      ..nextAttempt = retryAt;
    final peerId = link.nodeId;
    if (peerId != null) {
      for (final alias in _links.values.where((other) =>
          other != link &&
          other.nodeId == peerId &&
          other.state == PeerLinkState.disconnected)) {
        alias.nextAttempt = DateTime.now();
      }
    }
    _emitPeers();
  }

  Future<void> _rememberPeer(_Link link) async {
    final peerId = link.nodeId;
    if (peerId == null) return;
    link.lastRegistryWrite = DateTime.now();
    try {
      await peerRegistry.rememberPeer(
        peerId: peerId,
        displayName: link.name ?? '',
        lastSeenMillis: link.lastSeen.millisecondsSinceEpoch,
      );
    } catch (error) {
      link.connectionError = 'Peer details could not be saved: $error';
      _emitPeers();
    }
  }

  String _displayConnectionError(Object error) {
    final text = error.toString();
    return text.length <= 160 ? text : '${text.substring(0, 157)}…';
  }

  Future<void> _disconnectRestrictedLinks() async {
    if (!_online) return;
    var changed = false;
    for (final link in _links.values.toList()) {
      final peerId = link.nodeId;
      if (peerId == null) continue;
      final restricted = await messagingPolicy.isMessagingRestricted(peerId);
      if (!restricted) {
        if (link.messagingRestricted) {
          link
            ..messagingRestricted = false
            ..connectionError = null
            ..nextAttempt = DateTime.now();
          changed = true;
        }
        continue;
      }
      if (link.messagingRestricted &&
          link.state != PeerLinkState.connected &&
          link.state != PeerLinkState.connecting) {
        continue;
      }
      link
        ..messagingRestricted = true
        ..inbox = null
        ..state = PeerLinkState.disconnected
        ..connectionError = 'Blocked or changed identity; messaging restricted'
        ..nextAttempt = DateTime.now().add(BleConstants.peerStaleAfter);
      await link.connectionSub?.cancel();
      link.connectionSub = null;
      try {
        await link.device.disconnect();
      } catch (_) {}
      changed = true;
    }
    if (changed) _emitPeers();
  }

  Future<void> _maintain() async {
    final cutoff = DateTime.now().subtract(BleConstants.peerStaleAfter);
    _links.removeWhere((_, l) =>
        l.state != PeerLinkState.connected &&
        l.state != PeerLinkState.connecting &&
        l.lastSeen.isBefore(cutoff));
    for (final link in _links.values.toList()) {
      if (link.state != PeerLinkState.connected) continue;
      try {
        link
          ..rssi = await link.device.readRssi()
          ..lastSeen = DateTime.now();
      } catch (_) {}
    }
    _emitPeers();
  }

  // ---------------------------------------------------------------------------
  // Sending

  @override
  Future<int> broadcast(
    Uint8List frame, {
    Set<String> excludeNodeIds = const {},
  }) async {
    final targets = <_Link>[];
    for (final link in _links.values) {
      final peerId = link.nodeId;
      if (link.inbox == null ||
          peerId == null ||
          excludeNodeIds.contains(peerId) ||
          await messagingPolicy.isMessagingRestricted(peerId)) {
        continue;
      }
      targets.add(link);
    }
    final results = await Future.wait(targets.map((l) => _write(l, frame)));
    return results.where((ok) => ok).length;
  }

  @override
  Future<bool> sendTo(String nodeId, Uint8List frame) async {
    if (await messagingPolicy.isMessagingRestricted(nodeId)) return false;
    final link = _links.values
        .where((l) =>
            l.nodeId == nodeId &&
            l.inbox != null &&
            l.state == PeerLinkState.connected)
        .firstOrNull;
    return link == null ? false : _write(link, frame);
  }

  /// Writes are queued per link so chunks of different frames never interleave.
  Future<bool> _write(_Link link, Uint8List frame) {
    final result = link.writeQueue.then((_) => _writeNow(link, frame));
    link.writeQueue = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('LinkMesh: queued BLE write failed: $error');
      },
    );
    return result;
  }

  Future<bool> _writeNow(_Link link, Uint8List frame) async {
    final inbox = link.inbox;
    final peerId = link.nodeId;
    if (inbox == null ||
        peerId == null ||
        link.state != PeerLinkState.connected ||
        await messagingPolicy.isMessagingRestricted(peerId)) {
      return false;
    }
    try {
      final chunkSize = link.device.mtuNow - 3;
      for (final chunk in Chunker.split(frame, chunkSize)) {
        await inbox.write(chunk, timeout: 5);
      }
      return true;
    } catch (e) {
      debugPrint('LinkMesh: write to ${link.nodeId} failed: $e');
      return false;
    }
  }

  void _setStatus(TransportStatus status) {
    _status = status;
    _statusCtrl.add(status);
  }

  void _emitPeers() => _peersCtrl.add(peers);
}

class _Link {
  _Link(this.device);

  final BluetoothDevice device;
  String? nodeId;
  String? name;
  int rssi = -100;
  DateTime lastSeen = DateTime.now();
  DateTime lastRegistryWrite = DateTime.fromMillisecondsSinceEpoch(0);
  PeerLinkState state = PeerLinkState.discovered;
  String? connectionError;
  bool messagingRestricted = false;
  bool sawConnectedState = false;
  bool droppedDuringConnect = false;
  DateTime nextAttempt = DateTime.fromMillisecondsSinceEpoch(0);
  BluetoothCharacteristic? inbox;
  StreamSubscription<BluetoothConnectionState>? connectionSub;
  Future<void> writeQueue = Future.value();

  /// Our own advertisement, seen through the scanner.
  bool ignored = false;

  Peer toPeer() => Peer(
        address: device.remoteId.str,
        nodeId: nodeId,
        name: name,
        state: state,
        rssi: rssi,
        lastSeen: lastSeen,
        connectionError: connectionError,
      );
}
