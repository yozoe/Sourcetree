import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path_utils;

import '../git/git.dart';
import '../presentation/presentation.dart';
import 'desktop_window_bridge.dart';
import 'git_desktop_theme.dart';
import 'git_askpass_prompt_coordinator.dart';
import 'repository_library_controller.dart';
import 'repository_session.dart';
import 'repository_session_store.dart';
import 'repository_view_mapper.dart';
import 'theme_preferences.dart';

/// Returns operation-aware names for Git index stages two and three.
///
/// 中文：返回与当前 Git 操作匹配的索引第二、第三阶段版本名称，避免在变基、
/// 遴选或回滚时把 ours/theirs 误解为当前分支和合并来源。
(String, String) conflictVersionLabels(
  GitRepositoryOperationState operation, {
  required String currentBranch,
}) => switch (operation) {
  GitRepositoryOperationState.merge => ('当前分支版本 · $currentBranch', '合并来源版本'),
  GitRepositoryOperationState.rebase => ('变基目标基线版本', '正在重放的提交版本'),
  GitRepositoryOperationState.cherryPick => (
    '当前分支版本 · $currentBranch',
    '遴选提交版本',
  ),
  GitRepositoryOperationState.revert => ('当前分支版本 · $currentBranch', '待应用的回滚版本'),
  GitRepositoryOperationState.none => ('当前基线版本', '待应用版本'),
};

/// Returns native mutation-menu availability from the current repository
/// capability snapshot.
///
/// 中文：根据当前仓库 capability 快照返回原生写操作菜单可用性；没有仓库、
/// 后台任务或暂停中的 Git 操作都会关闭相关入口。
({bool canApplyPatch, bool canStopTracking}) nativeWorkspaceMenuAvailability(
  RepositorySessionState session,
  RepositoryOverviewViewData overview,
) {
  final repository = overview.repository;
  final canApplyPatch =
      session.phase == RepositorySessionPhase.ready &&
      repository != null &&
      !repository.blocksRepositoryMutations;
  return (
    canApplyPatch: canApplyPatch,
    canStopTracking:
        canApplyPatch &&
        (repository.selectedChange?.canStopTracking == true ||
            session.selectedCommitFile?.file.path.isValidUtf8 == true),
  );
}

class GitDesktopApp extends ConsumerStatefulWidget {
  const GitDesktopApp({
    super.key,
    this.isWorkspaceWindow = false,
    this.initialRepositoryPath,
    this.initialWorkspaceAction,
    this.restoresPreviouslyOpenWorkspace = false,
  });

  /// Whether this Flutter engine is hosted by a repository workspace window.
  final bool isWorkspaceWindow;

  /// Repository path opened automatically by a newly created workspace.
  final String? initialRepositoryPath;

  /// Optional action requested by the repository library for a new workspace.
  final String? initialWorkspaceAction;

  /// Whether this workspace was reopened automatically from the last launch.
  final bool restoresPreviouslyOpenWorkspace;

  @override
  ConsumerState<GitDesktopApp> createState() => _GitDesktopAppState();
}

class _GitDesktopAppState extends ConsumerState<GitDesktopApp> {
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    ref.listen<int>(
      gitDesktopThemePreferencesProvider.select(
        (state) => state.saveFailureCount,
      ),
      (previous, next) {
        if (previous == null || next <= previous) return;
        _messengerKey.currentState
          ?..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('主题偏好保存失败；本次切换仍然有效。')));
      },
    );
    final themePreferences = ref.watch(
      gitDesktopThemePreferencesProvider.select((state) => state.preferences),
    );
    final themeControl = GitDesktopThemeMenuButton(
      preferences: themePreferences,
      onThemeModeChanged: ref
          .read(gitDesktopThemePreferencesProvider.notifier)
          .setThemeMode,
    );
    return MaterialApp(
      title: 'Git Desktop',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: _messengerKey,
      themeMode: themePreferences.mode,
      theme: buildGitDesktopTheme(Brightness.light),
      darkTheme: buildGitDesktopTheme(Brightness.dark),
      home: widget.isWorkspaceWindow
          ? RepositoryWorkspaceScreen(
              key: ValueKey<String>(
                '${widget.initialRepositoryPath ?? ''}|${widget.initialWorkspaceAction ?? ''}',
              ),
              initialRepositoryPath: widget.initialRepositoryPath,
              initialAction: widget.initialWorkspaceAction,
              isRestoredWorkspace: widget.restoresPreviouslyOpenWorkspace,
              themeControl: themeControl,
            )
          : RepositoryLibraryWindow(themeControl: themeControl),
    );
  }
}

/// The independent window that lists locally known repositories.
class RepositoryLibraryWindow extends ConsumerStatefulWidget {
  const RepositoryLibraryWindow({super.key, this.themeControl});

  final Widget? themeControl;

  /// 中文：创建关联的状态对象。
  /// English: Creates the associated state object.
  @override
  ConsumerState<RepositoryLibraryWindow> createState() =>
      _RepositoryLibraryWindowState();
}

class _RepositoryLibraryWindowState
    extends ConsumerState<RepositoryLibraryWindow> {
  bool _isDirectoryDropActive = false;

  /// 中文：首页窗口初始化时恢复本地仓库清单。
  /// English: Restores the local repository list when the library window
  /// initializes.
  @override
  void initState() {
    super.initState();
    unawaited(_restoreRepositoryLibrary());
    DesktopWindowBridge.setRepositoryOpenedHandler(_recordRepositoryOpened);
    DesktopWindowBridge.setRepositoryDirectoryDropHandlers(
      onDirectoriesDropped: _registerDroppedDirectories,
      onDragStateChanged: _updateDirectoryDropState,
    );
    unawaited(DesktopWindowBridge.repositoryLibraryReady().catchError((_) {}));
  }

  /// 中文：恢复首页仓库清单；损坏或暂时不可读时保留原文件并显示可恢复提示。
  ///
  /// English: Restores the home repository list, preserving an unreadable
  /// snapshot and showing a recoverable error when loading fails.
  Future<void> _restoreRepositoryLibrary() async {
    try {
      await ref.read(repositoryLibraryProvider.notifier).restore();
    } on RepositorySessionLoadException {
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法读取已保存的仓库清单；原文件已保留，可重新添加仓库进行恢复。')),
        );
      });
    } on RepositoryLibraryPersistenceException {
      // Persistence failures are reported by the provider listener so restore
      // and later add/reorder/select writes share one recoverable error path.
    }
  }

  /// 中文：显示仓库清单保存失败的可恢复提示，不暴露底层路径或异常详情。
  /// English: Shows a recoverable repository-library persistence warning
  /// without exposing storage paths or underlying exception details.
  void _showRepositoryLibraryPersistenceFailure() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('仓库清单暂时无法保存；本次仓库更改已保留在当前窗口，但尚未写入磁盘。请检查磁盘空间或权限后再次调整清单。'),
        ),
      );
    });
  }

  @override
  void dispose() {
    DesktopWindowBridge.setRepositoryOpenedHandler(null);
    DesktopWindowBridge.setRepositoryDirectoryDropHandlers();
    super.dispose();
  }

  /// Adds a repository confirmed by a workspace to the live library and its
  /// persisted repository list.
  ///
  /// 中文：仅在首页完成登记和持久化后确认工作区回传；失败会保留原生重试记录。
  Future<void> _recordRepositoryOpened(String repositoryPath) async {
    final controller = ref.read(repositoryLibraryProvider.notifier);
    final result = await controller.registerAndPersist(repositoryPath);
    if (result != RepositoryLibraryRegistrationResult.added &&
        result != RepositoryLibraryRegistrationResult.alreadyRegistered) {
      throw StateError('Repository registration was not persisted.');
    }
    controller.select(repositoryPath);
    await controller.flushPendingWrites();
  }

  /// 中文：处理原生窗口投递的目录，依次识别 Git 根目录后添加到首页清单。
  ///
  /// English: Processes native dropped directories sequentially, adding only
  /// the Git roots recognized by the application layer to the library.
  Future<void> _registerDroppedDirectories(List<String> directoryPaths) async {
    var added = 0;
    var alreadyRegistered = 0;
    var rejected = 0;
    final controller = ref.read(repositoryLibraryProvider.notifier);
    for (final directoryPath in directoryPaths) {
      switch (await controller.add(directoryPath)) {
        case RepositoryLibraryRegistrationResult.added:
          added++;
        case RepositoryLibraryRegistrationResult.alreadyRegistered:
          alreadyRegistered++;
        case RepositoryLibraryRegistrationResult.notRepository:
        case RepositoryLibraryRegistrationResult.failed:
          rejected++;
      }
    }
    try {
      await controller.flushPendingWrites();
    } on RepositoryLibraryPersistenceException {
      // The provider listener explains that the additions remain in memory
      // but were not saved, so do not also show a misleading success message.
      return;
    }
    if (!mounted) return;
    final message = switch ((added, alreadyRegistered, rejected)) {
      (0, 0, _) => '未添加目录：请拖入可读取的 Git 仓库。',
      (0, _, 0) => '拖入的仓库已在清单中。',
      (_, 0, 0) => '已添加 $added 个 Git 仓库。',
      _ => '已添加 $added 个 Git 仓库；$alreadyRegistered 个已存在，$rejected 个未添加。',
    };
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 中文：更新目录拖入首页时的视觉反馈状态。
  ///
  /// English: Updates the library drop-target visual state sent by the native
  /// macOS window.
  void _updateDirectoryDropState(bool isActive) {
    if (!mounted || _isDirectoryDropActive == isActive) return;
    setState(() => _isDirectoryDropActive = isActive);
  }

  /// 中文：在独立工作区窗口中显示选中的仓库。
  /// English: Shows the selected repository in an independent workspace
  /// window.
  Future<void> _openWorkspace(
    String? repositoryPath, {
    String? initialAction,
  }) async {
    try {
      await DesktopWindowBridge.openWorkspace(
        repositoryPath: repositoryPath,
        initialAction: initialAction,
      );
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('无法创建工作区窗口：$error')));
    }
  }

  /// 中文：从首页直接选择本地仓库，并在独立工作区窗口中打开它。
  /// English: Picks a local repository from the library and opens it directly
  /// in an independent workspace window.
  Future<void> _pickRepositoryAndOpen() async {
    final directory = await getDirectoryPath(confirmButtonText: '打开仓库');
    if (directory == null || !mounted) return;
    await _openWorkspace(directory);
  }

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    ref.listen<(int, String?)>(
      repositoryLibraryProvider.select(
        (state) => (state.persistenceFailureCount, state.persistenceError),
      ),
      (previous, next) {
        if (next.$1 > (previous?.$1 ?? 0)) {
          _showRepositoryLibraryPersistenceFailure();
        }
      },
    );
    final repositories = ref.watch(
      repositoryLibraryProvider.select((state) => state.repositories),
    );
    return Scaffold(
      body: RepositoryLibraryPage(
        repositories: repositories
            .map(
              (RepositoryTab tab) => RepositoryLibraryItem(
                path: tab.path,
                label: tab.label,
                branchName: tab.branchName,
                changedFileCount: tab.changedFileCount,
                isDetached: tab.isDetached,
                isUnborn: tab.isUnborn,
                hasStatus: tab.hasStatus,
              ),
            )
            .toList(growable: false),
        activePath: null,
        onRepositorySelected: (String path) {
          ref.read(repositoryLibraryProvider.notifier).select(path);
          return _openWorkspace(path);
        },
        onOpenRepository: () => unawaited(_pickRepositoryAndOpen()),
        onCloneRepository: () =>
            unawaited(_openWorkspace(null, initialAction: 'cloneRepository')),
        onInitializeRepository: () => unawaited(
          _openWorkspace(null, initialAction: 'initializeRepository'),
        ),
        onRepositoriesReordered: ref
            .read(repositoryLibraryProvider.notifier)
            .reorder,
        isDirectoryDropActive: _isDirectoryDropActive,
        trailing: widget.themeControl,
      ),
    );
  }
}

/// Maps a route action name to the safe workspace action it requests.
RepositoryAction? _repositoryActionFromName(String? name) => switch (name) {
  'openRepository' => RepositoryAction.openRepository,
  'cloneRepository' => RepositoryAction.cloneRepository,
  'initializeRepository' => RepositoryAction.initializeRepository,
  _ => null,
};

enum _RebasePromptAction { continueRebase, abort, cancel }

class RepositoryWorkspaceScreen extends ConsumerStatefulWidget {
  const RepositoryWorkspaceScreen({
    super.key,
    this.initialRepositoryPath,
    this.initialAction,
    this.isRestoredWorkspace = false,
    this.themeControl,
  });

  /// Repository selected by the independent repository library window.
  final String? initialRepositoryPath;

  /// Action to start after this independent workspace window is ready.
  final String? initialAction;

  /// Whether an initial repository-open failure must discard a saved window.
  final bool isRestoredWorkspace;
  final Widget? themeControl;

  /// 中文：创建关联的状态对象。
  /// English: Creates the associated state object.
  @override
  ConsumerState<RepositoryWorkspaceScreen> createState() =>
      _RepositoryWorkspaceScreenState();
}

class _RepositoryWorkspaceScreenState
    extends ConsumerState<RepositoryWorkspaceScreen> {
  bool _isAskPassDialogVisible = false;
  bool _isRebasePromptVisible = false;
  bool _isSequencerPromptVisible = false;
  bool _hasHandledInitialAction = false;
  bool? _lastNativeStopTrackingAvailability;
  bool? _lastNativeApplyPatchAvailability;

  /// 中文：在窗口首次绘制后执行首页请求的仓库操作；恢复窗口打开失败时清除其原生恢复记录。
  /// English: Starts the repository action requested by the library after the
  /// workspace window has drawn; removes the native restore record when a
  /// restored workspace fails to open its repository.
  @override
  void initState() {
    super.initState();
    DesktopWindowBridge.setWorkspaceActionHandler(_handleWorkspaceMenuAction);
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepareWorkspace());
  }

  @override
  void dispose() {
    DesktopWindowBridge.setWorkspaceActionHandler(null);
    super.dispose();
  }

  /// Routes one native workspace-menu action to its Flutter use case.
  ///
  /// 中文：将当前前台工作区的原生菜单动作路由至 Flutter 用例；停止追踪优先
  /// 使用历史文件选择，其余选择在进入会话写入流程前仍会重新校验。
  Future<void> _handleWorkspaceMenuAction(String action) async {
    if (!mounted) return;
    switch (action) {
      case 'createPatch':
        await _showCreatePatchDialog();
      case 'applyPatch':
        await _showApplyPatchDialog();
      case 'repositoryDetails':
        await _showRepositoryDetailsDialog();
      case 'repositoryFeaturePending':
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('该菜单功能待实现。')));
      case 'stopTracking':
        final session = ref.read(repositorySessionProvider);
        if (session.selectedCommitFile?.file.path.isValidUtf8 == true) {
          await _stopTrackingSelectedCommitFile();
          return;
        }
        final selected = mapRepositoryOverview(
          session,
        ).repository?.selectedChange;
        if (selected?.canStopTracking == true) {
          await _stopTrackingChanges([selected!]);
          return;
        }
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请选择一个可停止追踪的已跟踪或已暂存文件。')));
    }
  }

  /// Synchronizes native mutation-menu availability with Flutter state.
  ///
  /// 中文：将当前仓库写入边界与选中文件能力快照交给 macOS 菜单；实际执行仍会
  /// 在 Flutter 入口重新读取状态，避免原生菜单使用过期快照。
  Future<void> _syncNativeWorkspaceMenuAvailability(
    RepositorySessionState session,
    RepositoryOverviewViewData overview,
  ) async {
    final availability = nativeWorkspaceMenuAvailability(session, overview);
    final canApplyPatch = availability.canApplyPatch;
    final canStopTracking = availability.canStopTracking;
    if (_lastNativeStopTrackingAvailability == canStopTracking &&
        _lastNativeApplyPatchAvailability == canApplyPatch) {
      return;
    }
    _lastNativeStopTrackingAvailability = canStopTracking;
    _lastNativeApplyPatchAvailability = canApplyPatch;
    try {
      await DesktopWindowBridge.setWorkspaceMenuState(
        canStopTracking: canStopTracking,
        canApplyPatch: canApplyPatch,
      );
    } on Object {
      // The Engine can be closing while a state notification is in flight.
      // Engine 可能正在关闭，状态通知在传输途中失效时无需更新已销毁的窗口。
    }
  }

  /// 中文：从 macOS“仓库”菜单显示当前仓库的真实 Git 详情。
  /// English: Opens the current repository's Git-backed details window from
  /// the native Repository menu.
  Future<void> _showRepositoryDetailsDialog() async {
    final repository = ref.read(repositorySessionProvider).repository;
    if (repository == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先打开一个仓库。')));
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RepositoryDetailsDialog(
        repositoryName: path_utils.basename(
          repository.workTreeRoot ?? repository.commonDirectory,
        ),
      ),
    );
  }

  /// 中文：执行首页请求的单仓库打开或新建操作。
  /// English: Fulfills the single-repository request from the library window.
  Future<void> _prepareWorkspace() async {
    if (!mounted || _hasHandledInitialAction) return;
    final controller = ref.read(repositorySessionProvider.notifier);
    final String? repositoryPath = widget.initialRepositoryPath;
    if (repositoryPath != null && repositoryPath.isNotEmpty) {
      _hasHandledInitialAction = true;
      await controller.openRepository(repositoryPath);
      if (!mounted) return;
      if (widget.isRestoredWorkspace &&
          ref.read(repositorySessionProvider).phase !=
              RepositorySessionPhase.ready) {
        unawaited(
          DesktopWindowBridge.repositoryRestoreFailed(
            repositoryPath,
          ).catchError((_) {}),
        );
      }
      return;
    }
    final RepositoryAction? action = _repositoryActionFromName(
      widget.initialAction,
    );
    if (action == null) return;
    _hasHandledInitialAction = true;
    _handleAction(action);
  }

  /// 中文：显示相应界面或信息。
  /// English: Shows the corresponding UI or information.
  Future<void> _showAskPassPrompt(GitAskPassRequest request) async {
    final secret = await showGitAskPassPromptDialog(context, request);
    if (!mounted) {
      return;
    }
    // The dialog may have been dismissed by cancellation. In either case, the
    // coordinator accepts at most one answer and never retains it in state.
    _isAskPassDialogVisible = false;
    ref.read(gitAskPassPromptCoordinatorProvider.notifier).submit(secret);
  }

  /// 中文：打开目标资源。
  /// English: Opens the target resource.
  Future<void> _openRepository() async {
    final directory = await getDirectoryPath(confirmButtonText: '打开仓库');
    if (directory == null || !mounted) return;
    try {
      await DesktopWindowBridge.openWorkspace(repositoryPath: directory);
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('无法创建工作区窗口：$error')));
    }
  }

  /// 中文：向首页上报当前工作区的仓库和最新 Git 状态快照。
  /// English: Reports the workspace repository and its newest Git status
  /// snapshot to the library window.
  void _reportRepositoryStatus(
    RepositorySessionState? previous,
    RepositorySessionState next,
  ) {
    final repository = next.repository;
    if (next.phase != RepositorySessionPhase.ready || repository == null) {
      return;
    }
    if (previous?.phase == RepositorySessionPhase.ready &&
        previous?.repository?.id == repository.id &&
        identical(previous?.status, next.status)) {
      return;
    }
    unawaited(
      DesktopWindowBridge.repositoryOpened(
        repository.commandDirectory,
      ).catchError((_) {}),
    );
  }

  /// 中文：在变基因冲突暂停时提供继续、中止或稍后处理的操作提示。
  /// English: Offers continue, abort, or defer actions when a rebase pauses.
  void _handleRepositoryStateChange(
    RepositorySessionState? previous,
    RepositorySessionState next,
  ) {
    _reportRepositoryStatus(previous, next);
    final enteredRebase =
        next.operationState == GitRepositoryOperationState.rebase &&
        previous?.operationState != GitRepositoryOperationState.rebase;
    if (enteredRebase && !_isRebasePromptVisible && mounted) {
      _isRebasePromptVisible = true;
      unawaited(_showRebasePrompt());
    }
    final enteredSequencer =
        (next.operationState == GitRepositoryOperationState.cherryPick ||
            next.operationState == GitRepositoryOperationState.revert) &&
        previous?.operationState != next.operationState;
    if (enteredSequencer && !_isSequencerPromptVisible && mounted) {
      _isSequencerPromptVisible = true;
      unawaited(_showSequencerPrompt(next.operationState));
    }
  }

  Future<void> _showRebasePrompt() async {
    final action = await showDialog<_RebasePromptAction>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('变基进行中'),
        content: const Text(
          '出现此种情况是因为你在变基的过程中被 Git 中止，可能是因为冲突。请解决冲突后继续变基，或放弃当前变基。',
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(_RebasePromptAction.cancel),
            child: const Text('取消'),
          ),
          OutlinedButton(
            onPressed: () =>
                Navigator.of(context).pop(_RebasePromptAction.abort),
            child: const Text('放弃变基'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(_RebasePromptAction.continueRebase),
            child: const Text('继续变基'),
          ),
        ],
      ),
    );
    _isRebasePromptVisible = false;
    if (!mounted || action == null || action == _RebasePromptAction.cancel) {
      return;
    }
    if (action == _RebasePromptAction.continueRebase) {
      await _continueRebase();
    } else {
      await _abortRebase();
    }
  }

  Future<void> _showSequencerPrompt(
    GitRepositoryOperationState operationState,
  ) async {
    final isCherryPick =
        operationState == GitRepositoryOperationState.cherryPick;
    final operationName = isCherryPick ? '遴选' : '回滚';
    final action = await showDialog<_RebasePromptAction>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text('$operationName进行中'),
        content: Text(
          'Git 因冲突暂停了$operationName。请解决冲突并暂存后继续，或放弃本次$operationName。',
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(_RebasePromptAction.cancel),
            child: const Text('取消'),
          ),
          OutlinedButton(
            onPressed: () =>
                Navigator.of(context).pop(_RebasePromptAction.abort),
            child: Text('放弃$operationName'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(_RebasePromptAction.continueRebase),
            child: Text('继续$operationName'),
          ),
        ],
      ),
    );
    _isSequencerPromptVisible = false;
    if (!mounted || action == null || action == _RebasePromptAction.cancel) {
      return;
    }
    final controller = ref.read(repositorySessionProvider.notifier);
    final completed = switch ((isCherryPick, action)) {
      (true, _RebasePromptAction.continueRebase) =>
        await controller.continueCherryPick(),
      (true, _) => await controller.abortCherryPick(),
      (false, _RebasePromptAction.continueRebase) =>
        await controller.continueRevert(),
      (false, _) => await controller.abortRevert(),
    };
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          completed
              ? action == _RebasePromptAction.continueRebase
                    ? '已继续$operationName。'
                    : '已中止$operationName。'
              : '$operationName未完成，请查看仓库状态。',
        ),
      ),
    );
  }

  /// 中文：初始化当前功能。
  /// English: Initializes the current feature.
  Future<void> _initializeRepository() async {
    final directory = await getDirectoryPath(confirmButtonText: '选择空目录');
    if (directory == null || !mounted) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('初始化 Git 仓库'),
        content: const Text('仅当所选目录为空时才会继续。Git 将在其中创建 .git 目录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('初始化'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    final initialized = await ref
        .read(repositorySessionProvider.notifier)
        .initializeRepository(directory);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(initialized ? '已初始化 Git 仓库。' : '初始化失败，请查看仓库错误信息。'),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// 中文：收集远端地址和存放位置，经用户确认后创建同名子目录并克隆。
  ///
  /// English: Collects a remote URL and parent destination, confirms with the
  /// user, then creates a repository-named child and clones into it.
  Future<void> _cloneRepository() async {
    final remoteUrl = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => const _CloneDialog(),
    );
    if (remoteUrl == null || !mounted) return;
    final directory = await getDirectoryPath(confirmButtonText: '选择存放位置');
    if (directory == null || !mounted) return;
    final repositoryName = cloneRepositoryNameFromRemote(remoteUrl);
    final approved = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('克隆 Git 仓库'),
        content: Text('将在所选位置下自动创建“$repositoryName”目录。克隆可能需要现有 Git 凭据。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('克隆'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    final cloned = await ref
        .read(repositorySessionProvider.notifier)
        .cloneRepositoryIntoParent(
          remoteUrl: remoteUrl,
          parentDirectoryPath: directory,
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(cloned ? '已克隆并打开仓库。' : '克隆失败，请查看仓库错误信息。')),
    );
  }

  /// 中文：处理当前事件。
  /// English: Handles the current event.
  void _handleAction(RepositoryAction action) {
    switch (action) {
      case RepositoryAction.openRepository:
        _openRepository();
      case RepositoryAction.initializeRepository:
        _initializeRepository();
      case RepositoryAction.cloneRepository:
        _cloneRepository();
      case RepositoryAction.cancelClone:
        ref.read(repositorySessionProvider.notifier).cancelClone();
      case RepositoryAction.fetch:
        _showFetchDialog();
      case RepositoryAction.cancelFetch:
        ref.read(repositorySessionProvider.notifier).cancelFetch();
      case RepositoryAction.pull:
        _confirmPull();
      case RepositoryAction.cancelPull:
        ref.read(repositorySessionProvider.notifier).cancelPull();
      case RepositoryAction.cancelStash:
        ref.read(repositorySessionProvider.notifier).cancelStash();
      case RepositoryAction.continueRebase:
        unawaited(_continueRebase());
      case RepositoryAction.abortRebase:
        unawaited(_confirmAbortRebase());
      case RepositoryAction.continueSequencer:
        unawaited(_continueSequencer());
      case RepositoryAction.abortSequencer:
        unawaited(_confirmAbortSequencer());
      case RepositoryAction.push:
        _confirmPush();
      case RepositoryAction.cancelPush:
        ref.read(repositorySessionProvider.notifier).cancelPush();
      case RepositoryAction.showOperationLog:
        _showOperationLog();
      case RepositoryAction.refresh:
      case RepositoryAction.retry:
        ref.read(repositorySessionProvider.notifier).refresh();
      case RepositoryAction.commit:
        _showCommitDialog();
      case RepositoryAction.stash:
        unawaited(_showCreateStashDialog());
      case RepositoryAction.createBranch:
        _showBranchManagerDialog();
      case RepositoryAction.mergeBranch:
        _showMergeBranchDialog();
    }
  }

  /// 中文：显示相应界面或信息。
  /// English: Shows the corresponding UI or information.
  Future<void> _showOperationLog() async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => Consumer(
        builder: (BuildContext context, WidgetRef ref, Widget? child) {
          final operations = ref.watch(repositorySessionProvider).operations;
          return AlertDialog(
            title: const Text('操作日志'),
            content: SizedBox(
              width: 560,
              height: 360,
              child: operations.isEmpty
                  ? const Center(child: Text('尚无可显示的操作。'))
                  : ListView.separated(
                      itemCount: operations.length,
                      separatorBuilder: (BuildContext context, int index) =>
                          const Divider(height: 1),
                      itemBuilder: (BuildContext context, int index) {
                        final operation = operations[index];
                        return ListTile(
                          dense: true,
                          leading: Icon(_operationIcon(operation.outcome)),
                          title: Text(_operationName(operation.kind)),
                          subtitle: Text(
                            [
                              _operationSummary(operation.outcome),
                              _operationTime(operation),
                              if (operation.message != null) operation.message!,
                            ].join('\n'),
                          ),
                        );
                      },
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 中文：返回操作日志中展示的本地化操作名称。
  ///
  /// English: Returns the localized operation name shown in the activity log.
  String _operationName(RepositoryOperationKind kind) => switch (kind) {
    RepositoryOperationKind.clone => '克隆仓库',
    RepositoryOperationKind.fetch => '获取远端更新',
    RepositoryOperationKind.pull => '拉取更新',
    RepositoryOperationKind.push => '推送当前分支',
    RepositoryOperationKind.stash => '管理贮藏',
    RepositoryOperationKind.history => '历史提交操作',
  };

  /// 中文：返回操作结果对应的简短本地化状态说明。
  ///
  /// English: Returns a concise localized status description for an operation
  /// outcome.
  String _operationSummary(RepositoryOperationOutcome outcome) =>
      switch (outcome) {
        RepositoryOperationOutcome.running => '正在运行',
        RepositoryOperationOutcome.succeeded => '已完成',
        RepositoryOperationOutcome.cancelled => '已取消；请检查仓库状态。',
        RepositoryOperationOutcome.failed => '未完成',
      };

  /// 中文：为操作结果选择日志列表中使用的状态图标。
  ///
  /// English: Selects the status icon used for an operation in the log list.
  IconData _operationIcon(RepositoryOperationOutcome outcome) =>
      switch (outcome) {
        RepositoryOperationOutcome.running => Icons.sync,
        RepositoryOperationOutcome.succeeded => Icons.check_circle_outline,
        RepositoryOperationOutcome.cancelled => Icons.cancel_outlined,
        RepositoryOperationOutcome.failed => Icons.error_outline,
      };

  /// 中文：将操作开始时间与已用时格式化为日志副标题；未完成的操作显示进行中。
  ///
  /// English: Formats an operation's start time and elapsed duration for its
  /// log subtitle, marking unfinished operations as running.
  String _operationTime(RepositoryOperationRecord operation) {
    final started = operation.startedAt.toLocal();
    final startedAt =
        '${_twoDigits(started.hour)}:${_twoDigits(started.minute)}';
    final completed = operation.completedAt;
    if (completed == null) {
      return '$startedAt 开始 · 进行中';
    }
    final seconds = completed.difference(operation.startedAt).inSeconds;
    return '$startedAt 开始 · 用时 ${seconds < 1 ? '< 1 秒' : '$seconds 秒'}';
  }

  /// 中文：将数字补齐为两位，供时间的小时和分钟显示使用。
  ///
  /// English: Pads a number to two digits for hour and minute display.
  String _twoDigits(int value) => value.toString().padLeft(2, '0');

  /// 中文：显示抓取配置弹框，并按用户选择更新远端引用。
  ///
  /// English: Shows the fetch configuration dialog and updates remote refs
  /// using the options explicitly selected by the user.
  Future<void> _showFetchDialog() async {
    final options = await showDialog<GitFetchOptions>(
      context: context,
      builder: (context) => const _FetchDialog(),
    );
    if (options == null || !mounted) return;
    final fetched = await ref
        .read(repositorySessionProvider.notifier)
        .fetchWithOptions(options);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(fetched ? '已抓取远端更新。' : '抓取未完成，请查看仓库状态和错误信息。'),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// 中文：请求并处理用户确认。
  /// English: Requests and handles user confirmation.
  Future<void> _confirmPull({String? preferredRemote}) async {
    final session = ref.read(repositorySessionProvider);
    final controller = ref.read(repositorySessionProvider.notifier);
    final branch = session.status?.branch;
    final localBranch = branch?.head;
    final upstream = branch?.upstream;
    if (localBranch == null) return;
    final separator = upstream?.indexOf('/') ?? -1;
    final upstreamRemote = separator > 0
        ? upstream!.substring(0, separator)
        : null;
    final upstreamBranch = separator > 0 && separator < upstream!.length - 1
        ? upstream.substring(separator + 1)
        : null;
    final remoteNames = <String>{...session.remoteNames, ?upstreamRemote};
    if (remoteNames.isEmpty) return;
    final branchesByRemote = <String, List<String>>{};
    for (final remoteName in remoteNames) {
      branchesByRemote[remoteName] = <String>[];
    }
    for (final remoteBranch in session.remoteBranches) {
      if (remoteBranch.isSymbolic) continue;
      final slash = remoteBranch.name.indexOf('/');
      if (slash > 0) {
        final remote = remoteBranch.name.substring(0, slash);
        remoteNames.add(remote);
        branchesByRemote
            .putIfAbsent(remote, () => <String>[])
            .add(remoteBranch.name.substring(slash + 1));
      }
    }
    if (upstreamRemote != null && upstreamBranch != null) {
      final branches = branchesByRemote.putIfAbsent(
        upstreamRemote,
        () => <String>[],
      );
      if (!branches.contains(upstreamBranch)) branches.add(upstreamBranch);
    }
    for (final branches in branchesByRemote.values) {
      branches.sort();
    }
    final selectedRemote = remoteNames.contains(preferredRemote)
        ? preferredRemote!
        : upstreamRemote ??
              (remoteNames.contains('origin') ? 'origin' : remoteNames.first);
    final selectedBranch =
        selectedRemote == upstreamRemote && upstreamBranch != null
        ? upstreamBranch
        : branchesByRemote[selectedRemote]?.firstOrNull ?? localBranch;
    String? initialRemoteUrl;
    try {
      initialRemoteUrl = await controller.readRemoteUrl(selectedRemote);
    } on Object {
      // The dialog retains its own recoverable URL-loading path.
    }
    if (!mounted) return;
    final options = await showDialog<GitPullOptions>(
      context: context,
      builder: (BuildContext context) => _PullDialog(
        remoteNames: remoteNames.toList()..sort(),
        branchesByRemote: branchesByRemote,
        selectedRemote: selectedRemote,
        remoteBranch: selectedBranch,
        localBranch: localBranch,
        remoteUrl: initialRemoteUrl,
        onRefresh: (remoteName) async {
          final fetched = await controller.fetchRemote(remoteName);
          if (!fetched) {
            throw const GitException('Unable to refresh the selected remote.');
          }
          final latest = ref.read(repositorySessionProvider);
          final refreshed = <String, List<String>>{};
          for (final remoteBranch in latest.remoteBranches) {
            if (remoteBranch.isSymbolic) continue;
            final slash = remoteBranch.name.indexOf('/');
            if (slash <= 0) continue;
            refreshed
                .putIfAbsent(remoteBranch.name.substring(0, slash), () => [])
                .add(remoteBranch.name.substring(slash + 1));
          }
          return _PullRefreshResult(
            branchesByRemote: refreshed,
            remoteUrl: await controller.readRemoteUrl(remoteName),
          );
        },
        onRemoteChanged: (remoteName) => ref
            .read(repositorySessionProvider.notifier)
            .readRemoteUrl(remoteName),
      ),
    );
    if (options == null || !mounted) return;
    final pulled = await ref
        .read(repositorySessionProvider.notifier)
        .pullWithOptions(options);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(pulled ? '已拉取更新。' : '未拉取，请查看仓库状态和错误信息。'),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _continueRebase() async {
    final continued = await ref
        .read(repositorySessionProvider.notifier)
        .continueRebase();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(continued ? '已继续变基。' : '变基尚未完成，请处理冲突后重试。'),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _confirmAbortRebase() async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('中止变基'),
        content: const Text('将放弃当前变基过程并恢复变基前的分支状态。此操作不会删除未提交文件。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('中止变基'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    await _abortRebase();
  }

  Future<void> _abortRebase() async {
    final aborted = await ref
        .read(repositorySessionProvider.notifier)
        .abortRebase();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(aborted ? '已中止变基。' : '中止变基失败，请查看仓库错误信息。'),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// 中文：继续当前暂停的遴选或回滚，并保留 Git 的冲突恢复语义。
  /// English: Continues the current paused cherry-pick or revert while
  /// preserving Git's conflict recovery semantics.
  Future<void> _continueSequencer() async {
    final operationState = ref.read(repositorySessionProvider).operationState;
    final isCherryPick =
        operationState == GitRepositoryOperationState.cherryPick;
    if (!isCherryPick && operationState != GitRepositoryOperationState.revert) {
      return;
    }
    final completed = isCherryPick
        ? await ref
              .read(repositorySessionProvider.notifier)
              .continueCherryPick()
        : await ref.read(repositorySessionProvider.notifier).continueRevert();
    if (!mounted) return;
    final operationName = isCherryPick ? '遴选' : '回滚';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          completed ? '已继续$operationName。' : '$operationName尚未完成，请处理冲突后重试。',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// 中文：在中止当前暂停的遴选或回滚前说明恢复范围。
  /// English: Confirms aborting a paused cherry-pick or revert before Git
  /// restores the branch to its pre-operation state.
  Future<void> _confirmAbortSequencer() async {
    final operationState = ref.read(repositorySessionProvider).operationState;
    final isCherryPick =
        operationState == GitRepositoryOperationState.cherryPick;
    if (!isCherryPick && operationState != GitRepositoryOperationState.revert) {
      return;
    }
    final operationName = isCherryPick ? '遴选' : '回滚';
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('中止$operationName'),
        content: Text('将放弃当前$operationName过程并恢复操作前的分支状态。此操作不会删除未提交文件。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('中止$operationName'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    final aborted = isCherryPick
        ? await ref.read(repositorySessionProvider.notifier).abortCherryPick()
        : await ref.read(repositorySessionProvider.notifier).abortRevert();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          aborted ? '已中止$operationName。' : '中止$operationName失败，请查看仓库错误信息。',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// 中文：显示多分支推送面板，并按用户选择执行非强制推送。
  ///
  /// English: Shows the multi-branch push panel and performs the selected
  /// non-force push operation.
  Future<void> _confirmPush({String? preferredRemote}) async {
    final session = ref.read(repositorySessionProvider);
    final controller = ref.read(repositorySessionProvider.notifier);
    final remoteNames = await controller.readRemoteNames();
    if (!mounted) return;
    if (remoteNames.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('当前仓库没有可推送的远端。')));
      return;
    }
    final upstream = session.status?.branch.upstream;
    final upstreamRemote = upstream?.split('/').first;
    final selectedRemote = remoteNames.contains(preferredRemote)
        ? preferredRemote!
        : remoteNames.contains(upstreamRemote)
        ? upstreamRemote!
        : remoteNames.contains('origin')
        ? 'origin'
        : remoteNames.first;
    final remoteBranchesByRemote = <String, List<String>>{};
    for (final remoteBranch in session.remoteBranches) {
      if (remoteBranch.isSymbolic) continue;
      final slash = remoteBranch.name.indexOf('/');
      if (slash <= 0 || slash == remoteBranch.name.length - 1) continue;
      remoteBranchesByRemote
          .putIfAbsent(remoteBranch.name.substring(0, slash), () => [])
          .add(remoteBranch.name.substring(slash + 1));
    }
    for (final branches in remoteBranchesByRemote.values) {
      branches.sort();
    }
    final initialRemoteUrl = await controller.readRemoteUrl(selectedRemote);
    if (!mounted) return;
    final options = await showDialog<GitPushOptions>(
      context: context,
      builder: (BuildContext context) => _PushDialog(
        localBranches: session.localBranches,
        remoteNames: remoteNames,
        remoteBranchesByRemote: remoteBranchesByRemote,
        selectedRemote: selectedRemote,
        initialRemoteUrl: initialRemoteUrl,
        onRemoteChanged: controller.readRemoteUrl,
      ),
    );
    if (options == null || !mounted) return;
    final pushed = await controller.pushWithOptions(options);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(pushed ? '已推送所选引用。' : '推送未完成，请查看仓库状态和错误信息。'),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// 中文：显示相应界面或信息。
  /// English: Shows the corresponding UI or information.
  Future<void> _showCommitDialog() async {
    final result = await showDialog<_CommitDialogResult>(
      context: context,
      builder: (BuildContext context) => const _CommitDialog(),
    );
    if (result == null || !mounted) {
      return;
    }

    final created = await ref
        .read(repositorySessionProvider.notifier)
        .createCommit(result.message, amend: result.amend);
    if (!mounted) {
      return;
    }
    if (created && result.pushAfterCommit) {
      final pushed = await ref
          .read(repositorySessionProvider.notifier)
          .pushUpstream();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(pushed ? '已创建提交并推送到上游。' : '已创建提交，但推送未完成，请查看仓库状态。'),
          duration: const Duration(seconds: 3),
        ),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(created ? '已创建提交。' : '提交未完成，请查看仓库错误信息。'),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// Opens the stash management panel and reloads its Git-backed list after
  /// each operation so reflog indexes never become stale in the UI.
  ///
  /// 中文：打开贮藏管理面板；每次操作后都重新读取 Git 列表，避免 reflog 索引
  /// 变化导致界面误操作其他贮藏。
  Future<void> _showStashManager() async {
    final controller = ref.read(repositorySessionProvider.notifier);
    while (mounted) {
      late final List<GitStashEntry> stashes;
      try {
        stashes = await controller.readStashes();
      } on Object {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法读取贮藏列表，请查看仓库错误信息。')));
        return;
      }
      if (!mounted) return;
      final result = await showDialog<_StashManagerResult>(
        context: context,
        builder: (BuildContext context) =>
            _StashManagerDialog(stashes: stashes),
      );
      if (result == null || !mounted) return;
      if (result.kind == _StashManagerAction.create) {
        await _showCreateStashDialog();
        continue;
      }

      final entry = result.entry!;
      final approved = await _confirmStashAction(result.kind, entry);
      if (approved != true || !mounted) continue;
      final succeeded = switch (result.kind) {
        _StashManagerAction.apply => await controller.applyStash(entry),
        _StashManagerAction.pop => await controller.popStash(entry),
        _StashManagerAction.drop => await controller.dropStash(entry),
        _StashManagerAction.create => false,
      };
      if (!mounted) return;
      final label = switch (result.kind) {
        _StashManagerAction.apply => '恢复贮藏',
        _StashManagerAction.pop => '恢复并弹出贮藏',
        _StashManagerAction.drop => '删除贮藏',
        _StashManagerAction.create => '创建贮藏',
      };
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(succeeded ? '已$label。' : '$label未完成，请查看仓库状态。')),
      );
    }
  }

  /// 中文：显示创建贮藏对话框，并在 Git 操作后展示可恢复的结果提示。
  /// English: Shows the create-stash dialog and reports the Git-backed result.
  Future<void> _showCreateStashDialog() async {
    final options = await showDialog<_CreateStashOptions>(
      context: context,
      builder: (BuildContext context) => const _CreateStashDialog(),
    );
    if (options == null || !mounted) return;
    final created = await ref
        .read(repositorySessionProvider.notifier)
        .createStash(options.message, keepIndex: options.keepIndex);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(created ? '已创建贮藏。' : '未创建贮藏，请确认有可保存的改动且不存在冲突。')),
    );
  }

  /// 中文：在执行会改变工作区或删除数据的贮藏操作前显示影响说明并请求确认。
  /// English: Explains a work-tree-changing or destructive stash action and
  /// requests confirmation before it is run.
  Future<bool?> _confirmStashAction(
    _StashManagerAction action,
    GitStashEntry entry,
  ) {
    final title = switch (action) {
      _StashManagerAction.apply => '恢复贮藏',
      _StashManagerAction.pop => '恢复并弹出贮藏',
      _StashManagerAction.drop => '删除贮藏',
      _StashManagerAction.create => '创建贮藏',
    };
    final content = switch (action) {
      _StashManagerAction.apply =>
        '将 ${entry.reference} 的改动写回当前工作区，并尝试恢复原有暂存区。该贮藏会保留。\n\n'
            '仅在工作区干净时执行；若发生冲突，Git 会保留贮藏和冲突文件。',
      _StashManagerAction.pop =>
        '将 ${entry.reference} 的改动写回当前工作区，并尝试恢复原有暂存区。\n\n'
            'Git 仅在恢复成功后删除该贮藏；若发生冲突，贮藏会保留。',
      _StashManagerAction.drop =>
        '将永久删除 ${entry.reference}。删除后无法从本应用恢复其中的改动。\n\n'
            '确定要删除“${entry.message}”吗？',
      _StashManagerAction.create => '',
    };
    final label = action == _StashManagerAction.drop ? '删除' : '继续';
    return showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: action == _StashManagerAction.drop
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  )
                : null,
            child: Text(label),
          ),
        ],
      ),
    );
  }

  /// 中文：显示带动画的分支管理面板，并执行新建、检出或安全删除操作。
  ///
  /// English: Shows the animated branch manager and executes the requested
  /// create, checkout, or safe-delete operation through the session layer.
  Future<void> _showBranchManagerDialog({String? initialCommitId}) async {
    final session = ref.read(repositorySessionProvider);
    final result = await showGeneralDialog<_BranchManagerResult>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '分支管理',
      barrierColor: Colors.black.withValues(alpha: .24),
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (context, animation, secondaryAnimation) =>
          _BranchManagerDialog(
            session: session,
            initialCommitId: initialCommitId,
          ),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, .08),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
    );
    if (result == null || !mounted) return;

    final controller = ref.read(repositorySessionProvider.notifier);
    bool completed;
    String message;
    if (result.action == _BranchManagerAction.create) {
      final branchName = result.branchName!;
      completed = result.sourceCommitId == null
          ? await controller.createLocalBranch(branchName)
          : await controller.createLocalBranchFromCommit(
              branchName,
              result.sourceCommitId!,
            );
      if (completed && result.checkout) {
        completed = await controller.switchToLocalBranch(branchName);
      }
      message = completed
          ? result.checkout
                ? '已创建并切换到分支 $branchName。'
                : '已创建本地分支 $branchName。'
          : '分支未创建，请查看仓库状态和错误信息。';
    } else {
      final approved = await _confirmBranchDeletion(result);
      if (!approved || !mounted) return;
      completed = await controller.deleteBranches(
        localBranchNames: result.localBranchNames,
        remoteBranchNames: result.remoteBranchNames,
        forceLocal: result.forceLocalDelete,
      );
      message = completed ? '已删除所选分支。' : '分支未完全删除；请查看仓库状态和错误信息。';
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  /// 中文：确认分支删除的范围、远端影响和本地强制删除风险。
  ///
  /// English: Confirms deletion scope, remote impact, and local force-delete
  /// risk before any destructive Git command is started.
  Future<bool> _confirmBranchDeletion(_BranchManagerResult result) async {
    final local = result.localBranchNames;
    final remote = result.remoteBranchNames;
    final details = <String>[
      if (local.isNotEmpty) '本地：${local.join('、')}',
      if (remote.isNotEmpty) '远端：${remote.join('、')}',
      if (result.forceLocalDelete && local.isNotEmpty)
        '将忽略合并状态强制删除所选本地分支；其中未合并提交可能无法通过分支引用找回。',
      if (remote.isNotEmpty) '远端分支删除会推送到对应远端，受远端权限与保护规则限制。',
    ].join('\n\n');
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('确认删除分支'),
            content: Text(details),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(true),
                icon: const Icon(Icons.delete_outline),
                label: const Text('删除分支'),
              ),
            ],
          ),
        ) ??
        false;
  }

  /// 中文：显示分支命名对话框，并以指定本地分支的提交创建新分支而不切换工作区。
  ///
  /// English: Shows the branch naming dialog and creates a branch at the
  /// selected local branch without switching the work tree.
  Future<void> _showCreateBranchFromReferenceDialog(String sourceName) async {
    final name = await showDialog<String>(
      context: context,
      builder: (BuildContext context) =>
          _CreateBranchDialog(sourceBranch: sourceName),
    );
    if (name == null || !mounted) return;

    final created = await ref
        .read(repositorySessionProvider.notifier)
        .createLocalBranchFromLocalBranch(name, sourceName);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          created ? '已从 $sourceName 创建本地分支 $name。' : '分支未创建，请查看仓库错误信息。',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// 中文：请求新名称并安全重命名指定本地分支。
  ///
  /// English: Requests a new name and safely renames the specified local
  /// branch.
  Future<void> _showRenameLocalBranchDialog(String oldName) async {
    final newName = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => RenameBranchDialog(oldName: oldName),
    );
    if (newName == null || !mounted) return;

    final renamed = await ref
        .read(repositorySessionProvider.notifier)
        .renameLocalBranch(oldName, newName);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          renamed ? '已将分支 $oldName 重命名为 $newName。' : '分支未重命名，请查看仓库错误信息。',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// 中文：确认删除一个非当前本地分支，并允许用户明确选择强制删除或同步删除其上游远端分支。
  ///
  /// English: Confirms deletion of a non-current local branch and lets the user
  /// explicitly opt into force deletion or deletion of its upstream remote ref.
  Future<void> _confirmDeleteLocalBranch(String branchName) async {
    final session = ref.read(repositorySessionProvider);
    final upstream = session.localBranches
        .where((branch) => branch.name == branchName)
        .map((branch) => branch.upstream)
        .firstOrNull;
    final remoteBranchName =
        upstream != null &&
            session.remoteBranches.any((branch) => branch.name == upstream)
        ? upstream
        : null;
    final result = await showDialog<DeleteLocalBranchDialogResult>(
      context: context,
      builder: (BuildContext context) => DeleteLocalBranchDialog(
        branchName: branchName,
        remoteBranchName: remoteBranchName,
      ),
    );
    if (result == null || !mounted) return;

    final deleted = await ref
        .read(repositorySessionProvider.notifier)
        .deleteBranches(
          localBranchNames: [branchName],
          remoteBranchNames: result.deleteRemote && remoteBranchName != null
              ? [remoteBranchName]
              : const [],
          forceLocal: result.force,
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(deleted ? '已删除分支 $branchName。' : '分支未完全删除；请查看仓库状态和错误信息。'),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// 中文：列出除当前分支外的本地分支，供用户选择合并到当前分支的来源。
  ///
  /// English: Lists local branches other than the current one so the user can
  /// choose a source to merge into the current branch.
  Future<void> _showMergeBranchDialog() async {
    final session = ref.read(repositorySessionProvider);
    final currentBranch = session.status?.branch.head;
    if (currentBranch == null) return;
    final sourceBranches = session.localBranches
        .map((branch) => branch.name)
        .where((name) => name != currentBranch)
        .toList(growable: false);
    if (sourceBranches.isEmpty) return;

    final sourceName = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('合并到 $currentBranch'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440, maxHeight: 360),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: sourceBranches.length,
            itemBuilder: (BuildContext context, int index) {
              final source = sourceBranches[index];
              return ListTile(
                leading: const Icon(Icons.call_split),
                title: Text(source),
                subtitle: Text('合并 $source 到 $currentBranch'),
                onTap: () => Navigator.of(context).pop(source),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (sourceName == null || !mounted) return;
    await _confirmMergeBranch(currentBranch, sourceName);
  }

  /// 中文：确认后将右键选中的历史提交合并到当前分支。
  ///
  /// English: Confirms merging the right-clicked historical commit into the
  /// currently checked-out branch.
  Future<void> _confirmMergeCommit(CommitViewData commit) async {
    final currentBranch = ref
        .read(repositorySessionProvider)
        .status
        ?.branch
        .head;
    if (currentBranch == null) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认合并提交'),
        content: Text(
          '将提交 ${commit.shortOid} 合并到 $currentBranch。Git 会保留冲突状态，'
          '不会自动继续或中止合并。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.merge_type),
            label: const Text('合并'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    final merged = await ref
        .read(repositorySessionProvider.notifier)
        .mergeCommit(commit.oid);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          merged
              ? '已将提交 ${commit.shortOid} 合并到 $currentBranch。'
              : '合并未完成；如存在冲突，请处理后使用 Git 命令行继续或中止合并，再刷新仓库。',
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  /// 中文：确认后把当前分支变基到右键选中的提交；变基会改写提交历史。
  /// English: Confirms rebasing the current branch onto the selected commit;
  /// rebasing rewrites local commit history.
  Future<void> _confirmRebaseOntoCommit(CommitViewData commit) async {
    final session = ref.read(repositorySessionProvider);
    final currentBranch = session.status?.branch.head;
    if (currentBranch == null) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('变基'),
        content: Text(
          '将 $currentBranch 变基到提交 ${commit.shortOid}。\n\n'
          '这会重写当前分支上该提交之后的本地历史。仅在工作区干净、且没有正在进行的 Git 操作时执行；'
          '如果这些提交已经推送给他人，请先确认协作影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.call_split),
            label: const Text('开始变基'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    final controller = ref.read(repositorySessionProvider.notifier);
    final completed = await controller.rebaseOntoCommit(commit.oid);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(completed ? '已完成变基。' : '变基未完成；请确认工作区干净并查看仓库状态。'),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  /// 中文：读取可编辑的 todo 列表，并在确认后按用户选择执行交互式变基。
  /// English: Reads an editable todo list and runs interactive rebase after
  /// the user confirms the chosen order and actions.
  Future<void> _showInteractiveRebaseDialog(CommitViewData commit) async {
    final controller = ref.read(repositorySessionProvider.notifier);
    final session = ref.read(repositorySessionProvider);
    final branchName = session.status?.branch.head;
    if (branchName == null) return;
    List<GitInteractiveRebaseInstruction> todo;
    try {
      todo = await controller.readInteractiveRebaseTodo(commit.oid);
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法读取交互式变基列表，请刷新仓库后重试。')));
      return;
    }
    if (!mounted) return;
    if (todo.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('当前分支没有可在此提交之后重放的提交。')));
      return;
    }
    final instructions =
        await showDialog<List<GitInteractiveRebaseInstruction>>(
          context: context,
          barrierDismissible: false,
          builder: (context) => _InteractiveRebaseDialog(
            branchName: branchName,
            upstreamCommit: commit,
            initialInstructions: todo,
          ),
        );
    if (instructions == null || !mounted) return;
    final completed = await controller.interactiveRebaseOntoCommit(
      commit.oid,
      instructions: instructions,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(completed ? '已完成交互式变基。' : '交互式变基未完成，请查看仓库状态。'),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  /// 中文：让用户选择重置模式，并在 hard 重置前明确说明可能丢失的改动。
  /// English: Lets the user choose a reset mode and explains data loss before
  /// a hard reset can be confirmed.
  Future<void> _confirmResetCurrentBranch(CommitViewData commit) async {
    final session = ref.read(repositorySessionProvider);
    final currentBranch = session.status?.branch.head;
    if (currentBranch == null) return;
    final result = await showDialog<GitResetMode>(
      context: context,
      builder: (context) => _ResetCommitDialog(
        branchName: currentBranch,
        commit: commit,
        hasWorkingChanges: !(session.status?.isClean ?? true),
      ),
    );
    if (result == null || !mounted) return;
    final completed = await ref
        .read(repositorySessionProvider.notifier)
        .resetCurrentBranchToCommit(commit.oid, mode: result);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          completed
              ? '已将 $currentBranch 重置到 ${commit.shortOid}。'
              : '重置未完成，请查看仓库状态和错误信息。',
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  /// 中文：确认后创建所选提交的反向提交，不移动已有分支历史。
  /// English: Confirms creation of an inverse commit without moving existing
  /// branch history.
  Future<void> _confirmRevertCommit(CommitViewData commit) async {
    int? mainlineParent;
    if (commit.parents.length > 1) {
      mainlineParent = await _selectMainlineParent(commit, operation: '回滚');
      if (mainlineParent == null || !mounted) return;
    }
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('提交回滚'),
        content: Text(
          '将创建一个新提交来撤销 ${commit.shortOid} 的改动。不会删除原提交；'
          '若出现冲突，Git 会保留冲突状态供你解决。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.undo),
            label: const Text('回滚提交'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    final completed = await ref
        .read(repositorySessionProvider.notifier)
        .revertCommit(commit.oid, mainlineParent: mainlineParent);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          completed ? '已创建 ${commit.shortOid} 的回滚提交。' : '回滚未完成，请查看仓库状态。',
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  /// 中文：确认后把右键选中的提交遴选到当前分支；提交信息会标记来源。
  /// English: Confirms cherry-picking the selected commit onto the current
  /// branch and records the source in the resulting commit message.
  Future<void> _confirmCherryPickCommit(CommitViewData commit) async {
    final currentBranch = ref
        .read(repositorySessionProvider)
        .status
        ?.branch
        .head;
    if (currentBranch == null) return;
    int? mainlineParent;
    if (commit.parents.length > 1) {
      mainlineParent = await _selectMainlineParent(commit, operation: '遴选');
      if (mainlineParent == null || !mounted) return;
    }
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('遴选提交'),
        content: Text(
          '将提交 ${commit.shortOid} 应用到当前分支 $currentBranch。'
          '若出现冲突，Git 会保留冲突状态供你解决。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.content_copy),
            label: const Text('遴选'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    final completed = await ref
        .read(repositorySessionProvider.notifier)
        .cherryPickCommit(commit.oid, mainlineParent: mainlineParent);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          completed ? '已遴选提交 ${commit.shortOid}。' : '遴选未完成，请查看仓库状态。',
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  /// 中文：合并提交需要用户指定主线父提交，Git 据此决定要保留的一侧。
  /// English: Lets the user choose the mainline parent Git needs for a merge
  /// commit revert or cherry-pick.
  Future<int?> _selectMainlineParent(
    CommitViewData commit, {
    required String operation,
  }) => showDialog<int>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('$operation合并提交'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('提交 ${commit.shortOid} 有多个父提交。请选择要保留为主线的一侧：'),
            const SizedBox(height: 8),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: commit.parents.length,
                itemBuilder: (context, index) => ListTile(
                  title: Text('父提交 ${index + 1}'),
                  subtitle: Text(commit.parents[index]),
                  onTap: () => Navigator.of(context).pop(index + 1),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    ),
  );

  /// 中文：要求用户选择补丁输出位置，然后通过应用层导出所选提交。
  /// English: Requests a user-selected patch destination, then exports the
  /// selected commit through the application layer.
  Future<void> _createPatchForCommit(CommitViewData commit) async {
    final location = await getSaveLocation(
      suggestedName:
          '${commit.shortOid}-${_safePatchFileStem(commit.subject)}.patch',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Git patch', extensions: ['patch']),
      ],
    );
    if (location == null || !mounted) return;
    final outputPath = location.path;
    final completed = await ref
        .read(repositorySessionProvider.notifier)
        .createPatchForCommit(commit.oid, outputPath: outputPath);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(completed ? '已创建补丁：$outputPath' : '未能创建补丁，请查看仓库状态。'),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  String _safePatchFileStem(String subject) {
    final normalized = subject
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    if (normalized.isEmpty) return 'commit';
    return normalized.length <= 48 ? normalized : normalized.substring(0, 48);
  }

  /// 中文：从 macOS“动作”菜单打开补丁创建窗口，选择已加载提交和输出位置。
  /// English: Opens the patch-export window from the native Action menu.
  Future<void> _showCreatePatchDialog() async {
    final session = ref.read(repositorySessionProvider);
    if (session.repository == null || session.historyCommits.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先打开包含提交历史的仓库。')));
      return;
    }
    final request = await showDialog<_PatchCreateRequest>(
      context: context,
      barrierDismissible: false,
      builder: (context) => Consumer(
        builder: (context, dialogRef, _) {
          final dialogSession = dialogRef.watch(repositorySessionProvider);
          // The workspace search field only filters the main history view.
          // Patch export must retain every loaded commit, otherwise a search
          // can silently remove the selected commit from this dialog.
          final repository = mapRepositoryOverview(
            dialogSession.copyWith(searchQuery: ''),
          ).repository;
          if (repository == null || repository.commits.isEmpty) {
            return AlertDialog(
              content: const Text('当前仓库没有可导出的提交。'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('关闭'),
                ),
              ],
            );
          }
          final controller = dialogRef.read(repositorySessionProvider.notifier);
          return _PatchCreateDialog(
            repository: repository,
            selectedCommitId: session.selectedCommitId,
            onCommitSelected: (commit) =>
                unawaited(controller.selectCommit(commit.oid)),
            onCommitFileSelected: (file) =>
                unawaited(controller.selectCommitFile(file)),
            onLoadMore: repository.hasMoreHistory
                ? () => unawaited(controller.loadMoreHistory())
                : null,
          );
        },
      ),
    );
    if (request == null || !mounted) return;
    final completed = await ref
        .read(repositorySessionProvider.notifier)
        .createPatches(
          request.commitIds,
          outputPath: request.outputPath,
          createSeparateFiles: request.createSeparateFiles,
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          completed ? '已创建补丁：${request.outputPath}' : '未能创建补丁，请查看仓库状态。',
        ),
      ),
    );
  }

  /// 中文：处理 macOS“动作”菜单的应用补丁请求；先复核实时仓库写入 capability，
  /// 可写时才打开窗口并根据用户选项检查或应用补丁。
  ///
  /// English: Handles Apply Patch from the native Action menu, revalidating
  /// the live repository mutation capability before opening the dialog.
  Future<void> _showApplyPatchDialog() async {
    final session = ref.read(repositorySessionProvider);
    final repository = mapRepositoryOverview(session).repository;
    if (repository == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先打开一个仓库。')));
      return;
    }
    if (repository.blocksRepositoryMutations) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前仓库正在执行任务或等待冲突恢复，暂时无法应用补丁。')),
      );
      return;
    }
    final request = await showDialog<_PatchApplyRequest>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const _PatchApplyDialog(),
    );
    if (request == null || !mounted) return;
    final completed = await ref
        .read(repositorySessionProvider.notifier)
        .applyPatchFile(
          patchPath: request.patchPath,
          stripLevel: request.stripLevel,
          basePath: request.basePath,
          checkOnly: request.checkOnly,
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          completed
              ? (request.checkOnly ? '补丁检查通过。' : '已应用补丁。')
              : '补丁未能应用，请查看仓库状态。',
        ),
      ),
    );
  }

  /// 中文：确认后将来源分支合并到当前分支，并提示成功或需要人工处理的冲突。
  ///
  /// English: Confirms merging a source branch into the current branch and
  /// reports success or a conflict that requires manual resolution.
  Future<void> _confirmMergeBranch(
    String currentBranch,
    String sourceName,
  ) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('确认合并分支'),
        content: Text(
          '将 $sourceName 合并到 $currentBranch。Git 会创建显式合并提交；'
          '若发生冲突，不会自动继续或中止，需先处理冲突再刷新仓库。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.merge_type),
            label: const Text('合并'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    final merged = await ref
        .read(repositorySessionProvider.notifier)
        .mergeLocalBranch(sourceName);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          merged
              ? '已将 $sourceName 合并到 $currentBranch。'
              : '合并未完成；如存在冲突，请处理后使用 Git 命令行继续或中止，再刷新仓库。',
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  /// 中文：处理当前事件。
  /// English: Handles the current event.
  /// 中文：双击提交时确认修改工作副本并进入分离 HEAD 状态。
  /// English: Confirms changing the working copy before checking out a commit.
  Future<void> _confirmCheckoutCommit(CommitViewData commit) async {
    final hasWorkingChanges =
        !(ref.read(repositorySessionProvider).status?.isClean ?? true);
    final workingChangesWarning = hasWorkingChanges
        ? '当前工作区有未提交改动。Git 只会在不会覆盖这些改动时完成检出。\n\n'
        : '';
    final approved = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('确认修改工作副本'),
        content: Text(
          '你确定你想要检出 ${commit.oid}？\n\n'
          '这样做会使你的工作区变成一个“分离的 HEAD”。这意味着你不能在任何一个分支上。'
          '如果你在这之后想要提交，你很可能会丢失这些提交；要么创建一个新的分支。\n\n'
          '$workingChangesWarning这样可以吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    final checkedOut = await ref
        .read(repositorySessionProvider.notifier)
        .checkoutCommit(commit.oid);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          checkedOut
              ? '已检出 ${commit.shortOid}（分离 HEAD）。'
              : '未检出提交，请确认工作区干净并查看仓库状态。',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _handleReferenceActivated(RepositoryRefViewData reference) {
    switch (reference.kind) {
      case RepositoryRefKind.localBranch when !reference.isCurrent:
        _confirmSwitchBranch(reference.label);
      case RepositoryRefKind.remoteBranch:
        _confirmSwitchRemoteBranch(reference.label);
      default:
        return;
    }
  }

  /// 中文：将引用右键菜单的安全操作路由到既有确认流程或仓库控制器。
  ///
  /// English: Routes safe reference context-menu actions through existing
  /// confirmation flows or the repository controller.
  void _handleReferenceContextAction(
    RepositoryRefViewData reference,
    RepositoryRefContextAction action,
  ) {
    switch (action) {
      case RepositoryRefContextAction.fetchOrigin:
        final remoteName = _remoteNameForReference(reference);
        if (remoteName != null) {
          unawaited(_fetchRemote(remoteName));
        } else {
          _handleAction(RepositoryAction.fetch);
        }
      case RepositoryRefContextAction.pullCurrentBranch:
        unawaited(
          _confirmPull(
            preferredRemote: reference.kind == RepositoryRefKind.remote
                ? reference.label
                : null,
          ),
        );
      case RepositoryRefContextAction.pushCurrentBranch:
        unawaited(
          _confirmPush(
            preferredRemote: reference.kind == RepositoryRefKind.remote
                ? reference.label
                : null,
          ),
        );
      case RepositoryRefContextAction.removeRemote:
        if (reference.kind == RepositoryRefKind.remote) {
          unawaited(_confirmRemoveRemote(reference.label));
        }
      case RepositoryRefContextAction.refresh:
        _handleAction(RepositoryAction.refresh);
      case RepositoryRefContextAction.checkout:
        _handleReferenceActivated(reference);
      case RepositoryRefContextAction.mergeIntoCurrent:
        if (reference.kind != RepositoryRefKind.localBranch ||
            reference.isCurrent) {
          return;
        }
        final currentBranch = ref
            .read(repositorySessionProvider)
            .status
            ?.branch
            .head;
        if (currentBranch != null) {
          unawaited(_confirmMergeBranch(currentBranch, reference.label));
        }
      case RepositoryRefContextAction.createBranchFromReference:
        if (reference.kind == RepositoryRefKind.localBranch) {
          unawaited(_showCreateBranchFromReferenceDialog(reference.label));
        }
      case RepositoryRefContextAction.renameLocalBranch:
        if (reference.kind == RepositoryRefKind.localBranch) {
          unawaited(_showRenameLocalBranchDialog(reference.label));
        }
      case RepositoryRefContextAction.deleteLocalBranch:
        if (reference.kind == RepositoryRefKind.localBranch &&
            !reference.isCurrent) {
          unawaited(_confirmDeleteLocalBranch(reference.label));
        }
      case RepositoryRefContextAction.createStash:
        unawaited(_showCreateStashDialog());
      case RepositoryRefContextAction.manageStashes:
        unawaited(_showStashManager());
    }
  }

  /// 中文：将提交右键操作路由到标签面板；标签始终以右键选中的提交为默认目标。
  ///
  /// English: Routes commit context actions to the tag panel, using the
  /// right-clicked commit as the default tag target.
  Future<void> _handleCommitContextAction(
    CommitViewData commit,
    RepositoryCommitContextAction action,
  ) async {
    switch (action) {
      case RepositoryCommitContextAction.checkout:
        await _confirmCheckoutCommit(commit);
        return;
      case RepositoryCommitContextAction.merge:
        await _confirmMergeCommit(commit);
        return;
      case RepositoryCommitContextAction.createBranch:
        await _showBranchManagerDialog(initialCommitId: commit.oid);
        return;
      case RepositoryCommitContextAction.copyCommitHash:
        await Clipboard.setData(ClipboardData(text: commit.oid));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已复制提交 SHA-1。'),
            duration: Duration(seconds: 2),
          ),
        );
        return;
      case RepositoryCommitContextAction.pushRevision:
        await _confirmPush();
        return;
      case RepositoryCommitContextAction.rebase:
        await _confirmRebaseOntoCommit(commit);
        return;
      case RepositoryCommitContextAction.interactiveRebase:
        await _showInteractiveRebaseDialog(commit);
        return;
      case RepositoryCommitContextAction.reset:
        await _confirmResetCurrentBranch(commit);
        return;
      case RepositoryCommitContextAction.revert:
        await _confirmRevertCommit(commit);
        return;
      case RepositoryCommitContextAction.createPatch:
        await _createPatchForCommit(commit);
        return;
      case RepositoryCommitContextAction.cherryPick:
        await _confirmCherryPickCommit(commit);
        return;
      case RepositoryCommitContextAction.tag:
        break;
    }
    if (!mounted) return;
    final session = ref.read(repositorySessionProvider);
    final result = await showGeneralDialog<_TagDialogResult>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '标签',
      barrierColor: Colors.black.withValues(alpha: .24),
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (context, animation, secondaryAnimation) =>
          _TagDialog(session: session, defaultCommitId: commit.oid),
      transitionBuilder: (context, animation, secondaryAnimation, child) =>
          FadeTransition(
            opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
            child: ScaleTransition(
              scale: Tween<double>(begin: .96, end: 1).animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
              ),
              child: child,
            ),
          ),
    );
    if (result == null || !mounted) return;

    final controller = ref.read(repositorySessionProvider.notifier);
    final completed = switch (result) {
      _CreateTagDialogResult(:final options) => await controller.createTag(
        options,
      ),
      _DeleteTagDialogResult(:final options) =>
        await _confirmTagDeletion(options) && mounted
            ? await controller.deleteTag(options)
            : false,
    };
    if (!mounted) return;
    final sessionAfterOperation = ref.read(repositorySessionProvider);
    final operationMessage = sessionAfterOperation.message;
    final createdLocally = switch (result) {
      _CreateTagDialogResult(:final options)
          when !completed &&
              options.pushRemoteName != null &&
              sessionAfterOperation.tags.any(
                (tag) => tag.name == options.name.trim(),
              ) =>
        true,
      _ => false,
    };
    final message = switch (result) {
      _CreateTagDialogResult(:final options) =>
        completed
            ? options.pushRemoteName == null
                  ? '已添加标签 ${options.name}。'
                  : '已添加标签 ${options.name} 并推送到 ${options.pushRemoteName}。'
            : createdLocally
            ? '已创建本地标签 ${options.name}，但推送到 ${options.pushRemoteName} 失败：${operationMessage ?? '请检查远端和认证。'}'
            : '标签未添加：${operationMessage ?? '请检查标签名、当前提交和仓库状态。'}',
      _DeleteTagDialogResult(:final options) =>
        completed
            ? options.deleteRemoteName == null
                  ? '已删除本地标签 ${options.name}。'
                  : '已从本地和 ${options.deleteRemoteName} 删除标签 ${options.name}。'
            : '标签未完全删除：${operationMessage ?? '请查看仓库状态和错误信息。'}',
    };
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  /// 中文：在删除前明确提示本地和远端引用的不可逆影响。
  /// English: Explicitly confirms the irreversible local and optional remote
  /// ref removal before any Git delete command begins.
  Future<bool> _confirmTagDeletion(GitDeleteTagOptions options) async {
    final remote = options.deleteRemoteName;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('确认删除标签'),
            content: Text(
              remote == null
                  ? '将删除本地标签 ${options.name}。该引用将无法通过界面恢复。'
                  : '将删除本地标签 ${options.name}，并推送删除到远端 $remote。远端协作者将不再看到该标签。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(true),
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                ),
                icon: const Icon(Icons.delete_outline),
                label: const Text('删除标签'),
              ),
            ],
          ),
        ) ??
        false;
  }

  /// 中文：从引用数据解析其所属远端，供上下文菜单执行精确操作。
  /// English: Resolves the configured remote owned by one reference for exact
  /// context-menu operations.
  String? _remoteNameForReference(RepositoryRefViewData reference) {
    if (reference.kind == RepositoryRefKind.remote) return reference.label;
    if (reference.kind != RepositoryRefKind.remoteBranch) return null;
    final candidates =
        ref
            .read(repositorySessionProvider)
            .remoteNames
            .where((name) => reference.label.startsWith('$name/'))
            .toList(growable: false)
          ..sort((a, b) => b.length.compareTo(a.length));
    return candidates.firstOrNull;
  }

  /// 中文：获取指定远端并显示该远端操作的明确反馈。
  /// English: Fetches one named remote and reports its explicit outcome.
  Future<void> _fetchRemote(String remoteName) async {
    final fetched = await ref
        .read(repositorySessionProvider.notifier)
        .fetchRemote(remoteName);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          fetched ? '已从 $remoteName 获取更新。' : '未能从 $remoteName 获取更新，请查看仓库状态。',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// 中文：确认移除本地远端配置；不会删除远端仓库或远端分支。
  /// English: Confirms removal of a local remote configuration only.
  Future<void> _confirmRemoveRemote(String remoteName) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('移除 $remoteName'),
        content: Text(
          '这会从本地仓库移除 $remoteName 的远端配置及其远端跟踪引用。'
          '不会删除远端仓库或其上的分支。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.remove_circle_outline),
            label: const Text('移除远端'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    final removed = await ref
        .read(repositorySessionProvider.notifier)
        .removeRemote(remoteName);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          removed ? '已移除远端 $remoteName。' : '未移除远端 $remoteName，请查看仓库状态。',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// 中文：确认后切换到本地分支；由 Git 判断未提交改动是否可安全保留。
  /// English: Confirms a local branch switch and lets Git decide whether
  /// uncommitted changes can be carried safely.
  Future<void> _confirmSwitchBranch(String branchName) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('切换分支'),
        content: Text('切换到 $branchName？未提交改动会保留；如果切换会覆盖改动，Git 将拒绝执行。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.swap_horiz),
            label: const Text('切换'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) {
      return;
    }

    final switched = await ref
        .read(repositorySessionProvider.notifier)
        .switchToLocalBranch(branchName);
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          switched ? '已切换到 $branchName。' : '未切换分支，请确认工作区干净并查看仓库错误信息。',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// 中文：确认后基于已获取的远端跟踪引用创建本地分支并切换过去。
  ///
  /// English: Confirms creation of a local branch from an already fetched
  /// remote-tracking ref, then switches to it.
  Future<void> _confirmSwitchRemoteBranch(String remoteName) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('检出远端分支'),
        content: Text(
          '将基于已获取的 $remoteName 创建本地跟踪分支并切换过去。'
          '仅当工作区和暂存区均无改动时才会执行。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.download_outlined),
            label: const Text('创建并切换'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;

    final switched = await ref
        .read(repositorySessionProvider.notifier)
        .switchToRemoteBranch(remoteName);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          switched
              ? '已创建本地跟踪分支并切换到 $remoteName。'
              : '未检出远端分支；请确认工作区干净、引用仍存在并查看仓库错误信息。',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// 中文：将冲突菜单操作分流到内部 Diff 或直接的 Git 解决命令。
  ///
  /// English: Routes a conflict-menu action to the internal Diff or a direct
  /// Git resolution command.
  Future<void> _handleConflictAction(
    RepositoryChangeViewData change,
    RepositoryConflictAction action,
  ) async {
    final controller = ref.read(repositorySessionProvider.notifier);
    if (action != RepositoryConflictAction.launchInternalDiffTool) {
      await controller.resolveConflict(change, action);
      return;
    }

    final versions = await controller.readConflictVersions(change);
    if (!mounted) return;
    if (versions == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法读取冲突版本，请刷新后重试。')));
      return;
    }
    final branch = ref.read(repositorySessionProvider).status?.branch.head;
    final operation = ref.read(repositorySessionProvider).operationState;
    final labels = conflictVersionLabels(
      operation,
      currentBranch: branch ?? '当前分支',
    );
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => InternalConflictResolverDialog(
        path: versions.path.display,
        currentBranch: branch ?? '当前分支',
        oursText: versions.oursText,
        theirsText: versions.theirsText,
        workingText: versions.workingText,
        oursLabel: labels.$1,
        theirsLabel: labels.$2,
        isBinary: versions.isBinary,
        isTruncated: versions.isTruncated,
      ),
    );
    if (result == null || !mounted) return;

    final resolved = await controller.resolveConflictWithContent(
      change,
      result,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            resolved ? '已保存 ${change.path} 并标记为已解决。' : '未能保存冲突结果，请查看仓库错误信息。',
          ),
        ),
      );
  }

  /// 中文：在 Finder 中定位选中的工作区文件。
  /// English: Reveals selected working-tree files in Finder.
  Future<void> _revealChangesInFinder(
    List<RepositoryChangeViewData> changes,
  ) async {
    final root = ref.read(repositorySessionProvider).repository?.workTreeRoot;
    if (root == null || changes.isEmpty) return;
    final paths = <String>[];
    for (final change in changes) {
      final path = _workspaceChangePath(root, change.path);
      if (path != null) paths.add(path);
    }
    if (paths.isEmpty) return;
    try {
      final result = await Process.run('/usr/bin/open', ['-R', ...paths]);
      if (!mounted || result.exitCode == 0) return;
    } on Object {
      if (!mounted) return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('无法在 Finder 中显示所选文件。')));
  }

  /// Confirms deletion of selected staged or unstaged working-tree files.
  ///
  /// 中文：确认删除暂存或未暂存列表中选中文件的工作区副本。删除不会直接
  /// 改写 Git 索引或提交历史，但未提交且未暂存的本地内容将无法恢复。
  Future<void> _removeChanges(List<RepositoryChangeViewData> changes) async {
    if (changes.isEmpty) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除修改过的或未被跟踪的文件？'),
        content: Text(
          '下列文件包含了不在版本控制内的变更或信息，若它们被删除，将无法被找回：\n\n'
          '${changes.map((change) => change.path).toSet().join('\n')}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;

    final removal = await ref
        .read(repositorySessionProvider.notifier)
        .removeChanges(changes);
    if (!mounted) return;
    final String message;
    if (removal == null) {
      message = '未能移除所选文件；仓库状态可能已经变化，请刷新后重试。';
    } else if (removal.hasFailures) {
      final completed = removal.removedPaths.length;
      message = completed == 0
          ? '未能移除 ${removal.failedPaths.length} 个文件：\n'
                '${removal.failedPaths.join('\n')}\n'
                '失败目录可能已有部分内容被删除，请检查工作区。'
          : '已移除 $completed 个文件，${removal.failedPaths.length} 个删除失败：\n'
                '${removal.failedPaths.join('\n')}\n'
                '失败目录可能已有部分内容被删除，请检查工作区。';
    } else if (removal.removedPaths.isEmpty) {
      message = '所选 ${removal.missingPaths.length} 个文件已不在工作区。';
    } else if (removal.missingPaths.isNotEmpty) {
      message =
          '已从工作区移除 ${removal.removedPaths.length} 个文件；'
          '另有 ${removal.missingPaths.length} 个文件已不存在。';
    } else {
      message = '已从工作区移除 ${removal.removedPaths.length} 个文件。';
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Confirms stopping Git tracking while retaining the selected local files.
  ///
  /// 中文：明确说明索引删除和后续提交的影响；实际执行前由应用层重新读取
  /// Git 状态，确保确认窗口期间发生的外部改动不会作用到过期选择。
  Future<void> _stopTrackingChanges(
    List<RepositoryChangeViewData> changes,
  ) async {
    final supported =
        changes.isNotEmpty && changes.every((change) => change.canStopTracking);
    if (!supported) return;

    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('停止追踪文件'),
        content: Text(
          '这会从 Git 索引移除以下 ${changes.length} 个文件，但保留本地文件。\n\n'
          '${changes.map((change) => change.path).join('\n')}\n\n'
          '对于已有提交的文件，操作后会留下待提交的删除记录；只有提交后才会停止版本追踪。'
          '已暂存但尚未提交的新增文件会恢复为未追踪状态。\n\n'
          '若不将路径加入 .gitignore，这些文件之后仍可能被再次添加。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('停止追踪'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;

    final stopped = await ref
        .read(repositorySessionProvider.notifier)
        .stopTrackingChanges(changes);
    if (!mounted) return;
    if (stopped) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已从索引移除 ${changes.length} 个文件；已有提交的文件请提交暂存的删除记录。'),
        ),
      );
      return;
    }
    if (ref.read(repositorySessionProvider).phase ==
        RepositorySessionPhase.ready) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('选中的文件状态已变化，请刷新后重试。')));
    }
  }

  /// Confirms stopping tracking for the selected historical file path.
  ///
  /// 中文：确认是否对历史提交文件列表中选择的路径停止追踪；执行时仍由会话层
  /// 重读当前工作区和索引，避免将历史快照中的路径直接作为写入依据。
  Future<void> _stopTrackingSelectedCommitFile() async {
    final selected = ref.read(repositorySessionProvider).selectedCommitFile;
    if (selected == null || !selected.file.path.isValidUtf8) return;
    final selectedPath = selected.file.path.display;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('停止追踪文件'),
        content: Text(
          '这会从当前工作区的 Git 索引移除以下历史文件，但保留本地文件。\n\n'
          '$selectedPath\n\n'
          '操作后会留下待提交的删除记录；只有提交后才会停止版本追踪。\n\n'
          '若文件已不在当前索引中、已删除或状态不再安全，操作将不会执行。'
          '若不将路径加入 .gitignore，文件之后仍可能被再次添加。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('停止追踪'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;

    final stopped = await ref
        .read(repositorySessionProvider.notifier)
        .stopTrackingSelectedCommitFile();
    if (!mounted) return;
    if (stopped) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已从索引移除文件；请提交暂存的删除记录。')));
      return;
    }
    if (ref.read(repositorySessionProvider).phase ==
        RepositorySessionPhase.ready) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('历史文件未在当前工作区安全追踪，请刷新后重试。')));
    }
  }

  /// Confirms resetting selected tracked files to HEAD in index and work tree.
  ///
  /// 中文：确认将所选已暂存已跟踪文件的索引和工作区同时恢复到 HEAD；执行前由
  /// 应用层重新读取 Git 状态，避免确认期间的外部改动影响过期选择。
  Future<void> _resetChangesToHead(
    List<RepositoryChangeViewData> changes,
  ) async {
    final supported =
        changes.isNotEmpty && changes.every((change) => change.canResetToHead);
    if (!supported) return;

    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重置文件到 HEAD'),
        content: Text(
          '这会将以下 ${changes.length} 个文件的索引和工作区恢复到 HEAD 版本：\n\n'
          '${changes.map((change) => change.path).join('\n')}\n\n'
          '该文件的已暂存和未暂存改动都会永久丢失，无法通过提交恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('重置文件'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;

    final reset = await ref
        .read(repositorySessionProvider.notifier)
        .resetChangesToHead(changes);
    if (!mounted) return;
    if (reset) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已将 ${changes.length} 个文件重置到 HEAD。')),
      );
      return;
    }
    if (ref.read(repositorySessionProvider).phase ==
        RepositorySessionPhase.ready) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('选中的文件状态已变化，请刷新后重试。')));
    }
  }

  /// Routes one source-specific Diff hunk action through the session layer.
  ///
  /// Staging and unstaging are reversible index operations and run directly.
  /// Discarding working-tree content or reverse-applying a committed hunk first
  /// explains the impact and requires confirmation. Every mutation uses the
  /// raw Diff retained by the session so Git can reject stale context.
  ///
  /// 中文：根据 Diff 来源路由区块操作。暂存和取消暂存只修改索引，可直接执行；
  /// 放弃未暂存内容或反向应用已提交区块前会解释影响并要求确认。所有写入都使用
  /// 会话保留的原始 Diff，让 Git 拒绝已经过期的上下文。
  Future<void> _handleDiffHunkAction(
    RepositoryDiffHunkAction action,
    int hunkIndex,
  ) async {
    if (hunkIndex < 0) return;
    final session = ref.read(repositorySessionProvider);
    if (action == RepositoryDiffHunkAction.discard) {
      final change = session.selectedChange;
      if (change == null || session.diff == null || change.isStaged) return;
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('放弃区块'),
          content: Text(
            '将把 ${change.entry.path.display} 的此区块恢复到暂存区版本。'
            '该区块的未暂存内容会永久丢失，无法通过提交恢复。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('放弃区块'),
            ),
          ],
        ),
      );
      if (approved != true || !mounted) return;
    } else if (action == RepositoryDiffHunkAction.revertCommitted) {
      final selected = session.selectedCommitFile;
      if (selected == null || session.commitDiff == null) return;
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('回滚已提交区块'),
          content: Text(
            '将把 ${selected.file.path.display} 在所选提交中的此区块反向应用到当前工作区。'
            '原提交和历史不会改变，工作区会产生一条新的未提交改动；若当前内容不匹配，'
            'Git 会拒绝操作。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('回滚区块'),
            ),
          ],
        ),
      );
      if (approved != true || !mounted) return;
    }

    final controller = ref.read(repositorySessionProvider.notifier);
    final succeeded = switch (action) {
      RepositoryDiffHunkAction.stage => await controller.stageSelectedDiffHunk(
        hunkIndex,
      ),
      RepositoryDiffHunkAction.discard || RepositoryDiffHunkAction.unstage =>
        await controller.revertSelectedDiffHunk(hunkIndex),
      RepositoryDiffHunkAction.revertCommitted =>
        await controller.revertSelectedCommitDiffHunk(hunkIndex),
    };
    if (!mounted) return;
    if (succeeded) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(switch (action) {
            RepositoryDiffHunkAction.stage => '已暂存该区块。',
            RepositoryDiffHunkAction.discard => '已放弃该区块。',
            RepositoryDiffHunkAction.unstage => '已取消暂存该区块。',
            RepositoryDiffHunkAction.revertCommitted => '已将该提交区块回滚到当前工作区。',
          }),
        ),
      );
      return;
    }
    if (ref.read(repositorySessionProvider).phase ==
        RepositorySessionPhase.ready) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('区块或文件状态已变化，请刷新后重试。')));
    }
  }

  /// Routes one historical-file context-menu action through the application
  /// layer.
  ///
  /// 中文：将历史提交文件右键菜单动作路由至应用层。查看修改日志只读取 Git
  /// 历史和 Diff；其他待实现动作仍只显示无副作用提示。
  void _handleCommitFileContextAction(
    CommitFileViewData file,
    RepositoryCommitFileContextAction action,
  ) {
    if (action == RepositoryCommitFileContextAction.viewSelectedFileLog) {
      unawaited(_showSelectedFileHistory(file));
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('“${file.path}”的该菜单功能待实现。')));
  }

  /// Opens a focused, read-only history window for one historical file.
  ///
  /// 中文：为一个历史提交文件打开聚焦的只读历史窗口。窗口使用会话应用层读取
  /// Git，不改写主工作区的提交、文件或 Diff 选择。
  Future<void> _showSelectedFileHistory(CommitFileViewData file) async {
    final session = ref.read(repositorySessionProvider);
    if (!file.isPathValidUtf8 ||
        session.phase != RepositorySessionPhase.ready ||
        session.repository == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('当前没有可读取修改日志的仓库。')));
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => _FileHistoryDialog(
        path: file.path,
        loadHistory: (path, cancellationToken) => ref
            .read(repositorySessionProvider.notifier)
            .readFileHistory(
              path,
              sourceCommitId: session.selectedCommitId,
              cancellationToken: cancellationToken,
            ),
        loadCommitChanges: (commit, cancellationToken) => ref
            .read(repositorySessionProvider.notifier)
            .readFileHistoryCommitChanges(
              commit,
              cancellationToken: cancellationToken,
            ),
        loadCommitDiff: (commit, path, cancellationToken) => ref
            .read(repositorySessionProvider.notifier)
            .readFileHistoryCommitDiff(
              commit,
              path: path,
              cancellationToken: cancellationToken,
            ),
      ),
    );
  }

  String? _workspaceChangePath(String root, String changePath) {
    final target = path_utils.normalize(path_utils.join(root, changePath));
    return path_utils.isWithin(root, target) ? target : null;
  }

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    ref.listen<GitAskPassRequest?>(gitAskPassPromptCoordinatorProvider, (
      previous,
      next,
    ) {
      if (next != null && !_isAskPassDialogVisible) {
        _isAskPassDialogVisible = true;
        unawaited(_showAskPassPrompt(next));
      } else if (next == null && previous != null && _isAskPassDialogVisible) {
        _isAskPassDialogVisible = false;
        unawaited(Navigator.of(context, rootNavigator: true).maybePop());
      }
    });
    ref.listen<RepositorySessionState>(
      repositorySessionProvider,
      _handleRepositoryStateChange,
    );
    final session = ref.watch(repositorySessionProvider);
    final controller = ref.read(repositorySessionProvider.notifier);
    final overview = mapRepositoryOverview(session);
    unawaited(_syncNativeWorkspaceMenuAvailability(session, overview));
    return Scaffold(
      body: Stack(
        children: [
          RepositoryOverview(
            data: overview,
            toolbarTrailing: widget.themeControl,
            callbacks: RepositoryOverviewCallbacks(
              onAction: _handleAction,
              onRefSelected: (reference) {
                unawaited(controller.selectReference(reference));
                if (reference.kind == RepositoryRefKind.stash) {
                  if (reference.stashReference == null) {
                    unawaited(_showCreateStashDialog());
                  }
                }
              },
              onRefActivated: _handleReferenceActivated,
              onRefContextAction: _handleReferenceContextAction,
              onSearchChanged: controller.setSearchQuery,
              onLoadMoreHistory: () => unawaited(controller.loadMoreHistory()),
              onCommitSelected: (commit) =>
                  unawaited(controller.selectCommit(commit.oid)),
              onCommitActivated: (commit) =>
                  unawaited(_confirmCheckoutCommit(commit)),
              onCommitContextAction: (commit, action) =>
                  unawaited(_handleCommitContextAction(commit, action)),
              onUncommittedChangesSelected: controller.selectUncommittedChanges,
              onCommitFileSelected: (file) =>
                  unawaited(controller.selectCommitFile(file)),
              onCommitFileContextAction: _handleCommitFileContextAction,
              onChangeSelected: controller.selectChange,
              onChangeStageToggled: controller.toggleStage,
              onChangeGroupStageToggled: (changes, stage) =>
                  controller.toggleStageGroup(changes, stage: stage),
              onConflictAction: (change, action) =>
                  unawaited(_handleConflictAction(change, action)),
              onChangeRevealInFinder: (changes) =>
                  unawaited(_revealChangesInFinder(changes)),
              onChangeRemove: (changes) => unawaited(_removeChanges(changes)),
              onChangeStopTracking: (changes) =>
                  unawaited(_stopTrackingChanges(changes)),
              onChangeReset: (changes) =>
                  unawaited(_resetChangesToHead(changes)),
              onDiffHunkAction: (action, hunkIndex) =>
                  unawaited(_handleDiffHunkAction(action, hunkIndex)),
            ),
          ),
          if (overview.repository == null && widget.themeControl != null)
            Positioned(
              top: 8,
              right: 8,
              child: SafeArea(child: widget.themeControl!),
            ),
        ],
      ),
    );
  }
}

/// A Sourcetree-style, focused read-only history surface for one file.
///
/// The dialog owns only transient presentation state. Every displayed commit,
/// change summary and diff comes from the application-layer callbacks, so it
/// cannot mutate repository state or overwrite the workspace selection.
///
/// 中文：一个文件的 Sourcetree 风格聚焦只读历史界面。对话框只拥有短暂的
/// 展示状态；每一条提交、改动摘要和 Diff 都由应用层回调读取，因此不会修改
/// 仓库状态或覆盖主工作区选择。
final class _FileHistoryDialog extends StatefulWidget {
  const _FileHistoryDialog({
    required this.path,
    required this.loadHistory,
    required this.loadCommitChanges,
    required this.loadCommitDiff,
  });

  final String path;
  final Future<List<GitFileHistoryEntry>> Function(
    String path,
    GitCancellationToken cancellationToken,
  )
  loadHistory;
  final Future<GitCommitChangeSummary> Function(
    GitCommit commit,
    GitCancellationToken cancellationToken,
  )
  loadCommitChanges;
  final Future<GitUnifiedDiff> Function(
    GitCommit commit,
    String path,
    GitCancellationToken cancellationToken,
  )
  loadCommitDiff;

  @override
  State<_FileHistoryDialog> createState() => _FileHistoryDialogState();
}

final class _FileHistoryDialogState extends State<_FileHistoryDialog> {
  List<GitFileHistoryEntry>? _history;
  GitFileHistoryEntry? _selectedEntry;
  GitCommitChangeSummary? _summary;
  GitUnifiedDiff? _diff;
  Object? _historyError;
  Object? _detailError;
  var _isLoadingHistory = true;
  var _isLoadingDetails = false;
  var _detailGeneration = 0;
  GitCancellationToken? _historyCancellation;
  GitCancellationToken? _detailCancellation;

  /// Starts the first cancellable history read for this dialog instance.
  ///
  /// 中文：为当前弹窗实例启动首次可取消的文件历史读取。
  @override
  void initState() {
    super.initState();
    unawaited(_loadHistory());
  }

  /// Cancels dialog-owned Git reads before this local UI state is destroyed.
  ///
  /// 中文：弹窗销毁前取消其持有的文件历史、提交摘要和 Diff Git 读取，避免关闭
  /// 窗口后继续占用子进程与输出缓冲区。
  @override
  void dispose() {
    _detailGeneration++;
    _historyCancellation?.cancel();
    _detailCancellation?.cancel();
    super.dispose();
  }

  /// Reads the selected path's history when the dialog first opens.
  ///
  /// 中文：首次打开对话框时读取所选路径的历史；关闭后的回调不会更新已销毁的
  /// Widget。
  Future<void> _loadHistory() async {
    _historyCancellation?.cancel();
    final cancellation = GitCancellationToken();
    _historyCancellation = cancellation;
    try {
      final history = await widget.loadHistory(widget.path, cancellation);
      if (!mounted || cancellation.isCancelled) return;
      setState(() {
        _history = history;
        _isLoadingHistory = false;
      });
      if (history.isNotEmpty) {
        await _selectHistoryEntry(history.first);
      }
    } on Object catch (error) {
      if (!mounted || cancellation.isCancelled) return;
      setState(() {
        _historyError = error;
        _isLoadingHistory = false;
      });
    } finally {
      if (identical(_historyCancellation, cancellation)) {
        _historyCancellation = null;
      }
    }
  }

  /// Selects a history row and then loads its concrete changed files and diff.
  ///
  /// 中文：选择一条历史记录并读取其实际改动文件和 Diff。递增代次可使较早的
  /// 异步回调失效，快速切换提交时不会显示错误的差异。
  Future<void> _selectHistoryEntry(GitFileHistoryEntry entry) async {
    final generation = ++_detailGeneration;
    _detailCancellation?.cancel();
    final cancellation = GitCancellationToken();
    _detailCancellation = cancellation;
    setState(() {
      _selectedEntry = entry;
      _summary = null;
      _diff = null;
      _detailError = null;
      _isLoadingDetails = true;
    });
    try {
      final summary = await widget.loadCommitChanges(
        entry.commit,
        cancellation,
      );
      if (!mounted ||
          cancellation.isCancelled ||
          generation != _detailGeneration) {
        return;
      }
      setState(() {
        _summary = summary;
      });
      final diff = await widget.loadCommitDiff(
        entry.commit,
        entry.path.display,
        cancellation,
      );
      if (!mounted ||
          cancellation.isCancelled ||
          generation != _detailGeneration) {
        return;
      }
      setState(() {
        _diff = diff;
        _isLoadingDetails = false;
      });
    } on Object catch (error) {
      if (!mounted ||
          cancellation.isCancelled ||
          generation != _detailGeneration) {
        return;
      }
      setState(() {
        _detailError = error;
        _isLoadingDetails = false;
      });
    } finally {
      if (identical(_detailCancellation, cancellation)) {
        _detailCancellation = null;
      }
    }
  }

  /// Builds the bounded three-pane history dialog from dialog-local state.
  ///
  /// 中文：根据弹窗局部状态构建带尺寸约束的文件历史三栏界面。
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1180, maxHeight: 760),
        child: SizedBox(
          width: 1080,
          height: 680,
          child: Column(
            children: [
              Container(
                height: 42,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                color: colors.surfaceContainerHigh,
                child: Row(
                  children: [
                    const Icon(Icons.history, size: 19),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '修改日志：${widget.path}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      icon: const Icon(Icons.close, size: 19),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: colors.outlineVariant),
              Expanded(
                child: Row(
                  children: [
                    SizedBox(width: 432, child: _buildHistoryList(context)),
                    VerticalDivider(width: 1, color: colors.outlineVariant),
                    Expanded(child: _buildDiffPane(context)),
                  ],
                ),
              ),
              Divider(height: 1, color: colors.outlineVariant),
              Container(
                height: 46,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                color: colors.surfaceContainerLow,
                child: Row(
                  children: [
                    Text(
                      _history == null ? '正在读取历史…' : '${_history!.length} 个提交',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('关闭'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Builds the loading, error, empty, or selectable file-history list.
  ///
  /// 中文：构建文件历史列表，并覆盖加载、错误、空结果和可选择记录状态。
  Widget _buildHistoryList(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (_isLoadingHistory) {
      return const Center(child: CircularProgressIndicator.adaptive());
    }
    if (_historyError != null) {
      return _FileHistoryMessage(
        icon: Icons.error_outline,
        title: '无法读取修改日志',
        message: _historyError.toString(),
      );
    }
    final history = _history!;
    if (history.isEmpty) {
      return const _FileHistoryMessage(
        icon: Icons.history_toggle_off_outlined,
        title: '没有匹配的提交',
        message: '当前分支中没有这个文件的已提交修改。',
      );
    }
    return Column(
      children: [
        Container(
          height: 31,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          color: colors.surfaceContainerHigh,
          child: const Row(
            children: [
              SizedBox(width: 68, child: Text('提交号')),
              SizedBox(width: 78, child: Text('日期')),
              SizedBox(width: 78, child: Text('用户')),
              Expanded(child: Text('描述')),
            ],
          ),
        ),
        Divider(height: 1, color: colors.outlineVariant),
        Expanded(
          child: ListView.builder(
            itemCount: history.length,
            itemExtent: 34,
            itemBuilder: (context, index) {
              final entry = history[index];
              final commit = entry.commit;
              final selected =
                  commit.objectId == _selectedEntry?.commit.objectId;
              final shortId = commit.objectId.substring(
                0,
                math.min(8, commit.objectId.length),
              );
              final date = commit.author.when.toLocal();
              final dateLabel = '${date.month}/${date.day}';
              return InkWell(
                onTap: () => unawaited(_selectHistoryEntry(entry)),
                child: Container(
                  color: selected ? colors.primary : null,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  alignment: Alignment.centerLeft,
                  child: DefaultTextStyle(
                    style: Theme.of(context).textTheme.bodySmall!.copyWith(
                      color: selected ? colors.onPrimary : colors.onSurface,
                    ),
                    child: Row(
                      children: [
                        SizedBox(width: 68, child: Text(shortId)),
                        SizedBox(width: 78, child: Text(dateLabel)),
                        SizedBox(
                          width: 78,
                          child: Text(
                            commit.author.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Expanded(
                          child: Text(
                            commit.subject.isEmpty ? '（无提交标题）' : commit.subject,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// Builds details for the currently selected file-history record.
  ///
  /// 中文：为当前选中的文件历史记录构建提交摘要和只读 Diff 面板。
  Widget _buildDiffPane(BuildContext context) {
    final selectedEntry = _selectedEntry;
    if (selectedEntry == null) {
      return const _FileHistoryMessage(
        icon: Icons.touch_app_outlined,
        title: '选择一个提交',
        message: '从左侧选择提交以查看该文件的修改。',
      );
    }
    if (_isLoadingDetails) {
      return const Center(child: CircularProgressIndicator.adaptive());
    }
    if (_detailError != null) {
      return _FileHistoryMessage(
        icon: Icons.error_outline,
        title: '无法读取提交差异',
        message: _detailError.toString(),
      );
    }
    final summary = _summary;
    final diff = _diff;
    if (summary == null || diff == null) {
      return const _FileHistoryMessage(
        icon: Icons.difference_outlined,
        title: '没有可显示的文件差异',
        message: '此提交没有可读取的文本差异。',
      );
    }
    final shortId = selectedEntry.commit.objectId.substring(
      0,
      math.min(8, selectedEntry.commit.objectId.length),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(14, 9, 14, 8),
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$shortId  ${selectedEntry.commit.subject}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Text(
                '${selectedEntry.path.display} · ${summary.files.length} 个文件 · +${summary.additions} −${summary.deletions}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant),
        Expanded(child: _FileHistoryDiff(text: diff.text)),
      ],
    );
  }
}

final class _FileHistoryMessage extends StatelessWidget {
  const _FileHistoryMessage({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  /// Builds a centered status message for an empty, loading, or error surface.
  ///
  /// 中文：为空结果、加载或错误界面构建居中的状态提示。
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 30,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 10),
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 5),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}

final class _FileHistoryDiff extends StatelessWidget {
  const _FileHistoryDiff({required this.text});

  final String text;

  /// Builds a horizontally scrollable, selectable, read-only unified diff.
  ///
  /// 中文：构建可横向滚动、可选择且只读的 Unified Diff。
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final lines = text.split('\n');
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SelectableText.rich(
          TextSpan(
            children: [
              for (final line in lines)
                TextSpan(
                  text: '$line\n',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.45,
                    color: _diffLineColor(colors, line),
                    backgroundColor: _diffLineBackground(colors, line),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Returns the foreground color for one unified-diff line.
  ///
  /// 中文：根据 Unified Diff 行类型返回对应的前景色。
  Color _diffLineColor(ColorScheme colors, String line) => switch (line) {
    _ when line.startsWith('+') && !line.startsWith('+++') =>
      colors.brightness == Brightness.dark
          ? const Color(0xff91d5a5)
          : const Color(0xff166534),
    _ when line.startsWith('-') && !line.startsWith('---') =>
      colors.brightness == Brightness.dark
          ? const Color(0xffffadad)
          : const Color(0xffb42318),
    _ when line.startsWith('@@') => colors.primary,
    _ when line.startsWith('diff --git') || line.startsWith('index ') =>
      colors.onSurfaceVariant,
    _ => colors.onSurface,
  };

  /// Returns an optional background highlight for one unified-diff line.
  ///
  /// 中文：根据 Unified Diff 行类型返回可选的背景高亮色。
  Color? _diffLineBackground(ColorScheme colors, String line) => switch (line) {
    _ when line.startsWith('+') && !line.startsWith('+++') =>
      colors.brightness == Brightness.dark
          ? const Color(0xff153b27)
          : const Color(0xffdcfce7),
    _ when line.startsWith('-') && !line.startsWith('---') =>
      colors.brightness == Brightness.dark
          ? const Color(0xff4a2023)
          : const Color(0xffffe4e6),
    _ when line.startsWith('@@') => colors.primaryContainer,
    _ => null,
  };
}

final class _ResetCommitDialog extends StatefulWidget {
  const _ResetCommitDialog({
    required this.branchName,
    required this.commit,
    required this.hasWorkingChanges,
  });

  final String branchName;
  final CommitViewData commit;
  final bool hasWorkingChanges;

  @override
  State<_ResetCommitDialog> createState() => _ResetCommitDialogState();
}

final class _ResetCommitDialogState extends State<_ResetCommitDialog> {
  var _mode = GitResetMode.mixed;
  var _hardResetAcknowledged = false;

  @override
  Widget build(BuildContext context) {
    final isHard = _mode == GitResetMode.hard;
    return AlertDialog(
      title: const Text('将当前分支重置到此次提交'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('将 ${widget.branchName} 重置到 ${widget.commit.shortOid}。'),
            const SizedBox(height: 12),
            RadioGroup<GitResetMode>(
              groupValue: _mode,
              onChanged: (value) => setState(() => _mode = value!),
              child: Column(
                children: const [
                  RadioListTile<GitResetMode>(
                    value: GitResetMode.soft,
                    title: Text('软重置'),
                    subtitle: Text('保留暂存区和工作区改动。'),
                    contentPadding: EdgeInsets.zero,
                  ),
                  RadioListTile<GitResetMode>(
                    value: GitResetMode.mixed,
                    title: Text('混合重置'),
                    subtitle: Text('保留工作区改动，但取消暂存。'),
                    contentPadding: EdgeInsets.zero,
                  ),
                  RadioListTile<GitResetMode>(
                    value: GitResetMode.hard,
                    title: Text('硬重置'),
                    subtitle: Text('丢弃已跟踪文件和暂存区的未提交改动。'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
            if (isHard) ...[
              const SizedBox(height: 6),
              CheckboxListTile(
                value: _hardResetAcknowledged,
                onChanged: (value) =>
                    setState(() => _hardResetAcknowledged = value ?? false),
                title: Text(
                  widget.hasWorkingChanges
                      ? '我知道这会永久丢弃当前已跟踪的未提交改动'
                      : '我知道硬重置会永久丢弃已跟踪的未提交改动',
                ),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: isHard && !_hardResetAcknowledged
              ? null
              : () => Navigator.of(context).pop(_mode),
          style: isHard
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                )
              : null,
          child: const Text('重置'),
        ),
      ],
    );
  }
}

final class _InteractiveRebaseDialog extends StatefulWidget {
  const _InteractiveRebaseDialog({
    required this.branchName,
    required this.upstreamCommit,
    required this.initialInstructions,
  });

  final String branchName;
  final CommitViewData upstreamCommit;
  final List<GitInteractiveRebaseInstruction> initialInstructions;

  @override
  State<_InteractiveRebaseDialog> createState() =>
      _InteractiveRebaseDialogState();
}

final class _InteractiveRebaseDialogState
    extends State<_InteractiveRebaseDialog> {
  late final List<GitInteractiveRebaseInstruction> _instructions;

  @override
  void initState() {
    super.initState();
    _instructions = [...widget.initialInstructions];
  }

  bool get _canSubmit {
    var hasPreviousAppliedCommit = false;
    for (final instruction in _instructions) {
      switch (instruction.action) {
        case GitInteractiveRebaseAction.squash:
        case GitInteractiveRebaseAction.fixup:
          if (!hasPreviousAppliedCommit) return false;
        case GitInteractiveRebaseAction.drop:
          continue;
        case GitInteractiveRebaseAction.pick:
        case GitInteractiveRebaseAction.reword:
        case GitInteractiveRebaseAction.edit:
          hasPreviousAppliedCommit = true;
      }
    }
    return true;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('交互式变基'),
    content: SizedBox(
      width: 660,
      height: 480,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${widget.branchName} 将变基到 ${widget.upstreamCommit.shortOid}。拖动提交可调整顺序；'
            '选择操作后将改写本地历史。',
          ),
          const SizedBox(height: 10),
          const Text('squash 和 fixup 必须位于一个未丢弃提交之后。'),
          const SizedBox(height: 12),
          Expanded(
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              itemCount: _instructions.length,
              onReorderItem: (oldIndex, newIndex) {
                setState(() {
                  if (oldIndex < newIndex) newIndex--;
                  final item = _instructions.removeAt(oldIndex);
                  _instructions.insert(newIndex, item);
                });
              },
              itemBuilder: (context, index) {
                final instruction = _instructions[index];
                return ListTile(
                  key: ValueKey(instruction.objectId),
                  leading: ReorderableDragStartListener(
                    index: index,
                    child: const Icon(Icons.drag_indicator),
                  ),
                  title: Text(
                    instruction.subject.isEmpty
                        ? '（无提交标题）'
                        : instruction.subject,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(instruction.objectId.substring(0, 8)),
                  trailing: DropdownButton<GitInteractiveRebaseAction>(
                    value: instruction.action,
                    onChanged: (action) {
                      if (action == null) return;
                      setState(() {
                        _instructions[index] = instruction.copyWith(
                          action: action,
                        );
                      });
                    },
                    items: [
                      for (final action in GitInteractiveRebaseAction.values)
                        if (action != GitInteractiveRebaseAction.reword)
                          DropdownMenuItem(
                            value: action,
                            child: Text(_interactiveRebaseActionLabel(action)),
                          ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton.icon(
        onPressed: _canSubmit
            ? () => Navigator.of(context).pop(_instructions)
            : null,
        icon: const Icon(Icons.call_split),
        label: const Text('开始变基'),
      ),
    ],
  );

  String _interactiveRebaseActionLabel(GitInteractiveRebaseAction action) =>
      switch (action) {
        GitInteractiveRebaseAction.pick => 'pick',
        GitInteractiveRebaseAction.reword => 'reword',
        GitInteractiveRebaseAction.edit => 'edit',
        GitInteractiveRebaseAction.squash => 'squash',
        GitInteractiveRebaseAction.fixup => 'fixup',
        GitInteractiveRebaseAction.drop => 'drop',
      };
}

final class _PatchCreateRequest {
  const _PatchCreateRequest({
    required this.commitIds,
    required this.outputPath,
    required this.createSeparateFiles,
  });
  final List<String> commitIds;
  final String outputPath;
  final bool createSeparateFiles;
}

final class _PatchApplyRequest {
  const _PatchApplyRequest({
    required this.patchPath,
    required this.stripLevel,
    required this.basePath,
    required this.checkOnly,
  });
  final String patchPath;
  final int? stripLevel;
  final String basePath;
  final bool checkOnly;
}

final class _RepositoryDetailsDialog extends ConsumerStatefulWidget {
  const _RepositoryDetailsDialog({required this.repositoryName});

  final String repositoryName;

  @override
  ConsumerState<_RepositoryDetailsDialog> createState() =>
      _RepositoryDetailsDialogState();
}

final class _RepositoryDetailsDialogState
    extends ConsumerState<_RepositoryDetailsDialog> {
  GitRepositoryDetails? _details;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final details = await ref
          .read(repositorySessionProvider.notifier)
          .readRepositoryDetails();
      if (mounted) setState(() => _details = details);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  void dispose() {
    ref.read(repositorySessionProvider.notifier).cancelRepositoryDetailsRead();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _ResizableDialogSurface(
    initialSize: const Size(660, 670),
    minimumSize: const Size(520, 420),
    builder: (context, _) {
      final details = _details;
      if (details == null) {
        return Column(
          children: [
            _dialogTitle('仓库详情'),
            Expanded(
              child: Center(
                child: _error == null
                    ? const CircularProgressIndicator()
                    : Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.error_outline, size: 32),
                            const SizedBox(height: 10),
                            const Text('无法读取仓库详情'),
                            const SizedBox(height: 6),
                            Text(
                              _error.toString(),
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 14),
                            OutlinedButton(
                              onPressed: () => setState(() {
                                _error = null;
                                unawaited(_load());
                              }),
                              child: const Text('重试'),
                            ),
                          ],
                        ),
                      ),
              ),
            ),
            _dialogActions(
              context,
              enabled: true,
              label: '关闭',
              onConfirm: () => Navigator.of(context).pop(),
            ),
          ],
        );
      }
      final totalAuthorCommits = details.authors.fold<int>(
        0,
        (total, author) => total + author.commitCount,
      );
      return Column(
        children: [
          _dialogTitle('仓库详情'),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 16),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Row(
              children: [
                CircleAvatar(
                  radius: 23,
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  child: Icon(
                    Icons.code_rounded,
                    color: Theme.of(context).colorScheme.onPrimary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.repositoryName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(28, 18, 28, 12),
              child: Column(
                children: [
                  _RepositoryDetailsFacts(details: details),
                  const SizedBox(height: 16),
                  _RepositoryAuthorTable(
                    authors: details.authors,
                    totalCommitCount: totalAuthorCommits,
                  ),
                ],
              ),
            ),
          ),
          _dialogActions(
            context,
            enabled: true,
            label: '关闭',
            onConfirm: () => Navigator.of(context).pop(),
          ),
        ],
      );
    },
  );
}

final class _RepositoryDetailsFacts extends StatelessWidget {
  const _RepositoryDetailsFacts({required this.details});

  final GitRepositoryDetails details;

  @override
  Widget build(BuildContext context) {
    final labelStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final valueStyle = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600);
    final facts = <(String, String)>[
      ('创建于', _formatRepositoryDate(details.createdAt)),
      ('上次提交', _formatRepositoryDate(details.lastCommitAt)),
      ('占用磁盘空间', _formatBytes(details.diskUsageBytes)),
      ('LFS', details.lfsStatus),
      ('分支', '${details.branchCount}'),
      ('标签', '${details.tagCount}'),
      ('总提交数', '${details.commitCount}'),
      ('已跟踪文件', '${details.trackedFileCount}'),
      ('总作者数', '${details.authors.length}'),
    ];
    return Wrap(
      spacing: 20,
      runSpacing: 12,
      children: [
        for (final fact in facts)
          SizedBox(
            width: 250,
            child: Row(
              children: [
                SizedBox(width: 84, child: Text(fact.$1, style: labelStyle)),
                Expanded(child: Text(fact.$2, style: valueStyle)),
              ],
            ),
          ),
      ],
    );
  }
}

final class _RepositoryAuthorTable extends StatelessWidget {
  const _RepositoryAuthorTable({
    required this.authors,
    required this.totalCommitCount,
  });

  final List<GitRepositoryAuthorSummary> authors;
  final int totalCommitCount;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    decoration: BoxDecoration(
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    child: Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          child: const Row(
            children: [
              Expanded(flex: 3, child: Text('作者')),
              Expanded(child: Text('提交')),
              SizedBox(width: 62, child: Text('占比')),
            ],
          ),
        ),
        if (authors.isEmpty)
          const Padding(padding: EdgeInsets.all(18), child: Text('暂无提交作者'))
        else
          for (final author in authors)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Text(
                      author.email.isEmpty
                          ? author.name
                          : '${author.name} <${author.email}>',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Expanded(child: Text('${author.commitCount}')),
                  SizedBox(
                    width: 62,
                    child: Text(
                      totalCommitCount == 0
                          ? '—'
                          : '${(author.commitCount * 100 / totalCommitCount).toStringAsFixed(1)}%',
                    ),
                  ),
                ],
              ),
            ),
      ],
    ),
  );
}

String _formatRepositoryDate(DateTime? date) {
  if (date == null) return '—';
  return '${date.year}年${date.month}月${date.day}日 '
      '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

final class _ResizableDialogSurface extends StatefulWidget {
  const _ResizableDialogSurface({
    required this.initialSize,
    required this.minimumSize,
    required this.builder,
  });
  final Size initialSize;
  final Size minimumSize;
  final Widget Function(BuildContext context, Size size) builder;
  @override
  State<_ResizableDialogSurface> createState() =>
      _ResizableDialogSurfaceState();
}

final class _ResizableDialogSurfaceState
    extends State<_ResizableDialogSurface> {
  late Size _size = widget.initialSize;
  var _offset = Offset.zero;

  Size _fitSize(Size candidate, Size viewport) {
    const inset = 20.0;
    final maximumWidth = (viewport.width - inset * 2)
        .clamp(0.0, 1400.0)
        .toDouble();
    final maximumHeight = (viewport.height - inset * 2)
        .clamp(0.0, 960.0)
        .toDouble();
    return Size(
      candidate.width.clamp(0.0, maximumWidth).toDouble(),
      candidate.height.clamp(0.0, maximumHeight).toDouble(),
    );
  }

  void _resize(_DialogResizeEdge edge, Offset delta) {
    const inset = 20.0;
    final viewport = MediaQuery.sizeOf(context);
    final currentSize = _fitSize(_size, viewport);
    final maximumWidth = (viewport.width - inset * 2)
        .clamp(0.0, 1400.0)
        .toDouble();
    final maximumHeight = (viewport.height - inset * 2)
        .clamp(0.0, 960.0)
        .toDouble();
    final minimumWidth = widget.minimumSize.width.clamp(0.0, maximumWidth);
    final minimumHeight = widget.minimumSize.height.clamp(0.0, maximumHeight);
    final resizeHorizontally = edge.hasLeft || edge.hasRight;
    final resizeVertically = edge.hasTop || edge.hasBottom;
    final requestedWidth =
        currentSize.width +
        (edge.hasLeft ? -delta.dx : (edge.hasRight ? delta.dx : 0));
    final requestedHeight =
        currentSize.height +
        (edge.hasTop ? -delta.dy : (edge.hasBottom ? delta.dy : 0));
    final nextWidth = resizeHorizontally
        ? requestedWidth.clamp(minimumWidth, maximumWidth).toDouble()
        : currentSize.width;
    final nextHeight = resizeVertically
        ? requestedHeight.clamp(minimumHeight, maximumHeight).toDouble()
        : currentSize.height;
    final widthChange = nextWidth - currentSize.width;
    final heightChange = nextHeight - currentSize.height;
    final requestedOffset =
        _offset +
        Offset(
          edge.hasLeft ? -widthChange / 2 : widthChange / 2,
          edge.hasTop ? -heightChange / 2 : heightChange / 2,
        );
    final horizontalLimit = ((viewport.width - inset * 2 - nextWidth) / 2)
        .clamp(0.0, double.infinity);
    final verticalLimit = ((viewport.height - inset * 2 - nextHeight) / 2)
        .clamp(0.0, double.infinity);
    final nextOffset = Offset(
      requestedOffset.dx.clamp(-horizontalLimit, horizontalLimit).toDouble(),
      requestedOffset.dy.clamp(-verticalLimit, verticalLimit).toDouble(),
    );
    setState(() {
      _size = Size(nextWidth, nextHeight);
      _offset = nextOffset;
    });
  }

  @override
  Widget build(BuildContext context) {
    const inset = 20.0;
    final viewport = MediaQuery.sizeOf(context);
    final size = _fitSize(_size, viewport);
    final horizontalLimit = ((viewport.width - inset * 2 - size.width) / 2)
        .clamp(0.0, double.infinity);
    final verticalLimit = ((viewport.height - inset * 2 - size.height) / 2)
        .clamp(0.0, double.infinity);
    final offset = Offset(
      _offset.dx.clamp(-horizontalLimit, horizontalLimit).toDouble(),
      _offset.dy.clamp(-verticalLimit, verticalLimit).toDouble(),
    );
    return Transform.translate(
      // Translate the complete dialog, including its Material surface. Moving
      // only Dialog.child separates content from the rounded background.
      offset: offset,
      child: Dialog(
        insetPadding: const EdgeInsets.all(20),
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(child: widget.builder(context, size)),
              for (final edge in _DialogResizeEdge.values)
                _DialogResizeHandle(
                  edge: edge,
                  onPanUpdate: (delta) => _resize(edge, delta),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _DialogResizeEdge {
  top,
  right,
  bottom,
  left,
  topLeft,
  topRight,
  bottomRight,
  bottomLeft;

  bool get hasTop => this == top || this == topLeft || this == topRight;
  bool get hasRight => this == right || this == topRight || this == bottomRight;
  bool get hasBottom =>
      this == bottom || this == bottomLeft || this == bottomRight;
  bool get hasLeft => this == left || this == topLeft || this == bottomLeft;

  SystemMouseCursor get cursor => switch (this) {
    top || bottom => SystemMouseCursors.resizeUpDown,
    left || right => SystemMouseCursors.resizeLeftRight,
    topLeft || bottomRight => SystemMouseCursors.resizeUpLeftDownRight,
    topRight || bottomLeft => SystemMouseCursors.resizeUpRightDownLeft,
  };
}

final class _DialogResizeHandle extends StatelessWidget {
  const _DialogResizeHandle({required this.edge, required this.onPanUpdate});
  final _DialogResizeEdge edge;
  final ValueChanged<Offset> onPanUpdate;

  @override
  Widget build(BuildContext context) {
    const edgeSize = 10.0;
    const cornerSize = 24.0;
    final handle = MouseRegion(
      cursor: edge.cursor,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (details) => onPanUpdate(details.delta),
      ),
    );
    // Keep each hot zone inside the material bounds. Flutter intentionally
    // excludes overflow from hit testing, which made the previous negative
    // offsets leave the corner handles effectively unreachable.
    return switch (edge) {
      _DialogResizeEdge.top => Positioned(
        left: cornerSize,
        right: cornerSize,
        top: 0,
        height: edgeSize,
        child: handle,
      ),
      _DialogResizeEdge.right => Positioned(
        top: cornerSize,
        right: 0,
        bottom: cornerSize,
        width: edgeSize,
        child: handle,
      ),
      _DialogResizeEdge.bottom => Positioned(
        left: cornerSize,
        right: cornerSize,
        bottom: 0,
        height: edgeSize,
        child: handle,
      ),
      _DialogResizeEdge.left => Positioned(
        top: cornerSize,
        left: 0,
        bottom: cornerSize,
        width: edgeSize,
        child: handle,
      ),
      _DialogResizeEdge.topLeft => Positioned(
        left: 0,
        top: 0,
        width: cornerSize,
        height: cornerSize,
        child: handle,
      ),
      _DialogResizeEdge.topRight => Positioned(
        right: 0,
        top: 0,
        width: cornerSize,
        height: cornerSize,
        child: handle,
      ),
      _DialogResizeEdge.bottomRight => Positioned(
        right: 0,
        bottom: 0,
        width: cornerSize,
        height: cornerSize,
        child: handle,
      ),
      _DialogResizeEdge.bottomLeft => Positioned(
        left: 0,
        bottom: 0,
        width: cornerSize,
        height: cornerSize,
        child: handle,
      ),
    };
  }
}

final class _PatchCreateDialog extends StatefulWidget {
  const _PatchCreateDialog({
    required this.repository,
    required this.onCommitSelected,
    required this.onCommitFileSelected,
    required this.onLoadMore,
    this.selectedCommitId,
  });
  final RepositoryViewData repository;
  final String? selectedCommitId;
  final RepositoryCommitCallback onCommitSelected;
  final RepositoryCommitFileCallback onCommitFileSelected;
  final VoidCallback? onLoadMore;
  @override
  State<_PatchCreateDialog> createState() => _PatchCreateDialogState();
}

final class _PatchCreateDialogState extends State<_PatchCreateDialog> {
  late Set<String> _commitIds = {
    widget.selectedCommitId ?? widget.repository.commits.first.oid,
  };
  final _output = TextEditingController();
  var _createSeparateFiles = false;

  @override
  void initState() {
    super.initState();
    if (widget.selectedCommitId == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onCommitSelected(widget.repository.commits.first);
      });
    }
  }

  @override
  void dispose() {
    _output.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _PatchCreateDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    final visibleIds = widget.repository.commits
        .map((commit) => commit.oid)
        .toSet();
    final retained = _commitIds.where(visibleIds.contains).toSet();
    if (retained.isEmpty && widget.repository.commits.isNotEmpty) {
      retained.add(widget.repository.commits.first.oid);
    }
    _commitIds = retained;
  }

  Future<void> _browse() async {
    if (_createSeparateFiles) {
      final directory = await getDirectoryPath(confirmButtonText: '选择补丁目录');
      if (directory != null && mounted) {
        setState(() => _output.text = directory);
      }
      return;
    }
    final commit = widget.repository.commits.firstWhere(
      (item) => item.oid == _commitIds.first,
      orElse: () => widget.repository.commits.first,
    );
    final location = await getSaveLocation(
      suggestedName: '${commit.shortOid}.patch',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Git patch', extensions: ['patch']),
      ],
    );
    if (location != null && mounted) {
      setState(() => _output.text = location.path);
    }
  }

  void _toggleCommit(CommitViewData commit) {
    setState(() {
      if (!_commitIds.add(commit.oid)) _commitIds.remove(commit.oid);
    });
    widget.onCommitSelected(commit);
  }

  @override
  Widget build(BuildContext context) => _ResizableDialogSurface(
    initialSize: const Size(1320, 820),
    minimumSize: const Size(760, 540),
    builder: (context, _) => Column(
      children: [
        _dialogTitle('由提交操作创建补丁'),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: Column(
              children: [
                Container(
                  height: 34,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                  child: Row(
                    children: [
                      Text(
                        '选择要导出的提交',
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '点击提交可切换选择',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const Spacer(),
                      Text('${_commitIds.length} 个已选择'),
                    ],
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border(
                        left: BorderSide(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                        right: BorderSide(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                        bottom: BorderSide(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                      ),
                    ),
                    child: RepositoryHistoryPane(
                      repository: widget.repository,
                      selectedCommitIds: _commitIds,
                      showPaneHeader: false,
                      includeUncommittedChanges: false,
                      onSelected: _toggleCommit,
                      onLoadMore: widget.onLoadMore,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Expanded(
                  flex: 2,
                  child: LayoutBuilder(
                    builder: (context, constraints) => Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: RepositoryCommitChangesPane(
                            repository: widget.repository,
                            onSelected: widget.onCommitFileSelected,
                          ),
                        ),
                        if (constraints.maxWidth >= 960) ...[
                          VerticalDivider(
                            width: 1,
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                          SizedBox(
                            width: 300,
                            child: RepositoryCommitDetailsPane(
                              details: widget.repository.selectedCommit,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: Column(
            children: [
              Row(
                children: [
                  Text(_createSeparateFiles ? '补丁目录：' : '补丁文件：'),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _output,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _commitIds.isEmpty ? null : _browse,
                    child: const Text('浏览…'),
                  ),
                ],
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _createSeparateFiles,
                onChanged: (value) => setState(() {
                  _createSeparateFiles = value ?? false;
                  _output.clear();
                }),
                title: const Text('为每个提交创建独立的补丁文件（附加序号到文件名）'),
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ],
          ),
        ),
        _dialogActions(
          context,
          enabled: _commitIds.isNotEmpty && _output.text.trim().isNotEmpty,
          label: '创建',
          onConfirm: () => Navigator.of(context).pop(
            _PatchCreateRequest(
              // History is displayed newest first; patches must be exported
              // oldest first so dependent changes remain applicable.
              commitIds: widget.repository.commits.reversed
                  .where((commit) => _commitIds.contains(commit.oid))
                  .map((commit) => commit.oid)
                  .toList(growable: false),
              outputPath: _output.text.trim(),
              createSeparateFiles: _createSeparateFiles,
            ),
          ),
        ),
      ],
    ),
  );
}

final class _PatchApplyDialog extends StatefulWidget {
  const _PatchApplyDialog();
  @override
  State<_PatchApplyDialog> createState() => _PatchApplyDialogState();
}

final class _PatchApplyDialogState extends State<_PatchApplyDialog> {
  final _path = TextEditingController();
  final _base = TextEditingController();
  int? _strip;
  var _checkOnly = false;
  @override
  void dispose() {
    _path.dispose();
    _base.dispose();
    super.dispose();
  }

  Future<void> _browse() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Git patch', extensions: ['patch', 'diff']),
      ],
    );
    if (file != null && mounted) setState(() => _path.text = file.path);
  }

  @override
  Widget build(BuildContext context) => _ResizableDialogSurface(
    initialSize: const Size(760, 500),
    minimumSize: const Size(560, 360),
    builder: (context, _) => Column(
      children: [
        _dialogTitle('补丁文件'),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    const Text('文件：'),
                    Expanded(
                      child: TextField(
                        controller: _path,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: _browse,
                      child: const Text('浏览…'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: Container(
                    alignment: Alignment.topLeft,
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      border: Border.all(color: Theme.of(context).dividerColor),
                    ),
                    child: Text(_path.text.isEmpty ? '未指定补丁文件' : _path.text),
                  ),
                ),
                Row(
                  children: [
                    const Text('剥离：'),
                    DropdownButton<int?>(
                      value: _strip,
                      items: const [
                        DropdownMenuItem<int?>(
                          value: null,
                          child: Text('默认（Git -p1）'),
                        ),
                        DropdownMenuItem<int?>(value: 0, child: Text('0')),
                        DropdownMenuItem<int?>(value: 1, child: Text('1')),
                        DropdownMenuItem<int?>(value: 2, child: Text('2')),
                        DropdownMenuItem<int?>(value: 3, child: Text('3')),
                      ],
                      onChanged: (value) => setState(() => _strip = value),
                    ),
                    const SizedBox(width: 20),
                    Expanded(
                      child: TextField(
                        controller: _base,
                        decoration: const InputDecoration(
                          labelText: '基础路径',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    Checkbox(
                      value: _checkOnly,
                      onChanged: (value) =>
                          setState(() => _checkOnly = value ?? false),
                    ),
                    const Text('试运行'),
                  ],
                ),
              ],
            ),
          ),
        ),
        _dialogActions(
          context,
          enabled: _path.text.trim().isNotEmpty,
          label: _checkOnly ? '检查' : '应用',
          onConfirm: () => Navigator.of(context).pop(
            _PatchApplyRequest(
              patchPath: _path.text.trim(),
              stripLevel: _strip,
              basePath: _base.text.trim(),
              checkOnly: _checkOnly,
            ),
          ),
        ),
      ],
    ),
  );
}

Widget _dialogTitle(String title) => Container(
  width: double.infinity,
  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
  color: Colors.black12,
  child: Text(
    title,
    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
  ),
);
Widget _dialogActions(
  BuildContext context, {
  required bool enabled,
  required String label,
  required VoidCallback onConfirm,
}) => Padding(
  // Leave a clear interior margin for the bottom-corner resize targets.
  padding: const EdgeInsets.fromLTRB(14, 14, 30, 30),
  child: Row(
    mainAxisAlignment: MainAxisAlignment.end,
    children: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      const SizedBox(width: 8),
      FilledButton(onPressed: enabled ? onConfirm : null, child: Text(label)),
    ],
  ),
);

enum _StashManagerAction { create, apply, pop, drop }

final class _StashManagerResult {
  const _StashManagerResult(this.kind, {this.entry});

  final _StashManagerAction kind;
  final GitStashEntry? entry;
}

final class _CreateStashOptions {
  const _CreateStashOptions({required this.message, required this.keepIndex});

  final String message;
  final bool keepIndex;
}

class _StashManagerDialog extends StatelessWidget {
  const _StashManagerDialog({required this.stashes});

  final List<GitStashEntry> stashes;

  /// 中文：使用当前界面语言格式化贮藏创建时间。
  /// English: Formats a stash creation time with the current UI locale.
  String _timestamp(BuildContext context, DateTime time) {
    final local = time.toLocal();
    final localizations = MaterialLocalizations.of(context);
    return '${localizations.formatMediumDate(local)} '
        '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
  }

  /// 中文：构建贮藏管理面板。
  /// English: Builds the stash management panel.
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('贮藏'),
      content: SizedBox(
        width: 680,
        height: 360,
        child: stashes.isEmpty
            ? const Center(child: Text('没有已贮藏的改动。\n可创建贮藏以暂时清空当前工作区。'))
            : ListView.separated(
                itemCount: stashes.length,
                separatorBuilder: (BuildContext context, int index) =>
                    const Divider(height: 1),
                itemBuilder: (BuildContext context, int index) {
                  final entry = stashes[index];
                  final message = entry.message.trim().isEmpty
                      ? '未命名贮藏'
                      : entry.message;
                  return ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    leading: Icon(
                      Icons.inventory_2_outlined,
                      color: colors.primary,
                    ),
                    title: Text(
                      message,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${entry.reference} · ${_timestamp(context, entry.createdAt)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: PopupMenuButton<_StashManagerAction>(
                      tooltip: '贮藏操作',
                      onSelected: (action) => Navigator.of(
                        context,
                      ).pop(_StashManagerResult(action, entry: entry)),
                      itemBuilder: (BuildContext context) => const [
                        PopupMenuItem(
                          value: _StashManagerAction.apply,
                          child: ListTile(
                            dense: true,
                            leading: Icon(Icons.restore_outlined),
                            title: Text('恢复并保留'),
                          ),
                        ),
                        PopupMenuItem(
                          value: _StashManagerAction.pop,
                          child: ListTile(
                            dense: true,
                            leading: Icon(Icons.unarchive_outlined),
                            title: Text('恢复并弹出'),
                          ),
                        ),
                        PopupMenuItem(
                          value: _StashManagerAction.drop,
                          child: ListTile(
                            dense: true,
                            leading: Icon(Icons.delete_outline),
                            title: Text('删除贮藏'),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.of(
            context,
          ).pop(const _StashManagerResult(_StashManagerAction.create)),
          icon: const Icon(Icons.add),
          label: const Text('创建贮藏'),
        ),
      ],
    );
  }
}

class _CreateStashDialog extends StatefulWidget {
  const _CreateStashDialog();

  /// 中文：创建关联的状态对象。
  /// English: Creates the associated state object.
  @override
  State<_CreateStashDialog> createState() => _CreateStashDialogState();
}

class _CreateStashDialogState extends State<_CreateStashDialog> {
  final _messageController = TextEditingController();
  var _keepIndex = false;

  /// 中文：释放当前对象持有的文本控制器。
  /// English: Disposes the text controller owned by this dialog.
  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  /// 中文：提交当前创建选项并关闭对话框，不在界面层直接执行 Git。
  /// English: Returns the selected create options without running Git in the
  /// presentation layer.
  void _submit() {
    Navigator.of(context).pop(
      _CreateStashOptions(
        message: _messageController.text,
        keepIndex: _keepIndex,
      ),
    );
  }

  /// 中文：构建创建贮藏对话框。
  /// English: Builds the create-stash dialog.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      child: SizedBox(
        width: 500,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _keepIndex ? '将当前改动保存为贮藏，并保留暂存区内容。' : '将当前改动保存为贮藏，并恢复为干净的工作区。',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  const SizedBox(width: 42, child: Text('信息：')),
                  Expanded(
                    child: SizedBox(
                      height: 28,
                      child: TextField(
                        controller: _messageController,
                        autofocus: true,
                        maxLength: 240,
                        decoration: const InputDecoration(
                          hintText: '可选',
                          counterText: '',
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 5,
                          ),
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => _submit(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(left: 42),
                child: InkWell(
                  onTap: () => setState(() => _keepIndex = !_keepIndex),
                  borderRadius: BorderRadius.circular(4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        value: _keepIndex,
                        onChanged: (value) =>
                            setState(() => _keepIndex = value ?? false),
                        visualDensity: VisualDensity.compact,
                      ),
                      const Text('保留暂存的变更'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  SizedBox(
                    width: 86,
                    height: 28,
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 86,
                    height: 28,
                    child: FilledButton(
                      onPressed: _submit,
                      child: const Text('贮藏'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _CommitDialogResult {
  const _CommitDialogResult({
    required this.message,
    this.pushAfterCommit = false,
    this.amend = false,
  });

  final String message;
  final bool pushAfterCommit;
  final bool amend;
}

class _CommitDialog extends ConsumerStatefulWidget {
  const _CommitDialog();

  /// 中文：创建关联的状态对象。
  /// English: Creates the associated state object.
  @override
  ConsumerState<_CommitDialog> createState() => _CommitDialogState();
}

class _CloneDialog extends StatefulWidget {
  const _CloneDialog();

  /// 中文：创建关联的状态对象。
  /// English: Creates the associated state object.
  @override
  State<_CloneDialog> createState() => _CloneDialogState();
}

class _CloneDialogState extends State<_CloneDialog> {
  final _formKey = GlobalKey<FormState>();
  final _urlController = TextEditingController();

  /// 中文：释放当前对象持有的资源。
  /// English: Releases resources held by this object.
  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  /// 中文：提交当前表单或请求。
  /// English: Submits the current form or request.
  void _submit() {
    if (_formKey.currentState?.validate() ?? false) {
      Navigator.of(context).pop(_urlController.text);
    }
  }

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('克隆仓库'),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Form(
        key: _formKey,
        child: TextFormField(
          controller: _urlController,
          autofocus: true,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: '远端地址',
            hintText: 'https://… 或 git@host:owner/repository.git',
          ),
          validator: (value) {
            if (value == null || value.trim().isEmpty) {
              return '请输入远端地址。';
            }
            try {
              cloneRepositoryNameFromRemote(value);
              return null;
            } on Object {
              return '无法从远端地址确定仓库名称。';
            }
          },
          onFieldSubmitted: (_) => _submit(),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _submit, child: const Text('下一步')),
    ],
  );
}

enum _BranchManagerAction { create, delete }

final class _BranchManagerResult {
  const _BranchManagerResult({
    required this.action,
    this.branchName,
    this.sourceCommitId,
    this.checkout = false,
    this.localBranchNames = const [],
    this.remoteBranchNames = const [],
    this.forceLocalDelete = false,
  });

  final _BranchManagerAction action;
  final String? branchName;
  final String? sourceCommitId;
  final bool checkout;
  final List<String> localBranchNames;
  final List<String> remoteBranchNames;
  final bool forceLocalDelete;
}

final class _BranchDeletionTarget {
  const _BranchDeletionTarget({
    required this.name,
    required this.isRemote,
    required this.isCurrentLocal,
  });

  final String name;
  final bool isRemote;
  final bool isCurrentLocal;

  String get key => '${isRemote ? 'remote' : 'local'}:$name';
}

class _BranchManagerDialog extends StatefulWidget {
  const _BranchManagerDialog({required this.session, this.initialCommitId});

  final RepositorySessionState session;
  final String? initialCommitId;

  @override
  State<_BranchManagerDialog> createState() => _BranchManagerDialogState();
}

class _BranchManagerDialogState extends State<_BranchManagerDialog> {
  late final TextEditingController _nameController;
  final _selectedDeletionKeys = <String>{};
  String? _selectedCommitId;
  _BranchManagerAction _action = _BranchManagerAction.create;
  bool _useSpecifiedCommit = false;
  bool _checkout = true;
  bool _forceLocalDelete = false;

  RepositorySessionState get session => widget.session;

  String get _currentBranch {
    final branch = session.status?.branch;
    if (branch?.isDetached == true) {
      final objectId = branch?.objectId ?? '当前提交';
      return 'HEAD ${objectId.length > 12 ? objectId.substring(0, 12) : objectId}';
    }
    return branch?.head ?? '未创建提交';
  }

  List<_BranchDeletionTarget> get _deletionTargets {
    final current = session.status?.branch.head;
    return [
      for (final branch in session.localBranches)
        _BranchDeletionTarget(
          name: branch.name,
          isRemote: false,
          isCurrentLocal: branch.name == current,
        ),
      for (final branch in session.remoteBranches)
        _BranchDeletionTarget(
          name: branch.name,
          isRemote: true,
          isCurrentLocal: false,
        ),
    ];
  }

  /// 中文：初始化分支管理表单的默认分支选择。
  /// English: Initializes the branch manager's default branch selection.
  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    final initialCommitId = widget.initialCommitId;
    if (initialCommitId != null &&
        session.commits.any((commit) => commit.objectId == initialCommitId)) {
      _useSpecifiedCommit = true;
      _selectedCommitId = initialCommitId;
    }
  }

  /// 中文：释放分支管理表单控制器。
  /// English: Releases the branch manager form controller.
  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  /// 中文：打开已加载提交的选择器。
  /// English: Opens the picker for loaded commits.
  Future<void> _chooseCommit() async {
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => _CommitBasePicker(commits: session.commits),
    );
    if (!mounted || selected == null) return;
    setState(() => _selectedCommitId = selected);
  }

  /// 中文：校验并返回分支管理操作结果。
  /// English: Validates and returns the branch manager operation result.
  void _submit() {
    final branchName = _nameController.text.trim();
    if (_action == _BranchManagerAction.create &&
        _useSpecifiedCommit &&
        _selectedCommitId == null) {
      return;
    }
    if (_action == _BranchManagerAction.create && branchName.isEmpty) return;
    final targets = _deletionTargets
        .where((target) => _selectedDeletionKeys.contains(target.key))
        .toList(growable: false);
    if (_action == _BranchManagerAction.delete && targets.isEmpty) return;
    Navigator.of(context).pop(
      _BranchManagerResult(
        action: _action,
        branchName: _action == _BranchManagerAction.create ? branchName : null,
        sourceCommitId: _useSpecifiedCommit ? _selectedCommitId : null,
        checkout: _action == _BranchManagerAction.create && _checkout,
        localBranchNames: [
          for (final target in targets)
            if (!target.isRemote) target.name,
        ],
        remoteBranchNames: [
          for (final target in targets)
            if (target.isRemote) target.name,
        ],
        forceLocalDelete: _forceLocalDelete,
      ),
    );
  }

  /// 中文：格式化提交短 ID 和标题供基点选择显示。
  /// English: Formats a commit short ID and subject for base selection.
  String _commitLabel(String objectId) {
    final commit = session.commits.firstWhere(
      (candidate) => candidate.objectId == objectId,
      orElse: () => session.commits.first,
    );
    final shortId = commit.objectId.length > 8
        ? commit.objectId.substring(0, 8)
        : commit.objectId;
    return '$shortId  ${commit.subject.isEmpty ? '（无提交标题）' : commit.subject}';
  }

  /// 中文：构建带动画状态切换的创建/删除模式按钮。
  /// English: Builds an animated create/delete mode button.
  Widget _modeButton(
    BuildContext context, {
    required _BranchManagerAction action,
    required IconData icon,
    required String label,
    required Color accent,
  }) {
    final selected = _action == action;
    return InkWell(
      key: ValueKey<String>('branch-manager-tab-$action'),
      onTap: () => setState(() => _action = action),
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? accent.withValues(alpha: .10) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 17, color: selected ? accent : null),
            const SizedBox(height: 2),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: selected ? accent : null,
                fontWeight: selected ? FontWeight.w700 : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 中文：显示当前分支，只读且不改变 Git 状态。
  /// English: Displays the current branch without changing Git state.
  Widget _currentBranchField(BuildContext context) {
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: '当前分支',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      child: Text(
        _currentBranch,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }

  /// 中文：构建提交基点单选入口。
  /// English: Builds a commit-base radio entry.
  Widget _sourceRadio({required bool specified}) {
    final selected = _useSpecifiedCommit == specified;
    return InkWell(
      onTap: () => setState(() {
        _useSpecifiedCommit = specified;
        if (!specified) _selectedCommitId = null;
      }),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 18,
              color: selected ? Theme.of(context).colorScheme.primary : null,
            ),
            const SizedBox(width: 5),
            Text(specified ? '指定的提交' : '工作副本父节点'),
          ],
        ),
      ),
    );
  }

  /// 中文：构建新建分支表单。
  /// English: Builds the create-branch form.
  Widget _buildCreate(BuildContext context) {
    final selectedCommit = _selectedCommitId;
    final canSubmit =
        _nameController.text.trim().isNotEmpty &&
        (!_useSpecifiedCommit || selectedCommit != null);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _currentBranchField(context),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey<String>('branch-manager-name'),
            controller: _nameController,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: '新分支',
              hintText: '例如 feature/new-workflow',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          Text('提交基点', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          _sourceRadio(specified: false),
          _sourceRadio(specified: true),
          if (_useSpecifiedCommit)
            Padding(
              padding: const EdgeInsets.only(left: 23, top: 3),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: session.commits.isEmpty ? null : _chooseCommit,
                  icon: const Icon(Icons.commit, size: 16),
                  label: Text(
                    selectedCommit == null
                        ? '选择提交...'
                        : _commitLabel(selectedCommit),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          const SizedBox(height: 8),
          CheckboxListTile(
            value: _checkout,
            onChanged: (value) => setState(() => _checkout = value ?? false),
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('检出新分支'),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              key: const ValueKey<String>('branch-manager-create'),
              onPressed: canSubmit ? _submit : null,
              child: const Text('创建分支'),
            ),
          ),
        ],
      ),
    );
  }

  /// 中文：构建安全删除分支表单。
  /// English: Builds the safe-delete branch form.
  Widget _buildDelete(BuildContext context) {
    final targets = _deletionTargets;
    final selectedCount = _selectedDeletionKeys.length;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('选择您想要删除的分支：', style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 8),
          Container(
            height: 198,
            decoration: BoxDecoration(
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              children: [
                Container(
                  height: 29,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                    border: Border(
                      bottom: BorderSide(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                  ),
                  child: const Row(
                    children: [
                      SizedBox(width: 20),
                      Expanded(child: Text('分支名称')),
                      SizedBox(width: 92, child: Text('类型')),
                    ],
                  ),
                ),
                Expanded(
                  child: targets.isEmpty
                      ? const Center(child: Text('没有可删除的分支。'))
                      : ListView.builder(
                          itemCount: targets.length,
                          itemBuilder: (context, index) {
                            final target = targets[index];
                            final disabled = target.isCurrentLocal;
                            final selected = _selectedDeletionKeys.contains(
                              target.key,
                            );
                            return InkWell(
                              onTap: disabled
                                  ? null
                                  : () => setState(() {
                                      if (selected) {
                                        _selectedDeletionKeys.remove(
                                          target.key,
                                        );
                                      } else {
                                        _selectedDeletionKeys.add(target.key);
                                      }
                                    }),
                              child: SizedBox(
                                height: 27,
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 36,
                                      child: Checkbox(
                                        value: selected,
                                        onChanged: disabled
                                            ? null
                                            : (value) => setState(() {
                                                if (value ?? false) {
                                                  _selectedDeletionKeys.add(
                                                    target.key,
                                                  );
                                                } else {
                                                  _selectedDeletionKeys.remove(
                                                    target.key,
                                                  );
                                                }
                                              }),
                                        visualDensity: VisualDensity.compact,
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        target.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: disabled
                                            ? Theme.of(
                                                context,
                                              ).textTheme.bodySmall?.copyWith(
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.onSurfaceVariant,
                                              )
                                            : Theme.of(
                                                context,
                                              ).textTheme.bodySmall,
                                      ),
                                    ),
                                    SizedBox(
                                      width: 92,
                                      child: Text(
                                        target.isRemote ? 'Remote' : 'Local',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          CheckboxListTile(
            key: const ValueKey<String>('branch-manager-force-delete'),
            value: _forceLocalDelete,
            onChanged: (value) =>
                setState(() => _forceLocalDelete = value ?? false),
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('忽略合并状态强行删除'),
          ),
          Text(
            '当前检出的本地分支不能删除。远端分支会从对应远端删除。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              key: const ValueKey<String>('branch-manager-delete'),
              onPressed: selectedCount > 0 ? _submit : null,
              icon: const Icon(Icons.remove_circle_outline, size: 17),
              label: const Text('删除分支'),
            ),
          ),
        ],
      ),
    );
  }

  /// 中文：构建带 AnimatedSwitcher 的分支管理面板。
  /// English: Builds the branch manager with an AnimatedSwitcher.
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Dialog(
      key: const ValueKey<String>('branch-manager-dialog'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500, maxHeight: 540),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
              color: colors.surfaceContainerLow,
              child: Row(
                children: [
                  Text(
                    _action == _BranchManagerAction.create ? '新建分支' : '删除分支',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  _modeButton(
                    context,
                    action: _BranchManagerAction.create,
                    icon: Icons.call_split,
                    label: '新建分支',
                    accent: colors.primary,
                  ),
                  const SizedBox(width: 3),
                  _modeButton(
                    context,
                    action: _BranchManagerAction.delete,
                    icon: Icons.remove_circle_outline,
                    label: '删除分支',
                    accent: colors.error,
                  ),
                ],
              ),
            ),
            Flexible(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(.04, 0),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: _action == _BranchManagerAction.create
                    ? KeyedSubtree(
                        key: const ValueKey<String>(
                          'branch-manager-create-view',
                        ),
                        child: _buildCreate(context),
                      )
                    : KeyedSubtree(
                        key: const ValueKey<String>(
                          'branch-manager-delete-view',
                        ),
                        child: _buildDelete(context),
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: const ValueKey<String>('branch-manager-cancel'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _TagDialogMode { create, delete }

sealed class _TagDialogResult {
  const _TagDialogResult();
}

final class _CreateTagDialogResult extends _TagDialogResult {
  const _CreateTagDialogResult(this.options);

  final GitCreateTagOptions options;
}

final class _DeleteTagDialogResult extends _TagDialogResult {
  const _DeleteTagDialogResult(this.options);

  final GitDeleteTagOptions options;
}

/// Sourcetree-style tag manager opened from a historical commit context menu.
///
/// 中文：从历史提交右键打开的标签管理面板；创建默认指向该提交，删除始终另行确认。
class _TagDialog extends StatefulWidget {
  const _TagDialog({required this.session, required this.defaultCommitId});

  final RepositorySessionState session;
  final String defaultCommitId;

  @override
  State<_TagDialog> createState() => _TagDialogState();
}

class _TagDialogState extends State<_TagDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _annotationController;
  late String _targetCommitId;
  _TagDialogMode _mode = _TagDialogMode.create;
  bool _useSpecifiedCommit = false;
  bool _pushTag = false;
  bool _showAdvanced = false;
  bool _annotated = false;
  String? _remoteName;
  String? _deleteTagName;
  bool _deleteRemote = false;
  String? _deleteRemoteName;

  RepositorySessionState get session => widget.session;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _annotationController = TextEditingController();
    _targetCommitId = widget.defaultCommitId;
    _remoteName = _defaultRemote;
    _deleteRemoteName = _defaultRemote;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _annotationController.dispose();
    super.dispose();
  }

  String? get _defaultRemote {
    if (session.remoteNames.contains('origin')) return 'origin';
    return session.remoteNames.firstOrNull;
  }

  String _commitLabel(String objectId) {
    final commit = session.commits
        .where((item) => item.objectId == objectId)
        .firstOrNull;
    final shortId = objectId.length > 8 ? objectId.substring(0, 8) : objectId;
    if (commit == null || commit.subject.trim().isEmpty) return shortId;
    return '$shortId  ${commit.subject}';
  }

  Future<void> _chooseCommit() async {
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => _CommitBasePicker(commits: session.commits),
    );
    if (!mounted || selected == null) return;
    setState(() => _targetCommitId = selected);
  }

  void _submitCreate() {
    final name = _nameController.text.trim();
    if (name.isEmpty ||
        (_useSpecifiedCommit &&
            !session.commits.any(
              (commit) => commit.objectId == _targetCommitId,
            ))) {
      return;
    }
    Navigator.of(context).pop(
      _CreateTagDialogResult(
        GitCreateTagOptions(
          name: name,
          objectId: _targetCommitId,
          annotation: _annotated ? _annotationController.text : null,
          isAnnotated: _annotated,
          pushRemoteName: _pushTag ? _remoteName : null,
        ),
      ),
    );
  }

  void _submitDelete() {
    final name = _deleteTagName;
    if (name == null || (_deleteRemote && _deleteRemoteName == null)) return;
    Navigator.of(context).pop(
      _DeleteTagDialogResult(
        GitDeleteTagOptions(
          name: name,
          deleteRemoteName: _deleteRemote ? _deleteRemoteName : null,
        ),
      ),
    );
  }

  Widget _modeButton({
    required _TagDialogMode mode,
    required IconData icon,
    required String label,
    required Color color,
  }) {
    final selected = _mode == mode;
    return InkWell(
      key: ValueKey<String>('tag-dialog-tab-$mode'),
      borderRadius: BorderRadius.circular(8),
      onTap: () => setState(() => _mode = mode),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: .10) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 17, color: selected ? color : null),
            const SizedBox(height: 2),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: selected ? color : null,
                fontWeight: selected ? FontWeight.w700 : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sourceRadio({required bool specified}) {
    final selected = _useSpecifiedCommit == specified;
    return InkWell(
      onTap: () => setState(() => _useSpecifiedCommit = specified),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 18,
              color: selected ? Theme.of(context).colorScheme.primary : null,
            ),
            const SizedBox(width: 5),
            Text(specified ? '指定的提交' : '右键选择的提交'),
          ],
        ),
      ),
    );
  }

  Widget _remotePicker({
    required String? value,
    required ValueChanged<String?> onChanged,
  }) => DropdownButtonFormField<String>(
    initialValue: value,
    isDense: true,
    decoration: const InputDecoration(
      border: OutlineInputBorder(),
      isDense: true,
    ),
    items: [
      for (final remote in session.remoteNames)
        DropdownMenuItem(value: remote, child: Text(remote)),
    ],
    onChanged: onChanged,
  );

  Widget _buildCreate() {
    final canSubmit =
        _nameController.text.trim().isNotEmpty &&
        (!_pushTag || _remoteName != null);
    return SingleChildScrollView(
      key: const ValueKey<String>('tag-dialog-create-view'),
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey<String>('tag-dialog-name'),
            controller: _nameController,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: '标签名称',
              hintText: '例如 v1.2.0',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          Text('提交', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 3),
          _sourceRadio(specified: false),
          _sourceRadio(specified: true),
          if (_useSpecifiedCommit)
            Padding(
              padding: const EdgeInsets.only(left: 23, top: 4),
              child: OutlinedButton.icon(
                onPressed: session.commits.isEmpty ? null : _chooseCommit,
                icon: const Icon(Icons.commit, size: 16),
                label: Text(
                  _commitLabel(_targetCommitId),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(left: 23, top: 4),
              child: Text(
                _commitLabel(_targetCommitId),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(height: 10),
          CheckboxListTile(
            value: _pushTag,
            onChanged: session.remoteNames.isEmpty
                ? null
                : (value) => setState(() => _pushTag = value ?? false),
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('推送标签到远端'),
            subtitle: session.remoteNames.isEmpty
                ? const Text('当前仓库没有已配置的远端。')
                : null,
          ),
          if (_pushTag)
            Padding(
              padding: const EdgeInsets.only(left: 32, bottom: 8),
              child: _remotePicker(
                value: _remoteName,
                onChanged: (value) => setState(() => _remoteName = value),
              ),
            ),
          InkWell(
            key: const ValueKey<String>('tag-dialog-advanced'),
            onTap: () => setState(() => _showAdvanced = !_showAdvanced),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  Icon(
                    _showAdvanced ? Icons.expand_more : Icons.chevron_right,
                    size: 18,
                  ),
                  const SizedBox(width: 4),
                  const Text('高级选项'),
                ],
              ),
            ),
          ),
          if (_showAdvanced) ...[
            CheckboxListTile(
              value: _annotated,
              onChanged: (value) => setState(() => _annotated = value ?? false),
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('创建附注标签'),
            ),
            if (_annotated)
              TextField(
                key: const ValueKey<String>('tag-dialog-annotation'),
                controller: _annotationController,
                minLines: 2,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: '标签说明（可选）',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
          ],
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              key: const ValueKey<String>('tag-dialog-create'),
              onPressed: canSubmit ? _submitCreate : null,
              icon: const Icon(Icons.sell_outlined, size: 17),
              label: const Text('添加标签'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDelete() {
    final canSubmit =
        _deleteTagName != null && (!_deleteRemote || _deleteRemoteName != null);
    return SingleChildScrollView(
      key: const ValueKey<String>('tag-dialog-delete-view'),
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            key: const ValueKey<String>('tag-dialog-delete-name'),
            initialValue: _deleteTagName,
            isDense: true,
            decoration: const InputDecoration(
              labelText: '本地标签',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: [
              for (final tag in session.tags)
                DropdownMenuItem(
                  value: tag.name,
                  child: Text(tag.name, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (value) => setState(() => _deleteTagName = value),
          ),
          const SizedBox(height: 12),
          CheckboxListTile(
            value: _deleteRemote,
            onChanged: session.remoteNames.isEmpty
                ? null
                : (value) => setState(() => _deleteRemote = value ?? false),
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('同时删除远端标签'),
          ),
          if (_deleteRemote)
            Padding(
              padding: const EdgeInsets.only(left: 32, bottom: 8),
              child: _remotePicker(
                value: _deleteRemoteName,
                onChanged: (value) => setState(() => _deleteRemoteName = value),
              ),
            ),
          Text(
            _deleteRemote
                ? '删除会同时影响已选择远端的协作者。下一步会要求确认。'
                : '删除本地标签不会删除远端同名标签。下一步会要求确认。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              key: const ValueKey<String>('tag-dialog-delete'),
              onPressed: canSubmit ? _submitDelete : null,
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              icon: const Icon(Icons.delete_outline, size: 17),
              label: const Text('删除标签'),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Dialog(
      key: const ValueKey<String>('tag-dialog'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 490, maxHeight: 545),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
              color: colors.surfaceContainerLow,
              child: Row(
                children: [
                  Text(
                    _mode == _TagDialogMode.create ? '添加标签' : '删除标签',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  _modeButton(
                    mode: _TagDialogMode.create,
                    icon: Icons.sell_outlined,
                    label: '添加标签',
                    color: colors.primary,
                  ),
                  const SizedBox(width: 3),
                  _modeButton(
                    mode: _TagDialogMode.delete,
                    icon: Icons.delete_outline,
                    label: '删除标签',
                    color: colors.error,
                  ),
                ],
              ),
            ),
            Flexible(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: _mode == _TagDialogMode.create
                    ? _buildCreate()
                    : _buildDelete(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CommitBasePicker extends StatelessWidget {
  const _CommitBasePicker({required this.commits});

  final List<GitCommit> commits;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('选择提交基点'),
      content: SizedBox(
        width: 520,
        height: 380,
        child: commits.isEmpty
            ? const Center(child: Text('暂无可用提交。'))
            : ListView.builder(
                itemCount: commits.length,
                itemBuilder: (context, index) {
                  final commit = commits[index];
                  final shortId = commit.objectId.length > 8
                      ? commit.objectId.substring(0, 8)
                      : commit.objectId;
                  return ListTile(
                    key: ValueKey<String>('branch-base-${commit.objectId}'),
                    dense: true,
                    leading: const Icon(Icons.commit, size: 18),
                    title: Text(
                      commit.subject.isEmpty ? '（无提交标题）' : commit.subject,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(shortId),
                    onTap: () => Navigator.of(context).pop(commit.objectId),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

class _FetchDialog extends StatefulWidget {
  const _FetchDialog();

  @override
  State<_FetchDialog> createState() => _FetchDialogState();
}

class _FetchDialogState extends State<_FetchDialog> {
  bool _fetchAllRemotes = true;
  bool _pruneDeletedTrackingBranches = false;
  bool _fetchAllTags = false;

  /// 中文：返回当前抓取范围和附加选项。
  /// English: Returns the selected fetch scope and additional options.
  void _submit() {
    Navigator.of(context).pop(
      GitFetchOptions(
        fetchAllRemotes: _fetchAllRemotes,
        pruneDeletedTrackingBranches: _pruneDeletedTrackingBranches,
        fetchAllTags: _fetchAllTags,
      ),
    );
  }

  /// 中文：构建紧凑的抓取选项行。
  /// English: Builds one compact fetch option row.
  Widget _optionRow({
    required bool value,
    required ValueChanged<bool> onChanged,
    required String label,
  }) {
    return SizedBox(
      height: 26,
      child: InkWell(
        onTap: () => onChanged(!value),
        child: Row(
          children: [
            Checkbox(
              value: value,
              visualDensity: VisualDensity.compact,
              onChanged: (next) => onChanged(next ?? false),
            ),
            Expanded(child: Text(label)),
          ],
        ),
      ),
    );
  }

  /// 中文：构建抓取配置弹框。
  /// English: Builds the fetch configuration dialog.
  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _optionRow(
                value: _fetchAllRemotes,
                onChanged: (value) => setState(() => _fetchAllRemotes = value),
                label: '抓取所有远端更新',
              ),
              _optionRow(
                value: _pruneDeletedTrackingBranches,
                onChanged: (value) =>
                    setState(() => _pruneDeletedTrackingBranches = value),
                label: '删掉在所有远端都已经不存在的跟踪（tracking）分支',
              ),
              _optionRow(
                value: _fetchAllTags,
                onChanged: (value) => setState(() => _fetchAllTags = value),
                label: '抓取并在本地存储所有标签',
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(onPressed: _submit, child: const Text('确定')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PushDialog extends StatefulWidget {
  const _PushDialog({
    required this.localBranches,
    required this.remoteNames,
    required this.remoteBranchesByRemote,
    required this.selectedRemote,
    required this.initialRemoteUrl,
    required this.onRemoteChanged,
  });

  final List<GitLocalBranch> localBranches;
  final List<String> remoteNames;
  final Map<String, List<String>> remoteBranchesByRemote;
  final String selectedRemote;
  final String? initialRemoteUrl;
  final Future<String?> Function(String remoteName) onRemoteChanged;

  @override
  State<_PushDialog> createState() => _PushDialogState();
}

class _PushDialogState extends State<_PushDialog> {
  final _selectedBranches = <String>{};
  final _remoteDestinations = <String, String>{};
  final _destinationControllers = <String, TextEditingController>{};
  final _trackingBranches = <String>{};
  late String _selectedRemote;
  String? _remoteUrl;
  bool _isLoadingRemoteUrl = false;
  bool _pushTags = false;

  /// 中文：初始化推送表格的目标分支与远端地址。
  /// English: Initializes destinations and the selected remote URL.
  @override
  void initState() {
    super.initState();
    _selectedRemote = widget.selectedRemote;
    _remoteUrl = widget.initialRemoteUrl;
    for (final branch in widget.localBranches) {
      _remoteDestinations[branch.name] = branch.name;
      _destinationControllers[branch.name] = TextEditingController(
        text: branch.name,
      );
      if (branch.upstream == '$_selectedRemote/${branch.name}') {
        _trackingBranches.add(branch.name);
      }
    }
  }

  /// 中文：释放远程目标分支输入框所持有的控制器。
  /// English: Releases controllers owned by remote destination inputs.
  @override
  void dispose() {
    for (final controller in _destinationControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// 中文：返回当前远端下可快速选择的目标分支，并保留本地同名新建目标。
  /// English: Returns destination branches that can be picked quickly for the
  /// selected remote, retaining the same-name branch as a new-target default.
  List<String> _remoteDestinationOptions(GitLocalBranch branch) {
    final options = <String>{
      branch.name,
      ...?widget.remoteBranchesByRemote[_selectedRemote],
    }.toList()..sort();
    return options;
  }

  /// 中文：切换推送远端并异步读取其地址，不改变用户已勾选的本地分支。
  /// English: Changes the push remote and reads its URL asynchronously without
  /// changing the local branches selected by the user.
  Future<void> _changeRemote(String remoteName) async {
    if (remoteName == _selectedRemote) return;
    setState(() {
      _selectedRemote = remoteName;
      _isLoadingRemoteUrl = true;
      _remoteUrl = null;
      for (final branch in widget.localBranches) {
        final options = _remoteDestinationOptions(branch);
        if (!options.contains(_remoteDestinations[branch.name])) {
          _remoteDestinations[branch.name] = branch.name;
          _destinationControllers[branch.name]?.text = branch.name;
        }
        if (branch.upstream !=
            '$remoteName/${_remoteDestinations[branch.name]}') {
          _trackingBranches.remove(branch.name);
        }
      }
    });
    final remoteUrl = await widget.onRemoteChanged(remoteName);
    if (!mounted || remoteName != _selectedRemote) return;
    setState(() {
      _remoteUrl = remoteUrl;
      _isLoadingRemoteUrl = false;
    });
  }

  /// 中文：提交当前勾选的分支映射、跟踪设置和标签选项。
  /// English: Returns selected mappings, tracking settings, and the tag option.
  void _submit() {
    final branches = [
      for (final branch in widget.localBranches)
        if (_selectedBranches.contains(branch.name))
          GitPushBranch(
            localBranch: branch.name,
            remoteBranch:
                _destinationControllers[branch.name]?.text.trim() ??
                branch.name,
            trackRemote: _trackingBranches.contains(branch.name),
          ),
    ];
    if (branches.isEmpty && !_pushTags) return;
    Navigator.of(context).pop(
      GitPushOptions(
        remoteName: _selectedRemote,
        branches: branches,
        pushTags: _pushTags,
      ),
    );
  }

  /// 中文：构建分支推送表格的一行。
  /// English: Builds one row of the branch push table.
  Widget _buildBranchRow(BuildContext context, GitLocalBranch branch) {
    final selected = _selectedBranches.contains(branch.name);
    final destinations = _remoteDestinationOptions(branch);
    final destinationController = _destinationControllers[branch.name]!;
    return Container(
      color: selected
          ? Theme.of(context).colorScheme.primary.withValues(alpha: .055)
          : null,
      child: SizedBox(
        height: 31,
        child: Row(
          children: [
            SizedBox(
              width: 42,
              child: Checkbox(
                value: selected,
                visualDensity: VisualDensity.compact,
                onChanged: (value) => setState(() {
                  if (value ?? false) {
                    _selectedBranches.add(branch.name);
                  } else {
                    _selectedBranches.remove(branch.name);
                    _trackingBranches.remove(branch.name);
                  }
                }),
              ),
            ),
            Expanded(
              flex: 12,
              child: Text(
                branch.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Expanded(
              flex: 14,
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: TextField(
                  controller: destinationController,
                  enabled: selected,
                  maxLines: 1,
                  style: Theme.of(context).textTheme.bodySmall,
                  onChanged: (value) =>
                      _remoteDestinations[branch.name] = value.trim(),
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 7),
                    suffixIconConstraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    suffixIcon: PopupMenuButton<String>(
                      tooltip: '选择已有远程分支',
                      icon: const Icon(Icons.unfold_more, size: 17),
                      padding: EdgeInsets.zero,
                      onSelected: selected
                          ? (value) {
                              destinationController.text = value;
                              _remoteDestinations[branch.name] = value;
                            }
                          : null,
                      itemBuilder: (context) => [
                        for (final option in destinations)
                          PopupMenuItem(
                            value: option,
                            child: Text(
                              option,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(
              width: 54,
              child: Tooltip(
                message: '推送后将本地分支设为该远端分支的上游',
                child: Checkbox(
                  value: _trackingBranches.contains(branch.name),
                  visualDensity: VisualDensity.compact,
                  onChanged: selected
                      ? (value) => setState(() {
                          if (value ?? false) {
                            _trackingBranches.add(branch.name);
                          } else {
                            _trackingBranches.remove(branch.name);
                          }
                        })
                      : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 中文：构建多分支推送配置面板。
  /// English: Builds the multi-branch push configuration panel.
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final allSelected =
        widget.localBranches.isNotEmpty &&
        _selectedBranches.length == widget.localBranches.length;
    final canSubmit = _selectedBranches.isNotEmpty || _pushTags;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 500),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '推送',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  const Text('推送到仓库：'),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 112,
                    child: DropdownButtonFormField<String>(
                      key: ValueKey<String>(_selectedRemote),
                      initialValue: _selectedRemote,
                      isDense: true,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 7,
                        ),
                      ),
                      items: [
                        for (final remote in widget.remoteNames)
                          DropdownMenuItem(value: remote, child: Text(remote)),
                      ],
                      onChanged: (remote) {
                        if (remote != null) unawaited(_changeRemote(remote));
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 9,
                        ),
                      ),
                      child: Text(
                        _isLoadingRemoteUrl
                            ? '正在读取远端地址…'
                            : _remoteUrl ?? '未读取到远端地址',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text('要推送的分支', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 6),
              Container(
                height: 184,
                decoration: BoxDecoration(
                  border: Border.all(color: colors.outlineVariant),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  children: [
                    Container(
                      height: 30,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        color: colors.surfaceContainerLow,
                        border: Border(
                          bottom: BorderSide(color: colors.outlineVariant),
                        ),
                      ),
                      child: const Row(
                        children: [
                          SizedBox(width: 34, child: Text('推送？')),
                          Expanded(flex: 12, child: Text('本地分支')),
                          Expanded(flex: 14, child: Text('远程分支')),
                          SizedBox(width: 54, child: Text('跟踪？')),
                        ],
                      ),
                    ),
                    Expanded(
                      child: widget.localBranches.isEmpty
                          ? const Center(child: Text('没有可推送的本地分支。'))
                          : ListView.builder(
                              itemCount: widget.localBranches.length,
                              itemBuilder: (context, index) => _buildBranchRow(
                                context,
                                widget.localBranches[index],
                              ),
                            ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: 28,
                child: InkWell(
                  onTap: widget.localBranches.isEmpty
                      ? null
                      : () => setState(() {
                          if (allSelected) {
                            _selectedBranches.clear();
                            _trackingBranches.clear();
                          } else {
                            _selectedBranches.addAll(
                              widget.localBranches.map((branch) => branch.name),
                            );
                          }
                        }),
                  child: Row(
                    children: [
                      Checkbox(
                        value: allSelected,
                        visualDensity: VisualDensity.compact,
                        onChanged: widget.localBranches.isEmpty
                            ? null
                            : (value) => setState(() {
                                if (value ?? false) {
                                  _selectedBranches.addAll(
                                    widget.localBranches.map(
                                      (branch) => branch.name,
                                    ),
                                  );
                                } else {
                                  _selectedBranches.clear();
                                  _trackingBranches.clear();
                                }
                              }),
                      ),
                      const Text('全选'),
                    ],
                  ),
                ),
              ),
              SizedBox(
                height: 28,
                child: InkWell(
                  onTap: () => setState(() => _pushTags = !_pushTags),
                  child: Row(
                    children: [
                      Checkbox(
                        value: _pushTags,
                        visualDensity: VisualDensity.compact,
                        onChanged: (value) =>
                            setState(() => _pushTags = value ?? false),
                      ),
                      const Text('推送所有标签'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: canSubmit ? _submit : null,
                    child: const Text('确定'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CreateBranchDialog extends StatefulWidget {
  const _CreateBranchDialog({this.sourceBranch});

  final String? sourceBranch;

  /// 中文：创建关联的状态对象。
  /// English: Creates the associated state object.
  @override
  State<_CreateBranchDialog> createState() => _CreateBranchDialogState();
}

class _CreateBranchDialogState extends State<_CreateBranchDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();

  /// 中文：释放当前对象持有的资源。
  /// English: Releases resources held by this object.
  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  /// 中文：提交当前表单或请求。
  /// English: Submits the current form or request.
  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    Navigator.of(context).pop(_nameController.text);
  }

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final sourceBranch = widget.sourceBranch;
    return AlertDialog(
      title: Text(sourceBranch == null ? '创建本地分支' : '从分支创建本地分支'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Form(
          key: _formKey,
          child: TextFormField(
            controller: _nameController,
            autofocus: true,
            decoration: InputDecoration(
              border: OutlineInputBorder(),
              hintText: '例如 feature/new-workflow',
              labelText: '分支名称',
              helperText: sourceBranch == null
                  ? '分支将从当前 HEAD 创建，不会切换工作区。'
                  : '分支将从 $sourceBranch 创建，不会切换工作区。',
            ),
            validator: (String? value) {
              if (value == null || value.trim().isEmpty) {
                return '请输入分支名称。';
              }
              return null;
            },
            onFieldSubmitted: (_) => _submit(),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.call_split),
          label: const Text('创建'),
        ),
      ],
    );
  }
}

class RenameBranchDialog extends StatefulWidget {
  const RenameBranchDialog({super.key, required this.oldName});

  final String oldName;

  /// 中文：创建关联的状态对象。
  /// English: Creates the associated state object.
  @override
  State<RenameBranchDialog> createState() => _RenameBranchDialogState();
}

class _RenameBranchDialogState extends State<RenameBranchDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController = TextEditingController(
    text: widget.oldName,
  );

  /// 中文：初始化名称并默认全选，输入后即可直接替换旧分支名。
  /// English: Initializes and selects the complete name so typing immediately
  /// replaces the old branch name.
  @override
  void initState() {
    super.initState();
    _nameController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _nameController.text.length,
    );
  }

  /// 中文：释放当前对象持有的资源。
  /// English: Releases resources held by this object.
  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  /// 中文：验证新分支名称后关闭对话框。
  /// English: Validates the new branch name and closes the dialog.
  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop(_nameController.text);
  }

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey<String>('rename-branch-dialog'),
      title: const Text('重命名分支'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('新分支名称：'),
              const SizedBox(height: 7),
              TextFormField(
                key: const ValueKey<String>('rename-branch-name'),
                controller: _nameController,
                autofocus: true,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                validator: (String? value) {
                  if (value == null || value.trim().isEmpty) {
                    return '请输入分支名称。';
                  }
                  return null;
                },
                onFieldSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 7),
              Text(
                '不会覆盖已有分支，名称仍由 Git 校验。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey<String>('rename-branch-confirm'),
          onPressed: _submit,
          child: const Text('确定'),
        ),
      ],
    );
  }
}

final class DeleteLocalBranchDialogResult {
  const DeleteLocalBranchDialogResult({
    required this.force,
    required this.deleteRemote,
  });

  final bool force;
  final bool deleteRemote;
}

class DeleteLocalBranchDialog extends StatefulWidget {
  const DeleteLocalBranchDialog({
    super.key,
    required this.branchName,
    required this.remoteBranchName,
  });

  final String branchName;
  final String? remoteBranchName;

  /// 中文：创建删除分支确认弹窗的状态对象。
  /// English: Creates the state for the branch-deletion confirmation dialog.
  @override
  State<DeleteLocalBranchDialog> createState() =>
      _DeleteLocalBranchDialogState();
}

class _DeleteLocalBranchDialogState extends State<DeleteLocalBranchDialog> {
  bool _force = false;
  bool _deleteRemote = false;

  /// 中文：返回用户明确确认的本地强制删除和远端删除范围。
  /// English: Returns the explicitly confirmed local force-delete and remote
  /// deletion scope.
  void _submit() {
    Navigator.of(context).pop(
      DeleteLocalBranchDialogResult(force: _force, deleteRemote: _deleteRemote),
    );
  }

  /// 中文：构建接近 Sourcetree 信息层级的删除分支确认弹窗。
  /// English: Builds a branch-deletion confirmation dialog with a
  /// Sourcetree-like information hierarchy.
  @override
  Widget build(BuildContext context) {
    final remoteBranchName = widget.remoteBranchName;
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      key: const ValueKey<String>('delete-branch-dialog'),
      title: const Text('确认删除分支'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('您确定要删除以下分支吗？'),
            const SizedBox(height: 7),
            Text(
              widget.branchName,
              key: const ValueKey<String>('delete-branch-name'),
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            CheckboxListTile(
              key: const ValueKey<String>('delete-branch-force'),
              value: _force,
              onChanged: (value) => setState(() => _force = value ?? false),
              dense: true,
              contentPadding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('强制删除'),
            ),
            CheckboxListTile(
              key: const ValueKey<String>('delete-branch-remote'),
              value: _deleteRemote,
              onChanged: remoteBranchName == null
                  ? null
                  : (value) => setState(() => _deleteRemote = value ?? false),
              dense: true,
              contentPadding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('删除远程分支'),
              subtitle: remoteBranchName == null
                  ? const Text('此分支没有已加载的上游远程分支')
                  : Text(remoteBranchName),
            ),
            const SizedBox(height: 8),
            Text(
              _force
                  ? '强制删除会忽略合并状态，未合并提交可能无法再通过分支引用找回。'
                  : '默认使用 Git 安全删除；包含未合并提交时 Git 会拒绝。',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
            if (_deleteRemote && remoteBranchName != null) ...[
              const SizedBox(height: 5),
              Text(
                '同时请求删除远端 $remoteBranchName，最终结果受远端权限和保护规则限制。',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey<String>('delete-branch-confirm'),
          onPressed: _submit,
          child: const Text('确定'),
        ),
      ],
    );
  }
}

class _CommitDialogState extends ConsumerState<_CommitDialog> {
  final _formKey = GlobalKey<FormState>();
  final _messageController = TextEditingController();
  bool _pushAfterCommit = false;
  bool _amend = false;

  /// 中文：释放当前对象持有的资源。
  /// English: Releases resources held by this object.
  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  /// 中文：提交当前表单或请求。
  /// English: Submits the current form or request.
  void _submit({required bool canSubmit}) {
    if (!canSubmit) {
      return;
    }
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    Navigator.of(context).pop(
      _CommitDialogResult(
        message: _messageController.text.trim(),
        pushAfterCommit: _pushAfterCommit,
        amend: _amend,
      ),
    );
  }

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final session = ref.watch(repositorySessionProvider);
    final repository = mapRepositoryOverview(session).repository;
    final changes = repository?.changes ?? const <RepositoryChangeViewData>[];
    final staged = changes.where((change) => change.isStaged).toList();
    final unstaged = changes.where((change) => !change.isStaged).toList();
    final isBusy =
        session.phase == RepositorySessionPhase.loading ||
        session.operationState != GitRepositoryOperationState.none;
    final branch = session.status?.branch;
    String? amendMessage;
    final headObjectId = branch?.objectId;
    if (headObjectId != null) {
      for (final commit in session.commits) {
        if (commit.objectId == headObjectId) {
          final body = commit.body.trimRight();
          amendMessage = body.isEmpty
              ? commit.subject
              : '${commit.subject}\n\n$body';
          break;
        }
      }
    }
    final pushAvailable =
        !isBusy &&
        branch != null &&
        (branch.objectId != null || branch.isUnborn) &&
        !branch.isDetached &&
        (session.hasOriginRemote || branch.upstream != null);
    final amendAvailable =
        !isBusy &&
        branch != null &&
        branch.objectId != null &&
        !branch.isDetached;
    final canSubmit = staged.isNotEmpty || _amend;
    final pushOptionAvailable = pushAvailable && !_amend;

    Widget changeList(String title, List<RepositoryChangeViewData> entries) {
      if (entries.isEmpty) return const SizedBox.shrink();
      final colors = Theme.of(context).colorScheme;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            color: colors.surfaceContainerLow,
            child: Row(
              children: [
                Icon(
                  title == '已暂存文件'
                      ? Icons.check_box
                      : Icons.check_box_outline_blank,
                  size: 17,
                  color: title == '已暂存文件'
                      ? colors.primary
                      : colors.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Text('${entries.length}'),
              ],
            ),
          ),
          ...entries.map(
            (change) => CheckboxListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              value: change.isStaged,
              onChanged: !isBusy && change.canToggleStage
                  ? (_) => ref
                        .read(repositorySessionProvider.notifier)
                        .toggleStage(change)
                  : null,
              title: Text(change.path, overflow: TextOverflow.ellipsis),
              subtitle: change.previousPath == null
                  ? null
                  : Text('来自 ${change.previousPath}'),
              controlAffinity: ListTileControlAffinity.leading,
            ),
          ),
        ],
      );
    }

    return AlertDialog(
      title: const Text('提交工作区改动'),
      content: SizedBox(
        width: 760,
        height: 560,
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('选择要提交的文件', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: changes.isEmpty
                      ? const Center(child: Text('工作区没有待提交的改动。'))
                      : ListView(
                          padding: EdgeInsets.zero,
                          children: [
                            changeList('已暂存文件', staged),
                            changeList('未暂存文件', unstaged),
                          ],
                        ),
                ),
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _messageController,
                autofocus: true,
                minLines: 3,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                  hintText: '简要说明这次提交的改动',
                  labelText: '提交信息',
                ),
                validator: (String? value) {
                  if (value == null || value.trim().isEmpty) {
                    return '请输入提交信息。';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 4),
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: _pushAfterCommit,
                onChanged: pushOptionAvailable
                    ? (value) =>
                          setState(() => _pushAfterCommit = value ?? false)
                    : null,
                title: Text(
                  '立即推送变更到 ${branch?.upstream ?? 'origin/${branch?.head ?? '当前分支'}'}',
                ),
                subtitle: pushOptionAvailable
                    ? null
                    : Text(
                        _amend ? 'Amend 后不会自动强制推送，请手动处理远端分支。' : '当前分支没有可用的远端。',
                      ),
                controlAffinity: ListTileControlAffinity.leading,
              ),
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: _amend,
                onChanged: amendAvailable
                    ? (value) => setState(() {
                        _amend = value ?? false;
                        if (_amend) {
                          _pushAfterCommit = false;
                          if (_messageController.text.trim().isEmpty &&
                              amendMessage != null) {
                            _messageController.text = amendMessage;
                          }
                        }
                      })
                    : null,
                title: const Text('更正上一次提交'),
                subtitle: amendAvailable ? null : const Text('当前分支没有可更正的提交。'),
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: canSubmit && !isBusy
              ? () => _submit(canSubmit: canSubmit)
              : null,
          icon: const Icon(Icons.check_circle_outline),
          label: const Text('提交'),
        ),
      ],
    );
  }
}

final class _PullRefreshResult {
  const _PullRefreshResult({required this.branchesByRemote, this.remoteUrl});

  final Map<String, List<String>> branchesByRemote;
  final String? remoteUrl;
}

/// A compact pull configuration dialog modeled after Sourcetree's native
/// pull sheet. It deliberately keeps the working branch read-only: pulling
/// always updates the currently checked-out branch.
class _PullDialog extends StatefulWidget {
  const _PullDialog({
    required this.remoteNames,
    required this.branchesByRemote,
    required this.selectedRemote,
    required this.remoteBranch,
    required this.localBranch,
    required this.remoteUrl,
    this.onRefresh,
    this.onRemoteChanged,
  });

  final List<String> remoteNames;
  final Map<String, List<String>> branchesByRemote;
  final String selectedRemote;
  final String remoteBranch;
  final String localBranch;
  final String? remoteUrl;
  final Future<_PullRefreshResult> Function(String remoteName)? onRefresh;
  final Future<String?> Function(String remoteName)? onRemoteChanged;

  @override
  State<_PullDialog> createState() => _PullDialogState();
}

class _PullDialogState extends State<_PullDialog> {
  late String _remote;
  late String _branch;
  late Map<String, List<String>> _branchesByRemote;
  String? _remoteUrl;
  var _isRefreshing = false;
  String? _refreshError;
  var _commitMerge = false;
  var _includeMergedCommits = false;
  var _createMergeCommit = false;
  var _rebase = false;

  @override
  void initState() {
    super.initState();
    _branchesByRemote = {
      for (final entry in widget.branchesByRemote.entries)
        entry.key: List<String>.of(entry.value),
    };
    _remoteUrl = widget.remoteUrl;
    _remote = widget.remoteNames.contains(widget.selectedRemote)
        ? widget.selectedRemote
        : widget.remoteNames.first;
    _branch = _branchesFor(_remote).contains(widget.remoteBranch)
        ? widget.remoteBranch
        : _branchesFor(_remote).first;
    unawaited(_loadRemoteUrl(_remote));
  }

  List<String> _branchesFor(String remote) {
    final branches = _branchesByRemote[remote];
    if (branches == null || branches.isEmpty) {
      return <String>[widget.remoteBranch];
    }
    return branches;
  }

  Future<void> _refresh() async {
    final callback = widget.onRefresh;
    if (_isRefreshing || callback == null) return;
    setState(() {
      _isRefreshing = true;
      _refreshError = null;
    });
    try {
      final result = await callback(_remote);
      if (!mounted) return;
      setState(() {
        _branchesByRemote = {
          for (final entry in result.branchesByRemote.entries)
            entry.key: List<String>.of(entry.value)..sort(),
        };
        _remoteUrl = result.remoteUrl;
        final branches = _branchesFor(_remote);
        if (!branches.contains(_branch)) _branch = branches.first;
      });
    } on Object {
      if (mounted) {
        setState(() => _refreshError = '刷新失败，请检查网络或 Git 凭据。');
      }
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  Future<void> _loadRemoteUrl(String remote) async {
    final callback = widget.onRemoteChanged;
    if (callback == null) return;
    try {
      final url = await callback(remote);
      if (!mounted || _remote != remote) return;
      setState(() => _remoteUrl = url);
    } on Object {
      if (mounted && _remote == remote) setState(() => _remoteUrl = null);
    }
  }

  void _submit() {
    Navigator.of(context).pop(
      GitPullOptions(
        remoteName: _remote,
        remoteBranch: _branch,
        commitMerge: _commitMerge,
        includeMergedCommits: _includeMergedCommits,
        createMergeCommit: _createMergeCommit,
        rebase: _rebase,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final branches = _branchesFor(_remote);
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
      actionsPadding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _PullRow(
              label: '从仓库拉取：',
              child: _PullSelect<String>(
                value: _remote,
                items: widget.remoteNames,
                onChanged: (value) {
                  if (value == null) return;
                  final nextBranches = _branchesFor(value);
                  setState(() {
                    _remote = value;
                    _branch = nextBranches.first;
                  });
                  unawaited(_loadRemoteUrl(value));
                },
              ),
            ),
            const SizedBox(height: 7),
            _PullRow(
              label: '',
              child: Text(
                _remoteUrl ?? '未读取到远端地址',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 12),
            _PullRow(
              label: '要拉取的远程分支：',
              child: Row(
                children: [
                  Expanded(
                    child: _PullSelect<String>(
                      value: _branch,
                      items: branches,
                      onChanged: (value) {
                        if (value != null) setState(() => _branch = value);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: widget.onRefresh == null ? null : _refresh,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(54, 36),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    child: const Text('刷新'),
                  ),
                ],
              ),
            ),
            if (_refreshError != null) ...[
              const SizedBox(height: 4),
              Text(
                _refreshError!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 10),
            _PullRow(
              label: '拉取到本地分支：',
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  widget.localBranch,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withAlpha(90),
                border: Border.all(
                  color: theme.colorScheme.outlineVariant.withAlpha(110),
                ),
                borderRadius: BorderRadius.circular(7),
              ),
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Column(
                children: [
                  _PullCheckbox(
                    value: _commitMerge,
                    label: '立即提交合并的改动',
                    onChanged: (value) =>
                        setState(() => _commitMerge = value ?? false),
                  ),
                  _PullCheckbox(
                    value: _includeMergedCommits,
                    label: '包括被合并提交的信息内容',
                    onChanged: (value) =>
                        setState(() => _includeMergedCommits = value ?? false),
                  ),
                  _PullCheckbox(
                    value: _createMergeCommit,
                    label: '无论是否可以快速更新都创建新的提交',
                    onChanged: (value) =>
                        setState(() => _createMergeCommit = value ?? false),
                  ),
                  _PullCheckbox(
                    value: _rebase,
                    label: '用变基代替合并（警告：请确保您还没有推送您的变更）',
                    onChanged: (value) =>
                        setState(() => _rebase = value ?? false),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('确定')),
      ],
    );
  }
}

class _PullRow extends StatelessWidget {
  const _PullRow({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(width: 112, child: Text(label, textAlign: TextAlign.right)),
        const SizedBox(width: 10),
        Expanded(child: child),
      ],
    );
  }
}

class _PullSelect<T> extends StatelessWidget {
  const _PullSelect({
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final T value;
  final List<T> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outline),
        borderRadius: BorderRadius.circular(5),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          icon: const Icon(Icons.unfold_more, size: 18),
          items: [
            for (final item in items)
              DropdownMenuItem<T>(value: item, child: Text('$item')),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _PullCheckbox extends StatelessWidget {
  const _PullCheckbox({
    required this.value,
    required this.label,
    required this.onChanged,
  });

  final bool value;
  final String label;
  final ValueChanged<bool?> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 28,
      child: CheckboxListTile(
        value: value,
        onChanged: onChanged,
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(label, style: Theme.of(context).textTheme.bodyMedium),
      ),
    );
  }
}
