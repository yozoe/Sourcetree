import 'dart:convert';
import 'dart:io';

import 'git_errors.dart';
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

  /// 中文：读取所需的数据。
  /// English: Reads the required data.
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
    return statusParser.parse(result.stdoutBytes);
  }

  /// 中文：读取所需的数据。
  /// English: Reads the required data.
  Future<List<GitCommit>> readRecentHistory(
    GitRepository repository, {
    int limit = 100,
    int offset = 0,
  }) async {
    if (limit <= 0 || limit > 10000) {
      throw RangeError.range(limit, 1, 10000, 'limit');
    }
    if (offset < 0) {
      throw RangeError.value(offset, 'offset', 'Must not be negative.');
    }

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
        outputLimit: const GitOutputLimit(
          stdoutBytes: 1024,
          stderrBytes: 64 * 1024,
        ),
      ),
    );
    if (head.exitCode == 1 && head.stderrBytes.isEmpty) {
      return const [];
    }
    head.throwIfFailed(operation: 'Resolving HEAD');

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
          '--branches',
          'HEAD',
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

  /// Reads local branches without parsing human-oriented `git branch` output.
  /// 中文：读取所需的数据。
  /// English: Reads the required data.
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
          '--format=%(refname:short)%00%(objectname)%00%(upstream:short)',
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
      if (fields.length != 3 || fields[0].isEmpty || fields[1].isEmpty) {
        throw GitParseException('Unexpected local branch record: $record');
      }
      branches.add(
        GitLocalBranch(
          name: fields[0],
          objectId: fields[1],
          upstream: fields[2].isEmpty ? null : fields[2],
        ),
      );
    }
    return List<GitLocalBranch>.unmodifiable(branches);
  }

  /// Returns whether the conventional `origin` remote is configured.
  /// 中文：检查目标是否存在或可用。
  /// English: Checks whether the target exists or is available.
  Future<bool> hasOriginRemote(GitRepository repository) async {
    final result = await runner.run(
      GitInvocation(
        arguments: const ['--no-pager', 'remote', 'get-url', 'origin'],
        workingDirectory: repository.commandDirectory,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 256 * 1024,
          stderrBytes: 256 * 1024,
        ),
      ),
    );
    if (result.isSuccess) {
      return true;
    }
    final message = result.stderrText.toLowerCase();
    if (result.exitCode == 2 && message.contains('no such remote')) {
      return false;
    }
    result.throwIfFailed(operation: 'Reading origin remote');
    return false;
  }

  /// Reads the file list and line statistics produced by one committed revision.
  ///
  /// The revision comes from [readRecentHistory], but is still constrained to
  /// an object-id shaped value before it is passed to Git as a revision. Merge
  /// commits are compared with [parentObjectId], normally their first parent.
  /// 中文：读取所需的数据。
  /// English: Reads the required data.
  Future<GitCommitChangeSummary> readCommitChanges(
    GitRepository repository, {
    required String objectId,
    String? parentObjectId,
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
