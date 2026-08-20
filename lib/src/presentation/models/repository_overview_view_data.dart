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
  initializeRepository,
  fetch,
  pull,
  push,
  createBranch,
  commit,
  refresh,
  retry,
}

enum RepositoryRefKind { workspace, localBranch, remoteBranch, tag, stash }

enum RepositoryChangeKind {
  modified,
  added,
  deleted,
  renamed,
  copied,
  untracked,
  conflicted,
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
    this.headOid,
    this.ahead = 0,
    this.behind = 0,
    this.isDetachedHead = false,
    this.isRefreshing = false,
    this.isFetching = false,
    this.isPulling = false,
    this.refs = const [],
    this.commits = const [],
    this.changes = const [],
    this.selectedCommit,
    this.selectedChange,
    this.diff = const DiffViewData.empty(),
    this.footer = const RepositoryFooterViewData(),
    this.disabledActions = const {},
    this.searchQuery = '',
  });

  final String name;
  final String path;
  final String currentBranch;
  final String? headOid;
  final int ahead;
  final int behind;
  final bool isDetachedHead;
  final bool isRefreshing;
  final bool isFetching;
  final bool isPulling;
  final List<RepositoryRefViewData> refs;
  final List<CommitViewData> commits;
  final List<RepositoryChangeViewData> changes;
  final CommitDetailsViewData? selectedCommit;
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

/// A graph cell can be rendered without the presentation knowing Git topology.
///
/// [activeLanes] contains the lanes crossing this commit row, [lane] is the
/// commit dot lane, and [parentLanes] are the destinations leaving the row.
final class CommitGraphViewData {
  const CommitGraphViewData({
    this.lane = 0,
    this.activeLanes = const [0],
    this.parentLanes = const [0],
    this.colorIndex = 0,
  });

  final int lane;
  final List<int> activeLanes;
  final List<int> parentLanes;
  final int colorIndex;
}

final class CommitViewData {
  const CommitViewData({
    required this.oid,
    required this.shortOid,
    required this.subject,
    required this.author,
    required this.relativeDate,
    this.refs = const [],
    this.graph = const CommitGraphViewData(),
    this.isHead = false,
    this.isSelected = false,
    this.isMerge = false,
  });

  final String oid;
  final String shortOid;
  final String subject;
  final String author;
  final String relativeDate;
  final List<String> refs;
  final CommitGraphViewData graph;
  final bool isHead;
  final bool isSelected;
  final bool isMerge;
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
    this.hasWarnings = false,
    this.gitVersion,
  });

  final String message;
  final String? operationLabel;

  /// Progress in the inclusive range 0–1. Null represents indeterminate work.
  final double? operationProgress;
  final bool hasWarnings;
  final String? gitVersion;
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
