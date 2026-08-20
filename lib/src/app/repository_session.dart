import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path_utils;

import '../git/git.dart';
import '../presentation/presentation.dart';
import 'git_askpass_prompt_coordinator.dart';
import 'repository_session_store.dart';
import 'git_sensitive_text_redactor.dart';

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

final repositorySessionStoreProvider = Provider<RepositorySessionStore>(
  (Ref ref) => FileRepositorySessionStore(),
);

final repositorySessionProvider =
    NotifierProvider<RepositorySessionController, RepositorySessionState>(
      RepositorySessionController.new,
    );

enum RepositorySessionPhase { empty, loading, ready, error }

enum RepositoryOperationKind { clone, fetch, pull, push }

enum RepositoryOperationOutcome { running, succeeded, cancelled, failed }

/// A workspace tab for a successfully opened repository or linked worktree.
final class RepositoryTab {
  const RepositoryTab({
    required this.path,
    required this.label,
    String? baseLabel,
  }) : baseLabel = baseLabel ?? label;

  final String path;

  /// The current label rendered in the tab strip.
  final String label;

  /// The repository directory name before duplicate-name disambiguation.
  final String baseLabel;
}

final class RepositoryOperationRecord {
  const RepositoryOperationRecord({
    required this.id,
    required this.kind,
    required this.outcome,
    required this.startedAt,
    this.completedAt,
    this.message,
  });

  final String id;
  final RepositoryOperationKind kind;
  final RepositoryOperationOutcome outcome;
  final DateTime startedAt;
  final DateTime? completedAt;
  final String? message;

  /// 中文：以指定结果、完成时间和可选消息返回该操作记录的已完成副本。
  ///
  /// English: Returns a completed copy of this operation record with the
  /// supplied outcome, completion time, and optional message.
  RepositoryOperationRecord complete({
    required RepositoryOperationOutcome outcome,
    required DateTime completedAt,
    String? message,
  }) {
    return RepositoryOperationRecord(
      id: id,
      kind: kind,
      outcome: outcome,
      startedAt: startedAt,
      completedAt: completedAt,
      message: message,
    );
  }
}

final class SelectedRepositoryChange {
  const SelectedRepositoryChange({
    required this.entry,
    required this.source,
    required this.kind,
  });

  final GitStatusEntry entry;
  final GitDiffSource source;
  final RepositoryChangeKind kind;

  bool get isStaged => source == GitDiffSource.staged;

  /// 中文：判断是否与目标匹配。
  /// English: Determines whether this matches the target.
  bool matches(RepositoryChangeViewData change) {
    return entry.path.display == change.path && isStaged == change.isStaged;
  }
}

final class SelectedCommitFile {
  const SelectedCommitFile({required this.objectId, required this.file});

  final String objectId;
  final GitCommitFileChange file;

  /// 中文：判断是否与目标匹配。
  /// English: Determines whether this matches the target.
  bool matches(CommitFileViewData change) =>
      file.path.display == change.path && objectId.isNotEmpty;
}

final class RepositorySessionState {
  const RepositorySessionState({
    required this.phase,
    this.requestedPath,
    this.repository,
    this.status,
    this.hasOriginRemote = false,
    this.localBranches = const [],
    this.remoteBranches = const [],
    this.commits = const [],
    this.selectedCommitId,
    this.commitChanges = const [],
    this.selectedCommitFile,
    this.commitDiff,
    this.commitAdditions = 0,
    this.commitDeletions = 0,
    this.isCommitLoading = false,
    this.isCommitDiffLoading = false,
    this.selectedChange,
    this.diff,
    this.isDiffLoading = false,
    this.isCloneRunning = false,
    this.isFetchRunning = false,
    this.isPullRunning = false,
    this.isPushRunning = false,
    this.operations = const [],
    this.openRepositoryTabs = const [],
    this.activeRepositoryTabPath,
    this.searchQuery = '',
    this.gitVersion,
    this.message,
    this.technicalDetails,
  });

  const RepositorySessionState.empty()
    : this(phase: RepositorySessionPhase.empty);

  final RepositorySessionPhase phase;
  final String? requestedPath;
  final GitRepository? repository;
  final GitStatusSnapshot? status;
  final bool hasOriginRemote;
  final List<GitLocalBranch> localBranches;
  final List<GitRemoteBranch> remoteBranches;
  final List<GitCommit> commits;
  final String? selectedCommitId;
  final List<GitCommitFileChange> commitChanges;
  final SelectedCommitFile? selectedCommitFile;
  final GitUnifiedDiff? commitDiff;
  final int commitAdditions;
  final int commitDeletions;
  final bool isCommitLoading;
  final bool isCommitDiffLoading;
  final SelectedRepositoryChange? selectedChange;
  final GitUnifiedDiff? diff;
  final bool isDiffLoading;
  final bool isCloneRunning;
  final bool isFetchRunning;
  final bool isPullRunning;
  final bool isPushRunning;
  final List<RepositoryOperationRecord> operations;
  final List<RepositoryTab> openRepositoryTabs;
  final String? activeRepositoryTabPath;
  final String searchQuery;
  final String? gitVersion;
  final String? message;
  final String? technicalDetails;

  /// 中文：以传入字段创建新的不可变会话状态；未传入字段保留原值，`clear*` 标志会显式清除对应选择、Diff 或错误信息。
  ///
  /// English: Creates a new immutable session state with supplied fields while
  /// retaining omitted values; each `clear*` flag explicitly clears its
  /// related selection, diff, or error information.
  RepositorySessionState copyWith({
    RepositorySessionPhase? phase,
    String? requestedPath,
    GitRepository? repository,
    GitStatusSnapshot? status,
    bool? hasOriginRemote,
    List<GitLocalBranch>? localBranches,
    List<GitRemoteBranch>? remoteBranches,
    List<GitCommit>? commits,
    String? selectedCommitId,
    List<GitCommitFileChange>? commitChanges,
    SelectedCommitFile? selectedCommitFile,
    GitUnifiedDiff? commitDiff,
    int? commitAdditions,
    int? commitDeletions,
    bool? isCommitLoading,
    bool? isCommitDiffLoading,
    SelectedRepositoryChange? selectedChange,
    GitUnifiedDiff? diff,
    bool? isDiffLoading,
    bool? isCloneRunning,
    bool? isFetchRunning,
    bool? isPullRunning,
    bool? isPushRunning,
    List<RepositoryOperationRecord>? operations,
    List<RepositoryTab>? openRepositoryTabs,
    String? activeRepositoryTabPath,
    String? searchQuery,
    String? gitVersion,
    String? message,
    String? technicalDetails,
    bool clearSelectedChange = false,
    bool clearDiff = false,
    bool clearSelectedCommitFile = false,
    bool clearCommitDiff = false,
    bool clearMessage = false,
  }) {
    return RepositorySessionState(
      phase: phase ?? this.phase,
      requestedPath: requestedPath ?? this.requestedPath,
      repository: repository ?? this.repository,
      status: status ?? this.status,
      hasOriginRemote: hasOriginRemote ?? this.hasOriginRemote,
      localBranches: localBranches ?? this.localBranches,
      remoteBranches: remoteBranches ?? this.remoteBranches,
      commits: commits ?? this.commits,
      selectedCommitId: selectedCommitId ?? this.selectedCommitId,
      commitChanges: commitChanges ?? this.commitChanges,
      selectedCommitFile: clearSelectedCommitFile
          ? null
          : selectedCommitFile ?? this.selectedCommitFile,
      commitDiff: clearCommitDiff ? null : commitDiff ?? this.commitDiff,
      commitAdditions: commitAdditions ?? this.commitAdditions,
      commitDeletions: commitDeletions ?? this.commitDeletions,
      isCommitLoading: isCommitLoading ?? this.isCommitLoading,
      isCommitDiffLoading: isCommitDiffLoading ?? this.isCommitDiffLoading,
      selectedChange: clearSelectedChange
          ? null
          : selectedChange ?? this.selectedChange,
      diff: clearDiff ? null : diff ?? this.diff,
      isDiffLoading: isDiffLoading ?? this.isDiffLoading,
      isCloneRunning: isCloneRunning ?? this.isCloneRunning,
      isFetchRunning: isFetchRunning ?? this.isFetchRunning,
      isPullRunning: isPullRunning ?? this.isPullRunning,
      isPushRunning: isPushRunning ?? this.isPushRunning,
      operations: operations ?? this.operations,
      openRepositoryTabs: openRepositoryTabs ?? this.openRepositoryTabs,
      activeRepositoryTabPath:
          activeRepositoryTabPath ?? this.activeRepositoryTabPath,
      searchQuery: searchQuery ?? this.searchQuery,
      gitVersion: gitVersion ?? this.gitVersion,
      message: clearMessage ? null : message ?? this.message,
      technicalDetails: clearMessage
          ? null
          : technicalDetails ?? this.technicalDetails,
    );
  }
}

final class RepositorySessionController
    extends Notifier<RepositorySessionState> {
  late GitRunner _runner;
  late GitRepositoryInspector _inspector;
  late GitRepositoryReader _reader;
  late GitRepositoryWriter _writer;
  late RepositorySessionStore _sessionStore;
  int _repositoryGeneration = 0;
  int _diffGeneration = 0;
  int _commitGeneration = 0;
  int _commitDiffGeneration = 0;
  int _operationSequence = 0;
  GitCancellationToken? _cloneCancellation;
  GitCancellationToken? _fetchCancellation;
  GitCancellationToken? _pullCancellation;
  GitCancellationToken? _pushCancellation;
  GitCancellationToken? _pushVerificationCancellation;
  Future<void> _sessionWriteChain = Future<void>.value();
  bool _isRestoringSession = false;
  bool _sessionPersistenceEnabled = false;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  RepositorySessionState build() {
    _runner = ref.watch(gitRunnerProvider);
    _inspector = ref.watch(gitRepositoryInspectorProvider);
    _reader = ref.watch(gitRepositoryReaderProvider);
    _writer = ref.watch(gitRepositoryWriterProvider);
    _sessionStore = ref.watch(repositorySessionStoreProvider);
    return const RepositorySessionState.empty();
  }

  /// 中文：恢复上次成功打开的仓库和活动标签，不保存凭据或运行中的操作；失效路径会被丢弃。
  ///
  /// English: Restores previously opened repositories and the active tab
  /// without credentials or running operations, dropping invalid paths.
  Future<void> restoreSession() async {
    if (_isRestoringSession || _sessionPersistenceEnabled) {
      return;
    }
    _isRestoringSession = true;
    _sessionPersistenceEnabled = true;
    try {
      final saved = await _sessionStore.load();
      for (final path in saved.openRepositoryPaths) {
        final stateBeforeAttempt = state;
        await openRepository(path);
        if (state.phase != RepositorySessionPhase.ready) {
          state = stateBeforeAttempt;
        }
      }

      final activePath = saved.activeRepositoryPath;
      if (activePath != null &&
          activePath != state.activeRepositoryTabPath &&
          state.openRepositoryTabs.any((tab) => tab.path == activePath)) {
        final stateBeforeSelection = state;
        await selectRepositoryTab(activePath);
        if (state.phase != RepositorySessionPhase.ready) {
          state = stateBeforeSelection;
        }
      }
    } finally {
      _isRestoringSession = false;
      _persistRepositorySession();
    }
  }

  /// 中文：将当前已打开标签和活动路径串行写入本地会话存储，且写入失败不影响 Git 操作。
  ///
  /// English: Serializes the current tabs and active path to local session
  /// storage without letting write failures affect Git operations.
  void _persistRepositorySession() {
    if (!_sessionPersistenceEnabled || _isRestoringSession) {
      return;
    }
    final snapshot = RepositorySessionSnapshot(
      openRepositoryPaths: List<String>.unmodifiable(
        state.openRepositoryTabs.map((tab) => tab.path),
      ),
      activeRepositoryPath: state.activeRepositoryTabPath,
    );
    _sessionWriteChain = _sessionWriteChain.then((_) async {
      try {
        await _sessionStore.save(snapshot);
      } on Object {
        // A local preference write must not turn a successful Git operation
        // into an application error.
      }
    });
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

  /// 中文：打开目标资源。
  /// English: Opens the target resource.
  Future<void> openRepository(String path) async {
    final normalizedPath = path.trim();
    if (normalizedPath.isEmpty) {
      return;
    }

    final generation = ++_repositoryGeneration;
    _diffGeneration++;
    _commitGeneration++;
    _commitDiffGeneration++;
    state = state.copyWith(
      phase: RepositorySessionPhase.loading,
      requestedPath: normalizedPath,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );

    try {
      final repository = await _inspector.inspect(normalizedPath);
      if (repository == null) {
        throw const GitException('所选目录不在 Git 仓库中。');
      }

      final results = await Future.wait<Object>([
        _reader.readStatus(repository),
        _reader.hasOriginRemote(repository),
        _reader.readLocalBranches(repository),
        _reader.readRemoteBranches(repository),
        _reader.readRecentHistory(repository),
        _readGitVersion(),
      ]);
      if (generation != _repositoryGeneration) {
        return;
      }

      final status = results[0] as GitStatusSnapshot;
      final hasOriginRemote = results[1] as bool;
      final localBranches = results[2] as List<GitLocalBranch>;
      final remoteBranches = results[3] as List<GitRemoteBranch>;
      final commits = results[4] as List<GitCommit>;
      final tab = RepositoryTab(
        path: repository.commandDirectory,
        label: path_utils.basename(
          repository.workTreeRoot ?? repository.commonDirectory,
        ),
      );
      state = RepositorySessionState(
        phase: RepositorySessionPhase.ready,
        requestedPath: normalizedPath,
        repository: repository,
        status: status,
        hasOriginRemote: hasOriginRemote,
        localBranches: localBranches,
        remoteBranches: remoteBranches,
        commits: commits,
        // Keep the working-tree inspector visible until the user chooses a
        // historical commit. Selecting a commit then replaces it with that
        // commit's file list and Diff.
        selectedCommitId: null,
        operations: state.operations,
        openRepositoryTabs: _disambiguateRepositoryTabLabels(
          _upsertRepositoryTab(state.openRepositoryTabs, tab),
        ),
        activeRepositoryTabPath: tab.path,
        gitVersion: results[5] as String,
        searchQuery: state.searchQuery,
      );
      _persistRepositorySession();
    } on Object catch (error, stackTrace) {
      if (generation != _repositoryGeneration) {
        return;
      }
      state = state.copyWith(
        phase: RepositorySessionPhase.error,
        isDiffLoading: false,
        message: _friendlyError(error),
        technicalDetails: '$error\n$stackTrace',
      );
    }
  }

  /// Selects an already opened repository tab. Switching is intentionally
  /// unavailable while Git is mutating a repository so an in-flight operation
  /// cannot be mistaken for work in another tab.
  /// 中文：更新当前选择。
  /// English: Updates the current selection.
  Future<void> selectRepositoryTab(String repositoryPath) async {
    if (repositoryPath == state.activeRepositoryTabPath ||
        state.phase == RepositorySessionPhase.loading ||
        state.isCloneRunning ||
        state.isFetchRunning ||
        state.isPullRunning ||
        state.isPushRunning ||
        !state.openRepositoryTabs.any((tab) => tab.path == repositoryPath)) {
      return;
    }
    await openRepository(repositoryPath);
  }

  /// 中文：按路径替换已有标签，或在路径首次出现时追加标签，并保持列表不可变。
  ///
  /// English: Replaces an existing tab by path or appends a first-seen tab,
  /// returning an immutable list.
  List<RepositoryTab> _upsertRepositoryTab(
    List<RepositoryTab> existingTabs,
    RepositoryTab nextTab,
  ) {
    final result = <RepositoryTab>[];
    var replaced = false;
    for (final tab in existingTabs) {
      if (tab.path == nextTab.path) {
        result.add(nextTab);
        replaced = true;
      } else {
        result.add(tab);
      }
    }
    if (!replaced) {
      result.add(nextTab);
    }
    return List<RepositoryTab>.unmodifiable(result);
  }

  /// 中文：为重名仓库标签添加父目录前缀，避免标签栏中出现无法区分的名称。
  ///
  /// English: Prefixes duplicate repository labels with their parent directory
  /// so the tab strip remains unambiguous.
  List<RepositoryTab> _disambiguateRepositoryTabLabels(
    List<RepositoryTab> tabs,
  ) {
    final labelCounts = <String, int>{};
    for (final tab in tabs) {
      labelCounts.update(
        tab.baseLabel,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    return List<RepositoryTab>.unmodifiable([
      for (final tab in tabs)
        RepositoryTab(
          path: tab.path,
          baseLabel: tab.baseLabel,
          label: labelCounts[tab.baseLabel] == 1
              ? tab.baseLabel
              : '${path_utils.basename(path_utils.dirname(tab.path))}/${tab.baseLabel}',
        ),
    ]);
  }

  /// Initializes only an empty directory, then opens the new repository.
  /// 中文：初始化当前功能。
  /// English: Initializes the current feature.
  Future<bool> initializeRepository(String path) async {
    final normalizedPath = path.trim();
    if (normalizedPath.isEmpty ||
        state.phase == RepositorySessionPhase.loading) {
      return false;
    }
    _repositoryGeneration++;
    _diffGeneration++;
    state = state.copyWith(
      phase: RepositorySessionPhase.loading,
      requestedPath: normalizedPath,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    try {
      await _writer.initializeRepository(normalizedPath);
      await openRepository(normalizedPath);
      return state.phase == RepositorySessionPhase.ready;
    } on Object catch (error, stackTrace) {
      state = state.copyWith(
        phase: RepositorySessionPhase.error,
        isDiffLoading: false,
        message: _friendlyError(error),
        technicalDetails: '$error\n$stackTrace',
      );
      return false;
    }
  }

  /// 中文：在空目录克隆仓库，记录可取消的操作并在结束后刷新和打开新仓库。
  ///
  /// English: Clones a repository into an empty directory, records a
  /// cancellable operation, then refreshes and opens the new repository.
  Future<bool> cloneRepository({
    required String remoteUrl,
    required String directoryPath,
  }) async {
    if (remoteUrl.trim().isEmpty ||
        directoryPath.trim().isEmpty ||
        state.phase == RepositorySessionPhase.loading) {
      return false;
    }
    _repositoryGeneration++;
    _diffGeneration++;
    final cancellation = GitCancellationToken();
    _cloneCancellation = cancellation;
    final operation = _startOperation(RepositoryOperationKind.clone);
    state = state.copyWith(
      phase: RepositorySessionPhase.loading,
      requestedPath: directoryPath.trim(),
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
      isCloneRunning: true,
    );
    try {
      await _runWithAskPassSession(
        cancellation: cancellation,
        run: (environment) => _writer.cloneRepository(
          remoteUrl: remoteUrl,
          directoryPath: directoryPath,
          cancellationToken: cancellation,
          environment: environment,
        ),
      );
      await openRepository(directoryPath);
      final succeeded = state.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.failed,
        message: succeeded ? '仓库已克隆并打开。' : state.message,
      );
      return succeeded;
    } on Object catch (error, stackTrace) {
      final recovery = await _cloneRecoveryMessage(directoryPath);
      final message = recovery ?? _friendlyError(error);
      state = state.copyWith(
        phase: RepositorySessionPhase.error,
        isDiffLoading: false,
        isCloneRunning: false,
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
      if (identical(_cloneCancellation, cancellation)) {
        _cloneCancellation = null;
      }
    }
  }

  /// 中文：取消当前操作。
  /// English: Cancels the current operation.
  void cancelClone() => _cloneCancellation?.cancel();

  /// 中文：获取当前仓库的 `origin`，记录操作结果，并在成功后刷新本地引用状态。
  ///
  /// English: Fetches `origin` for the current repository, records the
  /// outcome, and refreshes local reference state on success.
  Future<bool> fetchOrigin() async {
    final repository = state.repository;
    if (repository == null ||
        !state.hasOriginRemote ||
        state.phase == RepositorySessionPhase.loading) {
      return false;
    }
    final cancellation = GitCancellationToken();
    _fetchCancellation = cancellation;
    final operation = _startOperation(RepositoryOperationKind.fetch);
    state = state.copyWith(
      phase: RepositorySessionPhase.loading,
      isFetchRunning: true,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    try {
      await _runWithAskPassSession(
        cancellation: cancellation,
        run: (environment) => _writer.fetchOrigin(
          repository,
          cancellationToken: cancellation,
          environment: environment,
        ),
      );
      await refresh();
      final succeeded = state.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.failed,
        message: succeeded ? '已更新远端引用。' : state.message,
      );
      return succeeded;
    } on Object catch (error, stackTrace) {
      final message = _friendlyError(error);
      state = state.copyWith(
        phase: RepositorySessionPhase.error,
        isFetchRunning: false,
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
      if (identical(_fetchCancellation, cancellation)) {
        _fetchCancellation = null;
      }
    }
  }

  /// 中文：取消当前操作。
  /// English: Cancels the current operation.
  void cancelFetch() => _fetchCancellation?.cancel();

  /// 中文：仅在工作区和索引干净且有上游时快速前进拉取，并在失败后刷新引用状态。
  ///
  /// English: Fast-forward pulls only with a clean work tree/index and an
  /// upstream, refreshing reference state after failure as well.
  Future<bool> pullFastForward() async {
    final repository = state.repository;
    final status = state.status;
    if (repository == null ||
        status == null ||
        status.branch.upstream == null ||
        !status.isClean ||
        state.phase == RepositorySessionPhase.loading) {
      return false;
    }
    final cancellation = GitCancellationToken();
    _pullCancellation = cancellation;
    final operation = _startOperation(RepositoryOperationKind.pull);
    state = state.copyWith(
      phase: RepositorySessionPhase.loading,
      isPullRunning: true,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    try {
      await _runWithAskPassSession(
        cancellation: cancellation,
        run: (environment) => _writer.pullFastForward(
          repository,
          cancellationToken: cancellation,
          environment: environment,
        ),
      );
      await refresh();
      final succeeded = state.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.failed,
        message: succeeded ? '已快速前进拉取。' : state.message,
      );
      return succeeded;
    } on Object catch (error, stackTrace) {
      // Pull can fetch successfully before rejecting a non-fast-forward update.
      // Refresh before showing the error so refs and ahead/behind stay accurate.
      await refresh();
      final message = _friendlyError(error);
      state = state.copyWith(
        phase: RepositorySessionPhase.error,
        isPullRunning: false,
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
      if (identical(_pullCancellation, cancellation)) {
        _pullCancellation = null;
      }
    }
  }

  /// 中文：取消当前操作。
  /// English: Cancels the current operation.
  void cancelPull() => _pullCancellation?.cancel();

  /// 中文：仅在当前分支领先上游时推送；异常结束后会验证远端是否已包含 HEAD。
  ///
  /// English: Pushes only when the current branch is ahead of its upstream and
  /// verifies whether the remote already contains HEAD after an uncertain exit.
  Future<bool> pushUpstream() async {
    final repository = state.repository;
    final status = state.status;
    if (repository == null ||
        status == null ||
        status.branch.upstream == null ||
        status.branch.ahead <= 0 ||
        state.phase == RepositorySessionPhase.loading) {
      return false;
    }
    final cancellation = GitCancellationToken();
    _pushCancellation = cancellation;
    final operation = _startOperation(RepositoryOperationKind.push);
    state = state.copyWith(
      phase: RepositorySessionPhase.loading,
      isPushRunning: true,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    try {
      await _runWithAskPassSession(
        cancellation: cancellation,
        run: (environment) => _writer.pushUpstream(
          repository,
          cancellationToken: cancellation,
          environment: environment,
        ),
      );
      await refresh();
      final succeeded = state.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.failed,
        message: succeeded ? '已推送当前分支。' : state.message,
      );
      return succeeded;
    } on Object catch (error, stackTrace) {
      // A push may reach the remote before the process exits or is cancelled.
      // Verify the target first, then refresh local tracking state. The
      // verification is read-only and can be cancelled through cancelPush.
      final remoteContainsHead = await _verifyUncertainPush(repository);
      await refresh();
      final message = remoteContainsHead
          ? '推送进程未正常完成，但远端已包含当前 HEAD。请 Fetch 刷新 ahead/behind。'
          : _friendlyError(error);
      state = state.copyWith(
        phase: RepositorySessionPhase.error,
        isPushRunning: false,
        isDiffLoading: false,
        message: message,
        technicalDetails: _technicalDetails(error, stackTrace),
      );
      _completeOperation(
        operation,
        outcome: remoteContainsHead
            ? RepositoryOperationOutcome.succeeded
            : _operationOutcomeForError(error),
        message: message,
      );
      return false;
    } finally {
      if (identical(_pushCancellation, cancellation)) {
        _pushCancellation = null;
      }
    }
  }

  /// 中文：取消当前操作。
  /// English: Cancels the current operation.
  void cancelPush() {
    _pushCancellation?.cancel();
    _pushVerificationCancellation?.cancel();
  }

  /// 中文：仅为明确的远端操作临时启用 AskPass；检查、刷新和推送验证始终保持非交互环境。
  ///
  /// English: Temporarily enables AskPass only for explicit remote operations;
  /// inspection, refresh, and push verification remain non-interactive.
  Future<void> _runWithAskPassSession({
    required GitCancellationToken cancellation,
    required Future<void> Function(Map<String, String> environment) run,
  }) async {
    if (!GitAskPassSession.isBundledHelperAvailableForCurrentRuntime) {
      // Never point GIT_ASKPASS at a guessed development/test binary. Git's
      // existing credential helper and SSH Agent remain available while
      // terminal prompting stays disabled by GitRunner.
      await run(const <String, String>{});
      return;
    }
    final promptCoordinator = ref.read(
      gitAskPassPromptCoordinatorProvider.notifier,
    );
    final session = await GitAskPassSession.start(
      onPrompt: promptCoordinator.request,
    );
    final registration = cancellation.register(() {
      promptCoordinator.cancel();
      unawaited(session.close());
    });
    try {
      await run(session.environmentForBundledHelper());
    } finally {
      registration.dispose();
      promptCoordinator.cancel();
      await session.close();
    }
  }

  /// 中文：验证当前条件。
  /// English: Verifies the current condition.
  Future<bool> _verifyUncertainPush(GitRepository repository) async {
    final cancellation = GitCancellationToken();
    _pushVerificationCancellation = cancellation;
    try {
      return await _writer.verifyUpstream(
        repository,
        cancellationToken: cancellation,
      );
    } on Object {
      return false;
    } finally {
      if (identical(_pushVerificationCancellation, cancellation)) {
        _pushVerificationCancellation = null;
      }
    }
  }

  /// 中文：刷新当前数据。
  /// English: Refreshes the current data.
  Future<void> refresh() async {
    final path = state.requestedPath ?? state.repository?.commandDirectory;
    if (path != null) {
      await openRepository(path);
    }
  }

  /// 中文：更新当前选择。
  /// English: Updates the current selection.
  Future<void> selectCommit(String objectId) async {
    if (!state.commits.any((GitCommit commit) => commit.objectId == objectId)) {
      return;
    }
    final repository = state.repository;
    if (repository == null) return;
    final parentObjectId = _parentObjectId(objectId);
    final generation = ++_commitGeneration;
    _commitDiffGeneration++;
    state = state.copyWith(
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
      if (summary.files.isNotEmpty) {
        await selectCommitFileByPath(summary.files.first.path.display);
      }
    } on Object catch (error, stackTrace) {
      if (!ref.mounted || generation != _commitGeneration) return;
      state = state.copyWith(
        isCommitLoading: false,
        message: _friendlyError(error),
        technicalDetails: '$error\n$stackTrace',
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
  Future<void> selectCommitFileByPath(String? path) async {
    final objectId = state.selectedCommitId;
    final repository = state.repository;
    if (path == null || objectId == null || repository == null) {
      _commitDiffGeneration++;
      state = state.copyWith(
        isCommitDiffLoading: false,
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
        technicalDetails: '$error\n$stackTrace',
      );
    }
  }

  /// 中文：更新提交历史的筛选查询，不触发新的 Git 读取。
  ///
  /// English: Updates the commit-history filter query without starting another
  /// Git read.
  void setSearchQuery(String query) {
    state = state.copyWith(searchQuery: query);
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

  /// 中文：更新当前选择。
  /// English: Updates the current selection.
  Future<void> selectChange(RepositoryChangeViewData? change) async {
    if (change == null) {
      _diffGeneration++;
      state = state.copyWith(
        isDiffLoading: false,
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
      isDiffLoading: true,
      clearDiff: true,
      clearMessage: true,
    );

    if (!entry.path.isValidUtf8 ||
        change.kind == RepositoryChangeKind.untracked) {
      state = state.copyWith(isDiffLoading: false);
      return;
    }

    try {
      final diff = await _reader.readUnifiedDiff(
        repository,
        path: entry.path.display,
        source: selected.source,
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
        technicalDetails: '$error\n$stackTrace',
      );
    }
  }

  /// 中文：切换当前状态。
  /// English: Toggles the current state.
  Future<void> toggleStage(RepositoryChangeViewData change) async {
    final repository = state.repository;
    final status = state.status;
    if (repository == null ||
        status == null ||
        state.phase == RepositorySessionPhase.loading) {
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

    state = state.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
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
      await refresh();
    } on Object catch (error, stackTrace) {
      state = state.copyWith(
        phase: RepositorySessionPhase.error,
        message: _friendlyError(error),
        technicalDetails: '$error\n$stackTrace',
      );
    }
  }

  /// Commits exactly the files currently staged in the repository index.
  ///
  /// Returns whether Git created the commit and the following refresh finished
  /// successfully. Git hooks are intentionally allowed to run.
  /// 中文：创建所需的对象或资源。
  /// English: Creates the required object or resource.
  Future<bool> createCommit(String message) async {
    final repository = state.repository;
    final status = state.status;
    if (repository == null ||
        status == null ||
        status.stagedEntries.isEmpty ||
        state.phase == RepositorySessionPhase.loading) {
      return false;
    }

    if (message.trim().isEmpty) {
      throw ArgumentError.value(message, 'message', 'Commit message is empty.');
    }

    state = state.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    try {
      await _writer.createCommit(repository, message: message);
      await refresh();
      return state.phase == RepositorySessionPhase.ready;
    } on Object catch (error, stackTrace) {
      state = state.copyWith(
        phase: RepositorySessionPhase.error,
        isDiffLoading: false,
        message: _friendlyError(error),
        technicalDetails: '$error\n$stackTrace',
      );
      return false;
    }
  }

  /// Creates a local branch at HEAD without switching the current work tree.
  /// 中文：创建所需的对象或资源。
  /// English: Creates the required object or resource.
  Future<bool> createLocalBranch(String name) async {
    final repository = state.repository;
    final status = state.status;
    if (repository == null ||
        status == null ||
        status.branch.isUnborn ||
        state.phase == RepositorySessionPhase.loading) {
      return false;
    }

    if (name.trim().isEmpty) {
      throw ArgumentError.value(name, 'name', 'Branch name is empty.');
    }

    state = state.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    try {
      await _writer.createLocalBranch(repository, name: name);
      await refresh();
      return state.phase == RepositorySessionPhase.ready;
    } on Object catch (error, stackTrace) {
      state = state.copyWith(
        phase: RepositorySessionPhase.error,
        isDiffLoading: false,
        message: _friendlyError(error),
        technicalDetails: '$error\n$stackTrace',
      );
      return false;
    }
  }

  /// Switches only when the working tree and index are clean.
  /// 中文：切换到目标状态。
  /// English: Switches to the target state.
  Future<bool> switchToLocalBranch(String name) async {
    final repository = state.repository;
    final status = state.status;
    if (repository == null ||
        status == null ||
        !status.isClean ||
        state.phase == RepositorySessionPhase.loading) {
      return false;
    }
    if (name.trim().isEmpty) {
      throw ArgumentError.value(name, 'name', 'Branch name is empty.');
    }
    if (status.branch.head == name) {
      return true;
    }

    state = state.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    try {
      await _writer.switchToLocalBranch(repository, name: name);
      await refresh();
      return state.phase == RepositorySessionPhase.ready;
    } on Object catch (error, stackTrace) {
      state = state.copyWith(
        phase: RepositorySessionPhase.error,
        isDiffLoading: false,
        message: _friendlyError(error),
        technicalDetails: '$error\n$stackTrace',
      );
      return false;
    }
  }

  /// 中文：仅在工作区干净且分支仍存在于已读取远端引用中时，创建本地跟踪分支并切换过去。
  ///
  /// English: Creates and switches to a local tracking branch only when the
  /// work tree is clean and the branch remains in the loaded remote refs.
  Future<bool> switchToRemoteBranch(String remoteName) async {
    final repository = state.repository;
    final status = state.status;
    if (repository == null ||
        status == null ||
        !status.isClean ||
        state.phase == RepositorySessionPhase.loading ||
        !state.remoteBranches.any((branch) => branch.name == remoteName)) {
      return false;
    }

    state = state.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    try {
      await _writer.switchToRemoteBranch(repository, remoteName: remoteName);
      await refresh();
      return state.phase == RepositorySessionPhase.ready;
    } on Object catch (error, stackTrace) {
      state = state.copyWith(
        phase: RepositorySessionPhase.error,
        isDiffLoading: false,
        message: _friendlyError(error),
        technicalDetails: '$error\n$stackTrace',
      );
      return false;
    }
  }

  /// 中文：将指定本地分支合并到当前分支；仅在工作区干净、来源不是当前分支且来源已加载时执行。
  /// 合并冲突会保留在仓库中并刷新为可见冲突状态，但不会自动继续或中止。
  ///
  /// English: Merges a loaded local source branch into the current branch only
  /// with a clean work tree and a distinct source. Merge conflicts remain in
  /// the repository and are refreshed for display; they are never continued or
  /// aborted automatically.
  Future<bool> mergeLocalBranch(String sourceName) async {
    final repository = state.repository;
    final status = state.status;
    final currentBranch = status?.branch.head;
    if (repository == null ||
        status == null ||
        currentBranch == null ||
        !status.isClean ||
        state.phase == RepositorySessionPhase.loading ||
        sourceName == currentBranch ||
        !state.localBranches.any((branch) => branch.name == sourceName)) {
      return false;
    }

    state = state.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    try {
      await _writer.mergeLocalBranch(repository, sourceName: sourceName);
      await refresh();
      return state.phase == RepositorySessionPhase.ready;
    } on Object catch (error, stackTrace) {
      // A failed merge can leave conflict entries and MERGE_HEAD behind. Read
      // them before showing the error so the user sees the actual recovery
      // state instead of the pre-merge snapshot.
      await refresh();
      final hasConflicts = state.status?.conflictedEntries.isNotEmpty ?? false;
      final message =
          hasConflicts ||
              (error is GitCommandException &&
                  error.kind == GitErrorKind.conflicts)
          ? '合并遇到冲突。请处理冲突后使用 Git 命令行继续或中止合并，再刷新仓库。'
          : _friendlyError(error);
      state = state.copyWith(
        phase: RepositorySessionPhase.error,
        isDiffLoading: false,
        message: message,
        technicalDetails: _technicalDetails(error, stackTrace),
      );
      return false;
    }
  }

  /// 中文：读取所需的数据。
  /// English: Reads the required data.
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
          : '无法启动 Git：${error.message}';
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
        _ => error.message,
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
  Future<String?> _cloneRecoveryMessage(String directoryPath) async {
    final directory = Directory(directoryPath.trim());
    if (!await directory.exists()) {
      return '克隆未完成，目标目录不存在，可重新选择目录后重试。';
    }
    final entries = await directory.list(followLinks: false).toList();
    if (entries.isEmpty) {
      return '克隆已取消或失败，目标目录仍为空，可以重试。';
    }
    final hasGitDirectory = entries.any(
      (entry) =>
          entry is Directory &&
          entry.path.endsWith('${Platform.pathSeparator}.git'),
    );
    return hasGitDirectory
        ? '克隆未完成，目标目录保留了部分 Git 数据。请检查后删除该目录或用命令行恢复。'
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
