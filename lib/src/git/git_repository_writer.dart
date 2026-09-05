import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as path_utils;
import 'package:meta/meta.dart';

import 'git_cancellation.dart';
import 'git_errors.dart';
import 'git_models.dart';
import 'git_runner.dart';

/// Performs the explicitly confirmed Git mutations used by the desktop UI.
///
/// Every method accepts literal inputs and never invokes a shell. Destructive
/// mutations such as hard reset are only reachable after a UI confirmation.
final class GitRepositoryWriter {
  GitRepositoryWriter(
    this.runner, {
    @visibleForTesting this.beforeConflictResultPublicationForTesting,
  });

  final GitRunner runner;
  final FutureOr<void> Function()? beforeConflictResultPublicationForTesting;

  /// 中文：暂存指定路径。
  /// English: Stages the specified path.
  Future<void> stagePath(GitRepository repository, GitPath path) async {
    await stagePaths(repository, [path]);
  }

  /// Stages multiple paths in one Git invocation.
  /// 中文：在一次 Git 调用中暂存多个路径，避免批量操作只完成一部分。
  Future<void> stagePaths(GitRepository repository, List<GitPath> paths) async {
    final displayPaths = [for (final path in paths) _requireUtf8Path(path)];
    if (displayPaths.isEmpty) return;
    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          '--literal-pathspecs',
          'add',
          '--',
          ...displayPaths,
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

  /// Stops tracking paths while preserving their working-tree files.
  ///
  /// 中文：从 Git 索引移除指定路径，但保留工作区文件；调用方必须在执行前
  /// 完成用户确认，并在执行后刷新状态以显示待提交的删除。
  Future<void> stopTrackingPaths(
    GitRepository repository,
    List<GitPath> paths,
  ) async {
    final displayPaths = [for (final path in paths) _requireUtf8Path(path)];
    if (displayPaths.isEmpty) return;
    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          '--literal-pathspecs',
          'rm',
          '--cached',
          '--force',
          '--',
          ...displayPaths,
        ],
        workingDirectory: repository.commandDirectory,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 256 * 1024,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Stopping file tracking');
  }

  /// Deletes one work-tree file or symlink without changing the Git index.
  /// On macOS every parent is opened relative to a pinned work-tree descriptor;
  /// directory removal is rejected because safe recursive unlink is not exposed
  /// by Dart's portable filesystem API.
  ///
  /// 中文：删除一个工作区文件或符号链接而不修改 Git 索引。macOS 会从固定的
  /// 工作区描述符逐级打开父目录；由于 Dart 可移植 API 无法安全递归 unlink，目录删除会失败关闭。
  Future<bool> removeWorkingTreePath(
    GitRepository repository,
    GitPath path,
  ) async {
    final workTreeRoot = repository.workTreeRoot;
    if (workTreeRoot == null) {
      throw const GitException('A working tree is required.');
    }
    final displayPath = _requireUtf8Path(path);
    if (path_utils.isAbsolute(displayPath) ||
        path_utils.split(path_utils.normalize(displayPath)).contains('..')) {
      throw const GitException('The removal path is outside the work tree.');
    }
    if (Platform.isMacOS) {
      return _MacOsSecureRemoval.remove(
        workTreeRoot: await Directory(workTreeRoot).resolveSymbolicLinks(),
        relativePath: displayPath,
      );
    }
    final target = path_utils.normalize(
      path_utils.join(workTreeRoot, displayPath),
    );
    final canonicalRoot = await Directory(workTreeRoot).resolveSymbolicLinks();
    final parent = Directory(path_utils.dirname(target));
    final canonicalParent = await parent.resolveSymbolicLinks();
    if (canonicalParent != canonicalRoot &&
        !path_utils.isWithin(canonicalRoot, canonicalParent)) {
      throw const GitException('The removal path is outside the work tree.');
    }
    final type = await FileSystemEntity.type(target, followLinks: false);
    if (type == FileSystemEntityType.notFound) return false;
    if (type == FileSystemEntityType.directory) {
      throw const GitException(
        'Safe recursive directory removal is unavailable on this platform.',
      );
    }
    if (type == FileSystemEntityType.link) {
      await Link(target).delete();
    } else if (type == FileSystemEntityType.file) {
      await File(target).delete();
    } else {
      throw const GitException('The removal target is not a regular file.');
    }
    return true;
  }

  /// Restores tracked paths to their HEAD versions in both index and work tree.
  ///
  /// 中文：将指定已跟踪路径的索引和工作区同时恢复到 HEAD 版本；这会丢弃这些
  /// 路径的已暂存和未暂存内容，调用方必须先取得用户的明确确认。
  Future<void> resetPathsToHead(
    GitRepository repository,
    List<GitPath> paths,
  ) async {
    final displayPaths = [for (final path in paths) _requireUtf8Path(path)];
    if (displayPaths.isEmpty) return;
    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          '--literal-pathspecs',
          'restore',
          '--source=HEAD',
          '--staged',
          '--worktree',
          '--',
          ...displayPaths,
        ],
        workingDirectory: repository.commandDirectory,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 256 * 1024,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Resetting files to HEAD');
  }

  /// Stages one text hunk from a previously read working-tree diff.
  ///
  /// The original byte patch is applied directly to Git's index. Git rejects
  /// it if the index changed after the Diff was read, while the working-tree
  /// file remains untouched.
  ///
  /// 中文：暂存先前读取的工作区文本 Diff 中的一个区块。原始字节补丁会直接
  /// 应用到 Git 索引；若读取 Diff 后索引发生变化，Git 会拒绝应用，工作区文件
  /// 始终保持不变。
  Future<void> stageDiffHunk(
    GitRepository repository, {
    required GitUnifiedDiff diff,
    required int hunkIndex,
  }) async {
    if (diff.source != GitDiffSource.workingTree) {
      throw ArgumentError.value(
        diff,
        'diff',
        'Only working-tree diff hunks can be staged.',
      );
    }
    if (diff.isTruncated) {
      throw ArgumentError.value(
        diff,
        'diff',
        'A truncated diff cannot be safely staged.',
      );
    }
    if (diff.changesFileMode) {
      throw ArgumentError.value(
        diff,
        'diff',
        'A diff that changes file mode cannot be safely staged by hunk.',
      );
    }
    final patch = _singleHunkPatch(diff.bytes, hunkIndex);
    final result = await runner.run(
      GitInvocation(
        arguments: const ['--no-pager', 'apply', '--cached'],
        workingDirectory: repository.commandDirectory,
        stdinBytes: patch,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 256 * 1024,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Staging diff hunk');
  }

  /// Reverse-applies one text hunk from a previously read Diff.
  ///
  /// A working-tree hunk is discarded, a staged hunk is removed only from the
  /// index, and a committed hunk is reverse-applied into the current working
  /// tree without rewriting history. Git rejects stale or incompatible patch
  /// context.
  ///
  /// 中文：反向应用先前读取的文本 Diff 区块。未暂存区块会被放弃，已暂存区块
  /// 只从索引移除，已提交区块会反向应用到当前工作区且不改写历史；上下文过期或
  /// 不兼容时由 Git 拒绝补丁。
  Future<void> revertDiffHunk(
    GitRepository repository, {
    required GitUnifiedDiff diff,
    required int hunkIndex,
  }) async {
    if (diff.isTruncated) {
      throw ArgumentError.value(
        diff,
        'diff',
        'A truncated diff cannot be safely reverted.',
      );
    }
    if (diff.changesFileMode) {
      throw ArgumentError.value(
        diff,
        'diff',
        'A diff that changes file mode cannot be safely reverted by hunk.',
      );
    }
    final patch = _singleHunkPatch(diff.bytes, hunkIndex);
    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          'apply',
          '--reverse',
          if (diff.source == GitDiffSource.staged) '--cached',
        ],
        workingDirectory: repository.commandDirectory,
        stdinBytes: patch,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 256 * 1024,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Reverting diff hunk');
  }

  /// 中文：取消暂存指定路径。
  /// English: Unstages the specified path.
  Future<void> unstagePath(
    GitRepository repository,
    GitPath path, {
    required bool isUnbornBranch,
  }) async {
    await unstagePaths(repository, [path], isUnbornBranch: isUnbornBranch);
  }

  /// Unstages multiple paths in one Git invocation.
  /// 中文：在一次 Git 调用中取消暂存多个路径，保持批量操作的一致性。
  Future<void> unstagePaths(
    GitRepository repository,
    List<GitPath> paths, {
    required bool isUnbornBranch,
  }) async {
    final displayPaths = [for (final path in paths) _requireUtf8Path(path)];
    if (displayPaths.isEmpty) return;
    final arguments = isUnbornBranch
        ? <String>[
            '--no-pager',
            '--literal-pathspecs',
            'rm',
            '--cached',
            '--ignore-unmatch',
            '--',
            ...displayPaths,
          ]
        : <String>[
            '--no-pager',
            '--literal-pathspecs',
            'restore',
            '--staged',
            '--',
            ...displayPaths,
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
    if (Platform.isMacOS) {
      await _MacOsAtomicFileWriter.replace(
        directoryPath: canonicalParent,
        fileName: path_utils.basename(target),
        bytes: utf8.encode(content),
        beforePublicationForTesting: beforeConflictResultPublicationForTesting,
      );
    } else {
      throw const GitException(
        'Safe conflict-result replacement is unavailable on this platform.',
      );
    }
    await stagePath(repository, path);
  }

  /// Creates a commit from the current index without bypassing Git hooks.
  /// When [amend] is true, replaces the current HEAD commit while retaining
  /// the same index semantics for staged and unstaged files.
  ///
  /// The message is sent through stdin rather than the command line, so it is
  /// not interpreted as an option and is not exposed in process arguments.
  /// 中文：创建所需的对象或资源。
  /// English: Creates the required object or resource.
  Future<void> createCommit(
    GitRepository repository, {
    required String message,
    bool amend = false,
  }) async {
    if (message.trim().isEmpty) {
      throw ArgumentError.value(message, 'message', 'Commit message is empty.');
    }
    final messageBytes = utf8.encode(
      message.endsWith('\n') ? message : '$message\n',
    );
    final result = await runner.run(
      GitInvocation(
        arguments: ['--no-pager', 'commit', if (amend) '--amend', '--file=-'],
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

  /// Saves the current working tree in Git's stash reflog. Staged entries are
  /// retained in the snapshot and restored with `--index` by apply/pop.
  ///
  /// 中文：将当前改动保存为贮藏；仅在 [includeUntracked] 为真时包含未跟踪
  /// 文件，绝不默认包含被忽略文件；[keepIndex] 为真时保留暂存区内容。
  Future<void> createStash(
    GitRepository repository, {
    String message = '',
    bool includeUntracked = false,
    bool keepIndex = false,
    GitCancellationToken? cancellationToken,
  }) async {
    final normalizedMessage = message.trim();
    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          'stash',
          'push',
          if (includeUntracked) '--include-untracked',
          if (keepIndex) '--keep-index',
          if (normalizedMessage.isNotEmpty) ...['--message', normalizedMessage],
        ],
        workingDirectory: repository.commandDirectory,
        cancellationToken: cancellationToken,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 512 * 1024,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Creating stash');
  }

  /// Applies one saved working-tree snapshot and retains it in the stash list.
  ///
  /// 中文：恢复指定贮藏但保留该条目；`--index` 同时恢复原有暂存区语义。
  Future<void> applyStash(
    GitRepository repository, {
    required String stashReference,
    GitCancellationToken? cancellationToken,
  }) => _runStashMutation(
    repository,
    operation: 'Applying stash',
    arguments: ['apply', '--index', _requireStashReference(stashReference)],
    cancellationToken: cancellationToken,
  );

  /// Applies one saved snapshot and removes it only if Git completed the apply.
  ///
  /// 中文：恢复后弹出指定贮藏；发生冲突或失败时 Git 会保留贮藏供后续恢复。
  Future<void> popStash(
    GitRepository repository, {
    required String stashReference,
    GitCancellationToken? cancellationToken,
  }) => _runStashMutation(
    repository,
    operation: 'Popping stash',
    arguments: ['pop', '--index', _requireStashReference(stashReference)],
    cancellationToken: cancellationToken,
  );

  /// Permanently removes one saved snapshot from Git's stash reflog.
  ///
  /// 中文：永久删除指定贮藏；调用方必须在此之前取得用户的明确确认。
  Future<void> dropStash(
    GitRepository repository, {
    required String stashReference,
    GitCancellationToken? cancellationToken,
  }) => _runStashMutation(
    repository,
    operation: 'Dropping stash',
    arguments: ['drop', _requireStashReference(stashReference)],
    cancellationToken: cancellationToken,
  );

  /// 中文：以受限输出执行已校验的贮藏子命令，不经由 shell。
  /// English: Executes a validated stash subcommand with bounded output and no
  /// shell interpolation.
  Future<void> _runStashMutation(
    GitRepository repository, {
    required String operation,
    required List<String> arguments,
    GitCancellationToken? cancellationToken,
  }) async {
    final result = await runner.run(
      GitInvocation(
        arguments: ['--no-pager', 'stash', ...arguments],
        workingDirectory: repository.commandDirectory,
        cancellationToken: cancellationToken,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 512 * 1024,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: operation);
  }

  /// 中文：校验 Git 生成的 `stash@{N}` 引用，拒绝任意 revision 或选项文本。
  /// English: Validates a Git-generated `stash@{N}` selector and rejects
  /// arbitrary revisions or option-shaped input.
  String _requireStashReference(String value) {
    final normalized = value.trim();
    if (!RegExp(r'^stash@\{[0-9]+\}$').hasMatch(normalized)) {
      throw ArgumentError.value(
        value,
        'stashReference',
        'A Git stash reference is required.',
      );
    }
    return normalized;
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

  /// 中文：以指定提交为起点创建本地分支，不切换工作区也不覆盖已有引用。
  ///
  /// English: Creates a local branch at the specified commit without checking
  /// it out or overwriting an existing ref.
  Future<void> createLocalBranchFromCommit(
    GitRepository repository, {
    required String name,
    required String objectId,
  }) async {
    final normalizedName = name.trim();
    final normalizedObjectId = objectId.trim();
    if (normalizedName.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Branch name is empty.');
    }
    if (normalizedObjectId.isEmpty ||
        !RegExp(r'^[0-9a-fA-F]{7,64}$').hasMatch(normalizedObjectId)) {
      throw ArgumentError.value(
        objectId,
        'objectId',
        'A valid commit id is required.',
      );
    }
    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          'branch',
          '--',
          normalizedName,
          normalizedObjectId,
        ],
        workingDirectory: repository.commandDirectory,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 256 * 1024,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Creating local branch from commit');
  }

  /// 在指定提交创建本地标签；可选创建包含说明文字的附注标签，绝不覆盖已有标签。
  ///
  /// English: Creates a local tag at the supplied commit. It optionally makes
  /// an annotated tag with a message and never overwrites an existing tag.
  Future<void> createTag(
    GitRepository repository, {
    required String name,
    required String objectId,
    String? annotation,
    bool? annotated,
  }) async {
    final normalizedName = name.trim();
    final normalizedObjectId = objectId.trim();
    final normalizedAnnotation = annotation?.trim();
    final makeAnnotated = annotated ?? normalizedAnnotation != null;
    if (!_isSafeTagName(normalizedName)) {
      throw ArgumentError.value(name, 'name', 'A valid tag name is required.');
    }
    if (!RegExp(r'^[0-9a-fA-F]{7,64}$').hasMatch(normalizedObjectId)) {
      throw ArgumentError.value(
        objectId,
        'objectId',
        'A valid commit id is required.',
      );
    }
    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          'tag',
          if (makeAnnotated) ...[
            '--annotate',
            '--message',
            normalizedAnnotation ?? '',
          ],
          '--',
          normalizedName,
          normalizedObjectId,
        ],
        workingDirectory: repository.commandDirectory,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 256 * 1024,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Creating tag');
  }

  /// 推送一个已经存在的本地标签；refspec 精确限定为用户刚创建的标签。
  ///
  /// English: Pushes exactly one existing local tag using an explicit refspec.
  Future<void> pushTag(
    GitRepository repository, {
    required String remoteName,
    required String tagName,
  }) async {
    final remote = remoteName.trim();
    final tag = tagName.trim();
    if (!_isSafeRemoteName(remote) || !_isSafeTagName(tag)) {
      throw ArgumentError(
        'A configured remote and valid tag name are required.',
      );
    }
    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          'push',
          '--porcelain',
          '--',
          remote,
          'refs/tags/$tag:refs/tags/$tag',
        ],
        workingDirectory: repository.commandDirectory,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 1024 * 1024,
          stderrBytes: 1024 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Pushing tag');
  }

  /// 删除一个本地标签。调用方必须在界面中获得明确确认。
  ///
  /// English: Deletes one local tag. The caller must obtain explicit UI
  /// confirmation before invoking this irreversible local ref mutation.
  Future<void> deleteTag(
    GitRepository repository, {
    required String name,
  }) async {
    final normalizedName = name.trim();
    if (!_isSafeTagName(normalizedName)) {
      throw ArgumentError.value(name, 'name', 'A valid tag name is required.');
    }
    final result = await runner.run(
      GitInvocation(
        arguments: ['--no-pager', 'tag', '--delete', '--', normalizedName],
        workingDirectory: repository.commandDirectory,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 256 * 1024,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Deleting tag');
  }

  /// 删除远端的同名标签。该操作不使用 force，且由调用方先向用户说明影响。
  ///
  /// English: Deletes the matching remote tag without force. The caller is
  /// responsible for presenting the destructive impact before this call.
  Future<void> deleteRemoteTag(
    GitRepository repository, {
    required String remoteName,
    required String tagName,
  }) async {
    final remote = remoteName.trim();
    final tag = tagName.trim();
    if (!_isSafeRemoteName(remote) || !_isSafeTagName(tag)) {
      throw ArgumentError(
        'A configured remote and valid tag name are required.',
      );
    }
    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          'push',
          '--porcelain',
          '--',
          remote,
          ':refs/tags/$tag',
        ],
        workingDirectory: repository.commandDirectory,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 1024 * 1024,
          stderrBytes: 1024 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Deleting remote tag');
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

  /// Checks out a commit in detached HEAD mode without altering refs.
  /// 中文：以分离 HEAD 模式检出指定提交，不修改任何分支引用。
  Future<void> checkoutCommit(
    GitRepository repository, {
    required String objectId,
  }) async {
    final normalizedId = objectId.trim();
    if (normalizedId.isEmpty ||
        !RegExp(r'^[0-9a-fA-F]{7,64}$').hasMatch(normalizedId)) {
      throw ArgumentError.value(
        objectId,
        'objectId',
        'A valid commit id is required.',
      );
    }
    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          'switch',
          '--detach',
          '--no-guess',
          '--',
          normalizedId,
        ],
        workingDirectory: repository.commandDirectory,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 256 * 1024,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Checking out commit');
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

  /// 中文：删除本地分支；默认仅删除已合并分支，只有用户已明确确认时才允许强制删除。
  ///
  /// English: Deletes a local branch. It uses Git's safe merged-only mode by
  /// default and permits force deletion only after explicit user confirmation.
  Future<void> deleteLocalBranch(
    GitRepository repository, {
    required String name,
    required bool force,
  }) async {
    final normalizedName = name.trim();
    if (normalizedName.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Branch name is empty.');
    }
    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          'branch',
          force ? '-D' : '-d',
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
    result.throwIfFailed(operation: 'Deleting local branch');
  }

  /// 中文：删除已获取远端上的分支；remoteName 必须来自已读取的远端引用。
  ///
  /// English: Deletes a branch from an already fetched remote. [remoteName]
  /// must originate from a loaded remote-tracking reference.
  Future<void> deleteRemoteBranch(
    GitRepository repository, {
    required String remoteName,
  }) async {
    final separator = remoteName.indexOf('/');
    if (separator <= 0 || separator == remoteName.length - 1) {
      throw ArgumentError.value(
        remoteName,
        'remoteName',
        'A remote-tracking branch name is required.',
      );
    }
    final remote = remoteName.substring(0, separator);
    final branch = remoteName.substring(separator + 1);
    if (!_isSafeRemoteName(remote)) {
      throw ArgumentError.value(
        remoteName,
        'remoteName',
        'The remote name is not safe to pass to Git.',
      );
    }
    final result = await runner.run(
      GitInvocation(
        arguments: ['--no-pager', 'push', remote, '--delete', '--', branch],
        workingDirectory: repository.commandDirectory,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 256 * 1024,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Deleting remote branch');
  }

  /// Removes one configured remote without deleting any remote repository data.
  ///
  /// 中文：移除一个本地 Git 远端配置；不会删除远端仓库或其上的分支。
  Future<void> removeRemote(GitRepository repository, String remoteName) async {
    final normalizedName = remoteName.trim();
    if (!_isSafeRemoteName(normalizedName) ||
        normalizedName.contains(RegExp(r'[\x00\s]'))) {
      throw ArgumentError.value(
        remoteName,
        'remoteName',
        'A valid remote name is required.',
      );
    }
    final result = await runner.run(
      GitInvocation(
        arguments: ['--no-pager', 'remote', 'remove', '--', normalizedName],
        workingDirectory: repository.commandDirectory,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 256 * 1024,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Removing remote');
  }

  /// 中文：以 Git 的安全删除模式删除已合并的本地分支，绝不强制删除未合并提交。
  ///
  /// English: Deletes a merged local branch with Git's safe deletion mode and
  /// never force-deletes unmerged commits.
  Future<void> deleteMergedLocalBranch(
    GitRepository repository, {
    required String name,
  }) => deleteLocalBranch(repository, name: name, force: false);

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

  /// 中文：将指定的历史提交合并到当前分支；提交 ID 仅作为字面 Git 对象参数使用。
  ///
  /// English: Merges one historical commit into the current branch, passing
  /// its validated object ID as a literal Git object argument.
  Future<void> mergeCommit(
    GitRepository repository, {
    required String objectId,
  }) async {
    final normalizedObjectId = objectId.trim();
    if (!RegExp(r'^[0-9a-fA-F]{7,64}$').hasMatch(normalizedObjectId)) {
      throw ArgumentError.value(
        objectId,
        'objectId',
        'A valid commit id is required.',
      );
    }
    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          'merge',
          '--no-edit',
          '--no-ff',
          normalizedObjectId,
        ],
        workingDirectory: repository.commandDirectory,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 512 * 1024,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Merging commit');
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
    final normalizedUrl = _requireCredentialFreeCloneUrl(remoteUrl);
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
    await fetch(
      repository,
      options: const GitFetchOptions(fetchAllRemotes: false),
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
  }) => fetch(
    repository,
    options: GitFetchOptions(fetchAllRemotes: false, remoteName: remoteName),
    cancellationToken: cancellationToken,
    environment: environment,
  );

  /// 中文：按用户明确选择的范围抓取远端，可选清理失效跟踪分支和同步所有标签。
  ///
  /// English: Fetches the explicitly selected remote scope, optionally
  /// pruning stale tracking refs and fetching all tags.
  Future<void> fetch(
    GitRepository repository, {
    required GitFetchOptions options,
    GitCancellationToken? cancellationToken,
    Map<String, String> environment = const {},
  }) async {
    final normalizedName = options.remoteName.trim();
    if (!options.fetchAllRemotes &&
        (normalizedName.isEmpty ||
            normalizedName.startsWith('-') ||
            normalizedName.contains(RegExp(r'[\x00\s]')))) {
      throw ArgumentError.value(
        options.remoteName,
        'options.remoteName',
        'A valid remote name is required.',
      );
    }
    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          'fetch',
          '--no-recurse-submodules',
          if (options.pruneDeletedTrackingBranches) '--prune',
          if (options.fetchAllTags) '--tags',
          if (options.fetchAllRemotes) '--all' else normalizedName,
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

  /// Rebases the checked-out branch onto one loaded commit. The caller must
  /// ensure the working tree is clean and show the history-rewrite warning.
  /// 中文：将当前分支变基到指定提交；调用方必须先确认工作区干净并展示改写历史提示。
  Future<void> rebaseOnto(
    GitRepository repository, {
    required String objectId,
    GitCancellationToken? cancellationToken,
    Map<String, String> environment = const {},
  }) async {
    final normalizedId = _requireCommitId(objectId);
    await _runRebaseCommand(
      repository,
      [normalizedId],
      operation: 'Rebasing current branch',
      cancellationToken: cancellationToken,
      environment: environment,
    );
  }

  /// Starts an interactive rebase using the user-edited [instructions]. The
  /// generated temporary todo file is copied into Git's sequence-editor path
  /// and removed when the Git process completes.
  /// 中文：使用用户编辑后的 [instructions] 启动交互式变基；临时 todo 文件会复制给 Git 并在结束后删除。
  Future<void> interactiveRebaseOnto(
    GitRepository repository, {
    required String objectId,
    required List<GitInteractiveRebaseInstruction> instructions,
    GitCancellationToken? cancellationToken,
  }) async {
    final normalizedId = _requireCommitId(objectId);
    if (instructions.isEmpty) {
      throw ArgumentError.value(
        instructions,
        'instructions',
        'At least one commit is required.',
      );
    }
    final todoLines = <String>[];
    final seen = <String>{};
    for (final instruction in instructions) {
      final id = _requireCommitId(instruction.objectId);
      if (!seen.add(id)) {
        throw ArgumentError.value(
          instructions,
          'instructions',
          'Each commit may appear once.',
        );
      }
      if (instruction.action == GitInteractiveRebaseAction.reword) {
        throw UnsupportedError(
          'Interactive rebase reword requires the in-app commit-message editor.',
        );
      }
      final action = switch (instruction.action) {
        GitInteractiveRebaseAction.pick => 'pick',
        GitInteractiveRebaseAction.reword => throw StateError('unreachable'),
        GitInteractiveRebaseAction.edit => 'edit',
        GitInteractiveRebaseAction.squash => 'squash',
        GitInteractiveRebaseAction.fixup => 'fixup',
        GitInteractiveRebaseAction.drop => 'drop',
      };
      todoLines.add(
        '$action $id ${instruction.subject.replaceAll(RegExp(r'[\r\n]+'), ' ')}',
      );
    }
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'git-desktop-rebase-',
    );
    final todoFile = File(path_utils.join(temporaryDirectory.path, 'todo'));
    try {
      await todoFile.writeAsString('${todoLines.join('\n')}\n', flush: true);
      final escapedTodoPath = todoFile.path.replaceAll("'", "'\\''");
      await _runRebaseCommand(
        repository,
        ['--interactive', normalizedId],
        operation: 'Starting interactive rebase',
        cancellationToken: cancellationToken,
        environment: {'GIT_SEQUENCE_EDITOR': "/bin/cp '$escapedTodoPath'"},
      );
    } finally {
      try {
        await temporaryDirectory.delete(recursive: true);
      } on FileSystemException {
        // A stale temp todo has no repository effect and will be cleaned by
        // the operating system later.
      }
    }
  }

  /// Moves the current branch to [objectId] using the explicitly chosen reset
  /// mode. `hard` may discard tracked working-tree changes and requires UI
  /// confirmation before this method is called.
  /// 中文：按用户明确选择的模式将当前分支重置到指定提交；hard 会丢弃已跟踪改动，必须先确认。
  Future<void> resetToCommit(
    GitRepository repository, {
    required String objectId,
    required GitResetMode mode,
    GitCancellationToken? cancellationToken,
  }) async {
    final normalizedId = _requireCommitId(objectId);
    final flag = switch (mode) {
      GitResetMode.soft => '--soft',
      GitResetMode.mixed => '--mixed',
      GitResetMode.hard => '--hard',
    };
    final result = await runner.run(
      GitInvocation(
        arguments: ['--no-pager', 'reset', flag, normalizedId],
        workingDirectory: repository.commandDirectory,
        cancellationToken: cancellationToken,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 512 * 1024,
          stderrBytes: 512 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Resetting current branch');
  }

  /// Creates a new inverse commit for [objectId]. Conflicts remain in the
  /// repository for the normal Git continue/abort recovery workflow.
  /// 中文：为指定提交创建反向提交；若发生冲突，保留 Git 的正常继续/中止恢复状态。
  Future<void> revertCommit(
    GitRepository repository, {
    required String objectId,
    int? mainlineParent,
    GitCancellationToken? cancellationToken,
  }) async {
    final normalizedId = _requireCommitId(objectId);
    if (mainlineParent != null && mainlineParent <= 0) {
      throw ArgumentError.value(
        mainlineParent,
        'mainlineParent',
        'Must be positive.',
      );
    }
    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          'revert',
          '--no-edit',
          if (mainlineParent != null) ...['-m', '$mainlineParent'],
          normalizedId,
        ],
        workingDirectory: repository.commandDirectory,
        cancellationToken: cancellationToken,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 1024 * 1024,
          stderrBytes: 1024 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Reverting commit');
  }

  /// Applies [objectId] to the current branch and records its origin with
  /// `-x`. Conflicts are deliberately left for Git's continue/abort workflow.
  /// 中文：以 `-x` 将指定提交遴选到当前分支；冲突保留给 Git 的继续/中止流程处理。
  Future<void> cherryPickCommit(
    GitRepository repository, {
    required String objectId,
    int? mainlineParent,
    GitCancellationToken? cancellationToken,
  }) async {
    final normalizedId = _requireCommitId(objectId);
    if (mainlineParent != null && mainlineParent <= 0) {
      throw ArgumentError.value(
        mainlineParent,
        'mainlineParent',
        'Must be positive.',
      );
    }
    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          'cherry-pick',
          '-x',
          if (mainlineParent != null) ...['-m', '$mainlineParent'],
          normalizedId,
        ],
        workingDirectory: repository.commandDirectory,
        cancellationToken: cancellationToken,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 1024 * 1024,
          stderrBytes: 1024 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Cherry-picking commit');
  }

  /// Continues a paused cherry-pick after conflict resolutions are staged.
  /// 中文：在暂存冲突解决结果后继续暂停的遴选。
  Future<void> continueCherryPick(
    GitRepository repository, {
    GitCancellationToken? cancellationToken,
  }) => _runSequencerCommand(
    repository,
    command: 'cherry-pick',
    argument: '--continue',
    operation: 'Continuing cherry-pick',
    cancellationToken: cancellationToken,
  );

  /// Aborts a paused cherry-pick and restores its pre-pick branch state.
  /// 中文：中止暂停的遴选并恢复遴选前的分支状态。
  Future<void> abortCherryPick(
    GitRepository repository, {
    GitCancellationToken? cancellationToken,
  }) => _runSequencerCommand(
    repository,
    command: 'cherry-pick',
    argument: '--abort',
    operation: 'Aborting cherry-pick',
    cancellationToken: cancellationToken,
  );

  /// Continues a paused revert after conflict resolutions are staged.
  /// 中文：在暂存冲突解决结果后继续暂停的回滚。
  Future<void> continueRevert(
    GitRepository repository, {
    GitCancellationToken? cancellationToken,
  }) => _runSequencerCommand(
    repository,
    command: 'revert',
    argument: '--continue',
    operation: 'Continuing revert',
    cancellationToken: cancellationToken,
  );

  /// Aborts a paused revert and restores its pre-revert branch state.
  /// 中文：中止暂停的回滚并恢复回滚前的分支状态。
  Future<void> abortRevert(
    GitRepository repository, {
    GitCancellationToken? cancellationToken,
  }) => _runSequencerCommand(
    repository,
    command: 'revert',
    argument: '--abort',
    operation: 'Aborting revert',
    cancellationToken: cancellationToken,
  );

  Future<void> _runSequencerCommand(
    GitRepository repository, {
    required String command,
    required String argument,
    required String operation,
    GitCancellationToken? cancellationToken,
  }) async {
    final result = await runner.run(
      GitInvocation(
        arguments: ['--no-pager', command, argument],
        workingDirectory: repository.commandDirectory,
        cancellationToken: cancellationToken,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 1024 * 1024,
          stderrBytes: 1024 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: operation);
  }

  /// Writes one binary-safe mail patch for [objectId] to [outputPath]. The
  /// destination is selected by the user and must not already be a directory.
  /// 中文：为指定提交写出一个支持二进制内容的邮件补丁；目标路径由用户选择，不能是目录。
  Future<void> createPatch(
    GitRepository repository, {
    required String objectId,
    required String outputPath,
    GitCancellationToken? cancellationToken,
  }) => createPatches(
    repository,
    objectIds: [objectId],
    outputPath: outputPath,
    createSeparateFiles: false,
    cancellationToken: cancellationToken,
  );

  /// Writes selected commits to one combined mail patch, or one patch per
  /// commit below an existing output directory. Existing files are never
  /// overwritten, so a failed or repeated export cannot destroy a patch.
  /// 中文：把选中的提交写入一个合并邮件补丁，或写成输出目录中的独立文件；绝不覆盖已有补丁文件。
  Future<void> createPatches(
    GitRepository repository, {
    required List<String> objectIds,
    required String outputPath,
    required bool createSeparateFiles,
    GitCancellationToken? cancellationToken,
  }) async {
    final normalizedIds = objectIds
        .map(_requireCommitId)
        .toList(growable: false);
    if (normalizedIds.isEmpty ||
        normalizedIds.toSet().length != normalizedIds.length) {
      throw ArgumentError.value(
        objectIds,
        'objectIds',
        'At least one unique commit is required.',
      );
    }
    final target = outputPath.trim();
    if (target.isEmpty) {
      throw ArgumentError.value(
        outputPath,
        'outputPath',
        'An output file is required.',
      );
    }
    final type = await FileSystemEntity.type(target, followLinks: false);
    if (createSeparateFiles) {
      if (type != FileSystemEntityType.directory) {
        throw ArgumentError.value(
          outputPath,
          'outputPath',
          'A destination directory is required for separate patch files.',
        );
      }
      await _createSeparatePatches(
        repository,
        objectIds: normalizedIds,
        outputDirectory: Directory(target),
        cancellationToken: cancellationToken,
      );
      return;
    }
    if (type == FileSystemEntityType.directory ||
        type == FileSystemEntityType.link) {
      throw ArgumentError.value(
        outputPath,
        'outputPath',
        'The patch destination must be a regular file.',
      );
    }
    if (type == FileSystemEntityType.file) {
      throw ArgumentError.value(
        outputPath,
        'outputPath',
        'The patch destination already exists.',
      );
    }
    final parent = Directory(path_utils.dirname(target));
    if (!await parent.exists()) {
      throw ArgumentError.value(
        outputPath,
        'outputPath',
        'The patch destination directory does not exist.',
      );
    }
    final pinnedDirectory = Platform.isMacOS
        ? _MacOsPinnedDirectory.open(parent.path)
        : null;
    final bytes = BytesBuilder(copy: false);
    try {
      for (final objectId in normalizedIds) {
        final patch = await _renderPatch(
          repository,
          objectId: objectId,
          cancellationToken: cancellationToken,
        );
        bytes.add(patch);
        if (patch.isNotEmpty && patch.last != 10) bytes.addByte(10);
      }
      if (pinnedDirectory != null) {
        pinnedDirectory.createExclusive(
          path_utils.basename(target),
          bytes.takeBytes(),
        );
        return;
      }
      await _writePatchAtomically(
        parent,
        path_utils.basename(target),
        bytes.takeBytes(),
      );
    } finally {
      pinnedDirectory?.close();
    }
  }

  Future<List<int>> _renderPatch(
    GitRepository repository, {
    required String objectId,
    GitCancellationToken? cancellationToken,
  }) async {
    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          'format-patch',
          '--binary',
          '--stdout',
          '-1',
          objectId,
        ],
        workingDirectory: repository.commandDirectory,
        cancellationToken: cancellationToken,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 16 * 1024 * 1024,
          stderrBytes: 1024 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Creating patch');
    if (result.stdoutTruncated) {
      throw const GitException(
        'The generated patch exceeds the supported 16 MB limit.',
      );
    }
    return result.stdoutBytes;
  }

  Future<void> _createSeparatePatches(
    GitRepository repository, {
    required List<String> objectIds,
    required Directory outputDirectory,
    GitCancellationToken? cancellationToken,
  }) async {
    final pinnedDirectory = Platform.isMacOS
        ? _MacOsPinnedDirectory.open(outputDirectory.path)
        : null;
    try {
      final fileNames = [
        for (var index = 0; index < objectIds.length; index++)
          '${(index + 1).toString().padLeft(4, '0')}-${objectIds[index].substring(0, 12)}.patch',
      ];
      for (final name in fileNames) {
        if (await FileSystemEntity.type(
              path_utils.join(outputDirectory.path, name),
              followLinks: false,
            ) !=
            FileSystemEntityType.notFound) {
          throw ArgumentError.value(
            outputDirectory.path,
            'outputPath',
            'A patch file named $name already exists.',
          );
        }
      }
      final generated = <List<int>>[];
      for (final objectId in objectIds) {
        generated.add(
          await _renderPatch(
            repository,
            objectId: objectId,
            cancellationToken: cancellationToken,
          ),
        );
      }
      if (pinnedDirectory != null) {
        for (var index = 0; index < fileNames.length; index++) {
          pinnedDirectory.createExclusive(fileNames[index], generated[index]);
        }
        return;
      }
      final temporaryDirectory = await outputDirectory.createTemp(
        '.git-desktop-patches.',
      );
      try {
        for (var index = 0; index < fileNames.length; index++) {
          await File(
            path_utils.join(temporaryDirectory.path, fileNames[index]),
          ).writeAsBytes(generated[index], flush: true);
        }
        for (final name in fileNames) {
          await _movePatchIfDestinationAbsent(
            File(path_utils.join(temporaryDirectory.path, name)),
            path_utils.join(outputDirectory.path, name),
          );
        }
      } finally {
        if (await temporaryDirectory.exists()) {
          try {
            await temporaryDirectory.delete(recursive: true);
          } on FileSystemException {
            // Do not mask the original export failure with cleanup noise.
          }
        }
      }
    } finally {
      pinnedDirectory?.close();
    }
  }

  Future<void> _writePatchAtomically(
    Directory parent,
    String fileName,
    List<int> bytes,
  ) async {
    final temporaryDirectory = await parent.createTemp('.$fileName.');
    final temporaryFile = File(
      path_utils.join(temporaryDirectory.path, 'patch'),
    );
    final target = path_utils.join(parent.path, fileName);
    try {
      await temporaryFile.writeAsBytes(bytes, flush: true);
      await _movePatchIfDestinationAbsent(temporaryFile, target);
    } finally {
      if (await temporaryFile.exists()) {
        try {
          await temporaryFile.delete();
        } on FileSystemException {
          // Do not mask the original export failure with cleanup noise.
        }
      }
      if (await temporaryDirectory.exists()) {
        try {
          await temporaryDirectory.delete(recursive: true);
        } on FileSystemException {
          // Do not mask the original export failure with cleanup noise.
        }
      }
    }
  }

  /// Publishes one completed temporary patch through an exclusive destination
  /// create, so a concurrent file can never be replaced.
  /// 中文：通过排他创建目标文件发布临时补丁，绝不替换并发创建的同名文件。
  Future<void> _movePatchIfDestinationAbsent(
    File source,
    String targetPath,
  ) async {
    final linkResult = await Process.run('/bin/ln', <String>[
      '--',
      source.path,
      targetPath,
    ]);
    if (linkResult.exitCode != 0) {
      throw ArgumentError.value(
        targetPath,
        'outputPath',
        'The patch destination already exists.',
      );
    }
  }

  /// 中文：拒绝会把 HTTP(S) 凭据或签名查询串暴露到 Git 参数与远端配置的克隆地址。
  ///
  /// English: Rejects clone URLs that would expose HTTP(S) credentials or
  /// signed query data through Git arguments and persisted remote config.
  String _requireCredentialFreeCloneUrl(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      throw const GitException('A clone URL is required.');
    }
    if (RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*::').hasMatch(normalized)) {
      throw const GitException(
        'Git remote-helper clone URLs are not supported.',
      );
    }
    final uri = Uri.tryParse(normalized);
    if (uri == null &&
        RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*:').hasMatch(normalized)) {
      throw const GitException('The clone URL is invalid.');
    }
    if (uri != null && uri.hasScheme) {
      final scheme = uri.scheme.toLowerCase();
      final isWindowsDrivePath = RegExp(
        r'^[A-Za-z]:[\\/]',
      ).hasMatch(normalized);
      if (!isWindowsDrivePath &&
          !const {
            'file',
            'ftp',
            'ftps',
            'git',
            'http',
            'https',
            'ssh',
          }.contains(scheme)) {
        throw const GitException('The clone URL scheme is not supported.');
      }
      final String decodedUserInfo;
      try {
        decodedUserInfo = Uri.decodeComponent(uri.userInfo);
      } on FormatException {
        throw const GitException('The clone URL is invalid.');
      }
      final passwordBearingUserInfo = decodedUserInfo.contains(':');
      final curlCredentialUserInfo =
          const {'http', 'https', 'ftp', 'ftps'}.contains(scheme) &&
          uri.userInfo.isNotEmpty;
      if (passwordBearingUserInfo ||
          curlCredentialUserInfo ||
          uri.hasQuery ||
          uri.hasFragment) {
        throw const GitException(
          'Clone URLs must not contain embedded credentials or query data. '
          'Enter credentials through the protected prompt instead.',
        );
      }
    }
    final scpCredential = RegExp(
      r'^[^/@\s:]+:[^/@\s]+@[^/:\s]+:',
    ).hasMatch(normalized);
    if (scpCredential) {
      throw const GitException(
        'Clone URLs must not contain embedded credentials. '
        'Enter credentials through the protected prompt instead.',
      );
    }
    return normalized;
  }

  /// Applies a user-selected patch to the work tree, or checks whether it can
  /// apply when [checkOnly] is true. Git remains the source of conflict data.
  /// 中文：将用户选择的补丁应用到工作区；[checkOnly] 为真时仅检查是否可应用，冲突状态仍由 Git 提供。
  Future<void> applyPatch(
    GitRepository repository, {
    required String patchPath,
    int? stripLevel,
    String basePath = '',
    bool checkOnly = false,
    GitCancellationToken? cancellationToken,
  }) async {
    final normalizedPath = patchPath.trim();
    if (normalizedPath.isEmpty || (stripLevel != null && stripLevel < 0)) {
      throw ArgumentError(
        'A patch path and non-negative strip level are required.',
      );
    }
    final type = await FileSystemEntity.type(
      normalizedPath,
      followLinks: false,
    );
    if (type != FileSystemEntityType.file) {
      throw ArgumentError.value(
        patchPath,
        'patchPath',
        'The patch must be a regular file.',
      );
    }
    final normalizedBasePath = basePath.trim();
    if (normalizedBasePath.startsWith('-') ||
        normalizedBasePath.contains('\u0000')) {
      throw ArgumentError.value(
        basePath,
        'basePath',
        'The base path is invalid.',
      );
    }
    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          'apply',
          if (checkOnly) '--check',
          if (stripLevel != null) '-p$stripLevel',
          if (normalizedBasePath.isNotEmpty) '--directory=$normalizedBasePath',
          '--',
          normalizedPath,
        ],
        workingDirectory: repository.commandDirectory,
        cancellationToken: cancellationToken,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 1024 * 1024,
          stderrBytes: 1024 * 1024,
        ),
      ),
    );
    result.throwIfFailed(
      operation: checkOnly ? 'Checking patch' : 'Applying patch',
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

  /// 中文：将当前或指定本地分支推送到已配置上游；首次推送时使用 origin 上的同名分支并设置上游。始终不提供 force 选项。
  ///
  /// English: Pushes the checked-out or explicitly named local branch to its
  /// configured upstream, or sets origin's same-named branch as upstream on
  /// first push. No force option is ever supplied.
  Future<void> pushUpstream(
    GitRepository repository, {
    String? localBranchName,
    GitCancellationToken? cancellationToken,
    Map<String, String> environment = const {},
  }) async {
    final target = await _readPushTarget(
      repository,
      localBranchName: localBranchName,
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

  /// 中文：将用户明确勾选的本地分支推送到一个已配置远端，可选同时推送全部标签；从不使用强制推送。
  ///
  /// English: Pushes explicitly selected local branches to one configured
  /// remote, optionally including all tags. It never supplies force push.
  Future<void> pushBranches(
    GitRepository repository, {
    required GitPushOptions options,
    GitCancellationToken? cancellationToken,
    Map<String, String> environment = const {},
  }) async {
    final remoteName = options.remoteName.trim();
    if (!_isSafeRemoteName(remoteName)) {
      throw ArgumentError.value(
        options.remoteName,
        'options.remoteName',
        'A configured remote name is required.',
      );
    }
    if (options.branches.isEmpty && !options.pushTags) {
      throw ArgumentError.value(
        options,
        'options',
        'Select at least one branch or push tags.',
      );
    }
    final refspecs = <String>[];
    final seenLocalBranches = <String>{};
    for (final branch in options.branches) {
      final local = branch.localBranch.trim();
      final remote = branch.remoteBranch.trim();
      if (!_isSafeBranchName(local) || !_isSafeBranchName(remote)) {
        throw ArgumentError.value(
          branch,
          'options.branches',
          'Valid local and remote branch names are required.',
        );
      }
      if (!seenLocalBranches.add(local)) {
        throw ArgumentError.value(
          branch,
          'options.branches',
          'Each local branch can be pushed only once.',
        );
      }
      refspecs.add('refs/heads/$local:refs/heads/$remote');
    }
    final result = await runner.run(
      GitInvocation(
        arguments: [
          '--no-pager',
          'push',
          '--porcelain',
          if (options.pushTags) '--tags',
          '--',
          remoteName,
          ...refspecs,
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
    result.throwIfFailed(operation: 'Pushing selected branches');
    for (final branch in options.branches.where(
      (branch) => branch.trackRemote,
    )) {
      await _setBranchTracking(
        repository,
        localBranch: branch.localBranch.trim(),
        remoteName: remoteName,
        remoteBranch: branch.remoteBranch.trim(),
        cancellationToken: cancellationToken,
      );
    }
  }

  /// 中文：通过单条 Git 分支命令为已成功推送的分支写入上游跟踪配置，不留下半配置状态。
  ///
  /// English: Records upstream tracking with one Git branch command, avoiding
  /// a half-written remote/merge pair without moving the work tree.
  Future<void> _setBranchTracking(
    GitRepository repository, {
    required String localBranch,
    required String remoteName,
    required String remoteBranch,
    GitCancellationToken? cancellationToken,
  }) async {
    final result = await runner.run(
      GitInvocation(
        arguments: [
          'branch',
          '--set-upstream-to=refs/remotes/$remoteName/$remoteBranch',
          '--',
          localBranch,
        ],
        workingDirectory: repository.commandDirectory,
        cancellationToken: cancellationToken,
        outputLimit: const GitOutputLimit(
          stdoutBytes: 256 * 1024,
          stderrBytes: 256 * 1024,
        ),
      ),
    );
    result.throwIfFailed(operation: 'Setting branch upstream');
  }

  /// 中文：判断远端名称是否能安全作为 Git 的字面参数使用。
  /// English: Checks whether a remote name is safe as a literal Git argument.
  bool _isSafeRemoteName(String value) =>
      value.isNotEmpty &&
      !value.startsWith('-') &&
      !value.contains(RegExp(r'[\x00\s]'));

  /// 中文：判断短分支名称是否可安全转换为 heads 引用。
  /// English: Checks whether a short branch name can safely form a heads ref.
  bool _isSafeBranchName(String value) =>
      value.isNotEmpty &&
      !value.startsWith('-') &&
      !value.startsWith('/') &&
      !value.endsWith('/') &&
      !value.endsWith('.') &&
      !value.contains('..') &&
      !value.contains('//') &&
      !value.contains(RegExp(r'[\x00\s~^:?*\[\\]'));

  /// 中文：判断短标签名是否可安全转换为 tags 引用。
  /// English: Checks whether a short tag name can safely form a tags ref.
  bool _isSafeTagName(String value) => _isSafeBranchName(value);

  /// Verifies whether the configured upstream currently contains the checked
  /// out HEAD or the explicitly selected local branch tip.
  ///
  /// This is read-only and deliberately does not update remote-tracking refs;
  /// callers can use Fetch when they need the local ahead/behind snapshot to
  /// catch up as well.
  /// 中文：验证当前条件。
  /// English: Verifies the current condition.
  Future<bool> verifyUpstream(
    GitRepository repository, {
    String? localBranchName,
    GitCancellationToken? cancellationToken,
  }) async {
    final target = await _readPushTarget(
      repository,
      localBranchName: localBranchName,
      cancellationToken: cancellationToken,
    );
    final headResult = await runner.run(
      GitInvocation(
        arguments: [
          'rev-parse',
          '--verify',
          localBranchName == null ? 'HEAD' : 'refs/heads/$localBranchName',
        ],
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
    String? localBranchName,
    GitCancellationToken? cancellationToken,
  }) async {
    final branchName =
        localBranchName ??
        await _readCheckedOutBranchName(
          repository,
          cancellationToken: cancellationToken,
        );
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
        refspec:
            '${localBranchName == null ? 'HEAD' : 'refs/heads/$branchName'}:$remoteRef',
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
      refspec:
          '${localBranchName == null ? 'HEAD' : 'refs/heads/$branchName'}:$remoteRef',
      setUpstream: false,
    );
  }

  /// 中文：读取当前检出的本地分支；游离 HEAD 没有可用结果。
  /// English: Reads the checked-out local branch; detached HEAD has no result.
  Future<String> _readCheckedOutBranchName(
    GitRepository repository, {
    GitCancellationToken? cancellationToken,
  }) async {
    final result = await runner.run(
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
    result.throwIfFailed(operation: 'Reading current branch');
    final branchName = result.stdoutText.trim();
    if (branchName.isEmpty) {
      throw const GitException('The current branch has no push target.');
    }
    return branchName;
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

  String _requireCommitId(String value) {
    final normalized = value.trim();
    if (!RegExp(r'^[0-9a-fA-F]{7,64}$').hasMatch(normalized)) {
      throw ArgumentError.value(
        value,
        'objectId',
        'A valid commit id is required.',
      );
    }
    return normalized;
  }
}

/// Uses directory-relative macOS syscalls to durably prepare a sibling file,
/// reject a detected target replacement, and atomically publish complete data.
final class _MacOsAtomicFileWriter {
  static final ffi.DynamicLibrary _libc = ffi.DynamicLibrary.process();
  static final _open = _libc
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Uint8>, ffi.Int32),
        int Function(ffi.Pointer<ffi.Uint8>, int)
      >('open');
  static final ffi.Pointer<ffi.NativeFunction<ffi.Int32 Function()>>
  _openAtSymbol = _libc.lookup('openat');
  static final int Function(int, ffi.Pointer<ffi.Uint8>, int) _openAtExisting =
      _openAtSymbol
          .cast<
            ffi.NativeFunction<
              ffi.Int32 Function(
                ffi.Int32,
                ffi.Pointer<ffi.Uint8>,
                ffi.Int32,
                ffi.VarArgs<()>,
              )
            >
          >()
          .asFunction();
  static final int Function(int, ffi.Pointer<ffi.Uint8>, int, int)
  _openAtCreate = _openAtSymbol
      .cast<
        ffi.NativeFunction<
          ffi.Int32 Function(
            ffi.Int32,
            ffi.Pointer<ffi.Uint8>,
            ffi.Int32,
            ffi.VarArgs<(ffi.Int32,)>,
          )
        >
      >()
      .asFunction();
  static final _write = _libc
      .lookupFunction<
        ffi.IntPtr Function(ffi.Int32, ffi.Pointer<ffi.Uint8>, ffi.IntPtr),
        int Function(int, ffi.Pointer<ffi.Uint8>, int)
      >('write');
  static final _fsync = _libc
      .lookupFunction<ffi.Int32 Function(ffi.Int32), int Function(int)>(
        'fsync',
      );
  static final _fchmod = _libc
      .lookupFunction<
        ffi.Int32 Function(ffi.Int32, ffi.Uint16),
        int Function(int, int)
      >('fchmod');
  static final _fstat = _libc
      .lookupFunction<
        ffi.Int32 Function(ffi.Int32, ffi.Pointer<ffi.Void>),
        int Function(int, ffi.Pointer<ffi.Void>)
      >('fstat');
  static final _linkAt = _libc
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Int32,
          ffi.Pointer<ffi.Uint8>,
          ffi.Int32,
          ffi.Pointer<ffi.Uint8>,
          ffi.Int32,
        ),
        int Function(
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
        )
      >('linkat');
  static final _renameAt = _libc
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Int32,
          ffi.Pointer<ffi.Uint8>,
          ffi.Int32,
          ffi.Pointer<ffi.Uint8>,
        ),
        int Function(int, ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Uint8>)
      >('renameat');
  static final _unlinkAt = _libc
      .lookupFunction<
        ffi.Int32 Function(ffi.Int32, ffi.Pointer<ffi.Uint8>, ffi.Int32),
        int Function(int, ffi.Pointer<ffi.Uint8>, int)
      >('unlinkat');
  static final _close = _libc
      .lookupFunction<ffi.Int32 Function(ffi.Int32), int Function(int)>(
        'close',
      );
  static final _malloc = _libc
      .lookupFunction<
        ffi.Pointer<ffi.Void> Function(ffi.IntPtr),
        ffi.Pointer<ffi.Void> Function(int)
      >('malloc');
  static final _free = _libc
      .lookupFunction<
        ffi.Void Function(ffi.Pointer<ffi.Void>),
        void Function(ffi.Pointer<ffi.Void>)
      >('free');
  static final _errnoLocation = _libc
      .lookupFunction<
        ffi.Pointer<ffi.Int32> Function(),
        ffi.Pointer<ffi.Int32> Function()
      >('__error');

  static const _oReadOnly = 0x00000000;
  static const _oWriteOnly = 0x00000001;
  static const _oNonBlock = 0x00000004;
  static const _oCreate = 0x00000200;
  static const _oExclusive = 0x00000800;
  static const _oNoFollow = 0x00000100;
  static const _oDirectory = 0x00100000;
  static const _oCloseOnExec = 0x01000000;

  /// 中文：固定父目录，完整写入同目录临时文件，复核目标身份后原子发布。
  ///
  /// English: Pins the parent, fully writes a sibling temporary file, then
  /// revalidates the target identity immediately before atomic publication.
  static Future<void> replace({
    required String directoryPath,
    required String fileName,
    required List<int> bytes,
    FutureOr<void> Function()? beforePublicationForTesting,
  }) async {
    if (!Platform.isMacOS || fileName.isEmpty || fileName.contains('/')) {
      throw const GitException('The conflict destination is invalid.');
    }
    ffi.Pointer<ffi.Uint8>? directoryPointer;
    ffi.Pointer<ffi.Uint8>? temporaryPointer;
    ffi.Pointer<ffi.Uint8>? targetPointer;
    var directoryFd = -1;
    var temporaryFd = -1;
    var targetFd = -1;
    var targetOriginallyExisted = false;
    var published = false;
    try {
      directoryPointer = _nativeString(directoryPath);
      directoryFd = _open(
        directoryPointer,
        _oDirectory | _oNoFollow | _oCloseOnExec,
      );
      _free(directoryPointer.cast());
      directoryPointer = null;
      if (directoryFd < 0) {
        throw const GitException(
          'The conflict destination directory could not be secured.',
        );
      }

      temporaryPointer = _nativeString(_temporaryName());
      targetPointer = _nativeString(fileName);
      targetFd = _openAtExisting(
        directoryFd,
        targetPointer,
        _oReadOnly | _oNonBlock | _oNoFollow | _oCloseOnExec,
      );
      int? existingMode;
      if (targetFd >= 0) {
        targetOriginallyExisted = true;
        final status = _malloc(256);
        if (status.address == 0) {
          throw const GitException(
            'Memory for conflict metadata is unavailable.',
          );
        }
        int targetMode;
        try {
          if (_fstat(targetFd, status) != 0) {
            throw const GitException(
              'The conflict destination metadata could not be read.',
            );
          }
          targetMode = (status.cast<ffi.Uint8>() + 4).cast<ffi.Uint16>().value;
        } finally {
          _free(status);
        }
        if (targetMode & 0xf000 != 0x8000) {
          throw const GitException(
            'The conflicted path is not a regular file.',
          );
        }
        existingMode = targetMode & 0x1ff;
      } else if (_errnoLocation().value != 2) {
        throw const GitException(
          'The conflict destination could not be inspected safely.',
        );
      }

      temporaryFd = _openAtCreate(
        directoryFd,
        temporaryPointer,
        _oWriteOnly | _oCreate | _oExclusive | _oNoFollow | _oCloseOnExec,
        0x1b6,
      );
      if (temporaryFd < 0) {
        throw const GitException(
          'A private conflict-result file could not be created.',
        );
      }
      if (existingMode != null && _fchmod(temporaryFd, existingMode) != 0) {
        throw const GitException(
          'The conflict-result permissions could not be secured.',
        );
      }
      _writeAll(temporaryFd, bytes);
      if (_fsync(temporaryFd) != 0) {
        throw const GitException('The conflict result could not be flushed.');
      }
      _close(temporaryFd);
      temporaryFd = -1;

      await beforePublicationForTesting?.call();
      final currentFd = _openAtExisting(
        directoryFd,
        targetPointer,
        _oReadOnly | _oNonBlock | _oNoFollow | _oCloseOnExec,
      );
      if (targetOriginallyExisted) {
        if (currentFd < 0) {
          throw const GitException(
            'The conflict destination changed while it was being saved.',
          );
        }
        try {
          if (!_sameFile(targetFd, currentFd)) {
            throw const GitException(
              'The conflict destination changed while it was being saved.',
            );
          }
        } finally {
          _close(currentFd);
        }
      } else {
        if (currentFd >= 0) {
          _close(currentFd);
          throw const GitException(
            'The conflict destination changed while it was being saved.',
          );
        }
        if (_errnoLocation().value != 2) {
          throw const GitException(
            'The conflict destination could not be revalidated safely.',
          );
        }
      }
      if (_renameAt(
            directoryFd,
            temporaryPointer,
            directoryFd,
            targetPointer,
          ) !=
          0) {
        throw const GitException(
          'The conflict result could not be published safely.',
        );
      }
      published = true;
      _fsync(directoryFd);
    } finally {
      if (targetFd >= 0) _close(targetFd);
      if (temporaryFd >= 0) _close(temporaryFd);
      if (!published && directoryFd >= 0 && temporaryPointer != null) {
        _unlinkAt(directoryFd, temporaryPointer, 0);
      }
      if (directoryPointer != null) _free(directoryPointer.cast());
      if (temporaryPointer != null) _free(temporaryPointer.cast());
      if (targetPointer != null) _free(targetPointer.cast());
      if (directoryFd >= 0) _close(directoryFd);
    }
  }

  /// Compares stable Darwin device and inode fields for two open descriptors.
  /// 中文：比较两个已打开描述符的 Darwin 设备号和 inode，确认路径仍指向原对象。
  static bool _sameFile(int firstFd, int secondFd) {
    final first = _malloc(256);
    final second = _malloc(256);
    if (first.address == 0 || second.address == 0) {
      if (first.address != 0) _free(first);
      if (second.address != 0) _free(second);
      throw const GitException('File identity memory is unavailable.');
    }
    try {
      if (_fstat(firstFd, first) != 0 || _fstat(secondFd, second) != 0) {
        throw const GitException('File identity could not be verified.');
      }
      final firstBytes = first.cast<ffi.Uint8>();
      final secondBytes = second.cast<ffi.Uint8>();
      return firstBytes.cast<ffi.Uint32>().value ==
              secondBytes.cast<ffi.Uint32>().value &&
          (firstBytes + 8).cast<ffi.Uint64>().value ==
              (secondBytes + 8).cast<ffi.Uint64>().value;
    } finally {
      _free(first);
      _free(second);
    }
  }

  /// 中文：把全部字节写入已排他创建的文件描述符，短写或错误时立即拒绝发布。
  ///
  /// English: Writes every byte to an exclusively created descriptor and
  /// rejects publication immediately on a short write or error.
  static void _writeAll(int fileDescriptor, List<int> bytes) {
    if (bytes.isEmpty) return;
    final pointer = _malloc(bytes.length).cast<ffi.Uint8>();
    if (pointer.address == 0) {
      throw const GitException(
        'Memory for the conflict result is unavailable.',
      );
    }
    try {
      pointer.asTypedList(bytes.length).setAll(0, bytes);
      var offset = 0;
      while (offset < bytes.length) {
        final written = _write(
          fileDescriptor,
          pointer + offset,
          bytes.length - offset,
        );
        if (written <= 0) {
          throw const GitException('The conflict result could not be written.');
        }
        offset += written;
      }
    } finally {
      _free(pointer.cast());
    }
  }

  /// 中文：分配一个以 NUL 结尾的 UTF-8 C 字符串；调用方负责释放。
  ///
  /// English: Allocates a NUL-terminated UTF-8 C string that the caller owns.
  static ffi.Pointer<ffi.Uint8> _nativeString(String value) {
    final bytes = utf8.encode(value);
    final pointer = _malloc(bytes.length + 1).cast<ffi.Uint8>();
    if (pointer.address == 0) {
      throw const GitException('Native path memory is unavailable.');
    }
    final buffer = pointer.asTypedList(bytes.length + 1);
    buffer
      ..setAll(0, bytes)
      ..[bytes.length] = 0;
    return pointer;
  }

  /// 中文：生成不可预测的同目录临时文件名，配合 O_EXCL 防止名称复用。
  ///
  /// English: Generates an unpredictable sibling name whose reuse is rejected
  /// by `O_EXCL`.
  static String _temporaryName() {
    final random = Random.secure();
    final nonce = List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    return '.git-desktop-resolve.$nonce';
  }
}

/// Pins a macOS directory descriptor and publishes new regular files without
/// re-resolving the user-selected path or replacing an existing destination.
/// 中文：固定 macOS 目录描述符，并在不重新解析用户路径、不覆盖目标的前提下发布新文件。
final class _MacOsPinnedDirectory {
  _MacOsPinnedDirectory._(this._fileDescriptor);

  int _fileDescriptor;

  /// Opens and pins [path], rejecting a final symlink or non-directory.
  /// 中文：打开并固定 [path]；最终路径若为链接或非目录则失败关闭。
  static _MacOsPinnedDirectory open(String path) {
    if (!Platform.isMacOS) {
      throw const GitException('Pinned directories require macOS.');
    }
    final pointer = _MacOsAtomicFileWriter._nativeString(path);
    try {
      final descriptor = _MacOsAtomicFileWriter._open(
        pointer,
        _MacOsAtomicFileWriter._oReadOnly |
            _MacOsAtomicFileWriter._oDirectory |
            _MacOsAtomicFileWriter._oNoFollow |
            _MacOsAtomicFileWriter._oCloseOnExec,
      );
      if (descriptor < 0) {
        throw const GitException(
          'The patch destination directory could not be secured.',
        );
      }
      return _MacOsPinnedDirectory._(descriptor);
    } finally {
      _MacOsAtomicFileWriter._free(pointer.cast());
    }
  }

  /// Creates [fileName] exclusively and durably writes [bytes].
  /// 中文：排他创建 [fileName] 并持久写入 [bytes]，同名目标存在时绝不覆盖。
  void createExclusive(String fileName, List<int> bytes) {
    if (_fileDescriptor < 0 ||
        fileName.isEmpty ||
        fileName == '.' ||
        fileName == '..' ||
        fileName.contains('/')) {
      throw const GitException('The patch destination is invalid.');
    }
    final targetPointer = _MacOsAtomicFileWriter._nativeString(fileName);
    final temporaryPointer = _MacOsAtomicFileWriter._nativeString(
      _MacOsAtomicFileWriter._temporaryName(),
    );
    var temporaryFd = -1;
    try {
      temporaryFd = _MacOsAtomicFileWriter._openAtCreate(
        _fileDescriptor,
        temporaryPointer,
        _MacOsAtomicFileWriter._oWriteOnly |
            _MacOsAtomicFileWriter._oCreate |
            _MacOsAtomicFileWriter._oExclusive |
            _MacOsAtomicFileWriter._oNoFollow |
            _MacOsAtomicFileWriter._oCloseOnExec,
        0x180,
      );
      if (temporaryFd < 0) {
        throw const GitException('A private patch file could not be created.');
      }
      _MacOsAtomicFileWriter._writeAll(temporaryFd, bytes);
      if (_MacOsAtomicFileWriter._fsync(temporaryFd) != 0) {
        throw const GitException('The patch could not be flushed.');
      }
      _MacOsAtomicFileWriter._close(temporaryFd);
      temporaryFd = -1;
      if (_MacOsAtomicFileWriter._linkAt(
            _fileDescriptor,
            temporaryPointer,
            _fileDescriptor,
            targetPointer,
            0,
          ) !=
          0) {
        throw ArgumentError.value(
          fileName,
          'outputPath',
          'The patch destination already exists or cannot be created safely.',
        );
      }
      if (_MacOsAtomicFileWriter._fsync(_fileDescriptor) != 0) {
        throw const GitException(
          'The patch destination directory could not be flushed.',
        );
      }
    } finally {
      if (temporaryFd >= 0) _MacOsAtomicFileWriter._close(temporaryFd);
      _MacOsAtomicFileWriter._unlinkAt(_fileDescriptor, temporaryPointer, 0);
      _MacOsAtomicFileWriter._free(targetPointer.cast());
      _MacOsAtomicFileWriter._free(temporaryPointer.cast());
    }
  }

  /// Releases the pinned directory descriptor.
  /// 中文：释放已固定的目录描述符。
  void close() {
    if (_fileDescriptor < 0) return;
    _MacOsAtomicFileWriter._close(_fileDescriptor);
    _fileDescriptor = -1;
  }
}

/// Removes a leaf through a descriptor-pinned macOS directory chain.
/// 中文：通过描述符固定的 macOS 目录链删除叶节点，拒绝链接父目录和递归目录删除。
final class _MacOsSecureRemoval {
  static const _atRemoveDir = 0x80;

  /// Removes [relativePath] below [workTreeRoot], returning false when absent.
  /// 中文：删除 [workTreeRoot] 下的 [relativePath]；目标不存在时返回 false。
  static bool remove({
    required String workTreeRoot,
    required String relativePath,
  }) {
    final components = path_utils
        .split(path_utils.normalize(relativePath))
        .where((component) => component != '.')
        .toList(growable: false);
    if (components.isEmpty ||
        components.any((component) => component == '..')) {
      throw const GitException('The removal path is invalid.');
    }
    final rootPointer = _MacOsAtomicFileWriter._nativeString(workTreeRoot);
    var currentFd = -1;
    try {
      currentFd = _MacOsAtomicFileWriter._open(
        rootPointer,
        _MacOsAtomicFileWriter._oReadOnly |
            _MacOsAtomicFileWriter._oDirectory |
            _MacOsAtomicFileWriter._oNoFollow |
            _MacOsAtomicFileWriter._oCloseOnExec,
      );
      if (currentFd < 0) {
        throw const GitException('The work tree could not be secured.');
      }
      for (final component in components.take(components.length - 1)) {
        final pointer = _MacOsAtomicFileWriter._nativeString(component);
        try {
          final nextFd = _MacOsAtomicFileWriter._openAtExisting(
            currentFd,
            pointer,
            _MacOsAtomicFileWriter._oReadOnly |
                _MacOsAtomicFileWriter._oDirectory |
                _MacOsAtomicFileWriter._oNoFollow |
                _MacOsAtomicFileWriter._oCloseOnExec,
          );
          if (nextFd < 0) {
            throw const GitException(
              'A removal parent changed or is not a safe directory.',
            );
          }
          _MacOsAtomicFileWriter._close(currentFd);
          currentFd = nextFd;
        } finally {
          _MacOsAtomicFileWriter._free(pointer.cast());
        }
      }
      final leafPointer = _MacOsAtomicFileWriter._nativeString(components.last);
      try {
        final leafFd = _MacOsAtomicFileWriter._openAtExisting(
          currentFd,
          leafPointer,
          _MacOsAtomicFileWriter._oReadOnly |
              _MacOsAtomicFileWriter._oNonBlock |
              _MacOsAtomicFileWriter._oNoFollow |
              _MacOsAtomicFileWriter._oCloseOnExec,
        );
        if (leafFd >= 0) {
          _MacOsAtomicFileWriter._close(leafFd);
          if (_MacOsAtomicFileWriter._unlinkAt(currentFd, leafPointer, 0) !=
              0) {
            throw const GitException(
              'The work-tree file could not be removed.',
            );
          }
          return true;
        }
        final error = _MacOsAtomicFileWriter._errnoLocation().value;
        if (error == 2) return false;
        // ELOOP identifies a final symlink under O_NOFOLLOW. unlinkat removes
        // the link itself and never follows its destination.
        if (error == 62) {
          if (_MacOsAtomicFileWriter._unlinkAt(currentFd, leafPointer, 0) !=
              0) {
            throw const GitException(
              'The work-tree link could not be removed.',
            );
          }
          return true;
        }
        // Never recurse through an unpinned directory tree.
        if (_MacOsAtomicFileWriter._unlinkAt(
              currentFd,
              leafPointer,
              _atRemoveDir,
            ) ==
            0) {
          return true;
        }
        throw const GitException(
          'Safe recursive directory removal is unavailable.',
        );
      } finally {
        _MacOsAtomicFileWriter._free(leafPointer.cast());
      }
    } finally {
      _MacOsAtomicFileWriter._free(rootPointer.cast());
      if (currentFd >= 0) _MacOsAtomicFileWriter._close(currentFd);
    }
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

/// Returns a complete single-file patch containing exactly one unified hunk.
///
/// Git emits byte-oriented patches, so this deliberately never round-trips
/// through UTF-8. The caller has already limited the feature to text diffs;
/// retaining the original bytes prevents a displayed replacement character
/// from silently changing what `git apply` receives.
///
/// 中文：从 Git 原始字节 Diff 中提取只含指定区块的完整单文件补丁。该过程不做
/// UTF-8 往返转换，避免界面替换字符悄悄改变最终传给 `git apply` 的内容。
List<int> _singleHunkPatch(List<int> diff, int hunkIndex) {
  if (hunkIndex < 0) {
    throw RangeError.range(hunkIndex, 0, null, 'hunkIndex');
  }
  final hunkOffsets = <int>[];
  var hasOldPath = false;
  var hasNewPath = false;
  var lineStart = 0;
  for (var index = 0; index <= diff.length; index++) {
    if (index != diff.length && diff[index] != 10) continue;
    if (_patchLineStartsWith(diff, lineStart, index, const [64, 64, 32])) {
      hunkOffsets.add(lineStart);
    } else if (_patchLineStartsWith(diff, lineStart, index, const [
      45,
      45,
      45,
      32,
    ])) {
      hasOldPath = true;
    } else if (_patchLineStartsWith(diff, lineStart, index, const [
      43,
      43,
      43,
      32,
    ])) {
      hasNewPath = true;
    }
    lineStart = index + 1;
  }
  if (!hasOldPath || !hasNewPath || hunkIndex >= hunkOffsets.length) {
    throw ArgumentError.value(hunkIndex, 'hunkIndex', 'Unknown diff hunk.');
  }
  final hunkStart = hunkOffsets[hunkIndex];
  final hunkEnd = hunkIndex + 1 < hunkOffsets.length
      ? hunkOffsets[hunkIndex + 1]
      : diff.length;
  return List<int>.unmodifiable([
    ...diff.sublist(0, hunkStart),
    ...diff.sublist(hunkStart, hunkEnd),
  ]);
}

/// Checks whether one byte-delimited patch line starts with [prefix].
///
/// 中文：判断一个由字节边界确定的补丁行是否以 [prefix] 开头，不解码路径或内容。
bool _patchLineStartsWith(
  List<int> bytes,
  int start,
  int end,
  List<int> prefix,
) {
  if (end - start < prefix.length) return false;
  for (var offset = 0; offset < prefix.length; offset++) {
    if (bytes[start + offset] != prefix[offset]) return false;
  }
  return true;
}
