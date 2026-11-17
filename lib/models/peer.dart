import '../core/constants.dart';

enum PeerLinkState { discovered, connecting, connected, disconnected }

/// BLE link state is independent from QR identity trust state.
enum SignalQuality { connected, weak, disconnected }

class Peer {
  const Peer({
    required this.address,
    required this.state,
    required this.rssi,
    required this.lastSeen,
    this.nodeId,
    this.name,
    this.connectionError,
  });

  /// Ephemeral transport locator (BLE address on Android); not a peer identity.
  final String address;

  /// Persistent installation-scoped mesh node ID read from GATT. This is not
  /// a cryptographic identity and must not be used as proof of authenticity.
  final String? nodeId;
  final String? name;
  final PeerLinkState state;
  final int rssi;
  final DateTime lastSeen;
  final String? connectionError;

  String get displayName {
    final displayName = name;
    if (displayName != null && displayName.isNotEmpty) return displayName;
    if (nodeId == null) return address;
    return nodeId!.length > 8 ? nodeId!.substring(0, 8) : nodeId!;
  }

  SignalQuality get quality {
    if (state != PeerLinkState.connected) return SignalQuality.disconnected;
    return rssi < BleConstants.weakRssi
        ? SignalQuality.weak
        : SignalQuality.connected;
  }

  /// 0–4 bars, for signal strength indicators.
  int get bars {
    if (rssi >= -60) return 4;
    if (rssi >= -70) return 3;
    if (rssi >= -80) return 2;
    if (rssi >= -90) return 1;
    return 0;
  }
}
