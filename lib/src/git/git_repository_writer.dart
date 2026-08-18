import 'dart:convert';

import 'git_errors.dart';
import 'git_models.dart';
import 'git_runner.dart';

/// Performs the small, explicitly allowed Git mutations used by the P0 UI.
///
/// This class deliberately excludes reset, clean, merge and all remote
/// operations. Each method accepts a literal path and never invokes a shell.
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

  String _requireUtf8Path(GitPath path) {
    if (!path.isValidUtf8) {
      throw const GitException(
        'This file name is not valid UTF-8 and cannot be changed safely yet.',
      );
    }
    return path.display;
  }
}
