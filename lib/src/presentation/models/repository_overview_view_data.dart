/// Pure Dart view data consumed by the repository overview presentation.
///
/// These types deliberately have no Flutter dependency so the application
/// layer can map Git snapshots into immutable UI input without importing
/// widgets.
enum RepositoryOverviewState { noRepository, loading, ready, error }

enum RepositoryAction {
  openRepository,
  cloneRepository,
  cancelClone,
  cancelFetch,
  cancelPull,
  continueRebase,
  abortRebase,
  cancelPush,
  initializeRepository,
  fetch,
  pull,
  push,
  showOperationLog,
  createBranch,
  mergeBranch,
  commit,
  refresh,
  retry,
}

enum RepositoryRefKind { workspace, localBranch, remoteBranch, tag, stash }

/// Actions available from the context menu of one repository reference.
enum RepositoryRefContextAction {
  fetchOrigin,
  pullCurrentBranch,
  pushCurrentBranch,
  refresh,
  checkout,
  mergeIntoCurrent,
  createBranchFromReference,
  renameLocalBranch,
  deleteLocalBranch,
}

enum RepositoryChangeKind {
  modified,
  added,
  deleted,
  renamed,
  copied,
  untracked,
  conflicted,
}

/// Actions available from the context menu of a conflicted working-tree file.
enum RepositoryConflictAction {
  launchInternalDiffTool,
  useOurs,
  useTheirs,
  restartMerge,
  markResolved,
  markUnresolved,
}

enum DiffLineKind { fileHeader, hunkHeader, context, addition, deletion, note }

final class RepositoryOverviewViewData {
  const RepositoryOverviewViewData._({
    required this.state,
    this.repository,
    this.title,
    this.message,
    this.technicalDetails,
    this.canCancelOperation = false,
  });

  const RepositoryOverviewViewData.noRepository({
    String? title,
    String? message,
  }) : this._(
         state: RepositoryOverviewState.noRepository,
         title: title,
         message: message,
       );

  const RepositoryOverviewViewData.loading({
    String? title,
    String? message,
    RepositoryViewData? staleRepository,
    bool canCancelOperation = false,
  }) : this._(
         state: RepositoryOverviewState.loading,
         repository: staleRepository,
         title: title,
         message: message,
         canCancelOperation: canCancelOperation,
       );

  const RepositoryOverviewViewData.ready(RepositoryViewData repository)
    : this._(state: RepositoryOverviewState.ready, repository: repository);

  const RepositoryOverviewViewData.error({
    String? title,
    required String message,
    String? technicalDetails,
    RepositoryViewData? staleRepository,
  }) : this._(
         state: RepositoryOverviewState.error,
         repository: staleRepository,
         title: title,
         message: message,
         technicalDetails: technicalDetails,
       );

  final RepositoryOverviewState state;
  final RepositoryViewData? repository;
  final String? title;
  final String? message;
  final String? technicalDetails;
  final bool canCancelOperation;
}

final class RepositoryViewData {
  const RepositoryViewData({
    required this.name,
    required this.path,
    required this.currentBranch,
    this.primaryLocalBranch,
    this.headOid,
    this.ahead = 0,
    this.behind = 0,
    this.isDetachedHead = false,
    this.isRefreshing = false,
    this.isFetching = false,
    this.isPulling = false,
    this.isPushing = false,
    this.isRebaseInProgress = false,
    this.isWorkingTreeClean = true,
    this.refs = const [],
    this.commits = const [],
    this.focusedRefCommitId,
    this.changes = const [],
    this.selectedCommit,
    this.commitChanges = const [],
    this.selectedCommitFile,
    this.commitDiff = const DiffViewData.empty(),
    this.isCommitLoading = false,
    this.selectedChange,
    this.diff = const DiffViewData.empty(),
    this.footer = const RepositoryFooterViewData(),
    this.disabledActions = const {},
    this.searchQuery = '',
  });

  final String name;
  final String path;
  final String currentBranch;
  final String? primaryLocalBranch;
  final String? headOid;
  final int ahead;
  final int behind;
  final bool isDetachedHead;
  final bool isRefreshing;
  final bool isFetching;
  final bool isPulling;
  final bool isPushing;
  final bool isRebaseInProgress;
  final bool isWorkingTreeClean;
  final List<RepositoryRefViewData> refs;
  final List<CommitViewData> commits;
  final String? focusedRefCommitId;
  final List<RepositoryChangeViewData> changes;
  final CommitDetailsViewData? selectedCommit;
  final List<CommitFileViewData> commitChanges;
  final CommitFileViewData? selectedCommitFile;
  final DiffViewData commitDiff;
  final bool isCommitLoading;
  final RepositoryChangeViewData? selectedChange;
  final DiffViewData diff;
  final RepositoryFooterViewData footer;
  final Set<RepositoryAction> disabledActions;
  final String searchQuery;

  int get stagedChangeCount => changes
      .where((RepositoryChangeViewData change) => change.isStaged)
      .length;

  int get unstagedChangeCount => changes.length - stagedChangeCount;
}

final class RepositoryRefViewData {
  const RepositoryRefViewData({
    required this.id,
    required this.label,
    required this.kind,
    this.secondaryLabel,
    this.isCurrent = false,
    this.isSelected = false,
    this.ahead = 0,
    this.behind = 0,
    this.childCount,
  });

  final String id;
  final String label;
  final RepositoryRefKind kind;
  final String? secondaryLabel;
  final bool isCurrent;
  final bool isSelected;
  final int ahead;
  final int behind;
  final int? childCount;
}

/// A small topology input used to calculate graph lanes for a history view.
final class CommitGraphNode {
  const CommitGraphNode({required this.oid, this.parents = const []});

  final String oid;
  final List<String> parents;
}

/// 中文：按拓扑顺序构建历史车道；游离 HEAD 位于分支共同基点时为它保留最左侧车道，
/// 并让右侧分支延续到该父节点所在行后再汇入。
///
/// English: Builds history lanes in topology order, reserving the leftmost
/// lane when a detached HEAD is the common base of visible branches and
/// delaying right-side branch convergence until that parent's row. The lane
/// reservation is enabled only when [isDetachedHead] is true.
List<CommitGraphViewData> buildCommitGraph(
  List<CommitGraphNode> nodes, {
  required String? headId,
  bool isDetachedHead = false,
}) {
  final parentIds = <String>{for (final node in nodes) ...node.parents};
  final reserveDetachedHeadLane =
      isDetachedHead &&
      headId != null &&
      nodes.any((node) => node.oid == headId) &&
      parentIds.contains(headId);
  final lanes = <String>[if (nodes.isNotEmpty) nodes.first.oid];

  int physicalLane(String oid, int logicalLane) {
    if (!reserveDetachedHeadLane) return logicalLane;
    return oid == headId ? 0 : logicalLane + 1;
  }

  int colorIndexFor(String oid, int lane) {
    if (!reserveDetachedHeadLane) return lane;
    return oid == headId ? 2 : lane - 1;
  }

  final result = <CommitGraphViewData>[];
  final pendingReservedHeadLanes = <int>{};
  var previousDestinations = <int>{};
  var nextReservedLane = 1;
  final reservedLaneByOid = <String, int>{};

  int reservedPhysicalLane(String oid, int logicalLane) {
    if (oid == headId) return 0;
    return reservedLaneByOid.putIfAbsent(oid, () => nextReservedLane++);
  }

  for (final node in nodes) {
    var logicalLane = lanes.indexOf(node.oid);
    if (logicalLane < 0) {
      logicalLane = lanes.length;
      lanes.add(node.oid);
    }
    if (reserveDetachedHeadLane) {
      reservedPhysicalLane(node.oid, logicalLane);
    }
    final activeIds = List<String>.of(lanes);
    final active = <int>[
      for (var index = 0; index < activeIds.length; index++)
        reserveDetachedHeadLane
            ? reservedPhysicalLane(activeIds[index], index)
            : physicalLane(activeIds[index], index),
    ];
    final lane = reserveDetachedHeadLane
        ? reservedPhysicalLane(node.oid, logicalLane)
        : physicalLane(node.oid, logicalLane);
    lanes.removeAt(logicalLane);
    final parents = <int>[];
    for (var index = 0; index < node.parents.length; index++) {
      final parent = node.parents[index];
      var parentLogicalLane = lanes.indexOf(parent);
      if (parentLogicalLane < 0) {
        parentLogicalLane = logicalLane + index;
        if (parentLogicalLane > lanes.length) {
          parentLogicalLane = lanes.length;
        }
        lanes.insert(parentLogicalLane, parent);
      }
      if (reserveDetachedHeadLane) {
        if (parent == headId) {
          reservedLaneByOid[parent] = 0;
        } else if (!reservedLaneByOid.containsKey(parent) && index == 0) {
          reservedLaneByOid[parent] = lane;
        } else {
          reservedPhysicalLane(parent, parentLogicalLane);
        }
        parents.add(reservedPhysicalLane(parent, parentLogicalLane));
      } else {
        parents.add(physicalLane(parent, parentLogicalLane));
      }
    }
    final destinations = <int?>[
      for (var index = 0; index < activeIds.length; index++)
        if (index == logicalLane)
          parents.isEmpty ? null : parents.first
        else
          switch (lanes.indexOf(activeIds[index])) {
            final destination when destination >= 0 =>
              reserveDetachedHeadLane
                  ? reservedPhysicalLane(activeIds[index], destination)
                  : physicalLane(activeIds[index], destination),
            _ => null,
          },
    ];
    final incomingLanes = <int>[];
    if (reserveDetachedHeadLane) {
      if (node.oid == headId) {
        incomingLanes.addAll(pendingReservedHeadLanes);
        pendingReservedHeadLanes.clear();
      } else {
        for (final pendingLane in pendingReservedHeadLanes) {
          if (!active.contains(pendingLane)) {
            active.add(pendingLane);
            destinations.add(pendingLane);
          }
        }
        if (node.parents.contains(headId)) {
          final nodeLaneIndex = active.indexOf(lane);
          if (nodeLaneIndex >= 0) {
            destinations[nodeLaneIndex] = lane;
          }
          pendingReservedHeadLanes.add(lane);
        }
      }
    }
    final previousLanes = <int>[
      for (final activeLane in active)
        if (previousDestinations.contains(activeLane)) activeLane,
    ];
    result.add(
      CommitGraphViewData(
        lane: lane,
        activeLanes: active,
        activeLaneDestinations: destinations,
        previousLanes: previousLanes,
        incomingLanes: incomingLanes,
        parentLanes: parents,
        colorIndex: colorIndexFor(node.oid, lane),
        hasPreviousNode: result.isNotEmpty,
        hasReservedHeadLane: reserveDetachedHeadLane,
      ),
    );
    previousDestinations = destinations.whereType<int>().toSet();
  }
  return result;
}

/// A graph cell can be rendered without the presentation knowing Git topology.
///
/// [activeLanes] contains the lanes crossing this commit row, [lane] is the
/// commit dot lane, and [activeLaneDestinations] maps every active lane to its
/// position below the row. [parentLanes] includes all parents of the commit.
final class CommitGraphViewData {
  const CommitGraphViewData({
    this.lane = 0,
    this.activeLanes = const [0],
    this.activeLaneDestinations = const [0],
    this.previousLanes = const [],
    this.incomingLanes = const [],
    this.hasWorkspaceNode = false,
    this.parentLanes = const [0],
    this.colorIndex = 0,
    this.hasPreviousNode = false,
    this.hasReservedHeadLane = false,
  });

  final int lane;
  final List<int> activeLanes;
  final List<int?> activeLaneDestinations;

  /// 中文：上一行确实延续到当前行顶部的活动车道。
  /// English: Active lanes that genuinely continue from the preceding row
  /// into the top of this row.
  final List<int> previousLanes;

  /// 中文：从上方延续到当前节点、并在当前行汇入其车道的连接来源。
  /// English: Source lanes that continue from above and converge into the
  /// current node on this row.
  final List<int> incomingLanes;

  /// 中文：当前历史列表是否包含顶部的工作区虚拟节点。
  /// English: Whether the history list contains the virtual workspace row.
  final bool hasWorkspaceNode;
  final List<int> parentLanes;
  final int colorIndex;

  /// 中文：上方是否存在可将活动车道延续到当前行的提交节点。
  /// English: Whether a graph row above this one contains nodes that can
  /// continue active rails into the current row.
  final bool hasPreviousNode;

  /// 中文：是否为位于历史内部的游离 HEAD 基点预留最左侧车道。
  /// English: Whether the leftmost lane is reserved for a detached HEAD that
  /// appears inside the loaded history rather than at a branch tip.
  final bool hasReservedHeadLane;

  /// 中文：复制图行，并可补充来自工作区等虚拟上一行的连接车道。
  ///
  /// English: Copies the graph row and can add lanes connected from a virtual
  /// preceding row such as the working-tree row.
  CommitGraphViewData copyWith({
    bool? hasPreviousNode,
    Set<int> additionalPreviousLanes = const {},
    bool? hasWorkspaceNode,
  }) => CommitGraphViewData(
    lane: lane,
    activeLanes: activeLanes,
    activeLaneDestinations: activeLaneDestinations,
    previousLanes: {...previousLanes, ...additionalPreviousLanes}.toList(),
    incomingLanes: incomingLanes,
    hasWorkspaceNode: hasWorkspaceNode ?? this.hasWorkspaceNode,
    parentLanes: parentLanes,
    colorIndex: colorIndex,
    hasPreviousNode: hasPreviousNode ?? this.hasPreviousNode,
    hasReservedHeadLane: hasReservedHeadLane,
  );
}

final class CommitViewData {
  const CommitViewData({
    required this.oid,
    required this.shortOid,
    required this.subject,
    required this.author,
    required this.relativeDate,
    this.refs = const [],
    this.remoteRefs = const [],
    this.graph = const CommitGraphViewData(),
    this.isHead = false,
    this.isSelected = false,
    this.isMerge = false,
    this.parents = const [],
  });

  final String oid;
  final String shortOid;
  final String subject;
  final String author;
  final String relativeDate;
  final List<String> refs;
  final List<String> remoteRefs;
  final CommitGraphViewData graph;
  final bool isHead;
  final bool isSelected;
  final bool isMerge;
  final List<String> parents;

  CommitViewData copyWith({CommitGraphViewData? graph}) => CommitViewData(
    oid: oid,
    shortOid: shortOid,
    subject: subject,
    author: author,
    relativeDate: relativeDate,
    refs: refs,
    remoteRefs: remoteRefs,
    graph: graph ?? this.graph,
    isHead: isHead,
    isSelected: isSelected,
    isMerge: isMerge,
    parents: parents,
  );
}

final class CommitDetailsViewData {
  const CommitDetailsViewData({
    required this.oid,
    required this.subject,
    required this.author,
    required this.authoredAt,
    this.authorEmail,
    this.body,
    this.parents = const [],
    this.refs = const [],
    this.remoteRefs = const [],
    this.currentBranch,
    this.primaryLocalBranch,
    this.changedFiles = 0,
    this.additions = 0,
    this.deletions = 0,
  });

  final String oid;
  final String subject;
  final String author;
  final String? authorEmail;
  final String authoredAt;
  final String? body;
  final List<String> parents;
  final List<String> refs;
  final List<String> remoteRefs;
  final String? currentBranch;
  final String? primaryLocalBranch;
  final int changedFiles;
  final int additions;
  final int deletions;
}

final class RepositoryChangeViewData {
  const RepositoryChangeViewData({
    required this.path,
    required this.kind,
    this.previousPath,
    this.isStaged = false,
    this.isSelected = false,
    this.isBinary = false,
    this.canToggleStage = true,
    this.additions,
    this.deletions,
  });

  final String path;
  final String? previousPath;
  final RepositoryChangeKind kind;
  final bool isStaged;
  final bool isSelected;
  final bool isBinary;
  final bool canToggleStage;
  final int? additions;
  final int? deletions;
}

/// A file changed by the selected historical commit.
final class CommitFileViewData {
  const CommitFileViewData({
    required this.path,
    required this.kind,
    this.previousPath,
    this.isSelected = false,
    this.isBinary = false,
    this.additions,
    this.deletions,
  });

  final String path;
  final String? previousPath;
  final RepositoryChangeKind kind;
  final bool isSelected;
  final bool isBinary;
  final int? additions;
  final int? deletions;
}

final class DiffViewData {
  const DiffViewData({
    required this.path,
    this.previousPath,
    this.lines = const [],
    this.isBinary = false,
    this.isTooLarge = false,
    this.notice,
  });

  const DiffViewData.empty()
    : path = null,
      previousPath = null,
      lines = const [],
      isBinary = false,
      isTooLarge = false,
      notice = null;

  final String? path;
  final String? previousPath;
  final List<DiffLineViewData> lines;
  final bool isBinary;
  final bool isTooLarge;
  final String? notice;
}

final class DiffLineViewData {
  const DiffLineViewData({
    required this.kind,
    required this.text,
    this.oldLineNumber,
    this.newLineNumber,
  });

  final DiffLineKind kind;
  final String text;
  final int? oldLineNumber;
  final int? newLineNumber;
}

final class RepositoryFooterViewData {
  const RepositoryFooterViewData({
    this.message = '就绪',
    this.operationLabel,
    this.operationProgress,
    this.operations = const [],
    this.hasWarnings = false,
    this.gitVersion,
  });

  final String message;
  final String? operationLabel;

  /// Progress in the inclusive range 0–1. Null represents indeterminate work.
  final double? operationProgress;
  final List<RepositoryOperationViewData> operations;
  final bool hasWarnings;
  final String? gitVersion;
}

enum RepositoryOperationState { running, succeeded, cancelled, failed }

/// A redacted, user-facing record of a repository operation.
///
/// Command arguments and raw Git output intentionally do not appear here so
/// remote URLs and credentials cannot leak through the UI.
final class RepositoryOperationViewData {
  const RepositoryOperationViewData({
    required this.id,
    required this.label,
    required this.state,
    required this.startedAt,
    this.completedAt,
    this.message,
  });

  final String id;
  final String label;
  final RepositoryOperationState state;
  final DateTime startedAt;
  final DateTime? completedAt;
  final String? message;
}

final class RepositoryOverviewLayout {
  const RepositoryOverviewLayout({
    this.navigationWidth = 224,
    this.detailsWidth = 352,
    this.changesHeight = 276,
  });

  final double navigationWidth;
  final double detailsWidth;
  final double changesHeight;

  /// 中文：以传入尺寸创建新的布局配置，未传入的尺寸沿用当前值。
  ///
  /// English: Creates a new layout configuration from supplied dimensions
  /// while retaining dimensions that are omitted.
  RepositoryOverviewLayout copyWith({
    double? navigationWidth,
    double? detailsWidth,
    double? changesHeight,
  }) {
    return RepositoryOverviewLayout(
      navigationWidth: navigationWidth ?? this.navigationWidth,
      detailsWidth: detailsWidth ?? this.detailsWidth,
      changesHeight: changesHeight ?? this.changesHeight,
    );
  }
}
