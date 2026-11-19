import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../visualization/mesh_network_view.dart';
import '../visualization/topology.dart';
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final source = ref.watch(topologySourceProvider(_simulate));

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 0),
          child: Row(
            children: [
              Icon(
                _simulate ? Icons.science_outlined : Icons.hub_outlined,
                size: 18,
                color: _simulate ? Colors.amber.shade700 : scheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _simulate
                      ? 'Development simulation'
                      : 'Live Bluetooth discovery',
                  style: theme.textTheme.titleSmall,
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
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
            child: Text(
              'Fabricated data for development only. It does not mean a '
              'Bluetooth link exists, and it is not proof that offline '
              'phone-to-phone messaging works.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 2, 10, 4),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  gradient: RadialGradient(
                    radius: 1.1,
                    colors: [
                      scheme.primaryContainer.withValues(alpha: 0.3),
                      scheme.surface,
                    ],
                  ),
                  border: Border.all(
                    color: scheme.outlineVariant.withValues(alpha: 0.5),
                  ),
                ),
                child: MeshNetworkView(source: source),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
          child: Wrap(
            spacing: 14,
            runSpacing: 8,
            children: [
              _LegendDot(
                color: meshPhaseColor(TopologyNodePhase.local, scheme),
                label: 'This device',
              ),
              _LegendDot(
                color: meshPhaseColor(TopologyNodePhase.connected, scheme),
                label: 'Connected',
              ),
              _LegendDot(
                color: meshPhaseColor(TopologyNodePhase.connecting, scheme),
                label: 'Connecting',
              ),
              _LegendDot(
                color: meshPhaseColor(TopologyNodePhase.discovering, scheme),
                label: 'Discovering',
              ),
              _LegendDot(
                color: meshPhaseColor(TopologyNodePhase.unavailable, scheme),
                label: 'Unavailable',
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Text(
            'Pinch to zoom · drag to pan',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}
