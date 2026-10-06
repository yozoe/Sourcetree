part of 'repository_session.dart';

/// Working-tree stage mutations owned by [RepositorySessionController].
///
/// 中文：集中维护文件暂存/取消暂存写操作；这些方法仍属于同一 Dart library，
/// 因此保留 controller 的私有状态、取消、generation 和写后刷新语义。
extension RepositorySessionWorkingTreeWrites on RepositorySessionController {
  /// Toggles one file between the staged and unstaged groups.
  ///
  /// 中文：在暂存和未暂存分组间移动一个文件。写入期间保留当前列表，完成后仅
  /// 刷新工作区状态，不重新打开仓库或清空历史数据。
  Future<void> toggleStage(RepositoryChangeViewData change) async {
    await _trackGitTask<void>(() => _toggleStage(change));
  }

  /// 中文：执行单文件暂存切换，完成前保持 Engine 所有权。
  /// English: Toggles one staged file while retaining Engine ownership until
  /// the mutation completes.
  Future<void> _toggleStage(RepositoryChangeViewData change) async {
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    if (repository == null ||
        status == null ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        _sessionState.isWorkingTreeBusy) {
      return;
    }

    GitStatusEntry? entry;
    for (final candidate in status.entries) {
      if (candidate.path.display == change.path) {
        entry = candidate;
        break;
      }
    }
    if (entry == null || entry.isConflicted || !entry.path.isValidUtf8) {
      return;
    }

    final repositoryGeneration = _repositoryGeneration;
    final previousSelection = _sessionState.selectedChange;
    final previousRefId = _sessionState.selectedRefId;
    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isWorkingTreeBusy: true,
      clearMessage: true,
    );
    final operation = _startOperation(RepositoryOperationKind.file);
    try {
      if (change.isStaged) {
        await _writer.unstagePath(
          repository,
          entry.path,
          isUnbornBranch: status.branch.isUnborn,
        );
      } else {
        await _writer.stagePath(repository, entry.path);
      }
      final succeeded = await _finishWorkingTreeMutation(
        repository: repository,
        repositoryGeneration: repositoryGeneration,
        previousSelection: previousSelection,
        previousRefId: previousRefId,
        preferredPath: change.path,
        preferredStaged: !change.isStaged,
      );
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded
            ? (change.isStaged ? '已取消暂存所选文件。' : '已暂存所选文件。')
            : '暂存状态可能已改变，但本地刷新失败；请刷新确认文件状态。',
      );
    } on Object catch (error, stackTrace) {
      if (repositoryGeneration == _repositoryGeneration &&
          _sessionState.repository?.id == repository.id) {
        _sessionState = _sessionState.copyWith(
          phase: RepositorySessionPhase.error,
          isWorkingTreeBusy: false,
          message: _friendlyError(error),
          technicalDetails: _technicalDetails(error, stackTrace),
        );
      }
      _completeOperation(
        operation,
        outcome: _operationOutcomeForError(error),
        message: _friendlyError(error),
      );
    }
  }

  /// 中文：批量切换文件组的暂存状态，一次刷新工作区。
  /// English: Stages or unstages a whole change group and refreshes once.
  Future<void> toggleStageGroup(
    List<RepositoryChangeViewData> changes, {
    required bool stage,
  }) async {
    await _trackGitTask<void>(() => _toggleStageGroup(changes, stage: stage));
  }

  /// 中文：执行一组文件的暂存切换，完成前保持 Engine 所有权。
  /// English: Toggles a staged-file group while retaining Engine ownership
  /// until the mutation completes.
  Future<void> _toggleStageGroup(
    List<RepositoryChangeViewData> changes, {
    required bool stage,
  }) async {
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    if (repository == null ||
        status == null ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        _sessionState.isWorkingTreeBusy) {
      return;
    }

    final entries = <GitStatusEntry>[];
    for (final change in changes) {
      if (!change.canToggleStage || change.isStaged == stage) continue;
      for (final entry in status.entries) {
        if (entry.path.display == change.path &&
            !entry.isConflicted &&
            entry.path.isValidUtf8) {
          entries.add(entry);
          break;
        }
      }
    }
    if (entries.isEmpty) return;

    final repositoryGeneration = _repositoryGeneration;
    final previousSelection = _sessionState.selectedChange;
    final previousRefId = _sessionState.selectedRefId;
    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isWorkingTreeBusy: true,
      clearMessage: true,
    );
    final operation = _startOperation(RepositoryOperationKind.file);
    try {
      final paths = [for (final entry in entries) entry.path];
      if (stage) {
        await _writer.stagePaths(repository, paths);
      } else {
        await _writer.unstagePaths(
          repository,
          paths,
          isUnbornBranch: status.branch.isUnborn,
        );
      }
      final succeeded = await _finishWorkingTreeMutation(
        repository: repository,
        repositoryGeneration: repositoryGeneration,
        previousSelection: previousSelection,
        previousRefId: previousRefId,
      );
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded
            ? (stage ? '已暂存所选文件。' : '已取消暂存所选文件。')
            : '批量暂存状态可能已改变，但本地刷新失败；请刷新确认文件状态。',
      );
    } on Object catch (error, stackTrace) {
      if (repositoryGeneration == _repositoryGeneration &&
          _sessionState.repository?.id == repository.id) {
        _sessionState = _sessionState.copyWith(
          phase: RepositorySessionPhase.error,
          isWorkingTreeBusy: false,
          message: _friendlyError(error),
          technicalDetails: _technicalDetails(error, stackTrace),
        );
      }
      _completeOperation(
        operation,
        outcome: _operationOutcomeForError(error),
        message: _friendlyError(error),
      );
    }
  }
}
