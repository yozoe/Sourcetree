import 'dart:async';
import 'dart:io';

typedef GitCancellationCallback = void Function();

/// A cooperative cancellation token shared by a caller and [GitRunner].
final class GitCancellationToken {
  final Set<GitCancellationCallback> _callbacks = {};
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  /// 中文：取消当前操作。
  /// English: Cancels the current operation.
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

  /// 中文：注册取消回调；若已取消则立即调用，并返回可安全释放的注册项。
  ///
  /// English: Registers a cancellation callback, invoking it immediately if
  /// already cancelled, and returns a safely disposable registration.
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

  /// 中文：释放当前对象持有的资源。
  /// English: Releases resources held by this object.
  void dispose() => _dispose?.call();
}

/// Platform implementations can replace this to terminate a complete process
/// tree. The default implementation terminates the direct Git process.
abstract interface class GitProcessTerminator {
  /// 中文：终止指定 Git 进程，平台实现可同时清理其子进程树。
  ///
  /// English: Terminates the supplied Git process; platform implementations
  /// may also clean up its child process tree.
  FutureOr<void> terminate(Process process);
}

final class DefaultGitProcessTerminator implements GitProcessTerminator {
  const DefaultGitProcessTerminator();

  /// 中文：终止直接启动的 Git 进程。
  ///
  /// English: Terminates the directly started Git process.
  @override
  void terminate(Process process) {
    process.kill();
  }
}
