import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../visualization/mesh_network_view.dart';
import '../visualization/mesh_style.dart';
import '../visualization/topology_providers.dart';

/// Shows how this device and its neighbours are connected.
///
/// The data source is either real BLE discovery or, in development builds, an
/// explicitly labelled simulation. Nothing here sends messages or changes
/// peer state.
class NetworkTab extends ConsumerStatefulWidget {
  const NetworkTab({super.key});

  @override
  ConsumerState<NetworkTab> createState() => _NetworkTabState();
}

class _NetworkTabState extends ConsumerState<NetworkTab> {
  /// Debug builds start on the labelled simulation because there is no
  /// guarantee that physical peers are in range; release builds never do.
  bool _simulate = kDebugMode;

  @override
  Widget build(BuildContext context) {
    final source = ref.watch(topologySourceProvider(_simulate));

    return ColoredBox(
      color: MeshPalette.appBackground,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 10, 0),
            child: Row(
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: (_simulate ? MeshPalette.warn : MeshPalette.accent)
                        .withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: (_simulate ? MeshPalette.warn : MeshPalette.accent)
                          .withValues(alpha: 0.30),
                    ),
                  ),
                  child: Icon(
                    _simulate ? Icons.science_outlined : Icons.hub_outlined,
                    size: 14,
                    color: _simulate ? MeshPalette.warn : MeshPalette.accent,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _simulate
                            ? 'Development simulation'
                            : 'Live Bluetooth discovery',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: MeshPalette.textPrimary,
                        ),
                      ),
                      Text(
                        _simulate
                            ? 'Fabricated peers, no radio involved'
                            : 'Read-only view of this device\'s peers',
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: MeshPalette.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (kDebugMode)
                  Switch.adaptive(
                    value: _simulate,
                    onChanged: (value) => setState(() => _simulate = value),
                  ),
              ],
            ),
          ),
          if (_simulate)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 1),
                    child: Icon(
                      Icons.info_outline,
                      size: 13,
                      color: MeshPalette.warn,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Fabricated data for development only. It does not mean a '
                      'Bluetooth link exists, and it is not proof that offline '
                      'phone-to-phone messaging works.',
                      style: TextStyle(
                        fontSize: 10.5,
                        height: 1.35,
                        color: MeshPalette.textSecondary.withValues(alpha: 0.9),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 2, 10, 4),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: MeshPalette.hairline),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 18,
                      offset: Offset(0, 6),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(17),
                  child: MeshNetworkView(
                    source: source,
                    // Larger radii keep labels from colliding with the drawn
                    // nodes on phone-sized canvases.
                    localDiameter: 76,
                    peerDiameter: 44,
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: Wrap(
              spacing: 14,
              runSpacing: 8,
              children: const [
                _LegendDot(
                  color: MeshPalette.accent,
                  label: 'This device',
                  ring: true,
                ),
                _LegendDot(
                  color: MeshPalette.connected,
                  label: 'Connected',
                ),
                _LegendDot(
                  color: MeshPalette.connecting,
                  label: 'Connecting',
                ),
                _LegendDot(
                  color: MeshPalette.discovering,
                  label: 'Discovering',
                ),
                _LegendDot(
                  color: MeshPalette.unavailable,
                  label: 'Unavailable',
                  hollow: true,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.open_with,
                  size: 12,
                  color: MeshPalette.textSecondary,
                ),
                const SizedBox(width: 5),
                Text(
                  'Pinch to zoom · drag to pan',
                  style: TextStyle(
                    fontSize: 10,
                    color: MeshPalette.textSecondary.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({
    required this.color,
    required this.label,
    this.ring = false,
    this.hollow = false,
  });

  final Color color;
  final String label;

  /// Draws the double ring used by this device's node.
  final bool ring;

  /// Draws an outline only, matching static unavailable peers.
  final bool hollow;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: hollow ? Colors.transparent : color.withValues(alpha: 0.9),
            border: Border.all(
              color: color.withValues(alpha: hollow ? 0.5 : 0.9),
              width: 1.2,
            ),
          ),
          child: ring
              ? Container(
                  width: 4,
                  height: 4,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: MeshPalette.canvas,
                  ),
                )
              : null,
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(
            fontSize: 10.5,
            color: MeshPalette.textSecondary,
          ),
        ),
      ],
    );
  }
}
