import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../git/git.dart';
import '../presentation/presentation.dart';
import 'git_askpass_prompt_coordinator.dart';
import 'repository_session.dart';
import 'repository_view_mapper.dart';

class GitDesktopApp extends StatelessWidget {
  const GitDesktopApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Git Desktop',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: const RepositoryWorkspaceScreen(),
    );
  }
}

ThemeData _theme(Brightness brightness) {
  final colors = ColorScheme.fromSeed(
    seedColor: const Color(0xFF2767D8),
    brightness: brightness,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: colors,
    visualDensity: VisualDensity.compact,
    scaffoldBackgroundColor: colors.surface,
    dividerTheme: DividerThemeData(color: colors.outlineVariant, thickness: 1),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 650),
    ),
  );
}

class RepositoryWorkspaceScreen extends ConsumerStatefulWidget {
  const RepositoryWorkspaceScreen({super.key});

  @override
  ConsumerState<RepositoryWorkspaceScreen> createState() =>
      _RepositoryWorkspaceScreenState();
}

class _RepositoryWorkspaceScreenState
    extends ConsumerState<RepositoryWorkspaceScreen> {
  bool _isAskPassDialogVisible = false;

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

  Future<void> _openRepository() async {
    final directory = await getDirectoryPath(confirmButtonText: '打开仓库');
    if (directory == null || !mounted) return;
    await ref
        .read(repositorySessionProvider.notifier)
        .openRepository(directory);
  }

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
    }
  }

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

  String _operationName(RepositoryOperationKind kind) => switch (kind) {
    RepositoryOperationKind.clone => '克隆仓库',
    RepositoryOperationKind.fetch => '获取远端更新',
    RepositoryOperationKind.pull => '快速前进拉取',
    RepositoryOperationKind.push => '推送当前分支',
  };

  String _operationSummary(RepositoryOperationOutcome outcome) =>
      switch (outcome) {
        RepositoryOperationOutcome.running => '正在运行',
        RepositoryOperationOutcome.succeeded => '已完成',
        RepositoryOperationOutcome.cancelled => '已取消；请检查仓库状态。',
        RepositoryOperationOutcome.failed => '未完成',
      };

  IconData _operationIcon(RepositoryOperationOutcome outcome) =>
      switch (outcome) {
        RepositoryOperationOutcome.running => Icons.sync,
        RepositoryOperationOutcome.succeeded => Icons.check_circle_outline,
        RepositoryOperationOutcome.cancelled => Icons.cancel_outlined,
        RepositoryOperationOutcome.failed => Icons.error_outline,
      };

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

  String _twoDigits(int value) => value.toString().padLeft(2, '0');

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

  void _handleReferenceSelected(RepositoryRefViewData reference) {
    if (reference.kind != RepositoryRefKind.localBranch ||
        reference.isCurrent) {
      return;
    }
    _confirmSwitchBranch(reference.label);
  }

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
    final session = ref.watch(repositorySessionProvider);
    final controller = ref.read(repositorySessionProvider.notifier);
    return Scaffold(
      body: RepositoryOverview(
        data: mapRepositoryOverview(session),
        callbacks: RepositoryOverviewCallbacks(
          onAction: _handleAction,
          onRefSelected: _handleReferenceSelected,
          onSearchChanged: controller.setSearchQuery,
          onCommitSelected: (commit) => controller.selectCommit(commit.oid),
          onChangeSelected: controller.selectChange,
          onChangeStageToggled: controller.toggleStage,
        ),
      ),
    );
  }
}

class _CommitDialog extends StatefulWidget {
  const _CommitDialog();

  @override
  State<_CommitDialog> createState() => _CommitDialogState();
}

class _CloneDialog extends StatefulWidget {
  const _CloneDialog();

  @override
  State<_CloneDialog> createState() => _CloneDialogState();
}

class _CloneDialogState extends State<_CloneDialog> {
  final _formKey = GlobalKey<FormState>();
  final _urlController = TextEditingController();

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState?.validate() ?? false) {
      Navigator.of(context).pop(_urlController.text);
    }
  }

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
  const _CreateBranchDialog();

  @override
  State<_CreateBranchDialog> createState() => _CreateBranchDialogState();
}

class _CreateBranchDialogState extends State<_CreateBranchDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    Navigator.of(context).pop(_nameController.text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('创建本地分支'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Form(
          key: _formKey,
          child: TextFormField(
            controller: _nameController,
            autofocus: true,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: '例如 feature/new-workflow',
              labelText: '分支名称',
              helperText: '分支将从当前 HEAD 创建，不会切换工作区。',
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

class _CommitDialogState extends State<_CommitDialog> {
  final _formKey = GlobalKey<FormState>();
  final _messageController = TextEditingController();

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    Navigator.of(context).pop(_messageController.text);
  }

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
