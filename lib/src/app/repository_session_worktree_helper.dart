part of 'repository_session.dart';

/// Shared post-mutation refresh helpers for [RepositorySessionController].
///
/// 中文：集中维护工作区写入后的刷新与选择恢复辅助逻辑。
extension RepositorySessionWorktreeHelpers on RepositorySessionController {
  /// Finishes a working-tree mutation with an atomic Git status refresh.
  ///
  /// The existing repository, history and file-list snapshot stay visible
  /// until the new status is ready. The replacement is applied atomically and
  /// the closest valid working-tree selection is then restored. A status that
  /// was already read for mutation validation can be supplied to avoid a
  /// second read.
  ///
  /// 中文：工作区写入后只刷新 Git 状态，在新状态读取完成前保留现有快照，并恢复
  /// 最接近的有效文件选择。
  Future<bool> _finishWorkingTreeMutation({
    required GitRepository repository,
    required int repositoryGeneration,
    required SelectedRepositoryChange? previousSelection,
    required String previousRefId,
    GitStatusSnapshot? validatedStatus,
    String? preferredPath,
    bool? preferredStaged,
  }) async {
    if (validatedStatus == null && !await _runRefreshHookForTesting()) {
      return false;
    }
    final GitStatusSnapshot refreshedStatus;
    try {
      refreshedStatus = validatedStatus ?? await _reader.readStatus(repository);
    } on Object catch (error, stackTrace) {
      _sessionState = _sessionState.copyWith(
        phase: RepositorySessionPhase.error,
        isWorkingTreeBusy: false,
        isDiffLoading: false,
        message: '写入已完成，但刷新仓库状态失败；请手动刷新确认。',
        technicalDetails: _technicalDetails(error, stackTrace),
      );
      return false;
    }
    if (!_providerRef.mounted ||
        repositoryGeneration != _repositoryGeneration ||
        _sessionState.repository?.id != repository.id) {
      return false;
    }

    final latestSelection = _sessionState.selectedChange;
    final latestRefId = _sessionState.selectedRefId;
    final selectionChangedDuringMutation =
        !identical(latestSelection, previousSelection) ||
        latestRefId != previousRefId;
    final shouldSelectPreferred =
        preferredPath != null &&
        preferredStaged != null &&
        !selectionChangedDuringMutation;
    final shouldSelectLatestCommit =
        latestRefId == 'uncommitted' && refreshedStatus.isClean;
    _diffGeneration++;
    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.ready,
      status: refreshedStatus,
      selectedRefId: shouldSelectLatestCommit ? 'history' : null,
      isWorkingTreeBusy: false,
      isDiffLoading: false,
      clearSelectedChange: true,
      clearDiff: true,
      clearMessage: true,
    );
    if (shouldSelectLatestCommit) {
      final latestCommit = _sessionState.historyCommits.firstOrNull;
      if (latestCommit != null) await selectCommit(latestCommit.objectId);
      return true;
    }
    await _restoreWorkingTreeSurfaceIfAvailable(
      previousSelection: shouldSelectPreferred ? null : latestSelection,
      previousRefId: latestRefId,
    );

    if (shouldSelectPreferred) {
      final entry = refreshedStatus.entries
          .where((candidate) => candidate.path.display == preferredPath)
          .firstOrNull;
      if (entry != null) {
        final preferred = _changeAfterStageToggle(
          entry,
          isStaged: preferredStaged,
        );
        final fallback = _changeAfterStageToggle(
          entry,
          isStaged: !preferredStaged,
        );
        final nextSelection = preferred ?? fallback;
        if (nextSelection != null) await selectChange(nextSelection);
      }
    }
    return true;
  }
}
