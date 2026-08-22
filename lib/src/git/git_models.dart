import 'dart:convert';

/// A repository identity that remains distinct for linked worktrees.
final class GitRepositoryId {
  const GitRepositoryId({
    required this.commonDirectory,
    required this.workTreeRoot,
  });

  final String commonDirectory;
  final String? workTreeRoot;

  @override
  bool operator ==(Object other) {
    return other is GitRepositoryId &&
        other.commonDirectory == commonDirectory &&
        other.workTreeRoot == workTreeRoot;
  }

  @override
  int get hashCode => Object.hash(commonDirectory, workTreeRoot);

  /// 中文：返回该对象的字符串表示。
  /// English: Returns this object's string representation.
  @override
  String toString() => '$commonDirectory::${workTreeRoot ?? '<bare>'}';
}

/// A recognized Git repository or linked worktree.
final class GitRepository {
  const GitRepository({
    required this.id,
    required this.openedPath,
    required this.gitDirectory,
    required this.commonDirectory,
    required this.workTreeRoot,
    required this.isBare,
    required this.isInsideWorkTree,
  });

  final GitRepositoryId id;
  final String openedPath;
  final String gitDirectory;
  final String commonDirectory;
  final String? workTreeRoot;
  final bool isBare;
  final bool isInsideWorkTree;

  bool get isLinkedWorktree =>
      !isBare && gitDirectory != commonDirectory && workTreeRoot != null;

  String get commandDirectory => workTreeRoot ?? commonDirectory;
}

/// A Git pathname with its exact bytes retained.
///
/// Git paths are byte strings on Unix. [display] is deliberately lossy only
/// when a path is not valid UTF-8; callers that need identity must use
/// [rawBytes].
final class GitPath {
  GitPath(List<int> rawBytes) : rawBytes = List<int>.unmodifiable(rawBytes);

  factory GitPath.fromString(String path) => GitPath(utf8.encode(path));

  final List<int> rawBytes;

  String get display => utf8.decode(rawBytes, allowMalformed: true);

  bool get isValidUtf8 {
    try {
      utf8.decode(rawBytes);
      return true;
    } on FormatException {
      return false;
    }
  }

  @override
  bool operator ==(Object other) {
    if (other is! GitPath || other.rawBytes.length != rawBytes.length) {
      return false;
    }
    for (var index = 0; index < rawBytes.length; index++) {
      if (rawBytes[index] != other.rawBytes[index]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(rawBytes);

  /// 中文：返回该对象的字符串表示。
  /// English: Returns this object's string representation.
  @override
  String toString() => display;
}

enum GitFileStatusKind {
  ordinary,
  renamed,
  copied,
  unmerged,
  untracked,
  ignored,
}

enum GitChangeType {
  unmodified,
  modified,
  typeChanged,
  added,
  deleted,
  renamed,
  copied,
  unmerged,
  untracked,
  ignored,
  unknown,
}

extension GitChangeTypeParsing on GitChangeType {
  /// 中文：将 porcelain 状态字符转换为对应的文件改动类型；未知字符保留为 `unknown`。
  ///
  /// English: Converts a porcelain status character to its file-change type,
  /// preserving unfamiliar characters as `unknown`.
  static GitChangeType fromCode(String code) {
    return switch (code) {
      '.' || ' ' => GitChangeType.unmodified,
      'M' => GitChangeType.modified,
      'T' => GitChangeType.typeChanged,
      'A' => GitChangeType.added,
      'D' => GitChangeType.deleted,
      'R' => GitChangeType.renamed,
      'C' => GitChangeType.copied,
      'U' => GitChangeType.unmerged,
      '?' => GitChangeType.untracked,
      '!' => GitChangeType.ignored,
      _ => GitChangeType.unknown,
    };
  }
}

final class GitSubmoduleStatus {
  const GitSubmoduleStatus({
    required this.raw,
    required this.isSubmodule,
    required this.commitChanged,
    required this.hasTrackedChanges,
    required this.hasUntrackedChanges,
  });

  factory GitSubmoduleStatus.parse(String raw) {
    if (raw == 'N...') {
      return const GitSubmoduleStatus(
        raw: 'N...',
        isSubmodule: false,
        commitChanged: false,
        hasTrackedChanges: false,
        hasUntrackedChanges: false,
      );
    }
    return GitSubmoduleStatus(
      raw: raw,
      isSubmodule: raw.isNotEmpty && raw[0] == 'S',
      commitChanged: raw.length > 1 && raw[1] == 'C',
      hasTrackedChanges: raw.length > 2 && raw[2] == 'M',
      hasUntrackedChanges: raw.length > 3 && raw[3] == 'U',
    );
  }

  final String raw;
  final bool isSubmodule;
  final bool commitChanged;
  final bool hasTrackedChanges;
  final bool hasUntrackedChanges;
}

/// One entry from `git status --porcelain=v2 -z`.
final class GitStatusEntry {
  GitStatusEntry({
    required this.kind,
    required this.path,
    required this.indexStatus,
    required this.workTreeStatus,
    this.originalPath,
    this.submodule,
    this.renameOrCopyScore,
    this.headMode,
    this.indexMode,
    this.workTreeMode,
    this.headObjectId,
    this.indexObjectId,
    this.stage1Mode,
    this.stage2Mode,
    this.stage3Mode,
    this.stage1ObjectId,
    this.stage2ObjectId,
    this.stage3ObjectId,
  });

  final GitFileStatusKind kind;
  final GitPath path;
  final GitPath? originalPath;
  final GitChangeType indexStatus;
  final GitChangeType workTreeStatus;
  final GitSubmoduleStatus? submodule;
  final int? renameOrCopyScore;

  final String? headMode;
  final String? indexMode;
  final String? workTreeMode;
  final String? headObjectId;
  final String? indexObjectId;

  final String? stage1Mode;
  final String? stage2Mode;
  final String? stage3Mode;
  final String? stage1ObjectId;
  final String? stage2ObjectId;
  final String? stage3ObjectId;

  bool get isConflicted =>
      kind == GitFileStatusKind.unmerged ||
      indexStatus == GitChangeType.unmerged ||
      workTreeStatus == GitChangeType.unmerged;

  bool get hasStagedChange =>
      indexStatus != GitChangeType.unmodified &&
      indexStatus != GitChangeType.untracked &&
      indexStatus != GitChangeType.ignored;

  bool get hasWorkTreeChange =>
      workTreeStatus != GitChangeType.unmodified &&
      workTreeStatus != GitChangeType.ignored;
}

/// 中文：内部冲突解决器使用的文本快照。
///
/// English: Text snapshots used by the internal conflict resolver. Missing
/// index stages are represented by empty text, as happens for
/// add/delete conflicts. Binary or truncated snapshots are read-only in the
/// presentation layer so they cannot be accidentally rewritten as UTF-8.
final class GitConflictFileVersions {
  const GitConflictFileVersions({
    required this.path,
    required this.baseText,
    required this.oursText,
    required this.theirsText,
    required this.workingText,
    required this.isBinary,
    required this.isTruncated,
  });

  final GitPath path;
  final String baseText;
  final String oursText;
  final String theirsText;
  final String workingText;
  final bool isBinary;
  final bool isTruncated;
}

final class GitBranchStatus {
  const GitBranchStatus({
    this.objectId,
    this.head,
    this.upstream,
    this.ahead = 0,
    this.behind = 0,
    this.isUpstreamGone = false,
    this.stashCount = 0,
    this.isDetached = false,
    this.isUnborn = false,
  });

  final String? objectId;
  final String? head;
  final String? upstream;
  final int ahead;
  final int behind;
  final bool isUpstreamGone;
  final int stashCount;
  final bool isDetached;
  final bool isUnborn;
}

/// A local branch discovered through `git for-each-ref`.
final class GitLocalBranch {
  const GitLocalBranch({
    required this.name,
    required this.objectId,
    this.upstream,
  });

  final String name;
  final String objectId;
  final String? upstream;
}

/// A remote-tracking branch discovered through `git for-each-ref`.
final class GitRemoteBranch {
  const GitRemoteBranch({required this.name, required this.objectId});

  /// The short remote-tracking name, for example `origin/main`.
  final String name;

  /// The object currently referenced by this remote-tracking branch.
  final String objectId;
}

/// Options exposed by the pull configuration dialog.
/// 中文：拉取配置对话框暴露的选项。
final class GitPullOptions {
  const GitPullOptions({
    required this.remoteName,
    required this.remoteBranch,
    this.commitMerge = false,
    this.includeMergedCommits = false,
    this.createMergeCommit = false,
    this.rebase = false,
  });

  final String remoteName;
  final String remoteBranch;
  final bool commitMerge;
  final bool includeMergedCommits;
  final bool createMergeCommit;
  final bool rebase;
}

final class GitStatusSnapshot {
  GitStatusSnapshot({
    required this.branch,
    required List<GitStatusEntry> entries,
    Map<String, String> additionalHeaders = const {},
  }) : entries = List<GitStatusEntry>.unmodifiable(entries),
       additionalHeaders = Map<String, String>.unmodifiable(additionalHeaders);

  final GitBranchStatus branch;
  final List<GitStatusEntry> entries;
  final Map<String, String> additionalHeaders;

  bool get isClean => entries.isEmpty;

  Iterable<GitStatusEntry> get stagedEntries =>
      entries.where((entry) => entry.hasStagedChange);

  Iterable<GitStatusEntry> get workTreeEntries =>
      entries.where((entry) => entry.hasWorkTreeChange);

  Iterable<GitStatusEntry> get conflictedEntries =>
      entries.where((entry) => entry.isConflicted);
}

final class GitSignature {
  const GitSignature({
    required this.name,
    required this.email,
    required this.when,
  });

  final String name;
  final String email;
  final DateTime when;
}

final class GitCommit {
  GitCommit({
    required this.objectId,
    required List<String> parentIds,
    required this.author,
    required this.committer,
    required this.subject,
    required this.body,
  }) : parentIds = List<String>.unmodifiable(parentIds);

  final String objectId;
  final List<String> parentIds;
  final GitSignature author;
  final GitSignature committer;
  final String subject;
  final String body;
}

enum GitDiffSource { workingTree, staged, commit }

/// An operation marker currently owned by Git in this repository.
/// 中文：仓库中当前由 Git 持有的进行中操作标记。
enum GitRepositoryOperationState { none, merge, rebase, cherryPick, revert }

enum GitCommitChangeKind {
  added,
  modified,
  deleted,
  renamed,
  copied,
  typeChanged,
  unknown,
}

/// A file changed by one committed revision.
final class GitCommitFileChange {
  const GitCommitFileChange({
    required this.path,
    required this.kind,
    this.previousPath,
    this.additions,
    this.deletions,
  });

  final GitPath path;
  final GitPath? previousPath;
  final GitCommitChangeKind kind;
  final int? additions;
  final int? deletions;
}

final class GitCommitChangeSummary {
  GitCommitChangeSummary({
    required List<GitCommitFileChange> files,
    required this.additions,
    required this.deletions,
  }) : files = List<GitCommitFileChange>.unmodifiable(files);

  final List<GitCommitFileChange> files;
  final int additions;
  final int deletions;
}

final class GitUnifiedDiff {
  GitUnifiedDiff({
    required this.path,
    required this.source,
    required List<int> bytes,
    required this.text,
    required this.isTruncated,
  }) : bytes = List<int>.unmodifiable(bytes);

  final GitPath path;
  final GitDiffSource source;
  final List<int> bytes;
  final String text;
  final bool isTruncated;
}
