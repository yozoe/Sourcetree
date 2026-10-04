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
    this.isFavorite = false,
    this.workspaceGroup,
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

  /// Whether the user marked this repository as a favorite in the home window.
  /// 中文：首页用户是否将此仓库标记为收藏。
  final bool isFavorite;

  /// User-created home-window group containing this repository, if any.
  /// 中文：该仓库所属的首页用户分组；为空表示未分组。
  final String? workspaceGroup;

  /// Returns this tab with a changed favorite marker while preserving Git data.
  /// 中文：仅更新收藏标记，保留仓库状态和显示标签。
  RepositoryTab copyWithFavorite(bool favorite) => RepositoryTab(
    path: path,
    label: label,
    baseLabel: baseLabel,
    branchName: branchName,
    changedFileCount: changedFileCount,
    isDetached: isDetached,
    isUnborn: isUnborn,
    hasStatus: hasStatus,
    isFavorite: favorite,
    workspaceGroup: workspaceGroup,
  );

  /// Returns this tab with a changed user-group assignment.
  /// 中文：只更新首页用户分组归属，保留 Git 状态和显示标签。
  RepositoryTab copyWithWorkspaceGroup(String? group) => RepositoryTab(
    path: path,
    label: label,
    baseLabel: baseLabel,
    branchName: branchName,
    changedFileCount: changedFileCount,
    isDetached: isDetached,
    isUnborn: isUnborn,
    hasStatus: hasStatus,
    isFavorite: isFavorite,
    workspaceGroup: group,
  );
}

/// Immutable state for the repository home window.
///
/// 中文：首页窗口的不可变仓库清单状态。
final class RepositoryLibraryState {
  const RepositoryLibraryState({
    this.repositories = const <RepositoryTab>[],
    this.workspaceGroups = const <String>[],
    this.repositoryGroups = const <String, String>{},
    this.activeRepositoryPath,
    this.persistenceFailureCount = 0,
    this.persistenceError,
  });

  final List<RepositoryTab> repositories;
  final List<String> workspaceGroups;
  final Map<String, String> repositoryGroups;
  final String? activeRepositoryPath;
  final int persistenceFailureCount;
  final String? persistenceError;

  RepositoryLibraryState copyWith({
    List<RepositoryTab>? repositories,
    List<String>? workspaceGroups,
    Map<String, String>? repositoryGroups,
    String? activeRepositoryPath,
    bool clearActiveRepositoryPath = false,
    int? persistenceFailureCount,
    String? persistenceError,
    bool clearPersistenceError = false,
  }) => RepositoryLibraryState(
    repositories: repositories ?? this.repositories,
    workspaceGroups: workspaceGroups ?? this.workspaceGroups,
    repositoryGroups: repositoryGroups ?? this.repositoryGroups,
    activeRepositoryPath: clearActiveRepositoryPath
        ? null
        : activeRepositoryPath ?? this.activeRepositoryPath,
    persistenceFailureCount:
        persistenceFailureCount ?? this.persistenceFailureCount,
    persistenceError: clearPersistenceError
        ? null
        : persistenceError ?? this.persistenceError,
  );
}

/// A repository-library snapshot that could not be durably persisted.
///
/// 中文：仓库清单快照无法可靠写入持久化存储时抛出的异常。
final class RepositoryLibraryPersistenceException implements Exception {
  const RepositoryLibraryPersistenceException(this.cause);

  final Object cause;

  @override
  String toString() => 'Repository library persistence failed: $cause';
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
  Future<void> _mutationTail = Future<void>.value();
  var _isRestoring = false;
  var _persistenceEnabled = false;
  var _acceptsMutations = true;
  Object? _lastPersistenceError;
  final Set<String> _favoriteRepositoryPaths = <String>{};

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
    if (_isRestoring || _persistenceEnabled || !_acceptsMutations) return;
    await _enqueueMutation(() async {
      if (_isRestoring || _persistenceEnabled) return;
      _isRestoring = true;
      var restored = false;
      try {
        final snapshot = await _store.load();
        restored = true;
        _persistenceEnabled = true;
        _favoriteRepositoryPaths
          ..clear()
          ..addAll(snapshot.favoriteRepositoryPaths);
        final knownGroups = <String>[];
        final seenGroups = <String>{};
        for (final group in snapshot.workspaceGroups) {
          final normalizedGroup = group.trim();
          if (normalizedGroup.isNotEmpty && seenGroups.add(normalizedGroup)) {
            knownGroups.add(normalizedGroup);
          }
        }
        state = state.copyWith(
          workspaceGroups: List<String>.unmodifiable(knownGroups),
          repositoryGroups: const <String, String>{},
        );
        if (!ref.mounted) return;
        for (final path in snapshot.openRepositoryPaths) {
          final result = await _add(path, persist: false);
          if (!ref.mounted) return;
          if (result == RepositoryLibraryRegistrationResult.notRepository ||
              result == RepositoryLibraryRegistrationResult.failed) {
            _retainUnavailableRepository(path);
          }
        }
        final activePath = snapshot.activeRepositoryPath;
        if (activePath != null &&
            state.repositories.any(
              (repository) => repository.path == activePath,
            )) {
          state = state.copyWith(activeRepositoryPath: activePath);
        }
        final restoredAssignments = <String, String>{};
        for (final entry in snapshot.repositoryGroups.entries) {
          if (state.repositories.any((tab) => tab.path == entry.key) &&
              knownGroups.contains(entry.value)) {
            restoredAssignments[entry.key] = entry.value;
          }
        }
        state = state.copyWith(
          repositoryGroups: Map<String, String>.unmodifiable(
            restoredAssignments,
          ),
          repositories: _withRepositoryGroups(
            state.repositories,
            restoredAssignments,
          ),
        );
      } finally {
        _isRestoring = false;
        if (ref.mounted && restored) await _persist();
      }
    });
  }

  /// Waits until every repository-library snapshot queued by this Engine has
  /// reached persistent storage.
  ///
  /// 中文：等待当前 Engine 已排队的仓库清单快照全部完成持久化。
  Future<void> flushPendingWrites() async {
    await _writeTail;
    final error = _lastPersistenceError;
    if (error != null) throw RepositoryLibraryPersistenceException(error);
  }

  /// Stops accepting registrations, drains queued mutations, and verifies
  /// that the newest repository snapshot reached durable storage.
  ///
  /// 中文：停止接收新登记，等待已排队变更完成，并确认最新仓库快照已持久化。
  Future<void> prepareForShutdown() async {
    _acceptsMutations = false;
    await _mutationTail;
    await flushPendingWrites();
  }

  /// Inspects one directory and records its Git root in the home-window list.
  ///
  /// 中文：检查一个目录，并将其 Git 根目录登记到首页清单。
  Future<RepositoryLibraryRegistrationResult> add(String directoryPath) async {
    if (!_acceptsMutations) return RepositoryLibraryRegistrationResult.failed;
    var result = RepositoryLibraryRegistrationResult.failed;
    await _enqueueMutation(() async {
      result = await _add(directoryPath, persist: true);
    });
    return result;
  }

  /// Registers a workspace and does not acknowledge success until its newest
  /// library snapshot has reached persistent storage.
  ///
  /// 中文：登记工作区，并在最新仓库清单快照完成持久化后才确认成功。
  Future<RepositoryLibraryRegistrationResult> registerAndPersist(
    String directoryPath,
  ) async {
    if (!_acceptsMutations) return RepositoryLibraryRegistrationResult.failed;
    var result = RepositoryLibraryRegistrationResult.failed;
    await _enqueueMutation(() async {
      result = await _add(
        directoryPath,
        persist: true,
        waitForPersistence: true,
      );
    });
    return result;
  }

  Future<RepositoryLibraryRegistrationResult> _add(
    String directoryPath, {
    required bool persist,
    bool waitForPersistence = false,
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
          : inspectedTab
                .copyWithFavorite(
                  existingTab?.isFavorite ??
                      _favoriteRepositoryPaths.contains(inspectedTab.path),
                )
                .copyWithWorkspaceGroup(
                  existingTab?.workspaceGroup ??
                      state.repositoryGroups[inspectedTab.path],
                );
      final existing = existingTab != null;
      final nextRepositories = _disambiguateLabels([
        for (final item in state.repositories)
          if (item.path == tab.path) tab else item,
        if (!existing) tab,
      ]);
      state = state.copyWith(repositories: nextRepositories);
      if (persist) {
        // A failed automatic restore must not overwrite the old snapshot, but
        // an explicit user registration starts a new recoverable list.
        _persistenceEnabled = true;
        final persistence = _persist();
        if (waitForPersistence) {
          await persistence;
        } else {
          unawaited(persistence.catchError((_) {}));
        }
      }
      return existing
          ? RepositoryLibraryRegistrationResult.alreadyRegistered
          : RepositoryLibraryRegistrationResult.added;
    } on Object {
      return RepositoryLibraryRegistrationResult.failed;
    }
  }

  /// Serializes restore and registration so a late result cannot overwrite a
  /// newer library snapshot.
  ///
  /// 中文：串行执行恢复与登记，避免较晚完成的旧结果覆盖较新的仓库清单。
  Future<void> _enqueueMutation(Future<void> Function() mutation) {
    final queued = _mutationTail.then((_) => mutation());
    _mutationTail = queued.catchError((_) {});
    return queued;
  }

  /// Keeps a persisted path visible when its repository is temporarily
  /// unavailable, without pretending that Git status was read successfully.
  ///
  /// 中文：仓库暂时不可用时保留持久化路径，但不伪造已读取成功的 Git 状态。
  void _retainUnavailableRepository(String repositoryPath) {
    final normalizedPath = repositoryPath.trim();
    if (normalizedPath.isEmpty ||
        state.repositories.any((tab) => tab.path == normalizedPath)) {
      return;
    }
    final baseLabel = path_utils.basename(normalizedPath);
    state = state.copyWith(
      repositories: _disambiguateLabels([
        ...state.repositories,
        RepositoryTab(
          path: normalizedPath,
          label: baseLabel.isEmpty ? normalizedPath : baseLabel,
          baseLabel: baseLabel.isEmpty ? normalizedPath : baseLabel,
          isFavorite: _favoriteRepositoryPaths.contains(normalizedPath),
        ),
      ]),
    );
  }

  /// Reorders a complete, duplicate-free repository path sequence.
  ///
  /// 中文：按完整且无重复的仓库路径序列重排首页清单。
  void reorder(List<String> repositoryPaths) {
    if (!_acceptsMutations ||
        repositoryPaths.length != state.repositories.length ||
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
    unawaited(_persist().catchError((_) {}));
  }

  /// Records the last repository selected from the home window.
  ///
  /// 中文：记录最近一次从首页选择的仓库。
  void select(String repositoryPath) {
    if (!_acceptsMutations) return;
    if (!state.repositories.any((tab) => tab.path == repositoryPath)) return;
    if (state.activeRepositoryPath == repositoryPath) return;
    state = state.copyWith(activeRepositoryPath: repositoryPath);
    unawaited(_persist().catchError((_) {}));
  }

  /// Toggles a repository's favorite marker and persists the home-window state.
  /// 中文：切换仓库收藏标记并持久化；不会打开仓库或修改 Git 状态。
  void toggleFavorite(String repositoryPath) {
    if (!_acceptsMutations) return;
    final index = state.repositories.indexWhere(
      (repository) => repository.path == repositoryPath,
    );
    if (index < 0) return;
    final current = state.repositories[index];
    final favorite = !current.isFavorite;
    if (favorite) {
      _favoriteRepositoryPaths.add(repositoryPath);
    } else {
      _favoriteRepositoryPaths.remove(repositoryPath);
    }
    final repositories = [...state.repositories];
    repositories[index] = current.copyWithFavorite(favorite);
    state = state.copyWith(repositories: _disambiguateLabels(repositories));
    unawaited(_persist().catchError((_) {}));
  }

  /// Creates a named home-window workspace group and persists it.
  /// 中文：创建首页用户命名的工作区分组并持久化；不会改变 Git 状态。
  bool createWorkspaceGroup(String name) {
    if (!_acceptsMutations) return false;
    final normalizedName = name.trim();
    if (normalizedName.isEmpty ||
        state.workspaceGroups.contains(normalizedName)) {
      return false;
    }
    state = state.copyWith(
      workspaceGroups: List<String>.unmodifiable([
        ...state.workspaceGroups,
        normalizedName,
      ]),
    );
    unawaited(_persist().catchError((_) {}));
    return true;
  }

  /// Renames a home-window workspace group without moving its repositories.
  /// 中文：重命名首页工作区分组并保留其仓库归属，不修改 Git。
  bool renameWorkspaceGroup(String oldName, String newName) {
    if (!_acceptsMutations) return false;
    final from = oldName.trim();
    final to = newName.trim();
    if (from.isEmpty ||
        to.isEmpty ||
        !state.workspaceGroups.contains(from) ||
        (from != to && state.workspaceGroups.contains(to))) {
      return false;
    }
    final groups = [
      for (final group in state.workspaceGroups) group == from ? to : group,
    ];
    final assignments = {
      for (final entry in state.repositoryGroups.entries)
        entry.key: entry.value == from ? to : entry.value,
    };
    state = state.copyWith(
      workspaceGroups: List<String>.unmodifiable(groups),
      repositoryGroups: Map<String, String>.unmodifiable(assignments),
      repositories: _withRepositoryGroups(state.repositories, assignments),
    );
    unawaited(_persist().catchError((_) {}));
    return true;
  }

  /// Deletes a group and leaves its repositories ungrouped.
  /// 中文：删除首页工作区分组，仓库保留在清单中并回到未分组状态。
  bool deleteWorkspaceGroup(String name) {
    if (!_acceptsMutations) return false;
    final normalizedName = name.trim();
    if (!state.workspaceGroups.contains(normalizedName)) return false;
    state = state.copyWith(
      workspaceGroups: List<String>.unmodifiable(
        state.workspaceGroups.where((group) => group != normalizedName),
      ),
      repositoryGroups: Map<String, String>.unmodifiable({
        for (final entry in state.repositoryGroups.entries)
          if (entry.value != normalizedName) entry.key: entry.value,
      }),
      repositories: _withRepositoryGroups(state.repositories, {
        for (final entry in state.repositoryGroups.entries)
          if (entry.value != normalizedName) entry.key: entry.value,
      }),
    );
    unawaited(_persist().catchError((_) {}));
    return true;
  }

  /// Assigns a repository to a named group, or clears its assignment.
  /// 中文：把仓库移入指定首页分组；传入 null 会移回未分组。
  bool assignRepositoryToWorkspaceGroup(String repositoryPath, String? group) {
    if (!_acceptsMutations ||
        !state.repositories.any((tab) => tab.path == repositoryPath)) {
      return false;
    }
    final normalizedGroup = group?.trim();
    if (normalizedGroup != null &&
        !state.workspaceGroups.contains(normalizedGroup)) {
      return false;
    }
    final assignments = {...state.repositoryGroups};
    if (normalizedGroup == null || normalizedGroup.isEmpty) {
      assignments.remove(repositoryPath);
    } else {
      assignments[repositoryPath] = normalizedGroup;
    }
    state = state.copyWith(
      repositoryGroups: Map<String, String>.unmodifiable(assignments),
      repositories: _withRepositoryGroups(state.repositories, assignments),
    );
    unawaited(_persist().catchError((_) {}));
    return true;
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
      isFavorite: _favoriteRepositoryPaths.contains(
        repository.commandDirectory,
      ),
      workspaceGroup: state.repositoryGroups[repository.commandDirectory],
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
          isFavorite: tab.isFavorite,
          workspaceGroup: tab.workspaceGroup,
        ),
    ]);
  }

  /// Applies persisted user-group markers without changing repository order.
  /// 中文：把用户分组映射同步到条目，保持仓库顺序和 Git 状态不变。
  List<RepositoryTab> _withRepositoryGroups(
    List<RepositoryTab> tabs,
    Map<String, String> assignments,
  ) => _disambiguateLabels([
    for (final tab in tabs) tab.copyWithWorkspaceGroup(assignments[tab.path]),
  ]);

  Future<void> _persist() async {
    if (!_persistenceEnabled || _isRestoring) return;
    final snapshot = RepositorySessionSnapshot(
      openRepositoryPaths: List<String>.unmodifiable(
        state.repositories.map((repository) => repository.path),
      ),
      activeRepositoryPath: state.activeRepositoryPath,
      favoriteRepositoryPaths: List<String>.unmodifiable(
        state.repositories
            .where((repository) => repository.isFavorite)
            .map((repository) => repository.path),
      ),
      workspaceGroups: state.workspaceGroups,
      repositoryGroups: Map<String, String>.unmodifiable({
        for (final entry in state.repositoryGroups.entries)
          if (state.repositories.any((tab) => tab.path == entry.key))
            entry.key: entry.value,
      }),
    );
    _writeTail = _writeTail.then((_) async {
      try {
        await _store.save(snapshot);
        _lastPersistenceError = null;
        if (ref.mounted) state = state.copyWith(clearPersistenceError: true);
      } on Object catch (error) {
        _lastPersistenceError = error;
        if (ref.mounted) {
          state = state.copyWith(
            persistenceFailureCount: state.persistenceFailureCount + 1,
            persistenceError: error.toString(),
          );
        }
      }
    });
    await _writeTail;
    final error = _lastPersistenceError;
    if (error != null) throw RepositoryLibraryPersistenceException(error);
  }
}
