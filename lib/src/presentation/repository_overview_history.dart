part of 'repository_overview.dart';

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

  // Building a fallback graph is O(n) in the loaded history.  Keep the
  // derived value for the current immutable commit list so resizing columns
  // or switching inspector tabs does not rebuild the whole graph.
  List<CommitViewData>? _fallbackGraphCommits;
  String? _fallbackGraphHeadId;
  bool? _fallbackGraphDetachedHead;
  Map<String, CommitGraphViewData> _fallbackGraphCache =
      const <String, CommitGraphViewData>{};

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
      final target = (rowIndex * _scaledDenseHeight(context, _historyRowHeight))
          .clamp(0.0, _scrollController.position.maxScrollExtent);
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
    final historyRowHeight = _scaledDenseHeight(context, _historyRowHeight);
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
        ? _fallbackGraphsForCached(
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
                                            historyRowHeight * 2) {
                                      widget.onLoadMore?.call();
                                    }
                                    return false;
                                  },
                                  child: ListView.builder(
                                    key: const ValueKey<String>('history-list'),
                                    controller: _scrollController,
                                    itemExtent: historyRowHeight,
                                    itemCount: historyListItemCount,
                                    itemBuilder: (BuildContext context, int index) {
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
                                      final graphWithWorkspace = graph.copyWith(
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
                                            : () => widget.onSelected!(commit),
                                        onDoubleTap:
                                            widget
                                                    .repository
                                                    .blocksRepositoryMutations ||
                                                widget.onActivated == null
                                            ? null
                                            : () => widget.onActivated!(commit),
                                        onContextAction:
                                            widget.onContextAction == null
                                            ? null
                                            : (action) =>
                                                  widget.onContextAction!(
                                                    commit,
                                                    action,
                                                  ),
                                        mutationActionsEnabled: !widget
                                            .repository
                                            .blocksRepositoryMutations,
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

  /// 中文：缓存当前历史列表的后备 Graph，避免普通布局重建重复 O(n) 计算。
  ///
  /// English: Caches the fallback graph for the current history list so
  /// routine layout rebuilds do not repeat the O(n) calculation.
  Map<String, CommitGraphViewData> _fallbackGraphsForCached(
    List<CommitViewData> commits, {
    required String? headId,
    required bool isDetachedHead,
  }) {
    if (identical(_fallbackGraphCommits, commits) &&
        _fallbackGraphHeadId == headId &&
        _fallbackGraphDetachedHead == isDetachedHead) {
      return _fallbackGraphCache;
    }
    final next = _fallbackGraphsFor(
      commits,
      headId: headId,
      isDetachedHead: isDetachedHead,
    );
    _fallbackGraphCommits = commits;
    _fallbackGraphHeadId = headId;
    _fallbackGraphDetachedHead = isDetachedHead;
    _fallbackGraphCache = next;
    return next;
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
                  height: _scaledDenseHeight(context, _historyRowHeight),
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
      height: _scaledDenseHeight(context, 25),
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
              textAlign: TextAlign.start,
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
    required this.mutationActionsEnabled,
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
  final bool mutationActionsEnabled;
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

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.enter): ?onDoubleTap,
        if (onContextAction != null) ...{
          const SingleActivator(LogicalKeyboardKey.f10, shift: true): () =>
              unawaited(_showContextMenu(context, _globalCenter(context))),
          const SingleActivator(LogicalKeyboardKey.contextMenu): () =>
              unawaited(_showContextMenu(context, _globalCenter(context))),
        },
      },
      child: Semantics(
        button: true,
        selected: commit.isSelected,
        onLongPress: onContextAction == null
            ? null
            : () =>
                  unawaited(_showContextMenu(context, _globalCenter(context))),
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
                : (details) => unawaited(
                    _showContextMenu(context, details.globalPosition),
                  ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              color: commit.isSelected ? colors.secondaryContainer : null,
              child: Row(
                children: [
                  SizedBox(
                    width: widths.graph,
                    height: _scaledDenseHeight(context, _historyRowHeight),
                    child: RepaintBoundary(
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
                                    _graphPalette[commit.graph.colorIndex
                                            .abs() %
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
                              fontWeight: commit.isHead
                                  ? FontWeight.w600
                                  : null,
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
                      textAlign: TextAlign.start,
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
      ),
    );
  }

  /// 中文：在指针位置显示提交操作菜单，提交写入仍交由应用层处理。
  /// English: Shows the commit action menu at the pointer; the app layer owns
  /// the actual Git mutation.
  Future<void> _showContextMenu(
    BuildContext context,
    Offset globalPosition,
  ) async {
    final handler = onContextAction;
    if (handler == null) return;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final position = RelativeRect.fromRect(
      globalPosition & const Size(1, 1),
      Offset.zero & overlay.size,
    );
    final action = await showMenu<RepositoryCommitContextAction>(
      context: context,
      position: position,
      items: [
        PopupMenuItem<RepositoryCommitContextAction>(
          value: RepositoryCommitContextAction.checkout,
          enabled: mutationActionsEnabled,
          height: 30,
          child: Text('检出…'),
        ),
        PopupMenuItem<RepositoryCommitContextAction>(
          value: RepositoryCommitContextAction.merge,
          enabled: mutationActionsEnabled,
          height: 30,
          child: Text('合并…'),
        ),
        PopupMenuDivider(),
        PopupMenuItem<RepositoryCommitContextAction>(
          value: RepositoryCommitContextAction.tag,
          enabled: mutationActionsEnabled,
          height: 30,
          child: Text('标签…'),
        ),
        PopupMenuItem<RepositoryCommitContextAction>(
          value: RepositoryCommitContextAction.createBranch,
          enabled: mutationActionsEnabled,
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
          enabled: mutationActionsEnabled,
          height: 30,
          child: Text('推送修订版本…'),
        ),
        PopupMenuItem<RepositoryCommitContextAction>(
          value: RepositoryCommitContextAction.rebase,
          enabled: mutationActionsEnabled,
          height: 30,
          child: Text('变基…'),
        ),
        PopupMenuItem<RepositoryCommitContextAction>(
          value: RepositoryCommitContextAction.interactiveRebase,
          enabled: mutationActionsEnabled,
          height: 30,
          child: Text('交互式变基…'),
        ),
        PopupMenuItem<RepositoryCommitContextAction>(
          value: RepositoryCommitContextAction.reset,
          enabled: mutationActionsEnabled,
          height: 30,
          child: Text('将当前分支重置到此次提交'),
        ),
        PopupMenuItem<RepositoryCommitContextAction>(
          value: RepositoryCommitContextAction.revert,
          enabled: mutationActionsEnabled,
          height: 30,
          child: Text('提交回滚'),
        ),
        PopupMenuItem<RepositoryCommitContextAction>(
          value: RepositoryCommitContextAction.createPatch,
          enabled: mutationActionsEnabled,
          height: 30,
          child: Text('创建补丁…'),
        ),
        PopupMenuItem<RepositoryCommitContextAction>(
          value: RepositoryCommitContextAction.cherryPick,
          enabled: mutationActionsEnabled,
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
