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
  final detachedPushBranch = branch.isDetached
      ? selectDetachedPushBranch(state)
      : null;
  final branchName = branch.isDetached
      ? 'Detached HEAD'
      : branch.head ?? (branch.isUnborn ? '未创建提交' : '未知分支');
  final changes = _mapChanges(state);
  final commits = _mapCommits(state, branch);
  final selectedCommit = _findCommit(state.commits, state.selectedCommitId);
  final commitChanges = _mapCommitChanges(state);
  final runningOperation = _runningOperation(state.operations);
  final focusedRefCommitId = _selectedRefObjectId(state);
  final hasStashableTrackedChanges = status.displayEntries.any(
    (entry) =>
        entry.kind != GitFileStatusKind.untracked &&
        (entry.hasStagedChange || entry.hasWorkTreeChange),
  );

  final disabledActions = <RepositoryAction>{
    RepositoryAction.cloneRepository,
    RepositoryAction.initializeRepository,
  };
  final isRebaseInProgress =
      state.operationState == GitRepositoryOperationState.rebase;
  final isCherryPickInProgress =
      state.operationState == GitRepositoryOperationState.cherryPick;
  final isRevertInProgress =
      state.operationState == GitRepositoryOperationState.revert;
  if (state.operationState != GitRepositoryOperationState.none) {
    disabledActions.addAll([
      RepositoryAction.fetch,
      RepositoryAction.pull,
      RepositoryAction.push,
      RepositoryAction.createBranch,
      RepositoryAction.mergeBranch,
      RepositoryAction.stash,
      RepositoryAction.commit,
    ]);
    if (!isRebaseInProgress) {
      disabledActions.addAll([
        RepositoryAction.continueRebase,
        RepositoryAction.abortRebase,
      ]);
    }
  }
  if (state.remoteNames.isEmpty ||
      (state.phase == RepositorySessionPhase.loading &&
          !state.isFetchRunning)) {
    disabledActions.add(RepositoryAction.fetch);
  }
  if (branch.isUnborn ||
      branch.isDetached ||
      state.remoteNames.isEmpty ||
      (state.phase == RepositorySessionPhase.loading && !state.isPullRunning)) {
    disabledActions.add(RepositoryAction.pull);
  }
  final canPushCurrentBranch =
      branch.objectId != null &&
      ((!branch.isDetached &&
              (branch.upstream != null || state.remoteNames.isNotEmpty)) ||
          (branch.isDetached && detachedPushBranch != null));
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
  if (status.displayEntries.isEmpty ||
      state.phase == RepositorySessionPhase.loading) {
    disabledActions.add(RepositoryAction.commit);
  }
  if (state.phase == RepositorySessionPhase.loading ||
      status.conflictedEntries.isNotEmpty ||
      !hasStashableTrackedChanges) {
    disabledActions.add(RepositoryAction.stash);
  }

  return RepositoryViewData(
    name: path.basename(repository.workTreeRoot ?? repository.commonDirectory),
    path: repository.commandDirectory,
    currentBranch: branchName,
    primaryLocalBranch: branch.isDetached
        ? detachedPushBranch?.name
        : branch.head,
    headOid: branch.objectId,
    ahead: detachedPushBranch?.ahead ?? branch.ahead,
    behind: detachedPushBranch?.behind ?? branch.behind,
    isDetachedHead: branch.isDetached,
    isRefreshing: state.phase == RepositorySessionPhase.loading,
    isFetching: state.isFetchRunning,
    isPulling: state.isPullRunning,
    isPushing: state.isPushRunning,
    isStashing: state.isStashRunning,
    isRebaseInProgress: isRebaseInProgress,
    isCherryPickInProgress: isCherryPickInProgress,
    isRevertInProgress: isRevertInProgress,
    isWorkingTreeClean: status.isClean,
    isUncommittedChangesSelected: state.selectedRefId == 'uncommitted',
    refs: [
      RepositoryRefViewData(
        id: 'workspace',
        label: '文件状态',
        kind: RepositoryRefKind.workspace,
        childCount: status.displayEntries.length,
        isSelected: state.selectedRefId == 'workspace',
      ),
      RepositoryRefViewData(
        id: 'history',
        label: '历史',
        kind: RepositoryRefKind.workspace,
        isSelected:
            state.selectedRefId == 'history' ||
            state.selectedRefId == 'uncommitted',
      ),
      if (branch.isDetached)
        RepositoryRefViewData(
          id: 'HEAD',
          label: 'HEAD',
          kind: RepositoryRefKind.localBranch,
          isCurrent: true,
          isSelected: state.selectedRefId == 'HEAD',
        ),
      for (final localBranch in state.localBranches)
        RepositoryRefViewData(
          id: 'refs/heads/${localBranch.name}',
          label: localBranch.name,
          kind: RepositoryRefKind.localBranch,
          secondaryLabel: localBranch.upstream,
          isCurrent: localBranch.name == branch.head,
          isSelected: state.selectedRefId == 'refs/heads/${localBranch.name}',
          ahead: localBranch.name == branch.head
              ? branch.ahead
              : localBranch.ahead,
          behind: localBranch.name == branch.head
              ? branch.behind
              : localBranch.behind,
        ),
      for (final remoteName in state.remoteNames)
        RepositoryRefViewData(
          id: 'remotes/$remoteName',
          label: remoteName,
          kind: RepositoryRefKind.remote,
          isSelected: state.selectedRefId == 'remotes/$remoteName',
          childCount: state.remoteBranches
              .where(
                (remoteBranch) => remoteBranch.name.startsWith('$remoteName/'),
              )
              .length,
        ),
      for (final remoteBranch in state.remoteBranches)
        RepositoryRefViewData(
          id: 'refs/remotes/${remoteBranch.name}',
          label: remoteBranch.name,
          kind: RepositoryRefKind.remoteBranch,
          isSymbolicRemote: remoteBranch.isSymbolic,
          isSelected:
              state.selectedRefId == 'refs/remotes/${remoteBranch.name}',
        ),
      for (final tag in state.tags)
        RepositoryRefViewData(
          id: 'refs/tags/${tag.name}',
          label: tag.name,
          kind: RepositoryRefKind.tag,
          secondaryLabel: tag.hasCommitTarget
              ? (tag.isAnnotated ? '附注标签' : null)
              : '${tag.isAnnotated ? '附注标签' : '轻量标签'} · ${tag.targetObjectType}',
          isSelected: state.selectedRefId == 'refs/tags/${tag.name}',
        ),
      // Keep the Stashes entry present even before the first saved snapshot.
      // This matches Sourcetree's stable navigation structure and provides a
      // discoverable destination for creating and managing stashes.
      RepositoryRefViewData(
        id: 'refs/stash',
        label: '已贮藏',
        kind: RepositoryRefKind.stash,
        isSelected: state.selectedRefId == 'refs/stash',
      ),
      for (final stash in state.stashes)
        RepositoryRefViewData(
          id: 'refs/stash/${stash.objectId}',
          label: stash.message.trim().isEmpty ? '未命名贮藏' : stash.message.trim(),
          kind: RepositoryRefKind.stash,
          stashReference: stash.reference,
          isSelected: state.selectedRefId == 'refs/stash/${stash.objectId}',
        ),
    ],
    commits: commits,
    hasMoreHistory: state.hasMoreHistory,
    isHistoryLoading: state.isHistoryLoading,
    historyLoadError: state.historyLoadError,
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
            refs: _refLabelsForCommit(state, selectedCommit.objectId),
            remoteRefs: _remoteRefsForCommit(state, selectedCommit.objectId),
            tagRefs: _tagRefsForCommit(state, selectedCommit.objectId),
            references: _referencesForCommit(state, selectedCommit.objectId),
            currentBranch: branch.head,
            primaryLocalBranch: branch.isDetached
                ? selectDetachedPushBranch(state)?.name
                : branch.head,
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

/// 中文：将 Git 操作类型映射为状态栏和日志中使用的本地化标签。
///
/// English: Maps a Git-operation kind to the localized label used in the
/// status bar and activity log.
String _operationLabel(RepositoryOperationKind kind) => switch (kind) {
  RepositoryOperationKind.clone => '克隆仓库',
  RepositoryOperationKind.fetch => '获取远端更新',
  RepositoryOperationKind.pull => '拉取更新',
  RepositoryOperationKind.push => '推送当前分支',
  RepositoryOperationKind.stash => '管理贮藏',
  RepositoryOperationKind.history => '历史提交操作',
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
  final graph = buildCommitGraph(
    [
      for (final commit in state.commits)
        CommitGraphNode(oid: commit.objectId, parents: commit.parentIds),
    ],
    headId: branch.objectId,
    isDetachedHead: branch.isDetached,
  );
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
          refs: _refLabelsForCommit(state, state.commits[index].objectId),
          remoteRefs: _remoteRefsForCommit(
            state,
            state.commits[index].objectId,
          ),
          tagRefs: _tagRefsForCommit(state, state.commits[index].objectId),
          references: _referencesForCommit(
            state,
            state.commits[index].objectId,
          ),
          graph: graph[index],
          isHead: state.commits[index].objectId == branch.objectId,
          isSelected: state.commits[index].objectId == state.selectedCommitId,
          isMerge: state.commits[index].parentIds.length > 1,
          parents: state.commits[index].parentIds,
        ),
  ];
}

/// 中文：返回选中分支指向的提交对象；工作区及其他引用没有历史定位目标。
/// English: Returns the commit targeted by the selected branch ref.
String? _selectedRefObjectId(RepositorySessionState state) {
  if (state.selectedRefId == 'HEAD') {
    return state.status?.branch.objectId;
  }
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
  for (final tag in state.tags) {
    if (state.selectedRefId == 'refs/tags/${tag.name}') {
      return tag.targetObjectId;
    }
  }
  return null;
}

/// 中文：收集指向同一提交的带来源类型引用，保留 Git 命名空间差异。
/// English: Collects typed refs targeting one commit without losing Git
/// namespace differences between equal display names.
List<CommitReferenceViewData> _referencesForCommit(
  RepositorySessionState state,
  String objectId,
) => [
  if (state.status?.branch.isDetached == true &&
      state.status?.branch.objectId == objectId)
    const CommitReferenceViewData(
      label: 'HEAD',
      kind: CommitReferenceKind.head,
    ),
  for (final branch in state.localBranches)
    if (branch.objectId == objectId)
      CommitReferenceViewData(
        label: branch.name,
        kind: CommitReferenceKind.localBranch,
      ),
  for (final branch in state.remoteBranches)
    if (branch.objectId == objectId)
      CommitReferenceViewData(
        label: branch.name,
        kind: CommitReferenceKind.remoteBranch,
      ),
  for (final tag in state.tags)
    if (tag.targetObjectId == objectId)
      CommitReferenceViewData(label: tag.name, kind: CommitReferenceKind.tag),
];

/// 中文：返回提交引用的展示标签，供左侧导航定位同名提交。
/// English: Returns commit ref labels for sidebar-to-history lookup.
List<String> _refLabelsForCommit(
  RepositorySessionState state,
  String objectId,
) => [
  for (final reference in _referencesForCommit(state, objectId))
    reference.label,
];

List<String> _remoteRefsForCommit(
  RepositorySessionState state,
  String objectId,
) => [
  for (final branch in state.remoteBranches)
    if (branch.objectId == objectId) branch.name,
];

/// 中文：收集指向同一提交的标签，供视图以标签语义独立渲染。
/// English: Collects tag refs targeting one commit for distinct tag rendering.
List<String> _tagRefsForCommit(RepositorySessionState state, String objectId) =>
    [
      for (final tag in state.tags)
        if (tag.targetObjectId == objectId) tag.name,
    ];

/// 中文：判断是否与目标匹配。
/// English: Determines whether this matches the target.
bool _matches(GitCommit commit, String query) {
  return query.isEmpty ||
      commit.subject.toLowerCase().contains(query) ||
      commit.author.name.toLowerCase().contains(query) ||
      commit.objectId.toLowerCase().startsWith(query);
}

/// 中文：将数据映射为目标表示。
/// English: Maps data to the target representation.
List<RepositoryChangeViewData> _mapChanges(RepositorySessionState state) {
  final status = state.status;
  if (status == null) return const [];
  final changes = <RepositoryChangeViewData>[];
  for (final entry in status.displayEntries) {
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
