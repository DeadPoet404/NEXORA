import 'dart:async';

/// Serializes stateful cryptographic/storage operations per peer.
///
/// Different peers remain independent. Failures are returned to the caller,
/// but they do not poison the queue or skip later operations for that peer.
class PeerOperationQueue {
  final Map<String, Future<void>> _tails = {};

  Future<T> run<T>(String peerId, FutureOr<T> Function() operation) {
    if (peerId.isEmpty) {
      throw ArgumentError.value(peerId, 'peerId', 'Must not be empty');
    }

    final result = Completer<T>();
    final previous = _tails[peerId] ?? Future<void>.value();
    late final Future<void> next;
    next = previous.then((_) async {
      try {
        result.complete(await operation());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    _tails[peerId] = next;
    unawaited(next.whenComplete(() {
      if (identical(_tails[peerId], next)) _tails.remove(peerId);
    }));
    return result.future;
  }
}
