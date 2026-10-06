part of 'repository_session.dart';

/// Working-tree file, hunk and reset mutations owned by
/// [RepositorySessionController].
///
/// 中文：集中维护忽略、复制、移动、移除、停止追踪、重置和 Diff hunk 写操作，
/// 保持写后刷新、选择恢复和不确定结果语义。
extension RepositorySessionWorktreeWrites on RepositorySessionController {
  /// Adds ignore rules for the selected working-tree rows after re-reading
  /// their current Git status. Tracked files remain tracked; this only edits
  /// the chosen ignore file and refreshes the workspace.
  ///
  /// 中文：重新读取所选工作区条目的 Git 状态后追加忽略规则。已跟踪文件仍保持
  /// 跟踪；该操作只编辑所选忽略文件并刷新工作区。
  Future<GitIgnoreWriteResult?> ignoreChanges(
    List<RepositoryChangeViewData> changes, {
    required GitIgnorePatternKind patternKind,
    required GitIgnoreDestination destination,
  }) async {
    if (!_isInsideTrackedGitTask) {
      return _trackGitTask<GitIgnoreWriteResult?>(
        () => ignoreChanges(
          changes,
          patternKind: patternKind,
          destination: destination,
        ),
      );
    }
    if (changes.isEmpty ||
        _sessionState.phase != RepositorySessionPhase.ready ||
        _sessionState.isWorkingTreeBusy) {
      return null;
    }

    final previousSelection = _sessionState.selectedChange;
    final previousRefId = _sessionState.selectedRefId;
    await refresh();
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    if (repository == null ||
        status == null ||
        _sessionState.phase != RepositorySessionPhase.ready) {
      return null;
    }

    final paths = <GitPath>[];
    for (final change in changes) {
      final entry = status.displayEntries
          .where((candidate) => candidate.path.display == change.path)
          .firstOrNull;
      final stillInSelectedSource = change.isStaged
          ? entry?.hasStagedChange == true
          : entry?.hasWorkTreeChange == true;
      if (entry == null ||
          !entry.path.isValidUtf8 ||
          entry.isConflicted ||
          !stillInSelectedSource ||
          entry.path.display.contains('\n') ||
          entry.path.display.contains('\r')) {
        return null;
      }
      if (!paths.contains(entry.path)) paths.add(entry.path);
    }
    if (paths.isEmpty) return null;

    final repositoryGeneration = _repositoryGeneration;
    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isWorkingTreeBusy: true,
      isDiffLoading: false,
      clearDiff: true,
      clearMessage: true,
    );
    final operation = _startOperation(RepositoryOperationKind.file);
    try {
      final result = await _writer.addIgnoreRules(
        repository,
        paths,
        patternKind: patternKind,
        destination: destination,
      );
      final refreshed = await _finishWorkingTreeMutation(
        repository: repository,
        repositoryGeneration: repositoryGeneration,
        previousSelection: previousSelection,
        previousRefId: previousRefId,
      );
      _completeOperation(
        operation,
        outcome: refreshed
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: refreshed ? '已更新忽略规则。' : '忽略规则可能已写入，但刷新失败；请刷新确认。',
      );
      return result;
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
      return null;
    }
  }

  /// Copies the selected working-tree files into [destinationDirectory]
  /// without overwriting existing entries. The selected rows are re-read from
  /// Git before copying, and the repository is refreshed after any result.
  ///
  /// 中文：把所选工作区文件复制到 [destinationDirectory] 且不覆盖已有条目。
  /// 复制前重新读取并复核 Git 条目，结束后刷新仓库真实状态。
  Future<GitWorkingTreeCopyResult?> copyChanges(
    List<RepositoryChangeViewData> changes, {
    required String destinationDirectory,
  }) async {
    if (!_isInsideTrackedGitTask) {
      return _trackGitTask<GitWorkingTreeCopyResult?>(
        () => copyChanges(changes, destinationDirectory: destinationDirectory),
      );
    }
    if (changes.isEmpty ||
        _sessionState.phase != RepositorySessionPhase.ready ||
        _sessionState.isWorkingTreeBusy) {
      return null;
    }

    final previousSelection = _sessionState.selectedChange;
    final previousRefId = _sessionState.selectedRefId;
    await refresh();
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    if (repository == null ||
        status == null ||
        _sessionState.phase != RepositorySessionPhase.ready) {
      return null;
    }

    final paths = <GitPath>[];
    for (final change in changes) {
      final entry = status.displayEntries
          .where((candidate) => candidate.path.display == change.path)
          .firstOrNull;
      final stillInSelectedSource = change.isStaged
          ? entry?.hasStagedChange == true
          : entry?.hasWorkTreeChange == true;
      if (entry == null ||
          !entry.path.isValidUtf8 ||
          entry.isConflicted ||
          !stillInSelectedSource ||
          entry.path.display.contains('\n') ||
          entry.path.display.contains('\r')) {
        return null;
      }
      if (!paths.contains(entry.path)) paths.add(entry.path);
    }
    if (paths.isEmpty) return null;

    final repositoryGeneration = _repositoryGeneration;
    final cancellation = GitCancellationToken();
    _copyCancellation?.cancel();
    _copyCancellation = cancellation;
    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isWorkingTreeBusy: true,
      isDiffLoading: false,
      clearDiff: true,
      clearMessage: true,
    );
    final operation = _startOperation(RepositoryOperationKind.file);
    try {
      final result = await _writer.copyWorkingTreeFiles(
        repository,
        paths,
        destinationDirectory: destinationDirectory,
        cancellationToken: cancellation,
      );
      if (cancellation.isCancelled ||
          !_isCurrentRepositoryRequest(repository, repositoryGeneration)) {
        _completeOperation(
          operation,
          outcome: RepositoryOperationOutcome.cancelled,
          message: '复制已取消。',
        );
        return null;
      }
      final refreshed = await _finishWorkingTreeMutation(
        repository: repository,
        repositoryGeneration: repositoryGeneration,
        previousSelection: previousSelection,
        previousRefId: previousRefId,
      );
      _completeOperation(
        operation,
        outcome: !refreshed
            ? RepositoryOperationOutcome.uncertain
            : result.hasFailures
            ? RepositoryOperationOutcome.partiallySucceeded
            : RepositoryOperationOutcome.succeeded,
        message: !refreshed
            ? '复制可能已完成，但刷新失败；请刷新确认文件状态。'
            : result.hasFailures
            ? '复制部分完成，请检查冲突和失败路径。'
            : '已复制所选文件。',
      );
      return result;
    } on GitCancelledException {
      if (_isCurrentRepositoryRequest(repository, repositoryGeneration)) {
        await _finishWorkingTreeMutation(
          repository: repository,
          repositoryGeneration: repositoryGeneration,
          previousSelection: previousSelection,
          previousRefId: previousRefId,
        );
      }
      _completeOperation(
        operation,
        outcome: RepositoryOperationOutcome.cancelled,
        message: '复制已取消。',
      );
      return null;
    } on Object catch (error, stackTrace) {
      if (_isCurrentRepositoryRequest(repository, repositoryGeneration)) {
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
      return null;
    } finally {
      if (identical(_copyCancellation, cancellation)) {
        _copyCancellation = null;
      }
    }
  }

  /// Moves the selected working-tree files into [destinationDirectory]
  /// without overwriting existing entries. Git status and the selected source
  /// rows are revalidated before moving, then the workspace is refreshed.
  ///
  /// 中文：把所选工作区文件移动到 [destinationDirectory] 且不覆盖已有条目。
  /// 移动前重新读取 Git 状态并复核选择来源，结束后刷新真实工作区状态。
  Future<GitWorkingTreeMoveResult?> moveChanges(
    List<RepositoryChangeViewData> changes, {
    required String destinationDirectory,
  }) async {
    if (!_isInsideTrackedGitTask) {
      return _trackGitTask<GitWorkingTreeMoveResult?>(
        () => moveChanges(changes, destinationDirectory: destinationDirectory),
      );
    }
    if (changes.isEmpty ||
        _sessionState.phase != RepositorySessionPhase.ready ||
        _sessionState.isWorkingTreeBusy) {
      return null;
    }

    final previousSelection = _sessionState.selectedChange;
    final previousRefId = _sessionState.selectedRefId;
    await refresh();
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    if (repository == null ||
        status == null ||
        _sessionState.phase != RepositorySessionPhase.ready) {
      return null;
    }

    final paths = <GitPath>[];
    for (final change in changes) {
      final entry = status.displayEntries
          .where((candidate) => candidate.path.display == change.path)
          .firstOrNull;
      final currentType = change.isStaged
          ? entry?.indexStatus
          : entry?.workTreeStatus;
      final stillInSelectedSource = change.isStaged
          ? entry?.hasStagedChange == true
          : entry?.hasWorkTreeChange == true;
      if (entry == null ||
          !entry.path.isValidUtf8 ||
          entry.isConflicted ||
          !stillInSelectedSource ||
          currentType == GitChangeType.deleted ||
          entry.path.display.contains('\n') ||
          entry.path.display.contains('\r')) {
        return null;
      }
      if (!paths.contains(entry.path)) paths.add(entry.path);
    }
    if (paths.isEmpty) return null;

    final repositoryGeneration = _repositoryGeneration;
    final cancellation = GitCancellationToken();
    _moveCancellation?.cancel();
    _moveCancellation = cancellation;
    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isWorkingTreeBusy: true,
      isDiffLoading: false,
      clearDiff: true,
      clearMessage: true,
    );
    final operation = _startOperation(RepositoryOperationKind.file);
    try {
      final result = await _writer.moveWorkingTreeFiles(
        repository,
        paths,
        destinationDirectory: destinationDirectory,
        cancellationToken: cancellation,
      );
      if (cancellation.isCancelled ||
          !_isCurrentRepositoryRequest(repository, repositoryGeneration)) {
        _completeOperation(
          operation,
          outcome: RepositoryOperationOutcome.cancelled,
          message: '移动已取消。',
        );
        return null;
      }
      final refreshed = await _finishWorkingTreeMutation(
        repository: repository,
        repositoryGeneration: repositoryGeneration,
        previousSelection: previousSelection,
        previousRefId: previousRefId,
      );
      _completeOperation(
        operation,
        outcome: !refreshed
            ? RepositoryOperationOutcome.uncertain
            : result.hasFailures
            ? RepositoryOperationOutcome.partiallySucceeded
            : RepositoryOperationOutcome.succeeded,
        message: !refreshed
            ? '移动可能已完成，但刷新失败；请刷新确认文件状态。'
            : result.hasFailures
            ? '移动部分完成，请检查保留源文件和失败路径。'
            : '已移动所选文件。',
      );
      return result;
    } on GitCancelledException {
      if (_isCurrentRepositoryRequest(repository, repositoryGeneration)) {
        await _finishWorkingTreeMutation(
          repository: repository,
          repositoryGeneration: repositoryGeneration,
          previousSelection: previousSelection,
          previousRefId: previousRefId,
        );
      }
      _completeOperation(
        operation,
        outcome: RepositoryOperationOutcome.cancelled,
        message: '移动已取消。',
      );
      return null;
    } on Object catch (error, stackTrace) {
      if (_isCurrentRepositoryRequest(repository, repositoryGeneration)) {
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
      return null;
    } finally {
      if (identical(_moveCancellation, cancellation)) {
        _moveCancellation = null;
      }
    }
  }

  /// Deletes selected staged or unstaged paths from the working tree.
  ///
  /// The Git index and commit history are left unchanged. Status is re-read
  /// after the caller's confirmation and each selected row must still exist in
  /// the same staged or unstaged source before any filesystem deletion starts.
  ///
  /// 中文：从工作区删除暂存或未暂存列表中选中的路径，不直接修改 Git 索引或
  /// 提交历史。调用方确认后会重新读取状态；所有选中行仍处于原暂存来源且路径
  /// 可安全表示时才开始文件系统删除，完成后刷新真实 Git 状态。
  Future<RepositoryChangeRemovalResult?> removeChanges(
    List<RepositoryChangeViewData> changes,
  ) async {
    if (!_isInsideTrackedGitTask) {
      return _trackGitTask<RepositoryChangeRemovalResult?>(
        () => removeChanges(changes),
      );
    }
    if (changes.isEmpty ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        _sessionState.isWorkingTreeBusy) {
      return null;
    }

    final previousSelection = _sessionState.selectedChange;
    final previousRefId = _sessionState.selectedRefId;
    await refresh();
    Future<RepositoryChangeRemovalResult?> rejectStaleSelection() async {
      await _restoreWorkingTreeSurfaceIfAvailable(
        previousSelection: previousSelection,
        previousRefId: previousRefId,
      );
      return null;
    }

    final repository = _sessionState.repository;
    final status = _sessionState.status;
    final workTreeRoot = repository?.workTreeRoot;
    if (repository == null ||
        status == null ||
        workTreeRoot == null ||
        _sessionState.phase != RepositorySessionPhase.ready) {
      return rejectStaleSelection();
    }

    final paths = <GitPath>[];
    for (final change in changes) {
      final entry = status.displayEntries
          .where((candidate) => candidate.path.display == change.path)
          .firstOrNull;
      final stillInSelectedSource = change.isStaged
          ? entry?.hasStagedChange == true
          : entry?.hasWorkTreeChange == true;
      if (entry == null || !entry.path.isValidUtf8 || !stillInSelectedSource) {
        return rejectStaleSelection();
      }
      if (!paths.contains(entry.path)) paths.add(entry.path);
    }
    if (paths.isEmpty) return rejectStaleSelection();

    for (final path in paths) {
      final localPath = path_utils.normalize(
        path_utils.join(workTreeRoot, path.display),
      );
      if (!path_utils.isWithin(workTreeRoot, localPath)) {
        return rejectStaleSelection();
      }
    }

    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearDiff: true,
      clearMessage: true,
    );
    final operation = _startOperation(RepositoryOperationKind.file);
    final removedPaths = <String>[];
    final missingPaths = <String>[];
    final failedPaths = <String>[];
    for (var index = 0; index < paths.length; index++) {
      final displayPath = paths[index].display;
      try {
        final removed = await _writer.removeWorkingTreePath(
          repository,
          paths[index],
        );
        if (!removed) {
          missingPaths.add(displayPath);
          continue;
        }
        removedPaths.add(displayPath);
      } on Object {
        failedPaths.add(displayPath);
      }
    }
    await refresh();
    await _restoreWorkingTreeSurfaceIfAvailable(
      previousSelection: previousSelection,
      previousRefId: previousRefId,
    );
    final refreshFailed = _sessionState.phase != RepositorySessionPhase.ready;
    _completeOperation(
      operation,
      outcome: refreshFailed
          ? RepositoryOperationOutcome.uncertain
          : failedPaths.isNotEmpty && removedPaths.isNotEmpty
          ? RepositoryOperationOutcome.partiallySucceeded
          : failedPaths.isNotEmpty
          ? RepositoryOperationOutcome.failed
          : RepositoryOperationOutcome.succeeded,
      message: refreshFailed
          ? '文件删除可能已完成，但刷新失败；请刷新确认文件状态。'
          : failedPaths.isNotEmpty && removedPaths.isNotEmpty
          ? '文件删除部分完成，请检查失败路径。'
          : failedPaths.isNotEmpty
          ? '文件删除失败，请检查文件状态。'
          : '已删除所选工作区文件。',
    );
    return RepositoryChangeRemovalResult(
      removedPaths: removedPaths,
      missingPaths: missingPaths,
      failedPaths: failedPaths,
    );
  }

  /// Stops tracking the selected working-tree files without deleting them.
  ///
  /// 中文：在调用方取得明确确认后，重新读取 Git 状态并仅从索引移除仍可安全
  /// 停止追踪的文件；本地文件保持不变，调用成功后会留下待提交的删除记录。
  Future<bool> stopTrackingChanges(
    List<RepositoryChangeViewData> changes,
  ) async {
    if (!_isInsideTrackedGitTask) {
      return _trackBooleanGitTask(() => stopTrackingChanges(changes));
    }
    if (changes.isEmpty ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        _sessionState.isWorkingTreeBusy) {
      return false;
    }

    // A confirmation dialog can stay open while another Git client changes
    // the repository. Always validate against a fresh status before writing.
    // 确认窗口显示期间，其他 Git 客户端仍可能改动仓库；写入前必须基于最新
    // 状态重新校验，不能复用打开对话框时的选择快照。
    await refresh();
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    if (repository == null ||
        status == null ||
        _sessionState.phase != RepositorySessionPhase.ready) {
      return false;
    }

    final paths = <GitPath>[];
    for (final change in changes) {
      if (!change.canStopTracking) {
        return false;
      }
      final entry = status.entries
          .where((candidate) => candidate.path.display == change.path)
          .firstOrNull;
      if (entry == null ||
          entry.isConflicted ||
          !entry.path.isValidUtf8 ||
          entry.kind != GitFileStatusKind.ordinary ||
          entry.workTreeStatus == GitChangeType.deleted ||
          entry.indexStatus == GitChangeType.deleted) {
        return false;
      }
      if (!paths.contains(entry.path)) paths.add(entry.path);
    }
    if (paths.isEmpty) return false;

    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    final operation = _startOperation(RepositoryOperationKind.file);
    try {
      await _writer.stopTrackingPaths(repository, paths);
      await refresh();
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded ? '已停止追踪所选文件。' : '停止追踪可能已完成，但本地刷新失败；请刷新确认文件状态。',
      );
      return succeeded;
    } on Object catch (error, stackTrace) {
      await refresh();
      _sessionState = _sessionState.copyWith(
        phase: RepositorySessionPhase.error,
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

  /// Stops tracking the file selected in a historical commit, if it remains a
  /// safe tracked file in the current working tree.
  ///
  /// 中文：对历史提交文件列表中的当前选择停止追踪。提交历史只提供路径；执行前
  /// 必须重新读取当前工作区并验证该路径仍在索引中且本地文件存在，不能依据历史
  /// 快照直接写入 Git。
  Future<bool> stopTrackingSelectedCommitFile() async {
    if (!_isInsideTrackedGitTask) {
      return _trackBooleanGitTask(stopTrackingSelectedCommitFile);
    }
    final selected = _sessionState.selectedCommitFile;
    if (selected == null ||
        !selected.file.path.isValidUtf8 ||
        _sessionState.isWorkingTreeBusy) {
      return false;
    }

    await refresh();
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    if (repository == null ||
        status == null ||
        _sessionState.phase != RepositorySessionPhase.ready) {
      return false;
    }

    final path = selected.file.path;
    final currentEntry = status.entries
        .where((entry) => entry.path == path)
        .firstOrNull;
    if (currentEntry != null &&
        (currentEntry.isConflicted ||
            currentEntry.kind == GitFileStatusKind.renamed ||
            currentEntry.kind == GitFileStatusKind.copied ||
            currentEntry.workTreeStatus == GitChangeType.deleted ||
            currentEntry.indexStatus == GitChangeType.deleted)) {
      return false;
    }
    if (!await _reader.isPathTracked(repository, path)) return false;

    final workTreeRoot = repository.workTreeRoot;
    if (workTreeRoot == null) return false;
    final localPath = path_utils.normalize(
      path_utils.join(workTreeRoot, path.display),
    );
    if (!path_utils.isWithin(workTreeRoot, localPath) ||
        await FileSystemEntity.type(localPath, followLinks: false) ==
            FileSystemEntityType.notFound) {
      return false;
    }

    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    final operation = _startOperation(RepositoryOperationKind.file);
    try {
      await _writer.stopTrackingPaths(repository, [path]);
      await refresh();
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded ? '已停止追踪所选历史文件。' : '停止追踪可能已完成，但本地刷新失败；请刷新确认文件状态。',
      );
      return succeeded;
    } on Object catch (error, stackTrace) {
      await refresh();
      _sessionState = _sessionState.copyWith(
        phase: RepositorySessionPhase.error,
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

  /// Restores selected tracked paths to their HEAD versions.
  ///
  /// The selected staged or working-tree surface must still contain the same
  /// supported change category when status is re-read after confirmation.
  ///
  /// 中文：在用户确认后重新读取 Git 状态，只将所选暂存区或工作区来源仍包含受
  /// 支持改动类型的普通已跟踪路径恢复到 HEAD；索引和工作区都会恢复，不能用于
  /// 未提交的新增、重命名、复制或冲突路径。
  Future<bool> resetChangesToHead(
    List<RepositoryChangeViewData> changes,
  ) async {
    if (!_isInsideTrackedGitTask) {
      return _trackBooleanGitTask(() => resetChangesToHead(changes));
    }
    final repository = _sessionState.repository;
    if (changes.isEmpty ||
        repository == null ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        _sessionState.isWorkingTreeBusy) {
      return false;
    }

    final repositoryGeneration = _repositoryGeneration;
    final previousSelection = _sessionState.selectedChange;
    final previousRefId = _sessionState.selectedRefId;
    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isWorkingTreeBusy: true,
      clearMessage: true,
    );

    Future<bool> rejectStaleSelection(GitStatusSnapshot status) async {
      await _finishWorkingTreeMutation(
        repository: repository,
        repositoryGeneration: repositoryGeneration,
        previousSelection: previousSelection,
        previousRefId: previousRefId,
        validatedStatus: status,
      );
      return false;
    }

    RepositoryOperationRecord? operation;
    try {
      final status = await _reader.readStatus(repository);
      if (!_providerRef.mounted ||
          repositoryGeneration != _repositoryGeneration ||
          _sessionState.repository?.id != repository.id) {
        return false;
      }
      if (status.branch.objectId == null) {
        return await rejectStaleSelection(status);
      }

      final paths = <GitPath>[];
      for (final change in changes) {
        if (!change.canResetToHead) {
          return await rejectStaleSelection(status);
        }
        final entry = status.entries
            .where((candidate) => candidate.path.display == change.path)
            .firstOrNull;
        final currentType = change.isStaged
            ? entry?.indexStatus
            : entry?.workTreeStatus;
        final matchesSelectedKind = switch (change.kind) {
          RepositoryChangeKind.modified =>
            currentType == GitChangeType.modified ||
                currentType == GitChangeType.typeChanged,
          RepositoryChangeKind.deleted => currentType == GitChangeType.deleted,
          _ => false,
        };
        if (entry == null ||
            entry.isConflicted ||
            !entry.path.isValidUtf8 ||
            entry.kind != GitFileStatusKind.ordinary ||
            (change.isStaged
                ? !entry.hasStagedChange
                : !entry.hasWorkTreeChange) ||
            !matchesSelectedKind) {
          return await rejectStaleSelection(status);
        }
        if (!paths.contains(entry.path)) paths.add(entry.path);
      }
      if (paths.isEmpty) return await rejectStaleSelection(status);

      operation = _startOperation(RepositoryOperationKind.file);
      await _writer.resetPathsToHead(repository, paths);
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
        message: succeeded ? '已将所选文件重置到 HEAD。' : '重置可能已完成，但本地刷新失败；请刷新确认文件状态。',
      );
      return succeeded;
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
      if (operation != null) {
        _completeOperation(
          operation,
          outcome: _operationOutcomeForError(error),
          message: _friendlyError(error),
        );
      }
      return false;
    }
  }

  /// Restores the currently selected historical path from its commit into the
  /// index and work tree after revalidating the selection and Git operation
  /// _sessionState.
  ///
  /// [objectId] and [path] are the values shown in the confirmation dialog.
  /// The operation is rejected if either selection changes, the commit leaves
  /// the loaded canonical history, the path is unsafe, or another repository
  /// mutation starts before the write. Detached HEAD is allowed because this
  /// operation never moves HEAD.
  ///
  /// 中文：重新验证选择与 Git 操作状态后，将当前历史提交中的路径恢复到索引和
  /// 工作区。[objectId] 与 [path] 是确认框展示的值；若提交或路径选择已变化、
  /// 提交不再属于已加载的规范历史、路径不安全，或写入前出现其他仓库操作，则
  /// 拒绝执行。由于不会移动 HEAD，detached HEAD 仍可使用此功能。
  Future<bool> resetSelectedCommitFileToCommit({
    required String objectId,
    required String path,
  }) async {
    if (!_isInsideTrackedGitTask) {
      return _trackBooleanGitTask(
        () => resetSelectedCommitFileToCommit(objectId: objectId, path: path),
      );
    }
    final repository = _sessionState.repository;
    final selected = _sessionState.selectedCommitFile;
    final supportedKind = switch (selected?.file.kind) {
      GitCommitChangeKind.added ||
      GitCommitChangeKind.modified ||
      GitCommitChangeKind.deleted => true,
      _ => false,
    };
    if (repository == null ||
        selected == null ||
        _sessionState.phase != RepositorySessionPhase.ready ||
        _sessionState.isWorkingTreeBusy ||
        _sessionState.operationState != GitRepositoryOperationState.none ||
        _sessionState.selectedCommitId != objectId ||
        selected.objectId != objectId ||
        selected.file.path.display != path ||
        !selected.file.path.isValidUtf8 ||
        !supportedKind ||
        !_sessionState.historyCommits.any(
          (commit) => commit.objectId == objectId,
        )) {
      return false;
    }

    final repositoryGeneration = _repositoryGeneration;
    final selectedRefId = _sessionState.selectedRefId;
    final selectedPath = selected.file.path;
    RepositoryOperationRecord? operation;
    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isWorkingTreeBusy: true,
      clearMessage: true,
    );
    try {
      final preflight = await Future.wait<Object>([
        _reader.readStatus(repository),
        _reader.readOperationState(repository),
      ]);
      final currentSelection = _sessionState.selectedCommitFile;
      if (!_providerRef.mounted ||
          repositoryGeneration != _repositoryGeneration ||
          _sessionState.repository?.id != repository.id ||
          _sessionState.selectedCommitId != objectId ||
          currentSelection?.objectId != objectId ||
          currentSelection?.file.path != selectedPath ||
          !_sessionState.historyCommits.any(
            (commit) => commit.objectId == objectId,
          ) ||
          preflight[1] != GitRepositoryOperationState.none) {
        if (repositoryGeneration == _repositoryGeneration &&
            _sessionState.repository?.id == repository.id) {
          _sessionState = _sessionState.copyWith(
            phase: RepositorySessionPhase.ready,
            status: preflight[0] as GitStatusSnapshot,
            operationState: preflight[1] as GitRepositoryOperationState,
            isWorkingTreeBusy: false,
          );
        }
        return false;
      }

      operation = _startOperation(RepositoryOperationKind.file);
      await _writer.restorePathFromCommit(
        repository,
        objectId: objectId,
        path: selectedPath,
      );
      final refreshed = await _finishWorkingTreeMutation(
        repository: repository,
        repositoryGeneration: repositoryGeneration,
        previousSelection: null,
        previousRefId: selectedRefId,
      );
      if (!refreshed ||
          _sessionState.selectedCommitId != objectId ||
          _sessionState.selectedCommitFile?.file.path != selectedPath) {
        _completeOperation(
          operation,
          outcome: RepositoryOperationOutcome.uncertain,
          message: '历史文件恢复可能已完成，但本地刷新失败；请刷新确认文件状态。',
        );
        return refreshed;
      }
      _sessionState = _sessionState.copyWith(selectedRefId: selectedRefId);
      await selectCommit(objectId);
      if (_sessionState.commitChanges.any(
        (file) => file.path == selectedPath,
      )) {
        await selectCommitFileByPath(path);
      }
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded ? '已恢复历史文件。' : '历史文件恢复可能已完成，但本地刷新失败；请刷新确认文件状态。',
      );
      return succeeded;
    } on Object catch (error, stackTrace) {
      if (repositoryGeneration == _repositoryGeneration &&
          _sessionState.repository?.id == repository.id) {
        GitStatusSnapshot? refreshedStatus;
        GitRepositoryOperationState? refreshedOperationState;
        try {
          final refreshed = await Future.wait<Object>([
            _reader.readStatus(repository),
            _reader.readOperationState(repository),
          ]);
          refreshedStatus = refreshed[0] as GitStatusSnapshot;
          refreshedOperationState = refreshed[1] as GitRepositoryOperationState;
        } on Object {
          // Preserve the original write error when the recovery read also
          // fails. A later manual refresh remains available from error _sessionState.
        }
        if (repositoryGeneration != _repositoryGeneration ||
            _sessionState.repository?.id != repository.id) {
          return false;
        }
        _sessionState = _sessionState.copyWith(
          phase: RepositorySessionPhase.error,
          status: refreshedStatus,
          operationState: refreshedOperationState,
          isWorkingTreeBusy: false,
          message: _friendlyError(error),
          technicalDetails: _technicalDetails(error, stackTrace),
        );
      }
      if (operation != null) {
        _completeOperation(
          operation,
          outcome: _operationOutcomeForError(error),
          message: _friendlyError(error),
        );
      }
      return false;
    }
  }

  /// Stages one selected working-tree text hunk and refreshes Git-backed _sessionState.
  ///
  /// 中文：暂存当前选中的一个未暂存文本区块并刷新 Git 状态。仅支持普通已跟踪
  /// 文件；补丁必须仍与索引匹配，刷新后恢复原工作区入口及最接近的文件选择。
  Future<bool> stageSelectedDiffHunk(int hunkIndex) async {
    if (!_isInsideTrackedGitTask) {
      return _trackBooleanGitTask(() => stageSelectedDiffHunk(hunkIndex));
    }
    final repository = _sessionState.repository;
    final selected = _sessionState.selectedChange;
    final diff = _sessionState.diff;
    final selectedRefId = _sessionState.selectedRefId;
    if (repository == null ||
        selected == null ||
        diff == null ||
        _sessionState.phase != RepositorySessionPhase.ready ||
        _sessionState.isWorkingTreeBusy ||
        _sessionState.operationState != GitRepositoryOperationState.none ||
        _sessionState.isDiffLoading ||
        selected.source != GitDiffSource.workingTree ||
        selected.kind != RepositoryChangeKind.modified ||
        selected.entry.isConflicted ||
        !selected.entry.path.isValidUtf8 ||
        diff.path != selected.entry.path ||
        diff.source != selected.source ||
        diff.isTruncated ||
        diff.changesFileMode ||
        diff.whitespaceMode != GitDiffWhitespaceMode.preserve ||
        hunkIndex < 0) {
      return false;
    }

    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearMessage: true,
    );
    final operation = _startOperation(RepositoryOperationKind.file);
    try {
      await _writer.stageDiffHunk(repository, diff: diff, hunkIndex: hunkIndex);
      await refresh();
      await _restoreWorkingTreeSelectionAfterRefresh(
        previousSelection: selected,
        previousRefId: selectedRefId,
      );
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded ? '已暂存选中的 Diff 区块。' : '区块可能已暂存，但本地刷新失败；请刷新确认文件状态。',
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

  /// Discards or unstages one selected text hunk and refreshes Git-backed _sessionState.
  ///
  /// 中文：放弃或取消暂存当前选中文件 Diff 的一个文本区块并刷新 Git 状态。仅
  /// 支持普通已跟踪文件；未暂存区块恢复到索引版本，已暂存区块只修改索引并保留
  /// 工作区内容。上下文变化时 Git 会拒绝补丁。
  Future<bool> revertSelectedDiffHunk(int hunkIndex) async {
    if (!_isInsideTrackedGitTask) {
      return _trackBooleanGitTask(() => revertSelectedDiffHunk(hunkIndex));
    }
    final repository = _sessionState.repository;
    final selected = _sessionState.selectedChange;
    final diff = _sessionState.diff;
    final selectedRefId = _sessionState.selectedRefId;
    if (repository == null ||
        selected == null ||
        diff == null ||
        _sessionState.phase != RepositorySessionPhase.ready ||
        _sessionState.isWorkingTreeBusy ||
        _sessionState.operationState != GitRepositoryOperationState.none ||
        _sessionState.isDiffLoading ||
        selected.kind != RepositoryChangeKind.modified ||
        selected.entry.isConflicted ||
        !selected.entry.path.isValidUtf8 ||
        diff.path != selected.entry.path ||
        diff.source != selected.source ||
        diff.isTruncated ||
        diff.changesFileMode ||
        diff.whitespaceMode != GitDiffWhitespaceMode.preserve ||
        hunkIndex < 0) {
      return false;
    }

    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearMessage: true,
    );
    final operation = _startOperation(RepositoryOperationKind.file);
    try {
      await _writer.revertDiffHunk(
        repository,
        diff: diff,
        hunkIndex: hunkIndex,
      );
      await refresh();
      await _restoreWorkingTreeSelectionAfterRefresh(
        previousSelection: selected,
        previousRefId: selectedRefId,
      );
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded ? '已处理选中的 Diff 区块。' : '区块可能已处理，但本地刷新失败；请刷新确认文件状态。',
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

  /// Reverse-applies one selected committed hunk into the current working tree.
  ///
  /// The immutable commit remains unchanged. After Git accepts the patch, all
  /// repository _sessionState is refreshed and the same commit and file are selected
  /// again so the historical context remains visible.
  ///
  /// 中文：将当前选中的已提交区块反向应用到工作区，不修改原提交。Git 接受补丁
  /// 后刷新完整仓库状态，并重新选中原提交和文件，使历史上下文保持可见。
  Future<bool> revertSelectedCommitDiffHunk(int hunkIndex) async {
    if (!_isInsideTrackedGitTask) {
      return _trackBooleanGitTask(
        () => revertSelectedCommitDiffHunk(hunkIndex),
      );
    }
    final repository = _sessionState.repository;
    final selected = _sessionState.selectedCommitFile;
    final diff = _sessionState.commitDiff;
    final selectedRefId = _sessionState.selectedRefId;
    final selectedCommitId = _sessionState.selectedCommitId;
    final supportedKind = switch (selected?.file.kind) {
      GitCommitChangeKind.added ||
      GitCommitChangeKind.modified ||
      GitCommitChangeKind.deleted => true,
      _ => false,
    };
    if (repository == null ||
        selected == null ||
        diff == null ||
        selectedCommitId == null ||
        _sessionState.phase != RepositorySessionPhase.ready ||
        _sessionState.operationState != GitRepositoryOperationState.none ||
        _sessionState.isCommitDiffLoading ||
        _sessionState.selectedRefId.startsWith('refs/stash/') ||
        selected.objectId != selectedCommitId ||
        !selected.file.path.isValidUtf8 ||
        !supportedKind ||
        diff.path != selected.file.path ||
        diff.source != GitDiffSource.commit ||
        diff.isTruncated ||
        diff.changesFileMode ||
        diff.whitespaceMode != GitDiffWhitespaceMode.preserve ||
        hunkIndex < 0) {
      return false;
    }

    final selectedPath = selected.file.path.display;
    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      clearMessage: true,
    );
    final operation = _startOperation(RepositoryOperationKind.file);
    try {
      await _writer.revertDiffHunk(
        repository,
        diff: diff,
        hunkIndex: hunkIndex,
      );
      await refresh();
      if (_sessionState.phase != RepositorySessionPhase.ready) {
        _completeOperation(
          operation,
          outcome: RepositoryOperationOutcome.uncertain,
          message: '区块可能已回滚，但本地刷新失败；请刷新确认文件状态。',
        );
        return false;
      }
      _sessionState = _sessionState.copyWith(selectedRefId: selectedRefId);
      await selectCommit(selectedCommitId);
      if (_sessionState.commitChanges.any(
        (candidate) => candidate.path.display == selectedPath,
      )) {
        await selectCommitFileByPath(selectedPath);
      }
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded ? '已回滚选中的提交区块。' : '区块可能已回滚，但本地刷新失败；请刷新确认文件状态。',
      );
      return succeeded;
    } on Object catch (error, stackTrace) {
      _sessionState = _sessionState.copyWith(
        phase: RepositorySessionPhase.error,
        isCommitDiffLoading: false,
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

  /// Restores a previously selected working-tree surface when it still exists.
  ///
  /// 中文：完整刷新后，如果原入口是“文件状态”，或仍有改动时原入口是
  /// `Uncommitted changes`，则恢复该入口及仍有效的文件选择。
  Future<void> _restoreWorkingTreeSurfaceIfAvailable({
    required SelectedRepositoryChange? previousSelection,
    required String previousRefId,
  }) async {
    final shouldRestore =
        previousRefId == 'workspace' ||
        (previousRefId == 'uncommitted' &&
            _sessionState.status?.isClean == false);
    if (!shouldRestore) return;
    await _restoreWorkingTreeSelectionAfterRefresh(
      previousSelection: previousSelection,
      previousRefId: previousRefId,
    );
  }

  /// Restores the working-tree surface and closest surviving file selection.
  ///
  /// 中文：工作区写入后的完整 Git 刷新会默认选中最新提交；此方法恢复操作前的
  /// “文件状态”或未提交行。若原文件选择仍存在，则优先恢复同一路径、同一暂存
  /// 来源，来源已消失时再选择另一侧仍存在的改动。
  Future<void> _restoreWorkingTreeSelectionAfterRefresh({
    required SelectedRepositoryChange? previousSelection,
    required String previousRefId,
  }) async {
    if (_sessionState.phase != RepositorySessionPhase.ready) return;
    if (previousRefId == 'workspace') {
      _commitGeneration++;
      _commitDiffGeneration++;
      _sessionState = _sessionState.copyWith(
        selectedRefId: 'workspace',
        clearSelectedCommit: true,
        commitChanges: const [],
        commitAdditions: 0,
        commitDeletions: 0,
        isCommitLoading: false,
        isCommitDiffLoading: false,
        clearSelectedCommitFile: true,
        clearCommitDiff: true,
        clearMessage: true,
      );
    } else {
      selectUncommittedChanges();
    }

    if (previousSelection == null) {
      await selectChange(null);
      return;
    }
    final entry = _sessionState.status?.entries
        .where((candidate) => candidate.path == previousSelection.entry.path)
        .firstOrNull;
    if (entry == null || entry.isConflicted || !entry.path.isValidUtf8) {
      await selectChange(null);
      return;
    }
    final preferred = _changeAfterStageToggle(
      entry,
      isStaged: previousSelection.isStaged,
    );
    final fallback = _changeAfterStageToggle(
      entry,
      isStaged: !previousSelection.isStaged,
    );
    final nextSelection = preferred ?? fallback;
    if (nextSelection == null) {
      await selectChange(null);
      return;
    }
    await selectChange(nextSelection);
  }

  /// 中文：为内部 Diff 读取选中冲突文件的各个 Git 阶段与工作区内容。
  ///
  /// English: Reads the Git stages and work-tree result for the selected
  /// conflicted file shown by the internal Diff.
  Future<GitConflictFileVersions?> readConflictVersions(
    RepositoryChangeViewData change,
  ) async {
    if (!_isInsideTrackedGitTask) {
      return _trackGitTask<GitConflictFileVersions?>(
        () => readConflictVersions(change),
      );
    }
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    if (repository == null || status == null) return null;

    GitStatusEntry? entry;
    for (final candidate in status.entries) {
      if (candidate.path.display == change.path) {
        entry = candidate;
        break;
      }
    }
    if (entry == null || !entry.isConflicted || !entry.path.isValidUtf8) {
      return null;
    }
    try {
      return await _reader.readConflictFileVersions(repository, entry);
    } on Object catch (error, stackTrace) {
      _sessionState = _sessionState.copyWith(
        phase: RepositorySessionPhase.error,
        message: _friendlyError(error),
        technicalDetails: _technicalDetails(error, stackTrace),
      );
      return null;
    }
  }
}
