import 'dart:convert';
import 'dart:io';

import 'git_cancellation.dart';
import 'git_errors.dart';
import 'git_models.dart';
import 'git_runner.dart';

/// Performs the small, explicitly allowed Git mutations used by the P0 UI.
///
/// This class deliberately excludes reset and clean operations. Each method
/// accepts literal inputs and never invokes a shell.
final class GitRepositoryWriter {
  GitRepositoryWriter(this.runner);

  final GitRunner runner;

  /// 中文：暂存指定路径。
  /// English: Stages the specified path.
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

  /// 中文：取消暂存指定路径。
  /// English: Unstages the specified path.
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
  /// 中文：创建所需的对象或资源。
  /// English: Creates the required object or resource.
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
  /// 中文：创建所需的对象或资源。
  /// English: Creates the required object or resource.
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
  /// 中文：切换到目标状态。
  /// English: Switches to the target state.
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

  /// 中文：从已获取的远端跟踪分支创建本地跟踪分支并切换过去，不猜测其他分支名。
  ///
  /// English: Creates and switches to a local tracking branch from an already
  /// fetched remote-tracking branch without guessing another branch name.
  Future<void> switchToRemoteBranch(
    GitRepository repository, {
    required String remoteName,
  }) async {
    final normalizedName = remoteName.trim();
    if (normalizedName.isEmpty || !normalizedName.contains('/')) {
      throw ArgumentError.value(
        remoteName,
        'remoteName',
        'A remote-tracking branch name is required.',
      );
    }
    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          'switch',
          '--track',
          '--no-guess',
          '--',
          normalizedName,
        ],
        workingDirectory: repository.commandDirectory,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 256 * 1024,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Checking out remote branch');
  }

  /// 中文：以指定本地分支的提交为起点创建新分支，不切换工作区也不覆盖已有引用。
  ///
  /// English: Creates a local branch at a named local branch without switching
  /// the work tree or overwriting an existing ref.
  Future<void> createLocalBranchFromLocalBranch(
    GitRepository repository, {
    required String name,
    required String sourceName,
  }) async {
    final normalizedName = name.trim();
    final normalizedSource = sourceName.trim();
    if (normalizedName.isEmpty || normalizedSource.isEmpty) {
      throw ArgumentError('A branch name and source branch are required.');
    }
    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          'branch',
          '--',
          normalizedName,
          'refs/heads/$normalizedSource',
        ],
        workingDirectory: repository.commandDirectory,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 256 * 1024,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Creating local branch from local branch');
  }

  /// 中文：重命名本地分支，不会覆盖已有引用或执行强制重命名。
  ///
  /// English: Renames a local branch without overwriting an existing ref or
  /// using Git's force-rename mode.
  Future<void> renameLocalBranch(
    GitRepository repository, {
    required String oldName,
    required String newName,
  }) async {
    final normalizedOldName = oldName.trim();
    final normalizedNewName = newName.trim();
    if (normalizedOldName.isEmpty || normalizedNewName.isEmpty) {
      throw ArgumentError('Both the old and new branch names are required.');
    }
    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          'branch',
          '-m',
          '--',
          normalizedOldName,
          normalizedNewName,
        ],
        workingDirectory: repository.commandDirectory,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 256 * 1024,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Renaming local branch');
  }

  /// 中文：以 Git 的安全删除模式删除已合并的本地分支，绝不强制删除未合并提交。
  ///
  /// English: Deletes a merged local branch with Git's safe deletion mode and
  /// never force-deletes unmerged commits.
  Future<void> deleteMergedLocalBranch(
    GitRepository repository, {
    required String name,
  }) async {
    final normalizedName = name.trim();
    if (normalizedName.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Branch name is empty.');
    }
    final result = await runner.run(
      GitInvocation(
        arguments: ['--no-pager', 'branch', '-d', '--', normalizedName],
        workingDirectory: repository.commandDirectory,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 256 * 1024,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Deleting merged local branch');
  }

  /// 中文：将指定本地分支合并到当前分支；有新增提交时使用 `--no-ff` 保留显式合并记录，
  /// 并允许 Git hooks 运行。
  ///
  /// English: Merges a local branch into the current branch, using `--no-ff`
  /// for an explicit record when it contributes commits, while allowing hooks.
  Future<void> mergeLocalBranch(
    GitRepository repository, {
    required String sourceName,
  }) async {
    final normalizedName = sourceName.trim();
    if (normalizedName.isEmpty) {
      throw ArgumentError.value(
        sourceName,
        'sourceName',
        'A source branch name is required.',
      );
    }
    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          'merge',
          '--no-edit',
          '--no-ff',
          'refs/heads/$normalizedName',
        ],
        workingDirectory: repository.commandDirectory,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 512 * 1024,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Merging local branch');
  }

  /// Initializes an existing empty directory without changing Git settings.
  /// 中文：初始化当前功能。
  /// English: Initializes the current feature.
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

  /// 中文：向不存在或已有的空目录克隆远端 URL，并将取消令牌和 AskPass 环境传给 Git。
  ///
  /// English: Clones a remote URL into a missing or existing empty directory and
  /// forwards cancellation and AskPass environment to Git.
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
    final targetType = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (targetType == FileSystemEntityType.directory &&
        !await directory.list(followLinks: false).isEmpty) {
      throw const GitException('只能克隆到空目录，避免覆盖现有文件。');
    }
    if (targetType != FileSystemEntityType.notFound &&
        targetType != FileSystemEntityType.directory) {
      throw const GitException('克隆目标已存在，但它不是目录。');
    }
    if (targetType == FileSystemEntityType.notFound &&
        !await directory.parent.exists()) {
      throw const GitException('所选存放位置已不存在。');
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

  /// 中文：获取约定的 `origin` 远端引用，不修改工作区。
  ///
  /// English: Fetches references from the conventional `origin` remote
  /// without changing the work tree.
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

  /// 中文：仅在当前 HEAD 可快速前进时从已配置上游拉取；`--ff-only` 会拒绝隐式合并提交。
  ///
  /// English: Pulls from the configured upstream only when HEAD can fast
  /// forward; `--ff-only` rejects implicit merge commits.
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

  /// 中文：将当前分支推送到已配置上游，且不提供 force 选项，因此不会重写远端历史。
  ///
  /// English: Pushes the current branch to its configured upstream without a
  /// force option, so it never rewrites remote history.
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
  /// 中文：验证当前条件。
  /// English: Verifies the current condition.
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

  /// 中文：读取所需的数据。
  /// English: Reads the required data.
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

  /// 中文：读取所需的数据。
  /// English: Reads the required data.
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

  /// 中文：检查并返回所需值。
  /// English: Checks for and returns the required value.
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
