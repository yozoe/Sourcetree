import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path_utils;
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

  /// 中文：确认并移除选中的未跟踪文件；不会删除已跟踪改动。
  /// English: Confirms and removes selected untracked files only.
  Future<void> _removeUntrackedChanges(
    List<RepositoryChangeViewData> changes,
  ) async {
    final root = ref.read(repositorySessionProvider).repository?.workTreeRoot;
    if (root == null ||
        changes.isEmpty ||
        changes.any(
          (change) => change.kind != RepositoryChangeKind.untracked,
        )) {
      return;
    }
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除未跟踪文件'),
        content: Text('确定要移除选中的 ${changes.length} 个未跟踪文件吗？此操作无法通过 Git 恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;

    // Re-read Git status after the confirmation. The list may have become
    // stale while the dialog was open; never delete a path whose current
    // status is no longer untracked.
    await ref.read(repositorySessionProvider.notifier).refresh();
    if (!mounted) return;
    final refreshed = ref.read(repositorySessionProvider);
    final refreshedRoot = refreshed.repository?.workTreeRoot;
    final status = refreshed.status;
    if (refreshedRoot != root || status == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('仓库状态已变化，请刷新后重试。')));
      return;
    }
    final currentUntrackedPaths = <String>{
      for (final entry in status.entries)
        if (entry.kind == GitFileStatusKind.untracked && entry.path.isValidUtf8)
          entry.path.display,
    };
    if (changes.any((change) => !currentUntrackedPaths.contains(change.path))) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('选中的文件状态已变化，请刷新后重试。')));
      return;
    }

    var removed = 0;
    var failed = 0;
    for (final change in changes) {
      final filePath = _workspaceChangePath(root, change.path);
      if (filePath == null) continue;
      try {
        final entityType = await FileSystemEntity.type(
          filePath,
          followLinks: false,
        );
        if (entityType == FileSystemEntityType.notFound) continue;
        if (entityType == FileSystemEntityType.directory) {
          await Directory(filePath).delete(recursive: true);
        } else {
          await File(filePath).delete();
        }
        removed++;
      } on Object {
        failed++;
      }
    }
    await ref.read(repositorySessionProvider.notifier).refresh();
    if (!mounted) return;
    final message = failed == 0
        ? '已移除 $removed 个未跟踪文件或目录。'
        : '已移除 $removed 个项目，$failed 个项目删除失败。';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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
                onCommitSelected: (commit) =>
                    unawaited(controller.selectCommit(commit.oid)),
                onCommitActivated: (commit) =>
                    unawaited(_confirmCheckoutCommit(commit)),
                onCommitContextAction: (commit, action) =>
                    unawaited(_handleCommitContextAction(commit, action)),
                onUncommittedChangesSelected:
                    controller.selectUncommittedChanges,
                onCommitFileSelected: (file) =>
                    unawaited(controller.selectCommitFile(file)),
                onChangeSelected: controller.selectChange,
                onChangeStageToggled: controller.toggleStage,
                onChangeGroupStageToggled: (changes, stage) =>
                    controller.toggleStageGroup(changes, stage: stage),
                onConflictAction: (change, action) =>
                    unawaited(_handleConflictAction(change, action)),
                onChangeRevealInFinder: (changes) =>
                    unawaited(_revealChangesInFinder(changes)),
                onChangeRemove: (changes) =>
                    unawaited(_removeUntrackedChanges(changes)),
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
