import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path_utils;

import '../git/git.dart';
import '../presentation/presentation.dart';
import 'git_askpass_prompt_coordinator.dart';
import 'git_sensitive_text_redactor.dart';
import 'external_tool_runner.dart';
import 'external_tool_configuration.dart';
import 'external_tool_configuration_store.dart';
import 'repository_trust.dart';
import 'git_flow_semantics.dart';
import 'repository_change_monitor.dart';

part 'repository_session_models.dart';
part 'repository_session_refresh.dart';
part 'repository_session_tasks.dart';
part 'repository_session_working_tree_writes.dart';
part 'repository_session_commit_writes.dart';
part 'repository_session_stash_writes.dart';
part 'repository_session_ref_writes.dart';
part 'repository_session_conflict_writes.dart';
part 'repository_session_tag_writes.dart';
part 'repository_session_tag_batch_writes.dart';
part 'repository_session_git_flow_writes.dart';
part 'repository_session_branch_writes.dart';
part 'repository_session_remote_writes.dart';
part 'repository_session_worktree_writes.dart';
part 'repository_session_worktree_helper.dart';
part 'repository_session_history_writes.dart';

/// Provides the Git runner used by repository-workspace providers.
///
/// 中文：提供仓库工作区各 provider 共用的 Git runner；具体的读取、写入、刷新和
/// 生命周期协调由对应的仓库会话 controller 负责。

final gitRunnerProvider = Provider<GitRunner>((Ref ref) => GitRunner());

final gitRepositoryInspectorProvider = Provider<GitRepositoryInspector>(
  (Ref ref) => GitRepositoryInspector(ref.watch(gitRunnerProvider)),
);

final gitRepositoryReaderProvider = Provider<GitRepositoryReader>(
  (Ref ref) => GitRepositoryReader(ref.watch(gitRunnerProvider)),
);

final gitRepositoryWriterProvider = Provider<GitRepositoryWriter>(
  (Ref ref) => GitRepositoryWriter(ref.watch(gitRunnerProvider)),
);

final repositoryChangeMonitorProvider = Provider<RepositoryChangeMonitor>(
  (Ref ref) => RepositoryChangeMonitor(),
);

final repositorySessionProvider =
    NotifierProvider<RepositorySessionController, RepositorySessionState>(
      RepositorySessionController.new,
    );

/// Optional test-only hook that can make the next explicit refresh fail.
/// 中文：仅供测试覆盖“写入成功但刷新失败”边界的可选钩子。
final repositoryRefreshHookForTestingProvider =
    Provider<Future<void> Function()?>((Ref ref) => null);

final class RepositorySessionController
    extends Notifier<RepositorySessionState> {
  static const int _historyPageSize = 100;
  static const int _historyPageReadLimit = _historyPageSize + 1;
  static const Duration _automaticRefreshCooldown = Duration(seconds: 1);

  late GitRunner _runner;
  late GitRepositoryInspector _inspector;
  late GitRepositoryReader _reader;
  late GitRepositoryWriter _writer;
  late RepositoryChangeMonitor _changeMonitor;
  late ExternalToolRunner _externalToolRunner;
  Future<void> Function()? _refreshHookForTesting;
  int _repositoryGeneration = 0;
  int _historyGeneration = 0;
  int _diffGeneration = 0;
  int _commitGeneration = 0;
  int _commitDiffGeneration = 0;
  int _operationSequence = 0;
  final _taskTracker = _RepositoryTaskTracker();
  var _fetchPreflightInProgress = false;
  var _pushPreflightInProgress = false;
  var _pullPreflightInProgress = false;
  var _remoteConfigurationPreflightInProgress = false;
  var _automaticRefreshEnabled = false;
  var _automaticRefreshInProgress = false;
  var _automaticRefreshPending = false;
  var _automaticRefreshNeedsMetadata = false;
  var _automaticRefreshRequestVersion = 0;
  var _isDisposed = false;
  DateTime? _lastAutomaticRefreshCompletedAt;

  /// Provides the private state boundary used by the refresh part.
  ///
  /// 中文：为刷新拆分文件提供同一 Controller 的状态读写边界，不改变 Riverpod
  /// 状态所有权或对外接口。
  RepositorySessionState get _sessionState => state;
  set _sessionState(RepositorySessionState value) => state = value;

  /// Provides the Riverpod ref to same-library operation parts.
  /// 中文：为同库操作拆分文件提供 Riverpod ref，避免扩展直接触碰受保护成员。
  Ref get _providerRef => ref;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  RepositorySessionState build() {
    _runner = ref.watch(gitRunnerProvider);
    _inspector = ref.watch(gitRepositoryInspectorProvider);
    _reader = ref.watch(gitRepositoryReaderProvider);
    _writer = ref.watch(gitRepositoryWriterProvider);
    _changeMonitor = ref.watch(repositoryChangeMonitorProvider);
    _externalToolRunner = ref.watch(externalToolRunnerProvider);
    _refreshHookForTesting = ref.watch(repositoryRefreshHookForTestingProvider);
    ref.onDispose(() {
      _isDisposed = true;
      _cancelActiveGitOperations();
      unawaited(_changeMonitor.stop());
    });
    return const RepositorySessionState.empty();
  }

  /// 中文：取消当前 Engine 的 Git 操作，并短暂等待 Git 与 AskPass 释放原生资源。
  ///
  /// English: Cancels Engine-owned Git operations and waits briefly for
  /// their Git processes and AskPass sessions to release native resources.
  Future<void> prepareForShutdown({
    Duration timeout = const Duration(seconds: 2),
  }) => _prepareForShutdown(timeout: timeout);

  /// Reads details for the active repository without changing the
  /// workspace-wide loading or error state.
  ///
  /// 中文：读取当前仓库的详情统计，不改变工作区的加载或错误状态；新的读取会
  /// 取消旧请求，仓库切换后旧结果会失效。
  Future<GitRepositoryDetails> readRepositoryDetails() async {
    if (!_isInsideTrackedGitTask) {
      return _trackRequiredGitTask(readRepositoryDetails);
    }
    final repository = state.repository;
    if (repository == null) {
      throw const GitException('请先打开一个仓库。');
    }
    _repositoryDetailsCancellation?.cancel();
    final cancellation = GitCancellationToken();
    _repositoryDetailsCancellation = cancellation;
    final generation = _repositoryGeneration;
    try {
      final details = await _reader.readRepositoryDetails(
        repository,
        cancellationToken: cancellation,
      );
      if (cancellation.isCancelled ||
          generation != _repositoryGeneration ||
          !identical(state.repository, repository)) {
        throw const GitException('仓库详情读取已失效。');
      }
      return details;
    } finally {
      if (identical(_repositoryDetailsCancellation, cancellation)) {
        _repositoryDetailsCancellation = null;
      }
    }
  }

  /// 中文：取消仍在读取的仓库详情，供详情窗口关闭时释放文件遍历。
  /// English: Cancels an in-flight repository-details read when its window
  /// closes, releasing Git and file traversal work promptly.
  void cancelRepositoryDetailsRead() {
    _repositoryDetailsCancellation?.cancel();
  }

  /// 中文：启动当前流程。
  /// English: Starts the current flow.
  RepositoryOperationRecord _startOperation(RepositoryOperationKind kind) {
    final operation = RepositoryOperationRecord(
      id: 'operation-${++_operationSequence}',
      kind: kind,
      outcome: RepositoryOperationOutcome.running,
      startedAt: DateTime.now(),
    );
    state = state.copyWith(
      operations: List<RepositoryOperationRecord>.unmodifiable(
        [operation, ...state.operations].take(12),
      ),
    );
    return operation;
  }

  /// 中文：以完成时间更新指定操作记录，并在写入状态前脱敏其消息。
  ///
  /// English: Updates the specified operation with its completion time and
  /// redacts its message before storing it in state.
  void _completeOperation(
    RepositoryOperationRecord operation, {
    required RepositoryOperationOutcome outcome,
    String? message,
  }) {
    state = state.copyWith(
      operations: List<RepositoryOperationRecord>.unmodifiable([
        for (final existing in state.operations)
          if (existing.id == operation.id)
            existing.complete(
              outcome: outcome,
              completedAt: DateTime.now(),
              message: message == null ? null : _redactSensitiveText(message),
            )
          else
            existing,
      ]),
    );
  }

  /// 中文：将取消类 Git 错误标记为 `cancelled`，其他错误标记为 `failed`。
  ///
  /// English: Classifies cancellation-shaped Git errors as `cancelled` and all
  /// other errors as `failed`.
  RepositoryOperationOutcome _operationOutcomeForError(Object error) {
    return error is GitCancelledException ||
            (error is GitCommandException &&
                error.kind == GitErrorKind.cancelled)
        ? RepositoryOperationOutcome.cancelled
        : RepositoryOperationOutcome.failed;
  }

  /// Returns whether an asynchronous preflight still belongs to the active
  /// repository and may publish state after an await boundary.
  ///
  /// 中文：判断异步预检在跨越 await 后是否仍属于当前仓库并允许发布状态。
  bool _isCurrentRepositoryRequest(
    GitRepository repository,
    int repositoryGeneration,
  ) =>
      !_isShuttingDown &&
      !_isDisposed &&
      repositoryGeneration == _repositoryGeneration &&
      identical(state.repository, repository);

  /// 中文：打开目标仓库、读取初始状态和首屏历史，并自动选中最新提交。
  ///
  /// 输入为用户选择的仓库路径；成功后状态切换为 ready，最新提交的详情与首个
  /// 可预览文件差异会异步填充。内部刷新可要求保留“文件状态”或仍有效的
  /// `Uncommitted changes` 入口及文件选择；仓库切换、刷新或控制器销毁会使
  /// 过期读取失效。
  ///
  /// English: Opens a repository, loads its initial state and first history
  /// page, then selects the newest commit automatically.
  ///
  /// The input is a user-selected repository path. On success it moves the
  /// state to ready, then asynchronously fills the newest commit's details
  /// and first previewable file diff. Internal refreshes may preserve the File
  /// Status or still-valid Uncommitted Changes surface and file selection.
  /// Repository switches, refreshes and controller disposal invalidate stale
  /// reads.
  Future<void> openRepository(
    String path, {
    bool preserveWorkingTreeSurface = false,
  }) async {
    await _trackGitTask<void>(
      () => _openRepository(
        path,
        preserveWorkingTreeSurface: preserveWorkingTreeSurface,
      ),
    );
  }

  /// 中文：执行已纳入关闭屏障的仓库打开与初始读取。
  /// English: Performs repository opening and initial reads inside the
  /// shutdown barrier.
  Future<void> _openRepository(
    String path, {
    required bool preserveWorkingTreeSurface,
  }) async {
    final normalizedPath = path.trim();
    if (normalizedPath.isEmpty) {
      return;
    }
    // A configured external Diff process owns snapshots for the previous
    // repository. Close it before publishing the new repository generation so
    // a GUI tool cannot retain stale paths across workspace switches.
    await _externalToolRunner.closeAll();
    final previousSelection = preserveWorkingTreeSurface
        ? state.selectedChange
        : null;
    final previousRefId = preserveWorkingTreeSurface
        ? state.selectedRefId
        : null;
    _historyQueryCancellation?.cancel();
    final generation = ++_repositoryGeneration;
    _historyGeneration++;
    _diffGeneration++;
    _commitGeneration++;
    _commitDiffGeneration++;
    state = state.copyWith(
      phase: RepositorySessionPhase.loading,
      requestedPath: normalizedPath,
      isWorkingTreeBusy: false,
      isDiffLoading: false,
      isHistoryLoading: false,
      historyOffset: 0,
      historyRevisionSnapshot: const [],
      hasMoreHistory: false,
      clearDiff: true,
      clearSelectedChange: !preserveWorkingTreeSurface,
      clearMessage: true,
      clearHistoryLoadError: true,
      hiddenChangeKeys: const {},
    );

    try {
      final repository = await _inspector.inspect(normalizedPath);
      if (repository == null) {
        throw const GitException('所选目录不在 Git 仓库中。');
      }

      await _startRepositoryMonitor(repository, generation);
      final refreshCoveredVersion = _automaticRefreshRequestVersion;

      final historyRevisionSnapshot = await _reader.readHistoryRevisionSnapshot(
        repository,
      );
      if (generation != _repositoryGeneration) return;

      GitHistoryQuery? historyQuery;
      try {
        final parsed = GitHistoryQuery.tryParse(state.searchQuery);
        historyQuery = parsed?.isStructured == true ? parsed : null;
      } on GitException {
        historyQuery = null;
      }

      final results = await Future.wait<Object?>([
        _reader.readStatus(repository),
        _reader.readRemoteUrl(repository),
        _reader.readOperationState(repository),
        _reader.readLocalBranches(repository),
        _reader.readRemoteNames(repository),
        _reader.readRemoteBranches(repository),
        _reader.readTags(repository),
        _reader.readStashes(repository),
        _reader.readRecentHistory(
          repository,
          limit: _historyPageReadLimit,
          revisionSnapshot: historyRevisionSnapshot,
          query: historyQuery,
        ),
        _readGitVersion(),
      ]);
      if (generation != _repositoryGeneration) {
        return;
      }

      final status = results[0] as GitStatusSnapshot;
      final rawOriginUrl = results[1] as String?;
      final originUrl = rawOriginUrl == null
          ? null
          : _redactSensitiveText(rawOriginUrl);
      final hasOriginRemote = rawOriginUrl != null;
      final operationState = results[2] as GitRepositoryOperationState;
      final localBranches = results[3] as List<GitLocalBranch>;
      final remoteNames = results[4] as List<String>;
      final remoteBranches = results[5] as List<GitRemoteBranch>;
      final tags = results[6] as List<GitTag>;
      final stashes = results[7] as List<GitStashEntry>;
      final loadedHistory = results[8] as List<GitCommit>;
      final commits = loadedHistory.take(_historyPageSize).toList();
      final shouldRestoreWorkingTreeSurface =
          previousRefId == 'workspace' ||
          (previousRefId == 'uncommitted' && !status.isClean);
      state = RepositorySessionState(
        phase: RepositorySessionPhase.ready,
        requestedPath: normalizedPath,
        repository: repository,
        status: status,
        hasOriginRemote: hasOriginRemote,
        originUrl: originUrl,
        operationState: operationState,
        localBranches: localBranches,
        remoteNames: remoteNames,
        remoteBranches: remoteBranches,
        tags: tags,
        stashes: stashes,
        commits: commits,
        historyCommits: commits,
        historyRevisionSnapshot: historyRevisionSnapshot,
        historyOffset: commits.length,
        hasMoreHistory: loadedHistory.length > _historyPageSize,
        selectedRefId: shouldRestoreWorkingTreeSurface
            ? previousRefId!
            : 'history',
        // A repository with history opens on its newest commit. Selecting it
        // below replaces the working-tree inspector with that commit's file
        // list and first available Diff.
        selectedCommitId: null,
        hiddenChangeKeys: const {},
        operations: state.operations,
        gitVersion: results[9] as String,
        searchQuery: state.searchQuery,
      );
      if (_automaticRefreshEnabled &&
          refreshCoveredVersion == _automaticRefreshRequestVersion) {
        _automaticRefreshPending = false;
        _automaticRefreshNeedsMetadata = false;
      }
      if (shouldRestoreWorkingTreeSurface) {
        await _restoreWorkingTreeSelectionAfterRefresh(
          previousSelection: previousSelection,
          previousRefId: previousRefId!,
        );
      } else if (commits.isNotEmpty) {
        await selectCommit(commits.first.objectId);
      }
    } on Object catch (error, stackTrace) {
      if (generation != _repositoryGeneration) {
        return;
      }
      state = state.copyWith(
        phase: RepositorySessionPhase.error,
        isDiffLoading: false,
        message: _friendlyError(error),
        technicalDetails: _technicalDetails(error, stackTrace),
      );
    }
  }

  /// 中文：刷新当前数据。
  ///
  /// 刷新同一仓库时保留“文件状态”，以及仍有改动时的 `Uncommitted changes`
  /// 入口和有效文件选择；不会先发布默认历史提交再切回工作区。
  ///
  /// English: Refreshes the current repository while preserving File Status,
  /// or a still-valid Uncommitted Changes surface and file selection, without
  /// publishing the default history commit first.
  Future<void> refresh() async {
    if (_isShuttingDown || state.isWorkingTreeBusy) return;
    if (!await _runRefreshHookForTesting()) return;
    final path = state.requestedPath ?? state.repository?.commandDirectory;
    if (path != null) {
      await openRepository(path, preserveWorkingTreeSurface: true);
    }
  }

  /// Hides selected working-tree entries from this window session only.
  ///
  /// 中文：仅从当前窗口会话的文件状态视图中隐藏所选改动；不执行 Git、不修改
  /// index、工作树或忽略规则。仓库刷新或切换时隐藏状态会被清除。
  void hideChanges(Iterable<RepositoryChangeViewData> changes) {
    final selectedChanges = List<RepositoryChangeViewData>.of(changes);
    final keys = <String>{...state.hiddenChangeKeys};
    for (final change in selectedChanges) {
      keys.add(
        repositoryChangeViewKey(isStaged: change.isStaged, path: change.path),
      );
    }
    if (keys.length == state.hiddenChangeKeys.length &&
        keys.containsAll(state.hiddenChangeKeys)) {
      return;
    }
    _diffGeneration++;
    state = state.copyWith(
      hiddenChangeKeys: Set<String>.unmodifiable(keys),
      clearSelectedChange: selectedChanges.any(
        (change) => state.selectedChange?.matches(change) == true,
      ),
      clearDiff: selectedChanges.any(
        (change) => state.selectedChange?.matches(change) == true,
      ),
      isDiffLoading: false,
    );
  }

  /// Restores all session-local hidden working-tree entries.
  ///
  /// 中文：恢复当前窗口会话中所有被隐藏的文件状态条目；不读取或修改 Git。
  void clearHiddenChanges() {
    if (state.hiddenChangeKeys.isEmpty) return;
    state = state.copyWith(hiddenChangeKeys: const {});
  }

  /// Runs the optional refresh-failure seam and publishes its safe error state.
  /// 中文：运行可选的刷新失败测试钩子，并发布安全的刷新错误状态。
  Future<bool> _runRefreshHookForTesting() async {
    final refreshHook = _refreshHookForTesting;
    if (refreshHook == null) return true;
    try {
      await refreshHook();
      return true;
    } on Object catch (error, stackTrace) {
      state = state.copyWith(
        phase: RepositorySessionPhase.error,
        isWorkingTreeBusy: false,
        isDiffLoading: false,
        message: '写入已完成，但刷新仓库状态失败；请手动刷新确认。',
        technicalDetails: _technicalDetails(error, stackTrace),
      );
      return false;
    }
  }

  /// 中文：继续读取下一页提交历史，并安全追加到当前提交图。
  ///
  /// English: Reads and appends the next history page without replacing the
  /// current graph, ignoring results that belong to an old repository view.
  Future<void> loadMoreHistory() async {
    if (!_isInsideTrackedGitTask) {
      return _trackVoidGitTask(loadMoreHistory);
    }
    final repository = state.repository;
    if (repository == null || state.isHistoryLoading || !state.hasMoreHistory) {
      return;
    }

    final existingCommits = state.historyCommits;
    final historyRevisionSnapshot = state.historyRevisionSnapshot;
    final historyOffset = state.historyOffset;
    GitHistoryQuery? historyQuery;
    try {
      final parsed = GitHistoryQuery.tryParse(state.searchQuery);
      historyQuery = parsed?.isStructured == true ? parsed : null;
    } on GitException catch (error) {
      state = state.copyWith(historyLoadError: error.message);
      return;
    }
    final generation = ++_historyGeneration;
    _historyQueryCancellation?.cancel();
    final cancellation = GitCancellationToken();
    _historyQueryCancellation = cancellation;
    state = state.copyWith(
      commits: existingCommits,
      historyCommits: existingCommits,
      isHistoryLoading: true,
      clearHistoryLoadError: true,
    );

    try {
      final loadedHistory = await _reader.readRecentHistory(
        repository,
        limit: _historyPageReadLimit,
        offset: historyOffset,
        revisionSnapshot: historyRevisionSnapshot,
        query: historyQuery,
        cancellationToken: cancellation,
      );
      if (!ref.mounted ||
          generation != _historyGeneration ||
          state.repository?.id != repository.id) {
        return;
      }

      final existingObjectIds = existingCommits
          .map((commit) => commit.objectId)
          .toSet();
      final nextCommits = loadedHistory
          .take(_historyPageSize)
          .where((commit) => existingObjectIds.add(commit.objectId))
          .toList();
      final mergedHistory = List<GitCommit>.unmodifiable([
        ...existingCommits,
        ...nextCommits,
      ]);
      state = state.copyWith(
        commits: mergedHistory,
        historyCommits: mergedHistory,
        historyOffset:
            historyOffset +
            (loadedHistory.length < _historyPageSize
                ? loadedHistory.length
                : _historyPageSize),
        hasMoreHistory:
            loadedHistory.length > _historyPageSize && nextCommits.isNotEmpty,
        isHistoryLoading: false,
        clearHistoryLoadError: true,
      );
    } on GitCancelledException {
      // A newer query or shutdown owns the visible state.
    } on Object catch (error) {
      if (!ref.mounted ||
          cancellation.isCancelled ||
          generation != _historyGeneration) {
        return;
      }
      state = state.copyWith(
        isHistoryLoading: false,
        historyLoadError: _friendlyError(error),
      );
    } finally {
      if (identical(_historyQueryCancellation, cancellation)) {
        _historyQueryCancellation = null;
      }
    }
  }

  /// 中文：浏览左侧引用；选择分支会定位到分支尖端并加载该提交的文件改动，
  /// “文件状态”会打开完整工作区，“历史”会恢复提交图。该操作不会切换当前检出的分支。
  ///
  /// English: Browses a sidebar ref. Branches focus their tip commit and load
  /// its changed files, while File Status opens the full workspace and History
  /// restores the commit graph. This never checks out a branch.
  Future<void> selectReference(RepositoryRefViewData reference) async {
    if (!_isInsideTrackedGitTask) {
      return _trackVoidGitTask(() => selectReference(reference));
    }
    if (state.repository == null) return;
    if (reference.kind == RepositoryRefKind.workspace) {
      _commitGeneration++;
      _commitDiffGeneration++;
      state = state.copyWith(
        selectedRefId: reference.id == 'workspace' ? 'workspace' : 'history',
        commits: _commitsWithoutStashPreviews(),
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
      return;
    }

    if (reference.kind == RepositoryRefKind.remote) {
      state = state.copyWith(selectedRefId: reference.id, clearMessage: true);
      return;
    }

    if (reference.kind == RepositoryRefKind.stash) {
      final previewFreeCommits = _commitsWithoutStashPreviews();
      if (reference.stashReference == null) {
        _commitGeneration++;
        _commitDiffGeneration++;
        state = state.copyWith(
          selectedRefId: reference.id,
          commits: previewFreeCommits,
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
        return;
      }
      state = state.copyWith(
        selectedRefId: reference.id,
        commits: previewFreeCommits,
      );
      final stashObjectId = state.stashes
          .where((stash) => stash.reference == reference.stashReference)
          .map((stash) => stash.objectId)
          .firstOrNull;
      if (stashObjectId != null) {
        await selectCommit(stashObjectId);
      }
      return;
    }

    String? objectId;
    String? selectedRefId;
    if (reference.id == 'HEAD' && state.status?.branch.isDetached == true) {
      objectId = state.status?.branch.objectId;
      selectedRefId = 'HEAD';
    } else if (reference.kind == RepositoryRefKind.localBranch) {
      for (final branch in state.localBranches) {
        if (branch.name == reference.label) {
          objectId = branch.objectId;
          selectedRefId = 'refs/heads/${branch.name}';
          break;
        }
      }
    } else if (reference.kind == RepositoryRefKind.remoteBranch) {
      for (final branch in state.remoteBranches) {
        if (branch.name == reference.label) {
          objectId = branch.objectId;
          selectedRefId = 'refs/remotes/${branch.name}';
          break;
        }
      }
    } else if (reference.kind == RepositoryRefKind.tag) {
      for (final tag in state.tags) {
        if (tag.name == reference.label) {
          if (!tag.hasCommitTarget) {
            _commitGeneration++;
            _commitDiffGeneration++;
            state = state.copyWith(
              selectedRefId: 'refs/tags/${tag.name}',
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
            return;
          }
          objectId = tag.targetObjectId;
          selectedRefId = 'refs/tags/${tag.name}';
          break;
        }
      }
    }
    if (objectId == null || selectedRefId == null) return;

    state = state.copyWith(
      selectedRefId: selectedRefId,
      commits: _commitsWithoutStashPreviews(),
    );
    await selectCommit(objectId);
  }

  /// 中文：选中历史图顶部的未提交改动，并清除提交详情以显示工作区改动。
  ///
  /// English: Selects the history graph's uncommitted row and clears commit
  /// details so the lower pane displays working-tree changes.
  void selectUncommittedChanges() {
    if (state.repository == null) return;
    _commitGeneration++;
    _commitDiffGeneration++;
    state = state.copyWith(
      selectedRefId: 'uncommitted',
      commits: _commitsWithoutStashPreviews(),
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
  }

  /// 中文：选中指定提交，读取其文件摘要，并自动预览首个可安全显示的文件。
  ///
  /// 输入为已加载或可按对象 ID 读取的提交；读取期间更新提交详情加载状态。仓库切换、
  /// 其他提交选择或控制器销毁会使该次异步读取失效。
  ///
  /// English: Selects a commit, reads its file summary, and automatically
  /// previews the first safely displayable file.
  ///
  /// The input may be a loaded commit or an object ID that can be read. It
  /// updates commit-detail loading state, while repository switches, another
  /// commit selection, or controller disposal invalidate the async read.
  Future<void> selectCommit(String objectId) async {
    if (!_isInsideTrackedGitTask) {
      return _trackVoidGitTask(() => selectCommit(objectId));
    }
    final repository = state.repository;
    if (repository == null) return;
    final generation = ++_commitGeneration;
    _commitDiffGeneration++;
    state = state.copyWith(
      selectedRefId: state.selectedRefId == 'uncommitted' ? 'history' : null,
      selectedCommitId: objectId,
      commitChanges: const [],
      commitAdditions: 0,
      commitDeletions: 0,
      isCommitLoading: true,
      isCommitDiffLoading: false,
      clearSelectedCommitFile: true,
      clearCommitDiff: true,
      clearMessage: true,
    );
    try {
      var selectedCommit = state.commits
          .where((commit) => commit.objectId == objectId)
          .firstOrNull;
      if (selectedCommit == null) {
        selectedCommit = await _reader.readCommit(
          repository,
          objectId: objectId,
        );
        if (!ref.mounted ||
            generation != _commitGeneration ||
            state.repository?.id != repository.id ||
            state.selectedCommitId != objectId) {
          return;
        }
        if (selectedCommit == null) {
          throw GitException('找不到提交 $objectId。');
        }
        state = state.copyWith(commits: [selectedCommit, ...state.commits]);
      }
      final parentObjectId = selectedCommit.parentIds.firstOrNull;
      final summary = await _reader.readCommitChanges(
        repository,
        objectId: objectId,
        parentObjectId: parentObjectId,
      );
      if (!ref.mounted ||
          generation != _commitGeneration ||
          state.repository?.id != repository.id ||
          state.selectedCommitId != objectId) {
        return;
      }
      state = state.copyWith(
        commitChanges: summary.files,
        commitAdditions: summary.additions,
        commitDeletions: summary.deletions,
        isCommitLoading: false,
      );
      final firstPreviewableFile = firstPreviewableCommitFile(summary.files);
      if (firstPreviewableFile != null) {
        await selectCommitFileByPath(firstPreviewableFile.path.display);
      }
    } on Object catch (error, stackTrace) {
      if (!ref.mounted || generation != _commitGeneration) return;
      state = state.copyWith(
        isCommitLoading: false,
        message: _friendlyError(error),
        technicalDetails: _technicalDetails(error, stackTrace),
      );
    }
  }

  /// 中文：更新当前选择。
  /// English: Updates the current selection.
  Future<void> selectCommitFile(CommitFileViewData? change) async {
    await selectCommitFileByPath(change?.path);
  }

  /// 中文：更新当前选择。
  /// English: Updates the current selection.
  Future<void> selectCommitFileByPath(
    String? path, {
    GitDiffWhitespaceMode? whitespaceMode,
  }) async {
    if (!_isInsideTrackedGitTask) {
      return _trackVoidGitTask(
        () => selectCommitFileByPath(path, whitespaceMode: whitespaceMode),
      );
    }
    final selectedWhitespaceMode =
        whitespaceMode ?? state.commitDiffWhitespaceMode;
    final objectId = state.selectedCommitId;
    final repository = state.repository;
    if (path == null || objectId == null || repository == null) {
      _commitDiffGeneration++;
      state = state.copyWith(
        isCommitDiffLoading: false,
        commitDiffWhitespaceMode: selectedWhitespaceMode,
        clearSelectedCommitFile: true,
        clearCommitDiff: true,
      );
      return;
    }
    final file = state.commitChanges
        .where((candidate) => candidate.path.display == path)
        .firstOrNull;
    if (file == null || !file.path.isValidUtf8) return;
    final parentObjectId = _parentObjectId(objectId);
    final generation = ++_commitDiffGeneration;
    state = state.copyWith(
      selectedCommitFile: SelectedCommitFile(objectId: objectId, file: file),
      commitDiffWhitespaceMode: selectedWhitespaceMode,
      isCommitDiffLoading: true,
      clearCommitDiff: true,
      clearMessage: true,
    );
    try {
      final diff = await _reader.readCommitUnifiedDiff(
        repository,
        objectId: objectId,
        path: file.path.display,
        parentObjectId: parentObjectId,
        whitespaceMode: selectedWhitespaceMode,
      );
      if (!ref.mounted ||
          generation != _commitDiffGeneration ||
          state.repository?.id != repository.id ||
          state.selectedCommitId != objectId) {
        return;
      }
      state = state.copyWith(commitDiff: diff, isCommitDiffLoading: false);
    } on Object catch (error, stackTrace) {
      if (!ref.mounted || generation != _commitDiffGeneration) return;
      state = state.copyWith(
        isCommitDiffLoading: false,
        message: _friendlyError(error),
        technicalDetails: _technicalDetails(error, stackTrace),
      );
    }
  }

  /// Reads a read-only Diff for one working-tree review target after checking
  /// that the path still belongs to the selected staged or unstaged surface.
  /// The result is cancelled or rejected when the workspace changes.
  ///
  /// 中文：复核路径仍属于所选暂存或未暂存来源后，为工作区审查目标读取只读
  /// Diff；窗口关闭、取消或仓库切换后不会返回过期结果。
  Future<GitUnifiedDiff> readWorkingTreeReviewDiff(
    RepositoryChangeViewData change, {
    required GitCancellationToken cancellationToken,
  }) async {
    if (!_isInsideTrackedGitTask) {
      return _trackRequiredGitTask(
        () => readWorkingTreeReviewDiff(
          change,
          cancellationToken: cancellationToken,
        ),
      );
    }
    final repository = state.repository;
    if (repository == null || state.phase != RepositorySessionPhase.ready) {
      throw StateError('当前没有可审查的工作区。');
    }
    final repositoryGeneration = _repositoryGeneration;
    final status = await _reader.readStatus(
      repository,
      cancellationToken: cancellationToken,
    );
    if (cancellationToken.isCancelled) {
      throw const GitCancelledException();
    }
    if (!ref.mounted ||
        repositoryGeneration != _repositoryGeneration ||
        state.repository?.id != repository.id) {
      throw StateError('仓库已切换，无法继续审查。');
    }
    final entry = status.displayEntries
        .where((candidate) => candidate.path.display == change.path)
        .firstOrNull;
    final stillInSelectedSource = change.isStaged
        ? entry?.hasStagedChange == true
        : entry?.hasWorkTreeChange == true;
    if (entry == null ||
        !entry.path.isValidUtf8 ||
        !stillInSelectedSource ||
        (change.kind == RepositoryChangeKind.untracked) !=
            (entry.kind == GitFileStatusKind.untracked)) {
      throw StateError('所选文件状态已变化，无法继续审查。');
    }
    final diff = entry.kind == GitFileStatusKind.untracked
        ? await _reader.readUntrackedFileDiff(
            repository,
            path: entry.path.display,
            cancellationToken: cancellationToken,
          )
        : await _reader.readUnifiedDiff(
            repository,
            path: entry.path.display,
            source: change.isStaged
                ? GitDiffSource.staged
                : GitDiffSource.workingTree,
            cancellationToken: cancellationToken,
          );
    if (cancellationToken.isCancelled) {
      throw const GitCancelledException();
    }
    if (!ref.mounted ||
        repositoryGeneration != _repositoryGeneration ||
        state.repository?.id != repository.id) {
      throw StateError('仓库已切换，无法继续审查。');
    }
    return diff;
  }

  /// Reads a historical file Diff for the built-in review without changing
  /// the main workspace selection.
  ///
  /// 中文：为内置审查读取历史提交中的文件 Diff，不改变主工作区选择。
  Future<GitUnifiedDiff> readCommitReviewDiff(
    GitCommit commit, {
    required String path,
    required GitCancellationToken cancellationToken,
  }) async {
    if (!_isInsideTrackedGitTask) {
      return _trackRequiredGitTask(
        () => readCommitReviewDiff(
          commit,
          path: path,
          cancellationToken: cancellationToken,
        ),
      );
    }
    final repository = state.repository;
    if (repository == null || state.phase != RepositorySessionPhase.ready) {
      throw StateError('当前没有可审查的提交。');
    }
    final repositoryGeneration = _repositoryGeneration;
    final diff = await _reader.readCommitUnifiedDiff(
      repository,
      objectId: commit.objectId,
      parentObjectId: commit.parentIds.firstOrNull,
      path: path,
      cancellationToken: cancellationToken,
    );
    if (cancellationToken.isCancelled) {
      throw const GitCancelledException();
    }
    if (!ref.mounted ||
        repositoryGeneration != _repositoryGeneration ||
        state.repository?.id != repository.id) {
      throw StateError('仓库已切换，无法继续审查。');
    }
    return diff;
  }

  /// Reads the currently selected historical file as binary-safe bytes after
  /// validating the commit and file selection before and after the Git call.
  ///
  /// 中文：以二进制安全字节读取当前选择的历史文件，并在 Git 调用前后复核提交、
  /// 文件与仓库代际；删除记录没有该提交版本，因此会被拒绝。
  Future<Uint8List> readSelectedCommitFileBytes({
    int maxBytes = 16 * 1024 * 1024,
    GitCancellationToken? cancellationToken,
  }) async {
    if (!_isInsideTrackedGitTask) {
      return _trackRequiredGitTask(
        () => readSelectedCommitFileBytes(
          maxBytes: maxBytes,
          cancellationToken: cancellationToken,
        ),
      );
    }
    final repository = state.repository;
    final selected = state.selectedCommitFile;
    if (repository == null ||
        state.phase != RepositorySessionPhase.ready ||
        selected == null ||
        !selected.file.path.isValidUtf8 ||
        selected.file.kind == GitCommitChangeKind.deleted) {
      throw StateError('当前没有可打开的历史文件版本。');
    }
    final repositoryGeneration = _repositoryGeneration;
    final bytes = await _reader.readFileAtCommit(
      repository,
      objectId: selected.objectId,
      path: selected.file.path.display,
      maxBytes: maxBytes,
      cancellationToken: cancellationToken,
    );
    if (cancellationToken?.isCancelled ?? false) {
      throw const GitCancelledException();
    }
    final current = state.selectedCommitFile;
    if (!ref.mounted ||
        repositoryGeneration != _repositoryGeneration ||
        state.repository?.id != repository.id ||
        current?.objectId != selected.objectId ||
        current?.file.path != selected.file.path) {
      throw StateError('提交或文件选择已变化，无法打开历史版本。');
    }
    return bytes;
  }

  /// Reads the first-parent before/after blobs for the selected historical
  /// file, using empty content for the absent side of an add or delete.
  ///
  /// 中文：读取当前历史文件相对第一父提交的前后 blob；新增或删除缺失的一侧
  /// 使用空内容，并在读取完成后复核仓库、提交和文件选择。
  Future<HistoricalFileComparison> readSelectedCommitFileComparison({
    int maxBytesPerSide = 16 * 1024 * 1024,
    GitCancellationToken? cancellationToken,
  }) async {
    if (!_isInsideTrackedGitTask) {
      return _trackRequiredGitTask(
        () => readSelectedCommitFileComparison(
          maxBytesPerSide: maxBytesPerSide,
          cancellationToken: cancellationToken,
        ),
      );
    }
    final repository = state.repository;
    final selected = state.selectedCommitFile;
    final supported =
        selected != null &&
        switch (selected.file.kind) {
          GitCommitChangeKind.added ||
          GitCommitChangeKind.modified ||
          GitCommitChangeKind.deleted ||
          GitCommitChangeKind.renamed ||
          GitCommitChangeKind.copied => true,
          _ => false,
        };
    if (repository == null ||
        state.phase != RepositorySessionPhase.ready ||
        selected == null ||
        !selected.file.path.isValidUtf8 ||
        !(selected.file.previousPath?.isValidUtf8 ?? true) ||
        !supported) {
      throw StateError('当前没有可进行外部差异比对的历史文件。');
    }
    final repositoryGeneration = _repositoryGeneration;
    final parentObjectId = _parentObjectId(selected.objectId);
    final beforePath = selected.file.previousPath ?? selected.file.path;
    final beforeBytes =
        selected.file.kind == GitCommitChangeKind.added ||
            parentObjectId == null
        ? Uint8List(0)
        : await _reader.readFileAtCommit(
            repository,
            objectId: parentObjectId,
            path: beforePath.display,
            maxBytes: maxBytesPerSide,
            cancellationToken: cancellationToken,
          );
    final afterBytes = selected.file.kind == GitCommitChangeKind.deleted
        ? Uint8List(0)
        : await _reader.readFileAtCommit(
            repository,
            objectId: selected.objectId,
            path: selected.file.path.display,
            maxBytes: maxBytesPerSide,
            cancellationToken: cancellationToken,
          );
    if (cancellationToken?.isCancelled ?? false) {
      throw const GitCancelledException();
    }
    final current = state.selectedCommitFile;
    if (!ref.mounted ||
        repositoryGeneration != _repositoryGeneration ||
        state.repository?.id != repository.id ||
        current?.objectId != selected.objectId ||
        current?.file.path != selected.file.path) {
      throw StateError('提交或文件选择已变化，无法进行外部差异比对。');
    }
    return HistoricalFileComparison(
      beforeBytes: beforeBytes,
      afterBytes: afterBytes,
    );
  }

  /// Reads a focused, read-only history for a selected historical file.
  ///
  /// The result belongs to the repository that was active when the request
  /// began. If the workspace closes or opens another repository while Git is
  /// reading, this method rejects the stale result instead of letting a dialog
  /// render history from the previous workspace.
  ///
  /// 中文：读取历史提交中所选文件的聚焦只读历史。它沿用当前已加载的多分支
  /// 历史快照，并补入 [sourceCommitId] 以覆盖贮藏等临时预览；结果只属于请求
  /// 开始时的仓库，若读取期间工作区关闭或切换了仓库，会拒绝过期结果。
  Future<List<GitFileHistoryEntry>> readFileHistory(
    String path, {
    String? sourceCommitId,
    required GitCancellationToken cancellationToken,
  }) async {
    if (!_isInsideTrackedGitTask) {
      return _trackRequiredGitTask(
        () => readFileHistory(
          path,
          sourceCommitId: sourceCommitId,
          cancellationToken: cancellationToken,
        ),
      );
    }
    final repository = state.repository;
    if (repository == null || state.phase != RepositorySessionPhase.ready) {
      throw StateError('当前没有可读取文件历史的仓库。');
    }
    final revisions = <String>{
      ...state.historyRevisionSnapshot,
      ?sourceCommitId,
    };
    final history = await _reader.readFileHistory(
      repository,
      path: path,
      revisionSnapshot: revisions.isEmpty ? null : revisions.toList(),
      cancellationToken: cancellationToken,
    );
    if (cancellationToken.isCancelled) {
      throw const GitCancelledException();
    }
    if (!ref.mounted || state.repository?.id != repository.id) {
      throw StateError('仓库已切换，无法继续读取文件历史。');
    }
    return history;
  }

  /// Reads line ownership for one current tracked file without changing the
  /// selected commit or working-tree state.
  ///
  /// 中文：读取当前已跟踪文件的逐行 Blame，不改变提交选择或工作区状态；仓库
  /// 切换和关闭会使过期结果失效。
  Future<List<GitBlameLine>> readBlame(
    String path, {
    required GitCancellationToken cancellationToken,
  }) async {
    if (!_isInsideTrackedGitTask) {
      return _trackRequiredGitTask(
        () => readBlame(path, cancellationToken: cancellationToken),
      );
    }
    final repository = state.repository;
    if (repository == null || state.phase != RepositorySessionPhase.ready) {
      throw StateError('当前没有可读取 Blame 的仓库。');
    }
    final blame = await _reader.readBlame(
      repository,
      path: path,
      cancellationToken: cancellationToken,
    );
    if (cancellationToken.isCancelled) {
      throw const GitCancelledException();
    }
    if (!ref.mounted || state.repository?.id != repository.id) {
      throw StateError('仓库已切换，无法继续读取 Blame。');
    }
    return blame;
  }

  /// Reads the current repository reflog for a read-only history dialog.
  ///
  /// 中文：读取当前仓库的分支与 HEAD reflog，结果只用于只读历史窗口；如果
  /// 仓库在读取期间关闭或切换，会拒绝返回属于旧工作区的记录。
  Future<List<GitReflogEntry>> readReflog({
    required GitCancellationToken cancellationToken,
  }) async {
    if (!_isInsideTrackedGitTask) {
      return _trackRequiredGitTask(
        () => readReflog(cancellationToken: cancellationToken),
      );
    }
    final repository = state.repository;
    if (repository == null || state.phase != RepositorySessionPhase.ready) {
      throw StateError('当前没有可读取引用日志的仓库。');
    }
    final entries = await _reader.readReflog(
      repository,
      cancellationToken: cancellationToken,
    );
    if (cancellationToken.isCancelled) {
      throw const GitCancelledException();
    }
    if (!ref.mounted || state.repository?.id != repository.id) {
      throw StateError('仓库已切换，无法继续读取引用日志。');
    }
    return entries;
  }

  /// Verifies one loaded annotated tag and stores the Git-backed result.
  ///
  /// 中文：验证一个已加载标签的签名并写回会话状态；轻量标签会返回
  /// `notAnnotated`，仓库切换、关闭或取消会使结果失效。
  Future<GitTagSignatureStatus> verifyTagSignature(String tagName) async {
    if (!_isInsideTrackedGitTask) {
      return _trackRequiredGitTask(() => verifyTagSignature(tagName));
    }
    final repository = state.repository;
    final tag = state.tags.where((item) => item.name == tagName).firstOrNull;
    if (repository == null ||
        tag == null ||
        state.phase != RepositorySessionPhase.ready) {
      throw StateError('当前没有可验证的标签。');
    }
    _tagInspectionCancellation?.cancel();
    final cancellation = GitCancellationToken();
    _tagInspectionCancellation = cancellation;
    state = state.copyWith(isTagInspectionRunning: true, clearMessage: true);
    final generation = _repositoryGeneration;
    try {
      final result = await _reader.readTagSignature(
        repository,
        tag,
        cancellationToken: cancellation,
      );
      if (cancellation.isCancelled ||
          !ref.mounted ||
          generation != _repositoryGeneration ||
          state.repository?.id != repository.id) {
        throw const GitCancelledException();
      }
      state = state.copyWith(
        tags: [
          for (final current in state.tags)
            current.name == tag.name
                ? current.copyWith(signatureStatus: result)
                : current,
        ],
        clearMessage: true,
      );
      return result;
    } finally {
      if (identical(_tagInspectionCancellation, cancellation)) {
        _tagInspectionCancellation = null;
        if (ref.mounted) {
          state = state.copyWith(isTagInspectionRunning: false);
        }
      }
    }
  }

  /// Verifies every loaded tag in one cancellable Git task.
  ///
  /// 中文：在同一个可取消任务中验证全部已加载标签；每个标签的结果会原子写回
  /// 会话状态，仓库切换或关闭会使整批结果失效。
  Future<Map<String, GitTagSignatureStatus>> verifyAllTagSignatures() async {
    if (!_isInsideTrackedGitTask) {
      return _trackRequiredGitTask(verifyAllTagSignatures);
    }
    final repository = state.repository;
    if (repository == null || state.phase != RepositorySessionPhase.ready) {
      throw StateError('当前没有可验证的标签。');
    }
    _tagInspectionCancellation?.cancel();
    final cancellation = GitCancellationToken();
    _tagInspectionCancellation = cancellation;
    state = state.copyWith(isTagInspectionRunning: true, clearMessage: true);
    final generation = _repositoryGeneration;
    try {
      final results = <String, GitTagSignatureStatus>{};
      for (final tag in state.tags) {
        final result = await _reader.readTagSignature(
          repository,
          tag,
          cancellationToken: cancellation,
        );
        if (cancellation.isCancelled) throw const GitCancelledException();
        results[tag.name] = result;
      }
      if (!ref.mounted ||
          generation != _repositoryGeneration ||
          state.repository?.id != repository.id) {
        throw const GitCancelledException();
      }
      state = state.copyWith(
        tags: [
          for (final tag in state.tags)
            tag.copyWith(signatureStatus: results[tag.name]),
        ],
        clearMessage: true,
      );
      return Map<String, GitTagSignatureStatus>.unmodifiable(results);
    } finally {
      if (identical(_tagInspectionCancellation, cancellation)) {
        _tagInspectionCancellation = null;
        if (ref.mounted) {
          state = state.copyWith(isTagInspectionRunning: false);
        }
      }
    }
  }

  /// Reads one configured remote's tags and compares a local tag without
  /// updating tracking refs or performing a fetch.
  ///
  /// 中文：只读检查本地标签与指定远端标签引用是否一致，不执行 Fetch，也不修改
  /// 本地远端跟踪引用；结果会写回会话状态。
  Future<GitTagRemoteStatus> readRemoteTagStatus(
    String tagName, {
    required String remoteName,
  }) async {
    if (!_isInsideTrackedGitTask) {
      return _trackRequiredGitTask(
        () => readRemoteTagStatus(tagName, remoteName: remoteName),
      );
    }
    final repository = state.repository;
    final tag = state.tags.where((item) => item.name == tagName).firstOrNull;
    final normalizedRemote = remoteName.trim();
    if (repository == null ||
        tag == null ||
        !state.remoteNames.contains(normalizedRemote) ||
        state.phase != RepositorySessionPhase.ready) {
      throw StateError('当前没有可检查的标签或远端。');
    }
    _tagInspectionCancellation?.cancel();
    final cancellation = GitCancellationToken();
    _tagInspectionCancellation = cancellation;
    state = state.copyWith(isTagInspectionRunning: true, clearMessage: true);
    final generation = _repositoryGeneration;
    try {
      final remoteTags = await _reader.readRemoteTags(
        repository,
        remoteName: normalizedRemote,
        cancellationToken: cancellation,
      );
      final remote = remoteTags
          .where((item) => item.name == tag.name)
          .firstOrNull;
      final result = compareGitTagWithRemote(tag, remote);
      if (cancellation.isCancelled ||
          !ref.mounted ||
          generation != _repositoryGeneration ||
          state.repository?.id != repository.id) {
        throw const GitCancelledException();
      }
      state = state.copyWith(
        tagRemoteStatuses: {...state.tagRemoteStatuses, tag.name: result},
        tagRemoteNames: {...state.tagRemoteNames, tag.name: normalizedRemote},
        clearMessage: true,
      );
      return result;
    } finally {
      if (identical(_tagInspectionCancellation, cancellation)) {
        _tagInspectionCancellation = null;
        if (ref.mounted) {
          state = state.copyWith(isTagInspectionRunning: false);
        }
      }
    }
  }

  /// Reads the current tag names advertised by one configured remote.
  ///
  /// 中文：读取指定远端当前公开的标签名称，供远端标签写操作在选择与执行前
  /// 重新校验；不更新本地跟踪引用，也不修改会话中的本地标签集合。
  Future<List<String>> readRemoteTagNames({required String remoteName}) async {
    if (!_isInsideTrackedGitTask) {
      return _trackRequiredGitTask(
        () => readRemoteTagNames(remoteName: remoteName),
      );
    }
    final repository = state.repository;
    final normalizedRemote = remoteName.trim();
    if (repository == null ||
        !state.remoteNames.contains(normalizedRemote) ||
        state.phase != RepositorySessionPhase.ready) {
      throw StateError('当前没有可读取标签的远端。');
    }
    _tagInspectionCancellation?.cancel();
    final cancellation = GitCancellationToken();
    _tagInspectionCancellation = cancellation;
    state = state.copyWith(isTagInspectionRunning: true, clearMessage: true);
    final generation = _repositoryGeneration;
    try {
      final tags = await _reader.readRemoteTags(
        repository,
        remoteName: normalizedRemote,
        cancellationToken: cancellation,
      );
      if (cancellation.isCancelled ||
          !ref.mounted ||
          generation != _repositoryGeneration ||
          state.repository?.id != repository.id) {
        throw const GitCancelledException();
      }
      return List<String>.unmodifiable(tags.map((tag) => tag.name));
    } finally {
      if (identical(_tagInspectionCancellation, cancellation)) {
        _tagInspectionCancellation = null;
        if (ref.mounted) {
          state = state.copyWith(isTagInspectionRunning: false);
        }
      }
    }
  }

  /// Compares every loaded local tag with one configured remote in one read.
  ///
  /// 中文：通过一次只读 `ls-remote` 检查全部本地标签与指定远端的状态，不执行
  /// Fetch，也不修改远端跟踪引用。
  Future<Map<String, GitTagRemoteStatus>> readAllRemoteTagStatuses({
    required String remoteName,
  }) async {
    if (!_isInsideTrackedGitTask) {
      return _trackRequiredGitTask(
        () => readAllRemoteTagStatuses(remoteName: remoteName),
      );
    }
    final repository = state.repository;
    final normalizedRemote = remoteName.trim();
    if (repository == null ||
        !state.remoteNames.contains(normalizedRemote) ||
        state.phase != RepositorySessionPhase.ready) {
      throw StateError('当前没有可检查的标签或远端。');
    }
    _tagInspectionCancellation?.cancel();
    final cancellation = GitCancellationToken();
    _tagInspectionCancellation = cancellation;
    state = state.copyWith(isTagInspectionRunning: true, clearMessage: true);
    final generation = _repositoryGeneration;
    try {
      final remoteTags = await _reader.readRemoteTags(
        repository,
        remoteName: normalizedRemote,
        cancellationToken: cancellation,
      );
      final byName = <String, GitRemoteTag>{
        for (final tag in remoteTags) tag.name: tag,
      };
      final results = <String, GitTagRemoteStatus>{};
      for (final tag in state.tags) {
        results[tag.name] = compareGitTagWithRemote(tag, byName[tag.name]);
      }
      if (cancellation.isCancelled ||
          !ref.mounted ||
          generation != _repositoryGeneration ||
          state.repository?.id != repository.id) {
        throw const GitCancelledException();
      }
      state = state.copyWith(
        tagRemoteStatuses: {...state.tagRemoteStatuses, ...results},
        tagRemoteNames: {
          ...state.tagRemoteNames,
          for (final name in results.keys) name: normalizedRemote,
        },
        clearMessage: true,
      );
      return Map<String, GitTagRemoteStatus>.unmodifiable(results);
    } finally {
      if (identical(_tagInspectionCancellation, cancellation)) {
        _tagInspectionCancellation = null;
        if (ref.mounted) {
          state = state.copyWith(isTagInspectionRunning: false);
        }
      }
    }
  }

  /// Cancels an in-flight tag signature or remote-status read.
  /// 中文：取消正在进行的标签签名或远端状态读取。
  void cancelTagInspection() => _tagInspectionCancellation?.cancel();

  /// Reads the changed-file summary for one entry in a focused file history.
  ///
  /// 中文：读取聚焦文件历史中某个提交的改动文件和行统计；仅执行只读 Git 查询，
  /// 且在仓库切换后拒绝过期结果。
  Future<GitCommitChangeSummary> readFileHistoryCommitChanges(
    GitCommit commit, {
    required GitCancellationToken cancellationToken,
  }) async {
    if (!_isInsideTrackedGitTask) {
      return _trackRequiredGitTask(
        () => readFileHistoryCommitChanges(
          commit,
          cancellationToken: cancellationToken,
        ),
      );
    }
    final repository = state.repository;
    if (repository == null || state.phase != RepositorySessionPhase.ready) {
      throw StateError('当前没有可读取提交改动的仓库。');
    }
    final summary = await _reader.readCommitChanges(
      repository,
      objectId: commit.objectId,
      parentObjectId: commit.parentIds.firstOrNull,
      cancellationToken: cancellationToken,
    );
    if (cancellationToken.isCancelled) {
      throw const GitCancelledException();
    }
    if (!ref.mounted || state.repository?.id != repository.id) {
      throw StateError('仓库已切换，无法继续读取提交改动。');
    }
    return summary;
  }

  /// Reads the selected file's unified diff for one focused-history commit.
  ///
  /// 中文：读取聚焦文件历史中指定提交和文件的 Unified Diff；不写入 Git，仓库
  /// 切换后不会返回可能过期的 Diff。
  Future<GitUnifiedDiff> readFileHistoryCommitDiff(
    GitCommit commit, {
    required String path,
    required GitCancellationToken cancellationToken,
  }) async {
    if (!_isInsideTrackedGitTask) {
      return _trackRequiredGitTask(
        () => readFileHistoryCommitDiff(
          commit,
          path: path,
          cancellationToken: cancellationToken,
        ),
      );
    }
    final repository = state.repository;
    if (repository == null || state.phase != RepositorySessionPhase.ready) {
      throw StateError('当前没有可读取提交差异的仓库。');
    }
    final diff = await _reader.readCommitUnifiedDiff(
      repository,
      objectId: commit.objectId,
      parentObjectId: commit.parentIds.firstOrNull,
      path: path,
      cancellationToken: cancellationToken,
    );
    if (cancellationToken.isCancelled) {
      throw const GitCancelledException();
    }
    if (!ref.mounted || state.repository?.id != repository.id) {
      throw StateError('仓库已切换，无法继续读取提交差异。');
    }
    return diff;
  }

  /// 中文：更新提交历史查询。普通文本继续筛选已加载提交；作者、提交者、路径或
  /// 时间字段会取消旧查询，并从固定引用快照重新执行真实 Git 分页读取。
  ///
  /// English: Updates the commit-history query. Plain text keeps filtering the
  /// loaded commits locally; author, committer, path, or date fields cancel an
  /// older query and restart Git-backed pagination from the fixed ref snapshot.
  void setSearchQuery(String query) {
    if (query == state.searchQuery) return;
    var previousWasStructured = false;
    try {
      previousWasStructured =
          GitHistoryQuery.tryParse(state.searchQuery)?.isStructured == true;
    } on GitException {
      previousWasStructured = true;
    }
    state = state.copyWith(searchQuery: query, clearHistoryLoadError: true);
    GitHistoryQuery? parsed;
    try {
      parsed = GitHistoryQuery.tryParse(query);
    } on GitException catch (error) {
      _historyQueryCancellation?.cancel();
      _historyGeneration++;
      state = state.copyWith(
        isHistoryLoading: false,
        historyLoadError: error.message,
      );
      return;
    }
    if (parsed?.isStructured != true && !previousWasStructured) return;
    unawaited(_trackVoidGitTask(() => _reloadHistoryForQuery(parsed)));
  }

  /// 中文：从当前固定引用快照重新读取查询首屏；旧查询、仓库切换和 Engine 关闭
  /// 都会取消底层 Git 进程并阻止过期结果写回。
  ///
  /// English: Reloads the first query page from the current fixed revision
  /// snapshot. Superseding queries, repository switches, and Engine shutdown
  /// cancel Git and prevent stale results from being published.
  Future<void> _reloadHistoryForQuery(GitHistoryQuery? query) async {
    final repository = state.repository;
    if (repository == null || state.phase != RepositorySessionPhase.ready) {
      return;
    }
    _historyQueryCancellation?.cancel();
    final cancellation = GitCancellationToken();
    _historyQueryCancellation = cancellation;
    final generation = ++_historyGeneration;
    final revisionSnapshot = state.historyRevisionSnapshot;
    state = state.copyWith(
      commits: const [],
      historyCommits: const [],
      historyOffset: 0,
      hasMoreHistory: false,
      isHistoryLoading: true,
      clearHistoryLoadError: true,
      clearSelectedCommit: true,
      clearSelectedCommitFile: true,
      clearCommitDiff: true,
    );
    try {
      final loadedHistory = await _reader.readRecentHistory(
        repository,
        limit: _historyPageReadLimit,
        revisionSnapshot: revisionSnapshot,
        query: query?.isStructured == true ? query : null,
        cancellationToken: cancellation,
      );
      if (!ref.mounted ||
          cancellation.isCancelled ||
          generation != _historyGeneration ||
          state.repository?.id != repository.id) {
        return;
      }
      final commits = List<GitCommit>.unmodifiable(
        loadedHistory.take(_historyPageSize),
      );
      state = state.copyWith(
        commits: commits,
        historyCommits: commits,
        historyOffset: commits.length,
        hasMoreHistory: loadedHistory.length > _historyPageSize,
        isHistoryLoading: false,
        clearHistoryLoadError: true,
      );
      if (commits.isNotEmpty) await selectCommit(commits.first.objectId);
    } on GitCancelledException {
      // A newer query or shutdown owns the visible state.
    } on Object catch (error) {
      if (!ref.mounted ||
          cancellation.isCancelled ||
          generation != _historyGeneration) {
        return;
      }
      state = state.copyWith(
        isHistoryLoading: false,
        historyLoadError: _friendlyError(error),
      );
    } finally {
      if (identical(_historyQueryCancellation, cancellation)) {
        _historyQueryCancellation = null;
      }
    }
  }

  /// 中文：返回已加载提交的第一父提交 ID；根提交或未加载提交返回 `null`。
  ///
  /// English: Returns the first parent ID of a loaded commit, or `null` for a
  /// root or absent commit.
  String? _parentObjectId(String objectId) {
    for (final commit in state.commits) {
      if (commit.objectId == objectId) return commit.parentIds.firstOrNull;
    }
    return null;
  }

  /// 中文：移除仅为贮藏预览临时读取的提交，避免其进入正常历史与 Graph。
  /// English: Removes commits loaded only for stash preview so they never leak
  /// into the normal history list or graph.
  List<GitCommit> _commitsWithoutStashPreviews() {
    final stashObjectIds = state.stashes.map((stash) => stash.objectId).toSet();
    if (stashObjectIds.isEmpty) return state.commits;
    return List<GitCommit>.unmodifiable(
      state.commits.where(
        (commit) => !stashObjectIds.contains(commit.objectId),
      ),
    );
  }

  /// 中文：更新当前选择。
  /// English: Updates the current selection.
  Future<void> selectChange(
    RepositoryChangeViewData? change, {
    GitDiffWhitespaceMode? whitespaceMode,
  }) async {
    if (!_isInsideTrackedGitTask) {
      return _trackVoidGitTask(
        () => selectChange(change, whitespaceMode: whitespaceMode),
      );
    }
    final selectedWhitespaceMode = whitespaceMode ?? state.diffWhitespaceMode;
    if (change == null) {
      _diffGeneration++;
      state = state.copyWith(
        isDiffLoading: false,
        diffWhitespaceMode: selectedWhitespaceMode,
        clearSelectedChange: true,
        clearDiff: true,
      );
      return;
    }

    final repository = state.repository;
    final status = state.status;
    if (repository == null || status == null) {
      return;
    }

    GitStatusEntry? entry;
    for (final candidate in status.entries) {
      if (candidate.path.display == change.path) {
        entry = candidate;
        break;
      }
    }
    if (entry == null) {
      return;
    }

    final selected = SelectedRepositoryChange(
      entry: entry,
      source: change.isStaged
          ? GitDiffSource.staged
          : GitDiffSource.workingTree,
      kind: change.kind,
    );
    final generation = ++_diffGeneration;
    state = state.copyWith(
      selectedChange: selected,
      diffWhitespaceMode: selectedWhitespaceMode,
      isDiffLoading: true,
      clearDiff: true,
      clearMessage: true,
    );

    if (!entry.path.isValidUtf8) {
      state = state.copyWith(isDiffLoading: false);
      return;
    }

    try {
      final diff = change.kind == RepositoryChangeKind.untracked
          ? await _reader.readUntrackedFileDiff(
              repository,
              path: entry.path.display,
              whitespaceMode: selectedWhitespaceMode,
            )
          : await _reader.readUnifiedDiff(
              repository,
              path: entry.path.display,
              source: selected.source,
              whitespaceMode: selectedWhitespaceMode,
            );
      if (generation != _diffGeneration) {
        return;
      }
      state = state.copyWith(diff: diff, isDiffLoading: false);
    } on Object catch (error, stackTrace) {
      if (generation != _diffGeneration) {
        return;
      }
      state = state.copyWith(
        isDiffLoading: false,
        message: _friendlyError(error),
        technicalDetails: _technicalDetails(error, stackTrace),
      );
    }
  }

  /// Reloads the active main or committed Diff using a new whitespace policy.
  ///
  /// 中文：使用新的空白策略重新读取当前主 Diff 或提交 Diff；非默认模式只
  /// 改变只读展示，应用层会同时移除区块写操作，避免把过滤后的上下文用于补丁。
  Future<void> setDiffWhitespaceMode(GitDiffWhitespaceMode mode) async {
    if (state.selectedCommitId != null && state.selectedCommitFile != null) {
      final selected = state.selectedCommitFile!;
      return selectCommitFileByPath(
        selected.file.path.display,
        whitespaceMode: mode,
      );
    }
    final selected = state.selectedChange;
    if (selected != null) {
      return selectChange(
        RepositoryChangeViewData(
          path: selected.entry.path.display,
          previousPath: selected.entry.originalPath?.display,
          kind: selected.kind,
          isStaged: selected.isStaged,
        ),
        whitespaceMode: mode,
      );
    }
    state = state.copyWith(
      diffWhitespaceMode: mode,
      commitDiffWhitespaceMode: mode,
    );
  }

  /// Reads the current stash reflog for the management dialog. This is
  /// read-only and deliberately does not change the active work-tree view.
  ///
  /// 中文：读取当前贮藏列表供管理面板展示，不改变工作区或当前提交选择。
  Future<List<GitStashEntry>> readStashes() async {
    if (!_isInsideTrackedGitTask) {
      return await _trackGitTask<List<GitStashEntry>>(readStashes) ?? const [];
    }
    final repository = state.repository;
    if (repository == null) return const [];
    return _reader.readStashes(repository);
  }

  /// Reads the installed Git version for capability diagnostics.
  /// 中文：读取当前安装的 Git 版本，仅用于能力诊断，不改变仓库状态。
  Future<String> _readGitVersion() async {
    final result = await _runner.run(
      GitInvocation(
        arguments: const ['--version'],
        outputLimit: const GitOutputLimit(
          stdoutBytes: 16 * 1024,
          stderrBytes: 16 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Reading Git version');
    return result.stdoutText.trim();
  }

  /// 中文：将 Git 和系统异常转换为可展示的本地化错误信息，同时避免泄露敏感文本。
  ///
  /// English: Converts Git and system exceptions into localized display
  /// messages while avoiding sensitive-text disclosure.
  String _friendlyError(Object error) {
    if (error is GitProcessStartException) {
      return error.kind == GitErrorKind.executableNotFound
          ? '找不到 Git。请先安装 Git 或在设置中选择 Git 可执行文件。'
          : '无法启动 Git：${_redactSensitiveText(error.message)}';
    }
    if (error is GitCommandException) {
      if (error.message.toLowerCase().contains(
        'not possible to fast-forward',
      )) {
        return '无法快速前进拉取：本地与远端分支已分叉。请先处理合并。';
      }
      final normalized = error.message.toLowerCase();
      if (normalized.contains('rejected') ||
          normalized.contains('non-fast-forward')) {
        return '推送被远端拒绝；请先 Fetch 并确认远端状态。';
      }
      return switch (error.kind) {
        GitErrorKind.notARepository => '所选目录不是 Git 仓库。',
        GitErrorKind.permissionDenied => '没有权限访问这个仓库。',
        GitErrorKind.unsafeRepository => 'Git 拒绝访问所有权不可信的仓库。',
        GitErrorKind.indexLocked => '仓库正被另一个 Git 操作占用。',
        GitErrorKind.authentication => 'Git 身份验证失败。',
        GitErrorKind.authorization => '当前凭据没有执行此操作的权限。',
        GitErrorKind.network => '无法连接远端，请检查网络和代理设置。',
        GitErrorKind.conflicts => '仓库存在需要处理的冲突。',
        GitErrorKind.cancelled => 'Git 操作已取消。',
        _ => _redactSensitiveText(error.message),
      };
    }
    if (error is GitException) {
      return _redactSensitiveText(error.message);
    }
    return '读取仓库时发生未知错误。';
  }

  /// 中文：检查克隆目标的残留内容，并返回可恢复或需要人工处理的说明。
  ///
  /// English: Inspects residual clone-target contents and returns guidance for
  /// recovery or manual cleanup.
  Future<String?> _cloneRecoveryMessage(
    String directoryPath, {
    required bool wasCancelled,
  }) async {
    final directory = Directory(directoryPath.trim());
    if (!await directory.exists()) {
      return wasCancelled ? '克隆已取消，未留下文件，可以重试。' : '克隆未完成，目标目录不存在，可重新选择目录后重试。';
    }
    final entries = await directory.list(followLinks: false).toList();
    if (entries.isEmpty) {
      return wasCancelled ? '克隆已取消，目标目录仍为空，可以重试。' : '克隆失败，目标目录仍为空，可以重试。';
    }
    final hasGitDirectory = entries.any(
      (entry) =>
          entry is Directory &&
          entry.path.endsWith('${Platform.pathSeparator}.git'),
    );
    if (hasGitDirectory) {
      return wasCancelled
          ? '克隆已取消，目标目录保留了部分 Git 数据。请检查后删除该目录或用命令行恢复。'
          : '克隆未完成，目标目录保留了部分 Git 数据。请检查后删除该目录或用命令行恢复。';
    }
    return wasCancelled
        ? '克隆已取消，目标目录保留了部分文件。请检查后删除该目录再重试。'
        : '克隆未完成，目标目录已有部分文件。请检查后删除该目录再重试。';
  }

  /// 中文：组合异常与堆栈信息并执行脱敏，供技术诊断区域显示。
  ///
  /// English: Combines and redacts an exception and stack trace for the
  /// technical-details area.
  String _technicalDetails(Object error, StackTrace stackTrace) =>
      _redactSensitiveText('$error\n$stackTrace');

  /// 中文：脱敏敏感内容。
  /// English: Redacts sensitive content.
  String _redactSensitiveText(String text) => redactGitSensitiveText(text);
}
