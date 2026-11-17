import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../security/public_identity.dart';
import '../state/providers.dart';

class MyIdentityQrScreen extends ConsumerStatefulWidget {
  const MyIdentityQrScreen({super.key});

  @override
  ConsumerState<MyIdentityQrScreen> createState() =>
      _MyIdentityQrScreenState();
}

class _MyIdentityQrScreenState extends ConsumerState<MyIdentityQrScreen> {
  late final Future<PublicIdentityMaterial?> _identity =
      ref.read(localIdentityProvider).currentPublicIdentity();

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('My identity QR')),
        body: FutureBuilder<PublicIdentityMaterial?>(
          future: _identity,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return _IdentityLoadError(error: snapshot.error!);
            }
            final identity = snapshot.data;
            if (identity == null) {
              return const _IdentityUnavailable();
            }
            final qr = IdentityQrPayload.fromIdentity(identity);
            return ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  'Let someone scan this while you are together in person.',
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Center(
                  child: QrImageView(
                    data: qr.encode(),
                    size: 260,
                    backgroundColor: Colors.white,
                    semanticsLabel: 'Public identity verification QR code',
                  ),
                ),
                const SizedBox(height: 16),
                SelectableText(
                  _group(identity.fingerprint),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontFamily: 'monospace',
                      ),
                ),
                const SizedBox(height: 16),
                const _PlaintextNotice(),
              ],
            );
          },
        ),
      );
}

class _IdentityLoadError extends StatelessWidget {
  const _IdentityLoadError({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Could not load the configured local identity. No QR was created. '
            'Details: $error',
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      );
}

class _IdentityUnavailable extends StatelessWidget {
  const _IdentityUnavailable();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Card(
          color: scheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.key_off, color: scheme.onErrorContainer, size: 36),
                const SizedBox(height: 12),
                Text(
                  'Cryptographic identity is not configured',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: scheme.onErrorContainer,
                      ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'This device currently has only a mesh node ID and display '
                  'name. Those are not cryptographic identity keys, so this '
                  'app will not create a QR code that could be mistaken for '
                  'identity verification.',
                  style: TextStyle(color: scheme.onErrorContainer),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PlaintextNotice extends StatelessWidget {
  const _PlaintextNotice();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          'QR verification pins a public key only. Messaging in this build is '
          'still plaintext and is not end-to-end encrypted.',
          style: TextStyle(color: scheme.onTertiaryContainer),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

String _group(String fingerprint) => RegExp('.{1,4}')
    .allMatches(fingerprint)
    .map((match) => match.group(0)!)
    .join(' ');
