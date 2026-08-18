import 'dart:math' as math;

import 'package:path/path.dart' as path;

import '../git/git.dart';
import '../presentation/presentation.dart';
import 'repository_session.dart';

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

  return RepositoryViewData(
    name: path.basename(repository.workTreeRoot ?? repository.commonDirectory),
    path: repository.commandDirectory,
    currentBranch: branchName,
    headOid: branch.objectId,
    ahead: branch.ahead,
    behind: branch.behind,
    isDetachedHead: branch.isDetached,
    isRefreshing: state.phase == RepositorySessionPhase.loading,
    refs: [
      RepositoryRefViewData(
        id: 'workspace',
        label: '文件状态',
        kind: RepositoryRefKind.workspace,
        childCount: status.entries.length,
        isSelected: true,
      ),
      if (branch.head != null)
        RepositoryRefViewData(
          id: 'refs/heads/${branch.head}',
          label: branchName,
          kind: RepositoryRefKind.localBranch,
          secondaryLabel: branch.upstream,
          isCurrent: true,
          ahead: branch.ahead,
          behind: branch.behind,
        ),
      if (branch.upstream != null)
        RepositoryRefViewData(
          id: branch.upstream!,
          label: branch.upstream!,
          kind: RepositoryRefKind.remoteBranch,
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
            refs:
                selectedCommit.objectId == branch.objectId &&
                    branch.head != null
                ? [branch.head!]
                : const [],
          ),
    selectedChange: _findSelectedChange(changes, state.selectedChange),
    diff: _mapDiff(state),
    footer: RepositoryFooterViewData(
      message: _footerMessage(state, changes.length),
      operationLabel: state.isDiffLoading ? '读取 Diff' : null,
      hasWarnings:
          status.conflictedEntries.isNotEmpty ||
          state.phase == RepositorySessionPhase.error,
      gitVersion: state.gitVersion,
    ),
    disabledActions: const {
      RepositoryAction.cloneRepository,
      RepositoryAction.initializeRepository,
      RepositoryAction.fetch,
      RepositoryAction.pull,
      RepositoryAction.push,
      RepositoryAction.createBranch,
      RepositoryAction.commit,
    },
    searchQuery: state.searchQuery,
  );
}

List<CommitViewData> _mapCommits(
  RepositorySessionState state,
  GitBranchStatus branch,
) {
  final query = state.searchQuery.trim().toLowerCase();
  final graph = _buildGraph(state.commits);
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
          refs:
              state.commits[index].objectId == branch.objectId &&
                  branch.head != null
              ? [branch.head!]
              : const [],
          graph: graph[index],
          isHead: state.commits[index].objectId == branch.objectId,
          isSelected: state.commits[index].objectId == state.selectedCommitId,
          isMerge: state.commits[index].parentIds.length > 1,
        ),
  ];
}

bool _matches(GitCommit commit, String query) {
  return query.isEmpty ||
      commit.subject.toLowerCase().contains(query) ||
      commit.author.name.toLowerCase().contains(query) ||
      commit.objectId.toLowerCase().startsWith(query);
}

List<CommitGraphViewData> _buildGraph(List<GitCommit> commits) {
  final lanes = <String>[];
  final result = <CommitGraphViewData>[];
  for (final commit in commits) {
    var lane = lanes.indexOf(commit.objectId);
    if (lane < 0) {
      lane = 0;
      lanes.insert(0, commit.objectId);
    }
    final active = List<int>.generate(lanes.length, (index) => index);
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
    result.add(
      CommitGraphViewData(
        lane: lane,
        activeLanes: active,
        parentLanes: parents,
        colorIndex: lane,
      ),
    );
  }
  return result;
}

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

DiffViewData _mapDiff(RepositorySessionState state) {
  final selected = state.selectedChange;
  if (selected == null) return const DiffViewData.empty();
  if (!selected.entry.path.isValidUtf8) {
    return DiffViewData(
      path: selected.entry.path.display,
      notice: '文件名不是有效 UTF-8，当前版本无法安全读取 Diff。',
    );
  }
  if (selected.kind == RepositoryChangeKind.untracked) {
    return DiffViewData(
      path: selected.entry.path.display,
      notice: '未跟踪文件尚未进入 Git，当前版本暂不直接读取其内容。',
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

String _relativeDate(DateTime when) {
  final elapsed = DateTime.now().toUtc().difference(when.toUtc());
  if (elapsed.inMinutes < 1) return '刚刚';
  if (elapsed.inHours < 1) return '${elapsed.inMinutes} 分钟前';
  if (elapsed.inDays < 1) return '${elapsed.inHours} 小时前';
  if (elapsed.inDays < 30) return '${elapsed.inDays} 天前';
  final local = when.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
}

String _footerMessage(RepositorySessionState state, int count) {
  if (state.phase == RepositorySessionPhase.loading) return '正在刷新仓库';
  if (state.phase == RepositorySessionPhase.error) {
    return state.message ?? '读取失败';
  }
  return count == 0 ? '工作区干净' : '$count 项改动';
}
