part of 'repository_session.dart';

/// Commit mutations owned by [RepositorySessionController].
///
/// 中文：集中维护提交、提交全部和按选择提交；这些方法仍共享 controller 的
/// 私有状态与任务追踪，保持写后刷新和不确定结果语义不变。
extension RepositorySessionCommitWrites on RepositorySessionController {
  /// Commits exactly the files currently staged in the repository index, or
  /// amends the current HEAD when [amend] is true.
  ///
  /// Returns whether Git created the commit and the following refresh finished
  /// successfully. Git hooks are intentionally allowed to run.
  /// 中文：提交当前已暂存内容，或在 [amend] 为 true 时修改当前 HEAD。
  Future<bool> createCommit(String message, {bool amend = false}) async =>
      await _trackGitTask<bool>(() => _createCommit(message, amend: amend)) ??
      false;

  /// Commits all tracked modifications and deletions together with files that
  /// are already staged, while leaving purely untracked files untouched.
  /// 中文：提交全部已跟踪修改和删除以及此前已暂存的文件；纯未跟踪文件保持不变。
  Future<bool> createCommitFromAllTracked(String message) =>
      _trackBooleanGitTask(() => _createCommitFromAllTracked(message));

  /// 中文：在关闭屏障内执行“提交所有”，并在执行前以及成功或失败后重读真实 Git 状态。
  /// English: Performs Commit All inside the shutdown barrier and refreshes
  /// real Git state before execution and after either success or failure.
  Future<bool> _createCommitFromAllTracked(String message) async {
    if (message.trim().isEmpty) {
      throw ArgumentError.value(message, 'message', 'Commit message is empty.');
    }
    if (_sessionState.phase == RepositorySessionPhase.loading ||
        _sessionState.isWorkingTreeBusy ||
        _sessionState.operationState != GitRepositoryOperationState.none) {
      return false;
    }

    await refresh();
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    final hasEligibleChange =
        status?.entries.any(
          (entry) =>
              entry.hasStagedChange ||
              entry.kind != GitFileStatusKind.untracked &&
                  entry.hasWorkTreeChange,
        ) ??
        false;
    if (repository == null ||
        status == null ||
        !hasEligibleChange ||
        status.conflictedEntries.isNotEmpty ||
        _sessionState.phase != RepositorySessionPhase.ready) {
      return false;
    }

    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    final operation = _startOperation(RepositoryOperationKind.commit);
    try {
      await _writer.createCommitFromAllTracked(repository, message: message);
      await refresh();
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded ? '已提交全部已跟踪改动。' : '提交可能已完成，但本地刷新失败；请刷新确认提交状态。',
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

  /// Commits only the current work-tree versions of the selected visible file
  /// paths, excluding every unrelated staged path from the new commit.
  /// 中文：仅提交所选可见文件路径，并排除未选中的已暂存路径。
  Future<bool> createCommitFromSelection(
    String message,
    List<RepositoryChangeViewData> changes,
  ) => _trackBooleanGitTask(() => _createCommitFromSelection(message, changes));

  /// Revalidates selected rows against a fresh status snapshot before a
  /// path-only commit. Renames include both old and new paths.
  /// 中文：路径限定提交前基于最新状态复核所选行；重命名同时包含旧路径和新路径。
  Future<bool> _createCommitFromSelection(
    String message,
    List<RepositoryChangeViewData> changes,
  ) async {
    if (changes.isEmpty ||
        message.trim().isEmpty ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        _sessionState.isWorkingTreeBusy ||
        _sessionState.operationState != GitRepositoryOperationState.none) {
      return false;
    }
    if (changes.any(
      (change) => !change.isActionEnabled || !change.isPathValidUtf8,
    )) {
      return false;
    }

    await refresh();
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    if (repository == null ||
        status == null ||
        _sessionState.phase != RepositorySessionPhase.ready ||
        status.conflictedEntries.isNotEmpty) {
      return false;
    }

    final paths = <GitPath>[];
    final untrackedPaths = <GitPath>[];
    for (final change in changes) {
      final entry = status.displayEntries
          .where((candidate) => candidate.path.display == change.path)
          .firstOrNull;
      final stillInSelectedSource = change.isStaged
          ? entry?.hasStagedChange == true
          : entry?.hasWorkTreeChange == true;
      if (entry == null ||
          entry.isConflicted ||
          !entry.path.isValidUtf8 ||
          !stillInSelectedSource) {
        return false;
      }
      if (!paths.contains(entry.path)) paths.add(entry.path);
      final originalPath = entry.originalPath;
      if (originalPath != null && !paths.contains(originalPath)) {
        paths.add(originalPath);
      }
      if (entry.kind == GitFileStatusKind.untracked &&
          !untrackedPaths.contains(entry.path)) {
        untrackedPaths.add(entry.path);
      }
    }
    if (paths.isEmpty) return false;

    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    final operation = _startOperation(RepositoryOperationKind.commit);
    try {
      await _writer.createCommitFromPaths(
        repository,
        message: message,
        paths: paths,
        untrackedPaths: untrackedPaths,
      );
      await refresh();
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded ? '已提交选中的改动。' : '提交可能已完成，但本地刷新失败；请刷新确认提交状态。',
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

  /// 中文：执行提交写入并在完成后刷新状态。
  /// English: Performs the commit write and refreshes state after completion.
  Future<bool> _createCommit(String message, {required bool amend}) async {
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    if (repository == null ||
        status == null ||
        (!amend && status.stagedEntries.isEmpty) ||
        (amend && status.branch.objectId == null) ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        _sessionState.operationState != GitRepositoryOperationState.none) {
      return false;
    }

    if (message.trim().isEmpty) {
      throw ArgumentError.value(message, 'message', 'Commit message is empty.');
    }

    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    final operation = _startOperation(RepositoryOperationKind.commit);
    try {
      await _writer.createCommit(repository, message: message, amend: amend);
      await refresh();
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded
            ? (amend ? '已修改当前提交。' : '已创建提交。')
            : '提交可能已完成，但本地刷新失败；请刷新确认提交状态。',
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
}
