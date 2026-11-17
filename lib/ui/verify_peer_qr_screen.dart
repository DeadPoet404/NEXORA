import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../state/providers.dart';

class VerifyPeerQrScreen extends ConsumerStatefulWidget {
  const VerifyPeerQrScreen({super.key, required this.peerId});

  final String peerId;

  @override
  ConsumerState<VerifyPeerQrScreen> createState() => _VerifyPeerQrScreenState();
}

class _VerifyPeerQrScreenState extends ConsumerState<VerifyPeerQrScreen> {
  bool _handling = false;
  String? _error;
  bool _verified = false;

  Future<void> _scan(BarcodeCapture capture) async {
    if (_handling || _verified) return;
    final raw = capture.barcodes
        .map((barcode) => barcode.rawValue)
        .whereType<String>()
        .firstOrNull;
    if (raw == null) return;

    setState(() {
      _handling = true;
      _error = null;
    });
    try {
      final service = ref.read(peerTrustServiceProvider);
      final challenge = await service.prepareVerification(
        expectedPeerId: widget.peerId,
        scannedQr: raw,
      );
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (context) => AlertDialog(
              icon: const Icon(Icons.verified_user_outlined),
              title: const Text('Compare fingerprints in person'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Peer ID: ${challenge.identity.peerId}'),
                  const SizedBox(height: 12),
                  SelectableText(
                    _group(challenge.identity.fingerprint),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Compare this full fingerprint with the other person '
                    'through a trusted in-person channel. Only continue if '
                    'every character matches.',
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('I compared them'),
                ),
              ],
            ),
          ) ??
          false;
      if (!mounted) return;
      if (confirmed) {
        await service.confirmVerification(challenge);
        ref.invalidate(peerTrustRecordProvider(widget.peerId));
        if (!mounted) return;
        setState(() => _verified = true);
      } else {
        setState(() => _handling = false);
      }
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _handling = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Verify peer identity')),
        body: _verified
            ? const _VerifiedView()
            : Column(
                children: [
                  Expanded(
                    child: MobileScanner(
                      onDetect: _scan,
                      errorBuilder: (context, error) => Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            'Camera scanner unavailable: ${error.errorCode.name}',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Text(
                          'Scan the QR shown by this peer in person. '
                          'Scanning alone does not verify the identity.',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                        if (_handling) ...[
                          const SizedBox(height: 12),
                          const CircularProgressIndicator(),
                        ],
                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            _error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
      );
}

class _VerifiedView extends StatelessWidget {
  const _VerifiedView();

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.verified, size: 64, color: Colors.green),
              const SizedBox(height: 12),
              Text('Public key pinned',
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 12),
              const Text(
                'This pins the scanned public key for this peer. It does not '
                'authenticate current BLE messages or encrypt messages; '
                'messaging remains plaintext in this build.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
}

String _group(String fingerprint) => RegExp('.{1,4}')
    .allMatches(fingerprint)
    .map((match) => match.group(0)!)
    .join(' ');
