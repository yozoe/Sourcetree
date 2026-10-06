part of 'repository_session.dart';

/// Git-flow Start and Finish mutations owned by [RepositorySessionController].
///
/// 中文：集中维护 Git-flow Start/Finish、取消和预检说明；保留原有本地引用、
/// 不自动推送/删除来源分支以及冲突恢复语义。
extension RepositorySessionGitFlowWrites on RepositorySessionController {
  /// Executes one validated Git-flow Start by creating and checking out the
  /// planned local branch without pushing or deleting any reference.
  /// 中文：执行一个已校验的 Git-flow Start；创建并检出本地分支，不推送或删除任何引用。
  /// The method keeps both Git writes inside one Engine task. If creation
  /// succeeds but checkout fails, the returned result preserves that partial
  /// success and the created branch remains visible after refresh.
  /// A stale plan is returned as an explicit unsuccessful result so the UI can
  /// explain which safety gate changed after the preview was shown.
  /// 中文：如果预览后仓库状态发生变化，会返回带明确原因的失败结果，而不是静默丢弃请求。
  Future<GitFlowStartExecutionResult?> startGitFlowBranch(
    GitFlowStartPlan plan,
  ) async {
    if (!_isInsideTrackedGitTask) {
      return _trackGitTask<GitFlowStartExecutionResult?>(
        () => startGitFlowBranch(plan),
      );
    }
    if (_sessionState.phase == RepositorySessionPhase.loading) return null;

    await refresh();
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    if (_sessionState.phase != RepositorySessionPhase.ready ||
        repository == null ||
        status == null ||
        status.branch.isDetached ||
        status.branch.isUnborn ||
        !status.isClean ||
        _sessionState.operationState != GitRepositoryOperationState.none ||
        !_sessionState.localBranches.any(
          (branch) => branch.name == plan.baseBranch,
        ) ||
        _sessionState.localBranches.any(
          (branch) => branch.name == plan.branchName,
        )) {
      return GitFlowStartExecutionResult(
        branchCreated: false,
        checkedOut: false,
        message: _gitFlowStartPreflightMessage(plan),
      );
    }

    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    final operation = _startOperation(RepositoryOperationKind.ref);
    final cancellation = GitCancellationToken();
    _gitFlowStartCancellation = cancellation;
    var branchCreated = false;
    var checkedOut = false;
    try {
      await _writer.createLocalBranchFromLocalBranch(
        repository,
        name: plan.branchName,
        sourceName: plan.baseBranch,
        cancellationToken: cancellation,
      );
      branchCreated = true;
      await _writer.switchToLocalBranch(
        repository,
        name: plan.branchName,
        cancellationToken: cancellation,
      );
      checkedOut = true;
      await refresh();
      final succeeded =
          _sessionState.phase == RepositorySessionPhase.ready &&
          _sessionState.status?.branch.head == plan.branchName;
      final result = GitFlowStartExecutionResult(
        branchCreated: branchCreated,
        checkedOut: checkedOut && succeeded,
        message: succeeded
            ? '已创建并切换到 Git-flow 分支 ${plan.branchName}。'
            : 'Git-flow 分支可能已创建并切换，但刷新结果不确定；请刷新确认当前分支。',
      );
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: result.message,
      );
      return result;
    } on Object catch (error, stackTrace) {
      await refresh();
      final message = branchCreated
          ? '已创建 Git-flow 分支 ${plan.branchName}，但检出失败：${_friendlyError(error)}'
          : _friendlyError(error);
      _sessionState = _sessionState.copyWith(
        phase: RepositorySessionPhase.error,
        isDiffLoading: false,
        message: message,
        technicalDetails: _technicalDetails(error, stackTrace),
      );
      final result = GitFlowStartExecutionResult(
        branchCreated: branchCreated,
        checkedOut: checkedOut,
        message: message,
      );
      _completeOperation(
        operation,
        outcome: branchCreated
            ? RepositoryOperationOutcome.partiallySucceeded
            : _operationOutcomeForError(error),
        message: message,
      );
      return result;
    } finally {
      if (identical(_gitFlowStartCancellation, cancellation)) {
        _gitFlowStartCancellation = null;
      }
    }
  }

  /// Cancels an in-flight Git-flow Start without attempting to undo a branch
  /// that Git may already have created.
  /// 中文：取消正在进行的 Git-flow Start；不会尝试回滚 Git 可能已经创建的分支。
  void cancelGitFlowStart() => _gitFlowStartCancellation?.cancel();

  /// Explains why a previously previewed Git-flow Start plan is no longer safe.
  /// 中文：说明已预览的 Git-flow Start 计划为何不再满足安全门槛。
  String _gitFlowStartPreflightMessage(GitFlowStartPlan plan) {
    if (_isShuttingDown) return 'Git-flow Start 已取消：仓库窗口正在关闭。';
    if (_sessionState.phase != RepositorySessionPhase.ready ||
        _sessionState.repository == null ||
        _sessionState.status == null) {
      return 'Git-flow Start 未执行：仓库状态尚未就绪，请刷新后重试。';
    }
    final status = _sessionState.status!;
    if (status.branch.isDetached) return 'Git-flow Start 需要附着在本地分支上。';
    if (status.branch.isUnborn) return 'Git-flow Start 需要已有提交的本地分支。';
    if (!status.isClean) return 'Git-flow Start 需要干净的工作区。';
    if (_sessionState.operationState != GitRepositoryOperationState.none) {
      return '当前存在未完成的 Git 操作，暂时不能开始 Git-flow 分支。';
    }
    if (!_sessionState.localBranches.any(
      (branch) => branch.name == plan.baseBranch,
    )) {
      return '起点分支 ${plan.baseBranch} 已不存在或状态已变化，请重新打开 Git-flow Start。';
    }
    if (_sessionState.localBranches.any(
      (branch) => branch.name == plan.branchName,
    )) {
      return '分支 ${plan.branchName} 已存在，请重新打开 Git-flow Start。';
    }
    return 'Git-flow Start 的仓库状态已变化，请重新打开对话框后重试。';
  }

  /// Executes one validated Git-flow Finish by checking out the explicit
  /// target branch and merging the current feature/release/hotfix branch into
  /// it. No push, source deletion, or upstream change is attempted.
  /// 中文：执行一个已校验的 Git-flow Finish：检出明确目标分支，再将当前
  /// feature/release/hotfix 分支合并进去；不会推送、删除来源或修改 upstream。
  /// If checkout succeeds but merge fails, the target branch and Git's actual
  /// conflict _sessionState are preserved for recovery through Continue/Abort.
  /// A stale plan is returned as an explicit unsuccessful result so the UI can
  /// explain why no checkout or merge was started.
  /// 中文：如果预览后仓库状态发生变化，会返回带明确原因的失败结果，并且不会开始检出或合并。
  Future<GitFlowFinishExecutionResult?> finishGitFlowBranch(
    GitFlowFinishPlan plan,
  ) async {
    if (!_isInsideTrackedGitTask) {
      return _trackGitTask<GitFlowFinishExecutionResult?>(
        () => finishGitFlowBranch(plan),
      );
    }
    if (_sessionState.phase == RepositorySessionPhase.loading) return null;

    await refresh();
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    final currentBranch = status?.branch.head;
    final currentKind = currentBranch == null
        ? null
        : gitFlowBranchKindForName(currentBranch);
    if (_sessionState.phase != RepositorySessionPhase.ready ||
        repository == null ||
        status == null ||
        currentBranch == null ||
        currentKind != plan.kind ||
        currentBranch != plan.sourceBranch ||
        status.branch.isDetached ||
        status.branch.isUnborn ||
        !status.isClean ||
        _sessionState.operationState != GitRepositoryOperationState.none ||
        !_sessionState.localBranches.any(
          (branch) => branch.name == plan.sourceBranch,
        ) ||
        !_sessionState.localBranches.any(
          (branch) => branch.name == plan.targetBranch,
        ) ||
        plan.sourceBranch == plan.targetBranch) {
      return GitFlowFinishExecutionResult(
        merged: false,
        message: _gitFlowFinishPreflightMessage(plan),
      );
    }

    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    final operation = _startOperation(RepositoryOperationKind.ref);
    final cancellation = GitCancellationToken();
    _gitFlowFinishCancellation = cancellation;
    var checkedOutTarget = false;
    try {
      await _writer.switchToLocalBranch(
        repository,
        name: plan.targetBranch,
        cancellationToken: cancellation,
      );
      checkedOutTarget = true;
      await _writer.mergeLocalBranch(
        repository,
        sourceName: plan.sourceBranch,
        cancellationToken: cancellation,
      );
      await refresh();
      final succeeded =
          _sessionState.phase == RepositorySessionPhase.ready &&
          _sessionState.status?.branch.head == plan.targetBranch &&
          _sessionState.status?.conflictedEntries.isEmpty == true;
      final result = GitFlowFinishExecutionResult(
        merged: succeeded,
        message: succeeded
            ? '已将 ${plan.sourceBranch} 合并到 ${plan.targetBranch}；未推送或删除来源分支。'
            : 'Git-flow Finish 可能已完成，但刷新结果不确定；请刷新确认 ${plan.targetBranch} 的状态。',
      );
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: result.message,
      );
      return result;
    } on Object catch (error, stackTrace) {
      await refresh();
      final hasConflicts =
          _sessionState.status?.conflictedEntries.isNotEmpty ?? false;
      final message =
          hasConflicts ||
              (error is GitCommandException &&
                  error.kind == GitErrorKind.conflicts)
          ? 'Git-flow Finish 在 ${plan.targetBranch} 上遇到冲突。请处理并暂存冲突后，从“动作”菜单继续或中止合并。'
          : checkedOutTarget
          ? '已切换到 ${plan.targetBranch}，但合并 ${plan.sourceBranch} 失败：${_friendlyError(error)}'
          : _friendlyError(error);
      _sessionState = _sessionState.copyWith(
        phase: RepositorySessionPhase.error,
        isDiffLoading: false,
        message: message,
        technicalDetails: _technicalDetails(error, stackTrace),
      );
      final outcome = hasConflicts
          ? _operationOutcomeForError(error)
          : checkedOutTarget
          ? RepositoryOperationOutcome.partiallySucceeded
          : _operationOutcomeForError(error);
      _completeOperation(operation, outcome: outcome, message: message);
      return GitFlowFinishExecutionResult(merged: false, message: message);
    } finally {
      if (identical(_gitFlowFinishCancellation, cancellation)) {
        _gitFlowFinishCancellation = null;
      }
    }
  }

  /// Executes a validated multi-source Git-flow Finish in order.
  /// 中文：按显式顺序完成多个 Git-flow 来源分支，可选创建本地版本标签并安全删除来源。
  ///
  /// Every merge is a separate Git write. Completed merges are never rolled
  /// back when a later merge, tag, deletion, cancellation, or refresh fails.
  /// Source deletion uses Git's merged-only mode and is attempted only after
  /// all requested merges and the optional release tag succeed.
  /// 中文：每次合并都是独立 Git 写入；后续合并、标签、删除、取消或刷新失败时不回滚已完成合并。
  /// 来源删除只使用 Git 安全模式，并且仅在全部合并及可选版本标签成功后尝试。
  Future<GitFlowBatchFinishExecutionResult?> finishGitFlowBatch(
    GitFlowBatchFinishPlan plan,
  ) async {
    if (!_isInsideTrackedGitTask) {
      return _trackGitTask<GitFlowBatchFinishExecutionResult?>(
        () => finishGitFlowBatch(plan),
      );
    }
    if (_sessionState.phase == RepositorySessionPhase.loading) return null;

    await refresh();
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    final validation = validateGitFlowBatchFinish(
      sourceBranches: plan.sourceBranches,
      targetBranch: plan.targetBranch,
      existingBranches: [
        for (final branch in _sessionState.localBranches) branch.name,
      ],
      isAttachedHead: status?.branch.isDetached == false,
      isWorkingTreeClean: status?.isClean == true,
      hasActiveOperation:
          _sessionState.operationState != GitRepositoryOperationState.none,
      deleteSourceBranches: plan.deleteSourceBranches,
      releaseTag: plan.releaseTag,
    );
    if (_sessionState.phase != RepositorySessionPhase.ready ||
        repository == null ||
        status == null ||
        validation.plan == null) {
      return GitFlowBatchFinishExecutionResult(
        items: const [],
        targetCheckedOut: false,
        tagCreated: false,
        cancelled: false,
        message: validation.error ?? 'Git-flow Finish 未执行：仓库状态尚未就绪，请刷新后重试。',
      );
    }

    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    final operation = _startOperation(RepositoryOperationKind.ref);
    final cancellation = GitCancellationToken();
    _gitFlowFinishCancellation = cancellation;
    final items = <GitFlowBatchFinishItemResult>[];
    var targetCheckedOut = false;
    var tagCreated = plan.releaseTag == null;
    var cancelled = false;
    var allMergesSucceeded = true;
    var allDeletionsSucceeded = true;
    String? failureMessage;
    try {
      await _writer.switchToLocalBranch(
        repository,
        name: plan.targetBranch,
        cancellationToken: cancellation,
      );
      targetCheckedOut = true;
      for (final source in plan.sourceBranches) {
        try {
          await _writer.mergeLocalBranch(
            repository,
            sourceName: source,
            cancellationToken: cancellation,
          );
          await refresh();
          final conflicts =
              _sessionState.status?.conflictedEntries.isNotEmpty ?? false;
          if (_sessionState.phase != RepositorySessionPhase.ready ||
              conflicts) {
            allMergesSucceeded = false;
            failureMessage = conflicts
                ? 'Git-flow Finish 在 $source 合并时遇到冲突。请处理冲突后继续或中止。'
                : 'Git-flow Finish 合并 $source 后刷新结果不确定；请刷新确认。';
            items.add(
              GitFlowBatchFinishItemResult(
                sourceBranch: source,
                merged:
                    !conflicts &&
                    _sessionState.phase == RepositorySessionPhase.ready,
                deleted: false,
                message: failureMessage,
              ),
            );
            break;
          }
          items.add(
            GitFlowBatchFinishItemResult(
              sourceBranch: source,
              merged: true,
              deleted: false,
            ),
          );
        } on GitCancelledException {
          cancelled = true;
          allMergesSucceeded = false;
          failureMessage = 'Git-flow Finish 已取消；已完成的合并不会自动回滚。';
          break;
        } on Object catch (error, stackTrace) {
          await refresh();
          allMergesSucceeded = false;
          failureMessage = _friendlyError(error);
          _sessionState = _sessionState.copyWith(
            phase: RepositorySessionPhase.error,
            isDiffLoading: false,
            message: failureMessage,
            technicalDetails: _technicalDetails(error, stackTrace),
          );
          items.add(
            GitFlowBatchFinishItemResult(
              sourceBranch: source,
              merged: false,
              deleted: false,
              message: failureMessage,
            ),
          );
          break;
        }
      }

      if (allMergesSucceeded && plan.releaseTag != null) {
        final headObjectId = _sessionState.status?.branch.objectId;
        if (headObjectId == null || headObjectId.isEmpty) {
          allMergesSucceeded = false;
          failureMessage = '无法读取目标分支的最新提交，未创建版本标签。';
        } else {
          try {
            await _writer.createTag(
              repository,
              name: plan.releaseTag!,
              objectId: headObjectId,
              annotation: 'Release ${plan.releaseTag}',
              annotated: true,
              cancellationToken: cancellation,
            );
            tagCreated = true;
            await refresh();
            if (_sessionState.phase != RepositorySessionPhase.ready) {
              allMergesSucceeded = false;
              failureMessage = '版本标签已创建，但写入后刷新结果不确定；未继续删除来源分支。';
            }
          } on GitCancelledException {
            cancelled = true;
            allMergesSucceeded = false;
            failureMessage = '版本标签创建已取消；已完成的合并不会自动回滚。';
          } on Object catch (error, stackTrace) {
            allMergesSucceeded = false;
            failureMessage = '合并已完成，但版本标签创建失败：${_friendlyError(error)}';
            _sessionState = _sessionState.copyWith(
              phase: RepositorySessionPhase.error,
              isDiffLoading: false,
              message: failureMessage,
              technicalDetails: _technicalDetails(error, stackTrace),
            );
          }
        }
      }

      if (allMergesSucceeded && tagCreated && plan.deleteSourceBranches) {
        for (var index = 0; index < items.length; index++) {
          final item = items[index];
          if (!item.merged) continue;
          try {
            await _writer.deleteLocalBranch(
              repository,
              name: item.sourceBranch,
              force: false,
              cancellationToken: cancellation,
            );
            items[index] = GitFlowBatchFinishItemResult(
              sourceBranch: item.sourceBranch,
              merged: true,
              deleted: true,
              message: item.message,
            );
          } on GitCancelledException {
            cancelled = true;
            allDeletionsSucceeded = false;
            failureMessage = '来源分支删除已取消；已完成的合并和删除不会自动回滚。';
            break;
          } on Object catch (error) {
            allDeletionsSucceeded = false;
            failureMessage ??= '部分来源分支已合并，但未能全部安全删除。';
            items[index] = GitFlowBatchFinishItemResult(
              sourceBranch: item.sourceBranch,
              merged: true,
              deleted: false,
              message: _friendlyError(error),
            );
          }
        }
        await refresh();
        if (_sessionState.phase != RepositorySessionPhase.ready) {
          allDeletionsSucceeded = false;
          failureMessage ??= '来源分支删除后刷新结果不确定，请刷新确认。';
        }
      }

      final succeeded =
          targetCheckedOut &&
          allMergesSucceeded &&
          !cancelled &&
          tagCreated &&
          allDeletionsSucceeded;
      final message = succeeded
          ? '已将 ${plan.sourceBranches.length} 个 Git-flow 分支合并到 ${plan.targetBranch}。'
                '${plan.releaseTag == null ? '' : ' 已创建版本标签 ${plan.releaseTag}。'}'
                '${plan.deleteSourceBranches ? ' 已尝试安全删除来源分支。' : ''}'
          : failureMessage ?? 'Git-flow 批量 Finish 未完全完成；请刷新确认仓库状态。';
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : cancelled
            ? RepositoryOperationOutcome.cancelled
            : items.any((item) => item.merged)
            ? RepositoryOperationOutcome.partiallySucceeded
            : RepositoryOperationOutcome.failed,
        message: message,
      );
      return GitFlowBatchFinishExecutionResult(
        items: items,
        targetCheckedOut: targetCheckedOut,
        tagCreated: tagCreated,
        cancelled: cancelled,
        message: message,
        deletionsSucceeded: allDeletionsSucceeded,
      );
    } on GitCancelledException {
      cancelled = true;
      final message = 'Git-flow 批量 Finish 已取消；已完成的合并不会自动回滚。';
      await refresh();
      _completeOperation(
        operation,
        outcome: RepositoryOperationOutcome.cancelled,
        message: message,
      );
      return GitFlowBatchFinishExecutionResult(
        items: items,
        targetCheckedOut: targetCheckedOut,
        tagCreated: tagCreated,
        cancelled: true,
        message: message,
        deletionsSucceeded: allDeletionsSucceeded,
      );
    } on Object catch (error, stackTrace) {
      final message = _friendlyError(error);
      await refresh();
      _sessionState = _sessionState.copyWith(
        phase: RepositorySessionPhase.error,
        isDiffLoading: false,
        message: message,
        technicalDetails: _technicalDetails(error, stackTrace),
      );
      _completeOperation(
        operation,
        outcome: items.any((item) => item.merged)
            ? RepositoryOperationOutcome.partiallySucceeded
            : _operationOutcomeForError(error),
        message: message,
      );
      return GitFlowBatchFinishExecutionResult(
        items: items,
        targetCheckedOut: targetCheckedOut,
        tagCreated: tagCreated,
        cancelled: false,
        message: message,
        deletionsSucceeded: allDeletionsSucceeded,
      );
    } finally {
      if (identical(_gitFlowFinishCancellation, cancellation)) {
        _gitFlowFinishCancellation = null;
      }
    }
  }

  /// Cancels an in-flight Git-flow Finish without attempting to switch back or
  /// undo a merge that Git may already have started.
  /// 中文：取消正在进行的 Git-flow Finish；不会自动切回来源分支或回滚 Git 已开始的合并。
  void cancelGitFlowFinish() => _gitFlowFinishCancellation?.cancel();

  /// Explains why a previously previewed Git-flow Finish plan is no longer safe.
  /// 中文：说明已预览的 Git-flow Finish 计划为何不再满足安全门槛。
  String _gitFlowFinishPreflightMessage(GitFlowFinishPlan plan) {
    if (_isShuttingDown) return 'Git-flow Finish 已取消：仓库窗口正在关闭。';
    if (_sessionState.phase != RepositorySessionPhase.ready ||
        _sessionState.repository == null ||
        _sessionState.status == null) {
      return 'Git-flow Finish 未执行：仓库状态尚未就绪，请刷新后重试。';
    }
    final status = _sessionState.status!;
    final currentBranch = status.branch.head;
    if (status.branch.isDetached) return 'Git-flow Finish 需要附着在本地分支上。';
    if (status.branch.isUnborn) return 'Git-flow Finish 需要已有提交的本地分支。';
    if (!status.isClean) return 'Git-flow Finish 需要干净的工作区。';
    if (_sessionState.operationState != GitRepositoryOperationState.none) {
      return '当前存在未完成的 Git 操作，暂时不能完成 Git-flow 分支。';
    }
    if (currentBranch != plan.sourceBranch) {
      return '当前分支已从 ${plan.sourceBranch} 变为 ${currentBranch ?? '未知'}，未执行合并。';
    }
    if (gitFlowBranchKindForName(currentBranch ?? '') != plan.kind) {
      return '当前分支不再是与预览一致的 Git-flow 分支，未执行合并。';
    }
    if (!_sessionState.localBranches.any(
      (branch) => branch.name == plan.sourceBranch,
    )) {
      return '来源分支 ${plan.sourceBranch} 已不存在或状态已变化，请重新打开 Git-flow Finish。';
    }
    if (!_sessionState.localBranches.any(
      (branch) => branch.name == plan.targetBranch,
    )) {
      return '目标分支 ${plan.targetBranch} 已不存在或状态已变化，请重新打开 Git-flow Finish。';
    }
    if (plan.sourceBranch == plan.targetBranch) {
      return 'Git-flow Finish 的来源和目标分支不能相同。';
    }
    return 'Git-flow Finish 的仓库状态已变化，请重新打开对话框后重试。';
  }
}
