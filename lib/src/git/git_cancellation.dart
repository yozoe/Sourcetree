import 'dart:async';
import 'dart:io';

typedef GitCancellationCallback = void Function();

/// A cooperative cancellation token shared by a caller and [GitRunner].
final class GitCancellationToken {
  final Set<GitCancellationCallback> _callbacks = {};
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  void cancel() {
    if (_isCancelled) {
      return;
    }
    _isCancelled = true;
    for (final callback in List<GitCancellationCallback>.of(_callbacks)) {
      callback();
    }
    _callbacks.clear();
  }

  GitCancellationRegistration register(GitCancellationCallback callback) {
    if (_isCancelled) {
      callback();
      return const GitCancellationRegistration._();
    }
    _callbacks.add(callback);
    return GitCancellationRegistration._(() => _callbacks.remove(callback));
  }
}

final class GitCancellationRegistration {
  const GitCancellationRegistration._([this._dispose]);

  final void Function()? _dispose;

  void dispose() => _dispose?.call();
}

/// Platform implementations can replace this to terminate a complete process
/// tree. The default implementation terminates the direct Git process.
abstract interface class GitProcessTerminator {
  FutureOr<void> terminate(Process process);
}

final class DefaultGitProcessTerminator implements GitProcessTerminator {
  const DefaultGitProcessTerminator();

  @override
  void terminate(Process process) {
    process.kill();
  }
}
