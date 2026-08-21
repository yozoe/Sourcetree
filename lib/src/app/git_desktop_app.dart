import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yeknom_ui_kit/yeknom_workbench.dart';

import '../git/git.dart';
import '../presentation/presentation.dart';
import 'desktop_window_bridge.dart';
import 'git_askpass_prompt_coordinator.dart';
import 'repository_session.dart';
import 'repository_view_mapper.dart';
import 'theme_preferences.dart';

class GitDesktopApp extends StatefulWidget {
  const GitDesktopApp({
    super.key,
    this.isWorkspaceWindow = false,
    this.initialRepositoryPath,
    this.initialWorkspaceAction,
    this.initialThemePreferences = GitDesktopThemePreferences.defaults,
    this.themePreferencesStore,
  });

  /// Whether this Flutter engine is hosted by a repository workspace window.
  final bool isWorkspaceWindow;

  /// Repository path opened automatically by a newly created workspace.
  final String? initialRepositoryPath;

  /// Optional action requested by the repository library for a new workspace.
  final String? initialWorkspaceAction;
  final GitDesktopThemePreferences initialThemePreferences;
  final GitDesktopThemePreferencesStore? themePreferencesStore;

  @override
  State<GitDesktopApp> createState() => _GitDesktopAppState();
}

class _GitDesktopAppState extends State<GitDesktopApp> {
  late bool _isWorkspaceWindow;
  String? _initialRepositoryPath;
  String? _initialWorkspaceAction;
  late GitDesktopThemePreferences _themePreferences;
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  Future<void> _themeSaveTail = Future<void>.value();
  StreamSubscription<GitDesktopThemePreferences>? _themeSubscription;

  /// 中文：注册原生窗口传入的工作区配置。
  /// English: Registers workspace configuration sent by the native window
  /// host after its Flutter engine becomes ready.
  @override
  void initState() {
    super.initState();
    _isWorkspaceWindow = widget.isWorkspaceWindow;
    _initialRepositoryPath = widget.initialRepositoryPath;
    _initialWorkspaceAction = widget.initialWorkspaceAction;
    _themePreferences = widget.initialThemePreferences;
    final store = widget.themePreferencesStore;
    if (store is WatchableGitDesktopThemePreferencesStore) {
      _themeSubscription = store.watch().listen((next) {
        if (mounted && next != _themePreferences) {
          setState(() => _themePreferences = next);
        }
      }, onError: (_) {});
    }
  }

  /// 中文：释放当前对象持有的资源。
  /// English: Releases resources held by the current object.
  @override
  void dispose() {
    final themeSubscription = _themeSubscription;
    if (themeSubscription != null) unawaited(themeSubscription.cancel());
    super.dispose();
  }

  void _setThemeMode(ThemeMode mode) =>
      _updateThemePreferences(_themePreferences.copyWith(mode: mode));

  void _setThemePreset(YeknomColorPreset preset) =>
      _updateThemePreferences(_themePreferences.copyWith(preset: preset));

  void _updateThemePreferences(GitDesktopThemePreferences next) {
    if (next == _themePreferences) return;
    setState(() => _themePreferences = next);
    final store = widget.themePreferencesStore;
    if (store == null) return;
    _themeSaveTail = _themeSaveTail.then((_) async {
      try {
        await store.save(next);
      } on Object {
        _messengerKey.currentState
          ?..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('主题偏好保存失败；本次切换仍然有效。')));
      }
    });
  }

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final themeControl = GitDesktopThemeMenuButton(
      preferences: _themePreferences,
      onThemeModeChanged: _setThemeMode,
      onThemePresetChanged: _setThemePreset,
    );
    return MaterialApp(
      title: 'Git Desktop',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: _messengerKey,
      themeMode: _themePreferences.mode,
      theme: _theme(Brightness.light, _themePreferences.preset),
      darkTheme: _theme(Brightness.dark, _themePreferences.preset),
      home: _isWorkspaceWindow
          ? RepositoryWorkspaceScreen(
              key: ValueKey<String>(
                '${_initialRepositoryPath ?? ''}|${_initialWorkspaceAction ?? ''}',
              ),
              initialRepositoryPath: _initialRepositoryPath,
              initialAction: _initialWorkspaceAction,
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
  late final Future<void> _restoreFuture;
  Future<void> _repositoryRegistrationTail = Future<void>.value();

  /// 中文：首页窗口初始化时恢复本地仓库清单。
  /// English: Restores the local repository list when the library window
  /// initializes.
  @override
  void initState() {
    super.initState();
    _restoreFuture = ref
        .read(repositorySessionProvider.notifier)
        .restoreSession();
    DesktopWindowBridge.setRepositoryOpenedHandler(_recordRepositoryOpened);
  }

  @override
  void dispose() {
    DesktopWindowBridge.setRepositoryOpenedHandler(null);
    super.dispose();
  }

  /// Adds a repository confirmed by a workspace to the live library and its
  /// persisted repository list.
  Future<void> _recordRepositoryOpened(String repositoryPath) {
    final registration = _repositoryRegistrationTail.then((_) async {
      await _restoreFuture;
      if (!mounted) return;
      await ref
          .read(repositorySessionProvider.notifier)
          .openRepository(repositoryPath);
    });
    _repositoryRegistrationTail = registration.catchError((_) {});
    return registration;
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
    final session = ref.watch(repositorySessionProvider);
    return Scaffold(
      body: RepositoryLibraryPage(
        repositories: session.openRepositoryTabs
            .map(
              (RepositoryTab tab) =>
                  RepositoryLibraryItem(path: tab.path, label: tab.label),
            )
            .toList(growable: false),
        activePath: null,
        onRepositorySelected: (String path) => _openWorkspace(path),
        onOpenRepository: () => unawaited(_pickRepositoryAndOpen()),
        onCloneRepository: () =>
            unawaited(_openWorkspace(null, initialAction: 'cloneRepository')),
        onInitializeRepository: () => unawaited(
          _openWorkspace(null, initialAction: 'initializeRepository'),
        ),
        trailing: widget.themeControl,
      ),
    );
  }
}

/// 中文：根据亮度创建 Git 桌面客户端的 Yeknom Workbench 主题，并使用 Cobalt 颜色组合。
///
/// English: Creates the Git desktop application's Yeknom Workbench theme for
/// a brightness using the Cobalt color preset.
ThemeData _theme(Brightness brightness, YeknomColorPreset preset) =>
    YeknomWorkbenchTheme.build(brightness, preset: preset);

/// Maps a route action name to the safe workspace action it requests.
RepositoryAction? _repositoryActionFromName(String? name) => switch (name) {
  'openRepository' => RepositoryAction.openRepository,
  'cloneRepository' => RepositoryAction.cloneRepository,
  'initializeRepository' => RepositoryAction.initializeRepository,
  _ => null,
};

class RepositoryWorkspaceScreen extends ConsumerStatefulWidget {
  const RepositoryWorkspaceScreen({
    super.key,
    this.initialRepositoryPath,
    this.initialAction,
    this.themeControl,
  });

  /// Repository selected by the independent repository library window.
  final String? initialRepositoryPath;

  /// Action to start after this independent workspace window is ready.
  final String? initialAction;
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
  bool _hasHandledInitialAction = false;

  /// 中文：在窗口首次绘制后执行首页请求的仓库操作。
  /// English: Starts the repository action requested by the library after the
  /// workspace window has drawn for the first time.
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepareWorkspace());
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

  /// Tells the repository library which repository this workspace now owns.
  void _reportOpenedRepository(
    RepositorySessionState? previous,
    RepositorySessionState next,
  ) {
    final repository = next.repository;
    if (next.phase != RepositorySessionPhase.ready || repository == null) {
      return;
    }
    if (previous?.phase == RepositorySessionPhase.ready &&
        previous?.repository?.id == repository.id) {
      return;
    }
    unawaited(
      DesktopWindowBridge.repositoryOpened(
        repository.commandDirectory,
      ).catchError((_) {}),
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

  /// 中文：收集远端地址和空目标目录，经用户确认后克隆并在界面提示结果。
  ///
  /// English: Collects a remote URL and empty destination, confirms with the
  /// user, then clones and reports the result in the UI.
  Future<void> _cloneRepository() async {
    final remoteUrl = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => const _CloneDialog(),
    );
    if (remoteUrl == null || !mounted) return;
    final directory = await getDirectoryPath(confirmButtonText: '选择空目录');
    if (directory == null || !mounted) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('克隆 Git 仓库'),
        content: const Text('仅当所选目标目录为空时才会继续。克隆可能需要现有 Git 凭据。'),
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
        .cloneRepository(remoteUrl: remoteUrl, directoryPath: directory);
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
        ref.read(repositorySessionProvider.notifier).fetchOrigin();
      case RepositoryAction.cancelFetch:
        ref.read(repositorySessionProvider.notifier).cancelFetch();
      case RepositoryAction.pull:
        _confirmPull();
      case RepositoryAction.cancelPull:
        ref.read(repositorySessionProvider.notifier).cancelPull();
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
      case RepositoryAction.createBranch:
        _showCreateBranchDialog();
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
                  ? const Center(child: Text('尚无可显示的远端操作。'))
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
    RepositoryOperationKind.pull => '快速前进拉取',
    RepositoryOperationKind.push => '推送当前分支',
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

  /// 中文：请求并处理用户确认。
  /// English: Requests and handles user confirmation.
  Future<void> _confirmPull() async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('快速前进拉取'),
        content: const Text('将从当前分支的上游拉取更新。仅允许快速前进，不会自动创建合并提交。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.south),
            label: const Text('拉取'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    final pulled = await ref
        .read(repositorySessionProvider.notifier)
        .pullFastForward();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(pulled ? '已快速前进拉取。' : '未拉取，请查看仓库状态和错误信息。'),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// 中文：请求并处理用户确认。
  /// English: Requests and handles user confirmation.
  Future<void> _confirmPush() async {
    final session = ref.read(repositorySessionProvider);
    final branch = session.status?.branch;
    final branchName = branch?.head ?? '当前分支';
    final upstream = branch?.upstream ?? '上游';
    final ahead = branch?.ahead ?? 0;
    final approved = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('推送提交'),
        content: Text('将 $branchName 的 $ahead 个本地提交推送到 $upstream。不会执行强制推送。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.north),
            label: const Text('推送'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    final pushed = await ref
        .read(repositorySessionProvider.notifier)
        .pushUpstream();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(pushed ? '已推送提交。' : '推送未完成，请查看仓库状态和错误信息。'),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// 中文：显示相应界面或信息。
  /// English: Shows the corresponding UI or information.
  Future<void> _showCommitDialog() async {
    final message = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => const _CommitDialog(),
    );
    if (message == null || !mounted) {
      return;
    }

    final created = await ref
        .read(repositorySessionProvider.notifier)
        .createCommit(message);
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(created ? '已创建提交。' : '提交未完成，请查看仓库错误信息。'),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// 中文：显示相应界面或信息。
  /// English: Shows the corresponding UI or information.
  Future<void> _showCreateBranchDialog() async {
    final name = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => const _CreateBranchDialog(),
    );
    if (name == null || !mounted) {
      return;
    }

    final created = await ref
        .read(repositorySessionProvider.notifier)
        .createLocalBranch(name);
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(created ? '已创建本地分支 $name。' : '分支未创建，请查看仓库错误信息。'),
        duration: const Duration(seconds: 3),
      ),
    );
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
      builder: (BuildContext context) => _RenameBranchDialog(oldName: oldName),
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

  /// 中文：确认后仅以 Git 的安全删除模式删除一个非当前本地分支。
  ///
  /// English: Confirms deletion of a non-current local branch using only Git's
  /// safe deletion mode.
  Future<void> _confirmDeleteLocalBranch(String branchName) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('删除本地分支'),
        content: Text('删除 $branchName？仅删除已合并的分支；未合并提交会被 Git 拒绝，且不会强制删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.delete_outline),
            label: const Text('安全删除'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;

    final deleted = await ref
        .read(repositorySessionProvider.notifier)
        .deleteMergedLocalBranch(branchName);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(deleted ? '已删除本地分支 $branchName。' : '分支未删除；它可能包含尚未合并的提交。'),
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
        _handleAction(RepositoryAction.fetch);
      case RepositoryRefContextAction.pullCurrentBranch:
        unawaited(_confirmPull());
      case RepositoryRefContextAction.pushCurrentBranch:
        unawaited(_confirmPush());
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
    }
  }

  /// 中文：请求并处理用户确认。
  /// English: Requests and handles user confirmation.
  Future<void> _confirmSwitchBranch(String branchName) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('切换分支'),
        content: Text('切换到 $branchName？仅当工作区和暂存区均无改动时才会执行。'),
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
      _reportOpenedRepository,
    );
    final session = ref.watch(repositorySessionProvider);
    final controller = ref.read(repositorySessionProvider.notifier);
    return Scaffold(
      body: Column(
        children: [
          RepositoryTabStrip(
            tabs: session.openRepositoryTabs,
            activePath: session.activeRepositoryTabPath,
            onSelected: controller.selectRepositoryTab,
            trailing: widget.themeControl,
          ),
          Expanded(
            child: RepositoryOverview(
              data: mapRepositoryOverview(session),
              callbacks: RepositoryOverviewCallbacks(
                onAction: _handleAction,
                onRefSelected: (reference) =>
                    unawaited(controller.selectReference(reference)),
                onRefActivated: _handleReferenceActivated,
                onRefContextAction: _handleReferenceContextAction,
                onSearchChanged: controller.setSearchQuery,
                onCommitSelected: (commit) =>
                    unawaited(controller.selectCommit(commit.oid)),
                onCommitFileSelected: (file) =>
                    unawaited(controller.selectCommitFile(file)),
                onChangeSelected: controller.selectChange,
                onChangeStageToggled: controller.toggleStage,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class RepositoryTabStrip extends StatelessWidget {
  const RepositoryTabStrip({
    super.key,
    required this.tabs,
    required this.activePath,
    required this.onSelected,
    this.trailing,
  });

  final List<RepositoryTab> tabs;
  final String? activePath;
  final Future<void> Function(String path) onSelected;
  final Widget? trailing;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerHighest,
      child: SizedBox(
        height: 42,
        child: Row(
          children: [
            Expanded(
              child: ListView.separated(
                key: const ValueKey<String>('repository-tab-strip'),
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                itemCount: tabs.length,
                separatorBuilder: (context, index) => const SizedBox(width: 4),
                itemBuilder: (context, index) {
                  final tab = tabs[index];
                  final selected = tab.path == activePath;
                  return Semantics(
                    button: true,
                    selected: selected,
                    label: '仓库标签 ${tab.label}',
                    child: Tooltip(
                      message: tab.path,
                      child: TextButton.icon(
                        onPressed: () => unawaited(onSelected(tab.path)),
                        style: TextButton.styleFrom(
                          backgroundColor: selected
                              ? colors.secondaryContainer
                              : Colors.transparent,
                          foregroundColor: selected
                              ? colors.onSecondaryContainer
                              : colors.onSurfaceVariant,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          shape: const RoundedRectangleBorder(
                            borderRadius: BorderRadius.all(Radius.circular(8)),
                          ),
                        ),
                        icon: const Icon(Icons.folder_outlined, size: 16),
                        label: Text(tab.label, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                  );
                },
              ),
            ),
            if (trailing case final trailing?) ...[
              VerticalDivider(
                width: 1,
                indent: 8,
                endIndent: 8,
                color: colors.outlineVariant,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: trailing,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CommitDialog extends StatefulWidget {
  const _CommitDialog();

  /// 中文：创建关联的状态对象。
  /// English: Creates the associated state object.
  @override
  State<_CommitDialog> createState() => _CommitDialogState();
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
          validator: (value) =>
              value == null || value.trim().isEmpty ? '请输入远端地址。' : null,
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

class _RenameBranchDialog extends StatefulWidget {
  const _RenameBranchDialog({required this.oldName});

  final String oldName;

  /// 中文：创建关联的状态对象。
  /// English: Creates the associated state object.
  @override
  State<_RenameBranchDialog> createState() => _RenameBranchDialogState();
}

class _RenameBranchDialogState extends State<_RenameBranchDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController = TextEditingController(
    text: widget.oldName,
  );

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
      title: const Text('重命名本地分支'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Form(
          key: _formKey,
          child: TextFormField(
            controller: _nameController,
            autofocus: true,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: '新分支名称',
              helperText: '不会覆盖已有分支，Git 会校验名称。',
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
          icon: const Icon(Icons.drive_file_rename_outline),
          label: const Text('重命名'),
        ),
      ],
    );
  }
}

class _CommitDialogState extends State<_CommitDialog> {
  final _formKey = GlobalKey<FormState>();
  final _messageController = TextEditingController();

  /// 中文：释放当前对象持有的资源。
  /// English: Releases resources held by this object.
  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  /// 中文：提交当前表单或请求。
  /// English: Submits the current form or request.
  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    Navigator.of(context).pop(_messageController.text);
  }

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('创建提交'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Form(
          key: _formKey,
          child: TextFormField(
            controller: _messageController,
            autofocus: true,
            minLines: 5,
            maxLines: 10,
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
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.check_circle_outline),
          label: const Text('提交'),
        ),
      ],
    );
  }
}
