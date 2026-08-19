import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../git/git.dart';
import '../presentation/presentation.dart';

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

final repositorySessionProvider =
    NotifierProvider<RepositorySessionController, RepositorySessionState>(
      RepositorySessionController.new,
    );

enum RepositorySessionPhase { empty, loading, ready, error }

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
    this.selectedChange,
    this.diff,
    this.isDiffLoading = false,
    this.isCloneRunning = false,
    this.isFetchRunning = false,
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
  final SelectedRepositoryChange? selectedChange;
  final GitUnifiedDiff? diff;
  final bool isDiffLoading;
  final bool isCloneRunning;
  final bool isFetchRunning;
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
    SelectedRepositoryChange? selectedChange,
    GitUnifiedDiff? diff,
    bool? isDiffLoading,
    bool? isCloneRunning,
    bool? isFetchRunning,
    String? searchQuery,
    String? gitVersion,
    String? message,
    String? technicalDetails,
    bool clearSelectedChange = false,
    bool clearDiff = false,
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
      selectedChange: clearSelectedChange
          ? null
          : selectedChange ?? this.selectedChange,
      diff: clearDiff ? null : diff ?? this.diff,
      isDiffLoading: isDiffLoading ?? this.isDiffLoading,
      isCloneRunning: isCloneRunning ?? this.isCloneRunning,
      isFetchRunning: isFetchRunning ?? this.isFetchRunning,
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
  int _repositoryGeneration = 0;
  int _diffGeneration = 0;
  GitCancellationToken? _cloneCancellation;
  GitCancellationToken? _fetchCancellation;

  @override
  RepositorySessionState build() {
    _runner = ref.watch(gitRunnerProvider);
    _inspector = ref.watch(gitRepositoryInspectorProvider);
    _reader = ref.watch(gitRepositoryReaderProvider);
    _writer = ref.watch(gitRepositoryWriterProvider);
    return const RepositorySessionState.empty();
  }

  Future<void> openRepository(String path) async {
    final normalizedPath = path.trim();
    if (normalizedPath.isEmpty) {
      return;
    }

    final generation = ++_repositoryGeneration;
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
      state = RepositorySessionState(
        phase: RepositorySessionPhase.ready,
        requestedPath: normalizedPath,
        repository: repository,
        status: status,
        hasOriginRemote: hasOriginRemote,
        localBranches: localBranches,
        commits: commits,
        selectedCommitId: commits.firstOrNull?.objectId,
        gitVersion: results[4] as String,
        searchQuery: state.searchQuery,
      );
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
      await _writer.cloneRepository(
        remoteUrl: remoteUrl,
        directoryPath: directoryPath,
        cancellationToken: cancellation,
      );
      await openRepository(directoryPath);
      return state.phase == RepositorySessionPhase.ready;
    } on Object catch (error, stackTrace) {
      final recovery = await _cloneRecoveryMessage(directoryPath);
      state = state.copyWith(
        phase: RepositorySessionPhase.error,
        isDiffLoading: false,
        isCloneRunning: false,
        message: recovery ?? _friendlyError(error),
        technicalDetails: _technicalDetails(error, stackTrace),
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
    state = state.copyWith(
      phase: RepositorySessionPhase.loading,
      isFetchRunning: true,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    try {
      await _writer.fetchOrigin(repository, cancellationToken: cancellation);
      await refresh();
      return state.phase == RepositorySessionPhase.ready;
    } on Object catch (error, stackTrace) {
      state = state.copyWith(
        phase: RepositorySessionPhase.error,
        isFetchRunning: false,
        isDiffLoading: false,
        message: _friendlyError(error),
        technicalDetails: _technicalDetails(error, stackTrace),
      );
      return false;
    } finally {
      if (identical(_fetchCancellation, cancellation)) {
        _fetchCancellation = null;
      }
    }
  }

  void cancelFetch() => _fetchCancellation?.cancel();

  Future<void> refresh() async {
    final path = state.requestedPath ?? state.repository?.commandDirectory;
    if (path != null) {
      await openRepository(path);
    }
  }

  void selectCommit(String objectId) {
    if (state.commits.any((GitCommit commit) => commit.objectId == objectId)) {
      state = state.copyWith(selectedCommitId: objectId);
    }
  }

  void setSearchQuery(String query) {
    state = state.copyWith(searchQuery: query);
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

  String _redactSensitiveText(String text) {
    final credentials = RegExp(
      r'([a-z][a-z0-9+.-]*://)([^/\s:@]+):([^@\s/]+)@',
      caseSensitive: false,
    );
    final token = RegExp(
      r'([?&](?:access_token|token|password)=)[^&\s]+',
      caseSensitive: false,
    );
    return text
        .replaceAllMapped(credentials, (match) => '${match[1]}***:***@')
        .replaceAllMapped(token, (match) => '${match[1]}***');
  }
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
