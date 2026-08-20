import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'models/repository_overview_view_data.dart';

export 'models/repository_overview_view_data.dart';

typedef RepositoryActionCallback = void Function(RepositoryAction action);
typedef RepositoryRefCallback = void Function(RepositoryRefViewData ref);
typedef RepositoryRefContextActionCallback =
    void Function(RepositoryRefViewData ref, RepositoryRefContextAction action);
typedef RepositoryCommitCallback = void Function(CommitViewData commit);
typedef RepositoryChangeCallback =
    void Function(RepositoryChangeViewData? change);
typedef RepositoryChangeStageCallback =
    void Function(RepositoryChangeViewData change);
typedef RepositoryCommitFileCallback = void Function(CommitFileViewData? file);

/// Interaction surface for [RepositoryOverview].
///
/// Callbacks are intentionally event-only: Git execution, confirmation and
/// state changes stay in the application layer.
final class RepositoryOverviewCallbacks {
  const RepositoryOverviewCallbacks({
    this.onAction,
    this.onSearchChanged,
    this.onRefSelected,
    this.onRefContextAction,
    this.onCommitSelected,
    this.onChangeSelected,
    this.onChangeStageToggled,
    this.onCommitFileSelected,
    this.onLayoutChanged,
  });

  final RepositoryActionCallback? onAction;
  final ValueChanged<String>? onSearchChanged;
  final RepositoryRefCallback? onRefSelected;
  final RepositoryRefContextActionCallback? onRefContextAction;
  final RepositoryCommitCallback? onCommitSelected;
  final RepositoryChangeCallback? onChangeSelected;
  final RepositoryChangeStageCallback? onChangeStageToggled;
  final RepositoryCommitFileCallback? onCommitFileSelected;
  final ValueChanged<RepositoryOverviewLayout>? onLayoutChanged;
}

/// High-density, responsive desktop repository workspace.
///
/// Layout behavior:
/// - >= 1180 px: resizable refs, history/changes and details columns.
/// - 760–1179 px: refs plus history with a lower tabbed inspector.
/// - < 760 px: one pane at a time, selected with an accessible compact switcher.
class RepositoryOverview extends StatefulWidget {
  const RepositoryOverview({
    super.key,
    required this.data,
    this.callbacks = const RepositoryOverviewCallbacks(),
    this.initialLayout = const RepositoryOverviewLayout(),
  });

  final RepositoryOverviewViewData data;
  final RepositoryOverviewCallbacks callbacks;
  final RepositoryOverviewLayout initialLayout;

  /// 中文：创建关联的状态对象。
  /// English: Creates the associated state object.
  @override
  State<RepositoryOverview> createState() => _RepositoryOverviewState();
}

enum _InspectorTab { changes, details }

enum _CompactPane { refs, history, changes, details }

class _RepositoryOverviewState extends State<RepositoryOverview> {
  late RepositoryOverviewLayout _layout = widget.initialLayout;
  _InspectorTab _inspectorTab = _InspectorTab.changes;
  _CompactPane _compactPane = _CompactPane.history;

  /// 中文：响应上层组件配置更新。
  /// English: Responds to updated widget configuration.
  @override
  void didUpdateWidget(RepositoryOverview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialLayout != widget.initialLayout) {
      _layout = widget.initialLayout;
    }
  }

  /// 中文：更新可调整面板的布局并通知上层回调保存新尺寸。
  ///
  /// English: Updates the resizable-pane layout and notifies the parent
  /// callback so the new dimensions can be retained.
  void _updateLayout(RepositoryOverviewLayout next) {
    setState(() => _layout = next);
    widget.callbacks.onLayoutChanged?.call(next);
  }

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final RepositoryViewData? repository = widget.data.repository;

    if (widget.data.state == RepositoryOverviewState.noRepository) {
      return _NoRepositoryView(
        data: widget.data,
        onAction: widget.callbacks.onAction,
      );
    }

    if (repository == null &&
        widget.data.state == RepositoryOverviewState.loading) {
      return _LoadingView(
        data: widget.data,
        onAction: widget.callbacks.onAction,
      );
    }

    if (repository == null &&
        widget.data.state == RepositoryOverviewState.error) {
      return _ErrorView(data: widget.data, onAction: widget.callbacks.onAction);
    }

    if (repository == null) {
      return _ErrorView(
        data: const RepositoryOverviewViewData.error(message: '仓库视图缺少可显示的数据。'),
        onAction: widget.callbacks.onAction,
      );
    }

    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        child: Column(
          children: [
            _RepositoryToolbar(
              repository: repository,
              callbacks: widget.callbacks,
            ),
            Expanded(
              child: Stack(
                children: [
                  LayoutBuilder(
                    builder:
                        (BuildContext context, BoxConstraints constraints) {
                          if (constraints.maxWidth >= 1180) {
                            return _buildWide(repository, constraints);
                          }
                          if (constraints.maxWidth >= 760) {
                            return _buildMedium(repository, constraints);
                          }
                          return _buildCompact(repository);
                        },
                  ),
                  if (widget.data.state == RepositoryOverviewState.loading)
                    const _StaleDataLoadingOverlay(),
                  if (widget.data.state == RepositoryOverviewState.error)
                    _StaleDataErrorBanner(
                      message: widget.data.message ?? '刷新仓库失败',
                      onRetry: widget.callbacks.onAction == null
                          ? null
                          : () => widget.callbacks.onAction!(
                              RepositoryAction.retry,
                            ),
                    ),
                ],
              ),
            ),
            _RepositoryStatusBar(
              data: repository.footer,
              onAction: widget.callbacks.onAction,
            ),
          ],
        ),
      ),
    );
  }

  /// 中文：构建宽屏三栏布局：引用导航、历史/改动区域和提交详情，并约束可拖拽尺寸。
  ///
  /// English: Builds the wide three-column layout—refs, history/changes, and
  /// commit details—while clamping resizable dimensions.
  Widget _buildWide(RepositoryViewData repository, BoxConstraints constraints) {
    final double navigationWidth = _layout.navigationWidth.clamp(
      176,
      math.min(320, constraints.maxWidth * .28),
    );
    final double detailsWidth = _layout.detailsWidth.clamp(
      280,
      math.min(480, constraints.maxWidth * .38),
    );
    final double changesHeight = _layout.changesHeight.clamp(
      168,
      math.max(168, constraints.maxHeight * .62),
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: navigationWidth,
          child: _RefsNavigation(
            repository: repository,
            onSelected: widget.callbacks.onRefSelected,
            onContextAction: widget.callbacks.onRefContextAction,
          ),
        ),
        _ResizeDivider(
          axis: Axis.vertical,
          semanticsLabel: '调整引用导航宽度',
          onDelta: (double delta) => _updateLayout(
            _layout.copyWith(navigationWidth: navigationWidth + delta),
          ),
        ),
        Expanded(
          child: Column(
            children: [
              Expanded(
                child: _HistoryPane(
                  repository: repository,
                  onSelected: widget.callbacks.onCommitSelected,
                ),
              ),
              _ResizeDivider(
                axis: Axis.horizontal,
                semanticsLabel: '调整改动面板高度',
                onDelta: (double delta) => _updateLayout(
                  _layout.copyWith(changesHeight: changesHeight - delta),
                ),
              ),
              SizedBox(
                height: changesHeight,
                child: _SelectedChangesPane(
                  repository: repository,
                  onSelected: widget.callbacks.onChangeSelected,
                  onStageToggled: widget.callbacks.onChangeStageToggled,
                  onCommitFileSelected: widget.callbacks.onCommitFileSelected,
                ),
              ),
            ],
          ),
        ),
        _ResizeDivider(
          axis: Axis.vertical,
          semanticsLabel: '调整提交详情宽度',
          onDelta: (double delta) => _updateLayout(
            _layout.copyWith(detailsWidth: detailsWidth - delta),
          ),
        ),
        SizedBox(
          width: detailsWidth,
          child: _CommitDetailsPane(details: repository.selectedCommit),
        ),
      ],
    );
  }

  /// 中文：构建中等宽度布局，在历史下方以选项卡承载改动和详情检查器。
  ///
  /// English: Builds the medium-width layout with a tabbed changes/details
  /// inspector below history.
  Widget _buildMedium(
    RepositoryViewData repository,
    BoxConstraints constraints,
  ) {
    final double navigationWidth = _layout.navigationWidth.clamp(
      176,
      math.min(280, constraints.maxWidth * .34),
    );
    final double changesHeight = _layout.changesHeight.clamp(
      180,
      math.max(180, constraints.maxHeight * .58),
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: navigationWidth,
          child: _RefsNavigation(
            repository: repository,
            onSelected: widget.callbacks.onRefSelected,
            onContextAction: widget.callbacks.onRefContextAction,
          ),
        ),
        _ResizeDivider(
          axis: Axis.vertical,
          semanticsLabel: '调整引用导航宽度',
          onDelta: (double delta) => _updateLayout(
            _layout.copyWith(navigationWidth: navigationWidth + delta),
          ),
        ),
        Expanded(
          child: Column(
            children: [
              Expanded(
                child: _HistoryPane(
                  repository: repository,
                  onSelected: widget.callbacks.onCommitSelected,
                ),
              ),
              _ResizeDivider(
                axis: Axis.horizontal,
                semanticsLabel: '调整检查器高度',
                onDelta: (double delta) => _updateLayout(
                  _layout.copyWith(changesHeight: changesHeight - delta),
                ),
              ),
              SizedBox(
                height: changesHeight,
                child: _TabbedInspector(
                  selectedTab: _inspectorTab,
                  onTabChanged: (_InspectorTab tab) {
                    setState(() => _inspectorTab = tab);
                  },
                  repository: repository,
                  onChangeSelected: widget.callbacks.onChangeSelected,
                  onChangeStageToggled: widget.callbacks.onChangeStageToggled,
                  onCommitFileSelected: widget.callbacks.onCommitFileSelected,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 中文：为窄屏选择当前紧凑面板，并配合底部导航在引用、历史、改动和详情之间切换。
  ///
  /// English: Selects the active compact pane for narrow screens, switching
  /// among refs, history, changes, and details through bottom navigation.
  Widget _buildCompact(RepositoryViewData repository) {
    final Widget pane = switch (_compactPane) {
      _CompactPane.refs => _RefsNavigation(
        repository: repository,
        onSelected: widget.callbacks.onRefSelected,
        onContextAction: widget.callbacks.onRefContextAction,
      ),
      _CompactPane.history => _HistoryPane(
        repository: repository,
        onSelected: widget.callbacks.onCommitSelected,
      ),
      _CompactPane.changes => _SelectedChangesPane(
        repository: repository,
        onSelected: widget.callbacks.onChangeSelected,
        onStageToggled: widget.callbacks.onChangeStageToggled,
        onCommitFileSelected: widget.callbacks.onCommitFileSelected,
      ),
      _CompactPane.details => _CommitDetailsPane(
        details: repository.selectedCommit,
      ),
    };

    return Column(
      children: [
        _CompactPaneSwitcher(
          selected: _compactPane,
          onSelected: (_CompactPane pane) {
            setState(() => _compactPane = pane);
          },
          changeCount: repository.changes.length,
        ),
        Expanded(child: pane),
      ],
    );
  }
}

class _RepositoryToolbar extends StatelessWidget {
  const _RepositoryToolbar({required this.repository, required this.callbacks});

  final RepositoryViewData repository;
  final RepositoryOverviewCallbacks callbacks;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;

    return Material(
      color: colors.surfaceContainerLow,
      child: Container(
        height: 54,
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: colors.outlineVariant)),
        ),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final bool showLabels = constraints.maxWidth >= 940;
            final bool showPath = constraints.maxWidth >= 680;

            return Row(
              children: [
                const SizedBox(width: 12),
                Icon(
                  Icons.account_tree_outlined,
                  size: 20,
                  color: colors.primary,
                  semanticLabel: 'Git 仓库',
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 260),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          repository.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (showPath)
                          Text(
                            repository.path,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _BranchChip(repository: repository),
                const SizedBox(width: 8),
                VerticalDivider(
                  width: 17,
                  indent: 10,
                  endIndent: 10,
                  color: colors.outlineVariant,
                ),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _ToolbarAction(
                          action: RepositoryAction.openRepository,
                          icon: Icons.folder_open_outlined,
                          label: '打开仓库',
                          showLabel: showLabels,
                          repository: repository,
                          onAction: callbacks.onAction,
                        ),
                        _ToolbarAction(
                          action: repository.isFetching
                              ? RepositoryAction.cancelFetch
                              : RepositoryAction.fetch,
                          icon: repository.isFetching
                              ? Icons.cancel_outlined
                              : Icons.sync,
                          label: repository.isFetching ? '取消获取' : '获取',
                          showLabel: showLabels,
                          repository: repository,
                          onAction: callbacks.onAction,
                          isBusy: repository.isFetching,
                        ),
                        _ToolbarAction(
                          action: repository.isPulling
                              ? RepositoryAction.cancelPull
                              : RepositoryAction.pull,
                          icon: repository.isPulling
                              ? Icons.cancel_outlined
                              : Icons.south,
                          label: repository.isPulling ? '取消拉取' : '拉取',
                          showLabel: showLabels,
                          repository: repository,
                          onAction: callbacks.onAction,
                          isBusy: repository.isPulling,
                        ),
                        _ToolbarAction(
                          action: repository.isPushing
                              ? RepositoryAction.cancelPush
                              : RepositoryAction.push,
                          icon: repository.isPushing
                              ? Icons.cancel_outlined
                              : Icons.north,
                          label: repository.isPushing ? '取消推送' : '推送',
                          showLabel: showLabels,
                          repository: repository,
                          onAction: callbacks.onAction,
                          isBusy: repository.isPushing,
                        ),
                        _ToolbarAction(
                          action: RepositoryAction.createBranch,
                          icon: Icons.call_split,
                          label: '分支',
                          showLabel: showLabels,
                          repository: repository,
                          onAction: callbacks.onAction,
                        ),
                        _ToolbarAction(
                          action: RepositoryAction.mergeBranch,
                          icon: Icons.merge_type,
                          label: '合并',
                          showLabel: showLabels,
                          repository: repository,
                          onAction: callbacks.onAction,
                        ),
                        _ToolbarAction(
                          action: RepositoryAction.commit,
                          icon: Icons.check_circle_outline,
                          label: '提交',
                          showLabel: showLabels,
                          repository: repository,
                          onAction: callbacks.onAction,
                          badge: repository.stagedChangeCount,
                        ),
                        _ToolbarAction(
                          action: RepositoryAction.refresh,
                          icon: Icons.refresh,
                          label: '刷新',
                          showLabel: false,
                          repository: repository,
                          onAction: callbacks.onAction,
                          isBusy: repository.isRefreshing,
                        ),
                      ],
                    ),
                  ),
                ),
                if (constraints.maxWidth >= 620)
                  SizedBox(
                    width: constraints.maxWidth >= 940 ? 220 : 150,
                    child: _HistorySearchField(
                      query: repository.searchQuery,
                      onChanged: callbacks.onSearchChanged,
                    ),
                  ),
                const SizedBox(width: 10),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _BranchChip extends StatelessWidget {
  const _BranchChip({required this.repository});

  final RepositoryViewData repository;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final String branchLabel = repository.isDetachedHead
        ? 'HEAD ${repository.headOid ?? repository.currentBranch}'
        : repository.currentBranch;
    final String trackingLabel = [
      if (repository.ahead > 0) '↑${repository.ahead}',
      if (repository.behind > 0) '↓${repository.behind}',
    ].join(' ');

    return Semantics(
      label: repository.isDetachedHead
          ? '游离 HEAD，$branchLabel'
          : '当前分支 $branchLabel',
      child: Tooltip(
        message: trackingLabel.isEmpty
            ? branchLabel
            : '$branchLabel，$trackingLabel',
        child: Container(
          constraints: const BoxConstraints(maxWidth: 190),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: colors.secondaryContainer,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                repository.isDetachedHead ? Icons.link_off : Icons.call_split,
                size: 14,
                color: colors.onSecondaryContainer,
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  branchLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: colors.onSecondaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (trackingLabel.isNotEmpty) ...[
                const SizedBox(width: 5),
                Text(
                  trackingLabel,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colors.onSecondaryContainer,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolbarAction extends StatelessWidget {
  const _ToolbarAction({
    required this.action,
    required this.icon,
    required this.label,
    required this.showLabel,
    required this.repository,
    required this.onAction,
    this.badge = 0,
    this.isBusy = false,
  });

  final RepositoryAction action;
  final IconData icon;
  final String label;
  final bool showLabel;
  final RepositoryViewData repository;
  final RepositoryActionCallback? onAction;
  final int badge;
  final bool isBusy;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final bool enabled =
        onAction != null && !repository.disabledActions.contains(action);
    final Widget iconWidget = isBusy
        ? const SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Badge(
            isLabelVisible: badge > 0,
            label: Text('$badge'),
            child: Icon(icon, size: 18),
          );

    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        enabled: enabled,
        child: showLabel
            ? TextButton.icon(
                onPressed: enabled ? () => onAction!(action) : null,
                icon: iconWidget,
                label: Text(label),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 9),
                ),
              )
            : IconButton(
                onPressed: enabled ? () => onAction!(action) : null,
                icon: iconWidget,
                tooltip: label,
                visualDensity: VisualDensity.compact,
              ),
      ),
    );
  }
}

class _HistorySearchField extends StatelessWidget {
  const _HistorySearchField({required this.query, required this.onChanged});

  final String query;
  final ValueChanged<String>? onChanged;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    return Semantics(
      textField: true,
      label: '搜索提交历史',
      child: TextFormField(
        initialValue: query,
        onChanged: onChanged,
        enabled: onChanged != null,
        style: Theme.of(context).textTheme.bodySmall,
        decoration: const InputDecoration(
          hintText: '搜索提交',
          prefixIcon: Icon(Icons.search, size: 17),
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          border: OutlineInputBorder(),
        ),
      ),
    );
  }
}

class _RefsNavigation extends StatelessWidget {
  const _RefsNavigation({
    required this.repository,
    required this.onSelected,
    required this.onContextAction,
  });

  final RepositoryViewData repository;
  final RepositoryRefCallback? onSelected;
  final RepositoryRefContextActionCallback? onContextAction;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final Map<RepositoryRefKind, List<RepositoryRefViewData>> sections = {
      for (final RepositoryRefKind kind in RepositoryRefKind.values)
        kind: repository.refs
            .where((RepositoryRefViewData ref) => ref.kind == kind)
            .toList(growable: false),
    };

    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      child: CustomScrollView(
        slivers: [
          const SliverToBoxAdapter(
            child: _PaneHeader(title: '仓库', icon: Icons.folder_open_outlined),
          ),
          for (final RepositoryRefKind kind in RepositoryRefKind.values)
            if (sections[kind]!.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: _SectionHeader(
                  title: _refKindLabel(kind),
                  count: sections[kind]!.length,
                ),
              ),
              SliverList.builder(
                itemCount: sections[kind]!.length,
                itemBuilder: (BuildContext context, int index) {
                  final RepositoryRefViewData ref = sections[kind]![index];
                  return _RefTile(
                    ref: ref,
                    onTap: onSelected == null ? null : () => onSelected!(ref),
                    contextItems: _contextItemsFor(ref),
                    onContextAction: onContextAction == null
                        ? null
                        : (RepositoryRefContextAction action) =>
                              onContextAction!(ref, action),
                  );
                },
              ),
            ],
          if (repository.refs.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: _PaneEmptyState(
                icon: Icons.call_split,
                title: '暂无引用',
                message: '分支、远端和标签会显示在这里。',
              ),
            ),
        ],
      ),
    );
  }

  /// 中文：根据引用类型及当前仓库状态构建右键菜单，并禁用不能安全执行的操作。
  ///
  /// English: Builds context-menu items from the reference kind and repository
  /// state, disabling operations that are not currently safe to run.
  List<_RefContextMenuItem> _contextItemsFor(RepositoryRefViewData ref) {
    final disabledActions = repository.disabledActions;
    final isBusy = repository.isRefreshing;
    final canFetch =
        !isBusy && !disabledActions.contains(RepositoryAction.fetch);
    final canPull = !isBusy && !disabledActions.contains(RepositoryAction.pull);
    final canPush = !isBusy && !disabledActions.contains(RepositoryAction.push);
    final canSwitch = repository.isWorkingTreeClean && !isBusy;
    final canMerge = !disabledActions.contains(RepositoryAction.mergeBranch);
    final canCreate =
        !isBusy && !disabledActions.contains(RepositoryAction.createBranch);
    final canManageLocalBranch = repository.isWorkingTreeClean && !isBusy;
    return switch (ref.kind) {
      RepositoryRefKind.workspace => [
        _RefContextMenuItem(
          action: RepositoryRefContextAction.fetchOrigin,
          label: '获取 origin',
          icon: Icons.sync,
          enabled: canFetch,
        ),
        _RefContextMenuItem(
          action: RepositoryRefContextAction.refresh,
          label: '刷新仓库',
          icon: Icons.refresh,
          enabled: !isBusy,
        ),
      ],
      RepositoryRefKind.localBranch when ref.isCurrent => [
        _RefContextMenuItem(
          action: RepositoryRefContextAction.fetchOrigin,
          label: '获取 origin',
          icon: Icons.sync,
          enabled: canFetch,
        ),
        _RefContextMenuItem(
          action: RepositoryRefContextAction.pullCurrentBranch,
          label: '拉取当前分支',
          icon: Icons.south,
          enabled: canPull,
        ),
        _RefContextMenuItem(
          action: RepositoryRefContextAction.pushCurrentBranch,
          label: '推送当前分支',
          icon: Icons.north,
          enabled: canPush,
        ),
        const _RefContextMenuItem.divider(),
        _RefContextMenuItem(
          action: RepositoryRefContextAction.createBranchFromReference,
          label: '从此分支创建新分支',
          icon: Icons.call_split,
          enabled: canCreate,
        ),
        _RefContextMenuItem(
          action: RepositoryRefContextAction.renameLocalBranch,
          label: '重命名此分支',
          icon: Icons.drive_file_rename_outline,
          enabled: canManageLocalBranch,
        ),
        const _RefContextMenuItem.divider(),
        _RefContextMenuItem(
          action: RepositoryRefContextAction.refresh,
          label: '刷新仓库',
          icon: Icons.refresh,
          enabled: !isBusy,
        ),
      ],
      RepositoryRefKind.localBranch => [
        _RefContextMenuItem(
          action: RepositoryRefContextAction.createBranchFromReference,
          label: '从此分支创建新分支',
          icon: Icons.call_split,
          enabled: canCreate,
        ),
        _RefContextMenuItem(
          action: RepositoryRefContextAction.renameLocalBranch,
          label: '重命名分支',
          icon: Icons.drive_file_rename_outline,
          enabled: canManageLocalBranch,
        ),
        _RefContextMenuItem(
          action: RepositoryRefContextAction.deleteLocalBranch,
          label: '删除分支',
          icon: Icons.delete_outline,
          enabled: canManageLocalBranch,
        ),
        const _RefContextMenuItem.divider(),
        _RefContextMenuItem(
          action: RepositoryRefContextAction.checkout,
          label: '切换到此分支',
          icon: Icons.swap_horiz,
          enabled: canSwitch,
        ),
        _RefContextMenuItem(
          action: RepositoryRefContextAction.mergeIntoCurrent,
          label: '合并到当前分支',
          icon: Icons.merge_type,
          enabled: canMerge,
        ),
        const _RefContextMenuItem.divider(),
        _RefContextMenuItem(
          action: RepositoryRefContextAction.refresh,
          label: '刷新仓库',
          icon: Icons.refresh,
          enabled: !isBusy,
        ),
      ],
      RepositoryRefKind.remoteBranch => [
        _RefContextMenuItem(
          action: RepositoryRefContextAction.checkout,
          label: '创建本地跟踪分支并切换',
          icon: Icons.download_outlined,
          enabled: canSwitch,
        ),
        _RefContextMenuItem(
          action: RepositoryRefContextAction.fetchOrigin,
          label: '获取 origin',
          icon: Icons.sync,
          enabled: canFetch,
        ),
        const _RefContextMenuItem.divider(),
        _RefContextMenuItem(
          action: RepositoryRefContextAction.refresh,
          label: '刷新仓库',
          icon: Icons.refresh,
          enabled: !isBusy,
        ),
      ],
      _ => [
        _RefContextMenuItem(
          action: RepositoryRefContextAction.refresh,
          label: '刷新仓库',
          icon: Icons.refresh,
          enabled: !isBusy,
        ),
      ],
    };
  }
}

final class _RefContextMenuItem {
  const _RefContextMenuItem({
    required this.action,
    required this.label,
    required this.icon,
    required this.enabled,
  }) : isDivider = false;

  const _RefContextMenuItem.divider()
    : action = null,
      label = '',
      icon = null,
      enabled = false,
      isDivider = true;

  final RepositoryRefContextAction? action;
  final String label;
  final IconData? icon;
  final bool enabled;
  final bool isDivider;
}

/// 中文：返回引用类型在导航栏中展示的本地化名称。
///
/// English: Returns the localized name shown in navigation for a ref type.
String _refKindLabel(RepositoryRefKind kind) {
  return switch (kind) {
    RepositoryRefKind.workspace => '工作区',
    RepositoryRefKind.localBranch => '分支',
    RepositoryRefKind.remoteBranch => '远端',
    RepositoryRefKind.tag => '标签',
    RepositoryRefKind.stash => '贮藏',
  };
}

/// 中文：返回与引用类型对应的导航图标。
///
/// English: Returns the navigation icon associated with a ref type.
IconData _refKindIcon(RepositoryRefKind kind) {
  return switch (kind) {
    RepositoryRefKind.workspace => Icons.edit_note,
    RepositoryRefKind.localBranch => Icons.call_split,
    RepositoryRefKind.remoteBranch => Icons.cloud_outlined,
    RepositoryRefKind.tag => Icons.sell_outlined,
    RepositoryRefKind.stash => Icons.inventory_2_outlined,
  };
}

class _RefTile extends StatelessWidget {
  const _RefTile({
    required this.ref,
    required this.onTap,
    required this.contextItems,
    required this.onContextAction,
  });

  final RepositoryRefViewData ref;
  final VoidCallback? onTap;
  final List<_RefContextMenuItem> contextItems;
  final ValueChanged<RepositoryRefContextAction>? onContextAction;

  /// 中文：在指针位置显示引用的上下文菜单，并将选中动作交给上层应用执行。
  ///
  /// English: Shows this reference's context menu at the pointer position and
  /// forwards its selected action to the application layer.
  Future<void> _showContextMenu(
    BuildContext context,
    Offset globalPosition,
  ) async {
    final handler = onContextAction;
    if (handler == null || contextItems.isEmpty) return;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final selection = await showMenu<RepositoryRefContextAction>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        for (final item in contextItems)
          if (item.isDivider)
            const PopupMenuDivider()
          else
            PopupMenuItem<RepositoryRefContextAction>(
              value: item.action,
              enabled: item.enabled,
              child: Row(
                children: [
                  Icon(item.icon, size: 18),
                  const SizedBox(width: 10),
                  Text(item.label),
                ],
              ),
            ),
      ],
    );
    if (selection != null) handler(selection);
  }

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final String tracking = [
      if (ref.ahead > 0) '↑${ref.ahead}',
      if (ref.behind > 0) '↓${ref.behind}',
    ].join(' ');

    return Semantics(
      button: true,
      selected: ref.isSelected,
      label: '${_refKindLabel(ref.kind)} ${ref.label}',
      child: Tooltip(
        message: ref.secondaryLabel ?? ref.label,
        waitDuration: const Duration(milliseconds: 650),
        child: GestureDetector(
          onLongPressStart: (details) =>
              unawaited(_showContextMenu(context, details.globalPosition)),
          child: InkWell(
            onTap: onTap,
            onSecondaryTapDown: (details) =>
                unawaited(_showContextMenu(context, details.globalPosition)),
            child: Container(
              height: 31,
              padding: const EdgeInsets.only(left: 14, right: 8),
              color: ref.isSelected ? colors.secondaryContainer : null,
              child: Row(
                children: [
                  Icon(
                    ref.isCurrent
                        ? Icons.radio_button_checked
                        : _refKindIcon(ref.kind),
                    size: 15,
                    color: ref.isCurrent
                        ? colors.primary
                        : colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      ref.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: ref.isCurrent ? FontWeight.w600 : null,
                        color: ref.isSelected
                            ? colors.onSecondaryContainer
                            : null,
                      ),
                    ),
                  ),
                  if (tracking.isNotEmpty)
                    Text(
                      tracking,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colors.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    )
                  else if (ref.childCount case final int count)
                    Text(
                      '$count',
                      style: theme.textTheme.labelSmall?.copyWith(
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

const double _historyRowHeight = 26;

class _HistoryPane extends StatelessWidget {
  const _HistoryPane({required this.repository, required this.onSelected});

  final RepositoryViewData repository;
  final RepositoryCommitCallback? onSelected;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: _historyBackground(colors),
      child: Column(
        children: [
          _PaneHeader(
            title: '历史',
            icon: Icons.history,
            trailing: '${repository.commits.length} 个提交',
          ),
          const _HistoryColumnHeader(),
          Expanded(
            child: repository.commits.isEmpty
                ? const _PaneEmptyState(
                    icon: Icons.commit,
                    title: '暂无提交',
                    message: '空仓库的首次提交会显示在这里。',
                  )
                : ListView.builder(
                    itemExtent: _historyRowHeight,
                    itemCount: repository.commits.length,
                    itemBuilder: (BuildContext context, int index) {
                      final CommitViewData commit = repository.commits[index];
                      return _CommitRow(
                        commit: commit,
                        onTap: onSelected == null
                            ? null
                            : () => onSelected!(commit),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _HistoryColumnHeader extends StatelessWidget {
  const _HistoryColumnHeader();

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;

    return Container(
      height: 25,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(color: colors.outlineVariant),
          top: BorderSide(color: colors.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          const SizedBox(width: 96),
          Expanded(child: Text('描述', style: theme.textTheme.labelSmall)),
          SizedBox(
            width: 108,
            child: Text('作者', style: theme.textTheme.labelSmall),
          ),
          SizedBox(
            width: 86,
            child: Text(
              '日期',
              textAlign: TextAlign.end,
              style: theme.textTheme.labelSmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _CommitRow extends StatelessWidget {
  const _CommitRow({required this.commit, required this.onTap});

  final CommitViewData commit;
  final VoidCallback? onTap;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;

    return Semantics(
      button: true,
      selected: commit.isSelected,
      label:
          '${commit.subject}，${commit.author}，${commit.relativeDate}，提交 ${commit.shortOid}',
      child: Tooltip(
        message: '${commit.subject}\n${commit.oid}',
        waitDuration: const Duration(milliseconds: 750),
        child: InkWell(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: commit.isSelected ? colors.secondaryContainer : null,
              border: Border(
                bottom: BorderSide(
                  color: colors.outlineVariant.withValues(alpha: .5),
                ),
              ),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 96,
                  height: _historyRowHeight,
                  child: CustomPaint(
                    key: const ValueKey<String>('commit-graph-canvas'),
                    painter: _CommitGraphPainter(
                      graph: commit.graph,
                      colors: _graphColors(colors),
                      backgroundColor: _graphBackground(colors),
                      selected: commit.isSelected,
                    ),
                  ),
                ),
                Expanded(
                  child: Row(
                    children: [
                      if (commit.isMerge)
                        Padding(
                          padding: const EdgeInsets.only(right: 5),
                          child: Icon(
                            Icons.merge,
                            size: 13,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      Flexible(
                        child: Text(
                          commit.subject,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: commit.isHead ? FontWeight.w600 : null,
                          ),
                        ),
                      ),
                      for (final String ref in commit.refs.take(2))
                        Padding(
                          padding: const EdgeInsets.only(left: 5),
                          child: _RefLabel(label: ref),
                        ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 108,
                  child: Text(
                    commit.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
                SizedBox(
                  width: 86,
                  child: Text(
                    commit.relativeDate,
                    textAlign: TextAlign.end,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CommitGraphPainter extends CustomPainter {
  const _CommitGraphPainter({
    required this.graph,
    required this.colors,
    required this.backgroundColor,
    required this.selected,
  });

  final CommitGraphViewData graph;
  final List<Color> colors;
  final Color backgroundColor;
  final bool selected;

  static const double laneSpacing = 12;
  static const double laneStart = 22;

  /// 中文：按车道索引循环选择提交图颜色，支持负索引。
  ///
  /// English: Selects a commit-graph color cyclically by lane index, including
  /// negative indices.
  Color _color(int index) => colors[index.abs() % colors.length];

  /// 中文：将车道索引转换为图画布中的 X 坐标，并限制最大可见车道。
  ///
  /// English: Converts a lane index to a graph-canvas X coordinate while
  /// capping the number of visible lanes.
  double _laneX(int lane) => laneStart + lane.clamp(0, 4) * laneSpacing;

  /// 中文：在给定画布上绘制当前内容。
  /// English: Paints the current content onto the canvas.
  @override
  void paint(Canvas canvas, Size size) {
    final double centerY = size.height / 2;
    canvas.drawRect(Offset.zero & size, Paint()..color = backgroundColor);

    for (var index = 0; index < graph.activeLanes.length; index++) {
      final activeLane = graph.activeLanes[index];
      final destination = index < graph.activeLaneDestinations.length
          ? graph.activeLaneDestinations[index]
          : activeLane;
      _drawLaneConnection(
        canvas,
        fromLane: activeLane,
        toLane: destination,
        top: 0,
        centerY: centerY,
        bottom: size.height,
        color: _color(activeLane),
      );
    }

    final int colorIndex = graph.colorIndex;
    for (final parentLane in graph.parentLanes.skip(1)) {
      _drawLaneConnection(
        canvas,
        fromLane: graph.lane,
        toLane: parentLane,
        top: centerY,
        centerY: centerY,
        bottom: size.height,
        color: _color(colorIndex),
      );
    }

    final Paint dotPaint = Paint()
      ..color = _color(colorIndex)
      ..style = PaintingStyle.fill;
    if (selected) {
      canvas.drawCircle(
        Offset(_laneX(graph.lane), centerY),
        5.5,
        Paint()
          ..color = const Color(0xFFFFFFFF).withValues(alpha: .9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }
    canvas.drawCircle(Offset(_laneX(graph.lane), centerY), 4.5, dotPaint);
  }

  /// 中文：以固定 3 像素宽度绘制车道的竖直连接线。
  ///
  /// English: Draws a lane's vertical connection rail at a fixed 3-pixel
  /// width.
  void _drawVerticalRail(
    Canvas canvas, {
    required double x,
    required double top,
    required double bottom,
    required Color color,
  }) {
    canvas.drawRect(
      Rect.fromLTRB(x - 1.5, top, x + 1.5, bottom),
      Paint()..color = color,
    );
  }

  /// 中文：绘制车道在当前行前后延续或转向目标父提交车道的连接路径。
  ///
  /// English: Draws a lane connection that continues through the row or turns
  /// toward a target parent lane.
  void _drawLaneConnection(
    Canvas canvas, {
    required int fromLane,
    required int? toLane,
    required double top,
    required double centerY,
    required double bottom,
    required Color color,
  }) {
    final sourceX = _laneX(fromLane);
    _drawVerticalRail(
      canvas,
      x: sourceX,
      top: top,
      bottom: centerY,
      color: color,
    );
    if (toLane == null) return;
    final targetX = _laneX(toLane);
    final turnY = centerY + (bottom - centerY) * .44;
    _drawVerticalRail(
      canvas,
      x: sourceX,
      top: centerY,
      bottom: turnY,
      color: color,
    );
    canvas.drawRect(
      Rect.fromLTRB(
        math.min(sourceX, targetX),
        turnY - 1.5,
        math.max(sourceX, targetX),
        turnY + 1.5,
      ),
      Paint()..color = color,
    );
    _drawVerticalRail(
      canvas,
      x: targetX,
      top: turnY,
      bottom: bottom,
      color: color,
    );
  }

  /// 中文：判断绘制结果是否需要刷新。
  /// English: Determines whether the painting needs refreshing.
  @override
  bool shouldRepaint(_CommitGraphPainter oldDelegate) {
    return oldDelegate.graph != graph ||
        oldDelegate.selected != selected ||
        oldDelegate.colors != colors ||
        oldDelegate.backgroundColor != backgroundColor;
  }
}

/// 中文：返回历史列表使用的深色背景色。
///
/// English: Returns the dark background color used by the history list.
Color _historyBackground(ColorScheme colors) => const Color(0xFF242D30);

/// 中文：返回提交图背景色，使其与历史列表保持一致。
///
/// English: Returns the commit-graph background color, matching the history
/// list.
Color _graphBackground(ColorScheme colors) => _historyBackground(colors);

/// 中文：返回用于区分提交图车道的固定高对比度颜色序列。
///
/// English: Returns the fixed, high-contrast color sequence used to
/// distinguish commit-graph lanes.
List<Color> _graphColors(ColorScheme colors) => const [
  Color(0xFF087FCD),
  Color(0xFFFF6500),
  Color(0xFFAE76E8),
  Color(0xFF2FA86F),
  Color(0xFFDBA70A),
];

class _RefLabel extends StatelessWidget {
  const _RefLabel({required this.label});

  final String label;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(maxWidth: 100),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: colors.tertiaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: colors.onTertiaryContainer,
          fontSize: 10,
        ),
      ),
    );
  }
}

class _SelectedChangesPane extends StatelessWidget {
  const _SelectedChangesPane({
    required this.repository,
    required this.onSelected,
    required this.onStageToggled,
    required this.onCommitFileSelected,
  });

  final RepositoryViewData repository;
  final RepositoryChangeCallback? onSelected;
  final RepositoryChangeStageCallback? onStageToggled;
  final RepositoryCommitFileCallback? onCommitFileSelected;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    if (repository.selectedCommit != null) {
      return _CommitChangesPane(
        repository: repository,
        onSelected: onCommitFileSelected,
      );
    }
    return _ChangesPane(
      repository: repository,
      onSelected: onSelected,
      onStageToggled: onStageToggled,
    );
  }
}

class _CommitChangesPane extends StatelessWidget {
  const _CommitChangesPane({
    required this.repository,
    required this.onSelected,
  });

  final RepositoryViewData repository;
  final RepositoryCommitFileCallback? onSelected;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final files = repository.commitChanges;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          _PaneHeader(
            title: '提交改动',
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
                        onSelected: onSelected,
                      );
                      if (constraints.maxWidth < 530) {
                        return repository.selectedCommitFile == null
                            ? list
                            : _DiffPreview(
                                diff: repository.commitDiff,
                                onBack: onSelected == null
                                    ? null
                                    : () => onSelected!(null),
                              );
                      }
                      return Row(
                        children: [
                          SizedBox(
                            width: math.min(286, constraints.maxWidth * .38),
                            child: list,
                          ),
                          VerticalDivider(
                            width: 1,
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                          Expanded(
                            child: _DiffPreview(diff: repository.commitDiff),
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
  const _CommitFileList({required this.files, required this.onSelected});

  final List<CommitFileViewData> files;
  final RepositoryCommitFileCallback? onSelected;

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
      itemExtent: 34,
      itemCount: files.length,
      itemBuilder: (context, index) => _CommitFileTile(
        file: files[index],
        onTap: onSelected == null ? null : () => onSelected!(files[index]),
      ),
    );
  }
}

class _CommitFileTile extends StatelessWidget {
  const _CommitFileTile({required this.file, required this.onTap});

  final CommitFileViewData file;
  final VoidCallback? onTap;

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
    return Semantics(
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
    );
  }
}

class _ChangesPane extends StatelessWidget {
  const _ChangesPane({
    required this.repository,
    required this.onSelected,
    required this.onStageToggled,
  });

  final RepositoryViewData repository;
  final RepositoryChangeCallback? onSelected;
  final RepositoryChangeStageCallback? onStageToggled;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          _PaneHeader(
            title: '文件状态',
            icon: Icons.difference_outlined,
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
                          onSelected: onSelected,
                          onStageToggled: onStageToggled,
                        )
                      : _DiffPreview(
                          diff: repository.diff,
                          onBack: onSelected == null
                              ? null
                              : () => onSelected!(null),
                        );
                }
                return Row(
                  children: [
                    SizedBox(
                      width: math.min(286, constraints.maxWidth * .38),
                      child: _ChangeList(
                        changes: repository.changes,
                        onSelected: onSelected,
                        onStageToggled: onStageToggled,
                      ),
                    ),
                    VerticalDivider(
                      width: 1,
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                    Expanded(child: _DiffPreview(diff: repository.diff)),
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

class _ChangeList extends StatelessWidget {
  const _ChangeList({
    required this.changes,
    required this.onSelected,
    required this.onStageToggled,
  });

  final List<RepositoryChangeViewData> changes;
  final RepositoryChangeCallback? onSelected;
  final RepositoryChangeStageCallback? onStageToggled;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    if (changes.isEmpty) {
      return const _PaneEmptyState(
        icon: Icons.task_alt,
        title: '工作区干净',
        message: '没有需要提交的文件改动。',
      );
    }

    return ListView.builder(
      itemExtent: 34,
      itemCount: changes.length,
      itemBuilder: (BuildContext context, int index) {
        final RepositoryChangeViewData change = changes[index];
        return _ChangeTile(
          change: change,
          onTap: onSelected == null ? null : () => onSelected!(change),
          onStageToggled: onStageToggled == null
              ? null
              : () => onStageToggled!(change),
        );
      },
    );
  }
}

class _ChangeTile extends StatelessWidget {
  const _ChangeTile({
    required this.change,
    required this.onTap,
    required this.onStageToggled,
  });

  final RepositoryChangeViewData change;
  final VoidCallback? onTap;
  final VoidCallback? onStageToggled;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final String fileName = change.path.split('/').last;
    final int slash = change.path.lastIndexOf('/');
    final String parentPath = slash <= 0 ? '' : change.path.substring(0, slash);
    final String stats = [
      if (change.additions case final int value) '+$value',
      if (change.deletions case final int value) '−$value',
    ].join(' ');

    return Semantics(
      button: true,
      selected: change.isSelected,
      label:
          '${change.isStaged ? "已暂存" : "未暂存"}，${_changeKindLabel(change.kind)}，${change.path}',
      child: Tooltip(
        message: change.path,
        waitDuration: const Duration(milliseconds: 650),
        child: InkWell(
          onTap: onTap,
          child: Container(
            color: change.isSelected ? colors.secondaryContainer : null,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
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
                          style: theme.textTheme.bodySmall,
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
                              color: colors.onSurfaceVariant,
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
                      color: colors.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                Tooltip(
                  message: !change.canToggleStage
                      ? '冲突或无法安全表示的文件名不能在此暂存'
                      : change.isStaged
                      ? '取消暂存 ${change.path}'
                      : '暂存 ${change.path}',
                  child: IconButton(
                    onPressed: onStageToggled == null || !change.canToggleStage
                        ? null
                        : onStageToggled,
                    icon: Icon(
                      change.isStaged
                          ? Icons.check_box
                          : Icons.check_box_outline_blank,
                      size: 17,
                    ),
                    color: change.isStaged
                        ? colors.primary
                        : colors.onSurfaceVariant,
                    disabledColor: colors.onSurface.withValues(alpha: .32),
                    iconSize: 17,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 30,
                      height: 30,
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

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
      RepositoryChangeKind.added => ('A', colors.tertiary),
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

class _DiffPreview extends StatelessWidget {
  const _DiffPreview({required this.diff, this.onBack});

  final DiffViewData diff;
  final VoidCallback? onBack;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    if (diff.path == null) {
      return const _PaneEmptyState(
        icon: Icons.article_outlined,
        title: '选择文件以查看差异',
        message: '差异内容将在此处显示。',
      );
    }
    if (diff.isBinary || diff.isTooLarge) {
      return _PaneEmptyState(
        icon: diff.isBinary ? Icons.data_object : Icons.warning_amber,
        title: diff.isBinary ? '二进制文件' : '文件过大',
        message:
            diff.notice ??
            (diff.isBinary ? '此文件无法显示文本差异。' : '为保持界面响应，已跳过差异预览。'),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 27,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: colors.surfaceContainerLow,
            border: Border(bottom: BorderSide(color: colors.outlineVariant)),
          ),
          child: Row(
            children: [
              if (onBack != null) ...[
                Tooltip(
                  message: '返回文件列表',
                  child: InkWell(
                    onTap: onBack,
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
                  diff.path!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(fontFamily: 'monospace'),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: diff.lines.isEmpty
              ? const _PaneEmptyState(
                  icon: Icons.horizontal_rule,
                  title: '没有文本差异',
                  message: 'Git 没有返回可显示的补丁。',
                )
              : ListView.builder(
                  itemExtent: 20,
                  itemCount: diff.lines.length,
                  itemBuilder: (BuildContext context, int index) {
                    return _DiffLine(line: diff.lines[index]);
                  },
                ),
        ),
      ],
    );
  }
}

class _DiffLine extends StatelessWidget {
  const _DiffLine({required this.line});

  final DiffLineViewData line;

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
      color: background,
      child: Row(
        children: [
          _LineNumber(value: line.oldLineNumber),
          _LineNumber(value: line.newLineNumber),
          Expanded(
            child: Text(
              line.text,
              maxLines: 1,
              overflow: TextOverflow.clip,
              softWrap: false,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: foreground,
                fontFamily: 'monospace',
                fontSize: 11,
                height: 1.45,
              ),
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

class _CommitDetailsPane extends StatelessWidget {
  const _CommitDetailsPane({required this.details});

  final CommitDetailsViewData? details;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final CommitDetailsViewData? details = this.details;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      child: Column(
        children: [
          const _PaneHeader(title: '提交详情', icon: Icons.info_outline),
          Expanded(
            child: details == null
                ? const _PaneEmptyState(
                    icon: Icons.commit,
                    title: '选择一个提交',
                    message: '作者、提交信息和统计会显示在这里。',
                  )
                : _CommitDetailsContent(details: details),
          ),
        ],
      ),
    );
  }
}

class _CommitDetailsContent extends StatelessWidget {
  const _CommitDetailsContent({required this.details});

  final CommitDetailsViewData details;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;

    return SelectionArea(
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          Text(
            details.subject,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
          ),
          if (details.refs.isNotEmpty) ...[
            const SizedBox(height: 9),
            Wrap(
              spacing: 5,
              runSpacing: 5,
              children: [
                for (final String ref in details.refs) _RefLabel(label: ref),
              ],
            ),
          ],
          const SizedBox(height: 13),
          _MetadataRow(
            label: '作者',
            value: details.authorEmail == null
                ? details.author
                : '${details.author} <${details.authorEmail}>',
          ),
          _MetadataRow(label: '日期', value: details.authoredAt),
          _MetadataRow(label: '提交', value: details.oid, monospace: true),
          if (details.parents.isNotEmpty)
            _MetadataRow(
              label: '父级',
              value: details.parents.join('\n'),
              monospace: true,
            ),
          if (details.body?.trim().isNotEmpty ?? false) ...[
            const SizedBox(height: 12),
            Divider(color: colors.outlineVariant),
            const SizedBox(height: 7),
            Text(
              details.body!,
              style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
            ),
          ],
          const SizedBox(height: 14),
          Divider(color: colors.outlineVariant),
          const SizedBox(height: 8),
          Wrap(
            spacing: 13,
            runSpacing: 6,
            children: [
              _StatLabel(
                icon: Icons.description_outlined,
                value: '${details.changedFiles} 个文件',
                color: colors.onSurfaceVariant,
              ),
              _StatLabel(
                icon: Icons.add,
                value: '+${details.additions}',
                color: colors.tertiary,
              ),
              _StatLabel(
                icon: Icons.remove,
                value: '−${details.deletions}',
                color: colors.error,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MetadataRow extends StatelessWidget {
  const _MetadataRow({
    required this.label,
    required this.value,
    this.monospace = false,
  });

  final String label;
  final String value;
  final bool monospace;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 38,
            child: Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.labelSmall?.copyWith(
                fontFamily: monospace ? 'monospace' : null,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatLabel extends StatelessWidget {
  const _StatLabel({
    required this.icon,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String value;
  final Color color;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 3),
        Text(
          value,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
        ),
      ],
    );
  }
}

class _TabbedInspector extends StatelessWidget {
  const _TabbedInspector({
    required this.selectedTab,
    required this.onTabChanged,
    required this.repository,
    required this.onChangeSelected,
    required this.onChangeStageToggled,
    required this.onCommitFileSelected,
  });

  final _InspectorTab selectedTab;
  final ValueChanged<_InspectorTab> onTabChanged;
  final RepositoryViewData repository;
  final RepositoryChangeCallback? onChangeSelected;
  final RepositoryChangeStageCallback? onChangeStageToggled;
  final RepositoryCommitFileCallback? onCommitFileSelected;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _DenseTabBar<_InspectorTab>(
          selected: selectedTab,
          tabs: const {
            _InspectorTab.changes: ('文件状态', Icons.difference_outlined),
            _InspectorTab.details: ('提交详情', Icons.info_outline),
          },
          onSelected: onTabChanged,
        ),
        Expanded(
          child: switch (selectedTab) {
            _InspectorTab.changes => _SelectedChangesPane(
              repository: repository,
              onSelected: onChangeSelected,
              onStageToggled: onChangeStageToggled,
              onCommitFileSelected: onCommitFileSelected,
            ),
            _InspectorTab.details => _CommitDetailsPane(
              details: repository.selectedCommit,
            ),
          },
        ),
      ],
    );
  }
}

class _CompactPaneSwitcher extends StatelessWidget {
  const _CompactPaneSwitcher({
    required this.selected,
    required this.onSelected,
    required this.changeCount,
  });

  final _CompactPane selected;
  final ValueChanged<_CompactPane> onSelected;
  final int changeCount;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    return _DenseTabBar<_CompactPane>(
      selected: selected,
      tabs: {
        _CompactPane.refs: const ('引用', Icons.account_tree_outlined),
        _CompactPane.history: const ('历史', Icons.history),
        _CompactPane.changes: (
          changeCount > 0 ? '改动 $changeCount' : '改动',
          Icons.difference_outlined,
        ),
        _CompactPane.details: const ('详情', Icons.info_outline),
      },
      onSelected: onSelected,
    );
  }
}

class _DenseTabBar<T> extends StatelessWidget {
  const _DenseTabBar({
    required this.selected,
    required this.tabs,
    required this.onSelected,
  });

  final T selected;
  final Map<T, (String, IconData)> tabs;
  final ValueChanged<T> onSelected;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerLow,
      child: Container(
        height: 37,
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: colors.outlineVariant)),
        ),
        child: Row(
          children: [
            for (final MapEntry<T, (String, IconData)> tab in tabs.entries)
              Expanded(
                child: Semantics(
                  button: true,
                  selected: selected == tab.key,
                  label: tab.value.$1,
                  child: InkWell(
                    onTap: () => onSelected(tab.key),
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            width: 2,
                            color: selected == tab.key
                                ? colors.primary
                                : Colors.transparent,
                          ),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(tab.value.$2, size: 15),
                          const SizedBox(width: 5),
                          Flexible(
                            child: Text(
                              tab.value.$1,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelMedium,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PaneHeader extends StatelessWidget {
  const _PaneHeader({required this.title, required this.icon, this.trailing});

  final String title;
  final IconData icon;
  final String? trailing;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: colors.outlineVariant)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: colors.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            title,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          if (trailing != null)
            Text(
              trailing!,
              style: theme.textTheme.labelSmall?.copyWith(
                color: colors.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.count});

  final String title;
  final int count;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                color: colors.onSurfaceVariant,
                fontWeight: FontWeight.w700,
                letterSpacing: .55,
              ),
            ),
          ),
          Text(
            '$count',
            style: theme.textTheme.labelSmall?.copyWith(
              color: colors.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _PaneEmptyState extends StatelessWidget {
  const _PaneEmptyState({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 28, color: colors.onSurfaceVariant),
            const SizedBox(height: 9),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RepositoryStatusBar extends StatelessWidget {
  const _RepositoryStatusBar({required this.data, this.onAction});

  final RepositoryFooterViewData data;
  final RepositoryActionCallback? onAction;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final bool isRunning = data.operationLabel != null;

    return Semantics(
      liveRegion: isRunning || data.hasWarnings,
      label: data.operationLabel ?? data.message,
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          border: Border(top: BorderSide(color: colors.outlineVariant)),
        ),
        child: Row(
          children: [
            if (isRunning) ...[
              SizedBox.square(
                dimension: 13,
                child: CircularProgressIndicator(
                  strokeWidth: 1.7,
                  value: data.operationProgress,
                ),
              ),
              const SizedBox(width: 7),
            ] else
              Icon(
                data.hasWarnings
                    ? Icons.warning_amber_rounded
                    : Icons.check_circle_outline,
                size: 14,
                color: data.hasWarnings
                    ? colors.error
                    : colors.onSurfaceVariant,
              ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                data.operationLabel ?? data.message,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall,
              ),
            ),
            if (data.operations.isNotEmpty)
              IconButton(
                onPressed: onAction == null
                    ? null
                    : () => onAction!(RepositoryAction.showOperationLog),
                icon: const Icon(Icons.receipt_long_outlined, size: 17),
                tooltip: '查看操作日志',
                visualDensity: VisualDensity.compact,
              ),
            if (data.gitVersion != null)
              Text(
                data.gitVersion!,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ResizeDivider extends StatelessWidget {
  const _ResizeDivider({
    required this.axis,
    required this.semanticsLabel,
    required this.onDelta,
  });

  final Axis axis;
  final String semanticsLabel;
  final ValueChanged<double> onDelta;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final Color dividerColor = Theme.of(context).colorScheme.outlineVariant;
    final bool vertical = axis == Axis.vertical;

    return Semantics(
      label: semanticsLabel,
      slider: true,
      child: MouseRegion(
        cursor: vertical
            ? SystemMouseCursors.resizeColumn
            : SystemMouseCursors.resizeRow,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragUpdate: vertical
              ? (DragUpdateDetails details) => onDelta(details.delta.dx)
              : null,
          onVerticalDragUpdate: vertical
              ? null
              : (DragUpdateDetails details) => onDelta(details.delta.dy),
          child: Container(
            width: vertical ? 5 : double.infinity,
            height: vertical ? double.infinity : 5,
            alignment: Alignment.center,
            child: Container(
              width: vertical ? 1 : double.infinity,
              height: vertical ? double.infinity : 1,
              color: dividerColor,
            ),
          ),
        ),
      ),
    );
  }
}

class _NoRepositoryView extends StatelessWidget {
  const _NoRepositoryView({required this.data, required this.onAction});

  final RepositoryOverviewViewData data;
  final RepositoryActionCallback? onAction;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    return _StandaloneStateView(
      icon: Icons.account_tree_outlined,
      title: data.title ?? '开始使用 Git 仓库',
      message: data.message ?? '打开现有仓库、克隆远端项目，或创建一个新仓库。',
      actions: [
        _StateAction(
          label: '打开仓库',
          icon: Icons.folder_open,
          action: RepositoryAction.openRepository,
          primary: true,
        ),
        _StateAction(
          label: '克隆仓库',
          icon: Icons.download_outlined,
          action: RepositoryAction.cloneRepository,
        ),
        _StateAction(
          label: '初始化仓库',
          icon: Icons.create_new_folder_outlined,
          action: RepositoryAction.initializeRepository,
        ),
      ],
      onAction: onAction,
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView({required this.data, required this.onAction});

  final RepositoryOverviewViewData data;
  final RepositoryActionCallback? onAction;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    return _StandaloneStateView(
      progress: true,
      icon: Icons.folder_open_outlined,
      title: data.title ?? '正在读取仓库',
      message: data.message ?? '正在识别仓库并加载状态与提交历史…',
      actions: [
        if (data.canCancelOperation)
          const _StateAction(
            label: '取消克隆',
            icon: Icons.cancel_outlined,
            action: RepositoryAction.cancelClone,
          ),
      ],
      onAction: onAction,
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.data, required this.onAction});

  final RepositoryOverviewViewData data;
  final RepositoryActionCallback? onAction;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final String technicalDetails = data.technicalDetails?.trim() ?? '';
    return _StandaloneStateView(
      icon: Icons.error_outline,
      title: data.title ?? '无法打开仓库',
      message: data.message ?? '读取仓库时发生错误。',
      details: technicalDetails.isEmpty ? null : technicalDetails,
      actions: const [
        _StateAction(
          label: '重试',
          icon: Icons.refresh,
          action: RepositoryAction.retry,
          primary: true,
        ),
        _StateAction(
          label: '选择其他仓库',
          icon: Icons.folder_open,
          action: RepositoryAction.openRepository,
        ),
      ],
      onAction: onAction,
    );
  }
}

class _StateAction {
  const _StateAction({
    required this.label,
    required this.icon,
    required this.action,
    this.primary = false,
  });

  final String label;
  final IconData icon;
  final RepositoryAction action;
  final bool primary;
}

class _StandaloneStateView extends StatelessWidget {
  const _StandaloneStateView({
    required this.icon,
    required this.title,
    required this.message,
    required this.actions,
    this.details,
    this.progress = false,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? details;
  final bool progress;
  final List<_StateAction> actions;
  final RepositoryActionCallback? onAction;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;

    return ColoredBox(
      color: colors.surface,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Semantics(
                liveRegion: progress,
                child: Card(
                  elevation: 0,
                  color: colors.surfaceContainerLow,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: colors.outlineVariant),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (progress)
                          const SizedBox.square(
                            dimension: 34,
                            child: CircularProgressIndicator(strokeWidth: 3),
                          )
                        else
                          Container(
                            width: 54,
                            height: 54,
                            decoration: BoxDecoration(
                              color: colors.primaryContainer,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Icon(
                              icon,
                              size: 28,
                              color: colors.onPrimaryContainer,
                            ),
                          ),
                        const SizedBox(height: 18),
                        Text(
                          title,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          message,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                            height: 1.45,
                          ),
                        ),
                        if (details != null) ...[
                          const SizedBox(height: 14),
                          Container(
                            width: double.infinity,
                            constraints: const BoxConstraints(maxHeight: 120),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: colors.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(7),
                            ),
                            child: SelectionArea(
                              child: SingleChildScrollView(
                                child: Text(
                                  details!,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                        if (actions.isNotEmpty) ...[
                          const SizedBox(height: 22),
                          Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 9,
                            runSpacing: 9,
                            children: [
                              for (final _StateAction action in actions)
                                action.primary
                                    ? FilledButton.icon(
                                        onPressed: onAction == null
                                            ? null
                                            : () => onAction!(action.action),
                                        icon: Icon(action.icon, size: 18),
                                        label: Text(action.label),
                                      )
                                    : OutlinedButton.icon(
                                        onPressed: onAction == null
                                            ? null
                                            : () => onAction!(action.action),
                                        icon: Icon(action.icon, size: 18),
                                        label: Text(action.label),
                                      ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StaleDataLoadingOverlay extends StatelessWidget {
  const _StaleDataLoadingOverlay();

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    return const Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: LinearProgressIndicator(minHeight: 2),
    );
  }
}

class _StaleDataErrorBanner extends StatelessWidget {
  const _StaleDataErrorBanner({required this.message, required this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Positioned(
      left: 10,
      right: 10,
      top: 8,
      child: Material(
        color: colors.errorContainer,
        elevation: 2,
        borderRadius: BorderRadius.circular(8),
        child: Semantics(
          liveRegion: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              children: [
                Icon(
                  Icons.error_outline,
                  size: 17,
                  color: colors.onErrorContainer,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    message,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.onErrorContainer,
                    ),
                  ),
                ),
                TextButton(onPressed: onRetry, child: const Text('重试')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
