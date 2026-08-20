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

  /// Waits for a controlled UI response to a validated AskPass request.
  ///
  /// A session is single-use, so a second request is rejected instead of
  /// replacing the visible prompt or retaining multiple secret responses.
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
  void submit(String? secret) => _complete(secret);

  /// Rejects the active prompt, for example when the Git operation is
  /// cancelled or its one-time session is closed.
  void cancel() => _complete(null);

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
