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

  /// 中文：处理 register 相关逻辑。
  /// English: Handles the register related logic.
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
  /// 中文：处理 terminate 相关逻辑。
  /// English: Handles the terminate related logic.
  FutureOr<void> terminate(Process process);
}

final class DefaultGitProcessTerminator implements GitProcessTerminator {
  const DefaultGitProcessTerminator();

  /// 中文：处理 terminate 相关逻辑。
  /// English: Handles the terminate related logic.
  @override
  void terminate(Process process) {
    process.kill();
  }
}
