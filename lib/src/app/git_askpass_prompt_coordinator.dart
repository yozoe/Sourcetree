import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../git/git.dart';

/// Delivers the one validated AskPass request of an active Git operation to
/// the UI without retaining its answer in application state.
final gitAskPassPromptCoordinatorProvider =
    NotifierProvider<GitAskPassPromptCoordinator, GitAskPassRequest?>(
      GitAskPassPromptCoordinator.new,
    );

final class GitAskPassPromptCoordinator extends Notifier<GitAskPassRequest?> {
  Completer<String?>? _response;

  @override
  GitAskPassRequest? build() {
    ref.onDispose(_dispose);
    return null;
  }

  /// 中文：显示已验证的 AskPass 请求并等待受控 UI 的一次响应；第二个请求会被拒绝。
  ///
  /// English: Exposes a validated AskPass request and waits for one controlled
  /// UI response; a second request is rejected.
  Future<String?> request(GitAskPassRequest request) {
    if (_response != null) {
      return Future<String?>.value();
    }
    final response = Completer<String?>();
    _response = response;
    state = request;
    return response.future;
  }

  /// Returns the current prompt answer exactly once. The value is passed to
  /// the AskPass session but is never stored in Riverpod state.
  /// 中文：提交当前表单或请求。
  /// English: Submits the current form or request.
  void submit(String? secret) => _complete(secret);

  /// Rejects the active prompt, for example when the Git operation is
  /// cancelled or its one-time session is closed.
  /// 中文：取消当前操作。
  /// English: Cancels the current operation.
  void cancel() => _complete(null);

  /// 中文：仅完成当前未决请求一次，并在完成前清除可见的提示状态。
  ///
  /// English: Completes the current pending request at most once and clears
  /// the visible prompt state first.
  void _complete(String? secret) {
    final response = _response;
    if (response == null) {
      return;
    }
    _response = null;
    state = null;
    if (!response.isCompleted) {
      response.complete(secret);
    }
  }

  /// 中文：释放当前对象持有的资源。
  /// English: Releases resources held by this object.
  void _dispose() {
    final response = _response;
    _response = null;
    // Riverpod is disposing the provider, so writing [state] here is invalid.
    // Completing the pending callback still lets the session reject safely.
    if (response != null && !response.isCompleted) {
      response.complete(null);
    }
  }
}
