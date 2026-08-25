import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path_utils;

import '../git/git.dart';
import 'repository_session.dart';
import 'repository_session_store.dart';

/// The persistent repository library owned by the home-window Engine.
///
/// 中文：首页窗口持有的持久化仓库清单。
final repositoryLibraryProvider =
    NotifierProvider<RepositoryLibraryController, RepositoryLibraryState>(
      RepositoryLibraryController.new,
    );

/// Persists the non-sensitive repository list between application launches.
///
/// 中文：在应用重启后持久化非敏感的仓库清单。
final repositorySessionStoreProvider = Provider<RepositorySessionStore>(
  (Ref ref) => FileRepositorySessionStore(),
);

/// The result of adding a directory to the repository library.
///
/// 中文：向首页仓库清单添加目录后的结果。
enum RepositoryLibraryRegistrationResult {
  added,
  alreadyRegistered,
  notRepository,
  failed,
}

/// One Git repository displayed in the persistent home-window library.
///
/// 中文：首页持久化仓库清单中的一个 Git 仓库条目。
final class RepositoryTab {
  const RepositoryTab({
    required this.path,
    required this.label,
    String? baseLabel,
    this.branchName,
    this.changedFileCount = 0,
    this.isDetached = false,
    this.isUnborn = false,
    this.hasStatus = false,
  }) : baseLabel = baseLabel ?? label;

  /// Absolute Git command directory used to reopen this repository.
  final String path;

  /// Human-readable name after duplicate-name disambiguation.
  final String label;

  /// Repository directory name before duplicate-name disambiguation.
  final String baseLabel;

  /// Current local branch name reported by Git, when status is available.
  final String? branchName;

  /// Number of files with staged, unstaged, or untracked changes.
  final int changedFileCount;

  /// Whether the repository is currently checked out at a detached HEAD.
  final bool isDetached;

  /// Whether the current branch has not received its first commit.
  final bool isUnborn;

  /// Whether the branch and change summary was successfully read from Git.
  final bool hasStatus;
}

/// Immutable state for the repository home window.
///
/// 中文：首页窗口的不可变仓库清单状态。
final class RepositoryLibraryState {
  const RepositoryLibraryState({
    this.repositories = const <RepositoryTab>[],
    this.activeRepositoryPath,
  });

  final List<RepositoryTab> repositories;
  final String? activeRepositoryPath;

  RepositoryLibraryState copyWith({
    List<RepositoryTab>? repositories,
    String? activeRepositoryPath,
    bool clearActiveRepositoryPath = false,
  }) => RepositoryLibraryState(
    repositories: repositories ?? this.repositories,
    activeRepositoryPath: clearActiveRepositoryPath
        ? null
        : activeRepositoryPath ?? this.activeRepositoryPath,
  );
}

/// Separates home-window repository registration and persistence from the
/// active workspace's Git session.
///
/// 中文：将首页仓库登记与持久化同当前工作区 Git 会话分离。
///
/// English: Owns the home-window repository list, its lightweight Git status
/// reads, and session-file persistence. It never opens a workspace or reads
/// history and Diff data, which remain the workspace controller's responsibility.
final class RepositoryLibraryController
    extends Notifier<RepositoryLibraryState> {
  late GitRepositoryInspector _inspector;
  late GitRepositoryReader _reader;
  late RepositorySessionStore _store;
  Future<void> _writeTail = Future<void>.value();
  var _isRestoring = false;
  var _persistenceEnabled = false;

  @override
  RepositoryLibraryState build() {
    _inspector = ref.watch(gitRepositoryInspectorProvider);
    _reader = ref.watch(gitRepositoryReaderProvider);
    _store = ref.watch(repositorySessionStoreProvider);
    return const RepositoryLibraryState();
  }

  /// Restores known repositories for the home window without opening a
  /// workspace or reading its history.
  ///
  /// 中文：首页窗口恢复已知仓库，但不打开工作区、不读取历史记录。
  Future<void> restore() async {
    if (_isRestoring || _persistenceEnabled) return;
    _isRestoring = true;
    _persistenceEnabled = true;
    try {
      final snapshot = await _store.load();
      if (!ref.mounted) return;
      for (final path in snapshot.openRepositoryPaths) {
        await _add(path, persist: false);
        if (!ref.mounted) return;
      }
      final activePath = snapshot.activeRepositoryPath;
      if (activePath != null &&
          state.repositories.any(
            (repository) => repository.path == activePath,
          )) {
        state = state.copyWith(activeRepositoryPath: activePath);
      }
    } finally {
      _isRestoring = false;
      if (ref.mounted) _persist();
    }
  }

  /// Inspects one directory and records its Git root in the home-window list.
  ///
  /// 中文：检查一个目录，并将其 Git 根目录登记到首页清单。
  Future<RepositoryLibraryRegistrationResult> add(String directoryPath) =>
      _add(directoryPath, persist: true);

  Future<RepositoryLibraryRegistrationResult> _add(
    String directoryPath, {
    required bool persist,
  }) async {
    final normalizedPath = directoryPath.trim();
    if (normalizedPath.isEmpty) {
      return RepositoryLibraryRegistrationResult.notRepository;
    }
    try {
      final repository = await _inspector.inspect(normalizedPath);
      if (repository == null) {
        return RepositoryLibraryRegistrationResult.notRepository;
      }
      final inspectedTab = _repositoryTab(
        repository,
        status: await _tryReadRepositoryStatus(repository),
      );
      if (!ref.mounted) return RepositoryLibraryRegistrationResult.failed;
      final existingTab = state.repositories
          .where((item) => item.path == inspectedTab.path)
          .firstOrNull;
      final tab = existingTab != null && !inspectedTab.hasStatus
          ? existingTab
          : inspectedTab;
      final existing = existingTab != null;
      final nextRepositories = _disambiguateLabels([
        for (final item in state.repositories)
          if (item.path == tab.path) tab else item,
        if (!existing) tab,
      ]);
      state = state.copyWith(repositories: nextRepositories);
      if (persist) _persist();
      return existing
          ? RepositoryLibraryRegistrationResult.alreadyRegistered
          : RepositoryLibraryRegistrationResult.added;
    } on Object {
      return RepositoryLibraryRegistrationResult.failed;
    }
  }

  /// Reorders a complete, duplicate-free repository path sequence.
  ///
  /// 中文：按完整且无重复的仓库路径序列重排首页清单。
  void reorder(List<String> repositoryPaths) {
    if (repositoryPaths.length != state.repositories.length ||
        repositoryPaths.toSet().length != repositoryPaths.length) {
      return;
    }
    final byPath = <String, RepositoryTab>{
      for (final tab in state.repositories) tab.path: tab,
    };
    if (!repositoryPaths.every(byPath.containsKey)) return;
    state = state.copyWith(
      repositories: _disambiguateLabels([
        for (final path in repositoryPaths) byPath[path]!,
      ]),
    );
    _persist();
  }

  /// Records the last repository selected from the home window.
  ///
  /// 中文：记录最近一次从首页选择的仓库。
  void select(String repositoryPath) {
    if (!state.repositories.any((tab) => tab.path == repositoryPath)) return;
    if (state.activeRepositoryPath == repositoryPath) return;
    state = state.copyWith(activeRepositoryPath: repositoryPath);
    _persist();
  }

  /// Converts a Git repository and its recent status into one library entry.
  ///
  /// 中文：将 Git 仓库及其最近状态转换为一个首页清单条目。
  RepositoryTab _repositoryTab(
    GitRepository repository, {
    GitStatusSnapshot? status,
  }) {
    final branch = status?.branch;
    return RepositoryTab(
      path: repository.commandDirectory,
      label: path_utils.basename(
        repository.workTreeRoot ?? repository.commonDirectory,
      ),
      branchName: branch?.head,
      changedFileCount: status?.entries.length ?? 0,
      isDetached: branch?.isDetached ?? false,
      isUnborn: branch?.isUnborn ?? false,
      hasStatus: status != null,
    );
  }

  Future<GitStatusSnapshot?> _tryReadRepositoryStatus(
    GitRepository repository,
  ) async {
    try {
      return await _reader.readStatus(repository);
    } on Object {
      return null;
    }
  }

  List<RepositoryTab> _disambiguateLabels(List<RepositoryTab> tabs) {
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
          branchName: tab.branchName,
          changedFileCount: tab.changedFileCount,
          isDetached: tab.isDetached,
          isUnborn: tab.isUnborn,
          hasStatus: tab.hasStatus,
        ),
    ]);
  }

  void _persist() {
    if (!_persistenceEnabled || _isRestoring) return;
    final snapshot = RepositorySessionSnapshot(
      openRepositoryPaths: List<String>.unmodifiable(
        state.repositories.map((repository) => repository.path),
      ),
      activeRepositoryPath: state.activeRepositoryPath,
    );
    _writeTail = _writeTail.then((_) async {
      try {
        await _store.save(snapshot);
      } on Object {
        // A preference write must not turn a valid repository registration
        // into an application error.
      }
    });
  }
}
