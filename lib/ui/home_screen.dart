import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../mesh/transport.dart';
import '../models/peer.dart';
import '../models/stored_message.dart';
import '../services/permissions.dart';
import '../state/providers.dart';
import 'chat_screen.dart';
import 'chats_tab.dart';
import 'my_identity_qr_screen.dart';
import 'nearby_tab.dart';
import 'settings_sheet.dart';
import 'sos_tab.dart';
import 'widgets/signal_bars.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: 3, vsync: this);
  StreamSubscription<StoredMessage>? _sosSub;
  late final AppLifecycleListener _lifecycle;
  MeshPermissions? _permissions;
  String? _startError;

  @override
  void initState() {
    super.initState();
    _sosSub = ref.read(routerProvider).sosAlerts.listen(_showSosAlert);
    _lifecycle = AppLifecycleListener(onResume: _openPendingChat);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startMesh();
      _openPendingChat();
    });
  }

  @override
  void dispose() {
    _sosSub?.cancel();
    _lifecycle.dispose();
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _startMesh() async {
    try {
      final permissions =
          await ref.read(meshControllerProvider).requestAndStart();
      if (!mounted) return;
      setState(() {
        _permissions = permissions;
        _startError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _startError = error.toString());
    }
  }

  /// Opens the conversation (or SOS tab) for a tapped notification.
  Future<void> _openPendingChat() async {
    final peerId = await ref.read(bridgeProvider).takePendingChat();
    if (peerId == null || !mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    if (peerId == 'sos') {
      _tabs.animateTo(2);
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChatScreen(peerId: peerId),
    ));
  }

  void _showSosAlert(StoredMessage alert) {
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: scheme.error,
      content: Text(
        'SOS from ${alert.message.senderName}: ${alert.message.content}',
        style: TextStyle(color: scheme.onError),
      ),
      action: SnackBarAction(
        label: 'View',
        textColor: scheme.onError,
        onPressed: () => _tabs.animateTo(2),
      ),
    ));
  }

  void _openSettings() => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => const SettingsSheet(),
      );

  @override
  Widget build(BuildContext context) {
    final peers = ref.watch(peersProvider).value ?? const <Peer>[];
    final status = ref.watch(transportStatusProvider).value;
    final identity = ref.watch(identityProvider).value;
    final sosActive = ref.watch(sosActiveProvider).value ?? false;
    final connected =
        peers.where((p) => p.state == PeerLinkState.connected).toList();
    final bestBars = connected.fold(0, (best, p) => p.bars > best ? p.bars : best);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('LinkMesh'),
            Text(
              '${connected.length} connected · ${peers.length} peers',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
        actions: [
          SignalBars(bars: bestBars, active: connected.isNotEmpty),
          IconButton(
            tooltip: 'Show identity QR',
            icon: const Icon(Icons.qr_code_2),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const MyIdentityQrScreen(),
              ),
            ),
          ),
          IconButton(
            tooltip: identity == null ? 'Profile' : 'You: ${identity.name}',
            icon: const Icon(Icons.account_circle_outlined),
            onPressed: _openSettings,
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            const Tab(text: 'Chats'),
            Tab(text: 'Peers (${peers.length})'),
            Tab(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (sosActive) ...[
                    Icon(Icons.circle,
                        size: 8, color: Theme.of(context).colorScheme.error),
                    const SizedBox(width: 6),
                  ],
                  const Text('SOS'),
                ],
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          ?_banner(status),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: const [ChatsTab(), NearbyTab(), SosTab()],
            ),
          ),
        ],
      ),
      // Persistent emergency button, reachable from every tab.
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'sos',
        backgroundColor: Theme.of(context).colorScheme.error,
        foregroundColor: Theme.of(context).colorScheme.onError,
        icon: Icon(sosActive ? Icons.stop_circle : Icons.sos),
        label: Text(sosActive ? 'Stop SOS' : 'SOS'),
        onPressed: () => _toggleSos(sosActive),
      ),
    );
  }

  Future<void> _toggleSos(bool active) async {
    final sos = ref.read(sosServiceProvider);
    if (active) {
      sos.stop();
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.sos),
        title: const Text('Send SOS?'),
        content: const Text(
          'Your location and an emergency alert will be broadcast to every '
          'nearby device, repeating until you stop it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Send SOS'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      sos.start('');
      _tabs.animateTo(2);
    }
  }

  Widget? _banner(TransportStatus? status) {
    final permissions = _permissions;
    if (_startError != null) {
      return MaterialBanner(
        content: Text('Could not start Bluetooth: $_startError'),
        actions: [
          TextButton(onPressed: _startMesh, child: const Text('Retry')),
          TextButton(onPressed: openAppSettings, child: const Text('Settings')),
        ],
      );
    }
    if (permissions != null && !permissions.bluetooth) {
      return MaterialBanner(
        content: const Text(
          'LinkMesh needs Bluetooth permissions to find nearby devices.',
        ),
        actions: [
          TextButton(onPressed: openAppSettings, child: const Text('Settings')),
          TextButton(onPressed: _startMesh, child: const Text('Retry')),
        ],
      );
    }
    return switch (status) {
      TransportStatus.bluetoothOff => MaterialBanner(
          content: const Text('Bluetooth is off.'),
          actions: [
            if (Platform.isAndroid)
              TextButton(
                onPressed: () => FlutterBluePlus.turnOn(),
                child: const Text('Turn on'),
              )
            else
              const SizedBox.shrink(),
          ],
        ),
      TransportStatus.unsupported => const MaterialBanner(
          content: Text('This device does not support Bluetooth Low Energy.'),
          actions: [SizedBox.shrink()],
        ),
      TransportStatus.permissionDenied => MaterialBanner(
          content: const Text(
            'Bluetooth permission was denied. Allow it to scan and connect.',
          ),
          actions: [
            TextButton(onPressed: _startMesh, child: const Text('Retry')),
            TextButton(onPressed: openAppSettings, child: const Text('Settings')),
          ],
        ),
      TransportStatus.scanFailed => MaterialBanner(
          content: const Text('Bluetooth scan failed. Nearby discovery may be stale.'),
          actions: [
            TextButton(onPressed: _startMesh, child: const Text('Retry')),
          ],
        ),
      TransportStatus.receiveUnavailable => const MaterialBanner(
          content: Text(
            'Bluetooth advertising is unavailable. This device may send, '
            'but nearby peers may not be able to connect back.',
          ),
          actions: [SizedBox.shrink()],
        ),
      _ when permissions != null && !permissions.location => MaterialBanner(
          content: const Text(
            'Location is off: SOS will be sent without coordinates, and '
            'Android 11 and older cannot scan for devices.',
          ),
          actions: [
            TextButton(onPressed: _startMesh, child: const Text('Allow')),
          ],
        ),
      _ => null,
    };
  }
}
