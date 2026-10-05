part of 'repository_overview.dart';

class _SelectedChangesPane extends StatelessWidget {
  const _SelectedChangesPane({
    required this.repository,
    required this.onSelected,
    required this.onSelectionChanged,
    required this.onStageToggled,
    required this.onGroupStageToggled,
    required this.onConflictAction,
    required this.onRevealInFinder,
    required this.onOpenTerminal,
    required this.onQuickLook,
    required this.onViewFileHistory,
    required this.onBlame,
    required this.onReview,
    required this.onIgnore,
    required this.onExternalDiff,
    required this.onCreatePatch,
    required this.onApplyPatch,
    required this.onRemove,
    required this.onStopTracking,
    required this.onReset,
    required this.onHunkAction,
    this.onDiffWhitespaceModeChanged,
    required this.onCommitFileSelected,
    required this.onCommitFileContextAction,
  });

  final RepositoryViewData repository;
  final RepositoryChangeCallback? onSelected;
  final ValueChanged<List<RepositoryChangeViewData>>? onSelectionChanged;
  final RepositoryChangeStageCallback? onStageToggled;
  final RepositoryChangeGroupStageCallback? onGroupStageToggled;
  final RepositoryConflictActionCallback? onConflictAction;
  final RepositoryChangeFilesCallback? onRevealInFinder;
  final RepositoryChangeFilesCallback? onOpenTerminal;
  final RepositoryChangeFilesCallback? onQuickLook;
  final RepositoryChangeFilesCallback? onViewFileHistory;
  final RepositoryChangeFilesCallback? onBlame;
  final RepositoryChangeFilesCallback? onReview;
  final RepositoryChangeFilesCallback? onIgnore;
  final RepositoryChangeFilesCallback? onExternalDiff;
  final RepositoryChangeFilesCallback? onCreatePatch;
  final VoidCallback? onApplyPatch;
  final RepositoryChangeFilesCallback? onRemove;
  final RepositoryChangeFilesCallback? onStopTracking;
  final RepositoryChangeFilesCallback? onReset;
  final RepositoryDiffHunkActionCallback? onHunkAction;
  final RepositoryDiffWhitespaceModeCallback? onDiffWhitespaceModeChanged;
  final RepositoryCommitFileCallback? onCommitFileSelected;
  final RepositoryCommitFileContextActionCallback? onCommitFileContextAction;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    if (repository.selectedCommit != null) {
      return _CommitChangesPane(
        repository: repository,
        onSelected: onCommitFileSelected,
        onContextAction: onCommitFileContextAction,
        onHunkAction: onHunkAction,
        onDiffWhitespaceModeChanged: onDiffWhitespaceModeChanged,
      );
    }
    return _ChangesPane(
      repository: repository,
      onSelected: onSelected,
      onSelectionChanged: onSelectionChanged,
      onStageToggled: onStageToggled,
      onGroupStageToggled: onGroupStageToggled,
      onConflictAction: onConflictAction,
      onRevealInFinder: onRevealInFinder,
      onOpenTerminal: onOpenTerminal,
      onQuickLook: onQuickLook,
      onViewFileHistory: onViewFileHistory,
      onBlame: onBlame,
      onReview: onReview,
      onIgnore: onIgnore,
      onExternalDiff: onExternalDiff,
      onCreatePatch: onCreatePatch,
      onApplyPatch: onApplyPatch,
      onRemove: onRemove,
      onStopTracking: onStopTracking,
      onReset: onReset,
      onHunkAction: onHunkAction,
      onDiffWhitespaceModeChanged: onDiffWhitespaceModeChanged,
    );
  }
}

/// Reuses the workspace's selected-commit file list, Diff preview and
/// context-menu callback.
///
/// 中文：复用工作区中所选提交的文件列表、Diff 预览和右键菜单回调；回调为空时
/// 仍展示菜单结构，但不会执行文件操作。
class RepositoryCommitChangesPane extends StatelessWidget {
  const RepositoryCommitChangesPane({
    super.key,
    required this.repository,
    required this.onSelected,
    this.onContextAction,
    this.onHunkAction,
    this.onDiffWhitespaceModeChanged,
    this.title = '提交改动',
  });

  final RepositoryViewData repository;
  final RepositoryCommitFileCallback? onSelected;
  final RepositoryCommitFileContextActionCallback? onContextAction;
  final RepositoryDiffHunkActionCallback? onHunkAction;
  final RepositoryDiffWhitespaceModeCallback? onDiffWhitespaceModeChanged;
  final String title;

  @override
  Widget build(BuildContext context) => _CommitChangesPane(
    repository: repository,
    onSelected: onSelected,
    onContextAction: onContextAction,
    onHunkAction: onHunkAction,
    onDiffWhitespaceModeChanged: onDiffWhitespaceModeChanged,
    title: title,
  );
}

class _CommitChangesPane extends StatefulWidget {
  const _CommitChangesPane({
    required this.repository,
    required this.onSelected,
    this.onContextAction,
    this.onHunkAction,
    this.onDiffWhitespaceModeChanged,
    this.title = '提交改动',
  });

  final RepositoryViewData repository;
  final RepositoryCommitFileCallback? onSelected;
  final RepositoryCommitFileContextActionCallback? onContextAction;
  final RepositoryDiffHunkActionCallback? onHunkAction;
  final RepositoryDiffWhitespaceModeCallback? onDiffWhitespaceModeChanged;
  final String title;

  @override
  State<_CommitChangesPane> createState() => _CommitChangesPaneState();
}

class _CommitChangesPaneState extends State<_CommitChangesPane> {
  double? _fileListWidth;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final repository = widget.repository;
    final files = repository.commitChanges;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          _PaneHeader(
            title: widget.title,
            icon: Icons.difference_outlined,
            trailing: repository.isCommitLoading
                ? '正在读取…'
                : '${files.length} 个文件',
          ),
          Expanded(
            child: repository.isCommitLoading && files.isEmpty
                ? const Center(child: CircularProgressIndicator.adaptive())
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final list = _CommitFileList(
                        files: files,
                        onSelected: widget.onSelected,
                        onContextAction: widget.onContextAction,
                        canResetToCommit: !repository.blocksRepositoryMutations,
                      );
                      if (constraints.maxWidth < 530) {
                        return repository.selectedCommitFile == null
                            ? list
                            : _DiffPreview(
                                diff: repository.commitDiff,
                                onHunkAction: widget.onHunkAction,
                                onDiffWhitespaceModeChanged:
                                    widget.onDiffWhitespaceModeChanged,
                                onBack: widget.onSelected == null
                                    ? null
                                    : () => widget.onSelected!(null),
                              );
                      }
                      final defaultWidth = math.min(
                        286.0,
                        constraints.maxWidth * .38,
                      );
                      final maximumWidth = math.max(
                        180.0,
                        constraints.maxWidth - 300,
                      );
                      final fileListWidth = (_fileListWidth ?? defaultWidth)
                          .clamp(180.0, maximumWidth)
                          .toDouble();
                      return Row(
                        children: [
                          SizedBox(width: fileListWidth, child: list),
                          _ResizeDivider(
                            axis: Axis.vertical,
                            semanticsLabel: '调整提交文件列表宽度',
                            onDelta: (delta) => setState(() {
                              _fileListWidth = fileListWidth + delta;
                            }),
                          ),
                          Expanded(
                            child: _DiffPreview(
                              diff: repository.commitDiff,
                              onHunkAction: widget.onHunkAction,
                              onDiffWhitespaceModeChanged:
                                  widget.onDiffWhitespaceModeChanged,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _CommitFileList extends StatelessWidget {
  const _CommitFileList({
    required this.files,
    required this.onSelected,
    required this.onContextAction,
    required this.canResetToCommit,
  });

  final List<CommitFileViewData> files;
  final RepositoryCommitFileCallback? onSelected;
  final RepositoryCommitFileContextActionCallback? onContextAction;
  final bool canResetToCommit;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    if (files.isEmpty) {
      return const _PaneEmptyState(
        icon: Icons.check_circle_outline,
        title: '没有文件改动',
        message: '此提交没有可显示的文件差异。',
      );
    }
    return ListView.builder(
      itemExtent: _scaledDenseHeight(context, 34),
      itemCount: files.length,
      itemBuilder: (context, index) => _CommitFileTile(
        file: files[index],
        onTap: onSelected == null ? null : () => onSelected!(files[index]),
        onContextAction: onContextAction,
        canResetToCommit: canResetToCommit,
      ),
    );
  }
}

class _CommitFileTile extends StatelessWidget {
  const _CommitFileTile({
    required this.file,
    required this.onTap,
    required this.onContextAction,
    required this.canResetToCommit,
  });

  final CommitFileViewData file;
  final VoidCallback? onTap;
  final RepositoryCommitFileContextActionCallback? onContextAction;
  final bool canResetToCommit;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final fileName = file.path.split('/').last;
    final slash = file.path.lastIndexOf('/');
    final parentPath = slash <= 0 ? '' : file.path.substring(0, slash);
    final stats = [
      if (file.additions case final int value) '+$value',
      if (file.deletions case final int value) '−$value',
    ].join(' ');
    final supportsResetToCommit =
        file.isPathValidUtf8 &&
        switch (file.kind) {
          RepositoryChangeKind.added ||
          RepositoryChangeKind.modified ||
          RepositoryChangeKind.deleted => true,
          _ => false,
        };
    final supportsExternalDiff =
        file.isPathValidUtf8 &&
        switch (file.kind) {
          RepositoryChangeKind.added ||
          RepositoryChangeKind.modified ||
          RepositoryChangeKind.deleted ||
          RepositoryChangeKind.renamed ||
          RepositoryChangeKind.copied => true,
          _ => false,
        };
    void invoke(RepositoryCommitFileContextAction action) =>
        onContextAction?.call(file, action);
    return MenuAnchor(
      consumeOutsideTap: true,
      useRootOverlay: true,
      menuChildren: [
        _commitFileContextMenuItem(
          file.isPathValidUtf8 ? '查看选中的修改日志…' : '查看选中的修改日志…（待实现）',
          RepositoryCommitFileContextAction.viewSelectedFileLog,
          invoke,
          enabled: file.isPathValidUtf8,
        ),
        _commitFileContextMenuItem(
          file.isPathValidUtf8 && file.kind != RepositoryChangeKind.deleted
              ? 'Blame'
              : 'Blame（待实现）',
          RepositoryCommitFileContextAction.blame,
          invoke,
          enabled:
              file.isPathValidUtf8 && file.kind != RepositoryChangeKind.deleted,
        ),
        _commitFileContextMenuItem(
          file.isPathValidUtf8 ? '审查选定的项目' : '审查选定的项目（待实现）',
          RepositoryCommitFileContextAction.reviewSelectedItem,
          invoke,
          enabled: file.isPathValidUtf8,
        ),
        _commitFileContextMenuItem(
          supportsResetToCommit ? '重置到提交…' : '重置到提交…（待实现）',
          RepositoryCommitFileContextAction.resetToCommit,
          invoke,
          enabled: supportsResetToCommit && canResetToCommit,
        ),
        const Divider(height: 1),
        _commitFileContextMenuItem(
          file.isPathValidUtf8 ? '打开当前版本' : '打开当前版本（待实现）',
          RepositoryCommitFileContextAction.openCurrentVersion,
          invoke,
          enabled: file.isPathValidUtf8,
        ),
        _commitFileContextMenuItem(
          file.isPathValidUtf8 && file.kind != RepositoryChangeKind.deleted
              ? '打开已选定版本'
              : '打开已选定版本（待实现）',
          RepositoryCommitFileContextAction.openSelectedVersion,
          invoke,
          enabled:
              file.isPathValidUtf8 && file.kind != RepositoryChangeKind.deleted,
        ),
        _commitFileContextMenuItem(
          file.isPathValidUtf8 ? '在 Finder 中显示' : '在 Finder 中显示（待实现）',
          RepositoryCommitFileContextAction.revealInFinder,
          invoke,
          enabled: file.isPathValidUtf8,
        ),
        _commitFileContextMenuItem(
          file.isPathValidUtf8 ? '复制路径到剪贴板' : '复制路径到剪贴板（待实现）',
          RepositoryCommitFileContextAction.copyPath,
          invoke,
          enabled: file.isPathValidUtf8,
        ),
        _commitFileContextMenuItem(
          file.isPathValidUtf8 ? '快速查看' : '快速查看（待实现）',
          RepositoryCommitFileContextAction.quickLook,
          invoke,
          enabled: file.isPathValidUtf8,
        ),
        const Divider(height: 1),
        _commitFileContextMenuItem(
          supportsExternalDiff ? '外部差异比对' : '外部差异比对（待实现）',
          RepositoryCommitFileContextAction.externalDiff,
          invoke,
          enabled: supportsExternalDiff,
        ),
        SubmenuButton(
          menuChildren: const [
            MenuItemButton(onPressed: null, child: Text('暂无可用操作（待实现）')),
          ],
          child: const Text('自定义操作（待实现）'),
        ),
      ],
      builder: (context, controller, child) => CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.f10, shift: true): () {
            onTap?.call();
            controller.open();
          },
          const SingleActivator(LogicalKeyboardKey.contextMenu): () {
            onTap?.call();
            controller.open();
          },
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onSecondaryTapDown: (details) {
            onTap?.call();
            controller.open(position: details.localPosition);
          },
          child: child,
        ),
      ),
      child: Semantics(
        button: true,
        selected: file.isSelected,
        label: '${_changeKindLabel(file.kind)}，${file.path}',
        child: Tooltip(
          message: file.path,
          waitDuration: const Duration(milliseconds: 650),
          child: InkWell(
            onTap: onTap,
            child: Container(
              color: file.isSelected ? colors.secondaryContainer : null,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  _ChangeStatusBadge(kind: file.kind),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            fileName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        if (parentPath.isNotEmpty) ...[
                          const SizedBox(width: 5),
                          Flexible(
                            child: Text(
                              parentPath,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(color: colors.onSurfaceVariant),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (stats.isNotEmpty)
                    Text(
                      stats,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: colors.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Builds one labelled action in the historical-file context menu.
///
/// 中文：构建历史文件右键菜单中的一个动作；视图层仅传递选择，具体业务操作
/// 始终由应用层处理。
MenuItemButton _commitFileContextMenuItem(
  String label,
  RepositoryCommitFileContextAction action,
  ValueChanged<RepositoryCommitFileContextAction> onPressed, {
  bool enabled = true,
}) => MenuItemButton(
  onPressed: enabled ? () => onPressed(action) : null,
  child: Text(label),
);

class _ChangesPane extends StatefulWidget {
  const _ChangesPane({
    required this.repository,
    required this.onSelected,
    required this.onSelectionChanged,
    required this.onStageToggled,
    required this.onGroupStageToggled,
    required this.onConflictAction,
    required this.onRevealInFinder,
    required this.onOpenTerminal,
    required this.onQuickLook,
    required this.onViewFileHistory,
    required this.onBlame,
    required this.onReview,
    required this.onIgnore,
    required this.onExternalDiff,
    required this.onCreatePatch,
    required this.onApplyPatch,
    required this.onRemove,
    required this.onStopTracking,
    required this.onReset,
    required this.onHunkAction,
    this.onDiffWhitespaceModeChanged,
  });

  final RepositoryViewData repository;
  final RepositoryChangeCallback? onSelected;
  final ValueChanged<List<RepositoryChangeViewData>>? onSelectionChanged;
  final RepositoryChangeStageCallback? onStageToggled;
  final RepositoryChangeGroupStageCallback? onGroupStageToggled;
  final RepositoryConflictActionCallback? onConflictAction;
  final RepositoryChangeFilesCallback? onRevealInFinder;
  final RepositoryChangeFilesCallback? onOpenTerminal;
  final RepositoryChangeFilesCallback? onQuickLook;
  final RepositoryChangeFilesCallback? onViewFileHistory;
  final RepositoryChangeFilesCallback? onBlame;
  final RepositoryChangeFilesCallback? onReview;
  final RepositoryChangeFilesCallback? onIgnore;
  final RepositoryChangeFilesCallback? onExternalDiff;
  final RepositoryChangeFilesCallback? onCreatePatch;
  final VoidCallback? onApplyPatch;
  final RepositoryChangeFilesCallback? onRemove;
  final RepositoryChangeFilesCallback? onStopTracking;
  final RepositoryChangeFilesCallback? onReset;
  final RepositoryDiffHunkActionCallback? onHunkAction;
  final RepositoryDiffWhitespaceModeCallback? onDiffWhitespaceModeChanged;

  @override
  State<_ChangesPane> createState() => _ChangesPaneState();
}

class _ChangesPaneState extends State<_ChangesPane> {
  double? _fileListWidth;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final repository = widget.repository;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          _PaneHeader(
            title: '文件状态',
            icon: Icons.difference_outlined,
            isBusy: repository.isWorkingTreeBusy,
            trailing:
                '${repository.stagedChangeCount} 已暂存 · ${repository.unstagedChangeCount} 未暂存',
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                if (constraints.maxWidth < 530) {
                  return repository.selectedChange == null
                      ? _ChangeList(
                          changes: repository.changes,
                          isWorkingTreeBusy: repository.isWorkingTreeBusy,
                          ordinaryMutationsEnabled:
                              !repository.blocksRepositoryMutations,
                          conflictActionsEnabled:
                              !repository.hasRunningRepositoryTask,
                          onSelected: widget.onSelected,
                          onSelectionChanged: widget.onSelectionChanged,
                          onStageToggled: widget.onStageToggled,
                          onGroupStageToggled: widget.onGroupStageToggled,
                          onConflictAction: widget.onConflictAction,
                          onRevealInFinder: widget.onRevealInFinder,
                          onOpenTerminal: widget.onOpenTerminal,
                          onQuickLook: widget.onQuickLook,
                          onViewFileHistory: widget.onViewFileHistory,
                          onBlame: widget.onBlame,
                          onReview: widget.onReview,
                          onIgnore: widget.onIgnore,
                          onExternalDiff: widget.onExternalDiff,
                          onCreatePatch: widget.onCreatePatch,
                          onApplyPatch: widget.onApplyPatch,
                          onRemove: widget.onRemove,
                          onStopTracking: widget.onStopTracking,
                          onReset: widget.onReset,
                        )
                      : _DiffPreview(
                          diff: repository.diff,
                          onDiffWhitespaceModeChanged:
                              widget.onDiffWhitespaceModeChanged,
                          onHunkAction: repository.blocksRepositoryMutations
                              ? null
                              : widget.onHunkAction,
                          onBack: widget.onSelected == null
                              ? null
                              : () => widget.onSelected!(null),
                        );
                }
                final defaultWidth = math.min(
                  286.0,
                  constraints.maxWidth * .38,
                );
                final maximumWidth = math.max(
                  180.0,
                  constraints.maxWidth - 300,
                );
                final fileListWidth = (_fileListWidth ?? defaultWidth)
                    .clamp(180.0, maximumWidth)
                    .toDouble();
                return Row(
                  children: [
                    SizedBox(
                      width: fileListWidth,
                      child: _ChangeList(
                        changes: repository.changes,
                        isWorkingTreeBusy: repository.isWorkingTreeBusy,
                        ordinaryMutationsEnabled:
                            !repository.blocksRepositoryMutations,
                        conflictActionsEnabled:
                            !repository.hasRunningRepositoryTask,
                        onSelected: widget.onSelected,
                        onSelectionChanged: widget.onSelectionChanged,
                        onStageToggled: widget.onStageToggled,
                        onGroupStageToggled: widget.onGroupStageToggled,
                        onConflictAction: widget.onConflictAction,
                        onRevealInFinder: widget.onRevealInFinder,
                        onOpenTerminal: widget.onOpenTerminal,
                        onQuickLook: widget.onQuickLook,
                        onViewFileHistory: widget.onViewFileHistory,
                        onBlame: widget.onBlame,
                        onReview: widget.onReview,
                        onIgnore: widget.onIgnore,
                        onExternalDiff: widget.onExternalDiff,
                        onCreatePatch: widget.onCreatePatch,
                        onApplyPatch: widget.onApplyPatch,
                        onRemove: widget.onRemove,
                        onStopTracking: widget.onStopTracking,
                        onReset: widget.onReset,
                      ),
                    ),
                    _ResizeDivider(
                      axis: Axis.vertical,
                      semanticsLabel: '调整文件列表宽度',
                      onDelta: (delta) => setState(() {
                        _fileListWidth = fileListWidth + delta;
                      }),
                    ),
                    Expanded(
                      child: _DiffPreview(
                        diff: repository.diff,
                        onDiffWhitespaceModeChanged:
                            widget.onDiffWhitespaceModeChanged,
                        onHunkAction: repository.blocksRepositoryMutations
                            ? null
                            : widget.onHunkAction,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Full workspace surface used when the file-status ref is selected.
///
/// 中文：文件状态选中时使用的完整工作区界面，保留文件操作与 Diff，并提供
/// 不直接执行 Git 的提交入口。
class _WorkspaceChangesView extends StatelessWidget {
  const _WorkspaceChangesView({
    required this.repository,
    required this.onSelected,
    required this.onSelectionChanged,
    required this.onStageToggled,
    required this.onGroupStageToggled,
    required this.onConflictAction,
    required this.onRevealInFinder,
    required this.onOpenTerminal,
    required this.onQuickLook,
    required this.onViewFileHistory,
    required this.onBlame,
    required this.onReview,
    required this.onIgnore,
    required this.onExternalDiff,
    required this.onCreatePatch,
    required this.onApplyPatch,
    required this.onRemove,
    required this.onStopTracking,
    required this.onReset,
    required this.onHunkAction,
    this.onDiffWhitespaceModeChanged,
    required this.onCommit,
  });

  final RepositoryViewData repository;
  final RepositoryChangeCallback? onSelected;
  final ValueChanged<List<RepositoryChangeViewData>>? onSelectionChanged;
  final RepositoryChangeStageCallback? onStageToggled;
  final RepositoryChangeGroupStageCallback? onGroupStageToggled;
  final RepositoryConflictActionCallback? onConflictAction;
  final RepositoryChangeFilesCallback? onRevealInFinder;
  final RepositoryChangeFilesCallback? onOpenTerminal;
  final RepositoryChangeFilesCallback? onQuickLook;
  final RepositoryChangeFilesCallback? onViewFileHistory;
  final RepositoryChangeFilesCallback? onBlame;
  final RepositoryChangeFilesCallback? onReview;
  final RepositoryChangeFilesCallback? onIgnore;
  final RepositoryChangeFilesCallback? onExternalDiff;
  final RepositoryChangeFilesCallback? onCreatePatch;
  final VoidCallback? onApplyPatch;
  final RepositoryChangeFilesCallback? onRemove;
  final RepositoryChangeFilesCallback? onStopTracking;
  final RepositoryChangeFilesCallback? onReset;
  final RepositoryDiffHunkActionCallback? onHunkAction;
  final RepositoryDiffWhitespaceModeCallback? onDiffWhitespaceModeChanged;
  final VoidCallback? onCommit;

  /// 中文：构建工作区文件、Diff 和提交信息入口。
  /// English: Builds the working-tree files, Diff, and commit-message entry.
  @override
  Widget build(BuildContext context) {
    final canCommit =
        onCommit != null &&
        !repository.disabledActions.contains(RepositoryAction.commit);
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        Expanded(
          child: _ChangesPane(
            repository: repository,
            onSelected: onSelected,
            onSelectionChanged: onSelectionChanged,
            onStageToggled: onStageToggled,
            onGroupStageToggled: onGroupStageToggled,
            onConflictAction: onConflictAction,
            onRevealInFinder: onRevealInFinder,
            onOpenTerminal: onOpenTerminal,
            onQuickLook: onQuickLook,
            onViewFileHistory: onViewFileHistory,
            onBlame: onBlame,
            onReview: onReview,
            onIgnore: onIgnore,
            onExternalDiff: onExternalDiff,
            onCreatePatch: onCreatePatch,
            onApplyPatch: onApplyPatch,
            onRemove: onRemove,
            onStopTracking: onStopTracking,
            onReset: onReset,
            onHunkAction: onHunkAction,
            onDiffWhitespaceModeChanged: onDiffWhitespaceModeChanged,
          ),
        ),
        Material(
          color: colors.surfaceContainerLow,
          child: Container(
            height: 52,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: colors.outlineVariant)),
            ),
            child: Semantics(
              button: true,
              enabled: canCommit,
              label: '打开提交面板',
              child: TextField(
                readOnly: true,
                enabled: canCommit,
                onTap: onCommit,
                decoration: const InputDecoration(
                  hintText: '提交信息',
                  prefixIcon: Icon(Icons.person_outline, size: 19),
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ChangeList extends StatefulWidget {
  const _ChangeList({
    required this.changes,
    required this.isWorkingTreeBusy,
    required this.ordinaryMutationsEnabled,
    required this.conflictActionsEnabled,
    required this.onSelected,
    required this.onSelectionChanged,
    required this.onStageToggled,
    required this.onGroupStageToggled,
    required this.onConflictAction,
    required this.onRevealInFinder,
    required this.onOpenTerminal,
    required this.onQuickLook,
    required this.onViewFileHistory,
    required this.onBlame,
    required this.onReview,
    required this.onIgnore,
    required this.onExternalDiff,
    required this.onCreatePatch,
    required this.onApplyPatch,
    required this.onRemove,
    required this.onStopTracking,
    required this.onReset,
  });

  final List<RepositoryChangeViewData> changes;
  final bool isWorkingTreeBusy;
  final bool ordinaryMutationsEnabled;
  final bool conflictActionsEnabled;
  final RepositoryChangeCallback? onSelected;
  final ValueChanged<List<RepositoryChangeViewData>>? onSelectionChanged;
  final RepositoryChangeStageCallback? onStageToggled;
  final RepositoryChangeGroupStageCallback? onGroupStageToggled;
  final RepositoryConflictActionCallback? onConflictAction;
  final RepositoryChangeFilesCallback? onRevealInFinder;
  final RepositoryChangeFilesCallback? onOpenTerminal;
  final RepositoryChangeFilesCallback? onQuickLook;
  final RepositoryChangeFilesCallback? onViewFileHistory;
  final RepositoryChangeFilesCallback? onBlame;
  final RepositoryChangeFilesCallback? onReview;
  final RepositoryChangeFilesCallback? onIgnore;
  final RepositoryChangeFilesCallback? onExternalDiff;
  final RepositoryChangeFilesCallback? onCreatePatch;
  final VoidCallback? onApplyPatch;
  final RepositoryChangeFilesCallback? onRemove;
  final RepositoryChangeFilesCallback? onStopTracking;
  final RepositoryChangeFilesCallback? onReset;

  @override
  State<_ChangeList> createState() => _ChangeListState();
}

class _ChangeListState extends State<_ChangeList> {
  final Set<String> _selectedKeys = <String>{};
  double? _stagedHeight;

  @override
  void initState() {
    super.initState();
    _syncModelSelection();
    _notifySelectionAfterFrame();
  }

  @override
  void didUpdateWidget(_ChangeList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final available = widget.changes.map(_changeSelectionKey).toSet();
    _selectedKeys.removeWhere((key) => !available.contains(key));
    final previousModelSelection = oldWidget.changes
        .where((change) => change.isSelected)
        .map(_changeSelectionKey)
        .toSet();
    final modelSelection = widget.changes
        .where((change) => change.isSelected)
        .map(_changeSelectionKey)
        .toSet();
    if (!previousModelSelection.containsAll(modelSelection) ||
        !modelSelection.containsAll(previousModelSelection)) {
      _selectedKeys
        ..clear()
        ..addAll(modelSelection);
    }
    _notifySelectionAfterFrame();
  }

  /// Publishes the effective local multi-selection after the current build.
  /// 中文：当前构建完成后发布文件列表的实际局部多选，供窗口级菜单状态使用。
  void _notifySelectionAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onSelectionChanged?.call(_selectedChanges);
    });
  }

  void _syncModelSelection() {
    _selectedKeys.addAll(
      widget.changes
          .where((change) => change.isSelected)
          .map(_changeSelectionKey),
    );
  }

  List<RepositoryChangeViewData> get _selectedChanges => [
    for (final change in widget.changes)
      if (_selectedKeys.contains(_changeSelectionKey(change))) change,
  ];

  void _selectChange(RepositoryChangeViewData change) {
    final key = _changeSelectionKey(change);
    if (!HardwareKeyboard.instance.isMetaPressed) {
      setState(() {
        _selectedKeys
          ..clear()
          ..add(key);
      });
      widget.onSelected?.call(change);
      widget.onSelectionChanged?.call(_selectedChanges);
      return;
    }

    setState(() {
      if (!_selectedKeys.add(key)) _selectedKeys.remove(key);
    });
    final selected = _selectedChanges;
    widget.onSelected?.call(
      _selectedKeys.contains(key)
          ? change
          : selected.isEmpty
          ? null
          : selected.last,
    );
    widget.onSelectionChanged?.call(_selectedChanges);
  }

  void _prepareContextMenu(RepositoryChangeViewData change) {
    final key = _changeSelectionKey(change);
    if (!_selectedKeys.contains(key)) {
      setState(() {
        _selectedKeys
          ..clear()
          ..add(key);
      });
    }
    widget.onSelected?.call(change);
    widget.onSelectionChanged?.call(_selectedChanges);
  }

  void _toggleSelectedStage(bool stage) {
    if (!widget.ordinaryMutationsEnabled) return;
    final selected = _selectedChanges
        .where((change) => change.canToggleStage && change.isStaged != stage)
        .toList(growable: false);
    if (selected.isEmpty) return;
    final result = widget.onGroupStageToggled?.call(selected, stage);
    if (result is Future<void>) unawaited(result);
  }

  /// Builds one scrollable working-tree status group.
  /// 中文：构建一个可滚动的工作区状态分组，并复用当前选择与文件操作回调。
  Widget _buildChangeGroup({
    required String title,
    required bool isChecked,
    required List<RepositoryChangeViewData> changes,
  }) => _ChangeGroupViewport(
    child: _ChangeGroup(
      title: title,
      isChecked: isChecked,
      changes: changes,
      isWorkingTreeBusy: widget.isWorkingTreeBusy,
      ordinaryMutationsEnabled: widget.ordinaryMutationsEnabled,
      conflictActionsEnabled: widget.conflictActionsEnabled,
      selectedKeys: _selectedKeys,
      selectedChanges: () => _selectedChanges,
      onSelected: _selectChange,
      onContextMenuRequested: _prepareContextMenu,
      onSelectedStageToggled: _toggleSelectedStage,
      onStageToggled: widget.onStageToggled,
      onGroupStageToggled: widget.onGroupStageToggled,
      onConflictAction: widget.onConflictAction,
      onRevealInFinder: widget.onRevealInFinder,
      onOpenTerminal: widget.onOpenTerminal,
      onQuickLook: widget.onQuickLook,
      onViewFileHistory: widget.onViewFileHistory,
      onBlame: widget.onBlame,
      onReview: widget.onReview,
      onIgnore: widget.onIgnore,
      onExternalDiff: widget.onExternalDiff,
      onCreatePatch: widget.onCreatePatch,
      onApplyPatch: widget.onApplyPatch,
      onRemove: widget.onRemove,
      onStopTracking: widget.onStopTracking,
      onReset: widget.onReset,
    ),
  );

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    if (widget.changes.isEmpty) {
      return const _PaneEmptyState(
        icon: Icons.task_alt,
        title: '工作区干净',
        message: '没有需要提交的文件改动。',
      );
    }

    final staged = widget.changes.where((change) => change.isStaged).toList();
    final unstaged = widget.changes
        .where((change) => !change.isStaged)
        .toList();
    return LayoutBuilder(
      builder: (context, constraints) {
        const dividerHeight = 5.0;
        const minimumGroupHeight = 30.0;
        final availableHeight = constraints.maxHeight - dividerHeight;
        final maximumStagedHeight = math.max(
          minimumGroupHeight,
          availableHeight - minimumGroupHeight,
        );
        final defaultStagedHeight = staged.isEmpty
            ? math.min(136, maximumStagedHeight)
            : math.min(availableHeight * .42, maximumStagedHeight);
        final stagedHeight = (_stagedHeight ?? defaultStagedHeight)
            .clamp(minimumGroupHeight, maximumStagedHeight)
            .toDouble();
        return Column(
          children: [
            SizedBox(
              height: stagedHeight,
              child: _buildChangeGroup(
                title: '已暂存文件',
                isChecked: true,
                changes: staged,
              ),
            ),
            _ResizeDivider(
              axis: Axis.horizontal,
              semanticsLabel: '调整已暂存文件区域高度',
              onDelta: (delta) => setState(() {
                _stagedHeight = stagedHeight + delta;
              }),
            ),
            Expanded(
              child: _buildChangeGroup(
                title: '未暂存文件',
                isChecked: false,
                changes: unstaged,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ChangeGroupViewport extends StatelessWidget {
  const _ChangeGroupViewport({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRect(child: SingleChildScrollView(primary: false, child: child));
  }
}

class _ChangeGroup extends StatelessWidget {
  const _ChangeGroup({
    required this.title,
    required this.isChecked,
    required this.changes,
    required this.isWorkingTreeBusy,
    required this.ordinaryMutationsEnabled,
    required this.conflictActionsEnabled,
    required this.selectedKeys,
    required this.selectedChanges,
    required this.onSelected,
    required this.onContextMenuRequested,
    required this.onSelectedStageToggled,
    required this.onRevealInFinder,
    required this.onOpenTerminal,
    required this.onQuickLook,
    required this.onViewFileHistory,
    required this.onBlame,
    required this.onReview,
    required this.onIgnore,
    required this.onExternalDiff,
    required this.onCreatePatch,
    required this.onApplyPatch,
    required this.onRemove,
    required this.onStopTracking,
    required this.onReset,
    required this.onStageToggled,
    required this.onGroupStageToggled,
    required this.onConflictAction,
  });

  final String title;
  final bool isChecked;
  final List<RepositoryChangeViewData> changes;
  final bool isWorkingTreeBusy;
  final bool ordinaryMutationsEnabled;
  final bool conflictActionsEnabled;
  final Set<String> selectedKeys;
  final ValueGetter<List<RepositoryChangeViewData>> selectedChanges;
  final ValueChanged<RepositoryChangeViewData> onSelected;
  final ValueChanged<RepositoryChangeViewData> onContextMenuRequested;
  final ValueChanged<bool> onSelectedStageToggled;
  final RepositoryChangeFilesCallback? onRevealInFinder;
  final RepositoryChangeFilesCallback? onOpenTerminal;
  final RepositoryChangeFilesCallback? onQuickLook;
  final RepositoryChangeFilesCallback? onViewFileHistory;
  final RepositoryChangeFilesCallback? onBlame;
  final RepositoryChangeFilesCallback? onReview;
  final RepositoryChangeFilesCallback? onIgnore;
  final RepositoryChangeFilesCallback? onExternalDiff;
  final RepositoryChangeFilesCallback? onCreatePatch;
  final VoidCallback? onApplyPatch;
  final RepositoryChangeFilesCallback? onRemove;
  final RepositoryChangeFilesCallback? onStopTracking;
  final RepositoryChangeFilesCallback? onReset;
  final RepositoryChangeStageCallback? onStageToggled;
  final RepositoryChangeGroupStageCallback? onGroupStageToggled;
  final RepositoryConflictActionCallback? onConflictAction;

  /// 中文：将工作区文件按暂存状态分组，保持与桌面 Git 客户端一致的扫描顺序。
  /// English: Groups workspace files by staging state for a desktop Git-client
  /// scanning order.
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          key: ValueKey<String>(
            isChecked ? 'staged-files-header' : 'unstaged-files-header',
          ),
          height: _scaledDenseHeight(context, 30),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: colors.surfaceContainerLow,
            border: Border(
              top: BorderSide(color: colors.outlineVariant),
              bottom: BorderSide(color: colors.outlineVariant),
            ),
          ),
          child: Row(
            children: [
              Checkbox(
                value: isChecked && changes.isNotEmpty,
                onChanged:
                    onGroupStageToggled == null ||
                        !ordinaryMutationsEnabled ||
                        changes.isEmpty ||
                        changes.every((change) => !change.canToggleStage)
                    ? null
                    : (_) {
                        final result = onGroupStageToggled!(
                          changes,
                          !isChecked,
                        );
                        if (result is Future<void>) unawaited(result);
                      },
                visualDensity: const VisualDensity(
                  horizontal: -4,
                  vertical: -4,
                ),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                side: BorderSide(color: colors.onSurfaceVariant),
                fillColor: isWorkingTreeBusy && isChecked && changes.isNotEmpty
                    ? WidgetStatePropertyAll(colors.primary)
                    : null,
                checkColor: isWorkingTreeBusy ? colors.onPrimary : null,
              ),
              const SizedBox(width: 2),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '${changes.length}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
        for (final change in changes)
          SizedBox(
            height: _scaledDenseHeight(context, 34),
            child: _ChangeTile(
              change: change,
              isSelected: selectedKeys.contains(_changeSelectionKey(change)),
              selectedChanges: selectedChanges,
              onTap: () => onSelected(change),
              onContextMenuRequested: () => onContextMenuRequested(change),
              onSelectedStageToggled: onSelectedStageToggled,
              ordinaryMutationsEnabled: ordinaryMutationsEnabled,
              conflictActionsEnabled: conflictActionsEnabled,
              onRevealInFinder: onRevealInFinder,
              onOpenTerminal: onOpenTerminal,
              onQuickLook: onQuickLook,
              onViewFileHistory: onViewFileHistory,
              onBlame: onBlame,
              onReview: onReview,
              onIgnore: onIgnore,
              onExternalDiff: onExternalDiff,
              onCreatePatch: onCreatePatch,
              onApplyPatch: onApplyPatch,
              onRemove: onRemove,
              onStopTracking: onStopTracking,
              onReset: onReset,
              onStageToggled: onStageToggled == null
                  ? null
                  : () => onStageToggled!(change),
              onConflictAction: onConflictAction == null
                  ? null
                  : (action) => onConflictAction!(change, action),
            ),
          ),
      ],
    );
  }
}

class _ChangeTile extends StatelessWidget {
  const _ChangeTile({
    required this.change,
    required this.isSelected,
    required this.selectedChanges,
    required this.onTap,
    required this.onContextMenuRequested,
    required this.onSelectedStageToggled,
    required this.ordinaryMutationsEnabled,
    required this.conflictActionsEnabled,
    required this.onRevealInFinder,
    required this.onOpenTerminal,
    required this.onQuickLook,
    required this.onViewFileHistory,
    required this.onBlame,
    required this.onReview,
    required this.onIgnore,
    required this.onExternalDiff,
    required this.onCreatePatch,
    required this.onApplyPatch,
    required this.onRemove,
    required this.onStopTracking,
    required this.onReset,
    required this.onStageToggled,
    required this.onConflictAction,
  });

  final RepositoryChangeViewData change;
  final bool isSelected;
  final ValueGetter<List<RepositoryChangeViewData>> selectedChanges;
  final VoidCallback? onTap;
  final VoidCallback onContextMenuRequested;
  final ValueChanged<bool> onSelectedStageToggled;
  final bool ordinaryMutationsEnabled;
  final bool conflictActionsEnabled;
  final RepositoryChangeFilesCallback? onRevealInFinder;
  final RepositoryChangeFilesCallback? onOpenTerminal;
  final RepositoryChangeFilesCallback? onQuickLook;
  final RepositoryChangeFilesCallback? onViewFileHistory;
  final RepositoryChangeFilesCallback? onBlame;
  final RepositoryChangeFilesCallback? onReview;
  final RepositoryChangeFilesCallback? onIgnore;
  final RepositoryChangeFilesCallback? onExternalDiff;
  final RepositoryChangeFilesCallback? onCreatePatch;
  final VoidCallback? onApplyPatch;
  final RepositoryChangeFilesCallback? onRemove;
  final RepositoryChangeFilesCallback? onStopTracking;
  final RepositoryChangeFilesCallback? onReset;
  final VoidCallback? onStageToggled;
  final ValueChanged<RepositoryConflictAction>? onConflictAction;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    // A deferred action is unavailable unless every current selection supports
    // it; mixed selections must not expose a partially applicable write path.
    // 待实现写操作只有在所有当前选择均适用时才可开放，混合选择不能暴露部分适用的写入路径。
    bool canStopTracking() =>
        ordinaryMutationsEnabled &&
        onStopTracking != null &&
        selectedChanges().isNotEmpty &&
        selectedChanges().every((item) => item.canStopTracking);
    bool canReset() =>
        ordinaryMutationsEnabled &&
        onReset != null &&
        selectedChanges().isNotEmpty &&
        selectedChanges().every((item) => item.canResetToHead);
    bool canRemove() =>
        ordinaryMutationsEnabled &&
        onRemove != null &&
        selectedChanges().isNotEmpty &&
        selectedChanges().every(
          (item) => item.isActionEnabled && item.isPathValidUtf8,
        );
    bool hasUnsupportedRemovePath() =>
        selectedChanges().any((item) => !item.isPathValidUtf8);
    bool canUseReadOnlyFileActions() =>
        selectedChanges().isNotEmpty &&
        selectedChanges().every(
          (item) => item.isActionEnabled && item.isPathValidUtf8,
        );
    bool canOpenTerminal() =>
        onOpenTerminal != null &&
        selectedChanges().length == 1 &&
        canUseReadOnlyFileActions();
    bool canViewFileHistory() =>
        onViewFileHistory != null &&
        selectedChanges().length == 1 &&
        canUseReadOnlyFileActions() &&
        selectedChanges().single.kind != RepositoryChangeKind.untracked;
    bool canBlame() =>
        onBlame != null &&
        selectedChanges().length == 1 &&
        canUseReadOnlyFileActions() &&
        selectedChanges().single.kind != RepositoryChangeKind.untracked &&
        selectedChanges().single.kind != RepositoryChangeKind.deleted &&
        selectedChanges().single.kind != RepositoryChangeKind.conflicted;
    void invokeFileAction(RepositoryChangeFilesCallback callback) {
      final result = callback(selectedChanges());
      if (result is Future<void>) unawaited(result);
    }

    final String fileName = change.path.split('/').last;
    final int slash = change.path.lastIndexOf('/');
    final String parentPath = slash <= 0 ? '' : change.path.substring(0, slash);
    final String stats = [
      if (change.additions case final int value) '+$value',
      if (change.deletions case final int value) '−$value',
    ].join(' ');

    final content = Semantics(
      key: ValueKey<String>(
        'change-tile-${change.isStaged ? "staged" : "unstaged"}-${change.path}',
      ),
      button: true,
      selected: isSelected,
      label:
          '${change.isStaged ? "已暂存" : "未暂存"}，${_changeKindLabel(change.kind)}，${change.path}'
          '${change.submoduleStatus == null ? '' : '，子模块：${change.submoduleStatus}'}',
      child: Tooltip(
        message: change.path,
        waitDuration: const Duration(milliseconds: 650),
        child: InkWell(
          onTap: onTap,
          child: Container(
            color: isSelected ? colors.primary : null,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Tooltip(
                  message: !change.isActionEnabled
                      ? '正在更新文件状态'
                      : !change.canToggleStage
                      ? '冲突或无法安全表示的文件名不能在此暂存'
                      : change.isStaged
                      ? '取消暂存 ${change.path}'
                      : '暂存 ${change.path}',
                  child: SizedBox(
                    width: 32,
                    height: 32,
                    child: Checkbox(
                      value: change.isStaged,
                      onChanged:
                          !ordinaryMutationsEnabled ||
                              onStageToggled == null ||
                              !change.canToggleStage
                          ? null
                          : (_) => onStageToggled!(),
                      visualDensity: const VisualDensity(
                        horizontal: -4,
                        vertical: -4,
                      ),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      side: BorderSide(color: colors.onSurfaceVariant),
                      fillColor: !change.isActionEnabled && change.isStaged
                          ? WidgetStatePropertyAll(colors.primary)
                          : null,
                      checkColor: !change.isActionEnabled
                          ? colors.onPrimary
                          : null,
                    ),
                  ),
                ),
                _ChangeStatusBadge(kind: change.kind),
                const SizedBox(width: 7),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: isSelected ? colors.onPrimary : null,
                          ),
                        ),
                      ),
                      if (parentPath.isNotEmpty) ...[
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            parentPath,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: isSelected
                                  ? colors.onPrimary.withValues(alpha: .82)
                                  : colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                      if (change.submoduleStatus case final status?) ...[
                        const SizedBox(width: 6),
                        Flexible(
                          child: Tooltip(
                            message: '子模块：$status',
                            child: Text(
                              '子模块 · $status',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: isSelected
                                    ? colors.onPrimary.withValues(alpha: .82)
                                    : colors.tertiary,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (stats.isNotEmpty)
                  Text(
                    stats,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: isSelected
                          ? colors.onPrimary.withValues(alpha: .82)
                          : colors.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    return MenuAnchor(
      consumeOutsideTap: true,
      useRootOverlay: true,
      menuChildren: [
        MenuItemButton(onPressed: onTap, child: const Text('在差异视图中选择')),
        MenuItemButton(
          onPressed: onRevealInFinder == null || !canUseReadOnlyFileActions()
              ? null
              : () {
                  final result = onRevealInFinder!(selectedChanges());
                  if (result is Future<void>) unawaited(result);
                },
          child: Text(
            selectedChanges().every((item) => item.isPathValidUtf8)
                ? '在 Finder 中显示'
                : '在 Finder 中显示（待实现）',
          ),
        ),
        MenuItemButton(
          onPressed: canUseReadOnlyFileActions()
              ? () {
                  final paths = selectedChanges()
                      .map((item) => item.path)
                      .join('\n');
                  unawaited(Clipboard.setData(ClipboardData(text: paths)));
                }
              : null,
          child: Text(
            selectedChanges().every((item) => item.isPathValidUtf8)
                ? '复制路径到剪贴板'
                : '复制路径到剪贴板（待实现）',
          ),
        ),
        MenuItemButton(
          onPressed: canOpenTerminal()
              ? () => invokeFileAction(onOpenTerminal!)
              : null,
          child: Text(
            selectedChanges().every((item) => item.isPathValidUtf8)
                ? '在终端中打开'
                : '在终端中打开（待实现）',
          ),
        ),
        MenuItemButton(
          onPressed: onQuickLook != null && canUseReadOnlyFileActions()
              ? () => invokeFileAction(onQuickLook!)
              : null,
          child: Text(
            selectedChanges().every((item) => item.isPathValidUtf8)
                ? '快速查看'
                : '快速查看（待实现）',
          ),
        ),
        const Divider(height: 1),
        MenuItemButton(
          onPressed:
              conflictActionsEnabled &&
                  onExternalDiff != null &&
                  selectedChanges().length == 1 &&
                  selectedChanges().single.isActionEnabled &&
                  selectedChanges().single.isPathValidUtf8 &&
                  selectedChanges().single.canExternalDiff &&
                  selectedChanges().single.kind !=
                      RepositoryChangeKind.untracked &&
                  selectedChanges().single.kind !=
                      RepositoryChangeKind.conflicted
              ? () => invokeFileAction(onExternalDiff!)
              : null,
          child: Text(
            selectedChanges().length == 1 &&
                    selectedChanges().single.isPathValidUtf8 &&
                    selectedChanges().single.canExternalDiff &&
                    selectedChanges().single.kind !=
                        RepositoryChangeKind.untracked &&
                    selectedChanges().single.kind !=
                        RepositoryChangeKind.conflicted
                ? '外部差异比对'
                : '外部差异比对（待实现）',
          ),
        ),
        MenuItemButton(
          onPressed:
              ordinaryMutationsEnabled &&
                  onCreatePatch != null &&
                  selectedChanges().isNotEmpty &&
                  selectedChanges().every(
                    (item) =>
                        item.isActionEnabled &&
                        item.isPathValidUtf8 &&
                        item.kind != RepositoryChangeKind.untracked &&
                        item.kind != RepositoryChangeKind.conflicted,
                  )
              ? () => invokeFileAction(onCreatePatch!)
              : null,
          child: Text(
            selectedChanges().any(
                  (item) =>
                      !item.isPathValidUtf8 ||
                      item.kind == RepositoryChangeKind.untracked ||
                      item.kind == RepositoryChangeKind.conflicted,
                )
                ? '创建补丁…（待实现）'
                : '创建补丁…',
          ),
        ),
        MenuItemButton(
          onPressed: ordinaryMutationsEnabled ? onApplyPatch : null,
          child: const Text('应用补丁…'),
        ),
        const Divider(height: 1),
        MenuItemButton(
          onPressed:
              ordinaryMutationsEnabled &&
                  selectedChanges().any(
                    (item) => !item.isStaged && item.canToggleStage,
                  )
              ? () => onSelectedStageToggled(true)
              : null,
          child: const Text('添加到索引'),
        ),
        MenuItemButton(
          onPressed:
              ordinaryMutationsEnabled &&
                  selectedChanges().any(
                    (item) => item.isStaged && item.canToggleStage,
                  )
              ? () => onSelectedStageToggled(false)
              : null,
          child: const Text('从索引中取消暂存'),
        ),
        MenuItemButton(
          onPressed: canRemove()
              ? () {
                  final result = onRemove!(selectedChanges());
                  if (result is Future<void>) unawaited(result);
                }
              : null,
          child: Text(hasUnsupportedRemovePath() ? '移除（待实现）' : '移除'),
        ),
        MenuItemButton(
          onPressed: canStopTracking()
              ? () {
                  final result = onStopTracking!(selectedChanges());
                  if (result is Future<void>) unawaited(result);
                }
              : null,
          child: const Text('停止追踪'),
        ),
        MenuItemButton(
          onPressed: canReset()
              ? () {
                  final result = onReset!(selectedChanges());
                  if (result is Future<void>) unawaited(result);
                }
              : null,
          child: const Text('重置…'),
        ),
        MenuItemButton(
          onPressed:
              ordinaryMutationsEnabled &&
                  onIgnore != null &&
                  canUseReadOnlyFileActions() &&
                  selectedChanges().every(
                    (item) =>
                        item.kind != RepositoryChangeKind.conflicted &&
                        !item.path.contains('\n') &&
                        !item.path.contains('\r'),
                  )
              ? () => invokeFileAction(onIgnore!)
              : null,
          child: Text(
            selectedChanges().every((item) => item.isPathValidUtf8)
                ? '忽略…'
                : '忽略…（待实现）',
          ),
        ),
        const Divider(height: 1),
        if (change.kind == RepositoryChangeKind.conflicted &&
            conflictActionsEnabled &&
            change.isActionEnabled &&
            onConflictAction != null)
          SubmenuButton(
            leadingIcon: const Icon(Icons.merge_type, size: 18),
            menuChildren: _conflictMenuChildren(),
            child: const Text('解决冲突'),
          ),
        MenuItemButton(
          onPressed: canViewFileHistory()
              ? () => invokeFileAction(onViewFileHistory!)
              : null,
          child: Text(
            selectedChanges().every((item) => item.isPathValidUtf8)
                ? '查看选中的修改日志…'
                : '查看选中的修改日志…（待实现）',
          ),
        ),
        if (onBlame != null)
          MenuItemButton(
            onPressed: canBlame() ? () => invokeFileAction(onBlame!) : null,
            child: Text(canBlame() ? 'Blame' : 'Blame（待实现）'),
          ),
        MenuItemButton(
          onPressed: onReview != null && canUseReadOnlyFileActions()
              ? () => invokeFileAction(onReview!)
              : null,
          child: Text(
            selectedChanges().every((item) => item.isPathValidUtf8)
                ? '审查选定的项目'
                : '审查选定的项目（待实现）',
          ),
        ),
      ],
      builder: (context, controller, child) => CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.f10, shift: true): () {
            onContextMenuRequested();
            controller.open();
          },
          const SingleActivator(LogicalKeyboardKey.contextMenu): () {
            onContextMenuRequested();
            controller.open();
          },
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onSecondaryTapDown: (details) {
            onContextMenuRequested();
            controller.open(position: details.localPosition);
          },
          child: child,
        ),
      ),
      child: content,
    );
  }

  List<Widget> _conflictMenuChildren() {
    final handler = onConflictAction!;
    return [
      MenuItemButton(
        onPressed: () =>
            handler(RepositoryConflictAction.launchInternalDiffTool),
        child: const Text('打开内部 Diff 工具'),
      ),
      MenuItemButton(
        onPressed: () => handler(RepositoryConflictAction.useOurs),
        child: const Text('使用当前基线版本解决（Git stage 2）'),
      ),
      MenuItemButton(
        onPressed: () => handler(RepositoryConflictAction.useTheirs),
        child: const Text('使用待应用版本解决（Git stage 3）'),
      ),
      const Divider(height: 1),
      MenuItemButton(
        onPressed: () => handler(RepositoryConflictAction.restartMerge),
        child: const Text('重新合并'),
      ),
      MenuItemButton(
        onPressed: () => handler(RepositoryConflictAction.markResolved),
        child: const Text('标记为已解决'),
      ),
      MenuItemButton(
        onPressed: () => handler(RepositoryConflictAction.markUnresolved),
        child: const Text('标记为未解决'),
      ),
    ];
  }
}

String _changeSelectionKey(RepositoryChangeViewData change) =>
    '${change.isStaged ? 'staged' : 'unstaged'}\u0000${change.path}';

/// 中文：返回文件改动类型在改动列表中展示的本地化标签。
///
/// English: Returns the localized label displayed for a file-change kind.
String _changeKindLabel(RepositoryChangeKind kind) {
  return switch (kind) {
    RepositoryChangeKind.modified => '已修改',
    RepositoryChangeKind.added => '已添加',
    RepositoryChangeKind.deleted => '已删除',
    RepositoryChangeKind.renamed => '已重命名',
    RepositoryChangeKind.copied => '已复制',
    RepositoryChangeKind.untracked => '未跟踪',
    RepositoryChangeKind.conflicted => '有冲突',
  };
}

class _ChangeStatusBadge extends StatelessWidget {
  const _ChangeStatusBadge({required this.kind});

  final RepositoryChangeKind kind;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final (String, Color) display = switch (kind) {
      RepositoryChangeKind.modified => ('M', colors.primary),
      RepositoryChangeKind.added => ('+', colors.tertiary),
      RepositoryChangeKind.deleted => ('D', colors.error),
      RepositoryChangeKind.renamed => ('R', colors.secondary),
      RepositoryChangeKind.copied => ('C', colors.secondary),
      RepositoryChangeKind.untracked => ('?', colors.onSurfaceVariant),
      RepositoryChangeKind.conflicted => ('!', colors.error),
    };

    return Container(
      width: 18,
      height: 18,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: display.$2.withValues(alpha: .14),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        display.$1,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: display.$2,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _DiffPreview extends StatefulWidget {
  const _DiffPreview({
    required this.diff,
    this.onBack,
    this.onHunkAction,
    this.onDiffWhitespaceModeChanged,
  });

  final DiffViewData diff;
  final VoidCallback? onBack;
  final RepositoryDiffHunkActionCallback? onHunkAction;
  final RepositoryDiffWhitespaceModeCallback? onDiffWhitespaceModeChanged;

  @override
  State<_DiffPreview> createState() => _DiffPreviewState();
}

class _DiffPreviewState extends State<_DiffPreview> {
  late final ScrollController _scrollController;
  late final FocusNode _focusNode;
  bool _showOnlyChanges = false;
  bool _showSideBySide = false;
  int? _activeChangedIndex;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _focusNode = FocusNode(debugLabel: 'Diff change navigator');
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// 中文：当 Diff 内容替换时清除不再适用的活动差异索引。
  /// English: Clears the active change index when the preview content changes.
  @override
  void didUpdateWidget(covariant _DiffPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.diff, widget.diff)) {
      _activeChangedIndex = null;
    }
  }

  /// 中文：循环定位到下一条新增/删除行并滚动到可见位置。
  /// English: Cycles to the next or previous changed line and reveals it.
  void _jumpToChangedLine({
    required List<int> changedIndices,
    required List<DiffLineViewData> visibleLines,
    required BuildContext context,
    required bool forward,
  }) {
    if (changedIndices.isEmpty) return;
    final currentPosition = _activeChangedIndex == null
        ? -1
        : changedIndices.indexOf(_activeChangedIndex!);
    final nextPosition = forward
        ? (currentPosition + 1) % changedIndices.length
        : (currentPosition <= 0
              ? changedIndices.length - 1
              : currentPosition - 1);
    final targetIndex = changedIndices[nextPosition];
    final visiblePosition = visibleLines.indexWhere(
      (line) => identical(line, widget.diff.lines[targetIndex]),
    );
    if (visiblePosition < 0) return;
    setState(() => _activeChangedIndex = targetIndex);
    if (!_scrollController.hasClients) return;
    var offset = 0.0;
    for (var index = 0; index < visiblePosition; index++) {
      offset += _scaledDenseHeight(
        context,
        visibleLines[index].kind == DiffLineKind.hunkHeader ? 26 : 20,
      );
    }
    _scrollController.animateTo(
      offset.clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  /// 中文：将当前 Diff 的完整文本复制到系统剪贴板，不受显示筛选影响。
  /// English: Copies the complete Diff text to the system clipboard, ignoring
  /// the display-only context filter.
  Future<void> _copyDiff(BuildContext context) async {
    final text = widget.diff.lines.map((line) => line.text).join('\n');
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已复制 Diff。')));
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法复制 Diff 到剪贴板。')));
    }
  }

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    if (widget.diff.path == null) {
      return const _PaneEmptyState(
        icon: Icons.article_outlined,
        title: '选择文件以查看差异',
        message: '差异内容将在此处显示。',
      );
    }
    if (widget.diff.isBinary || widget.diff.isTooLarge) {
      return _PaneEmptyState(
        icon: widget.diff.isBinary ? Icons.data_object : Icons.warning_amber,
        title: widget.diff.isBinary ? '二进制文件' : '文件过大',
        message:
            widget.diff.notice ??
            (widget.diff.isBinary ? '此文件无法显示文本差异。' : '为保持界面响应，已跳过差异预览。'),
      );
    }

    final changedLineCount = widget.diff.lines.where((line) {
      return line.kind == DiffLineKind.addition ||
          line.kind == DiffLineKind.deletion;
    }).length;
    final visibleLines = _showOnlyChanges
        ? widget.diff.lines
              .where((line) => line.kind != DiffLineKind.context)
              .toList(growable: false)
        : widget.diff.lines;
    final changedIndices = <int>[
      for (var index = 0; index < widget.diff.lines.length; index++)
        if (widget.diff.lines[index].kind == DiffLineKind.addition ||
            widget.diff.lines[index].kind == DiffLineKind.deletion)
          index,
    ];
    final activeChangedIndex =
        _activeChangedIndex != null &&
            changedIndices.contains(_activeChangedIndex!)
        ? _activeChangedIndex
        : null;
    final sideBySideRows = _showSideBySide
        ? _buildSideBySideRows(visibleLines)
        : const <_SideBySideDiffRow>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: _scaledDenseHeight(context, 27),
          padding: const EdgeInsets.symmetric(horizontal: 9),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: colors.surfaceContainerLow,
            border: Border(bottom: BorderSide(color: colors.outlineVariant)),
          ),
          child: Row(
            children: [
              if (widget.onBack != null) ...[
                Tooltip(
                  message: '返回文件列表',
                  child: InkWell(
                    onTap: widget.onBack,
                    borderRadius: BorderRadius.circular(4),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 3),
                      child: Icon(Icons.arrow_back, size: 15),
                    ),
                  ),
                ),
                const SizedBox(width: 5),
              ],
              Expanded(
                child: Text(
                  widget.diff.path!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(fontFamily: 'monospace'),
                ),
              ),
              if (changedLineCount > 0 ||
                  widget.onDiffWhitespaceModeChanged != null)
                SizedBox(
                  width: _scaledDenseHeight(
                    context,
                    widget.onDiffWhitespaceModeChanged == null ? 216 : 270,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(
                        '$changedLineCount 行变更',
                        semanticsLabel: '$changedLineCount 行变更',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                      Tooltip(
                        message: '复制完整 Diff',
                        child: IconButton(
                          key: const ValueKey('copy-diff'),
                          onPressed: () => _copyDiff(context),
                          padding: EdgeInsets.zero,
                          iconSize: _scaledDenseHeight(context, 16),
                          tooltip: '复制完整 Diff',
                          icon: const Icon(Icons.copy_outlined),
                        ),
                      ),
                      Tooltip(
                        message: _showOnlyChanges ? '显示全部 Diff' : '仅显示改动',
                        child: IconButton(
                          key: const ValueKey('toggle-diff-changes'),
                          onPressed: () {
                            setState(() {
                              _showOnlyChanges = !_showOnlyChanges;
                            });
                          },
                          padding: EdgeInsets.zero,
                          iconSize: _scaledDenseHeight(context, 16),
                          tooltip: _showOnlyChanges ? '显示全部 Diff' : '仅显示改动',
                          icon: Icon(
                            _showOnlyChanges
                                ? Icons.filter_alt_off_outlined
                                : Icons.filter_alt_outlined,
                          ),
                        ),
                      ),
                      Tooltip(
                        message: _showSideBySide ? '显示统一 Diff' : '左右对比',
                        child: IconButton(
                          key: const ValueKey('toggle-diff-layout'),
                          onPressed: () {
                            setState(() {
                              _showSideBySide = !_showSideBySide;
                            });
                          },
                          padding: EdgeInsets.zero,
                          iconSize: _scaledDenseHeight(context, 16),
                          tooltip: _showSideBySide ? '显示统一 Diff' : '左右对比',
                          icon: Icon(
                            _showSideBySide
                                ? Icons.view_agenda_outlined
                                : Icons.view_column_outlined,
                          ),
                        ),
                      ),
                      if (widget.onDiffWhitespaceModeChanged != null)
                        PopupMenuButton<DiffWhitespaceMode>(
                          key: const ValueKey('diff-whitespace-mode'),
                          tooltip:
                              '空白比较：${_diffWhitespaceModeLabel(widget.diff.whitespaceMode)}',
                          initialValue: widget.diff.whitespaceMode,
                          onSelected: (mode) {
                            final result = widget.onDiffWhitespaceModeChanged!(
                              mode,
                            );
                            if (result is Future<void>) unawaited(result);
                          },
                          padding: EdgeInsets.zero,
                          iconSize: _scaledDenseHeight(context, 16),
                          icon: const Icon(Icons.space_bar),
                          itemBuilder: (context) => [
                            for (final mode in DiffWhitespaceMode.values)
                              PopupMenuItem(
                                value: mode,
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 22,
                                      child: mode == widget.diff.whitespaceMode
                                          ? const Icon(Icons.check, size: 16)
                                          : null,
                                    ),
                                    Text(_diffWhitespaceModeLabel(mode)),
                                  ],
                                ),
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: widget.diff.lines.isEmpty
              ? const _PaneEmptyState(
                  icon: Icons.horizontal_rule,
                  title: '没有文本差异',
                  message: 'Git 没有返回可显示的补丁。',
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final longestLine = visibleLines.fold<int>(
                      0,
                      (longest, line) => math.max(longest, line.text.length),
                    );
                    final textScale = math.max(
                      1.0,
                      MediaQuery.textScalerOf(context).scale(1),
                    );
                    final contentWidth = math.max(
                      constraints.maxWidth,
                      math.min(
                        32768.0,
                        _showSideBySide
                            ? 240 + longestLine * 7.2 * textScale * 2
                            : 118 + longestLine * 7.2 * textScale,
                      ),
                    );
                    return Focus(
                      focusNode: _focusNode,
                      onKeyEvent: (node, event) {
                        if (event is! KeyDownEvent) {
                          return KeyEventResult.ignored;
                        }
                        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                          _jumpToChangedLine(
                            changedIndices: changedIndices,
                            visibleLines: visibleLines,
                            context: context,
                            forward: true,
                          );
                          return KeyEventResult.handled;
                        }
                        if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                          _jumpToChangedLine(
                            changedIndices: changedIndices,
                            visibleLines: visibleLines,
                            context: context,
                            forward: false,
                          );
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _focusNode.requestFocus,
                        child: Semantics(
                          container: true,
                          label: changedLineCount == 0
                              ? 'Diff 对比，无改动行'
                              : 'Diff 对比，共 $changedLineCount 行改动；可用上下方向键定位',
                          child: SingleChildScrollView(
                            key: const ValueKey('diff-horizontal-scroll'),
                            scrollDirection: Axis.horizontal,
                            child: SizedBox(
                              width: contentWidth,
                              height: constraints.maxHeight,
                              child: ListView.builder(
                                controller: _scrollController,
                                itemCount: _showSideBySide
                                    ? sideBySideRows.length
                                    : visibleLines.length,
                                itemBuilder: (BuildContext context, int index) {
                                  if (_showSideBySide) {
                                    final row = sideBySideRows[index];
                                    return SizedBox(
                                      height: _scaledDenseHeight(
                                        context,
                                        row.fullLine?.kind ==
                                                DiffLineKind.hunkHeader
                                            ? 26
                                            : 20,
                                      ),
                                      child: _SideBySideDiffRowWidget(
                                        row: row,
                                        path: widget.diff.path!,
                                        activeLine: activeChangedIndex == null
                                            ? null
                                            : widget
                                                  .diff
                                                  .lines[activeChangedIndex],
                                        hunkActions: widget.diff.hunkActions,
                                        onHunkAction: widget.onHunkAction,
                                      ),
                                    );
                                  }
                                  final line = visibleLines[index];
                                  final canAct =
                                      line.kind == DiffLineKind.hunkHeader &&
                                      line.hunkIndex != null &&
                                      widget.diff.hunkActions.isNotEmpty &&
                                      widget.onHunkAction != null;
                                  return SizedBox(
                                    height: _scaledDenseHeight(
                                      context,
                                      line.kind == DiffLineKind.hunkHeader
                                          ? 26
                                          : 20,
                                    ),
                                    child: _DiffLine(
                                      key:
                                          activeChangedIndex != null &&
                                              identical(
                                                line,
                                                widget
                                                    .diff
                                                    .lines[activeChangedIndex],
                                              )
                                          ? const ValueKey('diff-active-line')
                                          : null,
                                      line: line,
                                      path: widget.diff.path!,
                                      isActive:
                                          activeChangedIndex != null &&
                                          identical(
                                            line,
                                            widget
                                                .diff
                                                .lines[activeChangedIndex],
                                          ),
                                      hunkActions: canAct
                                          ? widget.diff.hunkActions
                                          : const [],
                                      onHunkAction: canAct
                                          ? widget.onHunkAction
                                          : null,
                                    ),
                                  );
                                },
                              ),
                            ),
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
}

/// Returns the user-facing label for one whitespace comparison mode.
/// 中文：返回空白比较模式的用户可见标签。
String _diffWhitespaceModeLabel(DiffWhitespaceMode mode) {
  return switch (mode) {
    DiffWhitespaceMode.preserve => '保留空白差异',
    DiffWhitespaceMode.ignoreAll => '忽略所有空白',
    DiffWhitespaceMode.ignoreChanges => '忽略空白数量变化',
    DiffWhitespaceMode.ignoreBlankLines => '忽略空白行',
  };
}

/// A display row used by the optional side-by-side Diff presentation.
/// 中文：左右对比视图使用的展示行；删除和新增行会在同一行对齐。
final class _SideBySideDiffRow {
  const _SideBySideDiffRow({this.fullLine, this.left, this.right});

  final DiffLineViewData? fullLine;
  final DiffLineViewData? left;
  final DiffLineViewData? right;
}

/// Converts unified Diff lines into aligned left/right display rows.
/// 中文：将 Unified Diff 行转换为左右对齐的展示行，不改变原始补丁内容。
List<_SideBySideDiffRow> _buildSideBySideRows(List<DiffLineViewData> lines) {
  final rows = <_SideBySideDiffRow>[];
  var index = 0;
  while (index < lines.length) {
    final line = lines[index];
    if (line.kind == DiffLineKind.deletion) {
      final deletions = <DiffLineViewData>[];
      while (index < lines.length &&
          lines[index].kind == DiffLineKind.deletion) {
        deletions.add(lines[index++]);
      }
      final additions = <DiffLineViewData>[];
      while (index < lines.length &&
          lines[index].kind == DiffLineKind.addition) {
        additions.add(lines[index++]);
      }
      final count = math.max(deletions.length, additions.length);
      for (var offset = 0; offset < count; offset++) {
        rows.add(
          _SideBySideDiffRow(
            left: offset < deletions.length ? deletions[offset] : null,
            right: offset < additions.length ? additions[offset] : null,
          ),
        );
      }
      continue;
    }
    if (line.kind == DiffLineKind.addition) {
      rows.add(_SideBySideDiffRow(right: line));
    } else {
      rows.add(_SideBySideDiffRow(fullLine: line));
    }
    index++;
  }
  return rows;
}

class _SideBySideDiffRowWidget extends StatelessWidget {
  const _SideBySideDiffRowWidget({
    required this.row,
    required this.path,
    required this.activeLine,
    required this.hunkActions,
    required this.onHunkAction,
  });

  final _SideBySideDiffRow row;
  final String path;
  final DiffLineViewData? activeLine;
  final List<RepositoryDiffHunkAction> hunkActions;
  final RepositoryDiffHunkActionCallback? onHunkAction;

  @override
  Widget build(BuildContext context) {
    final fullLine = row.fullLine;
    if (fullLine != null) {
      final canAct =
          fullLine.kind == DiffLineKind.hunkHeader &&
          fullLine.hunkIndex != null &&
          hunkActions.isNotEmpty &&
          onHunkAction != null;
      return _DiffLine(
        key: identical(fullLine, activeLine)
            ? const ValueKey('diff-active-line')
            : null,
        line: fullLine,
        path: path,
        isActive: identical(fullLine, activeLine),
        hunkActions: canAct ? hunkActions : const [],
        onHunkAction: canAct ? onHunkAction : null,
      );
    }
    return Row(
      children: [
        Expanded(
          child: _DiffSideCell(
            line: row.left,
            path: path,
            isActive: identical(row.left, activeLine),
            showOldLineNumber: true,
            hunkActions: const [],
            onHunkAction: null,
          ),
        ),
        SizedBox(
          width: 1,
          child: ColoredBox(color: Theme.of(context).dividerColor),
        ),
        Expanded(
          child: _DiffSideCell(
            line: row.right,
            path: path,
            isActive: identical(row.right, activeLine),
            showOldLineNumber: false,
            hunkActions: const [],
            onHunkAction: null,
          ),
        ),
      ],
    );
  }
}

class _DiffSideCell extends StatelessWidget {
  const _DiffSideCell({
    required this.line,
    required this.path,
    required this.isActive,
    required this.showOldLineNumber,
    required this.hunkActions,
    required this.onHunkAction,
  });

  final DiffLineViewData? line;
  final String path;
  final bool isActive;
  final bool showOldLineNumber;
  final List<RepositoryDiffHunkAction> hunkActions;
  final RepositoryDiffHunkActionCallback? onHunkAction;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (line == null) {
      return const SizedBox.expand();
    }
    final current = line!;
    final background = current.kind == DiffLineKind.deletion
        ? colors.errorContainer.withValues(alpha: .46)
        : current.kind == DiffLineKind.addition
        ? colors.tertiaryContainer.withValues(alpha: .46)
        : null;
    final foreground = current.kind == DiffLineKind.deletion
        ? colors.onErrorContainer
        : current.kind == DiffLineKind.addition
        ? colors.onTertiaryContainer
        : colors.onSurface;
    final text =
        current.text.isNotEmpty &&
            (current.kind == DiffLineKind.deletion ||
                current.kind == DiffLineKind.addition)
        ? current.text.substring(1)
        : current.text;
    return Container(
      key: isActive ? const ValueKey('diff-active-line') : null,
      color: isActive ? colors.primaryContainer : background,
      child: Row(
        children: [
          _LineNumber(
            value: showOldLineNumber
                ? current.oldLineNumber
                : current.newLineNumber,
          ),
          Expanded(
            child: _buildDiffTextWidget(
              text: text,
              path: path,
              colors: colors,
              baseStyle: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: foreground,
                fontFamily: 'monospace',
                fontSize: 11,
                height: 1.45,
              ),
            ),
          ),
          if (onHunkAction != null && current.hunkIndex != null)
            for (final action in hunkActions)
              TextButton(
                onPressed: () {
                  final result = onHunkAction!(action, current.hunkIndex!);
                  if (result is Future<void>) unawaited(result);
                },
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 20),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  textStyle: Theme.of(context).textTheme.labelSmall,
                ),
                child: Text(switch (action) {
                  RepositoryDiffHunkAction.stage => '暂存区块',
                  RepositoryDiffHunkAction.discard => '放弃区块',
                  RepositoryDiffHunkAction.unstage => '取消暂存区块',
                  RepositoryDiffHunkAction.revertCommitted => '回滚区块',
                }),
              ),
        ],
      ),
    );
  }
}

class _DiffLine extends StatelessWidget {
  const _DiffLine({
    super.key,
    required this.line,
    required this.path,
    this.isActive = false,
    this.hunkActions = const [],
    this.onHunkAction,
  });

  final DiffLineViewData line;
  final String path;
  final bool isActive;
  final List<RepositoryDiffHunkAction> hunkActions;
  final RepositoryDiffHunkActionCallback? onHunkAction;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color? background = switch (line.kind) {
      DiffLineKind.addition => colors.tertiaryContainer.withValues(alpha: .46),
      DiffLineKind.deletion => colors.errorContainer.withValues(alpha: .46),
      DiffLineKind.hunkHeader => colors.primaryContainer.withValues(alpha: .5),
      DiffLineKind.fileHeader => colors.surfaceContainerHigh,
      _ => null,
    };
    final Color foreground = switch (line.kind) {
      DiffLineKind.addition => colors.onTertiaryContainer,
      DiffLineKind.deletion => colors.onErrorContainer,
      DiffLineKind.hunkHeader => colors.onPrimaryContainer,
      _ => colors.onSurface,
    };

    return Container(
      color: isActive ? colors.primaryContainer : background,
      child: Row(
        children: [
          _LineNumber(value: line.oldLineNumber),
          _LineNumber(value: line.newLineNumber),
          Expanded(
            child: _buildUnifiedDiffTextWidget(
              line: line,
              path: path,
              colors: colors,
              baseStyle: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: foreground,
                fontFamily: 'monospace',
                fontSize: 11,
                height: 1.45,
              ),
            ),
          ),
          if (onHunkAction != null && line.hunkIndex != null)
            for (final action in hunkActions)
              Tooltip(
                message: switch (action) {
                  RepositoryDiffHunkAction.stage => '只将这个未暂存区块加入索引',
                  RepositoryDiffHunkAction.discard => '放弃这个区块并恢复到索引版本',
                  RepositoryDiffHunkAction.unstage => '从索引中移除这个区块，保留工作区内容',
                  RepositoryDiffHunkAction.revertCommitted =>
                    '将已提交区块反向应用到当前工作区',
                },
                child: TextButton(
                  onPressed: () {
                    final result = onHunkAction!(action, line.hunkIndex!);
                    if (result is Future<void>) unawaited(result);
                  },
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 20),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                    textStyle: Theme.of(context).textTheme.labelSmall,
                  ),
                  child: Text(switch (action) {
                    RepositoryDiffHunkAction.stage => '暂存区块',
                    RepositoryDiffHunkAction.discard => '放弃区块',
                    RepositoryDiffHunkAction.unstage => '取消暂存区块',
                    RepositoryDiffHunkAction.revertCommitted => '回滚区块',
                  }),
                ),
              ),
        ],
      ),
    );
  }
}

class _LineNumber extends StatelessWidget {
  const _LineNumber({required this.value});

  final int? value;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Container(
      width: 38,
      padding: const EdgeInsets.only(right: 5),
      alignment: Alignment.centerRight,
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow.withValues(alpha: .7),
        border: Border(right: BorderSide(color: colors.outlineVariant)),
      ),
      child: Text(
        value?.toString() ?? '',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: colors.onSurfaceVariant,
          fontFamily: 'monospace',
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// Builds a syntax-aware span for one line of source text.
/// 中文：按文件扩展名为单行源码生成轻量语法高亮；无法识别的文件保持原始文本。
TextSpan _buildDiffTextSpan({
  required String text,
  required String path,
  required ColorScheme colors,
  required TextStyle? baseStyle,
}) {
  final syntax = _diffSyntaxForPath(path);
  if (syntax == _DiffSyntax.none || text.isEmpty) {
    return TextSpan(text: text, style: baseStyle);
  }
  final syntaxColors = _diffSyntaxColors(colors);
  final tokenPattern = RegExp(switch (syntax) {
    _DiffSyntax.json =>
      r'"(?:\\.|[^"\\])*"|\b(?:true|false|null)\b|\b\d+(?:\.\d+)?\b',
    _ =>
      r'''//.*|#.*|/\*.*?\*/|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\b\d+(?:\.\d+)?\b|\b(?:as|async|await|break|case|catch|class|const|continue|def|else|enum|extends|final|finally|for|from|func|function|if|implements|import|in|interface|let|library|map|new|null|override|private|protected|public|return|static|switch|this|throw|try|typedef|var|void|while|with|yield)\b''',
  }, multiLine: true);
  final spans = <TextSpan>[];
  var cursor = 0;
  for (final match in tokenPattern.allMatches(text)) {
    if (match.start > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, match.start)));
    }
    final token = match.group(0)!;
    final color = _diffTokenColor(token, syntaxColors, syntax);
    spans.add(
      TextSpan(
        text: token,
        style: baseStyle?.copyWith(color: color),
      ),
    );
    cursor = match.end;
  }
  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor)));
  }
  return TextSpan(style: baseStyle, children: spans);
}

/// Uses a plain Text widget when highlighting is unavailable so Flutter's
/// text finder and accessibility tree preserve the exact source line.
/// 中文：无法高亮时保留普通 Text，确保测试查找器和辅助功能仍看到完整源码行。
Widget _buildDiffTextWidget({
  required String text,
  required String path,
  required ColorScheme colors,
  required TextStyle? baseStyle,
}) {
  if (_diffSyntaxForPath(path) == _DiffSyntax.none || text.isEmpty) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.clip,
      softWrap: false,
      style: baseStyle,
    );
  }
  return Text.rich(
    _buildDiffTextSpan(
      text: text,
      path: path,
      colors: colors,
      baseStyle: baseStyle,
    ),
    maxLines: 1,
    overflow: TextOverflow.clip,
    softWrap: false,
  );
}

/// Keeps the unified Diff marker outside the syntax lexer.
/// 中文：统一 Diff 的前缀字符保持状态颜色，源码正文才进入语法高亮。
TextSpan _buildUnifiedDiffTextSpan({
  required DiffLineViewData line,
  required String path,
  required ColorScheme colors,
  required TextStyle? baseStyle,
}) {
  if (line.kind != DiffLineKind.context &&
      line.kind != DiffLineKind.addition &&
      line.kind != DiffLineKind.deletion) {
    return TextSpan(text: line.text, style: baseStyle);
  }
  if (line.text.isEmpty) {
    return TextSpan(text: line.text, style: baseStyle);
  }
  final marker = line.text.substring(0, 1);
  final source = line.text.substring(1);
  return TextSpan(
    style: baseStyle,
    children: [
      TextSpan(text: marker),
      _buildDiffTextSpan(
        text: source,
        path: path,
        colors: colors,
        baseStyle: baseStyle,
      ),
    ],
  );
}

/// Preserves plain Text for headers and unknown files while highlighting source
/// content for recognized paths.
/// 中文：文件头、区块头和未知文件保持普通 Text，其余源码行使用轻量高亮。
Widget _buildUnifiedDiffTextWidget({
  required DiffLineViewData line,
  required String path,
  required ColorScheme colors,
  required TextStyle? baseStyle,
}) {
  final canHighlight =
      _diffSyntaxForPath(path) != _DiffSyntax.none &&
      (line.kind == DiffLineKind.context ||
          line.kind == DiffLineKind.addition ||
          line.kind == DiffLineKind.deletion) &&
      line.text.length > 1;
  if (!canHighlight) {
    return Text(
      line.text,
      maxLines: 1,
      overflow: TextOverflow.clip,
      softWrap: false,
      style: baseStyle,
    );
  }
  return Text.rich(
    _buildUnifiedDiffTextSpan(
      line: line,
      path: path,
      colors: colors,
      baseStyle: baseStyle,
    ),
    maxLines: 1,
    overflow: TextOverflow.clip,
    softWrap: false,
  );
}

enum _DiffSyntax { none, dart, json, generic }

/// Selects the lightweight lexer from a repository-relative file path.
/// 中文：根据仓库相对路径选择轻量词法器；未知扩展名返回无高亮模式。
_DiffSyntax _diffSyntaxForPath(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.json') || lower.endsWith('.jsonc')) {
    return _DiffSyntax.json;
  }
  const sourceExtensions = <String>{
    '.c',
    '.cc',
    '.cpp',
    '.cs',
    '.css',
    '.dart',
    '.go',
    '.h',
    '.hpp',
    '.html',
    '.java',
    '.js',
    '.jsx',
    '.kt',
    '.kts',
    '.m',
    '.mm',
    '.php',
    '.py',
    '.rb',
    '.rs',
    '.scss',
    '.sh',
    '.sql',
    '.swift',
    '.ts',
    '.tsx',
    '.xml',
    '.yaml',
    '.yml',
  };
  if (sourceExtensions.any(lower.endsWith)) {
    return lower.endsWith('.dart') ? _DiffSyntax.dart : _DiffSyntax.generic;
  }
  return _DiffSyntax.none;
}

/// Derives syntax colors from the active Material color scheme.
/// 中文：从当前 Material 主题派生语法颜色，确保浅色和深色模式都可读。
({Color comment, Color keyword, Color number, Color string}) _diffSyntaxColors(
  ColorScheme colors,
) {
  return (
    comment: colors.onSurfaceVariant,
    keyword: colors.primary,
    number: colors.secondary,
    string: colors.tertiary,
  );
}

/// Classifies one lexer token without changing its source text.
/// 中文：分类单个词法 token，只改变显示颜色，不修改源码内容。
Color _diffTokenColor(
  String token,
  ({Color comment, Color keyword, Color number, Color string}) colors,
  _DiffSyntax syntax,
) {
  if (token.startsWith('//') ||
      token.startsWith('#') ||
      token.startsWith('/*')) {
    return colors.comment;
  }
  if (token.startsWith('"') || token.startsWith("'")) {
    return colors.string;
  }
  if (RegExp(r'^\d').hasMatch(token)) {
    return colors.number;
  }
  if (syntax == _DiffSyntax.json &&
      (token == 'true' || token == 'false' || token == 'null')) {
    return colors.keyword;
  }
  return colors.keyword;
}

/// Reuses the workspace's selected-commit metadata pane.
/// 中文：复用工作区中所选提交的元数据面板。
