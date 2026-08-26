import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path_utils;

import 'git_errors.dart';
import 'git_cancellation.dart';
import 'git_history_parser.dart';
import 'git_models.dart';
import 'git_runner.dart';
import 'git_status_parser.dart';

final class GitRepositoryInspector {
  GitRepositoryInspector(this.runner);

  final GitRunner runner;

  /// 中文：判断当前条件是否成立。
  /// English: Determines whether the current condition holds.
  Future<bool> isRepository(String path) async {
    try {
      return await inspect(path) != null;
    } on GitProcessStartException catch (error) {
      if (error.kind == GitErrorKind.workingDirectoryNotFound) {
        return false;
      }
      rethrow;
    }
  }

  /// 中文：探测 [path] 所在仓库并返回规范化的目录信息；路径不在仓库中时返回 `null`。
  ///
  /// English: Inspects the repository containing [path] and returns normalized
  /// directory information, or `null` when the path is outside a repository.
  Future<GitRepository?> inspect(String path) async {
    final flags = await _revParse(path, const [
      '--is-bare-repository',
      '--is-inside-work-tree',
    ]);
    if (!flags.isSuccess) {
      if (flags.error?.kind == GitErrorKind.notARepository) {
        return null;
      }
      flags.throwIfFailed(operation: 'Repository detection');
    }
    final flagLines = _outputLines(flags.stdoutBytes);
    if (flagLines.length != 2) {
      throw const GitParseException(
        'git rev-parse returned an unexpected repository probe.',
      );
    }
    final isBare = _parseBoolean(flagLines[0]);
    final isInsideWorkTree = _parseBoolean(flagLines[1]);

    final gitDirectory = await _readPath(path, const [
      '--path-format=absolute',
      '--git-dir',
    ]);
    final commonDirectory = await _readPath(path, const [
      '--path-format=absolute',
      '--git-common-dir',
    ]);
    final workTreeRoot = isInsideWorkTree
        ? await _readPath(path, const [
            '--path-format=absolute',
            '--show-toplevel',
          ])
        : null;

    final canonicalGitDirectory = _canonicalDirectory(gitDirectory);
    final canonicalCommonDirectory = _canonicalDirectory(commonDirectory);
    final canonicalWorkTreeRoot = workTreeRoot == null
        ? null
        : _canonicalDirectory(workTreeRoot);
    return GitRepository(
      id: GitRepositoryId(
        commonDirectory: canonicalCommonDirectory,
        workTreeRoot: canonicalWorkTreeRoot,
      ),
      openedPath: path,
      gitDirectory: canonicalGitDirectory,
      commonDirectory: canonicalCommonDirectory,
      workTreeRoot: canonicalWorkTreeRoot,
      isBare: isBare,
      isInsideWorkTree: isInsideWorkTree,
    );
  }

  /// 中文：以受限输出大小运行 `git rev-parse`，供仓库结构探测复用。
  ///
  /// English: Runs `git rev-parse` with bounded output for reusable repository
  /// structure probes.
  Future<GitResult> _revParse(String path, List<String> arguments) {
    return runner.run(
      GitInvocation(
        arguments: ['--no-pager', 'rev-parse', ...arguments],
        workingDirectory: path,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 256 * 1024,
          stderrBytes: 256 * 1024,
        ),
      ),
    );
  }

  /// 中文：固定当前本地分支与 HEAD 的对象 ID，供所有历史分页共享同一拓扑快照。
  /// English: Snapshots the current local-branch and HEAD object IDs so every
  /// history page reads the same topology.
  Future<String> _readPath(String path, List<String> arguments) async {
    final result = await _revParse(path, arguments);
    result.throwIfFailed(operation: 'Repository path detection');
    return _decodeSingleLine(result.stdoutBytes);
  }

  /// 中文：解析输入数据。
  /// English: Parses the input data.
  bool _parseBoolean(String value) {
    return switch (value) {
      'true' => true,
      'false' => false,
      _ => throw GitParseException('Expected Git boolean, got: $value'),
    };
  }

  /// 中文：优先解析目录中的符号链接；无法解析时回退到绝对路径。
  ///
  /// English: Resolves directory symlinks when possible and falls back to an
  /// absolute path when resolution fails.
  String _canonicalDirectory(String path) {
    try {
      return Directory(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      return Directory(path).absolute.path;
    }
  }
}

final class GitRepositoryReader {
  GitRepositoryReader(
    this.runner, {
    this.statusParser = const GitStatusParser(),
    this.historyParser = const GitHistoryParser(),
  });

  final GitRunner runner;
  final GitStatusParser statusParser;
  final GitHistoryParser historyParser;

  /// 中文：读取仓库详情所需的真实 Git 统计和本地磁盘用量。
  ///
  /// English: Reads Git-backed repository statistics and local disk usage for
  /// the repository-details window. Cancellation stops subsequent reads and
  /// file traversal without changing repository state.
  Future<GitRepositoryDetails> readRepositoryDetails(
    GitRepository repository, {
    GitCancellationToken? cancellationToken,
  }) async {
    void ensureNotCancelled() {
      if (cancellationToken?.isCancelled ?? false) {
        throw const GitException('Reading repository details was cancelled.');
      }
    }

    ensureNotCancelled();
    final hasHead = await _hasResolvableHead(repository);
    ensureNotCancelled();
    final results = await Future.wait([
      _runDetailsCommand(repository, const [
        '--no-pager',
        'for-each-ref',
        '--format=%(refname)',
        'refs/heads',
      ], cancellationToken),
      _runDetailsCommand(repository, const [
        '--no-pager',
        'for-each-ref',
        '--format=%(refname)',
        'refs/tags',
      ], cancellationToken),
      _runDetailsCommand(repository, const [
        '--no-pager',
        'ls-files',
        '-z',
      ], cancellationToken),
      _runDetailsCommand(repository, const [
        '--no-pager',
        'shortlog',
        '-sne',
        '--all',
      ], cancellationToken),
      if (hasHead)
        _runDetailsCommand(repository, const [
          '--no-pager',
          'log',
          '--reverse',
          '--format=%ct',
          '-1',
          '--all',
          'HEAD',
        ], cancellationToken),
      if (hasHead)
        _runDetailsCommand(repository, const [
          '--no-pager',
          'log',
          '-1',
          '--format=%ct',
          '--all',
          'HEAD',
        ], cancellationToken),
      if (hasHead)
        _runDetailsCommand(repository, const [
          '--no-pager',
          'rev-list',
          '--count',
          '--all',
        ], cancellationToken),
    ]);
    ensureNotCancelled();
    final branchOutput = results[0];
    final tagOutput = results[1];
    final trackedFilesOutput = results[2];
    final authorsOutput = results[3];
    final createdOutput = hasHead ? results[4] : null;
    final lastCommitOutput = hasHead ? results[5] : null;
    final commitCountOutput = hasHead ? results[6] : null;
    final diskUsageBytes = await _readRepositoryDiskUsage(
      repository,
      cancellationToken,
    );
    ensureNotCancelled();
    return GitRepositoryDetails(
      createdAt: _parseUnixTimestamp(createdOutput?.stdoutBytes),
      lastCommitAt: _parseUnixTimestamp(lastCommitOutput?.stdoutBytes),
      diskUsageBytes: diskUsageBytes,
      lfsStatus: await _readLfsStatus(repository, cancellationToken),
      branchCount: _outputLines(
        branchOutput.stdoutBytes,
      ).where((line) => line.isNotEmpty).length,
      tagCount: _outputLines(
        tagOutput.stdoutBytes,
      ).where((line) => line.isNotEmpty).length,
      commitCount:
          int.tryParse(
            _decodeSingleLine(commitCountOutput?.stdoutBytes ?? const []),
          ) ??
          0,
      trackedFileCount: _nullSeparatedBytes(
        trackedFilesOutput.stdoutBytes,
      ).where((path) => path.isNotEmpty).length,
      authors: _parseAuthorSummaries(authorsOutput.stdoutBytes),
    );
  }

  Future<GitResult> _runDetailsCommand(
    GitRepository repository,
    List<String> arguments,
    GitCancellationToken? cancellationToken,
  ) async {
    final result = await runner.run(
      GitInvocation(
        arguments: arguments,
        workingDirectory: repository.commandDirectory,
        cancellationToken: cancellationToken,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 16 * 1024 * 1024,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Reading repository details');
    if (result.stdoutTruncated) {
      throw const GitParseException(
        'Repository details exceeded the configured output limit.',
      );
    }
    return result;
  }

  Future<int> _readRepositoryDiskUsage(
    GitRepository repository,
    GitCancellationToken? cancellationToken,
  ) async {
    final roots = <String>{
      repository.workTreeRoot ?? repository.commonDirectory,
    };
    final workTree = repository.workTreeRoot;
    if (workTree == null ||
        !path_utils.isWithin(workTree, repository.commonDirectory)) {
      roots.add(repository.commonDirectory);
    }
    var total = 0;
    for (final root in roots) {
      final entity = Directory(root);
      if (!await entity.exists()) continue;
      try {
        await for (final child in entity.list(
          recursive: true,
          followLinks: false,
        )) {
          if (cancellationToken?.isCancelled ?? false) {
            throw const GitException(
              'Reading repository details was cancelled.',
            );
          }
          if (child is File) {
            try {
              total += await child.length();
            } on FileSystemException {
              // A concurrently removed or protected file simply cannot be
              // included in a best-effort disk usage summary.
            }
          }
        }
      } on FileSystemException {
        // Disk usage remains best effort when a directory disappears or
        // becomes inaccessible while it is being enumerated.
      }
    }
    return total;
  }

  Future<String> _readLfsStatus(
    GitRepository repository,
    GitCancellationToken? cancellationToken,
  ) async {
    if (cancellationToken?.isCancelled ?? false) {
      throw const GitException('Reading repository details was cancelled.');
    }
    final root = repository.workTreeRoot;
    if (root == null) return '未使用 LFS';
    try {
      final attributes = File(path_utils.join(root, '.gitattributes'));
      if (!await attributes.exists()) return '未使用 LFS';
      final content = await attributes.readAsString();
      return content.contains('filter=lfs') ? '已配置 LFS' : '未使用 LFS';
    } on FileSystemException {
      return '状态不可用';
    }
  }

  /// 中文：读取冲突文件的共同基线、我的版本、他们的版本和当前工作区内容。
  ///
  /// English: Reads the base, ours, theirs, and current working-tree text for
  /// a conflicted file with a bounded output size.
  Future<GitConflictFileVersions> readConflictFileVersions(
    GitRepository repository,
    GitStatusEntry entry, {
    int maxBytesPerVersion = 2 * 1024 * 1024,
  }) async {
    if (!entry.isConflicted || !entry.path.isValidUtf8) {
      throw const GitException('A UTF-8 conflicted path is required.');
    }
    if (maxBytesPerVersion <= 0) {
      throw RangeError.value(
        maxBytesPerVersion,
        'maxBytesPerVersion',
        'Must be positive.',
      );
    }

    final base = await _readConflictBlob(
      repository,
      entry.stage1ObjectId,
      maxBytesPerVersion,
    );
    final ours = await _readConflictBlob(
      repository,
      entry.stage2ObjectId,
      maxBytesPerVersion,
    );
    final theirs = await _readConflictBlob(
      repository,
      entry.stage3ObjectId,
      maxBytesPerVersion,
    );
    final working = await _readWorkingTreeConflictFile(
      repository,
      entry.path,
      maxBytesPerVersion,
    );
    return GitConflictFileVersions(
      path: entry.path,
      baseText: base.text,
      oursText: ours.text,
      theirsText: theirs.text,
      workingText: working.text,
      isBinary:
          base.isBinary || ours.isBinary || theirs.isBinary || working.isBinary,
      isTruncated:
          base.isTruncated ||
          ours.isTruncated ||
          theirs.isTruncated ||
          working.isTruncated,
    );
  }

  /// 中文：按 Git 对象 ID 读取一个有大小上限的冲突阶段 blob。
  /// English: Reads one bounded conflict-stage blob by Git object ID.
  Future<_ConflictTextSnapshot> _readConflictBlob(
    GitRepository repository,
    String? objectId,
    int maxBytes,
  ) async {
    if (objectId == null || RegExp(r'^0+$').hasMatch(objectId)) {
      return const _ConflictTextSnapshot.empty();
    }
    _validateObjectId(objectId);
    final result = await runner.run(
      GitInvocation(
        arguments: ['--no-pager', 'cat-file', 'blob', objectId],
        workingDirectory: repository.commandDirectory,
        outputLimit: GitOutputLimit(
          stdoutBytes: maxBytes,
          stderrBytes: 256 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Reading conflict version');
    return _ConflictTextSnapshot.fromBytes(
      result.stdoutBytes,
      isTruncated: result.stdoutTruncated,
    );
  }

  /// 中文：在不跟随文件符号链接的前提下，有界读取冲突工作区文件。
  /// English: Reads a conflicted work-tree file within a byte limit without
  /// following a symlink at the file itself.
  Future<_ConflictTextSnapshot> _readWorkingTreeConflictFile(
    GitRepository repository,
    GitPath path,
    int maxBytes,
  ) async {
    final root = repository.workTreeRoot;
    if (root == null) {
      throw const GitException('A working tree is required.');
    }
    final relativePath = path.display;
    if (path_utils.isAbsolute(relativePath)) {
      throw const GitException('The conflicted path is outside the work tree.');
    }
    final target = path_utils.normalize(path_utils.join(root, relativePath));
    if (!path_utils.isWithin(root, target)) {
      throw const GitException('The conflicted path is outside the work tree.');
    }
    final canonicalRoot = await Directory(root).resolveSymbolicLinks();
    final canonicalParent = await Directory(
      path_utils.dirname(target),
    ).resolveSymbolicLinks();
    if (canonicalParent != canonicalRoot &&
        !path_utils.isWithin(canonicalRoot, canonicalParent)) {
      throw const GitException('The conflicted path is outside the work tree.');
    }
    final type = await FileSystemEntity.type(target, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return const _ConflictTextSnapshot.empty();
    }
    if (type != FileSystemEntityType.file) {
      return const _ConflictTextSnapshot.binary();
    }
    final file = await File(target).open();
    try {
      final length = await file.length();
      final bytes = await file.read(length > maxBytes ? maxBytes : length);
      return _ConflictTextSnapshot.fromBytes(
        bytes,
        isTruncated: length > maxBytes,
      );
    } finally {
      await file.close();
    }
  }

  /// 中文：读取所需的数据。
  /// English: Reads the required data.
  Future<GitStatusSnapshot> readStatus(GitRepository repository) async {
    final result = await runner.run(
      GitInvocation(
        arguments: const [
          '--no-pager',
          '--no-optional-locks',
          '-c',
          'color.status=false',
          'status',
          '--porcelain=v2',
          '-z',
          '--branch',
          '--show-stash',
          // Show files inside untracked directories, without exposing the
          // directory itself as a change row (matching Sourcetree's file list).
          '--untracked-files=all',
        ],
        workingDirectory: repository.commandDirectory,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 32 * 1024 * 1024,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Reading repository status');
    if (result.stdoutTruncated) {
      throw const GitParseException(
        'Repository status exceeded the configured output limit.',
      );
    }
    final parsed = statusParser.parse(result.stdoutBytes);
    final visibleEntries = <GitStatusEntry>[];
    for (final entry in parsed.entries) {
      if (entry.workTreeStatus == GitChangeType.untracked &&
          await _isUntrackedDirectory(repository, entry.path)) {
        continue;
      }
      visibleEntries.add(entry);
    }
    return GitStatusSnapshot(
      branch: parsed.branch,
      entries: parsed.entries,
      displayEntries: visibleEntries,
      additionalHeaders: parsed.additionalHeaders,
    );
  }

  /// Returns whether [path] currently has an entry in Git's index.
  ///
  /// 中文：判断 [path] 当前是否仍在 Git 索引中。此检查适用于工作区状态
  /// 干净、因而不会出现在 `git status` 输出中的已跟踪文件。
  Future<bool> isPathTracked(GitRepository repository, GitPath path) async {
    if (!path.isValidUtf8) return false;
    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          '--no-optional-locks',
          '--literal-pathspecs',
          'ls-files',
          '--error-unmatch',
          '--',
          path.display,
        ],
        workingDirectory: repository.commandDirectory,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 256 * 1024,
          stderrBytes: 256 * 1024,
        ),
      ),
    );
    return result.isSuccess;
  }

  /// 中文：判断未跟踪状态项是否实际对应目录；Sourcetree 不展示这类目录项。
  /// English: Checks whether an untracked status entry is a directory;
  /// Sourcetree omits these directory-only rows.
  Future<bool> _isUntrackedDirectory(
    GitRepository repository,
    GitPath gitPath,
  ) async {
    final target = path_utils.normalize(
      path_utils.join(repository.commandDirectory, gitPath.display),
    );
    if (!path_utils.isWithin(repository.commandDirectory, target)) return false;
    return await FileSystemEntity.type(target, followLinks: false) ==
        FileSystemEntityType.directory;
  }

  /// 中文：读取所需的数据。
  /// English: Reads the required data.
  Future<List<String>> readHistoryRevisionSnapshot(
    GitRepository repository,
  ) async {
    if (!await _hasResolvableHead(repository)) return const [];

    final result = await runner.run(
      GitInvocation(
        arguments: const [
          '--no-pager',
          'rev-parse',
          '--revs-only',
          '--branches',
          'HEAD',
          '--',
        ],
        workingDirectory: repository.commandDirectory,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 32 * 1024 * 1024,
          stderrBytes: 64 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Snapshotting repository history');
    if (result.stdoutTruncated) {
      throw const GitParseException(
        'Repository history revision snapshot exceeded the configured output limit.',
      );
    }
    final revisions = <String>{};
    for (final line in _outputLines(result.stdoutBytes)) {
      final revision = line.trim();
      if (revision.isEmpty) continue;
      _validateObjectId(revision);
      revisions.add(revision);
    }
    return List<String>.unmodifiable(revisions);
  }

  /// 中文：按固定引用快照和偏移读取一页 Git 拓扑历史；未传快照时读取当前本地分支与 HEAD。
  /// English: Reads one Git-topology history page from a fixed revision
  /// snapshot and offset, falling back to the current local branches and HEAD.
  Future<List<GitCommit>> readRecentHistory(
    GitRepository repository, {
    int limit = 100,
    int offset = 0,
    List<String>? revisionSnapshot,
  }) async {
    if (limit <= 0 || limit > 10000) {
      throw RangeError.range(limit, 1, 10000, 'limit');
    }
    if (offset < 0) {
      throw RangeError.value(offset, 'offset', 'Must not be negative.');
    }

    final revisions = revisionSnapshot;
    if (revisions != null) {
      for (final revision in revisions) {
        _validateObjectId(revision);
      }
      if (revisions.isEmpty) return const [];
    } else if (!await _hasResolvableHead(repository)) {
      return const [];
    }

    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          '-c',
          'color.ui=false',
          'log',
          '--topo-order',
          '-z',
          '--encoding=UTF-8',
          '--max-count=$limit',
          '--skip=$offset',
          '--format=$gitHistoryFormat',
          ...?revisions,
          if (revisions == null) ...['--branches', 'HEAD'],
          '--',
        ],
        workingDirectory: repository.commandDirectory,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 32 * 1024 * 1024,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Reading repository history');
    if (result.stdoutTruncated) {
      throw const GitParseException(
        'Repository history exceeded the configured output limit.',
      );
    }
    return historyParser.parse(result.stdoutBytes).commits;
  }

  /// Reads the committed history for one repository-relative file path.
  ///
  /// Git's `--follow` option keeps a single-file history useful after a rename
  /// and each result retains the path valid at that revision. The optional
  /// [revisionSnapshot] can match the workspace's multi-branch history scope.
  /// The path is passed after `--` with literal pathspec handling, so it cannot
  /// be interpreted as a revision or another Git option.
  ///
  /// 中文：读取一个仓库相对文件路径的已提交历史。单文件查询使用 Git 的
  /// `--follow` 跟踪重命名，并为每条结果保留该提交有效的路径；可选
  /// [revisionSnapshot] 会与工作区的多分支历史范围保持一致。路径始终位于
  /// `--` 之后并启用 literal pathspec，不会被解释为提交引用或 Git 选项。
  Future<List<GitFileHistoryEntry>> readFileHistory(
    GitRepository repository, {
    required String path,
    int limit = 100,
    List<String>? revisionSnapshot,
    GitCancellationToken? cancellationToken,
  }) async {
    if (path.isEmpty || path.contains('\u0000')) {
      throw ArgumentError.value(path, 'path', 'Expected a non-empty Git path.');
    }
    if (limit <= 0 || limit > 10000) {
      throw RangeError.range(limit, 1, 10000, 'limit');
    }
    final revisions = revisionSnapshot;
    if (revisions != null) {
      for (final revision in revisions) {
        _validateObjectId(revision);
      }
      if (revisions.isEmpty) return const [];
    } else if (!await _hasResolvableHead(
      repository,
      cancellationToken: cancellationToken,
    )) {
      return const [];
    }

    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          '--no-optional-locks',
          '--literal-pathspecs',
          '-c',
          'color.ui=false',
          'log',
          '--follow',
          '--name-status',
          '-z',
          '--encoding=UTF-8',
          '--max-count=$limit',
          '--format=$gitFileHistoryFormat',
          ...?revisions,
          if (revisions == null) ...['--branches', 'HEAD'],
          '--',
          path,
        ],
        workingDirectory: repository.commandDirectory,
        cancellationToken: cancellationToken,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 32 * 1024 * 1024,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Reading file history');
    if (result.stdoutTruncated) {
      throw const GitParseException(
        'File history exceeded the configured output limit.',
      );
    }
    return historyParser.parseFileHistory(result.stdoutBytes).entries;
  }

  /// Reads the current branch commits that an interactive rebase will replay
  /// after [upstreamObjectId], oldest first.
  /// 中文：读取交互式变基将在 [upstreamObjectId] 之后重放的当前分支提交，按从旧到新排序。
  Future<List<GitInteractiveRebaseInstruction>> readInteractiveRebaseTodo(
    GitRepository repository, {
    required String upstreamObjectId,
  }) async {
    _validateObjectId(upstreamObjectId);
    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          '-c',
          'color.ui=false',
          'log',
          '--reverse',
          '-z',
          '--format=%H%x00%s',
          '$upstreamObjectId..HEAD',
          '--',
        ],
        workingDirectory: repository.commandDirectory,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 8 * 1024 * 1024,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Reading interactive rebase todo');
    if (result.stdoutTruncated) {
      throw const GitParseException(
        'Interactive rebase todo exceeded the configured output limit.',
      );
    }
    final fields = utf8
        .decode(result.stdoutBytes, allowMalformed: false)
        .split('\u0000');
    if (fields.isNotEmpty && fields.last.isEmpty) fields.removeLast();
    if (fields.length.isOdd) {
      throw const GitParseException(
        'Interactive rebase todo has invalid fields.',
      );
    }
    return List<GitInteractiveRebaseInstruction>.unmodifiable([
      for (var index = 0; index < fields.length; index += 2)
        () {
          _validateObjectId(fields[index]);
          return GitInteractiveRebaseInstruction(
            objectId: fields[index],
            subject: fields[index + 1],
          );
        }(),
    ]);
  }

  /// 中文：确认仓库已经有可解析的 HEAD；未首次提交的仓库返回 `false`，并将
  /// 可选取消令牌传递给唯一的只读 Git 子进程。
  /// English: Returns whether the repository has a resolvable HEAD, treating an
  /// unborn repository as an empty history rather than an error and forwarding
  /// the optional cancellation token to its single read-only Git process.
  Future<bool> _hasResolvableHead(
    GitRepository repository, {
    GitCancellationToken? cancellationToken,
  }) async {
    final head = await runner.run(
      GitInvocation(
        arguments: const [
          '--no-pager',
          'rev-parse',
          '--verify',
          '--quiet',
          'HEAD',
        ],
        workingDirectory: repository.commandDirectory,
        cancellationToken: cancellationToken,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 1024,
          stderrBytes: 64 * 1024,
        ),
      ),
    );
    if (head.exitCode == 1 && head.stderrBytes.isEmpty) return false;
    head.throwIfFailed(operation: 'Resolving HEAD');
    return true;
  }

  /// Reads saved working-tree snapshots without parsing `git stash`'s
  /// human-oriented default output.
  ///
  /// 中文：使用 NUL 分隔字段读取贮藏列表；展示消息不能作为后续 Git 写操作的
  /// 输入，调用方必须保留 [GitStashEntry.reference]。
  Future<List<GitStashEntry>> readStashes(GitRepository repository) async {
    final result = await runner.run(
      GitInvocation(
        arguments: const [
          '--no-pager',
          '-c',
          'color.ui=false',
          'stash',
          'list',
          '--format=%gd%x00%H%x00%ct%x00%gs',
        ],
        workingDirectory: repository.commandDirectory,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 4 * 1024 * 1024,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Reading stashes');
    if (result.stdoutTruncated) {
      throw const GitParseException(
        'Stash list exceeded the configured output limit.',
      );
    }

    final stashes = <GitStashEntry>[];
    final output = utf8.decode(result.stdoutBytes, allowMalformed: true);
    for (final record in output.split('\n')) {
      if (record.isEmpty) continue;
      final fields = record.split('\u0000');
      if (fields.length != 4 ||
          !_isStashReference(fields[0]) ||
          !RegExp(r'^[0-9a-fA-F]{7,64}$').hasMatch(fields[1])) {
        throw GitParseException('Unexpected stash record: $record');
      }
      final epochSeconds = int.tryParse(fields[2]);
      if (epochSeconds == null) {
        throw GitParseException('Unexpected stash timestamp: ${fields[2]}');
      }
      stashes.add(
        GitStashEntry(
          reference: fields[0],
          objectId: fields[1],
          createdAt: DateTime.fromMillisecondsSinceEpoch(
            epochSeconds * Duration.millisecondsPerSecond,
            isUtc: true,
          ),
          message: fields[3],
        ),
      );
    }
    return List<GitStashEntry>.unmodifiable(stashes);
  }

  /// 中文：按对象 ID 读取单个提交，供分支尖端不在当前历史窗口时补充定位。
  /// English: Reads one commit by object ID when a branch tip is outside the
  /// current history window.
  Future<GitCommit?> readCommit(
    GitRepository repository, {
    required String objectId,
  }) async {
    _validateObjectId(objectId);
    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          '-c',
          'color.ui=false',
          'log',
          '-1',
          '-z',
          '--encoding=UTF-8',
          '--format=$gitHistoryFormat',
          objectId,
          '--',
        ],
        workingDirectory: repository.commandDirectory,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 2 * 1024 * 1024,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Reading commit');
    if (result.stdoutTruncated) {
      throw const GitParseException(
        'Commit details exceeded the configured output limit.',
      );
    }
    final commits = historyParser.parse(result.stdoutBytes).commits;
    return commits.isEmpty ? null : commits.single;
  }

  /// Reads local branches without parsing human-oriented `git branch` output.
  /// 中文：读取一个提交相对指定父提交的文件状态与行统计；两个只读 Git 查询
  /// 共享可选取消令牌，全部成功后才返回合并结果。
  /// English: Reads file statuses and line statistics for one commit relative
  /// to the selected parent. Both read-only Git queries share the optional
  /// cancellation token, and results are combined only after both succeed.
  Future<List<GitLocalBranch>> readLocalBranches(
    GitRepository repository,
  ) async {
    final result = await runner.run(
      GitInvocation(
        arguments: const [
          '--no-pager',
          '-c',
          'color.ui=false',
          'for-each-ref',
          '--sort=refname',
          '--format=%(refname:short)%00%(objectname)%00%(upstream:short)%00%(upstream:track,nobracket)',
          'refs/heads',
        ],
        workingDirectory: repository.commandDirectory,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 4 * 1024 * 1024,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Reading local branches');
    if (result.stdoutTruncated) {
      throw const GitParseException(
        'Local branch list exceeded the configured output limit.',
      );
    }

    final branches = <GitLocalBranch>[];
    final output = utf8.decode(result.stdoutBytes, allowMalformed: true);
    for (final record in output.split('\n')) {
      if (record.isEmpty) {
        continue;
      }
      final fields = record.split('\u0000');
      if (fields.length != 4 || fields[0].isEmpty || fields[1].isEmpty) {
        throw GitParseException('Unexpected local branch record: $record');
      }
      final ahead = _parseAheadBehind(fields[3], 'ahead');
      final behind = _parseAheadBehind(fields[3], 'behind');
      branches.add(
        GitLocalBranch(
          name: fields[0],
          objectId: fields[1],
          upstream: fields[2].isEmpty ? null : fields[2],
          ahead: ahead,
          behind: behind,
        ),
      );
    }
    return List<GitLocalBranch>.unmodifiable(branches);
  }

  /// 中文：解析 `for-each-ref` 的 ahead/behind 跟踪摘要。
  /// English: Parses the ahead/behind tracking summary from `for-each-ref`.
  int _parseAheadBehind(String value, String direction) {
    final match = RegExp('(?:^|, )$direction (\\d+)').firstMatch(value);
    return match == null ? 0 : int.parse(match.group(1)!);
  }

  /// 中文：读取全部远端跟踪分支，并保留 `origin/HEAD` 等符号引用以供导航展示。
  ///
  /// English: Reads all remote-tracking branches while retaining symbolic refs
  /// such as `origin/HEAD` for navigation display.
  Future<List<GitRemoteBranch>> readRemoteBranches(
    GitRepository repository,
  ) async {
    final result = await runner.run(
      GitInvocation(
        arguments: const [
          '--no-pager',
          '-c',
          'color.ui=false',
          'for-each-ref',
          '--sort=refname',
          '--format=%(refname:lstrip=2)%00%(objectname)%00%(symref)',
          'refs/remotes',
        ],
        workingDirectory: repository.commandDirectory,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 4 * 1024 * 1024,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Reading remote branches');
    if (result.stdoutTruncated) {
      throw const GitParseException(
        'Remote branch list exceeded the configured output limit.',
      );
    }

    final branches = <GitRemoteBranch>[];
    final output = utf8.decode(result.stdoutBytes, allowMalformed: true);
    for (final record in output.split('\n')) {
      if (record.isEmpty) continue;
      final fields = record.split('\u0000');
      if (fields.length != 3 || fields[0].isEmpty || fields[1].isEmpty) {
        throw GitParseException('Unexpected remote branch record: $record');
      }
      branches.add(
        GitRemoteBranch(
          name: fields[0],
          objectId: fields[1],
          isSymbolic: fields[2].isNotEmpty,
        ),
      );
    }
    return List<GitRemoteBranch>.unmodifiable(branches);
  }

  /// 读取全部本地标签；附注标签会解包到其实际目标对象。
  ///
  /// English: Reads every local tag and peels annotated tags to their actual
  /// target object, so callers can associate commit tags without parsing
  /// human-oriented decoration output.
  Future<List<GitTag>> readTags(GitRepository repository) async {
    final result = await runner.run(
      GitInvocation(
        arguments: const [
          '--no-pager',
          '-c',
          'color.ui=false',
          'for-each-ref',
          '--sort=refname',
          '--format=%(refname:lstrip=2)%00%(objecttype)%00%(objectname)%00%(*objecttype)%00%(*objectname)',
          'refs/tags',
        ],
        workingDirectory: repository.commandDirectory,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 4 * 1024 * 1024,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Reading tags');
    if (result.stdoutTruncated) {
      throw const GitParseException(
        'Tag list exceeded the configured output limit.',
      );
    }

    final tags = <GitTag>[];
    final output = utf8.decode(result.stdoutBytes, allowMalformed: true);
    for (final record in output.split('\n')) {
      if (record.isEmpty) continue;
      final fields = record.split('\u0000');
      if (fields.length != 5 || fields[0].isEmpty || fields[2].isEmpty) {
        throw GitParseException('Unexpected tag record: $record');
      }
      final isAnnotated = fields[1] == 'tag';
      final targetObjectId = isAnnotated && fields[4].isNotEmpty
          ? fields[4]
          : fields[2];
      final targetObjectType = isAnnotated && fields[3].isNotEmpty
          ? fields[3]
          : fields[1];
      tags.add(
        GitTag(
          name: fields[0],
          targetObjectId: targetObjectId,
          targetObjectType: targetObjectType,
          isAnnotated: isAnnotated,
        ),
      );
    }
    return List<GitTag>.unmodifiable(tags);
  }

  /// Returns whether the conventional `origin` remote is configured.
  /// 中文：检查目标是否存在或可用。
  /// English: Checks whether the target exists or is available.
  Future<bool> hasOriginRemote(GitRepository repository) async {
    final url = await readRemoteUrl(repository, remoteName: 'origin');
    return url != null;
  }

  /// 中文：读取仓库已配置的远端名称，结果只用于显示与显式远端操作。
  ///
  /// English: Reads configured remote names for display and explicitly
  /// requested remote operations.
  Future<List<String>> readRemoteNames(GitRepository repository) async {
    final result = await runner.run(
      GitInvocation(
        arguments: const ['--no-pager', 'remote'],
        workingDirectory: repository.commandDirectory,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 256 * 1024,
          stderrBytes: 256 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Reading remote names');
    final names =
        result.stdoutText
            .split('\n')
            .map((name) => name.trim())
            .where((name) => name.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    return List<String>.unmodifiable(names);
  }

  /// Reads a configured remote's fetch URL, returning null when it is absent.
  /// 中文：读取远端的拉取地址；远端不存在时返回 null。
  Future<String?> readRemoteUrl(
    GitRepository repository, {
    String remoteName = 'origin',
  }) async {
    final normalizedName = remoteName.trim();
    if (normalizedName.isEmpty ||
        normalizedName.contains(RegExp(r'[\x00\s]'))) {
      throw ArgumentError.value(
        remoteName,
        'remoteName',
        'A remote name is required.',
      );
    }
    final result = await runner.run(
      GitInvocation(
        arguments: ['--no-pager', 'remote', 'get-url', normalizedName],
        workingDirectory: repository.commandDirectory,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 256 * 1024,
          stderrBytes: 256 * 1024,
        ),
      ),
    );
    if (result.isSuccess) {
      final url = result.stdoutText.trim();
      return url.isEmpty ? null : url;
    }
    final message = result.stderrText.toLowerCase();
    if (result.exitCode == 2 && message.contains('no such remote')) {
      return null;
    }
    result.throwIfFailed(operation: 'Reading remote URL');
    return null;
  }

  /// Reads Git's operation markers without changing the repository.
  /// 中文：读取 Git 的进行中操作标记，不修改仓库。
  Future<GitRepositoryOperationState> readOperationState(
    GitRepository repository,
  ) async {
    final gitDirectory = repository.gitDirectory;
    if (await _entityExists(path_utils.join(gitDirectory, 'rebase-merge')) ||
        await _entityExists(path_utils.join(gitDirectory, 'rebase-apply'))) {
      return GitRepositoryOperationState.rebase;
    }
    if (await _entityExists(path_utils.join(gitDirectory, 'MERGE_HEAD'))) {
      return GitRepositoryOperationState.merge;
    }
    if (await _entityExists(
      path_utils.join(gitDirectory, 'CHERRY_PICK_HEAD'),
    )) {
      return GitRepositoryOperationState.cherryPick;
    }
    if (await _entityExists(path_utils.join(gitDirectory, 'REVERT_HEAD'))) {
      return GitRepositoryOperationState.revert;
    }
    return GitRepositoryOperationState.none;
  }

  Future<bool> _entityExists(String target) async {
    final type = await FileSystemEntity.type(target, followLinks: false);
    return type != FileSystemEntityType.notFound;
  }

  /// Reads the file list and line statistics produced by one committed revision.
  ///
  /// The revision comes from [readRecentHistory], but is still constrained to
  /// an object-id shaped value before it is passed to Git as a revision. Merge
  /// commits are compared with [parentObjectId], normally their first parent.
  /// 中文：读取一个提交中指定路径的 Unified Diff；路径按字面值传递，可选取消
  /// 令牌控制唯一的只读 Git 子进程，输出超限时结果会明确标记为截断。
  /// English: Reads one path's unified diff at a commit, passing the path
  /// literally and forwarding the optional cancellation token to the single
  /// read-only Git process. Oversized output is returned as truncated.
  Future<GitCommitChangeSummary> readCommitChanges(
    GitRepository repository, {
    required String objectId,
    String? parentObjectId,
    GitCancellationToken? cancellationToken,
  }) async {
    _validateObjectId(objectId);
    if (parentObjectId != null) _validateObjectId(parentObjectId);
    final results = await Future.wait<GitResult>([
      runner.run(
        GitInvocation(
          arguments: [
            '--no-pager',
            '--no-optional-locks',
            '-c',
            'color.ui=false',
            'diff-tree',
            if (parentObjectId == null) '--root',
            '--no-commit-id',
            '--find-renames',
            '--find-copies',
            '--name-status',
            '-r',
            '-z',
            ?parentObjectId,
            objectId,
          ],
          workingDirectory: repository.commandDirectory,
          cancellationToken: cancellationToken,
          outputLimit: const GitOutputLimit(
            stdoutBytes: 8 * 1024 * 1024,
            stderrBytes: 512 * 1024,
          ),
        ),
      ),
      runner.run(
        GitInvocation(
          arguments: [
            '--no-pager',
            '--no-optional-locks',
            '-c',
            'color.ui=false',
            'diff-tree',
            if (parentObjectId == null) '--root',
            '--no-commit-id',
            '--find-renames',
            '--find-copies',
            '--numstat',
            '-r',
            '-z',
            ?parentObjectId,
            objectId,
          ],
          workingDirectory: repository.commandDirectory,
          cancellationToken: cancellationToken,
          outputLimit: const GitOutputLimit(
            stdoutBytes: 8 * 1024 * 1024,
            stderrBytes: 512 * 1024,
          ),
        ),
      ),
    ]);
    for (final result in results) {
      result.throwIfFailed(operation: 'Reading commit changes');
      if (result.stdoutTruncated) {
        throw const GitParseException(
          'Commit change list exceeded the configured output limit.',
        );
      }
    }

    final statistics = _parseCommitNumStat(results[1].stdoutBytes);
    final files = _parseCommitNameStatus(results[0].stdoutBytes, statistics);
    return GitCommitChangeSummary(
      files: files,
      additions: statistics.additions,
      deletions: statistics.deletions,
    );
  }

  /// Reads a unified diff for one file as it existed in [objectId]. For a
  /// merge, [parentObjectId] selects the comparison parent.
  /// 中文：读取所需的数据。
  /// English: Reads the required data.
  Future<GitUnifiedDiff> readCommitUnifiedDiff(
    GitRepository repository, {
    required String objectId,
    required String path,
    String? parentObjectId,
    int contextLines = 3,
    int maxOutputBytes = 4 * 1024 * 1024,
    GitCancellationToken? cancellationToken,
  }) async {
    _validateObjectId(objectId);
    if (parentObjectId != null) _validateObjectId(parentObjectId);
    if (path.contains('\u0000')) {
      throw ArgumentError.value(path, 'path', 'Git paths cannot contain NUL.');
    }
    if (contextLines < 0 || contextLines > 10000) {
      throw RangeError.range(contextLines, 0, 10000, 'contextLines');
    }
    if (maxOutputBytes <= 0) {
      throw RangeError.value(
        maxOutputBytes,
        'maxOutputBytes',
        'Must be positive.',
      );
    }
    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          '--no-optional-locks',
          '--literal-pathspecs',
          '-c',
          'color.ui=false',
          parentObjectId == null ? 'show' : 'diff',
          if (parentObjectId == null) '--format=',
          '--no-color',
          '--no-ext-diff',
          '--no-textconv',
          '--find-renames',
          '--unified=$contextLines',
          ?parentObjectId,
          objectId,
          '--',
          path,
        ],
        workingDirectory: repository.commandDirectory,
        cancellationToken: cancellationToken,
        outputLimit: GitOutputLimit(
          stdoutBytes: maxOutputBytes,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Reading commit file diff');
    final decoded = utf8.decode(result.stdoutBytes, allowMalformed: true);
    final text = result.stdoutTruncated
        ? '$decoded\n… diff output truncated …\n'
        : decoded;
    return GitUnifiedDiff(
      path: GitPath.fromString(path),
      source: GitDiffSource.commit,
      bytes: result.stdoutBytes,
      text: text,
      isTruncated: result.stdoutTruncated,
    );
  }

  /// Reads a unified diff for one literal path.
  ///
  /// The path is always placed after `--`; wildcard/pathspec magic and
  /// external diff/textconv execution are disabled.
  /// 中文：读取所需的数据。
  /// English: Reads the required data.
  Future<GitUnifiedDiff> readUnifiedDiff(
    GitRepository repository, {
    required String path,
    GitDiffSource source = GitDiffSource.workingTree,
    int contextLines = 3,
    int maxOutputBytes = 4 * 1024 * 1024,
  }) async {
    if (path.contains('\u0000')) {
      throw ArgumentError.value(path, 'path', 'Git paths cannot contain NUL.');
    }
    if (contextLines < 0 || contextLines > 10000) {
      throw RangeError.range(contextLines, 0, 10000, 'contextLines');
    }
    if (maxOutputBytes <= 0) {
      throw RangeError.value(
        maxOutputBytes,
        'maxOutputBytes',
        'Must be positive.',
      );
    }

    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          '--no-optional-locks',
          '--literal-pathspecs',
          '-c',
          'color.ui=false',
          'diff',
          '--no-color',
          '--no-ext-diff',
          '--no-textconv',
          '--unified=$contextLines',
          if (source == GitDiffSource.staged) '--cached',
          '--',
          path,
        ],
        workingDirectory: repository.commandDirectory,
        outputLimit: GitOutputLimit(
          stdoutBytes: maxOutputBytes,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Reading file diff');
    final decoded = utf8.decode(result.stdoutBytes, allowMalformed: true);
    final text = result.stdoutTruncated
        ? '$decoded\n… diff output truncated …\n'
        : decoded;
    return GitUnifiedDiff(
      path: GitPath.fromString(path),
      source: source,
      bytes: result.stdoutBytes,
      text: text,
      isTruncated: result.stdoutTruncated,
    );
  }

  /// Reads an untracked file as a unified diff against an empty file.
  ///
  /// `git diff` normally omits untracked paths. No-index mode gives the UI the
  /// same full-file addition patch Git would produce after the path is staged,
  /// without changing the repository index.
  /// 中文：把未跟踪文件与空文件比较，在不修改暂存区的前提下生成整文件新增补丁。
  Future<GitUnifiedDiff> readUntrackedFileDiff(
    GitRepository repository, {
    required String path,
    int contextLines = 3,
    int maxOutputBytes = 4 * 1024 * 1024,
  }) async {
    if (path.contains('\u0000')) {
      throw ArgumentError.value(path, 'path', 'Git paths cannot contain NUL.');
    }
    if (contextLines < 0 || contextLines > 10000) {
      throw RangeError.range(contextLines, 0, 10000, 'contextLines');
    }
    if (maxOutputBytes <= 0) {
      throw RangeError.value(
        maxOutputBytes,
        'maxOutputBytes',
        'Must be positive.',
      );
    }

    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          '--no-optional-locks',
          '--literal-pathspecs',
          '-c',
          'color.ui=false',
          'diff',
          '--no-index',
          '--no-color',
          '--no-ext-diff',
          '--no-textconv',
          '--unified=$contextLines',
          '--',
          '/dev/null',
          path,
        ],
        workingDirectory: repository.commandDirectory,
        outputLimit: GitOutputLimit(
          stdoutBytes: maxOutputBytes,
          stderrBytes: 512 * 1024,
        ),
      ),
    );

    // `git diff --no-index` uses exit code 1 to report that differences were
    // found. Only other non-zero codes represent an actual command failure.
    if (result.exitCode != 0 && result.exitCode != 1) {
      result.throwIfFailed(operation: 'Reading untracked file diff');
    }
    final decoded = utf8.decode(result.stdoutBytes, allowMalformed: true);
    final text = result.stdoutTruncated
        ? '$decoded\n… diff output truncated …\n'
        : decoded;
    return GitUnifiedDiff(
      path: GitPath.fromString(path),
      source: GitDiffSource.workingTree,
      bytes: result.stdoutBytes,
      text: text,
      isTruncated: result.stdoutTruncated,
    );
  }
}

/// 中文：验证输入或状态。
/// English: Validates the input or state.
void _validateObjectId(String objectId) {
  if (!RegExp(r'^[0-9a-fA-F]{7,128}$').hasMatch(objectId)) {
    throw ArgumentError.value(
      objectId,
      'objectId',
      'Expected a Git object id.',
    );
  }
}

final class _ConflictTextSnapshot {
  const _ConflictTextSnapshot({
    this.text = '',
    this.isBinary = false,
    this.isTruncated = false,
  });

  const _ConflictTextSnapshot.empty() : this();

  const _ConflictTextSnapshot.binary() : this(isBinary: true);

  /// 中文：将有界原始字节解码为文本，并标记二进制或截断状态。
  /// English: Decodes bounded raw bytes and records binary or truncation
  /// state.
  factory _ConflictTextSnapshot.fromBytes(
    List<int> bytes, {
    required bool isTruncated,
  }) {
    final containsNull = bytes.contains(0);
    var isBinary = containsNull;
    String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      isBinary = true;
      text = utf8.decode(bytes, allowMalformed: true);
    }
    return _ConflictTextSnapshot(
      text: text,
      isBinary: isBinary,
      isTruncated: isTruncated,
    );
  }

  final String text;
  final bool isBinary;
  final bool isTruncated;
}

/// 中文：解析输入数据。
/// English: Parses the input data.
List<GitCommitFileChange> _parseCommitNameStatus(
  List<int> bytes,
  _CommitNumStat statistics,
) {
  final fields = _nullSeparatedBytes(bytes);
  final files = <GitCommitFileChange>[];
  var index = 0;
  while (index < fields.length) {
    final status = utf8.decode(fields[index++], allowMalformed: true);
    if (status.isEmpty) continue;
    final code = status[0];
    if (index >= fields.length) {
      throw const GitParseException('Commit change record has no path.');
    }
    GitPath? previousPath;
    GitPath nextPath;
    if (code == 'R' || code == 'C') {
      if (index + 1 >= fields.length) {
        throw const GitParseException('Rename or copy record is incomplete.');
      }
      previousPath = GitPath(fields[index++]);
      nextPath = GitPath(fields[index++]);
    } else {
      nextPath = GitPath(fields[index++]);
    }
    final stat = statistics.byPath[nextPath];
    files.add(
      GitCommitFileChange(
        path: nextPath,
        previousPath: previousPath,
        kind: switch (code) {
          'A' => GitCommitChangeKind.added,
          'D' => GitCommitChangeKind.deleted,
          'R' => GitCommitChangeKind.renamed,
          'C' => GitCommitChangeKind.copied,
          'T' => GitCommitChangeKind.typeChanged,
          'M' => GitCommitChangeKind.modified,
          _ => GitCommitChangeKind.unknown,
        },
        additions: stat?.additions,
        deletions: stat?.deletions,
      ),
    );
  }
  return List<GitCommitFileChange>.unmodifiable(files);
}

_CommitNumStat _parseCommitNumStat(List<int> bytes) {
  final fields = _nullSeparatedBytes(bytes);
  final byPath = <GitPath, _FileStat>{};
  var additions = 0;
  var deletions = 0;
  var index = 0;
  while (index < fields.length) {
    final record = fields[index++];
    if (record.isEmpty) continue;
    final firstTab = record.indexOf(0x09);
    final secondTab = firstTab < 0 ? -1 : record.indexOf(0x09, firstTab + 1);
    if (firstTab < 0 || secondTab < 0) {
      throw GitParseException('Unexpected commit numstat record: $record');
    }
    final added = int.tryParse(utf8.decode(record.sublist(0, firstTab)));
    final deleted = int.tryParse(
      utf8.decode(record.sublist(firstTab + 1, secondTab)),
    );
    final path = record.sublist(secondTab + 1);
    List<int> targetPath = path;
    if (path.isEmpty) {
      if (index + 1 >= fields.length) {
        throw const GitParseException('Rename numstat record is incomplete.');
      }
      index++; // Original path is represented by the next NUL-delimited field.
      targetPath = fields[index++];
    }
    final stat = _FileStat(additions: added, deletions: deleted);
    byPath[GitPath(targetPath)] = stat;
    additions += added ?? 0;
    deletions += deleted ?? 0;
  }
  return _CommitNumStat(
    byPath: Map<GitPath, _FileStat>.unmodifiable(byPath),
    additions: additions,
    deletions: deletions,
  );
}

/// 中文：按 NUL 字节拆分 Git 输出，并保留每个字段的原始路径字节。
///
/// English: Splits Git output on NUL bytes while preserving raw path bytes in
/// every field.
List<List<int>> _nullSeparatedBytes(List<int> bytes) {
  if (bytes.isEmpty) return const [];
  final fields = <List<int>>[];
  var start = 0;
  for (var index = 0; index < bytes.length; index++) {
    if (bytes[index] != 0) continue;
    fields.add(bytes.sublist(start, index));
    start = index + 1;
  }
  if (start < bytes.length) {
    fields.add(bytes.sublist(start));
  }
  return fields;
}

final class _FileStat {
  const _FileStat({required this.additions, required this.deletions});

  final int? additions;
  final int? deletions;
}

final class _CommitNumStat {
  const _CommitNumStat({
    required this.byPath,
    required this.additions,
    required this.deletions,
  });

  final Map<GitPath, _FileStat> byPath;
  final int additions;
  final int deletions;
}

/// 中文：将 UTF-8 输出按换行拆分，并忽略唯一的末尾换行符。
///
/// English: Splits UTF-8 output into lines while discarding one trailing
/// newline.
List<String> _outputLines(List<int> bytes) {
  final text = utf8.decode(bytes, allowMalformed: true);
  final withoutFinalNewline = text.endsWith('\n')
      ? text.substring(0, text.length - 1)
      : text;
  return withoutFinalNewline.split('\n');
}

/// 中文：解码输入内容。
/// English: Decodes the input content.
String _decodeSingleLine(List<int> bytes) {
  var end = bytes.length;
  if (end > 0 && bytes[end - 1] == 0x0a) {
    end--;
  }
  if (end > 0 && bytes[end - 1] == 0x0d) {
    end--;
  }
  return utf8.decode(bytes.sublist(0, end), allowMalformed: true);
}

DateTime? _parseUnixTimestamp(List<int>? bytes) {
  if (bytes == null) return null;
  final seconds = int.tryParse(_decodeSingleLine(bytes).trim());
  return seconds == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(
          seconds * 1000,
          isUtc: true,
        ).toLocal();
}

List<GitRepositoryAuthorSummary> _parseAuthorSummaries(List<int> bytes) {
  final summaries = <GitRepositoryAuthorSummary>[];
  final record = RegExp(r'^\s*(\d+)\s+(.+?)\s+<([^>]*)>$');
  for (final line in _outputLines(bytes)) {
    final match = record.firstMatch(line);
    if (match == null) continue;
    final count = int.tryParse(match.group(1)!);
    if (count == null) continue;
    summaries.add(
      GitRepositoryAuthorSummary(
        name: match.group(2)!.trim(),
        email: match.group(3)!.trim(),
        commitCount: count,
      ),
    );
  }
  return List<GitRepositoryAuthorSummary>.unmodifiable(summaries);
}

/// 中文：识别由 Git stash reflog 输出的受限引用选择器。
/// English: Recognizes the constrained reference selectors emitted by Git's
/// stash reflog.
bool _isStashReference(String value) =>
    RegExp(r'^stash@\{[0-9]+\}$').hasMatch(value);
