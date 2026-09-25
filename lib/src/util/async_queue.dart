import 'dart:async';
import 'dart:collection';

import '../exceptions.dart';

/// A single-consumer FIFO whose reads can wait, time out, and be failed.
///
/// The wire protocols receive packets as a push stream from the platform but
/// consume them as request/response pairs; this is the seam between the two.
/// A terminal error (disconnect, protocol violation) is sticky: every pending
/// and later [next] fails with it, so nothing waits on a dead link forever.
class AsyncQueue<T> {
  final Queue<T> _items = Queue<T>();
  Completer<T>? _waiter;
  Object? _error;
  StackTrace? _errorStack;

  bool get isEmpty => _items.isEmpty;

  void add(T item) {
    if (_error != null) return;
    final waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) {
      _waiter = null;
      waiter.complete(item);
    } else {
      _items.add(item);
    }
  }

  /// Fails the queue permanently.
  void fail(Object error, [StackTrace? stackTrace]) {
    if (_error != null) return;
    _error = error;
    _errorStack = stackTrace;
    final waiter = _waiter;
    _waiter = null;
    if (waiter != null && !waiter.isCompleted) {
      waiter.completeError(error, stackTrace);
    }
  }

  void clear() => _items.clear();

  Future<T> next({Duration? timeout}) {
    if (_items.isNotEmpty) return Future.value(_items.removeFirst());
    if (_error != null) return Future.error(_error!, _errorStack);
    if (_waiter != null) {
      throw StateError('AsyncQueue supports a single pending reader');
    }
    final waiter = Completer<T>();
    _waiter = waiter;
    if (timeout == null) return waiter.future;
    return waiter.future.timeout(
      timeout,
      onTimeout: () {
        if (identical(_waiter, waiter)) _waiter = null;
        throw TrezorTimeoutException('No response within $timeout');
      },
    );
  }
}

/// Serializes async critical sections, in call order.
class AsyncLock {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    // The next section waits for this one to settle, but not on its outcome.
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }
}
