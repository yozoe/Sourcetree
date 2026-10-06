part of 'repository_session.dart';

/// Stash mutations owned by [RepositorySessionController].
///
/// 中文：集中维护贮藏创建、恢复、弹出、删除和取消；读取列表仍由主 controller
/// 保留，所有写操作继续共享同一取消、刷新与不确定结果语义。
extension RepositorySessionStashWrites on RepositorySessionController {
  /// Saves eligible working-tree changes in a new stash and refreshes all
  /// Git-backed state after Git completes.
  /// 中文：将可保存的改动创建为新贮藏；可选择包含未跟踪文件或保留暂存区。
  Future<bool> createStash(
    String message, {
    bool includeUntracked = false,
    bool keepIndex = false,
  }) async {
    if (!_isInsideTrackedGitTask) {
      return _trackBooleanGitTask(
        () => createStash(
          message,
          includeUntracked: includeUntracked,
          keepIndex: keepIndex,
        ),
      );
    }
    final status = _sessionState.status;
    final hasTrackedChanges =
        status?.displayEntries.any(
          (entry) =>
              entry.kind != GitFileStatusKind.untracked &&
              (entry.hasStagedChange || entry.hasWorkTreeChange),
        ) ??
        false;
    final hasUntrackedChanges =
        status?.displayEntries.any(
          (entry) => entry.kind == GitFileStatusKind.untracked,
        ) ??
        false;
    if (!_canMutateStashes ||
        status == null ||
        status.conflictedEntries.isNotEmpty ||
        (!hasTrackedChanges && !(includeUntracked && hasUntrackedChanges))) {
      return false;
    }
    return _runStashMutation(
      successMessage: '已创建贮藏。',
      write: (repository, cancellation) => _writer.createStash(
        repository,
        message: message,
        includeUntracked: includeUntracked,
        keepIndex: keepIndex,
        cancellationToken: cancellation,
      ),
    );
  }

  /// Applies one stash while retaining it in Git's stash reflog.
  /// 中文：恢复指定贮藏并保留该条目，仅允许在干净工作区执行。
  Future<bool> applyStash(GitStashEntry stash) =>
      _trackBooleanGitTask(() => _restoreStash(stash, pop: false));

  /// Applies one stash and lets Git remove it only after a successful restore.
  /// 中文：恢复并弹出指定贮藏；冲突时保留条目。
  Future<bool> popStash(GitStashEntry stash) =>
      _trackBooleanGitTask(() => _restoreStash(stash, pop: true));

  /// Drops one stash after the presentation layer has obtained confirmation.
  /// 中文：删除指定贮藏；确认由界面层负责。
  Future<bool> dropStash(GitStashEntry stash) async {
    if (!_isInsideTrackedGitTask) {
      return _trackBooleanGitTask(() => dropStash(stash));
    }
    if (!_canMutateStashes || !await _isCurrentStash(stash)) return false;
    return _runStashMutation(
      successMessage: '已删除贮藏。',
      write: (repository, cancellation) => _writer.dropStash(
        repository,
        stashReference: stash.reference,
        cancellationToken: cancellation,
      ),
    );
  }

  /// 中文：判断当前仓库是否允许安全开始一项贮藏写操作。
  /// English: Returns whether the current repository can safely start a stash
  /// mutation.
  bool get _canMutateStashes {
    final repository = _sessionState.repository;
    return repository != null &&
        repository.workTreeRoot != null &&
        _sessionState.phase != RepositorySessionPhase.loading &&
        _sessionState.operationState == GitRepositoryOperationState.none;
  }

  /// 中文：在干净工作区恢复或弹出指定贮藏，把冲突状态交还给 Git 和刷新流程。
  Future<bool> _restoreStash(GitStashEntry stash, {required bool pop}) async {
    final status = _sessionState.status;
    if (!_canMutateStashes ||
        status == null ||
        !status.isClean ||
        status.conflictedEntries.isNotEmpty ||
        !await _isCurrentStash(stash)) {
      return false;
    }
    return _runStashMutation(
      successMessage: pop ? '已恢复并弹出贮藏。' : '已恢复贮藏。',
      conflictMessage: pop
          ? '恢复贮藏时发生冲突；贮藏已保留，请解决冲突后继续。'
          : '恢复贮藏时发生冲突；贮藏仍已保留，请解决冲突后继续。',
      write: (repository, cancellation) => pop
          ? _writer.popStash(
              repository,
              stashReference: stash.reference,
              cancellationToken: cancellation,
            )
          : _writer.applyStash(
              repository,
              stashReference: stash.reference,
              cancellationToken: cancellation,
            ),
    );
  }

  /// 中文：确认贮藏列表在用户确认后仍指向同一个 Git 对象，避免 reflog 索引漂移。
  Future<bool> _isCurrentStash(GitStashEntry expected) async {
    final repository = _sessionState.repository;
    if (repository == null) return false;
    try {
      final stashes = await _reader.readStashes(repository);
      final matches = stashes.any(
        (stash) =>
            stash.reference == expected.reference &&
            stash.objectId == expected.objectId,
      );
      if (matches) return true;
    } on Object {
      // A reader failure also means it is unsafe to operate on a positional
      // stash reference, so surface the same stale-list guidance below.
    }
    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.error,
      isStashRunning: false,
      message: '贮藏列表已发生变化，请重新打开管理面板后再操作。',
    );
    return false;
  }

  /// 中文：串行执行一项贮藏写操作，完成、失败或取消后均重新读取 Git 状态。
  Future<bool> _runStashMutation({
    required String successMessage,
    String? conflictMessage,
    required Future<void> Function(GitRepository, GitCancellationToken) write,
  }) async {
    final repository = _sessionState.repository;
    if (repository == null) return false;
    final cancellation = GitCancellationToken();
    _stashCancellation = cancellation;
    final operation = _startOperation(RepositoryOperationKind.stash);
    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isStashRunning: true,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    try {
      await write(repository, cancellation);
      await refresh();
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded
            ? successMessage
            : '贮藏操作可能已完成，但本地刷新失败；请刷新确认贮藏和工作区状态。',
      );
      return succeeded;
    } on Object catch (error, stackTrace) {
      await refresh();
      final message =
          error is GitCommandException &&
              error.kind == GitErrorKind.conflicts &&
              conflictMessage != null
          ? conflictMessage
          : _friendlyError(error);
      _sessionState = _sessionState.copyWith(
        phase: RepositorySessionPhase.error,
        isStashRunning: false,
        isDiffLoading: false,
        message: message,
        technicalDetails: _technicalDetails(error, stackTrace),
      );
      _completeOperation(
        operation,
        outcome: _operationOutcomeForError(error),
        message: message,
      );
      return false;
    } finally {
      if (identical(_stashCancellation, cancellation)) {
        _stashCancellation = null;
      }
    }
  }

  /// 中文：取消当前贮藏操作；进程结束后会刷新仓库状态。
  /// English: Cancels the active stash process; repository state is refreshed
  /// once the process exits.
  void cancelStash() => _stashCancellation?.cancel();
}
