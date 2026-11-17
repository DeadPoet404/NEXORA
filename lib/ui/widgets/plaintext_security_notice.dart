import 'package:flutter/material.dart';

/// Persistent UI warning while no reviewed message-protection backend exists.
class PlaintextSecurityNotice extends StatelessWidget {
  const PlaintextSecurityNotice({
    super.key,
    this.message = 'Messages are plaintext in this development build. '
        'Do not send sensitive information.',
  });

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Plaintext security warning. $message',
      child: Material(
        color: scheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.lock_open, color: scheme.onErrorContainer, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(
                    color: scheme.onErrorContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
