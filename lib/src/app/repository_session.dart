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

  bool matches(RepositoryChangeViewData change) {
    return entry.path.display == change.path && isStaged == change.isStaged;
  }
}

final class SelectedCommitFile {
  const SelectedCommitFile({required this.objectId, required this.file});

  final String objectId;
  final GitCommitFileChange file;

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

  RepositorySessionState copyWith({
    RepositorySessionPhase? phase,
    String? requestedPath,
    GitRepository? repository,
    GitStatusSnapshot? status,
    bool? hasOriginRemote,
    List<GitLocalBranch>? localBranches,
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

  @override
  RepositorySessionState build() {
    _runner = ref.watch(gitRunnerProvider);
    _inspector = ref.watch(gitRepositoryInspectorProvider);
    _reader = ref.watch(gitRepositoryReaderProvider);
    _writer = ref.watch(gitRepositoryWriterProvider);
    _sessionStore = ref.watch(repositorySessionStoreProvider);
    return const RepositorySessionState.empty();
  }

  /// Restores the last successfully opened repositories without retaining any
  /// Git credentials or operation state. Missing or invalid paths are dropped.
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

  RepositoryOperationOutcome _operationOutcomeForError(Object error) {
    return error is GitCancelledException ||
            (error is GitCommandException &&
                error.kind == GitErrorKind.cancelled)
        ? RepositoryOperationOutcome.cancelled
        : RepositoryOperationOutcome.failed;
  }

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
        _reader.readRecentHistory(repository),
        _readGitVersion(),
      ]);
      if (generation != _repositoryGeneration) {
        return;
      }

      final status = results[0] as GitStatusSnapshot;
      final hasOriginRemote = results[1] as bool;
      final localBranches = results[2] as List<GitLocalBranch>;
      final commits = results[3] as List<GitCommit>;
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
        gitVersion: results[4] as String,
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

  void cancelClone() => _cloneCancellation?.cancel();

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

  void cancelFetch() => _fetchCancellation?.cancel();

  /// Pulls the configured upstream only into a clean working tree and index.
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

  void cancelPull() => _pullCancellation?.cancel();

  /// Pushes only an ahead portion of the current branch to its upstream.
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

  void cancelPush() {
    _pushCancellation?.cancel();
    _pushVerificationCancellation?.cancel();
  }

  /// Enables AskPass only for an explicit remote operation. All repository
  /// inspection, refresh and post-push verification invocations keep the
  /// default non-interactive environment.
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

  Future<void> refresh() async {
    final path = state.requestedPath ?? state.repository?.commandDirectory;
    if (path != null) {
      await openRepository(path);
    }
  }

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

  Future<void> selectCommitFile(CommitFileViewData? change) async {
    await selectCommitFileByPath(change?.path);
  }

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

  void setSearchQuery(String query) {
    state = state.copyWith(searchQuery: query);
  }

  String? _parentObjectId(String objectId) {
    for (final commit in state.commits) {
      if (commit.objectId == objectId) return commit.parentIds.firstOrNull;
    }
    return null;
  }

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

  String _technicalDetails(Object error, StackTrace stackTrace) =>
      _redactSensitiveText('$error\n$stackTrace');

  String _redactSensitiveText(String text) => redactGitSensitiveText(text);
}
