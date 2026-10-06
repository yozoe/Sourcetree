part of 'repository_session.dart';

/// Branch checkout, merge and reference mutations owned by
/// [RepositorySessionController].
///
/// 中文：集中维护分支检出、远端分支切换、重命名、删除和合并，保持 Git 刷新、
/// 冲突恢复与部分成功语义。
extension RepositorySessionBranchWrites on RepositorySessionController {
  /// Checks out a commit in detached HEAD mode, letting Git reject conflicts.
  /// 中文：以分离 HEAD 模式检出提交，由 Git 拒绝会覆盖本地改动的情况。
  Future<bool> checkoutCommit(String objectId) async =>
      await _trackGitTask<bool>(() => _checkoutCommit(objectId)) ?? false;

  /// 中文：在关闭屏障内以分离 HEAD 检出提交。
  /// English: Checks out a detached commit inside the shutdown barrier.
  Future<bool> _checkoutCommit(String objectId) async {
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    if (repository == null ||
        status == null ||
        _sessionState.phase == RepositorySessionPhase.loading) {
      return false;
    }
    final normalizedId = objectId.trim();
    if (normalizedId.isEmpty) return false;

    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    final operation = _startOperation(RepositoryOperationKind.ref);
    try {
      await _writer.checkoutCommit(repository, objectId: normalizedId);
      await refresh();
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded ? '已检出提交。' : '检出可能已完成，但本地刷新失败；请刷新确认 HEAD 状态。',
      );
      return succeeded;
    } on Object catch (error, stackTrace) {
      await refresh();
      _sessionState = _sessionState.copyWith(
        phase: RepositorySessionPhase.error,
        isDiffLoading: false,
        message: _friendlyError(error),
        technicalDetails: _technicalDetails(error, stackTrace),
      );
      _completeOperation(
        operation,
        outcome: _operationOutcomeForError(error),
        message: _friendlyError(error),
      );
      return false;
    }
  }

  /// 中文：仅在工作区干净且分支仍存在于已读取远端引用中时，创建本地跟踪分支并切换过去。
  ///
  /// English: Creates and switches to a local tracking branch only when the
  /// work tree is clean and the branch remains in the loaded remote refs.
  Future<bool> switchToRemoteBranch(String remoteName) async =>
      await _trackGitTask<bool>(() => _switchToRemoteBranch(remoteName)) ??
      false;

  /// 中文：在关闭屏障内创建并切换远端跟踪分支。
  /// English: Creates and switches a remote-tracking branch inside the
  /// shutdown barrier.
  Future<bool> _switchToRemoteBranch(String remoteName) async {
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    if (repository == null ||
        status == null ||
        !status.isClean ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        !_sessionState.remoteBranches.any(
          (branch) => branch.name == remoteName,
        )) {
      return false;
    }

    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    final operation = _startOperation(RepositoryOperationKind.ref);
    try {
      await _writer.switchToRemoteBranch(repository, remoteName: remoteName);
      await refresh();
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded
            ? '已切换到远端分支 $remoteName。'
            : '远端分支可能已切换，但本地刷新失败；请刷新确认引用状态。',
      );
      return succeeded;
    } on Object catch (error, stackTrace) {
      await refresh();
      _sessionState = _sessionState.copyWith(
        phase: RepositorySessionPhase.error,
        isDiffLoading: false,
        message: _friendlyError(error),
        technicalDetails: _technicalDetails(error, stackTrace),
      );
      _completeOperation(
        operation,
        outcome: _operationOutcomeForError(error),
        message: _friendlyError(error),
      );
      return false;
    }
  }

  /// 中文：重命名仍被加载的本地分支，不触碰工作区文件且不允许覆盖已有分支。
  ///
  /// English: Renames a loaded local branch without touching work-tree files
  /// and never allows Git to overwrite an existing branch.
  Future<bool> renameLocalBranch(String oldName, String newName) async {
    if (!_isInsideTrackedGitTask) {
      return _trackBooleanGitTask(() => renameLocalBranch(oldName, newName));
    }
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    if (repository == null ||
        status == null ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        !_sessionState.localBranches.any((branch) => branch.name == oldName)) {
      return false;
    }
    if (oldName.trim().isEmpty || newName.trim().isEmpty) {
      throw ArgumentError('Both the old and new branch names are required.');
    }
    if (oldName == newName) return true;

    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    final operation = _startOperation(RepositoryOperationKind.ref);
    try {
      await _writer.renameLocalBranch(
        repository,
        oldName: oldName,
        newName: newName,
      );
      await refresh();
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded
            ? '已将分支 $oldName 重命名为 $newName。'
            : '分支可能已重命名，但本地刷新失败；请刷新确认引用状态。',
      );
      return succeeded;
    } on Object catch (error, stackTrace) {
      await refresh();
      _sessionState = _sessionState.copyWith(
        phase: RepositorySessionPhase.error,
        isDiffLoading: false,
        message: _friendlyError(error),
        technicalDetails: _technicalDetails(error, stackTrace),
      );
      _completeOperation(
        operation,
        outcome: _operationOutcomeForError(error),
        message: _friendlyError(error),
      );
      return false;
    }
  }

  /// 中文：仅删除已加载且非当前的本地分支；Git 会拒绝删除尚未合并的提交。
  ///
  /// English: Deletes only a loaded, non-current local branch; Git refuses to
  /// delete a branch whose commits are not safely merged.
  Future<bool> deleteMergedLocalBranch(String name) async {
    return deleteBranches(localBranchNames: [name]);
  }

  /// 中文：删除用户在分支面板中明确选择的本地和远端分支；本地强制删除必须已由界面确认。
  ///
  /// English: Deletes local and remote branches explicitly selected in the
  /// branch panel. Local force deletion must already have user confirmation.
  Future<bool> deleteBranches({
    List<String> localBranchNames = const [],
    List<String> remoteBranchNames = const [],
    bool forceLocal = false,
  }) async {
    if (!_isInsideTrackedGitTask) {
      return _trackBooleanGitTask(
        () => deleteBranches(
          localBranchNames: localBranchNames,
          remoteBranchNames: remoteBranchNames,
          forceLocal: forceLocal,
        ),
      );
    }
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    final currentBranch = status?.branch.head;
    final localNames = localBranchNames.map((name) => name.trim()).toSet();
    final remoteNames = remoteBranchNames.map((name) => name.trim()).toSet();
    if (repository == null ||
        status == null ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        localNames.isEmpty && remoteNames.isEmpty) {
      return false;
    }
    if (localNames.any((name) => name.isEmpty) ||
        remoteNames.any((name) => name.isEmpty) ||
        localNames.contains(currentBranch) ||
        !localNames.every(
          (name) =>
              _sessionState.localBranches.any((branch) => branch.name == name),
        ) ||
        !remoteNames.every(
          (name) =>
              _sessionState.remoteBranches.any((branch) => branch.name == name),
        )) {
      return false;
    }

    final operation = _startOperation(RepositoryOperationKind.history);
    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    var completedCount = 0;
    final requestedCount = localNames.length + remoteNames.length;
    try {
      for (final name in localNames) {
        await _writer.deleteLocalBranch(
          repository,
          name: name,
          force: forceLocal,
        );
        completedCount++;
      }
      for (final name in remoteNames) {
        await _writer.deleteRemoteBranch(repository, remoteName: name);
        completedCount++;
      }
      await refresh();
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : completedCount > 0
            ? RepositoryOperationOutcome.uncertain
            : RepositoryOperationOutcome.failed,
        message: succeeded
            ? '已删除 $requestedCount 个引用。'
            : completedCount > 0
            ? '已完成引用删除，但刷新失败；请刷新确认实际状态。'
            : _sessionState.message,
      );
      return succeeded;
    } on Object catch (error, stackTrace) {
      // Earlier selected branches may already have been deleted before a later
      // local or remote deletion fails. Refresh so the UI never keeps stale
      // refs after a partially completed batch.
      await refresh();
      _sessionState = _sessionState.copyWith(
        phase: RepositorySessionPhase.error,
        isDiffLoading: false,
        message: _friendlyError(error),
        technicalDetails: _technicalDetails(error, stackTrace),
      );
      _completeOperation(
        operation,
        outcome: completedCount > 0
            ? RepositoryOperationOutcome.partiallySucceeded
            : _operationOutcomeForError(error),
        message: completedCount > 0
            ? '已完成 $completedCount/$requestedCount 个删除操作；其余操作失败，请检查仓库状态。'
            : _friendlyError(error),
      );
      return false;
    }
  }

  /// 中文：将指定本地分支合并到当前分支；来源不是当前分支、来源已加载且当前没有未解决冲突时执行。
  /// 普通未提交改动的兼容性由 Git 判断，避免在界面层过早禁用操作。
  /// 合并冲突会保留在仓库中并刷新为可见冲突状态，但不会自动继续或中止。
  ///
  /// English: Merges a loaded local source branch into the current branch when
  /// it is distinct from the current branch and no unresolved conflicts exist.
  /// Git determines whether ordinary working-tree changes are compatible.
  /// Merge conflicts remain in the repository and are refreshed for display;
  /// they are never continued or aborted automatically.
  Future<bool> mergeLocalBranch(String sourceName) async {
    if (!_isInsideTrackedGitTask) {
      return _trackBooleanGitTask(() => mergeLocalBranch(sourceName));
    }
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    final currentBranch = status?.branch.head;
    if (repository == null ||
        status == null ||
        currentBranch == null ||
        status.conflictedEntries.isNotEmpty ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        sourceName == currentBranch ||
        !_sessionState.localBranches.any(
          (branch) => branch.name == sourceName,
        )) {
      return false;
    }

    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    final operation = _startOperation(RepositoryOperationKind.history);
    try {
      await _writer.mergeLocalBranch(repository, sourceName: sourceName);
      await refresh();
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded
            ? '已合并分支 $sourceName。'
            : '合并可能已完成，但本地刷新失败；请刷新确认合并状态。',
      );
      return succeeded;
    } on Object catch (error, stackTrace) {
      // A failed merge can leave conflict entries and MERGE_HEAD behind. Read
      // them before showing the error so the user sees the actual recovery
      // _sessionState instead of the pre-merge snapshot.
      await refresh();
      final hasConflicts =
          _sessionState.status?.conflictedEntries.isNotEmpty ?? false;
      final message =
          hasConflicts ||
              (error is GitCommandException &&
                  error.kind == GitErrorKind.conflicts)
          ? '合并遇到冲突。请处理并暂存冲突后，从“动作”菜单继续或中止合并。'
          : _friendlyError(error);
      _sessionState = _sessionState.copyWith(
        phase: RepositorySessionPhase.error,
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
    }
  }

  /// 中文：将已加载历史中的指定提交合并到当前分支，并在失败后刷新冲突状态。
  ///
  /// English: Merges one loaded historical commit into the current branch and
  /// refreshes the repository before exposing any resulting conflict _sessionState.
  Future<bool> mergeCommit(String objectId) async {
    if (!_isInsideTrackedGitTask) {
      return _trackBooleanGitTask(() => mergeCommit(objectId));
    }
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    final currentBranch = status?.branch.head;
    final normalizedObjectId = objectId.trim();
    if (repository == null ||
        status == null ||
        currentBranch == null ||
        status.conflictedEntries.isNotEmpty ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        !_sessionState.commits.any(
          (commit) => commit.objectId == normalizedObjectId,
        )) {
      return false;
    }

    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    final operation = _startOperation(RepositoryOperationKind.history);
    try {
      await _writer.mergeCommit(repository, objectId: normalizedObjectId);
      await refresh();
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded ? '已合并选中的提交。' : '合并可能已完成，但本地刷新失败；请刷新确认合并状态。',
      );
      return succeeded;
    } on Object catch (error, stackTrace) {
      await refresh();
      final hasConflicts =
          _sessionState.status?.conflictedEntries.isNotEmpty ?? false;
      final message =
          hasConflicts ||
              (error is GitCommandException &&
                  error.kind == GitErrorKind.conflicts)
          ? '合并遇到冲突。请处理并暂存冲突后，从“动作”菜单继续或中止合并。'
          : _friendlyError(error);
      _sessionState = _sessionState.copyWith(
        phase: RepositorySessionPhase.error,
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
    }
  }
}
