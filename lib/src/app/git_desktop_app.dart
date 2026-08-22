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

enum _RebasePromptAction { continueRebase, abort, cancel }

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
  bool _isRebasePromptVisible = false;
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

  /// 中文：在变基因冲突暂停时提供继续、中止或稍后处理的操作提示。
  /// English: Offers continue, abort, or defer actions when a rebase pauses.
  void _handleRepositoryStateChange(
    RepositorySessionState? previous,
    RepositorySessionState next,
  ) {
    _reportOpenedRepository(previous, next);
    final enteredRebase =
        next.operationState == GitRepositoryOperationState.rebase &&
        previous?.operationState != GitRepositoryOperationState.rebase;
    if (enteredRebase && !_isRebasePromptVisible && mounted) {
      _isRebasePromptVisible = true;
      unawaited(_showRebasePrompt());
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
        ref.read(repositorySessionProvider.notifier).fetchOrigin();
      case RepositoryAction.cancelFetch:
        ref.read(repositorySessionProvider.notifier).cancelFetch();
      case RepositoryAction.pull:
        _confirmPull();
      case RepositoryAction.cancelPull:
        ref.read(repositorySessionProvider.notifier).cancelPull();
      case RepositoryAction.continueRebase:
        unawaited(_continueRebase());
      case RepositoryAction.abortRebase:
        unawaited(_confirmAbortRebase());
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
    RepositoryOperationKind.pull => '拉取更新',
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
    final session = ref.read(repositorySessionProvider);
    final branch = session.status?.branch;
    final localBranch = branch?.head;
    final upstream = branch?.upstream;
    if (localBranch == null || upstream == null) return;
    final separator = upstream.indexOf('/');
    if (separator <= 0 || separator == upstream.length - 1) return;
    final upstreamRemote = upstream.substring(0, separator);
    final upstreamBranch = upstream.substring(separator + 1);
    final remoteNames = <String>{upstreamRemote};
    final branchesByRemote = <String, List<String>>{};
    for (final remoteBranch in session.remoteBranches) {
      final slash = remoteBranch.name.indexOf('/');
      if (slash > 0) {
        final remote = remoteBranch.name.substring(0, slash);
        remoteNames.add(remote);
        branchesByRemote
            .putIfAbsent(remote, () => <String>[])
            .add(remoteBranch.name.substring(slash + 1));
      }
    }
    branchesByRemote.putIfAbsent(upstreamRemote, () => <String>[]);
    if (!branchesByRemote[upstreamRemote]!.contains(upstreamBranch)) {
      branchesByRemote[upstreamRemote]!.add(upstreamBranch);
    }
    for (final branches in branchesByRemote.values) {
      branches.sort();
    }
    final options = await showDialog<GitPullOptions>(
      context: context,
      builder: (BuildContext context) => _PullDialog(
        remoteNames: remoteNames.toList()..sort(),
        branchesByRemote: branchesByRemote,
        selectedRemote: upstreamRemote,
        remoteBranch: upstreamBranch,
        localBranch: localBranch,
        remoteUrl: session.originUrl,
        onRefresh: (remoteName) async {
          final controller = ref.read(repositorySessionProvider.notifier);
          final fetched = await controller.fetchRemote(remoteName);
          if (!fetched) {
            throw const GitException('Unable to refresh the selected remote.');
          }
          final latest = ref.read(repositorySessionProvider);
          final refreshed = <String, List<String>>{};
          for (final remoteBranch in latest.remoteBranches) {
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

  /// 中文：请求并处理用户确认。
  /// English: Requests and handles user confirmation.
  Future<void> _confirmPush() async {
    final session = ref.read(repositorySessionProvider);
    final branch = session.status?.branch;
    final branchName = branch?.head ?? '当前分支';
    final upstream = branch?.upstream ?? 'origin/$branchName';
    final ahead = branch?.ahead ?? 0;
    final isFirstPush =
        branch != null && (branch.upstream == null || branch.isUpstreamGone);
    final approved = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('推送提交'),
        content: Text(
          isFirstPush
              ? '远端分支 $upstream 尚不存在。将推送 $branchName 并创建该远端分支。不会执行强制推送。'
              : '将 $branchName 的 $ahead 个本地提交推送到 $upstream。不会执行强制推送。',
        ),
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
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => InternalConflictResolverDialog(
        path: versions.path.display,
        currentBranch: branch ?? '当前分支',
        oursText: versions.oursText,
        theirsText: versions.theirsText,
        workingText: versions.workingText,
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
                onCommitActivated: (commit) =>
                    unawaited(_confirmCheckoutCommit(commit)),
                onCommitFileSelected: (file) =>
                    unawaited(controller.selectCommitFile(file)),
                onChangeSelected: controller.selectChange,
                onChangeStageToggled: controller.toggleStage,
                onChangeGroupStageToggled: (changes, stage) =>
                    controller.toggleStageGroup(changes, stage: stage),
                onConflictAction: (change, action) =>
                    unawaited(_handleConflictAction(change, action)),
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
