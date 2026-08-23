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

enum RepositoryOperationKind { clone, fetch, pull, push, stash }

enum RepositoryOperationOutcome { running, succeeded, cancelled, failed }

/// Returns the directory name Git would conventionally use for [remoteUrl].
///
/// URL, SCP-style and local-path remotes are supported. The result is always
/// one safe path component.
String cloneRepositoryNameFromRemote(String remoteUrl) {
  var remote = remoteUrl.trim();
  if (remote.isEmpty) {
    throw ArgumentError.value(remoteUrl, 'remoteUrl', 'Must not be empty.');
  }

  final suffixStart = <int>[remote.indexOf('?'), remote.indexOf('#')]
      .where((index) => index >= 0)
      .fold<int>(
        remote.length,
        (earliest, index) => index < earliest ? index : earliest,
      );
  remote = remote.substring(0, suffixStart);
  while (remote.endsWith('/') || remote.endsWith(r'\')) {
    remote = remote.substring(0, remote.length - 1);
  }

  final separatorIndex = <int>[
    remote.lastIndexOf('/'),
    remote.lastIndexOf(r'\'),
    remote.lastIndexOf(':'),
  ].reduce((latest, index) => index > latest ? index : latest);
  var name = remote.substring(separatorIndex + 1);
  try {
    name = Uri.decodeComponent(name);
  } on FormatException {
    // Git may accept a literal percent sign in a local or SCP-style path.
  }
  if (name.toLowerCase().endsWith('.git')) {
    name = name.substring(0, name.length - 4);
  }

  if (name.isEmpty ||
      name == '.' ||
      name == '..' ||
      name.contains('/') ||
      name.contains(r'\') ||
      name.contains('\u0000')) {
    throw const GitException('无法从远端地址确定仓库目录名。');
  }
  return name;
}

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

/// 中文：在暂存状态切换并刷新后，从 Git 状态恢复同一文件在目标分组中的展示数据。
/// English: Rebuilds the same file's display data in its target group after a
/// staging toggle and status refresh.
RepositoryChangeViewData? _changeAfterStageToggle(
  GitStatusEntry entry, {
  required bool isStaged,
}) {
  if (entry.isConflicted) return null;
  if (isStaged ? !entry.hasStagedChange : !entry.hasWorkTreeChange) return null;
  final type = isStaged ? entry.indexStatus : entry.workTreeStatus;
  final kind =
      entry.kind == GitFileStatusKind.renamed || type == GitChangeType.renamed
      ? RepositoryChangeKind.renamed
      : entry.kind == GitFileStatusKind.copied || type == GitChangeType.copied
      ? RepositoryChangeKind.copied
      : type == GitChangeType.added
      ? RepositoryChangeKind.added
      : type == GitChangeType.deleted
      ? RepositoryChangeKind.deleted
      : type == GitChangeType.untracked
      ? RepositoryChangeKind.untracked
      : RepositoryChangeKind.modified;
  return RepositoryChangeViewData(
    path: entry.path.display,
    previousPath: entry.originalPath?.display,
    kind: kind,
    isStaged: isStaged,
    canToggleStage: entry.path.isValidUtf8,
  );
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
    this.originUrl,
    this.operationState = GitRepositoryOperationState.none,
    this.localBranches = const [],
    this.remoteNames = const [],
    this.remoteBranches = const [],
    this.stashes = const [],
    this.commits = const [],
    this.selectedRefId = 'workspace',
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
    this.isStashRunning = false,
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
  final String? originUrl;
  final GitRepositoryOperationState operationState;
  final List<GitLocalBranch> localBranches;
  final List<String> remoteNames;
  final List<GitRemoteBranch> remoteBranches;
  final List<GitStashEntry> stashes;
  final List<GitCommit> commits;
  final String selectedRefId;
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
  final bool isStashRunning;
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
    String? originUrl,
    GitRepositoryOperationState? operationState,
    List<GitLocalBranch>? localBranches,
    List<String>? remoteNames,
    List<GitRemoteBranch>? remoteBranches,
    List<GitStashEntry>? stashes,
    List<GitCommit>? commits,
    String? selectedRefId,
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
    bool? isStashRunning,
    List<RepositoryOperationRecord>? operations,
    List<RepositoryTab>? openRepositoryTabs,
    String? activeRepositoryTabPath,
    String? searchQuery,
    String? gitVersion,
    String? message,
    String? technicalDetails,
    bool clearSelectedChange = false,
    bool clearDiff = false,
    bool clearSelectedCommit = false,
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
      originUrl: originUrl ?? this.originUrl,
      operationState: operationState ?? this.operationState,
      localBranches: localBranches ?? this.localBranches,
      remoteNames: remoteNames ?? this.remoteNames,
      remoteBranches: remoteBranches ?? this.remoteBranches,
      stashes: stashes ?? this.stashes,
      commits: commits ?? this.commits,
      selectedRefId: selectedRefId ?? this.selectedRefId,
      selectedCommitId: clearSelectedCommit
          ? null
          : selectedCommitId ?? this.selectedCommitId,
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
      isStashRunning: isStashRunning ?? this.isStashRunning,
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

/// 中文：为游离 HEAD 选择唯一的可推送本地分支，保证界面、确认框和 Git 写操作一致。
///
/// English: Selects the single pushable local branch for detached HEAD so the
/// mapper, confirmation dialog, and Git writer use the same target.
GitLocalBranch? selectDetachedPushBranch(RepositorySessionState state) {
  final candidates = state.localBranches
      .where((branch) => branch.upstream != null || state.hasOriginRemote)
      .toList(growable: false);
  if (candidates.isEmpty) return null;
  for (final candidate in candidates) {
    if (candidate.ahead > 0) return candidate;
  }
  for (final candidate in candidates) {
    final upstream = candidate.upstream;
    final remote = upstream == null
        ? null
        : state.remoteBranches
              .where((branch) => branch.name == upstream)
              .firstOrNull;
    if (remote == null || remote.objectId != candidate.objectId) {
      return candidate;
    }
  }
  return candidates.first;
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
  GitCancellationToken? _stashCancellation;
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
    ref.onDispose(_cancelActiveGitOperations);
    return const RepositorySessionState.empty();
  }

  /// 中文：取消当前 Engine 的 Git 操作，并短暂等待 Git 与 AskPass 释放原生资源。
  ///
  /// English: Cancels Engine-owned Git operations and waits briefly for
  /// their Git processes and AskPass sessions to release native resources.
  Future<void> prepareForShutdown({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    _repositoryGeneration++;
    _diffGeneration++;
    _commitGeneration++;
    _commitDiffGeneration++;
    _cancelActiveGitOperations();

    final deadline = DateTime.now().add(timeout);
    while (_hasActiveGitOperation && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  bool get _hasActiveGitOperation =>
      _cloneCancellation != null ||
      _fetchCancellation != null ||
      _pullCancellation != null ||
      _pushCancellation != null ||
      _pushVerificationCancellation != null ||
      _stashCancellation != null;

  void _cancelActiveGitOperations() {
    _cloneCancellation?.cancel();
    _fetchCancellation?.cancel();
    _pullCancellation?.cancel();
    _pushCancellation?.cancel();
    _pushVerificationCancellation?.cancel();
    _stashCancellation?.cancel();
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

      final results = await Future.wait<Object?>([
        _reader.readStatus(repository),
        _reader.readRemoteUrl(repository),
        _reader.readOperationState(repository),
        _reader.readLocalBranches(repository),
        _reader.readRemoteNames(repository),
        _reader.readRemoteBranches(repository),
        _reader.readStashes(repository),
        _reader.readRecentHistory(repository),
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
      final stashes = results[6] as List<GitStashEntry>;
      final commits = results[7] as List<GitCommit>;
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
        originUrl: originUrl,
        operationState: operationState,
        localBranches: localBranches,
        remoteNames: remoteNames,
        remoteBranches: remoteBranches,
        stashes: stashes,
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
        gitVersion: results[8] as String,
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
        state.isStashRunning ||
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
      final wasCancelled =
          _operationOutcomeForError(error) ==
          RepositoryOperationOutcome.cancelled;
      // Cancellation after Git starts is represented by GitCommandException
      // with a cancelled kind and may leave files behind. GitCancelledException
      // is raised before the process starts, so it cannot create clone residue.
      final recovery = error is GitCommandException
          ? await _cloneRecoveryMessage(
              directoryPath,
              wasCancelled: wasCancelled,
            )
          : error is GitCancelledException
          ? '克隆已取消，未留下文件，可以重试。'
          : null;
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

  /// 中文：在用户选择的存放位置下按远端仓库名创建子目录并克隆。
  ///
  /// English: Clones into a repository-named child of the selected parent.
  Future<bool> cloneRepositoryIntoParent({
    required String remoteUrl,
    required String parentDirectoryPath,
  }) async {
    if (remoteUrl.trim().isEmpty || parentDirectoryPath.trim().isEmpty) {
      return false;
    }
    try {
      final targetPath = path_utils.join(
        parentDirectoryPath.trim(),
        cloneRepositoryNameFromRemote(remoteUrl),
      );
      return await cloneRepository(
        remoteUrl: remoteUrl,
        directoryPath: targetPath,
      );
    } on Object catch (error, stackTrace) {
      state = state.copyWith(
        phase: RepositorySessionPhase.error,
        requestedPath: parentDirectoryPath.trim(),
        isDiffLoading: false,
        isCloneRunning: false,
        message: _friendlyError(error),
        technicalDetails: _technicalDetails(error, stackTrace),
      );
      return false;
    }
  }

  /// 中文：取消当前操作。
  /// English: Cancels the current operation.
  void cancelClone() => _cloneCancellation?.cancel();

  /// 中文：获取当前仓库的 `origin`，记录操作结果，并在成功后刷新本地引用状态。
  ///
  /// English: Fetches `origin` for the current repository, records the
  /// outcome, and refreshes local reference state on success.
  Future<bool> fetchOrigin() =>
      fetchWithOptions(const GitFetchOptions(fetchAllRemotes: false));

  /// Fetches one configured remote and refreshes its tracking references.
  /// 中文：获取指定远端并刷新该远端的跟踪引用。
  Future<bool> fetchRemote(String remoteName) => fetchWithOptions(
    GitFetchOptions(fetchAllRemotes: false, remoteName: remoteName),
  );

  /// 中文：按抓取面板选项获取一个或全部远端，并在完成后刷新本地引用状态。
  ///
  /// English: Fetches one or every remote according to the dialog options and
  /// refreshes local references after the operation completes.
  Future<bool> fetchWithOptions(GitFetchOptions options) async {
    final normalizedRemote = options.remoteName.trim();
    final repository = state.repository;
    if (repository == null || state.phase == RepositorySessionPhase.loading) {
      return false;
    }
    List<String> remoteNames;
    try {
      remoteNames = await _reader.readRemoteNames(repository);
    } on Object catch (error, stackTrace) {
      state = state.copyWith(
        phase: RepositorySessionPhase.error,
        isFetchRunning: false,
        isDiffLoading: false,
        message: _friendlyError(error),
        technicalDetails: _technicalDetails(error, stackTrace),
      );
      return false;
    }
    final hasRemote = options.fetchAllRemotes
        ? remoteNames.isNotEmpty
        : normalizedRemote.isNotEmpty && remoteNames.contains(normalizedRemote);
    if (!hasRemote) return false;
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
        run: (environment) => _writer.fetch(
          repository,
          options: options,
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
      // `fetch --all` can update an earlier remote before a later remote
      // fails or cancellation reaches Git. Refresh to expose completed refs.
      await refresh();
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

  /// Reads a configured remote URL for the pull dialog with credentials
  /// redacted before it reaches UI state.
  /// 中文：读取拉取对话框所需的远端地址，并在返回前脱敏凭据。
  Future<String?> readRemoteUrl(String remoteName) async {
    final repository = state.repository;
    if (repository == null) return null;
    final url = await _reader.readRemoteUrl(repository, remoteName: remoteName);
    return url == null ? null : _redactSensitiveText(url);
  }

  /// 中文：读取当前仓库已配置的远端名称，供显式的拉取和推送面板选择。
  ///
  /// English: Reads configured remote names for explicit pull and push dialog
  /// selection in the current repository.
  Future<List<String>> readRemoteNames() async {
    final repository = state.repository;
    if (repository == null) return const [];
    return _reader.readRemoteNames(repository);
  }

  /// Removes one configured remote after verifying it still exists, then
  /// reloads all repository state from Git.
  ///
  /// 中文：确认远端仍存在后移除其本地配置，并重新从 Git 读取完整仓库状态。
  Future<bool> removeRemote(String remoteName) async {
    final repository = state.repository;
    final normalizedName = remoteName.trim();
    if (repository == null ||
        normalizedName.isEmpty ||
        state.operationState != GitRepositoryOperationState.none ||
        state.phase == RepositorySessionPhase.loading) {
      return false;
    }
    try {
      final remoteNames = await _reader.readRemoteNames(repository);
      if (!remoteNames.contains(normalizedName)) return false;
      await _writer.removeRemote(repository, normalizedName);
      await refresh();
      return state.phase == RepositorySessionPhase.ready;
    } on Object catch (error, stackTrace) {
      state = state.copyWith(
        phase: RepositorySessionPhase.error,
        isDiffLoading: false,
        message: _friendlyError(error),
        technicalDetails: _technicalDetails(error, stackTrace),
      );
      return false;
    }
  }

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

  /// Runs a configured pull from the Sourcetree-style dialog.
  /// 中文：按 Sourcetree 风格拉取对话框的配置执行拉取。
  Future<bool> pullWithOptions(GitPullOptions options) async {
    final repository = state.repository;
    final status = state.status;
    if (repository == null ||
        status == null ||
        state.phase == RepositorySessionPhase.loading) {
      return false;
    }
    List<String> remoteNames;
    try {
      remoteNames = await _reader.readRemoteNames(repository);
    } on Object catch (error, stackTrace) {
      state = state.copyWith(
        phase: RepositorySessionPhase.error,
        isPullRunning: false,
        isDiffLoading: false,
        message: _friendlyError(error),
        technicalDetails: _technicalDetails(error, stackTrace),
      );
      return false;
    }
    if (!remoteNames.contains(options.remoteName.trim())) return false;
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
        run: (environment) => _writer.pull(
          repository,
          options: options,
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
        message: succeeded ? '已拉取更新。' : state.message,
      );
      return succeeded;
    } on Object catch (error, stackTrace) {
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

  /// Continues the paused rebase after conflict fixes have been staged.
  /// 中文：暂存冲突修复后继续暂停的变基。
  Future<bool> continueRebase() => _finishPausedRebase(abort: false);

  /// Aborts the paused rebase and restores the pre-rebase state.
  /// 中文：中止暂停的变基并恢复变基前状态。
  Future<bool> abortRebase() => _finishPausedRebase(abort: true);

  Future<bool> _finishPausedRebase({required bool abort}) async {
    final repository = state.repository;
    if (repository == null ||
        state.operationState != GitRepositoryOperationState.rebase ||
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
        run: (environment) => abort
            ? _writer.abortRebase(
                repository,
                cancellationToken: cancellation,
                environment: environment,
              )
            : _writer.continueRebase(
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
        message: succeeded ? (abort ? '已中止变基。' : '已继续变基。') : state.message,
      );
      return succeeded;
    } on Object catch (error, stackTrace) {
      await refresh();
      final message =
          error is GitCommandException && error.kind == GitErrorKind.conflicts
          ? '变基仍有冲突。请解决冲突并暂存后继续，或选择中止变基。'
          : _friendlyError(error);
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

  /// 中文：推送当前分支到已配置目标；首次推送时创建同名远端分支，即使没有领先提交也允许打开 Sourcetree 风格的推送流程；异常结束后会验证远端是否已包含 HEAD。
  ///
  /// English: Pushes the current branch to its configured target, creating the
  /// matching remote branch on first push. The no-op case is allowed so the
  /// Sourcetree-style toolbar action remains clickable; uncertain outcomes are
  /// verified against the remote.
  Future<bool> pushUpstream() async {
    final repository = state.repository;
    final status = state.status;
    final branch = status?.branch;
    final detachedPushBranch = branch?.isDetached == true
        ? selectDetachedPushBranch(state)
        : null;
    final canPush =
        repository != null &&
        branch != null &&
        branch.objectId != null &&
        ((!branch.isDetached &&
                (branch.upstream != null || state.hasOriginRemote)) ||
            (branch.isDetached && detachedPushBranch != null));
    if (!canPush || state.phase == RepositorySessionPhase.loading) {
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
          localBranchName: detachedPushBranch?.name,
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
      final remoteContainsHead = await _verifyUncertainPush(
        repository,
        localBranchName: detachedPushBranch?.name,
      );
      await refresh();
      final message = remoteContainsHead
          ? '推送进程未正常完成，但远端已包含目标分支提交。请 Fetch 刷新 ahead/behind。'
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

  /// 中文：推送用户在面板中明确选择的分支映射，并可同时推送所有标签；完成后刷新 Git 状态。
  ///
  /// English: Pushes branch mappings explicitly selected in the panel and can
  /// include all tags; refreshes the Git-backed state after completion.
  Future<bool> pushWithOptions(GitPushOptions options) async {
    final repository = state.repository;
    final selectedLocalBranches = options.branches
        .map((branch) => branch.localBranch.trim())
        .toSet();
    if (repository == null ||
        state.phase == RepositorySessionPhase.loading ||
        (selectedLocalBranches.isEmpty && !options.pushTags) ||
        selectedLocalBranches.any((name) => name.isEmpty) ||
        !selectedLocalBranches.every(
          (name) => state.localBranches.any((branch) => branch.name == name),
        )) {
      return false;
    }
    final remoteNames = await _reader.readRemoteNames(repository);
    if (!remoteNames.contains(options.remoteName.trim())) return false;

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
        run: (environment) => _writer.pushBranches(
          repository,
          options: options,
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
        message: succeeded ? '已推送所选引用。' : state.message,
      );
      return succeeded;
    } on Object catch (error, stackTrace) {
      await refresh();
      final message = _friendlyError(error);
      state = state.copyWith(
        phase: RepositorySessionPhase.error,
        isPushRunning: false,
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
  Future<bool> _verifyUncertainPush(
    GitRepository repository, {
    String? localBranchName,
  }) async {
    final cancellation = GitCancellationToken();
    _pushVerificationCancellation = cancellation;
    try {
      return await _writer.verifyUpstream(
        repository,
        localBranchName: localBranchName,
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

  /// 中文：浏览左侧引用；选择分支会定位到分支尖端并加载该提交的文件改动，
  /// 选择工作区则恢复未提交文件状态。该操作不会切换当前检出的分支。
  ///
  /// English: Browses a sidebar ref. Branches focus their tip commit and load
  /// its changed files, while the workspace restores uncommitted changes. This
  /// never checks out a branch.
  Future<void> selectReference(RepositoryRefViewData reference) async {
    if (state.repository == null) return;
    if (reference.kind == RepositoryRefKind.workspace) {
      _commitGeneration++;
      _commitDiffGeneration++;
      state = state.copyWith(
        selectedRefId: 'workspace',
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
    }
    if (objectId == null || selectedRefId == null) return;

    state = state.copyWith(
      selectedRefId: selectedRefId,
      commits: _commitsWithoutStashPreviews(),
    );
    await selectCommit(objectId);
  }

  /// 中文：更新当前选择。
  /// English: Updates the current selection.
  Future<void> selectCommit(String objectId) async {
    final repository = state.repository;
    if (repository == null) return;
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

    if (!entry.path.isValidUtf8) {
      state = state.copyWith(isDiffLoading: false);
      return;
    }

    try {
      final diff = change.kind == RepositoryChangeKind.untracked
          ? await _reader.readUntrackedFileDiff(
              repository,
              path: entry.path.display,
            )
          : await _reader.readUnifiedDiff(
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
      if (state.phase != RepositorySessionPhase.ready) return;
      final refreshedStatus = state.status;
      if (refreshedStatus == null) return;
      final shouldBeStaged = !change.isStaged;
      for (final refreshedEntry in refreshedStatus.entries) {
        if (refreshedEntry.path.display != change.path) continue;
        final refreshedChange = _changeAfterStageToggle(
          refreshedEntry,
          isStaged: shouldBeStaged,
        );
        if (refreshedChange != null) {
          await selectChange(refreshedChange);
        }
        break;
      }
    } on Object catch (error, stackTrace) {
      state = state.copyWith(
        phase: RepositorySessionPhase.error,
        message: _friendlyError(error),
        technicalDetails: '$error\n$stackTrace',
      );
    }
  }

  /// 中文：批量切换文件组的暂存状态，一次刷新工作区。
  /// English: Stages or unstages a whole change group and refreshes once.
  Future<void> toggleStageGroup(
    List<RepositoryChangeViewData> changes, {
    required bool stage,
  }) async {
    final repository = state.repository;
    final status = state.status;
    if (repository == null ||
        status == null ||
        state.phase == RepositorySessionPhase.loading) {
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

    state = state.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
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
      await refresh();
    } on Object catch (error, stackTrace) {
      state = state.copyWith(
        phase: RepositorySessionPhase.error,
        message: _friendlyError(error),
        technicalDetails: '$error\n$stackTrace',
      );
    }
  }

  /// Executes one explicit conflict-resolution action for an unmerged file.
  /// 中文：对一个未合并文件执行明确选择的冲突解决操作，并刷新文件与 Diff 状态。
  Future<bool> resolveConflict(
    RepositoryChangeViewData change,
    RepositoryConflictAction action,
  ) async {
    if (action == RepositoryConflictAction.launchInternalDiffTool) {
      return false;
    }
    final repository = state.repository;
    final status = state.status;
    if (repository == null ||
        status == null ||
        state.phase == RepositorySessionPhase.loading) {
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

    state = state.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    try {
      switch (action) {
        case RepositoryConflictAction.launchInternalDiffTool:
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

  /// 中文：为内部 Diff 读取选中冲突文件的各个 Git 阶段与工作区内容。
  ///
  /// English: Reads the Git stages and work-tree result for the selected
  /// conflicted file shown by the internal Diff.
  Future<GitConflictFileVersions?> readConflictVersions(
    RepositoryChangeViewData change,
  ) async {
    final repository = state.repository;
    final status = state.status;
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
      state = state.copyWith(
        phase: RepositorySessionPhase.error,
        message: _friendlyError(error),
        technicalDetails: '$error\n$stackTrace',
      );
      return null;
    }
  }

  /// 中文：保存内部 Diff 的自定义合并结果，暂存文件并刷新冲突状态。
  ///
  /// English: Saves a custom internal-Diff merge result, stages the file, and
  /// refreshes conflict state.
  Future<bool> resolveConflictWithContent(
    RepositoryChangeViewData change,
    String content,
  ) async {
    final repository = state.repository;
    final status = state.status;
    if (repository == null ||
        status == null ||
        state.phase == RepositorySessionPhase.loading) {
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

    state = state.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    try {
      await _writer.resolveConflictWithContent(repository, entry.path, content);
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

  /// Commits exactly the files currently staged in the repository index, or
  /// amends the current HEAD when [amend] is true.
  ///
  /// Returns whether Git created the commit and the following refresh finished
  /// successfully. Git hooks are intentionally allowed to run.
  /// 中文：创建所需的对象或资源。
  /// English: Creates the required object or resource.
  Future<bool> createCommit(String message, {bool amend = false}) async {
    final repository = state.repository;
    final status = state.status;
    if (repository == null ||
        status == null ||
        (!amend && status.stagedEntries.isEmpty) ||
        (amend && status.branch.objectId == null) ||
        state.phase == RepositorySessionPhase.loading ||
        state.operationState != GitRepositoryOperationState.none) {
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
      await _writer.createCommit(repository, message: message, amend: amend);
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

  /// Reads the current stash reflog for the management dialog. This is
  /// read-only and deliberately does not change the active work-tree view.
  ///
  /// 中文：读取当前贮藏列表供管理面板展示，不改变工作区或当前提交选择。
  Future<List<GitStashEntry>> readStashes() async {
    final repository = state.repository;
    if (repository == null) return const [];
    return _reader.readStashes(repository);
  }

  /// Saves eligible working-tree changes in a new stash and refreshes all
  /// Git-backed state after Git completes.
  ///
  /// 中文：将可保存的改动创建为新贮藏；可选择包含未跟踪文件或保留暂存区，
  /// 完成后重新读取 Git 状态。
  Future<bool> createStash(
    String message, {
    bool includeUntracked = false,
    bool keepIndex = false,
  }) async {
    final status = state.status;
    final hasTrackedChanges =
        status?.displayEntries.any(
          (entry) =>
              entry.kind != GitFileStatusKind.untracked &&
              (entry.hasStagedChange || entry.hasWorkTreeChange),
        ) ??
        false;
    final hasUntrackedChanges =
        status?.displayEntries.any(
          (entry) => entry.kind == GitFileStatusKind.untracked,
        ) ??
        false;
    if (!_canMutateStashes ||
        status == null ||
        status.conflictedEntries.isNotEmpty ||
        (!hasTrackedChanges && !(includeUntracked && hasUntrackedChanges))) {
      return false;
    }
    return _runStashMutation(
      successMessage: '已创建贮藏。',
      write: (repository, cancellation) => _writer.createStash(
        repository,
        message: message,
        includeUntracked: includeUntracked,
        keepIndex: keepIndex,
        cancellationToken: cancellation,
      ),
    );
  }

  /// Applies one stash while retaining it in Git's stash reflog.
  ///
  /// 中文：恢复指定贮藏并保留该条目；为避免覆盖本地改动，仅允许在干净工作区执行。
  Future<bool> applyStash(GitStashEntry stash) =>
      _restoreStash(stash, pop: false);

  /// Applies one stash and lets Git remove it only after a successful restore.
  ///
  /// 中文：恢复并弹出指定贮藏；若 Git 发生冲突，条目会保留以便用户继续恢复。
  Future<bool> popStash(GitStashEntry stash) => _restoreStash(stash, pop: true);

  /// Drops one stash after the presentation layer has obtained confirmation.
  ///
  /// 中文：删除指定贮藏；此方法只处理 Git 写入与状态刷新，确认由界面层负责。
  Future<bool> dropStash(GitStashEntry stash) async {
    if (!_canMutateStashes || !await _isCurrentStash(stash)) return false;
    return _runStashMutation(
      successMessage: '已删除贮藏。',
      write: (repository, cancellation) => _writer.dropStash(
        repository,
        stashReference: stash.reference,
        cancellationToken: cancellation,
      ),
    );
  }

  /// 中文：判断当前仓库是否允许安全开始一项贮藏写操作。
  /// English: Returns whether the current repository can safely start a stash
  /// mutation.
  bool get _canMutateStashes {
    final repository = state.repository;
    return repository != null &&
        repository.workTreeRoot != null &&
        state.phase != RepositorySessionPhase.loading &&
        state.operationState == GitRepositoryOperationState.none;
  }

  /// 中文：在干净工作区恢复或弹出指定贮藏，并把冲突状态交还给 Git 和刷新流程。
  /// English: Restores or pops one stash only on a clean work tree, leaving
  /// conflict state to Git and the subsequent refresh.
  Future<bool> _restoreStash(GitStashEntry stash, {required bool pop}) async {
    final status = state.status;
    if (!_canMutateStashes ||
        status == null ||
        !status.isClean ||
        status.conflictedEntries.isNotEmpty ||
        !await _isCurrentStash(stash)) {
      return false;
    }
    return _runStashMutation(
      successMessage: pop ? '已恢复并弹出贮藏。' : '已恢复贮藏。',
      conflictMessage: pop
          ? '恢复贮藏时发生冲突；贮藏已保留，请解决冲突后继续。'
          : '恢复贮藏时发生冲突；贮藏仍已保留，请解决冲突后继续。',
      write: (repository, cancellation) => pop
          ? _writer.popStash(
              repository,
              stashReference: stash.reference,
              cancellationToken: cancellation,
            )
          : _writer.applyStash(
              repository,
              stashReference: stash.reference,
              cancellationToken: cancellation,
            ),
    );
  }

  /// 中文：确认贮藏列表在用户确认后仍指向同一个 Git 对象，避免 reflog
  /// 索引因外部操作变化而误作用于其他贮藏。
  /// English: Confirms that a stash selector still resolves to the same Git
  /// object after user confirmation, protecting against reflog index shifts.
  Future<bool> _isCurrentStash(GitStashEntry expected) async {
    final repository = state.repository;
    if (repository == null) return false;
    try {
      final stashes = await _reader.readStashes(repository);
      final matches = stashes.any(
        (stash) =>
            stash.reference == expected.reference &&
            stash.objectId == expected.objectId,
      );
      if (matches) return true;
    } on Object {
      // Surface the same stale-list guidance below; a reader failure also
      // means it is unsafe to operate on a positional stash reference.
    }
    state = state.copyWith(
      phase: RepositorySessionPhase.error,
      isStashRunning: false,
      message: '贮藏列表已发生变化，请重新打开管理面板后再操作。',
    );
    return false;
  }

  /// 中文：串行执行一项贮藏写操作，确保完成、失败或取消后均重新读取 Git 状态。
  /// English: Runs one stash mutation and refreshes Git-backed state after
  /// success, failure, or cancellation.
  Future<bool> _runStashMutation({
    required String successMessage,
    String? conflictMessage,
    required Future<void> Function(GitRepository, GitCancellationToken) write,
  }) async {
    final repository = state.repository;
    if (repository == null) return false;
    final cancellation = GitCancellationToken();
    _stashCancellation = cancellation;
    final operation = _startOperation(RepositoryOperationKind.stash);
    state = state.copyWith(
      phase: RepositorySessionPhase.loading,
      isStashRunning: true,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    try {
      await write(repository, cancellation);
      await refresh();
      final succeeded = state.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.failed,
        message: succeeded ? successMessage : state.message,
      );
      return succeeded;
    } on Object catch (error, stackTrace) {
      // `stash apply` and `stash pop` can leave conflict entries even though
      // Git returns an error. Refresh before showing the failure so the user
      // always sees the actual Git state and a recovery path.
      await refresh();
      final message =
          error is GitCommandException &&
              error.kind == GitErrorKind.conflicts &&
              conflictMessage != null
          ? conflictMessage
          : _friendlyError(error);
      state = state.copyWith(
        phase: RepositorySessionPhase.error,
        isStashRunning: false,
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
      if (identical(_stashCancellation, cancellation)) {
        _stashCancellation = null;
      }
    }
  }

  /// 中文：取消当前贮藏操作；进程结束后会刷新仓库状态。
  /// English: Cancels the active stash process; repository state is refreshed
  /// once the process exits.
  void cancelStash() => _stashCancellation?.cancel();

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

  /// 中文：以历史中的指定提交为起点创建本地分支，可在上层随后选择检出。
  ///
  /// English: Creates a local branch at a loaded historical commit; callers
  /// may switch to it after creation when the user requested checkout.
  Future<bool> createLocalBranchFromCommit(String name, String objectId) async {
    final repository = state.repository;
    final status = state.status;
    if (repository == null ||
        status == null ||
        status.branch.isUnborn ||
        state.phase == RepositorySessionPhase.loading ||
        !state.commits.any((commit) => commit.objectId == objectId)) {
      return false;
    }
    if (name.trim().isEmpty || objectId.trim().isEmpty) {
      throw ArgumentError('A branch name and commit are required.');
    }

    state = state.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    try {
      await _writer.createLocalBranchFromCommit(
        repository,
        name: name,
        objectId: objectId,
      );
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

  /// 中文：以已加载的本地分支为起点创建另一个本地分支，不切换当前工作区。
  ///
  /// English: Creates a local branch from an already loaded local branch
  /// without switching the current work tree.
  Future<bool> createLocalBranchFromLocalBranch(
    String name,
    String sourceName,
  ) async {
    final repository = state.repository;
    final status = state.status;
    if (repository == null ||
        status == null ||
        status.branch.isUnborn ||
        state.phase == RepositorySessionPhase.loading ||
        !state.localBranches.any((branch) => branch.name == sourceName)) {
      return false;
    }
    if (name.trim().isEmpty || sourceName.trim().isEmpty) {
      throw ArgumentError('A branch name and source branch are required.');
    }

    state = state.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    try {
      await _writer.createLocalBranchFromLocalBranch(
        repository,
        name: name,
        sourceName: sourceName,
      );
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

  /// Switches to a local branch while preserving safe working-tree changes.
  /// 中文：切换到本地分支；保留可安全携带的工作区改动，并拒绝冲突状态。
  /// English: Switches to a local branch, preserving changes Git can carry
  /// safely and rejecting repositories with unresolved conflicts.
  Future<bool> switchToLocalBranch(String name) async {
    final repository = state.repository;
    final status = state.status;
    if (repository == null ||
        status == null ||
        status.conflictedEntries.isNotEmpty ||
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

  /// Checks out a commit in detached HEAD mode, letting Git reject conflicts.
  /// 中文：以分离 HEAD 模式检出提交，由 Git 拒绝会覆盖本地改动的情况。
  Future<bool> checkoutCommit(String objectId) async {
    final repository = state.repository;
    final status = state.status;
    if (repository == null ||
        status == null ||
        state.phase == RepositorySessionPhase.loading) {
      return false;
    }
    final normalizedId = objectId.trim();
    if (normalizedId.isEmpty) return false;

    state = state.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    try {
      await _writer.checkoutCommit(repository, objectId: normalizedId);
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

  /// 中文：仅在工作区干净且分支仍被加载时重命名本地分支，不允许覆盖已有分支。
  ///
  /// English: Renames a loaded local branch only with a clean work tree and
  /// never allows Git to overwrite an existing branch.
  Future<bool> renameLocalBranch(String oldName, String newName) async {
    final repository = state.repository;
    final status = state.status;
    if (repository == null ||
        status == null ||
        !status.isClean ||
        state.phase == RepositorySessionPhase.loading ||
        !state.localBranches.any((branch) => branch.name == oldName)) {
      return false;
    }
    if (oldName.trim().isEmpty || newName.trim().isEmpty) {
      throw ArgumentError('Both the old and new branch names are required.');
    }
    if (oldName == newName) return true;

    state = state.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    try {
      await _writer.renameLocalBranch(
        repository,
        oldName: oldName,
        newName: newName,
      );
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

  /// 中文：仅删除已加载且非当前的本地分支；Git 会拒绝删除尚未合并的提交。
  ///
  /// English: Deletes only a loaded, non-current local branch; Git refuses to
  /// delete a branch whose commits are not safely merged.
  Future<bool> deleteMergedLocalBranch(String name) async {
    return deleteBranches(localBranchNames: [name]);
  }

  /// 中文：删除用户在分支面板中明确选择的本地和远端分支；本地强制删除必须已由界面确认。
  ///
  /// English: Deletes local and remote branches explicitly selected in the
  /// branch panel. Local force deletion must already have user confirmation.
  Future<bool> deleteBranches({
    List<String> localBranchNames = const [],
    List<String> remoteBranchNames = const [],
    bool forceLocal = false,
  }) async {
    final repository = state.repository;
    final status = state.status;
    final currentBranch = status?.branch.head;
    final localNames = localBranchNames.map((name) => name.trim()).toSet();
    final remoteNames = remoteBranchNames.map((name) => name.trim()).toSet();
    if (repository == null ||
        status == null ||
        state.phase == RepositorySessionPhase.loading ||
        localNames.isEmpty && remoteNames.isEmpty) {
      return false;
    }
    if (localNames.any((name) => name.isEmpty) ||
        remoteNames.any((name) => name.isEmpty) ||
        localNames.contains(currentBranch) ||
        !localNames.every(
          (name) => state.localBranches.any((branch) => branch.name == name),
        ) ||
        !remoteNames.every(
          (name) => state.remoteBranches.any((branch) => branch.name == name),
        ) ||
        (localNames.isNotEmpty && !status.isClean)) {
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
      for (final name in localNames) {
        await _writer.deleteLocalBranch(
          repository,
          name: name,
          force: forceLocal,
        );
      }
      for (final name in remoteNames) {
        await _writer.deleteRemoteBranch(repository, remoteName: name);
      }
      await refresh();
      return state.phase == RepositorySessionPhase.ready;
    } on Object catch (error, stackTrace) {
      // Earlier selected branches may already have been deleted before a later
      // local or remote deletion fails. Refresh so the UI never keeps stale
      // refs after a partially completed batch.
      await refresh();
      state = state.copyWith(
        phase: RepositorySessionPhase.error,
        isDiffLoading: false,
        message: _friendlyError(error),
        technicalDetails: '$error\n$stackTrace',
      );
      return false;
    }
  }

  /// 中文：将指定本地分支合并到当前分支；来源不是当前分支、来源已加载且当前没有未解决冲突时执行。
  /// 普通未提交改动的兼容性由 Git 判断，避免在界面层过早禁用操作。
  /// 合并冲突会保留在仓库中并刷新为可见冲突状态，但不会自动继续或中止。
  ///
  /// English: Merges a loaded local source branch into the current branch when
  /// it is distinct from the current branch and no unresolved conflicts exist.
  /// Git determines whether ordinary working-tree changes are compatible.
  /// Merge conflicts remain in the repository and are refreshed for display;
  /// they are never continued or aborted automatically.
  Future<bool> mergeLocalBranch(String sourceName) async {
    final repository = state.repository;
    final status = state.status;
    final currentBranch = status?.branch.head;
    if (repository == null ||
        status == null ||
        currentBranch == null ||
        status.conflictedEntries.isNotEmpty ||
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
