import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path_utils;

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

  /// Chooses one side of an unmerged path and stages that choice as resolved.
  /// 中文：选择冲突文件的“我的”或“他们的”版本，并将该选择标记为已解决。
  Future<void> resolveConflictUsingSide(
    GitRepository repository,
    GitPath path, {
    required bool useOurs,
  }) async {
    final displayPath = _requireUtf8Path(path);
    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          '--literal-pathspecs',
          'checkout',
          useOurs ? '--ours' : '--theirs',
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
    result.throwIfFailed(operation: 'Choosing conflict side');
    await stagePath(repository, path);
  }

  /// Restores Git's conflict-marker merge result for an unmerged path.
  /// 中文：重新生成未解决文件的冲突标记。
  Future<void> restartConflictMerge(
    GitRepository repository,
    GitPath path,
  ) async {
    final displayPath = _requireUtf8Path(path);
    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          '--literal-pathspecs',
          'checkout',
          '--merge',
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
    result.throwIfFailed(operation: 'Restarting conflict merge');
  }

  /// Restores the unmerged index stages retained by Git's resolve-undo data.
  /// 中文：使用 Git 的 resolve-undo 记录把文件重新标记为未解决。
  Future<void> markConflictUnresolved(
    GitRepository repository,
    GitPath path,
  ) async {
    final displayPath = _requireUtf8Path(path);
    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          '--literal-pathspecs',
          'update-index',
          '--unresolve',
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
    result.throwIfFailed(operation: 'Marking conflict unresolved');
  }

  /// 中文：将内部 Diff 中编辑的 UTF-8 结果安全写回工作区，并暂存为已解决。
  ///
  /// English: Safely writes the UTF-8 result edited in the internal Diff back
  /// to the work tree and stages it as resolved.
  Future<void> resolveConflictWithContent(
    GitRepository repository,
    GitPath path,
    String content,
  ) async {
    final root = repository.workTreeRoot;
    if (root == null) {
      throw const GitException('A working tree is required.');
    }
    final displayPath = _requireUtf8Path(path);
    if (path_utils.isAbsolute(displayPath)) {
      throw const GitException('The conflicted path is outside the work tree.');
    }
    final canonicalRoot = await Directory(root).resolveSymbolicLinks();
    final target = path_utils.normalize(path_utils.join(root, displayPath));
    if (!path_utils.isWithin(root, target)) {
      throw const GitException('The conflicted path is outside the work tree.');
    }
    final targetType = await FileSystemEntity.type(target, followLinks: false);
    if (targetType == FileSystemEntityType.link ||
        (targetType != FileSystemEntityType.file &&
            targetType != FileSystemEntityType.notFound)) {
      throw const GitException('The conflicted path is not a regular file.');
    }
    final parent = Directory(path_utils.dirname(target));
    final canonicalParent = await parent.resolveSymbolicLinks();
    if (canonicalParent != canonicalRoot &&
        !path_utils.isWithin(canonicalRoot, canonicalParent)) {
      throw const GitException('The conflicted path is outside the work tree.');
    }
    await File(target).writeAsString(content, encoding: utf8, flush: true);
    await stagePath(repository, path);
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
    await fetchRemote(
      repository,
      remoteName: 'origin',
      cancellationToken: cancellationToken,
      environment: environment,
    );
  }

  /// Fetches one configured remote without changing the working tree.
  /// 中文：获取指定远端引用，不修改工作区。
  Future<void> fetchRemote(
    GitRepository repository, {
    required String remoteName,
    GitCancellationToken? cancellationToken,
    Map<String, String> environment = const {},
  }) async {
    final normalizedName = remoteName.trim();
    if (normalizedName.isEmpty ||
        normalizedName.startsWith('-') ||
        normalizedName.contains(RegExp(r'[\x00\s]'))) {
      throw ArgumentError.value(
        remoteName,
        'remoteName',
        'A valid remote name is required.',
      );
    }
    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          'fetch',
          '--no-recurse-submodules',
          normalizedName,
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
    result.throwIfFailed(operation: 'Fetching remote');
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

  /// Executes a pull configured by the Sourcetree-style pull dialog.
  /// 中文：按 Sourcetree 风格拉取对话框的选项执行拉取。
  Future<void> pull(
    GitRepository repository, {
    required GitPullOptions options,
    GitCancellationToken? cancellationToken,
    Map<String, String> environment = const {},
  }) async {
    final remoteName = options.remoteName.trim();
    final remoteBranch = options.remoteBranch.trim();
    _validatePullRef(remoteName, 'remoteName');
    _validatePullRef(remoteBranch, 'remoteBranch');

    final arguments = <String>[
      '--no-pager',
      '-c',
      'submodule.recurse=false',
      'pull',
    ];
    if (options.rebase) {
      arguments.add('--rebase');
    } else {
      // Git commits a merge automatically by default. Sourcetree's
      // "立即提交合并的改动" checkbox controls that behavior.
      if (!options.commitMerge) arguments.add('--no-commit');
      if (options.createMergeCommit) arguments.add('--no-ff');
    }
    if (options.includeMergedCommits) arguments.add('--log');
    arguments
      ..add(remoteName)
      ..add(remoteBranch);

    final result = await runner.run(
      GitInvocation(
        arguments: arguments,
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

  static void _validatePullRef(String value, String name) {
    if (value.isEmpty ||
        value.startsWith('-') ||
        value.contains(RegExp(r'[\x00\s~^:?*\\\[]')) ||
        value.contains('..') ||
        value.contains('@{')) {
      throw ArgumentError.value(value, name, 'Must be a valid Git ref name.');
    }
  }

  /// Continues a paused rebase after the user has staged conflict fixes.
  /// 中文：用户暂存冲突修复后继续变基。
  Future<void> continueRebase(
    GitRepository repository, {
    GitCancellationToken? cancellationToken,
    Map<String, String> environment = const {},
  }) async {
    await _runRebaseCommand(
      repository,
      const ['--continue'],
      operation: 'Continuing rebase',
      cancellationToken: cancellationToken,
      environment: environment,
    );
  }

  /// Aborts the paused rebase and restores the pre-rebase branch state.
  /// 中文：中止暂停的变基并恢复变基前的分支状态。
  Future<void> abortRebase(
    GitRepository repository, {
    GitCancellationToken? cancellationToken,
    Map<String, String> environment = const {},
  }) async {
    await _runRebaseCommand(
      repository,
      const ['--abort'],
      operation: 'Aborting rebase',
      cancellationToken: cancellationToken,
      environment: environment,
    );
  }

  Future<void> _runRebaseCommand(
    GitRepository repository,
    List<String> commandArguments, {
    required String operation,
    GitCancellationToken? cancellationToken,
    Map<String, String> environment = const {},
  }) async {
    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          '-c',
          'core.editor=true',
          'rebase',
          ...commandArguments,
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
    result.throwIfFailed(operation: operation);
  }

  /// 中文：将当前分支推送到已配置上游；首次推送时使用 origin 上的同名分支并设置上游。始终不提供 force 选项。
  ///
  /// English: Pushes to the configured upstream, or sets origin's same-named
  /// branch as upstream on first push. No force option is ever supplied.
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
          if (target.setUpstream) '--set-upstream',
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

    final configuredRemote = await _tryReadBranchConfig(
      repository,
      branchName: branchName,
      key: 'remote',
      cancellationToken: cancellationToken,
    );
    final configuredMerge = await _tryReadBranchConfig(
      repository,
      branchName: branchName,
      key: 'merge',
      cancellationToken: cancellationToken,
    );
    if (configuredRemote == null && configuredMerge == null) {
      final remoteRef = 'refs/heads/$branchName';
      return _GitPushTarget(
        remoteName: 'origin',
        remoteRef: remoteRef,
        refspec: 'HEAD:$remoteRef',
        setUpstream: true,
      );
    }
    if (configuredRemote == null || configuredMerge == null) {
      throw const GitException(
        'The current branch has an incomplete remote tracking target.',
      );
    }
    final remoteName = configuredRemote;
    final remoteRef = configuredMerge;
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
      setUpstream: false,
    );
  }

  /// 中文：读取可选的分支配置；配置不存在时返回 null，其他 Git 错误仍向上传递。
  /// English: Reads optional branch configuration, returning null only when
  /// the key is absent while preserving all other Git failures.
  Future<String?> _tryReadBranchConfig(
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
    if (result.exitCode == 1 &&
        result.stdoutBytes.isEmpty &&
        result.stderrBytes.isEmpty) {
      return null;
    }
    result.throwIfFailed(operation: 'Reading branch push target');
    final value = result.stdoutText.trim();
    return value.isEmpty ? null : value;
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
    required this.setUpstream,
  });

  final String remoteName;
  final String remoteRef;
  final String refspec;
  final bool setUpstream;
}
