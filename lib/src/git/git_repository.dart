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

  /// Returns `null` when [path] is not within a repository.
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

  Future<String> _readPath(String path, List<String> arguments) async {
    final result = await _revParse(path, arguments);
    result.throwIfFailed(operation: 'Repository path detection');
    return _decodeSingleLine(result.stdoutBytes);
  }

  bool _parseBoolean(String value) {
    return switch (value) {
      'true' => true,
      'false' => false,
      _ => throw GitParseException('Expected Git boolean, got: $value'),
    };
  }

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

  /// Reads a unified diff for one literal path.
  ///
  /// The path is always placed after `--`; wildcard/pathspec magic and
  /// external diff/textconv execution are disabled.
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

List<String> _outputLines(List<int> bytes) {
  final text = utf8.decode(bytes, allowMalformed: true);
  final withoutFinalNewline = text.endsWith('\n')
      ? text.substring(0, text.length - 1)
      : text;
  return withoutFinalNewline.split('\n');
}

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
