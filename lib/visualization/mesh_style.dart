import 'dart:ui';

import 'topology.dart';

/// Colours for the network visualization.
///
/// The Network tab is a dark instrument panel regardless of the app theme, so
/// these are explicit constants rather than `ColorScheme` lookups: the palette
/// must stay stable on both light and dark app themes.
class MeshPalette {
  MeshPalette._();

  /// Page background behind the tab's cards.
  static const appBackground = Color(0xFF080D16);

  /// The network canvas itself.
  static const canvas = Color(0xFF0B1421);

  /// Raised chips, pills and control surfaces.
  static const surface = Color(0xFF111D2C);

  /// Primary accent: this device, live links, message particles.
  static const accent = Color(0xFF20E0C1);

  /// Secondary accent: negotiating links, relayed hops.
  static const accentSecondary = Color(0xFF788BFF);

  static const connected = Color(0xFF20E0C1);
  static const connecting = Color(0xFF5CB8FF);
  static const discovering = Color(0xFF788BFF);
  static const unavailable = Color(0xFF64748B);

  /// Restrained amber for the development-simulation indicator only.
  static const warn = Color(0xFFF3B24B);

  static const textPrimary = Color(0xFFE7F0FA);
  static const textSecondary = Color(0xFF8FA6BE);

  /// Very faint dots for the canvas texture.
  static const gridDot = Color(0x12FFFFFF);

  /// Borders on translucent surfaces.
  static const hairline = Color(0x24FFFFFF);

  /// Fill inside a peer node.
  static const nodeFill = Color(0xFF0E1B29);
}

/// Colour for a node phase, shared by the canvas and the legend so the two can
/// never drift apart.
Color meshPhaseColor(TopologyNodePhase phase) => switch (phase) {
      TopologyNodePhase.local => MeshPalette.accent,
      TopologyNodePhase.connected => MeshPalette.connected,
      TopologyNodePhase.connecting => MeshPalette.connecting,
      TopologyNodePhase.discovering => MeshPalette.discovering,
      TopologyNodePhase.unavailable => MeshPalette.unavailable,
    };
