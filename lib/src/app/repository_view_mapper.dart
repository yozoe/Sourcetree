import 'dart:math' as math;

import 'package:path/path.dart' as path;

import '../git/git.dart';
import '../presentation/presentation.dart';
import 'repository_session.dart';

/// 中文：将数据映射为目标表示。
/// English: Maps data to the target representation.
RepositoryOverviewViewData mapRepositoryOverview(RepositorySessionState state) {
  final repository = _mapRepository(state);
  return switch (state.phase) {
    RepositorySessionPhase.empty =>
      const RepositoryOverviewViewData.noRepository(
        title: '打开一个 Git 仓库',
        message: '选择本地仓库，查看改动、提交历史和分支状态。',
      ),
    RepositorySessionPhase.loading => RepositoryOverviewViewData.loading(
      title: '正在读取仓库',
      message: state.requestedPath,
      staleRepository: repository,
      canCancelOperation:
          state.isCloneRunning ||
          state.isFetchRunning ||
          state.isPullRunning ||
          state.isPushRunning,
    ),
    RepositorySessionPhase.ready when repository != null =>
      RepositoryOverviewViewData.ready(repository),
    RepositorySessionPhase.error => RepositoryOverviewViewData.error(
      title: '无法读取仓库',
      message: state.message ?? 'Git 返回了未知错误。',
      technicalDetails: state.technicalDetails,
      staleRepository: repository,
    ),
    _ => const RepositoryOverviewViewData.error(message: '仓库状态不完整，请重新打开。'),
  };
}

RepositoryViewData? _mapRepository(RepositorySessionState state) {
  final repository = state.repository;
  final status = state.status;
  if (repository == null || status == null) return null;

  final branch = status.branch;
  final branchName = branch.isDetached
      ? 'Detached HEAD'
      : branch.head ?? (branch.isUnborn ? '未创建提交' : '未知分支');
  final changes = _mapChanges(state);
  final commits = _mapCommits(state, branch);
  final selectedCommit = _findCommit(state.commits, state.selectedCommitId);
  final commitChanges = _mapCommitChanges(state);
  final runningOperation = _runningOperation(state.operations);
  final focusedRefCommitId = _selectedRefObjectId(state);

  final disabledActions = <RepositoryAction>{
    RepositoryAction.cloneRepository,
    RepositoryAction.initializeRepository,
  };
  final isRebaseInProgress =
      state.operationState == GitRepositoryOperationState.rebase;
  if (state.operationState != GitRepositoryOperationState.none) {
    disabledActions.addAll([
      RepositoryAction.fetch,
      RepositoryAction.pull,
      RepositoryAction.push,
      RepositoryAction.createBranch,
      RepositoryAction.mergeBranch,
      RepositoryAction.commit,
    ]);
    if (!isRebaseInProgress) {
      disabledActions.addAll([
        RepositoryAction.continueRebase,
        RepositoryAction.abortRebase,
      ]);
    }
  }
  if (!state.hasOriginRemote ||
      (state.phase == RepositorySessionPhase.loading &&
          !state.isFetchRunning)) {
    disabledActions.add(RepositoryAction.fetch);
  }
  if (branch.upstream == null ||
      (state.phase == RepositorySessionPhase.loading && !state.isPullRunning)) {
    disabledActions.add(RepositoryAction.pull);
  }
  final canPushCurrentBranch =
      branch.objectId != null &&
      !branch.isDetached &&
      ((branch.upstream == null && state.hasOriginRemote) ||
          (branch.upstream != null &&
              (branch.ahead > 0 || branch.isUpstreamGone)));
  if (!canPushCurrentBranch ||
      (state.phase == RepositorySessionPhase.loading && !state.isPushRunning)) {
    disabledActions.add(RepositoryAction.push);
  }
  if (branch.isUnborn || state.phase == RepositorySessionPhase.loading) {
    disabledActions.add(RepositoryAction.createBranch);
  }
  if (branch.isUnborn ||
      branch.head == null ||
      state.localBranches.length < 2 ||
      status.conflictedEntries.isNotEmpty ||
      state.phase == RepositorySessionPhase.loading) {
    disabledActions.add(RepositoryAction.mergeBranch);
  }
  if (status.entries.isEmpty || state.phase == RepositorySessionPhase.loading) {
    disabledActions.add(RepositoryAction.commit);
  }

  return RepositoryViewData(
    name: path.basename(repository.workTreeRoot ?? repository.commonDirectory),
    path: repository.commandDirectory,
    currentBranch: branchName,
    headOid: branch.objectId,
    ahead: branch.ahead,
    behind: branch.behind,
    isDetachedHead: branch.isDetached,
    isRefreshing: state.phase == RepositorySessionPhase.loading,
    isFetching: state.isFetchRunning,
    isPulling: state.isPullRunning,
    isPushing: state.isPushRunning,
    isRebaseInProgress: isRebaseInProgress,
    isWorkingTreeClean: status.isClean,
    refs: [
      RepositoryRefViewData(
        id: 'workspace',
        label: '文件状态',
        kind: RepositoryRefKind.workspace,
        childCount: status.entries.length,
        isSelected: state.selectedRefId == 'workspace',
      ),
      for (final localBranch in state.localBranches)
        RepositoryRefViewData(
          id: 'refs/heads/${localBranch.name}',
          label: localBranch.name,
          kind: RepositoryRefKind.localBranch,
          secondaryLabel: localBranch.upstream,
          isCurrent: localBranch.name == branch.head,
          isSelected: state.selectedRefId == 'refs/heads/${localBranch.name}',
          ahead: localBranch.name == branch.head ? branch.ahead : 0,
          behind: localBranch.name == branch.head ? branch.behind : 0,
        ),
      for (final remoteBranch in state.remoteBranches)
        RepositoryRefViewData(
          id: 'refs/remotes/${remoteBranch.name}',
          label: remoteBranch.name,
          kind: RepositoryRefKind.remoteBranch,
          isSelected:
              state.selectedRefId == 'refs/remotes/${remoteBranch.name}',
        ),
      if (branch.stashCount > 0)
        RepositoryRefViewData(
          id: 'refs/stash',
          label: 'Stash',
          kind: RepositoryRefKind.stash,
          childCount: branch.stashCount,
        ),
    ],
    commits: commits,
    focusedRefCommitId: focusedRefCommitId,
    changes: changes,
    selectedCommit: selectedCommit == null
        ? null
        : CommitDetailsViewData(
            oid: selectedCommit.objectId,
            subject: selectedCommit.subject,
            author: selectedCommit.author.name,
            authorEmail: selectedCommit.author.email,
            authoredAt: selectedCommit.author.when.toLocal().toString(),
            body: selectedCommit.body.trim().isEmpty
                ? null
                : selectedCommit.body.trim(),
            parents: selectedCommit.parentIds,
            refs: _refsForCommit(state, selectedCommit.objectId),
            changedFiles: state.commitChanges.length,
            additions: state.commitAdditions,
            deletions: state.commitDeletions,
          ),
    commitChanges: commitChanges,
    selectedCommitFile: _findSelectedCommitFile(
      commitChanges,
      state.selectedCommitFile,
    ),
    commitDiff: _mapCommitDiff(state),
    isCommitLoading: state.isCommitLoading || state.isCommitDiffLoading,
    selectedChange: _findSelectedChange(changes, state.selectedChange),
    diff: _mapDiff(state),
    footer: RepositoryFooterViewData(
      message: _footerMessage(state, changes.length),
      operationLabel: runningOperation == null
          ? (state.isDiffLoading ? '读取 Diff' : null)
          : '正在${_operationLabel(runningOperation.kind)}',
      operations: [
        for (final operation in state.operations)
          RepositoryOperationViewData(
            id: operation.id,
            label: _operationLabel(operation.kind),
            state: _operationState(operation.outcome),
            startedAt: operation.startedAt,
            completedAt: operation.completedAt,
            message: operation.message,
          ),
      ],
      hasWarnings:
          status.conflictedEntries.isNotEmpty ||
          state.phase == RepositorySessionPhase.error,
      gitVersion: state.gitVersion,
    ),
    disabledActions: disabledActions,
    searchQuery: state.searchQuery,
  );
}

/// 中文：将数据映射为目标表示。
/// English: Maps data to the target representation.
List<CommitFileViewData> _mapCommitChanges(RepositorySessionState state) {
  return [
    for (final change in state.commitChanges)
      CommitFileViewData(
        path: change.path.display,
        previousPath: change.previousPath?.display,
        kind: switch (change.kind) {
          GitCommitChangeKind.added => RepositoryChangeKind.added,
          GitCommitChangeKind.deleted => RepositoryChangeKind.deleted,
          GitCommitChangeKind.renamed => RepositoryChangeKind.renamed,
          GitCommitChangeKind.copied => RepositoryChangeKind.copied,
          GitCommitChangeKind.typeChanged ||
          GitCommitChangeKind.modified => RepositoryChangeKind.modified,
          GitCommitChangeKind.unknown => RepositoryChangeKind.modified,
        },
        isSelected: state.selectedCommitFile?.file.path == change.path,
        additions: change.additions,
        deletions: change.deletions,
      ),
  ];
}

CommitFileViewData? _findSelectedCommitFile(
  List<CommitFileViewData> changes,
  SelectedCommitFile? selected,
) {
  if (selected == null) return null;
  for (final change in changes) {
    if (selected.matches(change)) return change;
  }
  return null;
}

RepositoryOperationRecord? _runningOperation(
  List<RepositoryOperationRecord> operations,
) {
  for (final operation in operations) {
    if (operation.outcome == RepositoryOperationOutcome.running) {
      return operation;
    }
  }
  return null;
}

/// 中文：将远端操作类型映射为状态栏和日志中使用的本地化标签。
///
/// English: Maps a remote-operation kind to the localized label used in the
/// status bar and activity log.
String _operationLabel(RepositoryOperationKind kind) => switch (kind) {
  RepositoryOperationKind.clone => '克隆仓库',
  RepositoryOperationKind.fetch => '获取远端更新',
  RepositoryOperationKind.pull => '拉取更新',
  RepositoryOperationKind.push => '推送当前分支',
};

/// 中文：将会话操作结果映射为呈现层的状态枚举。
///
/// English: Maps a session operation outcome to the presentation-layer state
/// enum.
RepositoryOperationState _operationState(
  RepositoryOperationOutcome outcome,
) => switch (outcome) {
  RepositoryOperationOutcome.running => RepositoryOperationState.running,
  RepositoryOperationOutcome.succeeded => RepositoryOperationState.succeeded,
  RepositoryOperationOutcome.cancelled => RepositoryOperationState.cancelled,
  RepositoryOperationOutcome.failed => RepositoryOperationState.failed,
};

/// 中文：将数据映射为目标表示。
/// English: Maps data to the target representation.
List<CommitViewData> _mapCommits(
  RepositorySessionState state,
  GitBranchStatus branch,
) {
  final query = state.searchQuery.trim().toLowerCase();
  final graph = _buildGraph(state.commits, headId: branch.objectId);
  return [
    for (var index = 0; index < state.commits.length; index++)
      if (_matches(state.commits[index], query))
        CommitViewData(
          oid: state.commits[index].objectId,
          shortOid: state.commits[index].objectId.substring(
            0,
            math.min(8, state.commits[index].objectId.length),
          ),
          subject: state.commits[index].subject.isEmpty
              ? '（无提交标题）'
              : state.commits[index].subject,
          author: state.commits[index].author.name,
          relativeDate: _relativeDate(state.commits[index].author.when),
          refs: _refsForCommit(state, state.commits[index].objectId),
          graph: graph[index],
          isHead: state.commits[index].objectId == branch.objectId,
          isSelected: state.commits[index].objectId == state.selectedCommitId,
          isMerge: state.commits[index].parentIds.length > 1,
        ),
  ];
}

/// 中文：返回选中分支指向的提交对象；工作区及其他引用没有历史定位目标。
/// English: Returns the commit targeted by the selected branch ref.
String? _selectedRefObjectId(RepositorySessionState state) {
  for (final branch in state.localBranches) {
    if (state.selectedRefId == 'refs/heads/${branch.name}') {
      return branch.objectId;
    }
  }
  for (final branch in state.remoteBranches) {
    if (state.selectedRefId == 'refs/remotes/${branch.name}') {
      return branch.objectId;
    }
  }
  return null;
}

/// 中文：收集指向同一提交的本地和远端分支标签。
/// English: Collects local and remote branch labels pointing to a commit.
List<String> _refsForCommit(RepositorySessionState state, String objectId) => [
  for (final branch in state.localBranches)
    if (branch.objectId == objectId) branch.name,
  for (final branch in state.remoteBranches)
    if (branch.objectId == objectId) branch.name,
];

/// 中文：判断是否与目标匹配。
/// English: Determines whether this matches the target.
bool _matches(GitCommit commit, String query) {
  return query.isEmpty ||
      commit.subject.toLowerCase().contains(query) ||
      commit.author.name.toLowerCase().contains(query) ||
      commit.objectId.toLowerCase().startsWith(query);
}

/// 中文：为按时间排序的提交生成稳定的车道、延续线和父提交连接信息。
///
/// English: Builds stable lanes, continuation rails, and parent connections
/// for chronologically ordered commits.
List<CommitGraphViewData> _buildGraph(
  List<GitCommit> commits, {
  required String? headId,
}) {
  final parentIds = <String>{for (final commit in commits) ...commit.parentIds};
  // Start with every visible branch tip. This gives sibling branches a stable
  // lane before either one is rendered, so their lines can remain continuous
  // instead of collapsing into a single HEAD-only column.
  final tips = <String>[
    for (final commit in commits)
      if (!parentIds.contains(commit.objectId)) commit.objectId,
  ];
  final lanes = <String>[
    if (headId != null && tips.remove(headId)) headId,
    ...tips,
  ];
  final result = <CommitGraphViewData>[];
  for (final commit in commits) {
    var lane = lanes.indexOf(commit.objectId);
    if (lane < 0) {
      lane = 0;
      lanes.insert(0, commit.objectId);
    }
    final activeIds = List<String>.of(lanes);
    final active = List<int>.generate(activeIds.length, (index) => index);
    lanes.removeAt(lane);
    final parents = <int>[];
    for (var index = 0; index < commit.parentIds.length; index++) {
      final parent = commit.parentIds[index];
      var parentLane = lanes.indexOf(parent);
      if (parentLane < 0) {
        parentLane = math.min(lane + index, lanes.length);
        lanes.insert(parentLane, parent);
      }
      parents.add(parentLane);
    }
    final destinations = <int?>[
      for (var index = 0; index < activeIds.length; index++)
        if (index == lane)
          parents.firstOrNull
        else
          switch (lanes.indexOf(activeIds[index])) {
            final destination when destination >= 0 => destination,
            _ => null,
          },
    ];
    result.add(
      CommitGraphViewData(
        lane: lane,
        activeLanes: active,
        activeLaneDestinations: destinations,
        parentLanes: parents,
        colorIndex: lane,
        hasPreviousNode: result.isNotEmpty,
      ),
    );
  }
  return result;
}

/// 中文：将数据映射为目标表示。
/// English: Maps data to the target representation.
List<RepositoryChangeViewData> _mapChanges(RepositorySessionState state) {
  final status = state.status;
  if (status == null) return const [];
  final changes = <RepositoryChangeViewData>[];
  for (final entry in status.entries) {
    if (entry.isConflicted) {
      changes.add(_changeData(state, entry, GitDiffSource.workingTree));
    } else {
      if (entry.hasStagedChange) {
        changes.add(_changeData(state, entry, GitDiffSource.staged));
      }
      if (entry.hasWorkTreeChange) {
        changes.add(_changeData(state, entry, GitDiffSource.workingTree));
      }
    }
  }
  return changes;
}

/// 中文：按暂存或工作区来源把 Git 状态条目映射为可展示的文件改动，并保留可暂存性与选中状态。
///
/// English: Maps a Git status entry from the index or work tree to displayable
/// change data, preserving staging capability and selection state.
RepositoryChangeViewData _changeData(
  RepositorySessionState state,
  GitStatusEntry entry,
  GitDiffSource source,
) {
  final staged = source == GitDiffSource.staged;
  final type = entry.isConflicted
      ? GitChangeType.unmerged
      : staged
      ? entry.indexStatus
      : entry.workTreeStatus;
  final kind = entry.isConflicted || type == GitChangeType.unmerged
      ? RepositoryChangeKind.conflicted
      : entry.kind == GitFileStatusKind.renamed || type == GitChangeType.renamed
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
  final selected = state.selectedChange;
  return RepositoryChangeViewData(
    path: entry.path.display,
    previousPath: entry.originalPath?.display,
    kind: kind,
    isStaged: staged,
    canToggleStage: !entry.isConflicted && entry.path.isValidUtf8,
    isSelected:
        selected?.entry.path == entry.path && selected?.source == source,
  );
}

RepositoryChangeViewData? _findSelectedChange(
  List<RepositoryChangeViewData> changes,
  SelectedRepositoryChange? selected,
) {
  if (selected == null) return null;
  for (final change in changes) {
    if (selected.matches(change)) return change;
  }
  return null;
}

GitCommit? _findCommit(List<GitCommit> commits, String? objectId) {
  for (final commit in commits) {
    if (commit.objectId == objectId) return commit;
  }
  return null;
}

/// 中文：将数据映射为目标表示。
/// English: Maps data to the target representation.
DiffViewData _mapDiff(RepositorySessionState state) {
  final selected = state.selectedChange;
  if (selected == null) return const DiffViewData.empty();
  if (!selected.entry.path.isValidUtf8) {
    return DiffViewData(
      path: selected.entry.path.display,
      notice: '文件名不是有效 UTF-8，当前版本无法安全读取 Diff。',
    );
  }
  if (state.isDiffLoading) {
    return DiffViewData(
      path: selected.entry.path.display,
      notice: '正在读取 Diff…',
    );
  }
  final diff = state.diff;
  if (diff == null) {
    return DiffViewData(
      path: selected.entry.path.display,
      notice: state.message ?? '此文件没有可显示的文本差异。',
    );
  }
  final binary =
      diff.text.contains('Binary files ') ||
      diff.text.contains('GIT binary patch');
  return DiffViewData(
    path: selected.entry.path.display,
    previousPath: selected.entry.originalPath?.display,
    isBinary: binary,
    isTooLarge: diff.isTruncated,
    notice: diff.isTruncated ? 'Diff 超过安全显示上限，内容已截断。' : null,
    lines: binary ? const [] : _diffLines(diff.text),
  );
}

/// 中文：将数据映射为目标表示。
/// English: Maps data to the target representation.
DiffViewData _mapCommitDiff(RepositorySessionState state) {
  final selected = state.selectedCommitFile;
  if (selected == null) return const DiffViewData.empty();
  if (!selected.file.path.isValidUtf8) {
    return DiffViewData(
      path: selected.file.path.display,
      notice: '文件名不是有效 UTF-8，当前版本无法安全读取 Diff。',
    );
  }
  if (state.isCommitDiffLoading) {
    return DiffViewData(path: selected.file.path.display, notice: '正在读取 Diff…');
  }
  final diff = state.commitDiff;
  if (diff == null) {
    return DiffViewData(
      path: selected.file.path.display,
      notice: state.message ?? '此文件没有可显示的文本差异。',
    );
  }
  final binary =
      diff.text.contains('Binary files ') ||
      diff.text.contains('GIT binary patch');
  return DiffViewData(
    path: selected.file.path.display,
    previousPath: selected.file.previousPath?.display,
    isBinary: binary,
    isTooLarge: diff.isTruncated,
    notice: diff.isTruncated ? 'Diff 超过安全显示上限，内容已截断。' : null,
    lines: binary ? const [] : _diffLines(diff.text),
  );
}

/// 中文：解析统一 Diff，标记文件头、hunk、增删和上下文行，并维护旧/新行号。
///
/// English: Parses a unified diff into file headers, hunks, additions,
/// deletions, and context while tracking old and new line numbers.
List<DiffLineViewData> _diffLines(String text) {
  final result = <DiffLineViewData>[];
  var oldLine = 0;
  var newLine = 0;
  final hunk = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@');
  for (final line in text.split('\n')) {
    final match = hunk.firstMatch(line);
    if (match != null) {
      oldLine = int.parse(match.group(1)!);
      newLine = int.parse(match.group(2)!);
      result.add(DiffLineViewData(kind: DiffLineKind.hunkHeader, text: line));
    } else if (line.startsWith('+') && !line.startsWith('+++')) {
      result.add(
        DiffLineViewData(
          kind: DiffLineKind.addition,
          text: line,
          newLineNumber: newLine++,
        ),
      );
    } else if (line.startsWith('-') && !line.startsWith('---')) {
      result.add(
        DiffLineViewData(
          kind: DiffLineKind.deletion,
          text: line,
          oldLineNumber: oldLine++,
        ),
      );
    } else if (line.startsWith('diff --git ') ||
        line.startsWith('index ') ||
        line.startsWith('--- ') ||
        line.startsWith('+++ ')) {
      result.add(DiffLineViewData(kind: DiffLineKind.fileHeader, text: line));
    } else if (line.startsWith(r'\ No newline at end of file')) {
      result.add(DiffLineViewData(kind: DiffLineKind.note, text: line));
    } else {
      result.add(
        DiffLineViewData(
          kind: DiffLineKind.context,
          text: line,
          oldLineNumber: oldLine == 0 ? null : oldLine++,
          newLineNumber: newLine == 0 ? null : newLine++,
        ),
      );
    }
  }
  return result;
}

/// 中文：将提交时间格式化为“刚刚”、相对时长或本地日期。
///
/// English: Formats a commit time as “just now”, a relative duration, or a
/// local calendar date.
String _relativeDate(DateTime when) {
  final elapsed = DateTime.now().toUtc().difference(when.toUtc());
  if (elapsed.inMinutes < 1) return '刚刚';
  if (elapsed.inHours < 1) return '${elapsed.inMinutes} 分钟前';
  if (elapsed.inDays < 1) return '${elapsed.inHours} 小时前';
  if (elapsed.inDays < 30) return '${elapsed.inDays} 天前';
  final local = when.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
}

/// 中文：根据会话阶段和文件改动数量生成底部状态栏消息。
///
/// English: Produces the status-bar message from the session phase and change
/// count.
String _footerMessage(RepositorySessionState state, int count) {
  if (state.phase == RepositorySessionPhase.loading) return '正在刷新仓库';
  if (state.phase == RepositorySessionPhase.error) {
    return state.message ?? '读取失败';
  }
  return count == 0 ? '工作区干净' : '$count 项改动';
}
