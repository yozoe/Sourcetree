part of 'repository_session.dart';

/// Local branch creation mutations owned by [RepositorySessionController].
///
/// 中文：集中维护本地分支创建、检出、远端分支切换、重命名、删除和合并写操作，
/// 保持统一的取消、刷新和不确定结果语义。
extension RepositorySessionRefWrites on RepositorySessionController {
  /// Creates a local branch at HEAD without switching the current work tree.
  /// 中文：在当前 HEAD 创建本地分支，不切换当前工作区。
  Future<bool> createLocalBranch(String name) async {
    if (!_isInsideTrackedGitTask) {
      return _trackBooleanGitTask(() => createLocalBranch(name));
    }
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    if (repository == null ||
        status == null ||
        status.branch.isUnborn ||
        _sessionState.phase == RepositorySessionPhase.loading) {
      return false;
    }

    if (name.trim().isEmpty) {
      throw ArgumentError.value(name, 'name', 'Branch name is empty.');
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
      await _writer.createLocalBranch(repository, name: name);
      await refresh();
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded ? '已创建本地分支 $name。' : '分支可能已创建，但本地刷新失败；请刷新确认引用状态。',
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

  /// Creates a local branch from a loaded historical commit without checking
  /// it out. 中文：以已加载历史提交为起点创建本地分支，不自动检出。
  Future<bool> createLocalBranchFromCommit(String name, String objectId) async {
    if (!_isInsideTrackedGitTask) {
      return _trackBooleanGitTask(
        () => createLocalBranchFromCommit(name, objectId),
      );
    }
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    if (repository == null ||
        status == null ||
        status.branch.isUnborn ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        !_sessionState.commits.any((commit) => commit.objectId == objectId)) {
      return false;
    }
    if (name.trim().isEmpty || objectId.trim().isEmpty) {
      throw ArgumentError('A branch name and commit are required.');
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
      await _writer.createLocalBranchFromCommit(
        repository,
        name: name,
        objectId: objectId,
      );
      await refresh();
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded ? '已从提交创建本地分支 $name。' : '分支可能已创建，但本地刷新失败；请刷新确认引用状态。',
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
