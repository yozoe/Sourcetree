part of 'repository_session.dart';

/// Automatic file-monitor refresh behavior for the repository session.
///
/// 中文：承载文件监控、节流刷新和工作区状态恢复；Controller 仍拥有状态、
/// generation、取消令牌和 Git runner，避免异步生命周期被拆散。
extension RepositorySessionRefresh on RepositorySessionController {
  /// Enables file-system invalidation for this Engine-owned repository session.
  ///
  /// The monitor follows repository switches and is released with the
  /// provider. File events only request a refresh; Git remains authoritative.
  ///
  /// 中文：为当前 Engine 的仓库会话启用文件系统失效监听。监听会跟随仓库切换
  /// 并随 Provider 释放；文件事件只触发刷新，最终状态仍以 Git 为准。
  Future<void> enableAutomaticRefresh() async {
    if (_isShuttingDown) return;
    _automaticRefreshEnabled = true;
    final repository = _sessionState.repository;
    if (repository != null &&
        _sessionState.phase == RepositorySessionPhase.ready) {
      await _startRepositoryMonitor(repository, _repositoryGeneration);
    }
  }

  /// Disables automatic refresh and drains the active directory subscriptions.
  ///
  /// 中文：关闭自动刷新并等待当前目录监听全部释放。
  Future<void> disableAutomaticRefresh() async {
    _automaticRefreshEnabled = false;
    _automaticRefreshPending = false;
    _automaticRefreshNeedsMetadata = false;
    await _changeMonitor.stop();
  }

  /// Requests a coalesced refresh after an external invalidation or focus gain.
  ///
  /// Metadata invalidations reload refs and history; ordinary work-tree and
  /// focus invalidations only read status, operation state, and the selected
  /// working-tree Diff. Concurrent requests collapse into at most one follow-up.
  ///
  /// 中文：在外部变化或窗口重新聚焦后请求合并刷新。Git 元数据变化会重读引用
  /// 和历史；普通工作区及聚焦兜底只重读状态、操作状态和当前工作区 Diff。
  /// 并发请求最多合并为一次后续刷新。
  void requestAutomaticRefresh({bool repositoryMetadataChanged = false}) {
    if (!_automaticRefreshEnabled || _isShuttingDown) return;
    _automaticRefreshRequestVersion++;
    _automaticRefreshPending = true;
    _automaticRefreshNeedsMetadata |= repositoryMetadataChanged;
    if (!_automaticRefreshInProgress) {
      unawaited(_drainAutomaticRefresh());
    }
  }

  /// Installs the monitor only if an async repository open is still current.
  ///
  /// 中文：仅在异步仓库打开结果仍属于当前代际时安装目录监听。
  Future<void> _startRepositoryMonitor(
    GitRepository repository,
    int repositoryGeneration,
  ) async {
    if (!_automaticRefreshEnabled ||
        _isShuttingDown ||
        repositoryGeneration != _repositoryGeneration) {
      return;
    }
    try {
      await _changeMonitor.start(
        repository,
        onChanged: (scope) => requestAutomaticRefresh(
          repositoryMetadataChanged:
              scope == RepositoryExternalChangeScope.repositoryMetadata,
        ),
      );
    } on Object {
      // File watching is opportunistic; focus and manual refresh remain safe.
    }
  }

  /// Serializes automatic reads and waits out application-owned Git mutations.
  ///
  /// 中文：串行执行自动读取，并在应用自身 Git 写操作期间等待安全刷新时机。
  Future<void> _drainAutomaticRefresh() async {
    if (_automaticRefreshInProgress) return;
    _automaticRefreshInProgress = true;
    try {
      while (_automaticRefreshPending &&
          _automaticRefreshEnabled &&
          !_isShuttingDown &&
          !_isDisposed) {
        final repository = _sessionState.repository;
        if (repository == null ||
            _sessionState.phase == RepositorySessionPhase.empty ||
            _sessionState.phase == RepositorySessionPhase.error) {
          _automaticRefreshPending = false;
          _automaticRefreshNeedsMetadata = false;
          return;
        }
        if (_automaticRefreshIsBlocked) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          continue;
        }
        final lastCompletedAt = _lastAutomaticRefreshCompletedAt;
        if (lastCompletedAt != null) {
          final remainingCooldown =
              RepositorySessionController._automaticRefreshCooldown -
              DateTime.now().difference(lastCompletedAt);
          if (remainingCooldown > Duration.zero) {
            await Future<void>.delayed(remainingCooldown);
            continue;
          }
        }
        final reloadMetadata = _automaticRefreshNeedsMetadata;
        _automaticRefreshPending = false;
        _automaticRefreshNeedsMetadata = false;
        try {
          if (reloadMetadata) {
            await refresh();
          } else {
            await _refreshWorkingTreeFromGit();
          }
        } finally {
          _lastAutomaticRefreshCompletedAt = DateTime.now();
        }
      }
    } finally {
      _automaticRefreshInProgress = false;
      if (_automaticRefreshPending &&
          _automaticRefreshEnabled &&
          !_isShuttingDown) {
        unawaited(_drainAutomaticRefresh());
      }
    }
  }

  /// Whether an application-owned operation currently excludes auto refresh.
  ///
  /// 中文：判断应用自身操作当前是否要求延后自动刷新。
  bool get _automaticRefreshIsBlocked =>
      _sessionState.phase != RepositorySessionPhase.ready ||
      _sessionState.isWorkingTreeBusy ||
      _sessionState.isCloneRunning ||
      _sessionState.isFetchRunning ||
      _sessionState.isPullRunning ||
      _sessionState.isPushRunning ||
      _sessionState.isStashRunning ||
      _sessionState.operations.any(
        (operation) => operation.outcome == RepositoryOperationOutcome.running,
      );

  /// Reads only the Git state invalidated by ordinary external file changes.
  ///
  /// The history snapshot stays intact. A surviving working-tree selection is
  /// restored and its Diff is re-read; a clean tree returns an uncommitted-row
  /// selection to the latest commit.
  ///
  /// 中文：只读取普通外部文件变化影响的 Git 状态，保留历史快照。仍有效的
  /// 工作区文件选择会恢复并重读 Diff；工作区变干净时回到最新提交。
  Future<void> _refreshWorkingTreeFromGit() async {
    if (!_isInsideTrackedGitTask) {
      return _trackVoidGitTask(_refreshWorkingTreeFromGit);
    }
    final repository = _sessionState.repository;
    if (repository == null ||
        _sessionState.phase != RepositorySessionPhase.ready) {
      return;
    }
    final repositoryGeneration = _repositoryGeneration;
    final previousSelection = _sessionState.selectedChange;
    final previousRefId = _sessionState.selectedRefId;
    try {
      final results = await Future.wait<Object>([
        _reader.readStatus(repository),
        _reader.readOperationState(repository),
      ]);
      if (!_isCurrentRepositoryRequest(repository, repositoryGeneration)) {
        return;
      }
      final refreshedStatus = results[0] as GitStatusSnapshot;
      final refreshedOperationState = results[1] as GitRepositoryOperationState;
      // A directory watch also observes ignored build output and editor
      // metadata. Git remains the source of truth, but when it confirms that
      // neither the work-tree snapshot nor operation state changed, avoid
      // publishing a replacement session and rebuilding the workspace.
      // A selected file is intentionally excluded: its contents may have
      // changed while porcelain status remains `M`, so its Diff must reload.
      if (previousSelection == null &&
          _sameGitStatusSnapshot(_sessionState.status, refreshedStatus)) {
        if (_sessionState.operationState != refreshedOperationState) {
          _sessionState = _sessionState.copyWith(
            operationState: refreshedOperationState,
          );
        }
        return;
      }

      // Automatic refresh is intentionally silent.  The generic mutation
      // finisher clears the current selection and Diff before reading them
      // again, which makes the commit-change and Diff panes flash empty on
      // every editor save.  Read the replacement Diff first and publish one
      // atomic state update instead.
      if (previousRefId != 'workspace' && previousRefId != 'uncommitted') {
        _sessionState = _sessionState.copyWith(
          phase: RepositorySessionPhase.ready,
          status: refreshedStatus,
          operationState: refreshedOperationState,
        );
        return;
      }

      if (previousRefId == 'uncommitted' && refreshedStatus.isClean) {
        final refreshed = await _finishWorkingTreeMutation(
          repository: repository,
          repositoryGeneration: repositoryGeneration,
          previousSelection: previousSelection,
          previousRefId: previousRefId,
          validatedStatus: refreshedStatus,
        );
        if (refreshed &&
            _isCurrentRepositoryRequest(repository, repositoryGeneration)) {
          _sessionState = _sessionState.copyWith(
            operationState: refreshedOperationState,
          );
        }
        return;
      }

      RepositoryChangeViewData? nextChange;
      SelectedRepositoryChange? nextSelection;
      GitUnifiedDiff? nextDiff;
      if (previousSelection != null) {
        final entry = refreshedStatus.entries
            .where(
              (candidate) =>
                  candidate.path.display ==
                  previousSelection.entry.path.display,
            )
            .firstOrNull;
        if (entry != null && entry.path.isValidUtf8) {
          nextChange = _changeAfterStageToggle(
            entry,
            isStaged: previousSelection.isStaged,
          );
          nextChange ??= _changeAfterStageToggle(
            entry,
            isStaged: !previousSelection.isStaged,
          );
          if (nextChange != null) {
            nextSelection = SelectedRepositoryChange(
              entry: entry,
              source: nextChange.isStaged
                  ? GitDiffSource.staged
                  : GitDiffSource.workingTree,
              kind: nextChange.kind,
            );
            nextDiff = nextChange.kind == RepositoryChangeKind.untracked
                ? await _reader.readUntrackedFileDiff(
                    repository,
                    path: entry.path.display,
                  )
                : await _reader.readUnifiedDiff(
                    repository,
                    path: entry.path.display,
                    source: nextSelection.source,
                  );
          }
        }
      }
      if (!_isCurrentRepositoryRequest(repository, repositoryGeneration)) {
        return;
      }
      // A user may have changed the working-tree selection while the
      // replacement Diff was being read. Do not let this older refresh win
      // over the newer interaction.
      if (_sessionState.selectedRefId != previousRefId ||
          !identical(_sessionState.selectedChange, previousSelection)) {
        _sessionState = _sessionState.copyWith(
          phase: RepositorySessionPhase.ready,
          status: refreshedStatus,
          operationState: refreshedOperationState,
        );
        return;
      }
      _sessionState = _sessionState.copyWith(
        phase: RepositorySessionPhase.ready,
        status: refreshedStatus,
        operationState: refreshedOperationState,
        selectedRefId: previousRefId,
        selectedChange: nextSelection,
        diff: nextDiff,
        isDiffLoading: false,
        clearSelectedChange: nextSelection == null,
        clearDiff: nextDiff == null,
      );
      return;
    } on Object catch (error, stackTrace) {
      if (!_isCurrentRepositoryRequest(repository, repositoryGeneration)) {
        return;
      }
      _sessionState = _sessionState.copyWith(
        message: '自动刷新失败；当前内容已保留，可使用刷新按钮重试。',
        technicalDetails: _technicalDetails(error, stackTrace),
      );
    }
  }

  /// Compares every status field that can affect repository presentation.
  ///
  /// 中文：比较所有会影响仓库呈现的状态字段；自动刷新在无文件选择时用它抑制
  /// 忽略文件等无效事件产生的重复 session 发布。
  bool _sameGitStatusSnapshot(
    GitStatusSnapshot? current,
    GitStatusSnapshot refreshed,
  ) {
    if (current == null ||
        !_sameGitBranchStatus(current.branch, refreshed.branch) ||
        !_sameGitStatusEntries(current.entries, refreshed.entries) ||
        !_sameGitStatusEntries(
          current.displayEntries,
          refreshed.displayEntries,
        ) ||
        current.additionalHeaders.length !=
            refreshed.additionalHeaders.length) {
      return false;
    }
    for (final entry in current.additionalHeaders.entries) {
      if (refreshed.additionalHeaders[entry.key] != entry.value) return false;
    }
    return true;
  }

  bool _sameGitBranchStatus(GitBranchStatus first, GitBranchStatus second) =>
      first.objectId == second.objectId &&
      first.head == second.head &&
      first.upstream == second.upstream &&
      first.ahead == second.ahead &&
      first.behind == second.behind &&
      first.isUpstreamGone == second.isUpstreamGone &&
      first.stashCount == second.stashCount &&
      first.isDetached == second.isDetached &&
      first.isUnborn == second.isUnborn;

  bool _sameGitStatusEntries(
    List<GitStatusEntry> first,
    List<GitStatusEntry> second,
  ) {
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      if (!_sameGitStatusEntry(first[index], second[index])) return false;
    }
    return true;
  }

  bool _sameGitStatusEntry(GitStatusEntry first, GitStatusEntry second) =>
      first.kind == second.kind &&
      first.path == second.path &&
      first.originalPath == second.originalPath &&
      first.indexStatus == second.indexStatus &&
      first.workTreeStatus == second.workTreeStatus &&
      _sameGitSubmoduleStatus(first.submodule, second.submodule) &&
      first.renameOrCopyScore == second.renameOrCopyScore &&
      first.headMode == second.headMode &&
      first.indexMode == second.indexMode &&
      first.workTreeMode == second.workTreeMode &&
      first.headObjectId == second.headObjectId &&
      first.indexObjectId == second.indexObjectId &&
      first.stage1Mode == second.stage1Mode &&
      first.stage2Mode == second.stage2Mode &&
      first.stage3Mode == second.stage3Mode &&
      first.stage1ObjectId == second.stage1ObjectId &&
      first.stage2ObjectId == second.stage2ObjectId &&
      first.stage3ObjectId == second.stage3ObjectId;

  bool _sameGitSubmoduleStatus(
    GitSubmoduleStatus? first,
    GitSubmoduleStatus? second,
  ) =>
      first?.raw == second?.raw &&
      first?.isSubmodule == second?.isSubmodule &&
      first?.commitChanged == second?.commitChanged &&
      first?.hasTrackedChanges == second?.hasTrackedChanges &&
      first?.hasUntrackedChanges == second?.hasUntrackedChanges;
}
