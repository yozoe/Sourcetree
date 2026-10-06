part of 'repository_session.dart';

/// Conflict-resolution mutations owned by [RepositorySessionController].
///
/// 中文：集中维护冲突侧选择、自定义合并结果和 Git 状态刷新；冲突版本读取仍
/// 留在主 controller，保持读写边界清晰。
extension RepositorySessionConflictWrites on RepositorySessionController {
  /// Executes one explicit conflict-resolution action for an unmerged file.
  /// 中文：对一个未合并文件执行明确选择的冲突解决操作，并刷新文件与 Diff 状态。
  Future<bool> resolveConflict(
    RepositoryChangeViewData change,
    RepositoryConflictAction action,
  ) async {
    if (!_isInsideTrackedGitTask) {
      return _trackBooleanGitTask(() => resolveConflict(change, action));
    }
    if (action == RepositoryConflictAction.launchInternalDiffTool ||
        action == RepositoryConflictAction.launchExternalMergeTool) {
      return false;
    }
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    if (repository == null ||
        status == null ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        _sessionState.isWorkingTreeBusy) {
      return false;
    }

    GitStatusEntry? entry;
    for (final candidate in status.entries) {
      if (candidate.path.display == change.path) {
        entry = candidate;
        break;
      }
    }
    if (entry == null || !entry.isConflicted || !entry.path.isValidUtf8) {
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
      switch (action) {
        case RepositoryConflictAction.launchInternalDiffTool:
          return false;
        case RepositoryConflictAction.launchExternalMergeTool:
          return false;
        case RepositoryConflictAction.useOurs:
          await _writer.resolveConflictUsingSide(
            repository,
            entry.path,
            useOurs: true,
          );
        case RepositoryConflictAction.useTheirs:
          await _writer.resolveConflictUsingSide(
            repository,
            entry.path,
            useOurs: false,
          );
        case RepositoryConflictAction.restartMerge:
          await _writer.restartConflictMerge(repository, entry.path);
        case RepositoryConflictAction.markResolved:
          await _writer.stagePath(repository, entry.path);
        case RepositoryConflictAction.markUnresolved:
          await _writer.markConflictUnresolved(repository, entry.path);
      }
      await refresh();
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded ? '已处理冲突文件。' : '冲突处理可能已完成，但本地刷新失败；请刷新确认冲突状态。',
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

  /// Saves a custom internal-Diff merge result and refreshes conflict state.
  /// 中文：保存内部 Diff 的自定义合并结果，暂存文件并刷新冲突状态。
  Future<bool> resolveConflictWithContent(
    RepositoryChangeViewData change,
    String content,
  ) async {
    if (!_isInsideTrackedGitTask) {
      return _trackBooleanGitTask(
        () => resolveConflictWithContent(change, content),
      );
    }
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    if (repository == null ||
        status == null ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        _sessionState.isWorkingTreeBusy) {
      return false;
    }

    GitStatusEntry? entry;
    for (final candidate in status.entries) {
      if (candidate.path.display == change.path) {
        entry = candidate;
        break;
      }
    }
    if (entry == null || !entry.isConflicted || !entry.path.isValidUtf8) {
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
      await _writer.resolveConflictWithContent(repository, entry.path, content);
      await refresh();
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded ? '已保存冲突合并结果。' : '合并结果可能已保存，但本地刷新失败；请刷新确认冲突状态。',
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

  /// Runs the explicitly enabled external three-way Merge tool and safely
  /// writes its UTF-8 result back through the existing conflict writer.
  /// 中文：运行已明确启用的外部三方 Merge 工具，并复用现有安全冲突写回器写入
  /// UTF-8 结果；外部进程成功退出前不会改变工作区。
  Future<bool> resolveConflictWithExternalMerge(
    RepositoryChangeViewData change,
  ) async {
    if (!_isInsideTrackedGitTask) {
      return _trackBooleanGitTask(
        () => resolveConflictWithExternalMerge(change),
      );
    }
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    final configuration = _providerRef
        .read(externalToolConfigurationProvider)
        .configuration;
    final trustStatus = _providerRef.read(repositoryTrustProvider).status;
    if (repository == null ||
        status == null ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        _sessionState.isWorkingTreeBusy ||
        configuration == null ||
        configuration.kind != ExternalToolKind.mergeWriteBack ||
        !canActivateExternalTool(
          trustStatus: trustStatus,
          configuration: configuration,
        )) {
      return false;
    }

    GitStatusEntry? entry;
    for (final candidate in status.entries) {
      if (candidate.path.display == change.path) {
        entry = candidate;
        break;
      }
    }
    if (entry == null || !entry.isConflicted || !entry.path.isValidUtf8) {
      return false;
    }
    final initialStageIds = (
      entry.stage1ObjectId,
      entry.stage2ObjectId,
      entry.stage3ObjectId,
    );
    GitConflictFileVersions versions;
    try {
      versions = await _reader.readConflictFileVersions(repository, entry);
    } on Object catch (error, stackTrace) {
      _sessionState = _sessionState.copyWith(
        phase: RepositorySessionPhase.error,
        message: _friendlyError(error),
        technicalDetails: _technicalDetails(error, stackTrace),
      );
      return false;
    }
    if (versions.isBinary || versions.isTruncated) {
      _sessionState = _sessionState.copyWith(
        message: '二进制或超过读取上限的冲突文件不能使用外部 Merge 写回。',
      );
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
    final cancellation = GitCancellationToken();
    _externalMergeCancellation = cancellation;
    ExternalMergeToolRun? run;
    try {
      run = await _externalToolRunner.startMergeWriteBack(
        configuration: configuration,
        trustStatus: trustStatus,
        repositoryRoot: repository.workTreeRoot!,
        repositoryRelativePath: entry.path.display,
        baseBytes: utf8.encode(versions.baseText),
        oursBytes: utf8.encode(versions.oursText),
        theirsBytes: utf8.encode(versions.theirsText),
        cancellationToken: cancellation,
      );
      final content = await run.readResultUtf8();
      await run.close();
      run = null;
      if (RegExp(
        r'^(<<<<<<<|=======|>>>>>>>)(?:\s|$)',
        multiLine: true,
      ).hasMatch(content)) {
        throw StateError('外部 Merge 结果仍包含冲突标记，已拒绝写回。');
      }

      await refresh();
      if (_sessionState.phase != RepositorySessionPhase.ready) {
        throw StateError('外部 Merge 完成，但仓库状态刷新失败，未写回结果。');
      }
      final current = _sessionState.status?.entries.where(
        (candidate) => candidate.path.display == change.path,
      );
      final currentEntry = current == null || current.isEmpty
          ? null
          : current.first;
      final currentStageIds = currentEntry == null
          ? (null, null, null)
          : (
              currentEntry.stage1ObjectId,
              currentEntry.stage2ObjectId,
              currentEntry.stage3ObjectId,
            );
      if (currentEntry == null ||
          !currentEntry.isConflicted ||
          currentStageIds != initialStageIds) {
        throw StateError('冲突文件状态在外部 Merge 期间发生变化，已拒绝写回结果。');
      }
      final currentVersions = await _reader.readConflictFileVersions(
        repository,
        currentEntry,
      );
      if (currentVersions.isBinary ||
          currentVersions.isTruncated ||
          currentVersions.workingText != versions.workingText) {
        throw StateError('冲突文件工作区内容在外部 Merge 期间发生变化，已拒绝写回结果。');
      }
      await _writer.resolveConflictWithContent(
        repository,
        currentEntry.path,
        content,
      );
      await refresh();
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      final message = succeeded
          ? '已通过外部 Merge 保存 ${change.path} 并标记为已解决。'
          : '外部 Merge 结果已写入，但本地刷新失败；请刷新确认冲突状态。';
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: message,
      );
      return succeeded;
    } on Object catch (error, stackTrace) {
      if (run != null) await run.close();
      await refresh();
      final message = _friendlyError(error);
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
    } finally {
      if (run != null) await run.close();
      if (identical(_externalMergeCancellation, cancellation)) {
        _externalMergeCancellation = null;
      }
    }
  }
}
