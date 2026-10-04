import 'dart:convert';

/// A repository identity that remains distinct for linked worktrees.
///
/// 中文：能够区分关联工作树的仓库身份。
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
///
/// 中文：由 Git 检查层识别出的仓库或关联工作树。
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

/// A Git-backed summary rendered in the repository-details window.
/// 中文：用于仓库详情窗口的 Git 实际数据摘要；空仓库的提交相关字段为 `null`。
final class GitRepositoryDetails {
  GitRepositoryDetails({
    required this.createdAt,
    required this.lastCommitAt,
    required this.diskUsageBytes,
    required this.lfsStatus,
    required this.branchCount,
    required this.tagCount,
    required this.commitCount,
    required this.trackedFileCount,
    required List<GitRepositoryAuthorSummary> authors,
  }) : authors = List<GitRepositoryAuthorSummary>.unmodifiable(authors);

  final DateTime? createdAt;
  final DateTime? lastCommitAt;
  final int diskUsageBytes;
  final String lfsStatus;
  final int branchCount;
  final int tagCount;
  final int commitCount;
  final int trackedFileCount;
  final List<GitRepositoryAuthorSummary> authors;
}

/// One author and the number of commits attributed by Git's all-ref history.
/// 中文：Git 全部引用历史中的作者及其提交数量。
final class GitRepositoryAuthorSummary {
  const GitRepositoryAuthorSummary({
    required this.name,
    required this.email,
    required this.commitCount,
  });

  final String name;
  final String email;
  final int commitCount;
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

/// The supported shapes of a generated Git ignore rule.
/// 中文：应用可生成的 Git 忽略规则形式。
enum GitIgnorePatternKind { exactPath, fileExtension }

/// The supported repository-local destinations for ignore rules.
/// 中文：忽略规则可写入的仓库本地目标。
enum GitIgnoreDestination { repositoryGitignore, localExclude }

/// The result of appending deduplicated rules to one ignore file.
/// 中文：向一个忽略文件追加去重规则后的结果。
final class GitIgnoreWriteResult {
  const GitIgnoreWriteResult({
    required this.targetPath,
    required this.patterns,
    required this.addedPatterns,
  });

  final String targetPath;
  final List<String> patterns;
  final List<String> addedPatterns;
}

/// The per-path outcome of copying work-tree files without overwriting.
/// 中文：以不覆盖方式复制工作区文件后的逐路径结果。
final class GitWorkingTreeCopyResult {
  GitWorkingTreeCopyResult({
    required this.destinationDirectory,
    required List<String> copiedPaths,
    required List<String> conflictingPaths,
    required List<String> failedPaths,
  }) : copiedPaths = List.unmodifiable(copiedPaths),
       conflictingPaths = List.unmodifiable(conflictingPaths),
       failedPaths = List.unmodifiable(failedPaths);

  final String destinationDirectory;
  final List<String> copiedPaths;
  final List<String> conflictingPaths;
  final List<String> failedPaths;

  /// Whether any selected path was not copied.
  /// 中文：是否至少有一个所选路径未被复制。
  bool get hasFailures => conflictingPaths.isNotEmpty || failedPaths.isNotEmpty;
}

/// The per-path outcome of moving work-tree files without overwriting.
/// 中文：以不覆盖方式移动工作区文件后的逐路径结果。
final class GitWorkingTreeMoveResult {
  GitWorkingTreeMoveResult({
    required this.destinationDirectory,
    required List<String> movedPaths,
    required List<String> conflictingPaths,
    required List<String> retainedSourcePaths,
    required List<String> failedPaths,
  }) : movedPaths = List.unmodifiable(movedPaths),
       conflictingPaths = List.unmodifiable(conflictingPaths),
       retainedSourcePaths = List.unmodifiable(retainedSourcePaths),
       failedPaths = List.unmodifiable(failedPaths);

  final String destinationDirectory;
  final List<String> movedPaths;
  final List<String> conflictingPaths;

  /// Paths copied to the destination whose source could not be safely removed.
  /// 中文：目标副本已创建、但源文件无法安全删除的路径。
  final List<String> retainedSourcePaths;

  final List<String> failedPaths;

  /// Whether any selected path was not moved completely.
  /// 中文：是否至少有一个所选路径未完整移动。
  bool get hasFailures =>
      conflictingPaths.isNotEmpty ||
      retainedSourcePaths.isNotEmpty ||
      failedPaths.isNotEmpty;
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

  /// Returns a bounded, read-only label suitable for a changed-file row.
  ///
  /// 中文：返回可用于改动行的只读状态标签；该标签不暗示或触发子模块写操作。
  String? get displayLabel {
    if (!isSubmodule) return null;
    final details = <String>[
      if (commitChanged) '提交已变化',
      if (hasTrackedChanges) '有已跟踪改动',
      if (hasUntrackedChanges) '有未跟踪内容',
    ];
    return details.isEmpty ? '无改动' : details.join('，');
  }
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
/// index stages are represented by empty text, as happens for add/delete
/// conflicts, and [hasBaseVersion] preserves whether stage 1 actually exists.
/// Binary or truncated snapshots are read-only in the presentation layer so
/// they cannot be accidentally rewritten as UTF-8.
final class GitConflictFileVersions {
  const GitConflictFileVersions({
    required this.path,
    required this.baseText,
    required this.hasBaseVersion,
    required this.oursText,
    required this.theirsText,
    required this.workingText,
    required this.isBinary,
    required this.isTruncated,
  });

  final GitPath path;
  final String baseText;
  final bool hasBaseVersion;
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
    this.ahead = 0,
    this.behind = 0,
  });

  final String name;
  final String objectId;
  final String? upstream;
  final int ahead;
  final int behind;
}

/// A remote-tracking branch discovered through `git for-each-ref`.
final class GitRemoteBranch {
  const GitRemoteBranch({
    required this.name,
    required this.objectId,
    this.isSymbolic = false,
  });

  /// The short remote-tracking name, for example `origin/main`.
  final String name;

  /// The object currently referenced by this remote-tracking branch.
  final String objectId;

  /// Whether this ref redirects to another remote-tracking ref.
  /// 中文：此引用是否会重定向到另一条远端跟踪引用。
  final bool isSymbolic;
}

/// A local Git tag discovered through `git for-each-ref`.
///
/// 中文：通过 `git for-each-ref` 读取的本地标签。对于附注标签，[targetObjectId]
/// 是 Git 解包后的实际目标对象，因此历史视图可以与提交 ID 直接匹配。
enum GitTagSignatureStatus {
  /// The tag is lightweight and has no tag object to verify.
  notAnnotated,

  /// Git verified the tag signature successfully.
  valid,

  /// The tag object exists but contains no verifiable signature.
  unsigned,

  /// A signature exists but Git rejected it.
  invalid,

  /// Git could not run or identify the configured signature verifier.
  unavailable,
}

/// Comparison of a local tag ref with the same name on a remote.
/// 中文：本地标签引用与远端同名标签引用的比较结果。
enum GitTagRemoteStatus { notChecked, matching, missing, different }

/// A tag advertised by one configured remote.
///
/// 中文：一个配置远端公开的标签引用；对象 ID 是远端 `refs/tags/*` 的直接目标，
/// 对附注标签而言通常是标签对象而不是解包后的提交对象。
final class GitRemoteTag {
  const GitRemoteTag({
    required this.remoteName,
    required this.name,
    required this.objectId,
  });

  final String remoteName;
  final String name;
  final String objectId;
}

/// Compares the direct ref object IDs without conflating annotated tags with
/// their peeled commit targets.
///
/// 中文：比较标签引用直接存储的对象 ID；附注标签必须比较标签对象本身，不能只比较
/// 解包后的提交，否则远端重新签名或重建标签时会被误报为一致。
GitTagRemoteStatus compareGitTagWithRemote(GitTag local, GitRemoteTag? remote) {
  if (remote == null) return GitTagRemoteStatus.missing;
  return local.refObjectId == remote.objectId
      ? GitTagRemoteStatus.matching
      : GitTagRemoteStatus.different;
}

final class GitTag {
  const GitTag({
    required this.name,
    required this.refObjectId,
    required this.targetObjectId,
    required this.targetObjectType,
    required this.isAnnotated,
    this.signatureStatus = GitTagSignatureStatus.notAnnotated,
  });

  /// The short tag name without the `refs/tags/` prefix.
  final String name;

  /// The object ID stored directly in `refs/tags/<name>`.
  /// 中文：标签引用直接存储的对象 ID；附注标签与解包目标不同。
  final String refObjectId;

  /// The peeled target object ID for annotated tags, or the direct target for
  /// lightweight tags.
  final String targetObjectId;

  /// Git object type after peeling an annotated tag, such as `commit` or
  /// `tree`.
  final String targetObjectType;

  /// Whether this tag can be opened in the commit-history inspector.
  /// 中文：该标签是否可在提交历史详情中预览。
  bool get hasCommitTarget => targetObjectType == 'commit';

  /// Whether Git stored an annotated tag object instead of a direct ref.
  final bool isAnnotated;

  /// The last Git-backed signature verification result, when available.
  final GitTagSignatureStatus signatureStatus;

  /// Copies the tag while replacing verification state after a Git read.
  /// 中文：复制标签并替换 Git 读取到的签名验证状态。
  GitTag copyWith({GitTagSignatureStatus? signatureStatus}) => GitTag(
    name: name,
    refObjectId: refObjectId,
    targetObjectId: targetObjectId,
    targetObjectType: targetObjectType,
    isAnnotated: isAnnotated,
    signatureStatus: signatureStatus ?? this.signatureStatus,
  );
}

/// One saved working-tree snapshot reported by `git stash list`.
///
/// 中文：`git stash list` 返回的一条已贮藏工作区快照。引用名始终由 Git
/// 提供（例如 `stash@{0}`），写操作必须使用该引用而非展示文本。
final class GitStashEntry {
  const GitStashEntry({
    required this.reference,
    required this.objectId,
    required this.createdAt,
    required this.message,
  });

  /// Git's reflog selector, for example `stash@{0}`.
  final String reference;

  /// Object ID of the stash commit.
  final String objectId;

  /// Creation time recorded by Git, normalized to UTC.
  final DateTime createdAt;

  /// Human-readable reflog subject supplied by Git.
  final String message;
}

/// A local branch and its selected destination on one remote.
/// 中文：一个本地分支及其在指定远端上的目标分支。
final class GitPushBranch {
  const GitPushBranch({
    required this.localBranch,
    required this.remoteBranch,
    this.trackRemote = false,
  });

  /// The loaded local branch that will be pushed.
  final String localBranch;

  /// The destination branch name without the remote prefix.
  final String remoteBranch;

  /// Whether the local branch should track this remote destination afterwards.
  final bool trackRemote;
}

/// Options selected in the multi-branch push dialog.
/// 中文：多分支推送弹框中选择的推送选项。
final class GitPushOptions {
  const GitPushOptions({
    required this.remoteName,
    required this.branches,
    this.pushTags = false,
  });

  /// The configured remote receiving all selected refs.
  final String remoteName;

  /// Local-to-remote branch mappings explicitly selected by the user.
  final List<GitPushBranch> branches;

  /// Whether every local tag should also be pushed.
  final bool pushTags;
}

/// Options selected when creating one tag from a historical commit.
/// 中文：从历史提交创建单个标签时选择的选项。
final class GitCreateTagOptions {
  const GitCreateTagOptions({
    required this.name,
    required this.objectId,
    this.annotation,
    this.isAnnotated = false,
    this.sign = false,
    this.pushRemoteName,
  });

  final String name;
  final String objectId;
  final String? annotation;
  final bool isAnnotated;

  /// Whether Git should create a cryptographically signed annotated tag using
  /// the repository's configured signing key.
  /// 中文：是否使用仓库配置的签名密钥创建带签名的附注标签。
  final bool sign;

  /// When supplied, push only this new tag to the configured remote.
  final String? pushRemoteName;
}

/// Options selected when deleting one local tag and, optionally, its remote ref.
/// 中文：删除一个本地标签及（可选）同名远端标签时选择的选项。
final class GitDeleteTagOptions {
  const GitDeleteTagOptions({required this.name, this.deleteRemoteName});

  final String name;

  /// Configured remote on which the matching tag should also be removed.
  final String? deleteRemoteName;
}

/// Options selected in the fetch configuration dialog.
/// 中文：抓取配置弹框中选择的选项。
final class GitFetchOptions {
  const GitFetchOptions({
    this.fetchAllRemotes = true,
    this.pruneDeletedTrackingBranches = false,
    this.fetchAllTags = false,
    this.remoteName = 'origin',
  });

  /// Fetches every configured remote instead of one named remote.
  final bool fetchAllRemotes;

  /// Removes remote-tracking refs deleted from their corresponding remote.
  final bool pruneDeletedTrackingBranches;

  /// Fetches every tag reachable from the selected remote scope.
  final bool fetchAllTags;

  /// The configured remote fetched when [fetchAllRemotes] is false.
  final String remoteName;
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

/// Reset modes exposed by the history context menu.
/// 中文：历史提交右键菜单可选的重置模式。
enum GitResetMode { soft, mixed, hard }

/// One action available for a commit in an interactive rebase todo list.
/// 中文：交互式变基 todo 列表中单个提交可选的操作。
enum GitInteractiveRebaseAction { pick, reword, edit, squash, fixup, drop }

/// A selected commit and its requested interactive-rebase action.
/// 中文：用户在交互式变基中选定的提交及其执行操作。
final class GitInteractiveRebaseInstruction {
  const GitInteractiveRebaseInstruction({
    required this.objectId,
    required this.subject,
    this.action = GitInteractiveRebaseAction.pick,
  });

  final String objectId;
  final String subject;
  final GitInteractiveRebaseAction action;

  GitInteractiveRebaseInstruction copyWith({
    GitInteractiveRebaseAction? action,
  }) => GitInteractiveRebaseInstruction(
    objectId: objectId,
    subject: subject,
    action: action ?? this.action,
  );
}

final class GitStatusSnapshot {
  GitStatusSnapshot({
    required this.branch,
    required List<GitStatusEntry> entries,
    List<GitStatusEntry>? displayEntries,
    Map<String, String> additionalHeaders = const {},
  }) : entries = List<GitStatusEntry>.unmodifiable(entries),
       displayEntries = List<GitStatusEntry>.unmodifiable(
         displayEntries ?? entries,
       ),
       additionalHeaders = Map<String, String>.unmodifiable(additionalHeaders);

  final GitBranchStatus branch;
  final List<GitStatusEntry> entries;

  /// Entries suitable for the file-status UI. This can omit directory-only
  /// untracked rows while [entries] remains the complete Git status.
  final List<GitStatusEntry> displayEntries;
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

/// One committed file-history record with the path valid at that revision.
///
/// `path` can differ between adjacent entries when Git's `--follow` detects a
/// rename. Callers must use this value—not the newest display path—when
/// requesting a revision's diff.
///
/// 中文：一条提交文件历史记录及其在该提交中的有效路径。当 Git 的 `--follow`
/// 检测到重命名时，相邻记录的路径可能不同；读取某次提交的 Diff 时必须使用
/// 该字段，而不能一律使用最新显示路径。
final class GitFileHistoryEntry {
  const GitFileHistoryEntry({required this.commit, required this.path});

  final GitCommit commit;
  final GitPath path;
}

/// One line from `git blame --line-porcelain` for the current work tree.
///
/// 中文：当前工作树文件的一行责任归属信息；保留 Git 给出的提交、作者、原始
/// 行号和当前行号，展示层不需要重新解析人类格式输出。
final class GitBlameLine {
  const GitBlameLine({
    required this.lineNumber,
    required this.sourceLineNumber,
    required this.objectId,
    required this.author,
    required this.authorEmail,
    required this.authoredAt,
    required this.summary,
    required this.text,
    this.isBoundary = false,
  });

  /// One-based line number in the current file.
  final int lineNumber;

  /// One-based line number in the source commit.
  final int sourceLineNumber;

  /// Commit object responsible for this line.
  final String objectId;

  final String author;
  final String authorEmail;
  final DateTime authoredAt;
  final String summary;
  final String text;
  final bool isBoundary;
}

/// One entry from Git's reflog, preserving the ref and selector supplied by
/// Git so callers can identify the exact historical movement.
///
/// 中文：一条 Git reflog 记录；保留 Git 返回的引用和选择器，调用方可以精确
/// 定位某次历史移动，而不会依赖展示文本或当前分支状态。
final class GitReflogEntry {
  const GitReflogEntry({
    required this.objectId,
    required this.reference,
    required this.selector,
    required this.message,
    required this.createdAt,
  });

  /// Object currently recorded by this reflog entry.
  final String objectId;

  /// Full ref name, for example `refs/heads/main@{0}`.
  final String reference;

  /// Short selector, for example `main@{0}` or `HEAD@{0}`.
  final String selector;

  /// Reflog subject supplied by Git.
  final String message;

  /// Committer timestamp recorded by the reflog.
  final DateTime createdAt;
}

enum GitDiffSource { workingTree, staged, commit }

/// Controls how Git treats whitespace while producing a read-only Diff.
/// 中文：控制 Git 生成只读 Diff 时如何处理空白字符。
enum GitDiffWhitespaceMode {
  /// Preserve Git's default whitespace-sensitive comparison.
  /// 中文：保留 Git 默认的空白敏感比较。
  preserve,

  /// Ignore all whitespace, equivalent to `git diff --ignore-all-space`.
  /// 中文：忽略所有空白差异，对应 `git diff --ignore-all-space`。
  ignoreAll,

  /// Ignore changes in the amount of whitespace, equivalent to `-b`.
  /// 中文：忽略空白数量变化，但保留空白与非空白的变化，对应 `-b`。
  ignoreChanges,

  /// Ignore blank-only lines, equivalent to `--ignore-blank-lines`.
  /// 中文：忽略只由空白组成的行变化，对应 `--ignore-blank-lines`。
  ignoreBlankLines,
}

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
    this.whitespaceMode = GitDiffWhitespaceMode.preserve,
  }) : bytes = List<int>.unmodifiable(bytes);

  final GitPath path;
  final GitDiffSource source;
  final List<int> bytes;
  final String text;
  final bool isTruncated;

  /// Whitespace policy used by the Git process that produced this Diff.
  /// 中文：生成此 Diff 的 Git 进程实际采用的空白策略。
  final GitDiffWhitespaceMode whitespaceMode;

  /// 中文：此 Diff 是否同时修改了已有文件的模式（例如 executable bit）。
  /// 新增/删除文件的模式头不属于该情况，因为它们是补丁语义的一部分。
  ///
  /// English: Whether this diff also changes an existing file's mode, such as
  /// its executable bit. New/deleted-file mode headers are excluded because
  /// they are part of those patches' semantics.
  bool get changesFileMode =>
      text.startsWith('old mode ') ||
      text.startsWith('new mode ') ||
      text.contains('\nold mode ') ||
      text.contains('\nnew mode ');
}
