part of 'repository_session.dart';

/// Batch tag mutations owned by [RepositorySessionController].
///
/// 中文：集中维护批量本地/远端标签写操作及其取消边界。
extension RepositorySessionTagBatchWrites on RepositorySessionController {
  /// Deletes several loaded local tags sequentially and refreshes once.
  ///
  /// 中文：逐项重新校验并删除已加载的本地标签，最后只刷新一次；不会删除远端
  /// 标签。标签在执行前已消失或单项 Git 失败都会保留在结果中，调用方可展示部分成功。
  Future<RepositoryTagDeletionResult?> deleteTags(List<String> names) async {
    if (!_isInsideTrackedGitTask) {
      return _trackGitTask<RepositoryTagDeletionResult?>(
        () => deleteTags(names),
      );
    }
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    if (repository == null ||
        status == null ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        _sessionState.operationState != GitRepositoryOperationState.none) {
      return null;
    }
    final requested = <String>{
      for (final name in names)
        if (name.trim().isNotEmpty) name.trim(),
    }.toList(growable: false);
    if (requested.isEmpty) return null;

    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    final operation = _startOperation(RepositoryOperationKind.ref);
    _tagMutationCancellation?.cancel();
    final cancellation = GitCancellationToken();
    _tagMutationCancellation = cancellation;
    _sessionState = _sessionState.copyWith(isTagMutationRunning: true);
    final deleted = <String>[];
    final missing = <String>[];
    final failed = <String, String>{};
    try {
      for (final name in requested) {
        if (cancellation.isCancelled || _isShuttingDown) {
          throw const GitCancelledException();
        }
        final currentTags = await _reader.readTags(
          repository,
          cancellationToken: cancellation,
        );
        if (cancellation.isCancelled || _isShuttingDown) {
          throw const GitCancelledException();
        }
        if (!currentTags.any((tag) => tag.name == name)) {
          missing.add(name);
          continue;
        }
        try {
          await _writer.deleteTag(
            repository,
            name: name,
            cancellationToken: cancellation,
          );
          deleted.add(name);
        } on GitCancelledException {
          rethrow;
        } on GitCommandException catch (error) {
          if (cancellation.isCancelled ||
              _isShuttingDown ||
              _operationOutcomeForError(error) ==
                  RepositoryOperationOutcome.cancelled) {
            rethrow;
          }
          failed[name] = _friendlyError(error);
        } on Object catch (error) {
          if (cancellation.isCancelled || _isShuttingDown) rethrow;
          failed[name] = _friendlyError(error);
        }
      }
      await refresh();
      final result = RepositoryTagDeletionResult(
        deletedNames: deleted,
        missingNames: missing,
        failedNames: failed,
      );
      final outcome = result.hasFailures
          ? deleted.isEmpty
                ? RepositoryOperationOutcome.failed
                : RepositoryOperationOutcome.partiallySucceeded
          : _sessionState.phase == RepositorySessionPhase.ready
          ? RepositoryOperationOutcome.succeeded
          : RepositoryOperationOutcome.uncertain;
      final message = result.hasFailures
          ? '已删除 ${deleted.length} 个标签；${missing.length + failed.length} 个标签未删除。'
          : '已删除 ${deleted.length} 个本地标签。';
      _completeOperation(operation, outcome: outcome, message: message);
      return result;
    } on GitCancelledException {
      if (!_isShuttingDown) {
        await refresh();
      }
      _completeOperation(
        operation,
        outcome: RepositoryOperationOutcome.cancelled,
        message: '本地标签删除已取消；已完成项保持不变。',
      );
      return RepositoryTagDeletionResult(
        deletedNames: deleted,
        missingNames: missing,
        failedNames: failed,
      );
    } on Object catch (error, stackTrace) {
      if (_operationOutcomeForError(error) ==
          RepositoryOperationOutcome.cancelled) {
        if (!_isShuttingDown) {
          await refresh();
        }
        _completeOperation(
          operation,
          outcome: RepositoryOperationOutcome.cancelled,
          message: '本地标签删除已取消；已完成项保持不变。',
        );
        return RepositoryTagDeletionResult(
          deletedNames: deleted,
          missingNames: missing,
          failedNames: failed,
        );
      }
      if (!_isShuttingDown) {
        await refresh();
      }
      final message = _friendlyError(error);
      _sessionState = _sessionState.copyWith(
        phase: RepositorySessionPhase.error,
        isDiffLoading: false,
        message: message,
        technicalDetails: _technicalDetails(error, stackTrace),
      );
      _completeOperation(
        operation,
        outcome: deleted.isEmpty
            ? _operationOutcomeForError(error)
            : RepositoryOperationOutcome.partiallySucceeded,
        message: message,
      );
      return RepositoryTagDeletionResult(
        deletedNames: deleted,
        missingNames: missing,
        failedNames: {
          ...failed,
          for (final name in requested)
            if (!deleted.contains(name) &&
                !missing.contains(name) &&
                !failed.containsKey(name))
              name: message,
        },
      );
    } finally {
      if (identical(_tagMutationCancellation, cancellation)) {
        _tagMutationCancellation = null;
        _sessionState = _sessionState.copyWith(isTagMutationRunning: false);
      }
    }
  }

  /// Pushes several loaded local tags sequentially to one configured remote.
  ///
  /// 中文：逐项重新校验并将已加载的本地标签推送到一个明确选择的远端，最后只刷新
  /// 一次；不会使用 force，远端拒绝、执行前已不存在和部分成功都会保留逐项结果。
  Future<RepositoryTagPushResult?> pushTags(
    List<String> names, {
    required String remoteName,
  }) async {
    if (!_isInsideTrackedGitTask) {
      return _trackGitTask<RepositoryTagPushResult?>(
        () => pushTags(names, remoteName: remoteName),
      );
    }
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    final normalizedRemote = remoteName.trim();
    if (repository == null ||
        status == null ||
        normalizedRemote.isEmpty ||
        !_sessionState.remoteNames.contains(normalizedRemote) ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        _sessionState.operationState != GitRepositoryOperationState.none) {
      return null;
    }
    final requested = <String>{
      for (final name in names)
        if (name.trim().isNotEmpty) name.trim(),
    }.toList(growable: false);
    if (requested.isEmpty) return null;

    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    final operation = _startOperation(RepositoryOperationKind.ref);
    _tagMutationCancellation?.cancel();
    final cancellation = GitCancellationToken();
    _tagMutationCancellation = cancellation;
    _sessionState = _sessionState.copyWith(isTagMutationRunning: true);
    final pushed = <String>[];
    final missing = <String>[];
    final failed = <String, String>{};
    try {
      for (final name in requested) {
        if (cancellation.isCancelled || _isShuttingDown) {
          throw const GitCancelledException();
        }
        final currentTags = await _reader.readTags(
          repository,
          cancellationToken: cancellation,
        );
        if (cancellation.isCancelled || _isShuttingDown) {
          throw const GitCancelledException();
        }
        if (!currentTags.any((tag) => tag.name == name)) {
          missing.add(name);
          continue;
        }
        try {
          await _writer.pushTag(
            repository,
            remoteName: normalizedRemote,
            tagName: name,
            cancellationToken: cancellation,
          );
          pushed.add(name);
        } on GitCancelledException {
          rethrow;
        } on GitCommandException catch (error) {
          if (cancellation.isCancelled ||
              _isShuttingDown ||
              _operationOutcomeForError(error) ==
                  RepositoryOperationOutcome.cancelled) {
            rethrow;
          }
          failed[name] = _friendlyError(error);
        } on Object catch (error) {
          if (cancellation.isCancelled || _isShuttingDown) rethrow;
          failed[name] = _friendlyError(error);
        }
      }
      await refresh();
      final result = RepositoryTagPushResult(
        remoteName: normalizedRemote,
        pushedNames: pushed,
        missingNames: missing,
        failedNames: failed,
      );
      final outcome = result.hasFailures
          ? pushed.isEmpty
                ? RepositoryOperationOutcome.failed
                : RepositoryOperationOutcome.partiallySucceeded
          : _sessionState.phase == RepositorySessionPhase.ready
          ? RepositoryOperationOutcome.succeeded
          : RepositoryOperationOutcome.uncertain;
      final message = result.hasFailures
          ? '已推送 ${pushed.length} 个标签到 $normalizedRemote；${missing.length + failed.length} 个标签未推送。'
          : '已推送 ${pushed.length} 个标签到 $normalizedRemote。';
      _completeOperation(operation, outcome: outcome, message: message);
      return result;
    } on GitCancelledException {
      if (!_isShuttingDown) {
        await refresh();
      }
      _completeOperation(
        operation,
        outcome: RepositoryOperationOutcome.cancelled,
        message: '标签推送已取消；已完成项保持不变。',
      );
      return RepositoryTagPushResult(
        remoteName: normalizedRemote,
        pushedNames: pushed,
        missingNames: missing,
        failedNames: failed,
      );
    } on Object catch (error, stackTrace) {
      if (_operationOutcomeForError(error) ==
          RepositoryOperationOutcome.cancelled) {
        if (!_isShuttingDown) {
          await refresh();
        }
        _completeOperation(
          operation,
          outcome: RepositoryOperationOutcome.cancelled,
          message: '标签推送已取消；已完成项保持不变。',
        );
        return RepositoryTagPushResult(
          remoteName: normalizedRemote,
          pushedNames: pushed,
          missingNames: missing,
          failedNames: failed,
        );
      }
      if (!_isShuttingDown) {
        await refresh();
      }
      final message = _friendlyError(error);
      _sessionState = _sessionState.copyWith(
        phase: RepositorySessionPhase.error,
        isDiffLoading: false,
        message: message,
        technicalDetails: _technicalDetails(error, stackTrace),
      );
      _completeOperation(
        operation,
        outcome: pushed.isEmpty
            ? _operationOutcomeForError(error)
            : RepositoryOperationOutcome.partiallySucceeded,
        message: message,
      );
      return RepositoryTagPushResult(
        remoteName: normalizedRemote,
        pushedNames: pushed,
        missingNames: missing,
        failedNames: {
          ...failed,
          for (final name in requested)
            if (!pushed.contains(name) &&
                !missing.contains(name) &&
                !failed.containsKey(name))
              name: message,
        },
      );
    } finally {
      if (identical(_tagMutationCancellation, cancellation)) {
        _tagMutationCancellation = null;
        _sessionState = _sessionState.copyWith(isTagMutationRunning: false);
      }
    }
  }

  /// Deletes selected tag refs sequentially from one configured remote.
  ///
  /// 中文：逐项重新读取指定远端并删除所选标签引用，最后只刷新一次；本地同名
  /// 标签保持不变，不使用 force，执行前已不存在和部分成功都会保留逐项结果。
  Future<RepositoryRemoteTagDeletionResult?> deleteRemoteTags(
    List<String> names, {
    required String remoteName,
  }) async {
    if (!_isInsideTrackedGitTask) {
      return _trackGitTask<RepositoryRemoteTagDeletionResult?>(
        () => deleteRemoteTags(names, remoteName: remoteName),
      );
    }
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    final normalizedRemote = remoteName.trim();
    if (repository == null ||
        status == null ||
        normalizedRemote.isEmpty ||
        !_sessionState.remoteNames.contains(normalizedRemote) ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        _sessionState.operationState != GitRepositoryOperationState.none) {
      return null;
    }
    final requested = <String>{
      for (final name in names)
        if (name.trim().isNotEmpty) name.trim(),
    }.toList(growable: false);
    if (requested.isEmpty) return null;

    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    final operation = _startOperation(RepositoryOperationKind.ref);
    _remoteTagDeletionCancellation?.cancel();
    final cancellation = GitCancellationToken();
    _remoteTagDeletionCancellation = cancellation;
    _sessionState = _sessionState.copyWith(isTagMutationRunning: true);
    final deleted = <String>[];
    final missing = <String>[];
    final failed = <String, String>{};
    try {
      for (final name in requested) {
        if (cancellation.isCancelled || _isShuttingDown) {
          throw const GitCancelledException();
        }
        final currentRemoteTags = await _reader.readRemoteTags(
          repository,
          remoteName: normalizedRemote,
          cancellationToken: cancellation,
        );
        if (cancellation.isCancelled || _isShuttingDown) {
          throw const GitCancelledException();
        }
        if (!currentRemoteTags.any((tag) => tag.name == name)) {
          missing.add(name);
          continue;
        }
        try {
          await _writer.deleteRemoteTag(
            repository,
            remoteName: normalizedRemote,
            tagName: name,
            cancellationToken: cancellation,
          );
          deleted.add(name);
        } on GitCancelledException {
          rethrow;
        } on GitCommandException catch (error) {
          if (_isShuttingDown ||
              cancellation.isCancelled ||
              _operationOutcomeForError(error) ==
                  RepositoryOperationOutcome.cancelled) {
            throw const GitCancelledException();
          }
          failed[name] = _friendlyError(error);
        } on Object catch (error) {
          if (_isShuttingDown ||
              cancellation.isCancelled ||
              _operationOutcomeForError(error) ==
                  RepositoryOperationOutcome.cancelled) {
            throw const GitCancelledException();
          }
          failed[name] = _friendlyError(error);
        }
      }
      await refresh();
      if (_sessionState.repository?.id == repository.id) {
        _sessionState = _sessionState.copyWith(
          tagRemoteStatuses: {
            ..._sessionState.tagRemoteStatuses,
            for (final name in [...deleted, ...missing])
              name: GitTagRemoteStatus.missing,
          },
          tagRemoteNames: {
            ..._sessionState.tagRemoteNames,
            for (final name in [...deleted, ...missing]) name: normalizedRemote,
          },
        );
      }
      final result = RepositoryRemoteTagDeletionResult(
        remoteName: normalizedRemote,
        deletedNames: deleted,
        missingNames: missing,
        failedNames: failed,
      );
      final outcome = result.hasFailures
          ? deleted.isEmpty
                ? RepositoryOperationOutcome.failed
                : RepositoryOperationOutcome.partiallySucceeded
          : _sessionState.phase == RepositorySessionPhase.ready
          ? RepositoryOperationOutcome.succeeded
          : RepositoryOperationOutcome.uncertain;
      final message = result.hasFailures
          ? '已从 $normalizedRemote 删除 ${deleted.length} 个标签；${missing.length + failed.length} 个标签未删除。'
          : '已从 $normalizedRemote 删除 ${deleted.length} 个标签。';
      _completeOperation(operation, outcome: outcome, message: message);
      return result;
    } on GitCancelledException {
      if (!_isShuttingDown) {
        await refresh();
      }
      _completeOperation(
        operation,
        outcome: RepositoryOperationOutcome.cancelled,
        message: '远端标签删除已取消；已完成项保持不变。',
      );
      return RepositoryRemoteTagDeletionResult(
        remoteName: normalizedRemote,
        deletedNames: deleted,
        missingNames: missing,
        failedNames: failed,
      );
    } on Object catch (error, stackTrace) {
      if (_operationOutcomeForError(error) ==
          RepositoryOperationOutcome.cancelled) {
        if (!_isShuttingDown) {
          await refresh();
        }
        _completeOperation(
          operation,
          outcome: RepositoryOperationOutcome.cancelled,
          message: '远端标签删除已取消；已完成项保持不变。',
        );
        return RepositoryRemoteTagDeletionResult(
          remoteName: normalizedRemote,
          deletedNames: deleted,
          missingNames: missing,
          failedNames: failed,
        );
      }
      if (!_isShuttingDown) {
        await refresh();
      }
      final message = _friendlyError(error);
      _sessionState = _sessionState.copyWith(
        phase: RepositorySessionPhase.error,
        isDiffLoading: false,
        message: message,
        technicalDetails: _technicalDetails(error, stackTrace),
      );
      _completeOperation(
        operation,
        outcome: deleted.isEmpty
            ? _operationOutcomeForError(error)
            : RepositoryOperationOutcome.partiallySucceeded,
        message: message,
      );
      return RepositoryRemoteTagDeletionResult(
        remoteName: normalizedRemote,
        deletedNames: deleted,
        missingNames: missing,
        failedNames: {
          ...failed,
          for (final name in requested)
            if (!deleted.contains(name) &&
                !missing.contains(name) &&
                !failed.containsKey(name))
              name: message,
        },
      );
    } finally {
      if (identical(_remoteTagDeletionCancellation, cancellation)) {
        _remoteTagDeletionCancellation = null;
        _sessionState = _sessionState.copyWith(isTagMutationRunning: false);
      }
    }
  }

  /// Cancels an in-flight remote tag deletion between individual tag refs.
  ///
  /// 中文：取消正在进行的远端标签批量删除；已完成的删除不会回滚，尚未开始的
  /// 标签不会继续执行。
  void cancelRemoteTagDeletion() {
    _remoteTagDeletionCancellation?.cancel();
  }

  /// Cancels an in-flight batch tag mutation without rolling back completed refs.
  /// 中文：取消正在进行的批量标签写操作；已完成的引用不会回滚。
  void cancelTagMutation() {
    _tagMutationCancellation?.cancel();
    _remoteTagDeletionCancellation?.cancel();
  }

  /// 中文：以已加载的本地分支为起点创建另一个本地分支，不切换当前工作区。
  ///
  /// English: Creates a local branch from an already loaded local branch
  /// without switching the current work tree.
  Future<bool> createLocalBranchFromLocalBranch(
    String name,
    String sourceName,
  ) async {
    if (!_isInsideTrackedGitTask) {
      return _trackBooleanGitTask(
        () => createLocalBranchFromLocalBranch(name, sourceName),
      );
    }
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    if (repository == null ||
        status == null ||
        status.branch.isUnborn ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        !_sessionState.localBranches.any(
          (branch) => branch.name == sourceName,
        )) {
      return false;
    }
    if (name.trim().isEmpty || sourceName.trim().isEmpty) {
      throw ArgumentError('A branch name and source branch are required.');
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
      await _writer.createLocalBranchFromLocalBranch(
        repository,
        name: name,
        sourceName: sourceName,
      );
      await refresh();
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded
            ? '已从 $sourceName 创建本地分支 $name。'
            : '分支可能已创建，但本地刷新失败；请刷新确认引用状态。',
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

  /// Switches to a local branch while preserving safe working-tree changes.
  /// 中文：切换到本地分支；保留可安全携带的工作区改动，并拒绝冲突状态。
  /// English: Switches to a local branch, preserving changes Git can carry
  /// safely and rejecting repositories with unresolved conflicts.
  Future<bool> switchToLocalBranch(String name) async =>
      await _trackGitTask<bool>(() => _switchToLocalBranch(name)) ?? false;

  /// 中文：在关闭屏障内执行本地分支切换。
  /// English: Performs a local-branch switch inside the shutdown barrier.
  Future<bool> _switchToLocalBranch(String name) async {
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    if (repository == null ||
        status == null ||
        status.conflictedEntries.isNotEmpty ||
        _sessionState.phase == RepositorySessionPhase.loading) {
      return false;
    }
    if (name.trim().isEmpty) {
      throw ArgumentError.value(name, 'name', 'Branch name is empty.');
    }
    if (status.branch.head == name) {
      return true;
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
      await _writer.switchToLocalBranch(repository, name: name);
      await refresh();
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded ? '已切换到分支 $name。' : '分支可能已切换，但本地刷新失败；请刷新确认引用状态。',
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
