import 'dart:convert';
import 'dart:io';

import 'git_cancellation.dart';
import 'git_errors.dart';
import 'git_models.dart';
import 'git_runner.dart';

/// Performs the small, explicitly allowed Git mutations used by the P0 UI.
///
/// This class deliberately excludes reset, clean, merge and remote sync
/// operations. Each method accepts literal inputs and never invokes a shell.
final class GitRepositoryWriter {
  GitRepositoryWriter(this.runner);

  final GitRunner runner;

  Future<void> stagePath(GitRepository repository, GitPath path) async {
    final displayPath = _requireUtf8Path(path);
    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          '--literal-pathspecs',
          'add',
          '--',
          displayPath,
        ],
        workingDirectory: repository.commandDirectory,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 256 * 1024,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Staging file');
  }

  Future<void> unstagePath(
    GitRepository repository,
    GitPath path, {
    required bool isUnbornBranch,
  }) async {
    final displayPath = _requireUtf8Path(path);
    final arguments = isUnbornBranch
        ? <String>[
            '--no-pager',
            '--literal-pathspecs',
            'rm',
            '--cached',
            '--ignore-unmatch',
            '--',
            displayPath,
          ]
        : <String>[
            '--no-pager',
            '--literal-pathspecs',
            'restore',
            '--staged',
            '--',
            displayPath,
          ];
    final result = await runner.run(
      GitInvocation(
        arguments: arguments,
        workingDirectory: repository.commandDirectory,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 256 * 1024,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Unstaging file');
  }

  /// Creates a commit from the current index without bypassing Git hooks.
  ///
  /// The message is sent through stdin rather than the command line, so it is
  /// not interpreted as an option and is not exposed in process arguments.
  Future<void> createCommit(
    GitRepository repository, {
    required String message,
  }) async {
    if (message.trim().isEmpty) {
      throw ArgumentError.value(message, 'message', 'Commit message is empty.');
    }
    final messageBytes = utf8.encode(
      message.endsWith('\n') ? message : '$message\n',
    );
    final result = await runner.run(
      GitInvocation(
        arguments: const ['--no-pager', 'commit', '--file=-'],
        workingDirectory: repository.commandDirectory,
        stdinBytes: messageBytes,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 512 * 1024,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Creating commit');
  }

  /// Creates a new local branch at the current HEAD without checking it out.
  ///
  /// Git validates the ref name and refuses to overwrite an existing branch.
  Future<void> createLocalBranch(
    GitRepository repository, {
    required String name,
  }) async {
    if (name.trim().isEmpty) {
      throw ArgumentError.value(name, 'name', 'Branch name is empty.');
    }
    final result = await runner.run(
      GitInvocation(
        arguments: ['--no-pager', 'branch', '--', name],
        workingDirectory: repository.commandDirectory,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 256 * 1024,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Creating local branch');
  }

  /// Switches to an existing local branch without creating or overwriting refs.
  Future<void> switchToLocalBranch(
    GitRepository repository, {
    required String name,
  }) async {
    if (name.trim().isEmpty) {
      throw ArgumentError.value(name, 'name', 'Branch name is empty.');
    }
    final result = await runner.run(
      GitInvocation(
        arguments: ['--no-pager', 'switch', '--', name],
        workingDirectory: repository.commandDirectory,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 256 * 1024,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Switching local branch');
  }

  /// Initializes an existing empty directory without changing Git settings.
  Future<void> initializeRepository(String directoryPath) async {
    final normalizedPath = directoryPath.trim();
    if (normalizedPath.isEmpty) {
      throw ArgumentError.value(
        directoryPath,
        'directoryPath',
        'Must not be empty.',
      );
    }
    final directory = Directory(normalizedPath);
    if (!await directory.exists()) {
      throw const GitException('The selected directory no longer exists.');
    }
    if (!await directory.list(followLinks: false).isEmpty) {
      throw const GitException('只能初始化空目录，避免意外修改现有文件。');
    }

    final result = await runner.run(
      GitInvocation(
        arguments: ['--no-pager', 'init', '--', directory.path],
        outputLimit: const GitOutputLimit(
          stdoutBytes: 256 * 1024,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Initializing repository');
  }

  /// Clones into an existing empty directory without interpreting the URL.
  Future<void> cloneRepository({
    required String remoteUrl,
    required String directoryPath,
    GitCancellationToken? cancellationToken,
    Map<String, String> environment = const {},
  }) async {
    final normalizedUrl = remoteUrl.trim();
    if (normalizedUrl.isEmpty) {
      throw ArgumentError.value(remoteUrl, 'remoteUrl', 'Must not be empty.');
    }
    final directory = Directory(directoryPath.trim());
    if (!await directory.exists()) {
      throw const GitException('The selected directory no longer exists.');
    }
    if (!await directory.list(followLinks: false).isEmpty) {
      throw const GitException('只能克隆到空目录，避免覆盖现有文件。');
    }
    final result = await runner.run(
      GitInvocation(
        arguments: ['--no-pager', 'clone', '--', normalizedUrl, directory.path],
        cancellationToken: cancellationToken,
        environment: environment,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 1024 * 1024,
          stderrBytes: 1024 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Cloning repository');
  }

  /// Fetches the conventional `origin` remote without altering the work tree.
  Future<void> fetchOrigin(
    GitRepository repository, {
    GitCancellationToken? cancellationToken,
    Map<String, String> environment = const {},
  }) async {
    final result = await runner.run(
      GitInvocation(
        arguments: const [
          '--no-pager',
          'fetch',
          '--no-recurse-submodules',
          'origin',
        ],
        workingDirectory: repository.commandDirectory,
        cancellationToken: cancellationToken,
        environment: environment,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 1024 * 1024,
          stderrBytes: 1024 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Fetching origin');
  }

  /// Pulls the configured upstream only when it can fast-forward HEAD.
  ///
  /// `--ff-only` deliberately rejects implicit merge commits and leaves merge
  /// handling to a dedicated workflow.
  Future<void> pullFastForward(
    GitRepository repository, {
    GitCancellationToken? cancellationToken,
    Map<String, String> environment = const {},
  }) async {
    final result = await runner.run(
      GitInvocation(
        arguments: const [
          '--no-pager',
          '-c',
          'submodule.recurse=false',
          'pull',
          '--ff-only',
        ],
        workingDirectory: repository.commandDirectory,
        cancellationToken: cancellationToken,
        environment: environment,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 1024 * 1024,
          stderrBytes: 1024 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Pulling current branch');
  }

  /// Pushes the current branch to its configured upstream.
  ///
  /// No force option is exposed; a rejected non-fast-forward push is reported
  /// to the caller without rewriting remote history.
  Future<void> pushUpstream(
    GitRepository repository, {
    GitCancellationToken? cancellationToken,
    Map<String, String> environment = const {},
  }) async {
    final target = await _readPushTarget(
      repository,
      cancellationToken: cancellationToken,
    );
    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          'push',
          '--porcelain',
          '--',
          target.remoteName,
          target.refspec,
        ],
        workingDirectory: repository.commandDirectory,
        cancellationToken: cancellationToken,
        environment: environment,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 1024 * 1024,
          stderrBytes: 1024 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Pushing current branch');
  }

  /// Verifies whether the configured upstream currently contains local HEAD.
  ///
  /// This is read-only and deliberately does not update remote-tracking refs;
  /// callers can use Fetch when they need the local ahead/behind snapshot to
  /// catch up as well.
  Future<bool> verifyUpstream(
    GitRepository repository, {
    GitCancellationToken? cancellationToken,
  }) async {
    final target = await _readPushTarget(
      repository,
      cancellationToken: cancellationToken,
    );
    final headResult = await runner.run(
      GitInvocation(
        arguments: const ['rev-parse', 'HEAD'],
        workingDirectory: repository.commandDirectory,
        cancellationToken: cancellationToken,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 64 * 1024,
          stderrBytes: 64 * 1024,
        ),
      ),
    );
    headResult.throwIfFailed(operation: 'Reading local HEAD');
    final remoteResult = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          'ls-remote',
          '--refs',
          '--heads',
          '--',
          target.remoteName,
          target.remoteRef,
        ],
        workingDirectory: repository.commandDirectory,
        cancellationToken: cancellationToken,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 256 * 1024,
          stderrBytes: 256 * 1024,
        ),
      ),
    );
    remoteResult.throwIfFailed(operation: 'Verifying remote push state');
    final expectedHead = headResult.stdoutText.trim();
    final remoteLine = remoteResult.stdoutText
        .split('\n')
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => '');
    if (remoteLine.isEmpty) return false;
    final remoteHead = remoteLine.split(RegExp(r'\s+')).first;
    return remoteHead == expectedHead;
  }

  Future<_GitPushTarget> _readPushTarget(
    GitRepository repository, {
    GitCancellationToken? cancellationToken,
  }) async {
    final branchResult = await runner.run(
      GitInvocation(
        arguments: const ['symbolic-ref', '--quiet', '--short', 'HEAD'],
        workingDirectory: repository.commandDirectory,
        cancellationToken: cancellationToken,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 64 * 1024,
          stderrBytes: 64 * 1024,
        ),
      ),
    );
    branchResult.throwIfFailed(operation: 'Reading current branch');
    final branchName = branchResult.stdoutText.trim();
    if (branchName.isEmpty) {
      throw const GitException('The current branch has no push target.');
    }

    final remoteName = await _readBranchConfig(
      repository,
      branchName: branchName,
      key: 'remote',
      cancellationToken: cancellationToken,
    );
    final remoteRef = await _readBranchConfig(
      repository,
      branchName: branchName,
      key: 'merge',
      cancellationToken: cancellationToken,
    );
    if (remoteName == '.' ||
        !remoteRef.startsWith('refs/heads/') ||
        remoteRef.length == 'refs/heads/'.length) {
      throw const GitException(
        'The current branch does not have a supported remote tracking target.',
      );
    }
    return _GitPushTarget(
      remoteName: remoteName,
      remoteRef: remoteRef,
      refspec: 'HEAD:$remoteRef',
    );
  }

  Future<String> _readBranchConfig(
    GitRepository repository, {
    required String branchName,
    required String key,
    GitCancellationToken? cancellationToken,
  }) async {
    final result = await runner.run(
      GitInvocation(
        arguments: ['config', '--get', 'branch.$branchName.$key'],
        workingDirectory: repository.commandDirectory,
        cancellationToken: cancellationToken,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 64 * 1024,
          stderrBytes: 64 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Reading branch push target');
    final value = result.stdoutText.trim();
    if (value.isEmpty) {
      throw const GitException('The current branch has no push target.');
    }
    return value;
  }

  String _requireUtf8Path(GitPath path) {
    if (!path.isValidUtf8) {
      throw const GitException(
        'This file name is not valid UTF-8 and cannot be changed safely yet.',
      );
    }
    return path.display;
  }
}

final class _GitPushTarget {
  const _GitPushTarget({
    required this.remoteName,
    required this.remoteRef,
    required this.refspec,
  });

  final String remoteName;
  final String remoteRef;
  final String refspec;
}
