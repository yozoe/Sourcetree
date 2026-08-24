import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models/repository_overview_view_data.dart';

export 'models/repository_overview_view_data.dart';

typedef RepositoryActionCallback = void Function(RepositoryAction action);
typedef RepositoryRefCallback = void Function(RepositoryRefViewData ref);
typedef RepositoryRefContextActionCallback =
    void Function(RepositoryRefViewData ref, RepositoryRefContextAction action);
typedef RepositoryCommitCallback = void Function(CommitViewData commit);
typedef RepositoryCommitActivationCallback =
    void Function(CommitViewData commit);
typedef RepositoryCommitContextActionCallback =
    void Function(CommitViewData commit, RepositoryCommitContextAction action);
typedef RepositoryChangeCallback =
    void Function(RepositoryChangeViewData? change);
typedef RepositoryUncommittedChangesCallback = FutureOr<void> Function();
typedef RepositoryChangeStageCallback =
    void Function(RepositoryChangeViewData change);
typedef RepositoryChangeFilesCallback =
    FutureOr<void> Function(List<RepositoryChangeViewData> changes);
typedef RepositoryChangeGroupStageCallback =
    FutureOr<void> Function(List<RepositoryChangeViewData> changes, bool stage);
typedef RepositoryConflictActionCallback =
    void Function(
      RepositoryChangeViewData change,
      RepositoryConflictAction action,
    );
typedef RepositoryCommitFileCallback = void Function(CommitFileViewData? file);

/// Interaction surface for [RepositoryOverview].
///
/// Callbacks are intentionally event-only: Git execution, confirmation and
/// state changes stay in the application layer.
final class RepositoryOverviewCallbacks {
  const RepositoryOverviewCallbacks({
    this.onAction,
    this.onSearchChanged,
    this.onLoadMoreHistory,
    this.onRefSelected,
    this.onRefActivated,
    this.onRefContextAction,
    this.onCommitSelected,
    this.onCommitActivated,
    this.onCommitContextAction,
    this.onUncommittedChangesSelected,
    this.onChangeSelected,
    this.onChangeStageToggled,
    this.onChangeGroupStageToggled,
    this.onConflictAction,
    this.onChangeRevealInFinder,
    this.onChangeRemove,
    this.onCommitFileSelected,
    this.onLayoutChanged,
  });

  final RepositoryActionCallback? onAction;
  final ValueChanged<String>? onSearchChanged;
  final VoidCallback? onLoadMoreHistory;
  final RepositoryRefCallback? onRefSelected;
  final RepositoryRefCallback? onRefActivated;
  final RepositoryRefContextActionCallback? onRefContextAction;
  final RepositoryCommitCallback? onCommitSelected;
  final RepositoryCommitActivationCallback? onCommitActivated;
  final RepositoryCommitContextActionCallback? onCommitContextAction;
  final RepositoryUncommittedChangesCallback? onUncommittedChangesSelected;
  final RepositoryChangeCallback? onChangeSelected;
  final RepositoryChangeStageCallback? onChangeStageToggled;
  final RepositoryChangeGroupStageCallback? onChangeGroupStageToggled;
  final RepositoryConflictActionCallback? onConflictAction;
  final RepositoryChangeFilesCallback? onChangeRevealInFinder;
  final RepositoryChangeFilesCallback? onChangeRemove;
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
  String? _selectedRefId;

  /// 中文：响应上层组件配置更新。
  /// English: Responds to updated widget configuration.
  @override
  void didUpdateWidget(RepositoryOverview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialLayout != widget.initialLayout) {
      _layout = widget.initialLayout;
    }
    final previousRepository = oldWidget.data.repository;
    final repository = widget.data.repository;
    final previousModelSelection = previousRepository?.refs
        .where((ref) => ref.isSelected)
        .firstOrNull
        ?.id;
    final modelSelection = repository?.refs
        .where((ref) => ref.isSelected)
        .firstOrNull
        ?.id;
    if (previousRepository?.path != repository?.path ||
        previousModelSelection != modelSelection ||
        (repository != null &&
            _selectedRefId != null &&
            !repository.refs.any((ref) => ref.id == _selectedRefId))) {
      _selectedRefId = modelSelection;
    }
  }

  /// 中文：仅更新引用列表的选中态，不触发分支切换。
  /// English: Updates only the selected ref without switching branches. The
  /// stash root requests creation, while an individual stash selects its
  /// persistent workspace preview on every enabled activation.
  void _selectReference(RepositoryRefViewData reference) {
    if (reference.kind == RepositoryRefKind.stash) {
      setState(() {
        _selectedRefId = reference.id;
        if (reference.stashReference != null) {
          _compactPane = _CompactPane.changes;
        }
      });
      widget.callbacks.onRefSelected?.call(reference);
      return;
    }
    if (_selectedRefId == reference.id) return;
    setState(() => _selectedRefId = reference.id);
    widget.callbacks.onRefSelected?.call(reference);
  }

  /// 中文：双击激活引用，并将切换意图交给应用层。
  /// English: Activates a ref on double-click and delegates switching.
  void _activateReference(RepositoryRefViewData reference) {
    if (_selectedRefId != reference.id) {
      setState(() => _selectedRefId = reference.id);
    }
    widget.callbacks.onRefActivated?.call(reference);
  }

  /// 中文：选中历史顶部的未提交改动行，并保留提交图与下方改动面板。
  ///
  /// English: Selects the synthetic uncommitted row while keeping the history
  /// graph and the lower changes pane visible.
  void _selectUncommittedChanges() {
    widget.callbacks.onUncommittedChangesSelected?.call();
  }

  /// 中文：更新可调整面板的布局并通知上层回调保存新尺寸。
  ///
  /// English: Updates the resizable-pane layout and notifies the parent
  /// callback so the new dimensions can be retained.
  void _updateLayout(RepositoryOverviewLayout next) {
    setState(() => _layout = next);
    widget.callbacks.onLayoutChanged?.call(next);
  }

  /// 中文：判断当前是否正在预览左侧选中的单条贮藏。
  /// English: Returns whether the workspace is previewing one selected stash.
  bool _isStashPreview(RepositoryViewData repository) => repository.refs.any(
    (reference) => reference.stashReference != null && reference.isSelected,
  );

  /// 中文：构建占满引用导航右侧的贮藏文件与 Diff 预览。
  /// English: Builds the stash file and Diff preview across the full workspace
  /// area to the right of the refs navigation.
  Widget _buildStashPreview(RepositoryViewData repository) =>
      _CommitChangesPane(
        repository: repository,
        onSelected: widget.callbacks.onCommitFileSelected,
        title: '贮藏改动',
      );

  /// 中文：构建占满引用导航右侧的工作区文件状态与提交入口。
  /// English: Builds the working-tree file status and commit entry across the
  /// full workspace area to the right of the refs navigation.
  Widget _buildWorkspacePreview(RepositoryViewData repository) =>
      _WorkspaceChangesView(
        repository: repository,
        onSelected: widget.callbacks.onChangeSelected,
        onStageToggled: widget.callbacks.onChangeStageToggled,
        onGroupStageToggled: widget.callbacks.onChangeGroupStageToggled,
        onConflictAction: widget.callbacks.onConflictAction,
        onRevealInFinder: widget.callbacks.onChangeRevealInFinder,
        onRemove: widget.callbacks.onChangeRemove,
        onCommit: widget.callbacks.onAction == null
            ? null
            : () => widget.callbacks.onAction!(RepositoryAction.commit),
      );

  /// 中文：判断当前是否正在查看工作区文件状态。
  /// English: Returns whether the workspace file-status ref is selected.
  bool _isWorkspacePreview(RepositoryViewData repository) => repository.refs
      .any((reference) => reference.id == 'workspace' && reference.isSelected);

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
            if (widget.data.state == RepositoryOverviewState.error)
              _StaleDataErrorBanner(
                message: widget.data.message ?? '刷新仓库失败',
                onRetry: widget.callbacks.onAction == null
                    ? null
                    : () => widget.callbacks.onAction!(RepositoryAction.retry),
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
            selectedRefId: _selectedRefId,
            onSelected: _selectReference,
            onActivated: _activateReference,
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
          child: _isStashPreview(repository)
              ? _buildStashPreview(repository)
              : _isWorkspacePreview(repository)
              ? _buildWorkspacePreview(repository)
              : Column(
                  children: [
                    Expanded(
                      child: _HistoryPane(
                        repository: repository,
                        onLoadMore: widget.callbacks.onLoadMoreHistory,
                        onSelected: widget.callbacks.onCommitSelected,
                        onActivated: widget.callbacks.onCommitActivated,
                        onContextAction: widget.callbacks.onCommitContextAction,
                        onUncommittedChangesSelected: _selectUncommittedChanges,
                      ),
                    ),
                    _HistorySplitBar(
                      query: repository.searchQuery,
                      onSearchChanged: widget.callbacks.onSearchChanged,
                      semanticsLabel: '调整改动面板高度',
                      onDelta: (double delta) => _updateLayout(
                        _layout.copyWith(changesHeight: changesHeight - delta),
                      ),
                    ),
                    SizedBox(
                      height: changesHeight,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: _SelectedChangesPane(
                              repository: repository,
                              onSelected: widget.callbacks.onChangeSelected,
                              onStageToggled:
                                  widget.callbacks.onChangeStageToggled,
                              onGroupStageToggled:
                                  widget.callbacks.onChangeGroupStageToggled,
                              onConflictAction:
                                  widget.callbacks.onConflictAction,
                              onRevealInFinder:
                                  widget.callbacks.onChangeRevealInFinder,
                              onRemove: widget.callbacks.onChangeRemove,
                              onCommitFileSelected:
                                  widget.callbacks.onCommitFileSelected,
                            ),
                          ),
                          _ResizeDivider(
                            axis: Axis.vertical,
                            semanticsLabel: '调整提交详情宽度',
                            onDelta: (double delta) => _updateLayout(
                              _layout.copyWith(
                                detailsWidth: detailsWidth - delta,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: detailsWidth,
                            child: _CommitDetailsPane(
                              details: repository.selectedCommit,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
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
            selectedRefId: _selectedRefId,
            onSelected: _selectReference,
            onActivated: _activateReference,
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
          child: _isStashPreview(repository)
              ? _buildStashPreview(repository)
              : _isWorkspacePreview(repository)
              ? _buildWorkspacePreview(repository)
              : Column(
                  children: [
                    Expanded(
                      child: _HistoryPane(
                        repository: repository,
                        onLoadMore: widget.callbacks.onLoadMoreHistory,
                        onSelected: widget.callbacks.onCommitSelected,
                        onActivated: widget.callbacks.onCommitActivated,
                        onContextAction: widget.callbacks.onCommitContextAction,
                        onUncommittedChangesSelected: _selectUncommittedChanges,
                      ),
                    ),
                    _HistorySplitBar(
                      query: repository.searchQuery,
                      onSearchChanged: widget.callbacks.onSearchChanged,
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
                        onChangeStageToggled:
                            widget.callbacks.onChangeStageToggled,
                        onChangeGroupStageToggled:
                            widget.callbacks.onChangeGroupStageToggled,
                        onConflictAction: widget.callbacks.onConflictAction,
                        onRevealInFinder:
                            widget.callbacks.onChangeRevealInFinder,
                        onRemove: widget.callbacks.onChangeRemove,
                        onCommitFileSelected:
                            widget.callbacks.onCommitFileSelected,
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
    if (_isWorkspacePreview(repository)) {
      return _buildWorkspacePreview(repository);
    }
    final Widget pane = switch (_compactPane) {
      _CompactPane.refs => _RefsNavigation(
        repository: repository,
        selectedRefId: _selectedRefId,
        onSelected: _selectReference,
        onActivated: _activateReference,
        onContextAction: widget.callbacks.onRefContextAction,
      ),
      _CompactPane.history => _HistoryPane(
        repository: repository,
        onLoadMore: widget.callbacks.onLoadMoreHistory,
        onSelected: widget.callbacks.onCommitSelected,
        onActivated: widget.callbacks.onCommitActivated,
        onContextAction: widget.callbacks.onCommitContextAction,
        onUncommittedChangesSelected: _selectUncommittedChanges,
        showSearch: true,
        onSearchChanged: widget.callbacks.onSearchChanged,
      ),
      _CompactPane.changes => _SelectedChangesPane(
        repository: repository,
        onSelected: widget.callbacks.onChangeSelected,
        onStageToggled: widget.callbacks.onChangeStageToggled,
        onGroupStageToggled: widget.callbacks.onChangeGroupStageToggled,
        onConflictAction: widget.callbacks.onConflictAction,
        onRevealInFinder: widget.callbacks.onChangeRevealInFinder,
        onRemove: widget.callbacks.onChangeRemove,
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
                  child: LayoutBuilder(
                    builder:
                        (BuildContext context, BoxConstraints constraints) {
                          return SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            reverse: true,
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                minWidth: constraints.maxWidth,
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  _ToolbarAction(
                                    action: RepositoryAction.commit,
                                    icon: Icons.check_circle_outline,
                                    label: '提交',
                                    showLabel: showLabels,
                                    repository: repository,
                                    onAction: callbacks.onAction,
                                    badge: repository.changes.length,
                                  ),
                                  _ToolbarAction(
                                    action: repository.isStashing
                                        ? RepositoryAction.cancelStash
                                        : RepositoryAction.stash,
                                    icon: repository.isStashing
                                        ? Icons.cancel_outlined
                                        : Icons.inventory_2_outlined,
                                    label: repository.isStashing
                                        ? '取消贮藏'
                                        : '贮藏',
                                    showLabel: showLabels,
                                    repository: repository,
                                    onAction: callbacks.onAction,
                                    isBusy: repository.isStashing,
                                  ),
                                  if (repository.isRebaseInProgress &&
                                      !repository.isPulling) ...[
                                    _ToolbarAction(
                                      action: RepositoryAction.continueRebase,
                                      icon: Icons.play_arrow_outlined,
                                      label: '继续变基',
                                      showLabel: showLabels,
                                      repository: repository,
                                      onAction: callbacks.onAction,
                                    ),
                                    _ToolbarAction(
                                      action: RepositoryAction.abortRebase,
                                      icon: Icons.stop_circle_outlined,
                                      label: '中止变基',
                                      showLabel: showLabels,
                                      repository: repository,
                                      onAction: callbacks.onAction,
                                    ),
                                  ] else if ((repository
                                              .isCherryPickInProgress ||
                                          repository.isRevertInProgress) &&
                                      !repository.isPulling) ...[
                                    _ToolbarAction(
                                      action:
                                          RepositoryAction.continueSequencer,
                                      icon: Icons.play_arrow_outlined,
                                      label: repository.isCherryPickInProgress
                                          ? '继续遴选'
                                          : '继续回滚',
                                      showLabel: showLabels,
                                      repository: repository,
                                      onAction: callbacks.onAction,
                                    ),
                                    _ToolbarAction(
                                      action: RepositoryAction.abortSequencer,
                                      icon: Icons.stop_circle_outlined,
                                      label: repository.isCherryPickInProgress
                                          ? '中止遴选'
                                          : '中止回滚',
                                      showLabel: showLabels,
                                      repository: repository,
                                      onAction: callbacks.onAction,
                                    ),
                                  ] else
                                    _ToolbarAction(
                                      action: repository.isPulling
                                          ? RepositoryAction.cancelPull
                                          : RepositoryAction.pull,
                                      icon: repository.isPulling
                                          ? Icons.cancel_outlined
                                          : Icons.south,
                                      label: repository.isPulling
                                          ? '取消拉取'
                                          : '拉取',
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
                                    // Sourcetree shows the number of commits
                                    // that are ahead of the tracked remote on
                                    // the Push action. Keep the badge tied to
                                    // Git's ahead count; uncommitted file
                                    // changes belong to the Commit badge.
                                    badge: repository.ahead,
                                    isBusy: repository.isPushing,
                                  ),
                                  _ToolbarAction(
                                    action: repository.isFetching
                                        ? RepositoryAction.cancelFetch
                                        : RepositoryAction.fetch,
                                    icon: repository.isFetching
                                        ? Icons.cancel_outlined
                                        : Icons.sync,
                                    label: repository.isFetching
                                        ? '取消获取'
                                        : '获取',
                                    showLabel: showLabels,
                                    repository: repository,
                                    onAction: callbacks.onAction,
                                    isBusy: repository.isFetching,
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
                                    action: RepositoryAction.refresh,
                                    icon: Icons.refresh,
                                    label: '刷新',
                                    showLabel: false,
                                    repository: repository,
                                    onAction: callbacks.onAction,
                                    isBusy: repository.isRefreshing,
                                  ),
                                  _ToolbarAction(
                                    action: RepositoryAction.openRepository,
                                    icon: Icons.folder_open_outlined,
                                    label: '打开仓库',
                                    showLabel: false,
                                    repository: repository,
                                    onAction: callbacks.onAction,
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
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
      key: ValueKey<String>('repository-action-${action.name}'),
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
        key: const ValueKey<String>('history-search-field'),
        initialValue: query,
        onChanged: onChanged,
        enabled: onChanged != null,
        style: Theme.of(context).textTheme.bodySmall,
        decoration: const InputDecoration(
          hintText: '搜索提交',
          prefixIcon: Icon(Icons.search, size: 17),
          prefixIconConstraints: BoxConstraints(minWidth: 34, minHeight: 32),
          isDense: true,
          contentPadding: EdgeInsets.only(right: 10),
          border: OutlineInputBorder(),
        ),
      ),
    );
  }
}

class _CompactHistorySearchBar extends StatelessWidget {
  const _CompactHistorySearchBar({
    required this.query,
    required this.onChanged,
  });

  final String query;
  final ValueChanged<String>? onChanged;

  /// 中文：在紧凑布局中保留提交搜索入口。
  /// English: Keeps commit search available in compact layouts.
  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: colors.outlineVariant)),
      ),
      child: _HistorySearchField(query: query, onChanged: onChanged),
    );
  }
}

class _RefsNavigation extends StatelessWidget {
  const _RefsNavigation({
    required this.repository,
    required this.selectedRefId,
    required this.onSelected,
    required this.onActivated,
    required this.onContextAction,
  });

  final RepositoryViewData repository;
  final String? selectedRefId;
  final RepositoryRefCallback? onSelected;
  final RepositoryRefCallback? onActivated;
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
    final Map<RepositoryRefKind, List<Widget>> sectionTiles = {
      for (final RepositoryRefKind kind in RepositoryRefKind.values)
        kind: kind == RepositoryRefKind.remote
            ? _buildRemoteTiles(
                sections[RepositoryRefKind.remote]!,
                sections[RepositoryRefKind.remoteBranch]!,
              )
            : _buildSectionTiles(kind, sections[kind]!),
    };

    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      child: CustomScrollView(
        slivers: [
          const SliverToBoxAdapter(
            child: _PaneHeader(title: '仓库', icon: Icons.folder_open_outlined),
          ),
          for (final RepositoryRefKind kind in RepositoryRefKind.values)
            if (sectionTiles[kind]!.isNotEmpty &&
                kind != RepositoryRefKind.stash &&
                kind != RepositoryRefKind.remoteBranch) ...[
              SliverToBoxAdapter(
                child: _SectionHeader(
                  title: _refKindLabel(kind),
                  count: sections[kind]!.length,
                ),
              ),
              SliverList.builder(
                itemCount: sectionTiles[kind]!.length,
                itemBuilder: (BuildContext context, int index) {
                  return sectionTiles[kind]![index];
                },
              ),
            ],
          if (sectionTiles[RepositoryRefKind.stash]!.isNotEmpty)
            SliverList.builder(
              itemCount: sectionTiles[RepositoryRefKind.stash]!.length,
              itemBuilder: (BuildContext context, int index) =>
                  sectionTiles[RepositoryRefKind.stash]![index],
            ),
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

  /// 中文：构建一个引用分区的行；本地分支按斜杠分段显示为可折叠目录。
  ///
  /// English: Builds rows for one reference section, displaying slash-delimited
  /// local branches as collapsible directories.
  List<Widget> _buildSectionTiles(
    RepositoryRefKind kind,
    List<RepositoryRefViewData> references,
  ) {
    if (kind != RepositoryRefKind.localBranch) {
      if (kind == RepositoryRefKind.stash) {
        return [
          for (final ref in references)
            _buildRefTile(ref, indent: ref.stashReference == null ? 0 : 1),
        ];
      }
      return [for (final ref in references) _buildRefTile(ref)];
    }
    return [
      for (final node in _buildLocalBranchTree(references))
        if (node.children.isEmpty)
          _buildRefTile(node.reference!, label: node.label)
        else
          _RefDirectoryTile(
            key: ValueKey<String>('ref-directory:${node.path}'),
            node: node,
            depth: 0,
            colorFor: (ref) => _refGraphColor(repository, ref),
            isSelected: _isReferenceSelected,
            onSelected: onSelected,
            onActivated: onActivated,
            contextItemsFor: _contextItemsFor,
            onContextAction: onContextAction,
          ),
    ];
  }

  /// 中文：按远端名称归组远端跟踪引用，并显示可展开的远端父节点。
  /// English: Groups remote-tracking refs under expandable configured remotes.
  List<Widget> _buildRemoteTiles(
    List<RepositoryRefViewData> remotes,
    List<RepositoryRefViewData> remoteBranches,
  ) {
    return [
      for (final remote in remotes)
        _RemoteDirectoryTile(
          key: ValueKey<String>('remote-directory:${remote.id}'),
          remote: remote,
          isSelected:
              _isReferenceSelected(remote) ||
              remoteBranches.any(
                (branch) =>
                    branch.label.startsWith('${remote.label}/') &&
                    _isReferenceSelected(branch),
              ),
          contextItems: _contextItemsFor(remote),
          onContextAction: onContextAction == null
              ? null
              : (RepositoryRefContextAction action) =>
                    onContextAction!(remote, action),
          onSelected: onSelected == null ? null : () => onSelected!(remote),
          children: [
            for (final branch
                in remoteBranches
                    .where(
                      (branch) => branch.label.startsWith('${remote.label}/'),
                    )
                    .toList(growable: false)
                  ..sort((a, b) => a.label.compareTo(b.label)))
              _buildRefTile(
                branch,
                label: branch.label.substring(remote.label.length + 1),
                indent: 1,
                showIcon: false,
              ),
          ],
        ),
    ];
  }

  /// 中文：创建保持选择、双击和右键行为的引用行。
  ///
  /// English: Creates a reference row while preserving selection, activation,
  /// and context-menu behavior.
  _RefTile _buildRefTile(
    RepositoryRefViewData ref, {
    String? label,
    int indent = 0,
    bool showIcon = true,
  }) {
    final stashActionDisabled =
        ref.kind == RepositoryRefKind.stash &&
        ref.stashReference == null &&
        repository.disabledActions.contains(RepositoryAction.stash);
    final selectionCallback = onSelected == null || stashActionDisabled
        ? null
        : () => onSelected!(ref);
    return _RefTile(
      ref: ref,
      label: label,
      indent: indent,
      showIcon: showIcon,
      graphColor: _refGraphColor(repository, ref),
      isSelected: _isReferenceSelected(ref),
      onPointerDown: selectionCallback,
      onTap: ref.kind == RepositoryRefKind.stash ? null : selectionCallback,
      onDoubleTap:
          ref.kind == RepositoryRefKind.stash ||
              ref.isSymbolicRemote ||
              onActivated == null ||
              stashActionDisabled
          ? null
          : () => onActivated!(ref),
      contextItems: _contextItemsFor(ref),
      onContextAction: onContextAction == null
          ? null
          : (RepositoryRefContextAction action) =>
                onContextAction!(ref, action),
    );
  }

  /// 中文：判断一个引用是否应以当前选中状态显示。
  /// English: Determines whether a reference should render as selected.
  bool _isReferenceSelected(RepositoryRefViewData ref) =>
      selectedRefId == ref.id || (selectedRefId == null && ref.isSelected);

  /// 中文：查找远端分支所属的已配置远端名称。
  /// English: Finds the configured remote that owns a remote-tracking ref.
  String? _remoteNameFor(RepositoryRefViewData ref) {
    if (ref.kind == RepositoryRefKind.remote) return ref.label;
    if (ref.kind != RepositoryRefKind.remoteBranch) return null;
    final names =
        repository.refs
            .where((candidate) => candidate.kind == RepositoryRefKind.remote)
            .map((candidate) => candidate.label)
            .where((name) => ref.label.startsWith('$name/'))
            .toList(growable: false)
          ..sort((a, b) => b.length.compareTo(a.length));
    return names.firstOrNull;
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
    final hasConflicts = repository.changes.any(
      (change) => change.kind == RepositoryChangeKind.conflicted,
    );
    final canSwitch = !isBusy && !hasConflicts;
    final canMerge = !disabledActions.contains(RepositoryAction.mergeBranch);
    final canCreate =
        !isBusy && !disabledActions.contains(RepositoryAction.createBranch);
    final canManageLocalBranch = canCreate && !hasConflicts;
    final canManageRemote = !isBusy && !repository.isRebaseInProgress;
    final remoteName = _remoteNameFor(ref);
    if (ref.id == 'history') {
      return [
        _RefContextMenuItem(
          action: RepositoryRefContextAction.refresh,
          label: '刷新仓库',
          icon: Icons.refresh,
          enabled: !isBusy,
        ),
      ];
    }
    if (ref.id == 'HEAD') {
      return [
        _RefContextMenuItem(
          action: RepositoryRefContextAction.refresh,
          label: '刷新仓库',
          icon: Icons.refresh,
          enabled: !isBusy,
        ),
      ];
    }
    if (ref.kind == RepositoryRefKind.remoteBranch && ref.isSymbolicRemote) {
      return [
        _RefContextMenuItem(
          action: RepositoryRefContextAction.refresh,
          label: '刷新仓库',
          icon: Icons.refresh,
          enabled: !isBusy,
        ),
      ];
    }
    return switch (ref.kind) {
      RepositoryRefKind.workspace => [
        _RefContextMenuItem(
          action: RepositoryRefContextAction.createStash,
          label: '贮藏当前改动',
          icon: Icons.inventory_2_outlined,
          enabled:
              !isBusy &&
              repository.changes.isNotEmpty &&
              !repository.changes.any(
                (change) => change.kind == RepositoryChangeKind.conflicted,
              ),
        ),
        const _RefContextMenuItem.divider(),
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
          label: remoteName == null ? '获取远端' : '获取 $remoteName',
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
      RepositoryRefKind.remote => [
        _RefContextMenuItem(
          action: RepositoryRefContextAction.fetchOrigin,
          label: '从 ${ref.label} 获取',
          icon: Icons.sync,
          enabled: canFetch,
        ),
        _RefContextMenuItem(
          action: RepositoryRefContextAction.pullCurrentBranch,
          label: '从 ${ref.label} 拉取…',
          icon: Icons.south,
          enabled: canPull,
        ),
        _RefContextMenuItem(
          action: RepositoryRefContextAction.pushCurrentBranch,
          label: '推送到 ${ref.label}…',
          icon: Icons.north,
          enabled: canPush,
        ),
        _RefContextMenuItem(
          action: RepositoryRefContextAction.removeRemote,
          label: '移除 ${ref.label}',
          icon: Icons.remove_circle_outline,
          enabled: canManageRemote,
        ),
      ],
      RepositoryRefKind.stash => [
        _RefContextMenuItem(
          action: RepositoryRefContextAction.manageStashes,
          label: '管理贮藏',
          icon: Icons.inventory_2_outlined,
          enabled: !isBusy,
        ),
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
    RepositoryRefKind.remote => '远端',
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
    RepositoryRefKind.remote => Icons.cloud_outlined,
    RepositoryRefKind.remoteBranch => Icons.cloud_outlined,
    RepositoryRefKind.tag => Icons.sell_outlined,
    RepositoryRefKind.stash => Icons.inventory_2_outlined,
  };
}

/// 中文：返回左侧引用图标复用的提交图车道颜色；非分支引用保持主题中性色。
///
/// English: Returns the commit-graph lane color reused by a sidebar ref icon;
/// non-branch refs keep the theme's neutral color.
Color? _refGraphColor(
  RepositoryViewData repository,
  RepositoryRefViewData ref,
) {
  if (ref.id == 'HEAD' || ref.kind == RepositoryRefKind.remoteBranch) {
    return _graphBaseOrange;
  }
  CommitViewData? commit;
  for (final candidate in repository.commits) {
    if (candidate.refs.contains(ref.label)) {
      commit = candidate;
      break;
    }
  }
  if (commit != null) {
    return _graphPalette[commit.graph.colorIndex.abs() % _graphPalette.length];
  }
  if (ref.kind == RepositoryRefKind.localBranch) {
    final localBranches = repository.refs
        .where(
          (candidate) =>
              candidate.kind == RepositoryRefKind.localBranch &&
              candidate.id != 'HEAD',
        )
        .toList(growable: false);
    final isPrimary =
        ref.label == repository.primaryLocalBranch ||
        (repository.primaryLocalBranch == null &&
            ref.label == repository.currentBranch);
    if (isPrimary) return _graphPrimaryBlue;
    final index = localBranches.indexWhere(
      (candidate) => candidate.id == ref.id,
    );
    if (index >= 0) {
      return _graphPalette[(index + 1) % _graphPalette.length];
    }
  }
  return null;
}

/// A directory node derived from slash-delimited local branch names.
///
/// 中文：由带斜杠的本地分支名派生的目录节点；叶节点持有真实 Git 引用。
final class _RefNavigationTreeNode {
  _RefNavigationTreeNode({required this.label, required this.path});

  final String label;
  final String path;
  RepositoryRefViewData? reference;
  final Map<String, _RefNavigationTreeNode> children =
      <String, _RefNavigationTreeNode>{};
}

/// 中文：按 `/` 将本地分支构造成稳定顺序的目录树。
///
/// English: Builds a stable-order directory tree by splitting local branch
/// names on `/`.
List<_RefNavigationTreeNode> _buildLocalBranchTree(
  List<RepositoryRefViewData> references,
) {
  final roots = <String, _RefNavigationTreeNode>{};
  for (final ref in references) {
    final segments = ref.label
        .split('/')
        .where((String segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (segments.isEmpty) continue;

    Map<String, _RefNavigationTreeNode> siblings = roots;
    _RefNavigationTreeNode? node;
    var path = '';
    for (final segment in segments) {
      path = path.isEmpty ? segment : '$path/$segment';
      node = siblings.putIfAbsent(
        segment,
        () => _RefNavigationTreeNode(label: segment, path: path),
      );
      siblings = node.children;
    }
    node!.reference = ref;
  }
  return roots.values.toList(growable: false);
}

/// Displays one virtual branch directory and its nested local branch entries.
///
/// 中文：显示一个虚拟分支目录及其嵌套的本地分支条目。
final class _RefDirectoryTile extends StatefulWidget {
  const _RefDirectoryTile({
    super.key,
    required this.node,
    required this.depth,
    required this.colorFor,
    required this.isSelected,
    required this.onSelected,
    required this.onActivated,
    required this.contextItemsFor,
    required this.onContextAction,
  });

  final _RefNavigationTreeNode node;
  final int depth;
  final Color? Function(RepositoryRefViewData ref) colorFor;
  final bool Function(RepositoryRefViewData ref) isSelected;
  final RepositoryRefCallback? onSelected;
  final RepositoryRefCallback? onActivated;
  final List<_RefContextMenuItem> Function(RepositoryRefViewData ref)
  contextItemsFor;
  final RepositoryRefContextActionCallback? onContextAction;

  /// 中文：创建目录节点的可折叠状态。
  /// English: Creates the collapsible state for a directory node.
  @override
  State<_RefDirectoryTile> createState() => _RefDirectoryTileState();
}

/// Displays one configured remote and its remote-tracking refs.
///
/// 中文：显示一个可展开的远端及其远端跟踪引用，并为远端名称提供紧凑右键菜单。
final class _RemoteDirectoryTile extends StatefulWidget {
  const _RemoteDirectoryTile({
    super.key,
    required this.remote,
    required this.children,
    required this.isSelected,
    required this.contextItems,
    required this.onContextAction,
    required this.onSelected,
  });

  final RepositoryRefViewData remote;
  final List<Widget> children;
  final bool isSelected;
  final List<_RefContextMenuItem> contextItems;
  final ValueChanged<RepositoryRefContextAction>? onContextAction;
  final VoidCallback? onSelected;

  @override
  State<_RemoteDirectoryTile> createState() => _RemoteDirectoryTileState();
}

class _RemoteDirectoryTileState extends State<_RemoteDirectoryTile> {
  var _isExpanded = true;

  /// 中文：切换远端分组的展开状态，并将选择交给共享的引用状态。
  /// English: Toggles the remote group and delegates selection to shared ref
  /// state.
  void _toggleExpanded() {
    widget.onSelected?.call();
    setState(() => _isExpanded = !_isExpanded);
  }

  /// 中文：以紧凑、无图标样式显示远端名称的右键操作。
  /// English: Shows the compact, text-first context menu for a remote name.
  Future<void> _showContextMenu(
    BuildContext context,
    Offset globalPosition,
  ) async {
    final handler = widget.onContextAction;
    if (handler == null || widget.contextItems.isEmpty) return;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final selection = await showMenu<RepositoryRefContextAction>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        for (final item in widget.contextItems)
          if (item.isDivider)
            const PopupMenuDivider()
          else
            PopupMenuItem<RepositoryRefContextAction>(
              value: item.action,
              enabled: item.enabled,
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(item.label),
            ),
      ],
    );
    if (selection != null) handler(selection);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isSelected = widget.isSelected;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          expanded: _isExpanded,
          selected: isSelected,
          label: '远端 ${widget.remote.label}',
          child: GestureDetector(
            onLongPressStart: (details) =>
                unawaited(_showContextMenu(context, details.globalPosition)),
            child: InkWell(
              onTap: _toggleExpanded,
              onSecondaryTapDown: (details) =>
                  unawaited(_showContextMenu(context, details.globalPosition)),
              child: Container(
                height: 31,
                padding: const EdgeInsets.only(left: 14, right: 8),
                color: isSelected ? colors.secondaryContainer : null,
                child: Row(
                  children: [
                    Icon(
                      _isExpanded
                          ? Icons.keyboard_arrow_down
                          : Icons.keyboard_arrow_right,
                      size: 16,
                      color: isSelected
                          ? colors.onSecondaryContainer
                          : colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        widget.remote.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: isSelected
                              ? colors.onSecondaryContainer
                              : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_isExpanded) ...widget.children,
      ],
    );
  }
}

class _RefDirectoryTileState extends State<_RefDirectoryTile> {
  var _isExpanded = true;

  /// 中文：切换目录的展开状态，不影响其子分支的选择状态。
  /// English: Toggles directory expansion without changing child selection.
  void _toggleExpanded() => setState(() => _isExpanded = !_isExpanded);

  /// 中文：构建目录标题及其已展开的嵌套分支。
  /// English: Builds the directory header and, when expanded, its nested
  /// branches.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final leftInset = 14.0 + widget.depth * 18;
    final childDepth = widget.depth + 1;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          expanded: _isExpanded,
          label: '分支目录 ${widget.node.path}',
          child: Tooltip(
            message: widget.node.path,
            waitDuration: const Duration(milliseconds: 650),
            child: InkWell(
              onTap: _toggleExpanded,
              child: Container(
                height: 31,
                padding: EdgeInsets.only(left: leftInset, right: 8),
                child: Row(
                  children: [
                    Icon(
                      _isExpanded
                          ? Icons.keyboard_arrow_down
                          : Icons.keyboard_arrow_right,
                      size: 16,
                      color: colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      _isExpanded
                          ? Icons.folder_open_outlined
                          : Icons.folder_outlined,
                      size: 15,
                      color: colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        widget.node.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_isExpanded) ...[
          if (widget.node.reference case final ref?)
            _RefTile(
              ref: ref,
              label: widget.node.label,
              indent: childDepth,
              graphColor: widget.colorFor(ref),
              isSelected: widget.isSelected(ref),
              onPointerDown: widget.onSelected == null
                  ? null
                  : () => widget.onSelected!(ref),
              onTap: widget.onSelected == null
                  ? null
                  : () => widget.onSelected!(ref),
              onDoubleTap: widget.onActivated == null
                  ? null
                  : () => widget.onActivated!(ref),
              contextItems: widget.contextItemsFor(ref),
              onContextAction: widget.onContextAction == null
                  ? null
                  : (RepositoryRefContextAction action) =>
                        widget.onContextAction!(ref, action),
            ),
          for (final child in widget.node.children.values)
            if (child.children.isEmpty)
              _RefTile(
                ref: child.reference!,
                label: child.label,
                indent: childDepth,
                graphColor: widget.colorFor(child.reference!),
                isSelected: widget.isSelected(child.reference!),
                onPointerDown: widget.onSelected == null
                    ? null
                    : () => widget.onSelected!(child.reference!),
                onTap: widget.onSelected == null
                    ? null
                    : () => widget.onSelected!(child.reference!),
                onDoubleTap: widget.onActivated == null
                    ? null
                    : () => widget.onActivated!(child.reference!),
                contextItems: widget.contextItemsFor(child.reference!),
                onContextAction: widget.onContextAction == null
                    ? null
                    : (RepositoryRefContextAction action) =>
                          widget.onContextAction!(child.reference!, action),
              )
            else
              _RefDirectoryTile(
                key: ValueKey<String>('ref-directory:${child.path}'),
                node: child,
                depth: childDepth,
                colorFor: widget.colorFor,
                isSelected: widget.isSelected,
                onSelected: widget.onSelected,
                onActivated: widget.onActivated,
                contextItemsFor: widget.contextItemsFor,
                onContextAction: widget.onContextAction,
              ),
        ],
      ],
    );
  }
}

class _RefTile extends StatelessWidget {
  const _RefTile({
    required this.ref,
    this.label,
    this.indent = 0,
    this.showIcon = true,
    this.graphColor,
    required this.isSelected,
    required this.onPointerDown,
    required this.onTap,
    required this.onDoubleTap,
    required this.contextItems,
    required this.onContextAction,
  });

  final RepositoryRefViewData ref;
  final String? label;
  final int indent;
  final bool showIcon;
  final Color? graphColor;
  final bool isSelected;
  final VoidCallback? onPointerDown;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
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
    final displayLabel = label ?? ref.label;

    return Semantics(
      button: true,
      enabled: onPointerDown != null || onTap != null,
      onTap: onTap ?? onPointerDown,
      selected: isSelected,
      label: '${_refKindLabel(ref.kind)} $displayLabel',
      child: Opacity(
        opacity: onPointerDown == null && onTap == null ? 0.5 : 1,
        child: Tooltip(
          message: ref.secondaryLabel ?? ref.label,
          waitDuration: const Duration(milliseconds: 650),
          child: GestureDetector(
            onLongPressStart: (details) =>
                unawaited(_showContextMenu(context, details.globalPosition)),
            child: Listener(
              onPointerDown: (event) {
                if (event.buttons == kPrimaryButton) onPointerDown?.call();
              },
              child: InkWell(
                onTap: onTap,
                onDoubleTap: onDoubleTap,
                onSecondaryTapDown: (details) => unawaited(
                  _showContextMenu(context, details.globalPosition),
                ),
                child: Container(
                  height: 31,
                  padding: EdgeInsets.only(left: 14 + indent * 18, right: 8),
                  color: isSelected ? colors.secondaryContainer : null,
                  child: Row(
                    children: [
                      if (showIcon)
                        Icon(
                          key: ValueKey<String>('ref-nav-icon:${ref.id}'),
                          ref.isCurrent
                              ? Icons.radio_button_checked
                              : _refKindIcon(ref.kind),
                          size: 15,
                          color:
                              graphColor ??
                              (ref.isCurrent
                                  ? colors.primary
                                  : colors.onSurfaceVariant),
                        )
                      else
                        const SizedBox(width: 15),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          displayLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: ref.isCurrent ? FontWeight.w600 : null,
                            color: isSelected
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
        ),
      ),
    );
  }
}

// Sourcetree's history uses compact 24px rows: this keeps the commit graph
// readable while giving each history entry a little more breathing room.
const double _historyRowHeight = 24;
const double _historyDescriptionMinimumWidth = 0;
const double _historyGraphMinimumWidth = 0;
const double _historyCommitMinimumWidth = 0;
const double _historyAuthorMinimumWidth = 0;
const double _historyDateMinimumWidth = 0;

const double _historyColumnHandleWidth = 5;

// Sourcetree keeps the graph column bounded even when a repository has many
// simultaneously active branches. Preserve the complete Git topology in the
// view model, but expose at most eight physical rails in each history row.
/// 中文：返回提交图最左侧车道中心，使工作区节点与游离 HEAD 基点严格对齐。
///
/// English: Returns the leftmost graph-lane center shared by the workspace
/// marker and a detached-HEAD base node.
double _historyGraphLaneStart(bool compact) => compact ? 6 : 8;

/// 中文：返回与参照图一致的紧凑提交车道间距。
/// English: Returns the compact commit-lane spacing used by the reference UI.
double _historyGraphLaneSpacing(bool compact) => compact ? 9 : 11;

final class _HistoryColumnWidths {
  const _HistoryColumnWidths({
    required this.availableWidth,
    required this.graph,
    required this.graphMinimum,
    required this.commit,
    required this.commitMinimum,
    required this.commitMaximum,
    required this.author,
    required this.authorMinimum,
    required this.date,
    required this.dateMinimum,
  });

  final double availableWidth;
  final double graph;
  final double graphMinimum;
  final double commit;
  final double commitMinimum;
  final double commitMaximum;
  final double author;
  final double authorMinimum;
  final double date;
  final double dateMinimum;
}

/// Reuses the workspace's Sourcetree-style commit history table in focused
/// workflows such as patch creation.
/// 中文：在创建补丁等聚焦流程中复用工作区的 Sourcetree 风格提交历史表格。
class RepositoryHistoryPane extends StatelessWidget {
  const RepositoryHistoryPane({
    super.key,
    required this.repository,
    required this.onSelected,
    this.onActivated,
    this.onLoadMore,
    this.onContextAction,
    this.selectedCommitIds,
    this.showPaneHeader = true,
    this.includeUncommittedChanges = true,
  });

  final RepositoryViewData repository;
  final RepositoryCommitCallback? onSelected;
  final RepositoryCommitActivationCallback? onActivated;
  final RepositoryCommitContextActionCallback? onContextAction;
  final VoidCallback? onLoadMore;
  final Set<String>? selectedCommitIds;
  final bool showPaneHeader;
  final bool includeUncommittedChanges;

  @override
  Widget build(BuildContext context) => _HistoryPane(
    repository: repository,
    onSelected: onSelected,
    onActivated: onActivated,
    onContextAction: onContextAction,
    onLoadMore: onLoadMore,
    onUncommittedChangesSelected: null,
    selectedCommitIds: selectedCommitIds,
    showPaneHeader: showPaneHeader,
    includeUncommittedChanges: includeUncommittedChanges,
  );
}

class _HistoryPane extends StatefulWidget {
  const _HistoryPane({
    required this.repository,
    required this.onSelected,
    required this.onActivated,
    required this.onUncommittedChangesSelected,
    this.onLoadMore,
    this.onContextAction,
    this.showSearch = false,
    this.onSearchChanged,
    this.selectedCommitIds,
    this.showPaneHeader = true,
    this.includeUncommittedChanges = true,
  });

  final RepositoryViewData repository;
  final RepositoryCommitCallback? onSelected;
  final RepositoryCommitActivationCallback? onActivated;
  final RepositoryCommitContextActionCallback? onContextAction;
  final VoidCallback? onUncommittedChangesSelected;
  final VoidCallback? onLoadMore;
  final bool showSearch;
  final ValueChanged<String>? onSearchChanged;
  final Set<String>? selectedCommitIds;
  final bool showPaneHeader;
  final bool includeUncommittedChanges;

  @override
  State<_HistoryPane> createState() => _HistoryPaneState();
}

class _HistoryPaneState extends State<_HistoryPane> {
  final ScrollController _scrollController = ScrollController();
  final bool _showRemoteRefs = true;
  final bool _compactGraph = false;
  double? _graphColumnWidth;
  double? _commitColumnWidth;
  double? _authorColumnWidth;
  double? _dateColumnWidth;

  @override
  void initState() {
    super.initState();
    _scheduleFocusedRefScroll();
  }

  @override
  void didUpdateWidget(_HistoryPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    final focusedId = widget.repository.focusedRefCommitId;
    final selectedId = widget.repository.selectedCommit?.oid;
    if (focusedId != null &&
        selectedId == focusedId &&
        (oldWidget.repository.focusedRefCommitId != focusedId ||
            oldWidget.repository.selectedCommit?.oid != selectedId)) {
      _scheduleFocusedRefScroll();
    }
  }

  /// 中文：在历史列表完成布局后，将选中分支的尖端提交滚动到可见区域顶部。
  /// English: Scrolls the selected branch tip to the top after history layout.
  void _scheduleFocusedRefScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final objectId = widget.repository.focusedRefCommitId;
      if (objectId == null) return;
      final index = _visibleCommits(
        widget.repository,
      ).indexWhere((commit) => commit.oid == objectId);
      if (index < 0) return;
      final rowIndex = index + (widget.repository.isWorkingTreeClean ? 0 : 1);
      final target = (rowIndex * _historyRowHeight).clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final showUncommittedChanges =
        widget.includeUncommittedChanges &&
        !widget.repository.isWorkingTreeClean;
    final commits = _visibleCommits(widget.repository);
    final fallbackGraphs =
        commits.every(
          (commit) =>
              commit.graph.lane == 0 &&
              commit.graph.colorIndex == 0 &&
              commit.graph.activeLanes.length == 1 &&
              commit.graph.activeLanes.first == 0 &&
              commit.graph.parentLanes.length <= 1,
        )
        ? _fallbackGraphsFor(
            commits,
            headId: widget.repository.headOid,
            isDetachedHead: widget.repository.isDetachedHead,
          )
        : const <String, CommitGraphViewData>{};
    final uncommittedChangesSelected =
        widget.repository.isUncommittedChangesSelected;
    final historyRowCount = commits.length + (showUncommittedChanges ? 1 : 0);
    final showLoadMoreRow =
        widget.repository.hasMoreHistory ||
        widget.repository.isHistoryLoading ||
        widget.repository.historyLoadError != null;
    final historyListItemCount = historyRowCount + (showLoadMoreRow ? 1 : 0);
    return Material(
      color: _historyBackground(colors),
      child: Column(
        children: [
          if (widget.showPaneHeader)
            _PaneHeader(
              title: '历史',
              icon: Icons.history,
              trailing: '${commits.length} 个提交',
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final widths = _historyColumnWidths(
                  constraints.maxWidth,
                  compact: _compactGraph,
                );
                return Column(
                  children: [
                    if (widget.showSearch)
                      _CompactHistorySearchBar(
                        query: widget.repository.searchQuery,
                        onChanged: widget.onSearchChanged,
                      ),
                    _HistoryColumnHeader(
                      widths: widths,
                      onGraphDelta: (delta) =>
                          _resizeGraphColumn(widths, delta),
                      onDescriptionDelta: (delta) =>
                          _resizeDescriptionColumn(widths, delta),
                      onCommitDelta: (delta) =>
                          _resizeCommitColumn(widths, delta),
                      onAuthorDelta: (delta) =>
                          _resizeAuthorColumn(widths, delta),
                    ),
                    Expanded(
                      child: historyRowCount == 0 && !showLoadMoreRow
                          ? const _PaneEmptyState(
                              icon: Icons.commit,
                              title: '暂无提交',
                              message: '空仓库的首次提交会显示在这里。',
                            )
                          : Stack(
                              children: [
                                NotificationListener<ScrollNotification>(
                                  onNotification: (notification) {
                                    if (notification
                                            is ScrollUpdateNotification &&
                                        widget.repository.hasMoreHistory &&
                                        !widget.repository.isHistoryLoading &&
                                        widget.repository.historyLoadError ==
                                            null &&
                                        notification.metrics.extentAfter <=
                                            _historyRowHeight * 2) {
                                      widget.onLoadMore?.call();
                                    }
                                    return false;
                                  },
                                  child: ListView.builder(
                                    controller: _scrollController,
                                    itemExtent: _historyRowHeight,
                                    itemCount: historyListItemCount,
                                    itemBuilder:
                                        (BuildContext context, int index) {
                                          if (index == historyRowCount) {
                                            return _HistoryLoadMoreRow(
                                              isLoading: widget
                                                  .repository
                                                  .isHistoryLoading,
                                              error: widget
                                                  .repository
                                                  .historyLoadError,
                                              onPressed: widget.onLoadMore,
                                            );
                                          }
                                          if (showUncommittedChanges &&
                                              index == 0) {
                                            return _UncommittedChangesRow(
                                              isSelected:
                                                  uncommittedChangesSelected,
                                              compactGraph: _compactGraph,
                                              widths: widths,
                                              onTap: widget
                                                  .onUncommittedChangesSelected,
                                            );
                                          }
                                          final commitIndex =
                                              index -
                                              (showUncommittedChanges ? 1 : 0);
                                          final CommitViewData commit =
                                              commits[commitIndex];
                                          final graph =
                                              fallbackGraphs[commit.oid] ??
                                              commit.graph;
                                          final graphWithWorkspace = graph
                                              .copyWith(
                                                hasWorkspaceNode:
                                                    showUncommittedChanges,
                                                hasPreviousNode:
                                                    showUncommittedChanges &&
                                                        commitIndex == 0
                                                    ? true
                                                    : null,
                                                additionalPreviousLanes:
                                                    showUncommittedChanges &&
                                                        commitIndex == 0
                                                    ? const {0}
                                                    : const {},
                                              );
                                          return _CommitRow(
                                            commit: commit.copyWith(
                                              graph: graphWithWorkspace,
                                              isSelected:
                                                  widget.selectedCommitIds
                                                      ?.contains(commit.oid) ??
                                                  commit.isSelected,
                                            ),
                                            currentBranch:
                                                widget.repository.currentBranch,
                                            primaryLocalBranch: widget
                                                .repository
                                                .primaryLocalBranch,
                                            ahead: widget.repository.ahead,
                                            showRemoteRefs: _showRemoteRefs,
                                            compactGraph: _compactGraph,
                                            widths: widths,
                                            onTap: widget.onSelected == null
                                                ? null
                                                : () => widget.onSelected!(
                                                    commit,
                                                  ),
                                            onDoubleTap:
                                                widget.onActivated == null
                                                ? null
                                                : () => widget.onActivated!(
                                                    commit,
                                                  ),
                                            onContextAction:
                                                widget.onContextAction == null
                                                ? null
                                                : (action) =>
                                                      widget.onContextAction!(
                                                        commit,
                                                        action,
                                                      ),
                                          );
                                        },
                                  ),
                                ),
                                _HistoryResizeOverlay(
                                  widths: widths,
                                  onGraphDelta: (delta) =>
                                      _resizeGraphColumn(widths, delta),
                                  onDescriptionDelta: (delta) =>
                                      _resizeDescriptionColumn(widths, delta),
                                  onCommitDelta: (delta) =>
                                      _resizeCommitColumn(widths, delta),
                                  onAuthorDelta: (delta) =>
                                      _resizeAuthorColumn(widths, delta),
                                ),
                              ],
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

  _HistoryColumnWidths _historyColumnWidths(
    double availableWidth, {
    required bool compact,
  }) {
    final graphMinimum = _historyGraphMinimumWidth;
    final commitMinimum = _historyCommitMinimumWidth;
    final authorMinimum = _historyAuthorMinimumWidth;
    final dateMinimum = _historyDateMinimumWidth;
    final graphPreferred = (_graphColumnWidth ?? (compact ? 70 : 96))
        .clamp(graphMinimum, availableWidth)
        .toDouble();
    final commitPreferred = (_commitColumnWidth ?? (compact ? 82 : 108))
        .clamp(commitMinimum, availableWidth)
        .toDouble();
    final authorPreferred = (_authorColumnWidth ?? (compact ? 130 : 180))
        .clamp(authorMinimum, availableWidth)
        .toDouble();
    final datePreferred = (_dateColumnWidth ?? (compact ? 75 : 86))
        .clamp(dateMinimum, availableWidth)
        .toDouble();
    final preferredFixedWidth =
        graphPreferred + commitPreferred + authorPreferred + datePreferred;
    final availableFixedWidth = math.max(
      0,
      availableWidth -
          (_historyColumnHandleWidth * 4) -
          16 -
          _historyDescriptionMinimumWidth,
    );
    final minimumFixedWidth =
        graphMinimum + commitMinimum + authorMinimum + dateMinimum;
    final shrinkRatio = preferredFixedWidth <= minimumFixedWidth
        ? 0.0
        : preferredFixedWidth <= availableFixedWidth
        ? 1.0
        : ((availableFixedWidth - minimumFixedWidth) /
                  (preferredFixedWidth - minimumFixedWidth))
              .clamp(0.0, 1.0)
              .toDouble();
    final graph = graphMinimum + (graphPreferred - graphMinimum) * shrinkRatio;
    final commit =
        commitMinimum + (commitPreferred - commitMinimum) * shrinkRatio;
    final author =
        authorMinimum + (authorPreferred - authorMinimum) * shrinkRatio;
    final date = dateMinimum + (datePreferred - dateMinimum) * shrinkRatio;
    final fixedWidth =
        graph +
        author +
        date +
        (_historyColumnHandleWidth * 4) +
        16 +
        _historyDescriptionMinimumWidth;
    final double commitMaximum = math
        .max(commitMinimum, availableWidth - fixedWidth)
        .toDouble();
    return _HistoryColumnWidths(
      availableWidth: availableWidth,
      graph: graph,
      graphMinimum: graphMinimum,
      commit: commit,
      commitMinimum: commitMinimum,
      commitMaximum: commitMaximum,
      author: author,
      authorMinimum: authorMinimum,
      date: date,
      dateMinimum: dateMinimum,
    );
  }

  void _resizeDescriptionColumn(_HistoryColumnWidths widths, double delta) {
    // The description column fills the remaining space, so changing its
    // trailing edge changes the adjacent commit column in the opposite
    // direction.
    final currentCommit = widths.commit;
    final currentGraph = widths.graph;
    final currentAuthor = widths.author;
    final currentDate = widths.date;
    final commitMaximum = _commitMaximumFor(
      widths,
      graph: currentGraph,
      author: currentAuthor,
      date: currentDate,
    );
    final nextCommit = (currentCommit - delta)
        .clamp(widths.commitMinimum, commitMaximum)
        .toDouble();
    setState(() => _commitColumnWidth = nextCommit);
  }

  double _commitMaximumFor(
    _HistoryColumnWidths widths, {
    required double graph,
    required double author,
    required double date,
  }) {
    return math
        .max(
          widths.commitMinimum,
          widths.availableWidth -
              graph -
              author -
              date -
              (_historyColumnHandleWidth * 4) -
              16 -
              _historyDescriptionMinimumWidth,
        )
        .toDouble();
  }

  void _resizeGraphColumn(_HistoryColumnWidths widths, double delta) {
    final currentGraph = widths.graph;
    final maxGraph = math.max(
      widths.graphMinimum,
      widths.availableWidth -
          (widths.commit + widths.author + widths.date) -
          (_historyColumnHandleWidth * 4) -
          16 -
          _historyDescriptionMinimumWidth,
    );
    final nextGraph = (currentGraph + delta)
        .clamp(widths.graphMinimum, maxGraph)
        .toDouble();
    setState(() => _graphColumnWidth = nextGraph);
  }

  void _resizeCommitColumn(_HistoryColumnWidths widths, double delta) {
    // Keep the divider under the pointer by resizing both adjacent columns.
    final currentCommit = widths.commit;
    final currentAuthor = widths.author;
    final appliedDelta = delta
        .clamp(
          widths.commitMinimum - currentCommit,
          currentAuthor - widths.authorMinimum,
        )
        .toDouble();
    setState(() {
      _commitColumnWidth = currentCommit + appliedDelta;
      _authorColumnWidth = currentAuthor - appliedDelta;
    });
  }

  void _resizeAuthorColumn(_HistoryColumnWidths widths, double delta) {
    // Keep the divider under the pointer by resizing both adjacent columns.
    final currentAuthor = widths.author;
    final currentDate = widths.date;
    final appliedDelta = delta
        .clamp(
          widths.authorMinimum - currentAuthor,
          currentDate - widths.dateMinimum,
        )
        .toDouble();
    setState(() {
      _authorColumnWidth = currentAuthor + appliedDelta;
      _dateColumnWidth = currentDate - appliedDelta;
    });
  }

  /// 中文：返回 Git 已按拓扑顺序加载的全部分支提交，不再依赖已移除的范围工具条过滤。
  ///
  /// English: Returns every branch commit loaded in Git topology order,
  /// without filtering through the removed scope toolbar.
  List<CommitViewData> _visibleCommits(RepositoryViewData repository) =>
      repository.commits;

  /// 中文：为旧的手工视图数据补建 Graph；映射层提供的完整 Graph 始终优先。
  ///
  /// English: Builds a fallback graph for hand-authored view data while
  /// preferring the complete graph supplied by the application mapper.
  Map<String, CommitGraphViewData> _fallbackGraphsFor(
    List<CommitViewData> commits, {
    required String? headId,
    required bool isDetachedHead,
  }) {
    final graphs = buildCommitGraph(
      [
        for (final commit in commits)
          CommitGraphNode(oid: commit.oid, parents: commit.parents),
      ],
      headId: headId,
      isDetachedHead: isDetachedHead,
    );
    return <String, CommitGraphViewData>{
      for (var index = 0; index < commits.length; index++)
        commits[index].oid: graphs[index],
    };
  }
}

class _HistoryLoadMoreRow extends StatelessWidget {
  const _HistoryLoadMoreRow({
    required this.isLoading,
    required this.error,
    required this.onPressed,
  });

  final bool isLoading;
  final String? error;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    if (isLoading) {
      return Center(
        child: SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 1.8,
            color: colors.primary,
          ),
        ),
      );
    }

    final hasError = error != null;
    return Semantics(
      button: true,
      label: hasError ? '加载更多提交失败，点击重试' : '加载更多提交',
      child: InkWell(
        onTap: onPressed,
        child: Center(
          child: Text(
            hasError ? '加载失败，点击重试' : '加载更多提交',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: hasError ? colors.error : colors.primary,
            ),
          ),
        ),
      ),
    );
  }
}

class _UncommittedChangesRow extends StatelessWidget {
  const _UncommittedChangesRow({
    required this.isSelected,
    required this.compactGraph,
    required this.widths,
    required this.onTap,
  });

  final bool isSelected;
  final bool compactGraph;
  final _HistoryColumnWidths widths;
  final VoidCallback? onTap;

  /// 中文：在历史顶部展示不属于真实提交的工作区改动入口。
  /// English: Shows the non-commit workspace entry at the top of history.
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;

    return Semantics(
      button: true,
      selected: isSelected,
      label: 'Uncommitted changes，工作区未提交的更改，今天',
      child: Tooltip(
        message: '查看工作区未提交的更改',
        waitDuration: const Duration(milliseconds: 750),
        child: InkWell(
          onTap: onTap,
          child: Container(
            key: const ValueKey<String>('uncommitted-changes-row'),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            color: isSelected ? colors.primary : null,
            child: Row(
              children: [
                SizedBox(
                  width: widths.graph,
                  height: _historyRowHeight,
                  child: CustomPaint(
                    painter: _UncommittedGraphPainter(
                      color: colors.onSurfaceVariant,
                      selected: isSelected,
                      compact: compactGraph,
                    ),
                  ),
                ),
                const SizedBox(width: _historyColumnHandleWidth),
                Expanded(
                  child: Text(
                    'Uncommitted changes',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: isSelected ? colors.onPrimary : null,
                    ),
                  ),
                ),
                SizedBox(
                  width: widths.commit,
                  child: Text(
                    '*',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: isSelected
                          ? colors.onPrimary.withValues(alpha: .78)
                          : colors.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: _historyColumnHandleWidth),
                SizedBox(width: widths.author),
                const SizedBox(width: _historyColumnHandleWidth),
                SizedBox(
                  width: widths.date,
                  child: Text(
                    '今天',
                    textAlign: TextAlign.end,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: isSelected
                          ? colors.onPrimary.withValues(alpha: .78)
                          : colors.onSurfaceVariant,
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

class _UncommittedGraphPainter extends CustomPainter {
  const _UncommittedGraphPainter({
    required this.color,
    required this.selected,
    required this.compact,
  });

  final Color color;
  final bool selected;
  final bool compact;

  @override
  void paint(Canvas canvas, Size size) {
    final x = _historyGraphLaneStart(compact);
    final y = size.height / 2;
    final rail = Paint()..color = color;
    canvas.drawRect(Rect.fromLTRB(x - 1.5, y, x + 1.5, size.height), rail);
    canvas.drawCircle(
      Offset(x, y),
      5,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
    if (selected) {
      canvas.drawCircle(
        Offset(x, y),
        6.5,
        Paint()
          ..color = color.withValues(alpha: .42)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(_UncommittedGraphPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.selected != selected ||
      oldDelegate.compact != compact;
}

/// Displays the history column labels while retaining keyboard-accessible
/// drag targets for adjusting their widths.
///
/// 中文：显示历史列表的列名，并保留可访问的列宽拖拽边界。
final class _HistoryColumnHeader extends StatelessWidget {
  const _HistoryColumnHeader({
    required this.widths,
    required this.onGraphDelta,
    required this.onDescriptionDelta,
    required this.onCommitDelta,
    required this.onAuthorDelta,
  });

  final _HistoryColumnWidths widths;
  final ValueChanged<double> onGraphDelta;
  final ValueChanged<double> onDescriptionDelta;
  final ValueChanged<double> onCommitDelta;
  final ValueChanged<double> onAuthorDelta;

  /// 中文：构建历史列表表头。
  /// English: Builds the history list column header.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      key: const ValueKey<String>('history-column-header'),
      height: 25,
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
          SizedBox(
            width: widths.graph,
            child: Text('图表', style: theme.textTheme.labelSmall),
          ),
          _ResizeDivider(
            axis: Axis.vertical,
            semanticsLabel: '表头调整图表列宽度',
            onDelta: onGraphDelta,
          ),
          Expanded(child: Text('描述', style: theme.textTheme.labelSmall)),
          _ResizeDivider(
            axis: Axis.vertical,
            semanticsLabel: '表头调整描述列宽度',
            onDelta: onDescriptionDelta,
          ),
          SizedBox(
            width: widths.commit,
            child: Text('提交', style: theme.textTheme.labelSmall),
          ),
          _ResizeDivider(
            axis: Axis.vertical,
            semanticsLabel: '表头调整提交列宽度',
            onDelta: onCommitDelta,
          ),
          SizedBox(
            width: widths.author,
            child: Text('作者', style: theme.textTheme.labelSmall),
          ),
          _ResizeDivider(
            axis: Axis.vertical,
            semanticsLabel: '表头调整作者列宽度',
            onDelta: onAuthorDelta,
          ),
          SizedBox(
            width: widths.date,
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

/// Keeps compact history rows free of table chrome while retaining the
/// keyboard-accessible drag targets used to adjust their columns.
///
/// 中文：在不显示历史行装饰的前提下保留可访问的历史列拖拽边界。
final class _HistoryResizeOverlay extends StatelessWidget {
  const _HistoryResizeOverlay({
    required this.widths,
    required this.onGraphDelta,
    required this.onDescriptionDelta,
    required this.onCommitDelta,
    required this.onAuthorDelta,
  });

  final _HistoryColumnWidths widths;
  final ValueChanged<double> onGraphDelta;
  final ValueChanged<double> onDescriptionDelta;
  final ValueChanged<double> onCommitDelta;
  final ValueChanged<double> onAuthorDelta;

  /// 中文：构建覆盖历史内容的四个列宽调整边界。
  /// English: Builds the four column-resize boundaries over the history body.
  @override
  Widget build(BuildContext context) {
    final descriptionWidth = math.max(
      0,
      widths.availableWidth -
          widths.graph -
          widths.commit -
          widths.author -
          widths.date -
          (_historyColumnHandleWidth * 4) -
          16,
    );
    final graphDivider = 8 + widths.graph;
    final descriptionDivider =
        graphDivider + _historyColumnHandleWidth + descriptionWidth;
    final commitDivider =
        descriptionDivider + _historyColumnHandleWidth + widths.commit;
    final authorDivider =
        commitDivider + _historyColumnHandleWidth + widths.author;

    return Positioned.fill(
      child: Stack(
        children: [
          _HistoryResizeHandle(
            left: graphDivider,
            semanticsLabel: '调整图表列宽度',
            onDelta: onGraphDelta,
          ),
          _HistoryResizeHandle(
            left: descriptionDivider,
            semanticsLabel: '调整描述列宽度',
            onDelta: onDescriptionDelta,
          ),
          _HistoryResizeHandle(
            left: commitDivider,
            semanticsLabel: '调整提交列宽度',
            onDelta: onCommitDelta,
          ),
          _HistoryResizeHandle(
            left: authorDivider,
            semanticsLabel: '调整作者列宽度',
            onDelta: onAuthorDelta,
          ),
        ],
      ),
    );
  }
}

/// Provides one invisible, mouse-discoverable resize target in history.
///
/// 中文：提供一个不干扰紧凑视觉的历史列宽拖拽目标。
final class _HistoryResizeHandle extends StatelessWidget {
  const _HistoryResizeHandle({
    required this.left,
    required this.semanticsLabel,
    required this.onDelta,
  });

  final double left;
  final String semanticsLabel;
  final ValueChanged<double> onDelta;

  /// 中文：构建定位的列宽拖拽目标。
  /// English: Builds the positioned column-resize drag target.
  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: left,
      top: 0,
      bottom: 0,
      width: _historyColumnHandleWidth,
      child: _ResizeDivider(
        axis: Axis.vertical,
        semanticsLabel: semanticsLabel,
        onDelta: onDelta,
        showIndicator: false,
      ),
    );
  }
}

class _CommitRow extends StatelessWidget {
  const _CommitRow({
    required this.commit,
    required this.currentBranch,
    required this.primaryLocalBranch,
    required this.ahead,
    required this.onTap,
    this.onDoubleTap,
    this.onContextAction,
    required this.showRemoteRefs,
    required this.compactGraph,
    required this.widths,
  });

  final CommitViewData commit;
  final String currentBranch;
  final String? primaryLocalBranch;
  final int ahead;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final ValueChanged<RepositoryCommitContextAction>? onContextAction;
  final bool showRemoteRefs;
  final bool compactGraph;
  final _HistoryColumnWidths widths;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final visibleRefs = _commitReferences()
        .where(
          (ref) =>
              showRemoteRefs || ref.kind != CommitReferenceKind.remoteBranch,
        )
        .take(3)
        .toList(growable: false);

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
          onDoubleTap: onDoubleTap,
          onSecondaryTapDown: onContextAction == null
              ? null
              : (details) => unawaited(_showContextMenu(context, details)),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            color: commit.isSelected ? colors.secondaryContainer : null,
            child: Row(
              children: [
                SizedBox(
                  width: widths.graph,
                  height: _historyRowHeight,
                  child: CustomPaint(
                    key: const ValueKey<String>('commit-graph-canvas'),
                    painter: _CommitGraphPainter(
                      graph: commit.graph,
                      colors: _graphColors(colors),
                      workspaceRailColor: colors.onSurfaceVariant,
                      backgroundColor: commit.isSelected
                          ? colors.secondaryContainer
                          : _graphBackground(colors),
                      selected: commit.isSelected,
                      compact: compactGraph,
                    ),
                  ),
                ),
                const SizedBox(width: _historyColumnHandleWidth),
                Expanded(
                  child: Row(
                    children: [
                      for (final CommitReferenceViewData ref
                          in visibleRefs) ...[
                        Flexible(
                          fit: FlexFit.loose,
                          child: Padding(
                            padding: const EdgeInsets.only(right: 5),
                            child: _RefLabel(
                              label: ref.label,
                              kind: _commitRefKind(ref),
                              graphColor:
                                  _graphPalette[commit.graph.colorIndex.abs() %
                                      _graphPalette.length],
                            ),
                          ),
                        ),
                        if (ahead > 0 &&
                            _commitRefKind(ref) ==
                                _CommitRefKind.primaryLocalBranch)
                          Flexible(
                            fit: FlexFit.loose,
                            child: Padding(
                              padding: const EdgeInsets.only(right: 5),
                              child: _AheadLabel(count: ahead),
                            ),
                          ),
                      ],
                      if (commit.isMerge)
                        Flexible(
                          fit: FlexFit.loose,
                          child: Padding(
                            padding: const EdgeInsets.only(right: 5),
                            child: Icon(
                              Icons.merge,
                              size: 13,
                              color: colors.onSurfaceVariant,
                            ),
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
                    ],
                  ),
                ),
                const SizedBox(width: _historyColumnHandleWidth),
                SizedBox(
                  width: widths.commit,
                  child: Text(
                    commit.shortOid,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: _historyColumnHandleWidth),
                SizedBox(
                  width: widths.author,
                  child: Text(
                    commit.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: _historyColumnHandleWidth),
                SizedBox(
                  width: widths.date,
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

  /// 中文：在指针位置显示提交操作菜单，提交写入仍交由应用层处理。
  /// English: Shows the commit action menu at the pointer; the app layer owns
  /// the actual Git mutation.
  Future<void> _showContextMenu(
    BuildContext context,
    TapDownDetails details,
  ) async {
    final handler = onContextAction;
    if (handler == null) return;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromLTWH(details.globalPosition.dx, details.globalPosition.dy, 0, 0),
      Offset.zero & overlay.size,
    );
    final action = await showMenu<RepositoryCommitContextAction>(
      context: context,
      position: position,
      items: const [
        PopupMenuItem<RepositoryCommitContextAction>(
          value: RepositoryCommitContextAction.checkout,
          height: 30,
          child: Text('检出…'),
        ),
        PopupMenuItem<RepositoryCommitContextAction>(
          value: RepositoryCommitContextAction.merge,
          height: 30,
          child: Text('合并…'),
        ),
        PopupMenuDivider(),
        PopupMenuItem<RepositoryCommitContextAction>(
          value: RepositoryCommitContextAction.tag,
          height: 30,
          child: Text('标签…'),
        ),
        PopupMenuItem<RepositoryCommitContextAction>(
          value: RepositoryCommitContextAction.createBranch,
          height: 30,
          child: Text('分支…'),
        ),
        PopupMenuDivider(),
        PopupMenuItem<RepositoryCommitContextAction>(
          value: RepositoryCommitContextAction.copyCommitHash,
          height: 30,
          child: Text('复制 SHA-1 到剪贴板'),
        ),
        PopupMenuDivider(),
        PopupMenuItem<RepositoryCommitContextAction>(
          value: RepositoryCommitContextAction.pushRevision,
          height: 30,
          child: Text('推送修订版本…'),
        ),
        PopupMenuItem<RepositoryCommitContextAction>(
          value: RepositoryCommitContextAction.rebase,
          height: 30,
          child: Text('变基…'),
        ),
        PopupMenuItem<RepositoryCommitContextAction>(
          value: RepositoryCommitContextAction.interactiveRebase,
          height: 30,
          child: Text('交互式变基…'),
        ),
        PopupMenuItem<RepositoryCommitContextAction>(
          value: RepositoryCommitContextAction.reset,
          height: 30,
          child: Text('将当前分支重置到此次提交'),
        ),
        PopupMenuItem<RepositoryCommitContextAction>(
          value: RepositoryCommitContextAction.revert,
          height: 30,
          child: Text('提交回滚'),
        ),
        PopupMenuItem<RepositoryCommitContextAction>(
          value: RepositoryCommitContextAction.createPatch,
          height: 30,
          child: Text('创建补丁…'),
        ),
        PopupMenuItem<RepositoryCommitContextAction>(
          value: RepositoryCommitContextAction.cherryPick,
          height: 30,
          child: Text('遴选'),
        ),
      ],
    );
    if (action != null) handler(action);
  }

  /// 中文：按真实引用来源区分 HEAD、远端、标签、主本地分支和其他本地分支标签。
  ///
  /// English: Classifies a ref label as HEAD, remote, tag, primary local, or
  /// other local using repository metadata rather than its display name.
  _CommitRefKind _commitRefKind(CommitReferenceViewData ref) {
    if (ref.kind == CommitReferenceKind.head) return _CommitRefKind.head;
    if (ref.kind == CommitReferenceKind.remoteBranch) {
      return _CommitRefKind.remoteBranch;
    }
    if (ref.kind == CommitReferenceKind.tag) return _CommitRefKind.tag;
    if (ref.label == primaryLocalBranch || ref.label == currentBranch) {
      return _CommitRefKind.primaryLocalBranch;
    }
    return _CommitRefKind.localBranch;
  }

  /// Builds typed commit references, including compatibility for presentation
  /// callers created before typed ref metadata was introduced.
  List<CommitReferenceViewData> _commitReferences() {
    if (commit.references.isNotEmpty) return commit.references;
    return [
      for (final ref in commit.refs)
        CommitReferenceViewData(
          label: ref,
          kind: ref == 'HEAD'
              ? CommitReferenceKind.head
              : commit.remoteRefs.contains(ref)
              ? CommitReferenceKind.remoteBranch
              : commit.tagRefs.contains(ref)
              ? CommitReferenceKind.tag
              : CommitReferenceKind.localBranch,
        ),
    ];
  }
}

class _CommitGraphPainter extends CustomPainter {
  const _CommitGraphPainter({
    required this.graph,
    required this.colors,
    required this.workspaceRailColor,
    required this.backgroundColor,
    required this.selected,
    required this.compact,
  });

  final CommitGraphViewData graph;
  final List<Color> colors;
  final Color workspaceRailColor;
  final Color backgroundColor;
  final bool selected;
  final bool compact;

  double get laneSpacing => _historyGraphLaneSpacing(compact);
  double get laneStart => _historyGraphLaneStart(compact);

  /// 中文：按车道索引循环选择提交图颜色，支持负索引。
  ///
  /// English: Selects a commit-graph color cyclically by lane index, including
  /// negative indices.
  Color _color(int index) => colors[index.abs() % colors.length];

  /// 中文：为未携带逻辑颜色的兼容图行提供车道颜色回退。
  /// English: Falls back to a physical lane color for legacy graph rows.
  Color _fallbackLaneColor(int lane) {
    if (!graph.hasReservedHeadLane) return _color(lane);
    return lane == 0 ? workspaceRailColor : _color(lane - 1);
  }

  Color _activeLaneColor(int index, int lane) =>
      index < graph.activeLaneColorIndices.length
      ? _color(graph.activeLaneColorIndices[index])
      : _fallbackLaneColor(lane);

  Color _incomingLaneColor(int lane) => _color(
    graph.incomingLaneColorIndices[lane] ??
        (graph.hasReservedHeadLane && lane > 0 ? lane - 1 : lane),
  );

  Color _parentLaneColor(int index, int lane) =>
      index < graph.parentLaneColorIndices.length
      ? _color(graph.parentLaneColorIndices[index])
      : _fallbackLaneColor(lane);

  /// 中文：将车道索引转换为图画布中的 X 坐标，让可调整列宽决定可见车道数量。
  ///
  /// English: Converts a lane index to a graph-canvas X coordinate, leaving
  /// the resizable column width to determine how many lanes remain visible.
  double _laneX(int lane) => laneStart + math.max(0, lane) * laneSpacing;

  /// 中文：在给定画布上绘制当前内容。
  /// English: Paints the current content onto the canvas.
  @override
  void paint(Canvas canvas, Size size) {
    final double centerY = size.height / 2;
    canvas.drawRect(Offset.zero & size, Paint()..color = backgroundColor);
    // CustomPaint does not clip by default. Without this boundary, logical
    // lanes beyond the graph budget paint over the description column. The
    // topology remains intact for later rows; only its excess visual rails
    // are hidden until the active lane count contracts again.
    final graphRightEdge = math.min(
      size.width,
      laneStart + (laneSpacing * (commitGraphMaximumVisibleLanes - 1)) + 7,
    );
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, graphRightEdge, size.height));
    if (graph.hasReservedHeadLane && graph.hasWorkspaceNode) {
      final reservedRailBottom = graph.lane == 0 && graph.parentLanes.isEmpty
          ? centerY
          : size.height;
      _drawVerticalRail(
        canvas,
        x: _laneX(0),
        top: 0,
        bottom: reservedRailBottom,
        color: workspaceRailColor,
      );
    }

    for (var index = 0; index < graph.activeLanes.length; index++) {
      final activeLane = graph.activeLanes[index];
      final destination = index < graph.activeLaneDestinations.length
          ? graph.activeLaneDestinations[index]
          : activeLane;
      _drawLaneConnection(
        canvas,
        fromLane: activeLane,
        toLane: destination,
        top: graph.previousLanes.contains(activeLane) ? 0 : centerY,
        centerY: centerY,
        bottom: size.height,
        color: _activeLaneColor(index, activeLane),
      );
    }

    for (final incomingLane in graph.incomingLanes) {
      _drawIncomingLaneConnection(
        canvas,
        fromLane: incomingLane,
        toLane: graph.lane,
        top: 0,
        centerY: centerY,
        color: _incomingLaneColor(incomingLane),
      );
    }

    final int colorIndex = graph.colorIndex;
    for (
      var parentIndex = 1;
      parentIndex < graph.parentLanes.length;
      parentIndex++
    ) {
      final parentLane = graph.parentLanes[parentIndex];
      _drawLaneConnection(
        canvas,
        fromLane: graph.lane,
        toLane: parentLane,
        top: centerY,
        centerY: centerY,
        bottom: size.height,
        color: _parentLaneColor(parentIndex, parentLane),
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
    canvas.drawCircle(Offset(_laneX(graph.lane), centerY), 4, dotPaint);
    canvas.restore();
  }

  /// 中文：让从上方延续的分支在当前父节点行内汇入节点，而不是提前转向。
  ///
  /// English: Converges a branch arriving from above into its parent on the
  /// current row instead of turning on the child row.
  void _drawIncomingLaneConnection(
    Canvas canvas, {
    required int fromLane,
    required int toLane,
    required double top,
    required double centerY,
    required Color color,
  }) {
    final sourceX = _laneX(fromLane);
    final targetX = _laneX(toLane);
    final turnY = centerY - (centerY - top) * .32;
    _drawVerticalRail(
      canvas,
      x: sourceX,
      top: top,
      bottom: turnY,
      color: color,
    );
    canvas.drawLine(
      Offset(sourceX, turnY),
      Offset(targetX, centerY),
      Paint()
        ..color = color
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.square,
    );
  }

  /// 中文：以接近 Sourcetree 的固定 2 像素宽度绘制车道竖线。
  ///
  /// English: Draws a lane's vertical rail at a Sourcetree-like fixed
  /// two-pixel width.
  void _drawVerticalRail(
    Canvas canvas, {
    required double x,
    required double top,
    required double bottom,
    required Color color,
  }) {
    canvas.drawRect(
      Rect.fromLTRB(x - 1, top, x + 1, bottom),
      Paint()..color = color,
    );
  }

  /// 中文：绘制当前活动车道到下一行目标车道的紧凑斜向连接。
  ///
  /// English: Draws a compact diagonal connection from an active lane to its
  /// next-row target lane.
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
    canvas.drawLine(
      Offset(sourceX, centerY),
      Offset(targetX, bottom),
      Paint()
        ..color = color
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.square,
    );
  }

  /// 中文：判断绘制结果是否需要刷新。
  /// English: Determines whether the painting needs refreshing.
  @override
  bool shouldRepaint(_CommitGraphPainter oldDelegate) {
    return oldDelegate.graph != graph ||
        oldDelegate.selected != selected ||
        oldDelegate.compact != compact ||
        oldDelegate.colors != colors ||
        oldDelegate.workspaceRailColor != workspaceRailColor ||
        oldDelegate.backgroundColor != backgroundColor;
  }
}

/// 中文：返回与当前主题一致的历史列表背景色。
///
/// English: Returns the history-list background color for the active theme.
Color _historyBackground(ColorScheme colors) => colors.surface;

/// 中文：返回提交图背景色，使其与历史列表保持一致。
///
/// English: Returns the commit-graph background color, matching the history
/// list.
Color _graphBackground(ColorScheme colors) => _historyBackground(colors);

/// 中文：返回用于区分提交图车道的固定高对比度颜色序列。
///
/// English: Returns the fixed, high-contrast color sequence used to
/// distinguish commit-graph lanes.
const Color _graphPrimaryBlue = Color(0xFF0B6FCB);
const Color _graphBranchRed = Color(0xFFD8452A);
const Color _graphBaseOrange = Color(0xFFF28C00);

const List<Color> _graphPalette = [
  _graphPrimaryBlue,
  _graphBaseOrange,
  _graphBranchRed,
  Color(0xFF2FA86F),
  Color(0xFF6254B8),
  Color(0xFF00A0BE),
  Color(0xFF6F7B80),
  Color(0xFF9A7800),
];

List<Color> _graphColors(ColorScheme colors) => _graphPalette;

enum _CommitRefKind { primaryLocalBranch, localBranch, remoteBranch, tag, head }

class _RefLabel extends StatelessWidget {
  const _RefLabel({required this.label, required this.kind, this.graphColor});

  final String label;
  final _CommitRefKind kind;
  final Color? graphColor;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool dark = colors.brightness == Brightness.dark;
    final localColor =
        graphColor ??
        (kind == _CommitRefKind.primaryLocalBranch
            ? _graphPrimaryBlue
            : _graphBranchRed);
    final localForeground = dark
        ? Color.alphaBlend(Colors.white.withValues(alpha: .42), localColor)
        : localColor;
    final (
      Color background,
      Color foreground,
      Color border,
      IconData icon,
    ) = switch (kind) {
      _CommitRefKind.primaryLocalBranch => (
        Color.alphaBlend(
          localColor.withValues(alpha: dark ? .34 : .16),
          colors.surface,
        ),
        localForeground,
        localColor,
        Icons.call_split,
      ),
      _CommitRefKind.localBranch => (
        Color.alphaBlend(
          localColor.withValues(alpha: dark ? .32 : .15),
          colors.surface,
        ),
        localForeground,
        localColor,
        Icons.call_split,
      ),
      _CommitRefKind.remoteBranch => (
        Color.alphaBlend(
          _graphBaseOrange.withValues(alpha: dark ? .25 : .13),
          colors.surface,
        ),
        dark ? const Color(0xFFFFC26E) : const Color(0xFF9A5700),
        _graphBaseOrange,
        Icons.cloud_outlined,
      ),
      _CommitRefKind.tag => (
        Color.alphaBlend(
          _graphBaseOrange.withValues(alpha: dark ? .20 : .10),
          colors.surface,
        ),
        dark ? const Color(0xFFFFC26E) : const Color(0xFF9A5700),
        _graphBaseOrange,
        Icons.sell_outlined,
      ),
      _CommitRefKind.head => (
        Color.alphaBlend(
          _graphBaseOrange.withValues(alpha: dark ? .25 : .13),
          colors.surface,
        ),
        dark ? const Color(0xFFFFC26E) : const Color(0xFF9A5700),
        _graphBaseOrange,
        Icons.sell_outlined,
      ),
    };
    return Container(
      key: ValueKey<String>('commit-ref-$label'),
      constraints: const BoxConstraints(maxWidth: 180),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: foreground),
          const SizedBox(width: 2),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: foreground,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AheadLabel extends StatelessWidget {
  const _AheadLabel({required this.count});

  final int count;

  /// 中文：显示与主分支蓝色车道对应的领先提交数标签。
  /// English: Shows the ahead count using the primary branch lane color.
  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey<String>('commit-ahead-label'),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: _graphPrimaryBlue,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        '超前$count个版本',
        maxLines: 1,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w700,
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
    required this.onGroupStageToggled,
    required this.onConflictAction,
    required this.onRevealInFinder,
    required this.onRemove,
    required this.onCommitFileSelected,
  });

  final RepositoryViewData repository;
  final RepositoryChangeCallback? onSelected;
  final RepositoryChangeStageCallback? onStageToggled;
  final RepositoryChangeGroupStageCallback? onGroupStageToggled;
  final RepositoryConflictActionCallback? onConflictAction;
  final RepositoryChangeFilesCallback? onRevealInFinder;
  final RepositoryChangeFilesCallback? onRemove;
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
      onGroupStageToggled: onGroupStageToggled,
      onConflictAction: onConflictAction,
      onRevealInFinder: onRevealInFinder,
      onRemove: onRemove,
    );
  }
}

/// Reuses the workspace's selected-commit file list and Diff preview.
/// 中文：复用工作区中所选提交的文件列表与 Diff 预览。
class RepositoryCommitChangesPane extends StatelessWidget {
  const RepositoryCommitChangesPane({
    super.key,
    required this.repository,
    required this.onSelected,
    this.title = '提交改动',
  });

  final RepositoryViewData repository;
  final RepositoryCommitFileCallback? onSelected;
  final String title;

  @override
  Widget build(BuildContext context) => _CommitChangesPane(
    repository: repository,
    onSelected: onSelected,
    title: title,
  );
}

class _CommitChangesPane extends StatelessWidget {
  const _CommitChangesPane({
    required this.repository,
    required this.onSelected,
    this.title = '提交改动',
  });

  final RepositoryViewData repository;
  final RepositoryCommitFileCallback? onSelected;
  final String title;

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
            title: title,
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

class _ChangesPane extends StatefulWidget {
  const _ChangesPane({
    required this.repository,
    required this.onSelected,
    required this.onStageToggled,
    required this.onGroupStageToggled,
    required this.onConflictAction,
    required this.onRevealInFinder,
    required this.onRemove,
  });

  final RepositoryViewData repository;
  final RepositoryChangeCallback? onSelected;
  final RepositoryChangeStageCallback? onStageToggled;
  final RepositoryChangeGroupStageCallback? onGroupStageToggled;
  final RepositoryConflictActionCallback? onConflictAction;
  final RepositoryChangeFilesCallback? onRevealInFinder;
  final RepositoryChangeFilesCallback? onRemove;

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
                          onSelected: widget.onSelected,
                          onStageToggled: widget.onStageToggled,
                          onGroupStageToggled: widget.onGroupStageToggled,
                          onConflictAction: widget.onConflictAction,
                          onRevealInFinder: widget.onRevealInFinder,
                          onRemove: widget.onRemove,
                          currentBranch: repository.currentBranch,
                        )
                      : _DiffPreview(
                          diff: repository.diff,
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
                        onSelected: widget.onSelected,
                        onStageToggled: widget.onStageToggled,
                        onGroupStageToggled: widget.onGroupStageToggled,
                        onConflictAction: widget.onConflictAction,
                        onRevealInFinder: widget.onRevealInFinder,
                        onRemove: widget.onRemove,
                        currentBranch: repository.currentBranch,
                      ),
                    ),
                    _ResizeDivider(
                      axis: Axis.vertical,
                      semanticsLabel: '调整文件列表宽度',
                      onDelta: (delta) => setState(() {
                        _fileListWidth = fileListWidth + delta;
                      }),
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

/// Full workspace surface used when the file-status ref is selected.
///
/// 中文：文件状态选中时使用的完整工作区界面，保留文件操作与 Diff，并提供
/// 不直接执行 Git 的提交入口。
class _WorkspaceChangesView extends StatelessWidget {
  const _WorkspaceChangesView({
    required this.repository,
    required this.onSelected,
    required this.onStageToggled,
    required this.onGroupStageToggled,
    required this.onConflictAction,
    required this.onRevealInFinder,
    required this.onRemove,
    required this.onCommit,
  });

  final RepositoryViewData repository;
  final RepositoryChangeCallback? onSelected;
  final RepositoryChangeStageCallback? onStageToggled;
  final RepositoryChangeGroupStageCallback? onGroupStageToggled;
  final RepositoryConflictActionCallback? onConflictAction;
  final RepositoryChangeFilesCallback? onRevealInFinder;
  final RepositoryChangeFilesCallback? onRemove;
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
            onStageToggled: onStageToggled,
            onGroupStageToggled: onGroupStageToggled,
            onConflictAction: onConflictAction,
            onRevealInFinder: onRevealInFinder,
            onRemove: onRemove,
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
    required this.onSelected,
    required this.onStageToggled,
    required this.onGroupStageToggled,
    required this.onConflictAction,
    required this.onRevealInFinder,
    required this.onRemove,
    required this.currentBranch,
  });

  final List<RepositoryChangeViewData> changes;
  final RepositoryChangeCallback? onSelected;
  final RepositoryChangeStageCallback? onStageToggled;
  final RepositoryChangeGroupStageCallback? onGroupStageToggled;
  final RepositoryConflictActionCallback? onConflictAction;
  final RepositoryChangeFilesCallback? onRevealInFinder;
  final RepositoryChangeFilesCallback? onRemove;
  final String currentBranch;

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
  }

  @override
  void didUpdateWidget(_ChangeList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final available = widget.changes.map(_changeSelectionKey).toSet();
    _selectedKeys.removeWhere((key) => !available.contains(key));
    if (_selectedKeys.isEmpty) _syncModelSelection();
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
  }

  void _toggleSelectedStage(bool stage) {
    final selected = _selectedChanges
        .where((change) => change.canToggleStage && change.isStaged != stage)
        .toList(growable: false);
    if (selected.isEmpty) return;
    final result = widget.onGroupStageToggled?.call(selected, stage);
    if (result is Future<void>) unawaited(result);
  }

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
              child: _ChangeGroupViewport(
                child: _ChangeGroup(
                  title: '已暂存文件',
                  isChecked: true,
                  changes: staged,
                  selectedKeys: _selectedKeys,
                  selectedChanges: () => _selectedChanges,
                  onSelected: _selectChange,
                  onContextMenuRequested: _prepareContextMenu,
                  onSelectedStageToggled: _toggleSelectedStage,
                  onStageToggled: widget.onStageToggled,
                  onGroupStageToggled: widget.onGroupStageToggled,
                  onConflictAction: widget.onConflictAction,
                  onRevealInFinder: widget.onRevealInFinder,
                  onRemove: widget.onRemove,
                  currentBranch: widget.currentBranch,
                ),
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
              child: _ChangeGroupViewport(
                child: _ChangeGroup(
                  title: '未暂存文件',
                  isChecked: false,
                  changes: unstaged,
                  selectedKeys: _selectedKeys,
                  selectedChanges: () => _selectedChanges,
                  onSelected: _selectChange,
                  onContextMenuRequested: _prepareContextMenu,
                  onSelectedStageToggled: _toggleSelectedStage,
                  onStageToggled: widget.onStageToggled,
                  onGroupStageToggled: widget.onGroupStageToggled,
                  onConflictAction: widget.onConflictAction,
                  onRevealInFinder: widget.onRevealInFinder,
                  onRemove: widget.onRemove,
                  currentBranch: widget.currentBranch,
                ),
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
    required this.selectedKeys,
    required this.selectedChanges,
    required this.onSelected,
    required this.onContextMenuRequested,
    required this.onSelectedStageToggled,
    required this.onRevealInFinder,
    required this.onRemove,
    required this.onStageToggled,
    required this.onGroupStageToggled,
    required this.onConflictAction,
    required this.currentBranch,
  });

  final String title;
  final bool isChecked;
  final List<RepositoryChangeViewData> changes;
  final Set<String> selectedKeys;
  final ValueGetter<List<RepositoryChangeViewData>> selectedChanges;
  final ValueChanged<RepositoryChangeViewData> onSelected;
  final ValueChanged<RepositoryChangeViewData> onContextMenuRequested;
  final ValueChanged<bool> onSelectedStageToggled;
  final RepositoryChangeFilesCallback? onRevealInFinder;
  final RepositoryChangeFilesCallback? onRemove;
  final RepositoryChangeStageCallback? onStageToggled;
  final RepositoryChangeGroupStageCallback? onGroupStageToggled;
  final RepositoryConflictActionCallback? onConflictAction;
  final String currentBranch;

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
          height: 30,
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
            height: 34,
            child: _ChangeTile(
              change: change,
              isSelected: selectedKeys.contains(_changeSelectionKey(change)),
              selectedChanges: selectedChanges,
              onTap: () => onSelected(change),
              onContextMenuRequested: () => onContextMenuRequested(change),
              onSelectedStageToggled: onSelectedStageToggled,
              onRevealInFinder: onRevealInFinder,
              onRemove: onRemove,
              onStageToggled: onStageToggled == null
                  ? null
                  : () => onStageToggled!(change),
              onConflictAction: onConflictAction == null
                  ? null
                  : (action) => onConflictAction!(change, action),
              currentBranch: currentBranch,
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
    required this.onRevealInFinder,
    required this.onRemove,
    required this.onStageToggled,
    required this.onConflictAction,
    required this.currentBranch,
  });

  final RepositoryChangeViewData change;
  final bool isSelected;
  final ValueGetter<List<RepositoryChangeViewData>> selectedChanges;
  final VoidCallback? onTap;
  final VoidCallback onContextMenuRequested;
  final ValueChanged<bool> onSelectedStageToggled;
  final RepositoryChangeFilesCallback? onRevealInFinder;
  final RepositoryChangeFilesCallback? onRemove;
  final VoidCallback? onStageToggled;
  final ValueChanged<RepositoryConflictAction>? onConflictAction;
  final String currentBranch;

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

    final content = Semantics(
      button: true,
      selected: isSelected,
      label:
          '${change.isStaged ? "已暂存" : "未暂存"}，${_changeKindLabel(change.kind)}，${change.path}',
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
                  message: !change.canToggleStage
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
                          onStageToggled == null || !change.canToggleStage
                          ? null
                          : (_) => onStageToggled!(),
                      visualDensity: const VisualDensity(
                        horizontal: -4,
                        vertical: -4,
                      ),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      side: BorderSide(color: colors.onSurfaceVariant),
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
        MenuItemButton(onPressed: onTap, child: const Text('打开')),
        MenuItemButton(
          onPressed: onRevealInFinder == null
              ? null
              : () {
                  final result = onRevealInFinder!(selectedChanges());
                  if (result is Future<void>) unawaited(result);
                },
          child: const Text('在 Finder 中显示'),
        ),
        MenuItemButton(
          onPressed: () {
            final paths = selectedChanges().map((item) => item.path).join('\n');
            unawaited(Clipboard.setData(ClipboardData(text: paths)));
          },
          child: const Text('复制路径到剪贴板'),
        ),
        const MenuItemButton(onPressed: null, child: Text('在终端中打开')),
        const MenuItemButton(onPressed: null, child: Text('快速查看')),
        const Divider(height: 1),
        const MenuItemButton(onPressed: null, child: Text('外部差异比对')),
        const MenuItemButton(onPressed: null, child: Text('创建补丁…')),
        const MenuItemButton(onPressed: null, child: Text('应用补丁…')),
        const Divider(height: 1),
        MenuItemButton(
          onPressed:
              selectedChanges().any(
                (item) => !item.isStaged && item.canToggleStage,
              )
              ? () => onSelectedStageToggled(true)
              : null,
          child: const Text('添加到索引'),
        ),
        MenuItemButton(
          onPressed:
              selectedChanges().any(
                (item) => item.isStaged && item.canToggleStage,
              )
              ? () => onSelectedStageToggled(false)
              : null,
          child: const Text('从索引中取消暂存'),
        ),
        MenuItemButton(
          onPressed:
              onRemove != null &&
                  selectedChanges().every(
                    (item) => item.kind == RepositoryChangeKind.untracked,
                  )
              ? () {
                  final result = onRemove!(selectedChanges());
                  if (result is Future<void>) unawaited(result);
                }
              : null,
          child: const Text('移除'),
        ),
        const MenuItemButton(onPressed: null, child: Text('停止追踪')),
        const MenuItemButton(onPressed: null, child: Text('忽略…')),
        const Divider(height: 1),
        if (change.kind == RepositoryChangeKind.conflicted &&
            onConflictAction != null)
          SubmenuButton(
            leadingIcon: const Icon(Icons.merge_type, size: 18),
            menuChildren: _conflictMenuChildren(),
            child: const Text('解决冲突'),
          ),
        const MenuItemButton(onPressed: null, child: Text('查看选中的修改日志…')),
        const MenuItemButton(onPressed: null, child: Text('审核选定的项目')),
      ],
      builder: (context, controller, child) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapDown: (details) {
          onContextMenuRequested();
          controller.open(position: details.localPosition);
        },
        child: child,
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
        child: Text('使用“我的”版本解决（保留来自 $currentBranch 的更改）'),
      ),
      MenuItemButton(
        onPressed: () => handler(RepositoryConflictAction.useTheirs),
        child: const Text('使用“他们的”版本解决（接受合并来源的更改）'),
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

/// Reuses the workspace's selected-commit metadata pane.
/// 中文：复用工作区中所选提交的元数据面板。
class RepositoryCommitDetailsPane extends StatelessWidget {
  const RepositoryCommitDetailsPane({super.key, required this.details});

  final CommitDetailsViewData? details;

  @override
  Widget build(BuildContext context) => _CommitDetailsPane(details: details);
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
          if (details.references.isNotEmpty || details.refs.isNotEmpty) ...[
            const SizedBox(height: 9),
            Wrap(
              spacing: 5,
              runSpacing: 5,
              children: [
                for (final CommitReferenceViewData ref in _detailReferences(
                  details,
                ))
                  _RefLabel(label: ref.label, kind: _detailsRefKind(ref)),
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

  /// 中文：按提交详情引用的真实来源复用历史行颜色语义。
  /// English: Reuses history-row colors from the typed commit-detail ref.
  _CommitRefKind _detailsRefKind(CommitReferenceViewData ref) {
    if (ref.kind == CommitReferenceKind.head) return _CommitRefKind.head;
    if (ref.kind == CommitReferenceKind.remoteBranch) {
      return _CommitRefKind.remoteBranch;
    }
    if (ref.kind == CommitReferenceKind.tag) return _CommitRefKind.tag;
    if (ref.label == details.primaryLocalBranch ||
        ref.label == details.currentBranch) {
      return _CommitRefKind.primaryLocalBranch;
    }
    return _CommitRefKind.localBranch;
  }

  /// Builds typed detail refs and supports legacy callers with string labels.
  List<CommitReferenceViewData> _detailReferences(
    CommitDetailsViewData details,
  ) {
    if (details.references.isNotEmpty) return details.references;
    return [
      for (final ref in details.refs)
        CommitReferenceViewData(
          label: ref,
          kind: ref == 'HEAD'
              ? CommitReferenceKind.head
              : details.remoteRefs.contains(ref)
              ? CommitReferenceKind.remoteBranch
              : details.tagRefs.contains(ref)
              ? CommitReferenceKind.tag
              : CommitReferenceKind.localBranch,
        ),
    ];
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
    required this.onChangeGroupStageToggled,
    required this.onConflictAction,
    required this.onRevealInFinder,
    required this.onRemove,
    required this.onCommitFileSelected,
  });

  final _InspectorTab selectedTab;
  final ValueChanged<_InspectorTab> onTabChanged;
  final RepositoryViewData repository;
  final RepositoryChangeCallback? onChangeSelected;
  final RepositoryChangeStageCallback? onChangeStageToggled;
  final RepositoryChangeGroupStageCallback? onChangeGroupStageToggled;
  final RepositoryConflictActionCallback? onConflictAction;
  final RepositoryChangeFilesCallback? onRevealInFinder;
  final RepositoryChangeFilesCallback? onRemove;
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
              onGroupStageToggled: onChangeGroupStageToggled,
              onConflictAction: onConflictAction,
              onRevealInFinder: onRevealInFinder,
              onRemove: onRemove,
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

class _HistorySplitBar extends StatelessWidget {
  const _HistorySplitBar({
    required this.query,
    required this.onSearchChanged,
    required this.semanticsLabel,
    required this.onDelta,
  });

  final String query;
  final ValueChanged<String>? onSearchChanged;
  final String semanticsLabel;
  final ValueChanged<double> onDelta;

  /// 中文：构建位于历史与检查器之间、右侧承载搜索框的可拖拽工具条。
  /// English: Builds the draggable history/inspector bar with search aligned
  /// to its trailing edge.
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return Material(
      color: colors.surfaceContainerLow,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeRow,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onVerticalDragUpdate: (DragUpdateDetails details) =>
              onDelta(details.delta.dy),
          child: Semantics(
            label: semanticsLabel,
            slider: true,
            child: Container(
              key: const ValueKey<String>('history-split-bar'),
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: colors.outlineVariant),
                  bottom: BorderSide(color: colors.outlineVariant),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.drag_handle,
                    size: 16,
                    color: colors.onSurfaceVariant,
                  ),
                  const Spacer(),
                  SizedBox(
                    key: const ValueKey<String>('history-search-slot'),
                    width: 190,
                    height: 28,
                    child: _HistorySearchField(
                      query: query,
                      onChanged: onSearchChanged,
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

class _ResizeDivider extends StatelessWidget {
  const _ResizeDivider({
    required this.axis,
    required this.semanticsLabel,
    required this.onDelta,
    this.showIndicator = true,
  });

  final Axis axis;
  final String semanticsLabel;
  final ValueChanged<double> onDelta;
  final bool showIndicator;

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
            child: showIndicator
                ? Container(
                    width: vertical ? 1 : double.infinity,
                    height: vertical ? double.infinity : 1,
                    color: dividerColor,
                  )
                : null,
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
    return Material(
      color: colors.errorContainer,
      elevation: 1,
      child: Semantics(
        liveRegion: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
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
    );
  }
}
