part of 'repository_session.dart';

enum RepositorySessionPhase { empty, loading, ready, error }

enum RepositoryOperationKind {
  clone,
  fetch,
  pull,
  push,
  commit,
  file,
  remote,
  ref,
  stash,
  history,
}

enum RepositoryOperationOutcome {
  running,
  succeeded,
  cancelled,
  failed,
  partiallySucceeded,
  uncertain,
}

enum _RebaseRecoveryAction { continueRebase, skip, abort }

/// Returns the directory name Git would conventionally use for [remoteUrl].
///
/// URL, SCP-style and local-path remotes are supported. The result is always
/// one safe path component.
String cloneRepositoryNameFromRemote(String remoteUrl) {
  var remote = remoteUrl.trim();
  if (remote.isEmpty) {
    throw ArgumentError.value(remoteUrl, 'remoteUrl', 'Must not be empty.');
  }

  final suffixStart = <int>[remote.indexOf('?'), remote.indexOf('#')]
      .where((index) => index >= 0)
      .fold<int>(
        remote.length,
        (earliest, index) => index < earliest ? index : earliest,
      );
  remote = remote.substring(0, suffixStart);
  while (remote.endsWith('/') || remote.endsWith(r'\')) {
    remote = remote.substring(0, remote.length - 1);
  }

  final separatorIndex = <int>[
    remote.lastIndexOf('/'),
    remote.lastIndexOf(r'\'),
    remote.lastIndexOf(':'),
  ].reduce((latest, index) => index > latest ? index : latest);
  var name = remote.substring(separatorIndex + 1);
  try {
    name = Uri.decodeComponent(name);
  } on FormatException {
    // Git may accept a literal percent sign in a local or SCP-style path.
  }
  if (name.toLowerCase().endsWith('.git')) {
    name = name.substring(0, name.length - 4);
  }

  if (name.isEmpty ||
      name == '.' ||
      name == '..' ||
      name.contains('/') ||
      name.contains(r'\') ||
      name.contains('\u0000')) {
    throw const GitException('无法从远端地址确定仓库目录名。');
  }
  return name;
}

final class RepositoryOperationRecord {
  const RepositoryOperationRecord({
    required this.id,
    required this.kind,
    required this.outcome,
    required this.startedAt,
    this.completedAt,
    this.message,
  });

  final String id;
  final RepositoryOperationKind kind;
  final RepositoryOperationOutcome outcome;
  final DateTime startedAt;
  final DateTime? completedAt;
  final String? message;

  /// 中文：以指定结果、完成时间和可选消息返回该操作记录的已完成副本。
  ///
  /// English: Returns a completed copy of this operation record with the
  /// supplied outcome, completion time, and optional message.
  RepositoryOperationRecord complete({
    required RepositoryOperationOutcome outcome,
    required DateTime completedAt,
    String? message,
  }) {
    return RepositoryOperationRecord(
      id: id,
      kind: kind,
      outcome: outcome,
      startedAt: startedAt,
      completedAt: completedAt,
      message: message,
    );
  }
}

final class SelectedRepositoryChange {
  const SelectedRepositoryChange({
    required this.entry,
    required this.source,
    required this.kind,
  });

  final GitStatusEntry entry;
  final GitDiffSource source;
  final RepositoryChangeKind kind;

  bool get isStaged => source == GitDiffSource.staged;

  /// 中文：判断是否与目标匹配。
  /// English: Determines whether this matches the target.
  bool matches(RepositoryChangeViewData change) {
    return entry.path.display == change.path && isStaged == change.isStaged;
  }
}

/// Returns the stable session-local key used to hide one working-tree entry.
///
/// 中文：返回单个工作区改动的会话级隐藏键；仅用于视图过滤，不进入 Git。
String repositoryChangeViewKey({
  required bool isStaged,
  required String path,
}) => '${isStaged ? 'staged' : 'unstaged'}\u0000$path';

/// Outcome of deleting selected paths from the working tree.
///
/// 中文：从工作区删除所选路径的逐项结果。已移除、执行前已不存在和删除失败
/// 分别记录，使不可逆的部分成功不会被统一失败提示掩盖。
final class RepositoryChangeRemovalResult {
  RepositoryChangeRemovalResult({
    required List<String> removedPaths,
    required List<String> missingPaths,
    required List<String> failedPaths,
  }) : removedPaths = List<String>.unmodifiable(removedPaths),
       missingPaths = List<String>.unmodifiable(missingPaths),
       failedPaths = List<String>.unmodifiable(failedPaths);

  final List<String> removedPaths;
  final List<String> missingPaths;
  final List<String> failedPaths;

  /// Whether at least one selected path could not be deleted.
  /// 中文：是否至少有一个所选路径未能删除。
  bool get hasFailures => failedPaths.isNotEmpty;
}

/// Per-tag outcomes returned by a multi-delete operation.
///
/// 中文：批量删除本地标签的逐项结果；成功、执行前已不存在和删除失败分别保留，
/// 让不可逆操作的部分成功不会被统一提示掩盖。
final class RepositoryTagDeletionResult {
  RepositoryTagDeletionResult({
    required List<String> deletedNames,
    required List<String> missingNames,
    required Map<String, String> failedNames,
  }) : deletedNames = List<String>.unmodifiable(deletedNames),
       missingNames = List<String>.unmodifiable(missingNames),
       failedNames = Map<String, String>.unmodifiable(failedNames);

  final List<String> deletedNames;
  final List<String> missingNames;
  final Map<String, String> failedNames;

  bool get hasFailures => missingNames.isNotEmpty || failedNames.isNotEmpty;
}

/// Per-tag outcomes returned by a multi-push operation.
///
/// 中文：批量推送本地标签的逐项结果；成功、执行前已不存在和推送失败分别保留，
/// 让远端部分成功可以被明确展示和记录。
final class RepositoryTagPushResult {
  RepositoryTagPushResult({
    required List<String> pushedNames,
    required List<String> missingNames,
    required Map<String, String> failedNames,
    required this.remoteName,
  }) : pushedNames = List<String>.unmodifiable(pushedNames),
       missingNames = List<String>.unmodifiable(missingNames),
       failedNames = Map<String, String>.unmodifiable(failedNames);

  final String remoteName;
  final List<String> pushedNames;
  final List<String> missingNames;
  final Map<String, String> failedNames;

  bool get hasFailures => missingNames.isNotEmpty || failedNames.isNotEmpty;
}

/// Per-tag outcomes returned by a remote multi-delete operation.
///
/// 中文：批量删除指定远端标签的逐项结果；成功、执行前已不存在和删除失败分别
/// 保留。本地同名标签不会被删除，远端部分成功会被明确展示和记录。
final class RepositoryRemoteTagDeletionResult {
  RepositoryRemoteTagDeletionResult({
    required List<String> deletedNames,
    required List<String> missingNames,
    required Map<String, String> failedNames,
    required this.remoteName,
  }) : deletedNames = List<String>.unmodifiable(deletedNames),
       missingNames = List<String>.unmodifiable(missingNames),
       failedNames = Map<String, String>.unmodifiable(failedNames);

  final String remoteName;
  final List<String> deletedNames;
  final List<String> missingNames;
  final Map<String, String> failedNames;

  bool get hasFailures => missingNames.isNotEmpty || failedNames.isNotEmpty;
}

/// 中文：在暂存状态切换并刷新后，从 Git 状态恢复同一文件在目标分组中的展示数据。
/// English: Rebuilds the same file's display data in its target group after a
/// staging toggle and status refresh.
RepositoryChangeViewData? _changeAfterStageToggle(
  GitStatusEntry entry, {
  required bool isStaged,
}) {
  if (entry.isConflicted) return null;
  if (isStaged ? !entry.hasStagedChange : !entry.hasWorkTreeChange) return null;
  final type = isStaged ? entry.indexStatus : entry.workTreeStatus;
  final kind =
      entry.kind == GitFileStatusKind.renamed || type == GitChangeType.renamed
      ? RepositoryChangeKind.renamed
      : entry.kind == GitFileStatusKind.copied || type == GitChangeType.copied
      ? RepositoryChangeKind.copied
      : type == GitChangeType.added
      ? RepositoryChangeKind.added
      : type == GitChangeType.deleted
      ? RepositoryChangeKind.deleted
      : type == GitChangeType.untracked
      ? RepositoryChangeKind.untracked
      : RepositoryChangeKind.modified;
  return RepositoryChangeViewData(
    path: entry.path.display,
    previousPath: entry.originalPath?.display,
    kind: kind,
    isStaged: isStaged,
    canToggleStage: entry.path.isValidUtf8,
    canExternalDiff: entry.submodule?.isSubmodule != true,
    submoduleStatus: entry.submodule?.displayLabel,
  );
}

final class SelectedCommitFile {
  const SelectedCommitFile({required this.objectId, required this.file});

  final String objectId;
  final GitCommitFileChange file;

  /// 中文：判断是否与目标匹配。
  /// English: Determines whether this matches the target.
  bool matches(CommitFileViewData change) =>
      file.path.display == change.path && objectId.isNotEmpty;
}

/// Immutable before/after bytes for an external historical-file comparison.
/// 中文：用于历史文件外部差异比对的不可变前后版本字节。
final class HistoricalFileComparison {
  const HistoricalFileComparison({
    required this.beforeBytes,
    required this.afterBytes,
  });

  final Uint8List beforeBytes;
  final Uint8List afterBytes;
}

/// Two immutable snapshots for one selected working-tree diff.
/// 中文：当前所选工作区差异的两个不可变快照。
final class WorkingTreeFileComparison {
  const WorkingTreeFileComparison({
    required this.beforeBytes,
    required this.afterBytes,
  });

  final Uint8List beforeBytes;
  final Uint8List afterBytes;
}

/// 中文：从提交改动中返回第一个路径可安全显示的文件。
/// 非 UTF-8 路径会保留在 Git 数据模型中，但不能安全传入文本 Diff。
///
/// English: Returns the first commit change whose path is safe to display.
/// Non-UTF-8 paths remain in the Git model but cannot safely enter text Diff.
GitCommitFileChange? firstPreviewableCommitFile(
  Iterable<GitCommitFileChange> files,
) {
  for (final file in files) {
    if (file.path.isValidUtf8) return file;
  }
  return null;
}

final class RepositorySessionState {
  const RepositorySessionState({
    required this.phase,
    this.requestedPath,
    this.repository,
    this.status,
    this.hasOriginRemote = false,
    this.originUrl,
    this.operationState = GitRepositoryOperationState.none,
    this.localBranches = const [],
    this.remoteNames = const [],
    this.remoteBranches = const [],
    this.tags = const [],
    this.tagRemoteStatuses = const {},
    this.tagRemoteNames = const {},
    this.isTagInspectionRunning = false,
    this.isTagMutationRunning = false,
    this.stashes = const [],
    this.commits = const [],
    this.historyCommits = const [],
    this.historyRevisionSnapshot = const [],
    this.historyOffset = 0,
    this.hasMoreHistory = false,
    this.isHistoryLoading = false,
    this.historyLoadError,
    this.selectedRefId = 'history',
    this.selectedCommitId,
    this.commitChanges = const [],
    this.selectedCommitFile,
    this.commitDiff,
    this.commitDiffWhitespaceMode = GitDiffWhitespaceMode.preserve,
    this.commitAdditions = 0,
    this.commitDeletions = 0,
    this.isCommitLoading = false,
    this.isCommitDiffLoading = false,
    this.selectedChange,
    this.hiddenChangeKeys = const {},
    this.diff,
    this.diffWhitespaceMode = GitDiffWhitespaceMode.preserve,
    this.isDiffLoading = false,
    this.isWorkingTreeBusy = false,
    this.isCloneRunning = false,
    this.isFetchRunning = false,
    this.isPullRunning = false,
    this.isPushRunning = false,
    this.isStashRunning = false,
    this.operations = const [],
    this.searchQuery = '',
    this.gitVersion,
    this.message,
    this.technicalDetails,
  });

  const RepositorySessionState.empty()
    : this(phase: RepositorySessionPhase.empty);

  final RepositorySessionPhase phase;
  final String? requestedPath;
  final GitRepository? repository;
  final GitStatusSnapshot? status;
  final bool hasOriginRemote;
  final String? originUrl;
  final GitRepositoryOperationState operationState;
  final List<GitLocalBranch> localBranches;
  final List<String> remoteNames;
  final List<GitRemoteBranch> remoteBranches;
  final List<GitTag> tags;

  /// Remote comparison results keyed by local tag name.
  /// 中文：按本地标签名保存的远端比较结果；未检查的标签不进入此映射。
  final Map<String, GitTagRemoteStatus> tagRemoteStatuses;

  /// Remote used for each tag comparison, keyed by local tag name.
  /// 中文：按标签名保存最近一次检查所使用的远端名称。
  final Map<String, String> tagRemoteNames;

  /// Whether a tag signature or remote-status read currently owns the tag
  /// inspection cancellation boundary.
  /// 中文：标签签名或远端状态读取是否正在进行。
  final bool isTagInspectionRunning;

  /// Whether a local or remote batch tag mutation currently owns cancellation.
  /// 中文：批量标签写操作是否正在运行并占用取消边界。
  final bool isTagMutationRunning;
  final List<GitStashEntry> stashes;
  final List<GitCommit> commits;

  /// 中文：按 Git topo order 读取的规范历史页，不包含引用或贮藏预览临时插入的提交。
  /// English: Canonical Git-topo-order history pages, excluding commits
  /// temporarily inserted for reference or stash previews.
  final List<GitCommit> historyCommits;

  /// 中文：首屏读取时固定的本地分支与 HEAD 对象 ID，后续分页不得改用变化后的引用。
  /// English: Local-branch and HEAD object IDs fixed at the first page so later
  /// pages cannot drift with changing refs.
  final List<String> historyRevisionSnapshot;
  final int historyOffset;
  final bool hasMoreHistory;
  final bool isHistoryLoading;
  final String? historyLoadError;
  final String selectedRefId;
  final String? selectedCommitId;
  final List<GitCommitFileChange> commitChanges;
  final SelectedCommitFile? selectedCommitFile;
  final GitUnifiedDiff? commitDiff;

  /// Whitespace mode used for the currently selected committed Diff.
  /// 中文：当前提交 Diff 采用的空白比较模式。
  final GitDiffWhitespaceMode commitDiffWhitespaceMode;
  final int commitAdditions;
  final int commitDeletions;
  final bool isCommitLoading;
  final bool isCommitDiffLoading;
  final SelectedRepositoryChange? selectedChange;

  /// Session-local working-tree entries hidden from the Changes pane.
  /// 中文：仅当前工作区会话有效的文件状态隐藏键，不会写入 Git 或持久化。
  final Set<String> hiddenChangeKeys;
  final GitUnifiedDiff? diff;

  /// Whitespace mode used for the currently selected main Diff.
  /// 中文：当前主 Diff 采用的空白比较模式。
  final GitDiffWhitespaceMode diffWhitespaceMode;
  final bool isDiffLoading;
  final bool isWorkingTreeBusy;
  final bool isCloneRunning;
  final bool isFetchRunning;
  final bool isPullRunning;
  final bool isPushRunning;
  final bool isStashRunning;
  final List<RepositoryOperationRecord> operations;
  final String searchQuery;
  final String? gitVersion;
  final String? message;
  final String? technicalDetails;

  /// 中文：以传入字段创建新的不可变会话状态；未传入字段保留原值，`clear*` 标志会显式清除对应选择、Diff 或错误信息。
  ///
  /// English: Creates a new immutable session state with supplied fields while
  /// retaining omitted values; each `clear*` flag explicitly clears its
  /// related selection, diff, or error information.
  RepositorySessionState copyWith({
    RepositorySessionPhase? phase,
    String? requestedPath,
    GitRepository? repository,
    GitStatusSnapshot? status,
    bool? hasOriginRemote,
    String? originUrl,
    GitRepositoryOperationState? operationState,
    List<GitLocalBranch>? localBranches,
    List<String>? remoteNames,
    List<GitRemoteBranch>? remoteBranches,
    List<GitTag>? tags,
    Map<String, GitTagRemoteStatus>? tagRemoteStatuses,
    Map<String, String>? tagRemoteNames,
    bool? isTagInspectionRunning,
    bool? isTagMutationRunning,
    List<GitStashEntry>? stashes,
    List<GitCommit>? commits,
    List<GitCommit>? historyCommits,
    List<String>? historyRevisionSnapshot,
    int? historyOffset,
    bool? hasMoreHistory,
    bool? isHistoryLoading,
    String? historyLoadError,
    String? selectedRefId,
    String? selectedCommitId,
    List<GitCommitFileChange>? commitChanges,
    SelectedCommitFile? selectedCommitFile,
    GitUnifiedDiff? commitDiff,
    GitDiffWhitespaceMode? commitDiffWhitespaceMode,
    int? commitAdditions,
    int? commitDeletions,
    bool? isCommitLoading,
    bool? isCommitDiffLoading,
    SelectedRepositoryChange? selectedChange,
    Set<String>? hiddenChangeKeys,
    GitUnifiedDiff? diff,
    GitDiffWhitespaceMode? diffWhitespaceMode,
    bool? isDiffLoading,
    bool? isWorkingTreeBusy,
    bool? isCloneRunning,
    bool? isFetchRunning,
    bool? isPullRunning,
    bool? isPushRunning,
    bool? isStashRunning,
    List<RepositoryOperationRecord>? operations,
    String? searchQuery,
    String? gitVersion,
    String? message,
    String? technicalDetails,
    bool clearSelectedChange = false,
    bool clearDiff = false,
    bool clearSelectedCommit = false,
    bool clearSelectedCommitFile = false,
    bool clearCommitDiff = false,
    bool clearHistoryLoadError = false,
    bool clearMessage = false,
  }) {
    return RepositorySessionState(
      phase: phase ?? this.phase,
      requestedPath: requestedPath ?? this.requestedPath,
      repository: repository ?? this.repository,
      status: status ?? this.status,
      hasOriginRemote: hasOriginRemote ?? this.hasOriginRemote,
      originUrl: originUrl ?? this.originUrl,
      operationState: operationState ?? this.operationState,
      localBranches: localBranches ?? this.localBranches,
      remoteNames: remoteNames ?? this.remoteNames,
      remoteBranches: remoteBranches ?? this.remoteBranches,
      tags: tags ?? this.tags,
      tagRemoteStatuses: tagRemoteStatuses ?? this.tagRemoteStatuses,
      tagRemoteNames: tagRemoteNames ?? this.tagRemoteNames,
      isTagInspectionRunning:
          isTagInspectionRunning ?? this.isTagInspectionRunning,
      isTagMutationRunning: isTagMutationRunning ?? this.isTagMutationRunning,
      stashes: stashes ?? this.stashes,
      commits: commits ?? this.commits,
      historyCommits: historyCommits ?? this.historyCommits,
      historyRevisionSnapshot:
          historyRevisionSnapshot ?? this.historyRevisionSnapshot,
      historyOffset: historyOffset ?? this.historyOffset,
      hasMoreHistory: hasMoreHistory ?? this.hasMoreHistory,
      isHistoryLoading: isHistoryLoading ?? this.isHistoryLoading,
      historyLoadError: clearHistoryLoadError
          ? null
          : historyLoadError ?? this.historyLoadError,
      selectedRefId: selectedRefId ?? this.selectedRefId,
      selectedCommitId: clearSelectedCommit
          ? null
          : selectedCommitId ?? this.selectedCommitId,
      commitChanges: commitChanges ?? this.commitChanges,
      selectedCommitFile: clearSelectedCommitFile
          ? null
          : selectedCommitFile ?? this.selectedCommitFile,
      commitDiff: clearCommitDiff ? null : commitDiff ?? this.commitDiff,
      commitDiffWhitespaceMode:
          commitDiffWhitespaceMode ?? this.commitDiffWhitespaceMode,
      commitAdditions: commitAdditions ?? this.commitAdditions,
      commitDeletions: commitDeletions ?? this.commitDeletions,
      isCommitLoading: isCommitLoading ?? this.isCommitLoading,
      isCommitDiffLoading: isCommitDiffLoading ?? this.isCommitDiffLoading,
      selectedChange: clearSelectedChange
          ? null
          : selectedChange ?? this.selectedChange,
      hiddenChangeKeys: hiddenChangeKeys ?? this.hiddenChangeKeys,
      diff: clearDiff ? null : diff ?? this.diff,
      diffWhitespaceMode: diffWhitespaceMode ?? this.diffWhitespaceMode,
      isDiffLoading: isDiffLoading ?? this.isDiffLoading,
      isWorkingTreeBusy: isWorkingTreeBusy ?? this.isWorkingTreeBusy,
      isCloneRunning: isCloneRunning ?? this.isCloneRunning,
      isFetchRunning: isFetchRunning ?? this.isFetchRunning,
      isPullRunning: isPullRunning ?? this.isPullRunning,
      isPushRunning: isPushRunning ?? this.isPushRunning,
      isStashRunning: isStashRunning ?? this.isStashRunning,
      operations: operations ?? this.operations,
      searchQuery: searchQuery ?? this.searchQuery,
      gitVersion: gitVersion ?? this.gitVersion,
      message: clearMessage ? null : message ?? this.message,
      technicalDetails: clearMessage
          ? null
          : technicalDetails ?? this.technicalDetails,
    );
  }
}

/// 中文：为游离 HEAD 选择唯一的可推送本地分支，保证界面、确认框和 Git 写操作一致。
///
/// English: Selects the single pushable local branch for detached HEAD so the
/// mapper, confirmation dialog, and Git writer use the same target.
GitLocalBranch? selectDetachedPushBranch(RepositorySessionState state) {
  final candidates = state.localBranches
      .where((branch) => branch.upstream != null || state.hasOriginRemote)
      .toList(growable: false);
  if (candidates.isEmpty) return null;
  for (final candidate in candidates) {
    if (candidate.ahead > 0) return candidate;
  }
  for (final candidate in candidates) {
    final upstream = candidate.upstream;
    final remote = upstream == null
        ? null
        : state.remoteBranches
              .where((branch) => branch.name == upstream)
              .firstOrNull;
    if (remote == null || remote.objectId != candidate.objectId) {
      return candidate;
    }
  }
  return candidates.first;
}
