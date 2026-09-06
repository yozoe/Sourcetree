import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as path_utils;

import '../git/git.dart';

/// The widest repository state invalidated by a group of file-system events.
///
/// 中文：一组文件系统事件所影响的最大仓库状态范围。
enum RepositoryExternalChangeScope { workingTree, repositoryMetadata }

/// Creates a directory event stream for one monitored root.
///
/// 中文：为一个监听根目录创建文件系统事件流；该边界允许测试注入确定性事件。
typedef RepositoryWatchStreamFactory =
    Stream<FileSystemEvent> Function(String path, bool recursive);

/// Coalesces work-tree and Git metadata changes for one repository window.
///
/// The monitor never treats file events as repository truth. It only reports
/// an invalidation scope; callers must read the resulting state from Git.
///
/// 中文：合并单个仓库窗口中的工作区和 Git 元数据变化。文件事件只用于触发
/// 失效通知，调用方仍必须以 Git 重新读取的结果为准。
final class RepositoryChangeMonitor {
  RepositoryChangeMonitor({
    Duration debounceDelay = const Duration(milliseconds: 400),
    Duration maximumDelay = const Duration(seconds: 5),
    RepositoryWatchStreamFactory? watchDirectory,
  }) : _debounceDelay = debounceDelay,
       _maximumDelay = maximumDelay,
       _watchDirectory = watchDirectory ?? _defaultWatchDirectory;

  final Duration _debounceDelay;
  final Duration _maximumDelay;
  final RepositoryWatchStreamFactory _watchDirectory;
  final List<StreamSubscription<FileSystemEvent>> _subscriptions = [];

  GitRepository? _repository;
  void Function(RepositoryExternalChangeScope scope)? _onChanged;
  RepositoryExternalChangeScope? _pendingScope;
  Timer? _debounceTimer;
  Timer? _maximumTimer;
  int _generation = 0;

  /// Starts monitoring [repository], replacing any earlier repository watch.
  ///
  /// Missing or unsupported roots are skipped so manual and focus-triggered
  /// refresh remain available when the platform watcher cannot be installed.
  ///
  /// 中文：开始监听 [repository] 并替换旧监听。不存在或平台不支持的目录会被
  /// 跳过，使手动刷新和窗口聚焦兜底刷新仍然可用。
  Future<void> start(
    GitRepository repository, {
    required void Function(RepositoryExternalChangeScope scope) onChanged,
  }) async {
    final generation = ++_generation;
    _resetPendingEvents();
    await _cancelSubscriptions();
    if (generation != _generation) return;
    _repository = repository;
    _onChanged = onChanged;

    final roots = _watchRoots(repository);
    for (final root in roots) {
      if (!Directory(root.path).existsSync()) continue;
      try {
        late final StreamSubscription<FileSystemEvent> subscription;
        subscription = _watchDirectory(root.path, true).listen(
          (event) => _handleEvent(event, root, generation),
          onError: (Object _) {
            unawaited(subscription.cancel());
            _subscriptions.remove(subscription);
          },
          cancelOnError: true,
        );
        _subscriptions.add(subscription);
      } on FileSystemException {
        // Another root or the focus/manual fallback can still refresh safely.
      } on UnsupportedError {
        // Recursive watching is not available on every Dart desktop target.
      }
    }
  }

  /// Cancels every watcher and discards coalesced events not yet delivered.
  ///
  /// 中文：取消全部目录监听，并丢弃尚未发送的合并事件。
  Future<void> stop() async {
    _generation++;
    _resetPendingEvents();
    _repository = null;
    _onChanged = null;
    await _cancelSubscriptions();
  }

  /// Clears debounce state without changing the lifecycle generation.
  ///
  /// 中文：清除防抖状态，但不改变监听生命周期代际。
  void _resetPendingEvents() {
    _debounceTimer?.cancel();
    _maximumTimer?.cancel();
    _debounceTimer = null;
    _maximumTimer = null;
    _pendingScope = null;
  }

  /// Cancels the subscriptions detached by the latest lifecycle request.
  ///
  /// 中文：取消最近一次生命周期请求所分离出的全部目录订阅。
  Future<void> _cancelSubscriptions() async {
    final subscriptions = List<StreamSubscription<FileSystemEvent>>.of(
      _subscriptions,
    );
    _subscriptions.clear();
    await Future.wait<void>([
      for (final subscription in subscriptions) subscription.cancel(),
    ]);
  }

  /// Creates the platform directory stream used by the production monitor.
  ///
  /// 中文：创建生产环境使用的平台目录事件流。
  static Stream<FileSystemEvent> _defaultWatchDirectory(
    String path,
    bool recursive,
  ) => Directory(path).watch(recursive: recursive);

  /// Returns the smallest distinct roots needed for a worktree or bare repo.
  ///
  /// 中文：返回覆盖普通仓库、裸仓库和 linked worktree 所需的最小去重监听根。
  List<_RepositoryWatchRoot> _watchRoots(GitRepository repository) {
    final roots = <_RepositoryWatchRoot>[];
    final workTree = repository.workTreeRoot;
    if (workTree != null) {
      roots.add(_RepositoryWatchRoot(workTree, isGitMetadata: false));
    }
    for (final metadataRoot in {
      repository.commonDirectory,
      repository.gitDirectory,
    }) {
      final coveredByWorkTree =
          workTree != null &&
          (_samePath(workTree, metadataRoot) ||
              path_utils.isWithin(workTree, metadataRoot));
      final coveredByExistingMetadata = roots.any(
        (root) =>
            root.isGitMetadata &&
            (_samePath(root.path, metadataRoot) ||
                path_utils.isWithin(root.path, metadataRoot)),
      );
      if (!coveredByWorkTree && !coveredByExistingMetadata) {
        roots.add(_RepositoryWatchRoot(metadataRoot, isGitMetadata: true));
      }
    }
    return roots;
  }

  /// Classifies one current-generation event and adds it to the debounce batch.
  ///
  /// 中文：判断当前代际事件的失效范围，并将其加入防抖批次。
  void _handleEvent(
    FileSystemEvent event,
    _RepositoryWatchRoot root,
    int generation,
  ) {
    final repository = _repository;
    if (generation != _generation || repository == null) return;
    final candidate = path_utils.isAbsolute(event.path)
        ? event.path
        : path_utils.join(root.path, event.path);
    final scope =
        root.isGitMetadata || _isGitMetadataPath(repository, candidate)
        ? _gitChangeScope(repository, candidate)
        : RepositoryExternalChangeScope.workingTree;
    if (scope == null) return;
    _pendingScope = _mergeScopes(_pendingScope, scope);
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceDelay, _flush);
    _maximumTimer ??= Timer(_maximumDelay, _flush);
  }

  /// Reports the coalesced invalidation once and resets both delay bounds.
  ///
  /// 中文：发送一次合并后的失效通知，并重置普通与最大等待计时器。
  void _flush() {
    _debounceTimer?.cancel();
    _maximumTimer?.cancel();
    _debounceTimer = null;
    _maximumTimer = null;
    final scope = _pendingScope;
    _pendingScope = null;
    if (scope != null) _onChanged?.call(scope);
  }

  /// Returns whether [candidate] belongs to either Git administration root.
  ///
  /// 中文：判断 [candidate] 是否属于当前仓库的任一 Git 管理目录。
  bool _isGitMetadataPath(GitRepository repository, String candidate) {
    for (final root in {repository.gitDirectory, repository.commonDirectory}) {
      if (_samePath(root, candidate) || path_utils.isWithin(root, candidate)) {
        return true;
      }
    }
    return false;
  }

  /// Distinguishes index-only changes from refs and operation-state changes.
  ///
  /// 中文：区分仅影响工作区状态的 index 变化与引用、仓库操作状态变化。
  RepositoryExternalChangeScope? _gitChangeScope(
    GitRepository repository,
    String candidate,
  ) {
    for (final root in {repository.gitDirectory, repository.commonDirectory}) {
      if (!_samePath(root, candidate) &&
          !path_utils.isWithin(root, candidate)) {
        continue;
      }
      final relative = path_utils.relative(candidate, from: root);
      final segments = path_utils.split(relative);
      final basename = segments.isEmpty ? relative : segments.last;
      if (basename.endsWith('.lock')) return null;
      if (basename == 'index' || basename == 'index.lock') {
        final belongsToCurrentWorktree =
            _samePath(repository.gitDirectory, candidate) ||
            path_utils.isWithin(repository.gitDirectory, candidate);
        return belongsToCurrentWorktree
            ? RepositoryExternalChangeScope.workingTree
            : null;
      }
      final firstSegment = segments.firstOrNull;
      final reloadRepositoryMetadata =
          basename == 'HEAD' ||
          basename == 'MERGE_HEAD' ||
          basename == 'CHERRY_PICK_HEAD' ||
          basename == 'REVERT_HEAD' ||
          basename == 'packed-refs' ||
          basename == 'config' ||
          basename == 'config.worktree' ||
          firstSegment == 'refs' ||
          firstSegment == 'rebase-merge' ||
          firstSegment == 'rebase-apply' ||
          firstSegment == 'sequencer';
      return reloadRepositoryMetadata
          ? RepositoryExternalChangeScope.repositoryMetadata
          : null;
    }
    return RepositoryExternalChangeScope.workingTree;
  }

  /// Promotes a debounce batch to metadata scope when any event requires it.
  ///
  /// 中文：批次中任一事件涉及 Git 元数据时，将合并范围提升为仓库元数据。
  RepositoryExternalChangeScope _mergeScopes(
    RepositoryExternalChangeScope? current,
    RepositoryExternalChangeScope next,
  ) {
    if (current == RepositoryExternalChangeScope.repositoryMetadata ||
        next == RepositoryExternalChangeScope.repositoryMetadata) {
      return RepositoryExternalChangeScope.repositoryMetadata;
    }
    return RepositoryExternalChangeScope.workingTree;
  }

  /// Compares two normalized paths using the host platform's path semantics.
  ///
  /// 中文：按当前平台路径语义比较两个规范化路径。
  bool _samePath(String first, String second) => path_utils.equals(
    path_utils.normalize(first),
    path_utils.normalize(second),
  );
}

/// One directory root and whether every event below it is Git metadata.
///
/// 中文：一个监听根及其是否完全属于 Git 管理目录。
final class _RepositoryWatchRoot {
  const _RepositoryWatchRoot(this.path, {required this.isGitMetadata});

  final String path;
  final bool isGitMetadata;
}
