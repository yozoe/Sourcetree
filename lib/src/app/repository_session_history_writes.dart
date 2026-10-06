part of 'repository_session.dart';

/// History, patch and sequencer mutations owned by
/// [RepositorySessionController].
///
/// 中文：集中维护变基、回滚、遴选、重置、补丁和历史相关读取，保持 Git 操作、
/// 取消、冲突恢复与写后刷新语义。
extension RepositorySessionHistoryWrites on RepositorySessionController {
  /// Rebases the checked-out branch onto a loaded historical commit. A clean
  /// working tree is required because Git may replay multiple commits.
  /// 中文：将当前检出分支变基到已加载历史提交；因可能重放多个提交，要求工作区干净。
  Future<bool> rebaseOntoCommit(String objectId) => _trackBooleanGitTask(
    () => _runHistoryMutation(
      objectId: objectId,
      requireCleanWorkTree: true,
      successMessage: '已完成变基。',
      conflictMessage: '变基遇到冲突。请解决冲突并暂存后继续、跳过当前提交，或选择放弃变基。',
      run: (repository, cancellation) => _writer.rebaseOnto(
        repository,
        objectId: objectId,
        cancellationToken: cancellation,
      ),
    ),
  );

  /// Starts Git's interactive rebase for the commits after [objectId] while
  /// accepting Git's generated todo list unchanged instead of launching an
  /// external editor.
  /// 中文：对 [objectId] 之后的提交启动 Git 交互式变基；不启动外部编辑器，直接接受 Git 生成的 todo 列表。
  Future<bool> interactiveRebaseOntoCommit(
    String objectId, {
    required List<GitInteractiveRebaseInstruction> instructions,
  }) => _trackBooleanGitTask(
    () => _runHistoryMutation(
      objectId: objectId,
      requireCleanWorkTree: true,
      successMessage: '已完成交互式变基。',
      conflictMessage: '交互式变基遇到冲突。请解决冲突并暂存后继续、跳过当前提交，或选择放弃变基。',
      run: (repository, cancellation) => _writer.interactiveRebaseOnto(
        repository,
        objectId: objectId,
        cancellationToken: cancellation,
        instructions: instructions,
      ),
    ),
  );

  /// Reads the current branch commits that can be edited before interactive
  /// rebasing them onto [objectId].
  /// 中文：读取当前分支中可在交互式变基前编辑、并会重放到 [objectId] 之后的提交。
  Future<List<GitInteractiveRebaseInstruction>> readInteractiveRebaseTodo(
    String objectId,
  ) async {
    if (!_isInsideTrackedGitTask) {
      return await _trackGitTask<List<GitInteractiveRebaseInstruction>>(
            () => readInteractiveRebaseTodo(objectId),
          ) ??
          const [];
    }
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    final normalizedId = objectId.trim();
    if (repository == null ||
        status == null ||
        status.branch.head == null ||
        !status.isClean ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        _sessionState.operationState != GitRepositoryOperationState.none ||
        !_sessionState.historyCommits.any(
          (commit) => commit.objectId == normalizedId,
        )) {
      return const [];
    }
    return _reader.readInteractiveRebaseTodo(
      repository,
      upstreamObjectId: normalizedId,
    );
  }

  /// Resets the checked-out branch to a loaded commit using the confirmed
  /// mode. Hard reset approval is owned by the UI.
  /// 中文：按已确认的模式将当前分支重置到已加载提交；hard 重置的确认由 UI 负责。
  Future<bool> resetCurrentBranchToCommit(
    String objectId, {
    required GitResetMode mode,
  }) {
    if (_sessionState.status?.branch.isDetached != false) {
      return Future.value(false);
    }
    return _trackBooleanGitTask(
      () => _runHistoryMutation(
        objectId: objectId,
        requireCleanWorkTree: false,
        successMessage: '已重置当前分支。',
        run: (repository, cancellation) => _writer.resetToCommit(
          repository,
          objectId: objectId,
          mode: mode,
          cancellationToken: cancellation,
        ),
      ),
    );
  }

  /// Creates an inverse commit for one loaded historical commit. Conflicts
  /// stay in the repository for Git's normal recovery flow.
  /// 中文：为已加载的历史提交创建反向提交；冲突保留给 Git 的正常恢复流程。
  Future<bool> revertCommit(String objectId, {int? mainlineParent}) =>
      _trackBooleanGitTask(
        () => _runHistoryMutation(
          objectId: objectId,
          requireCleanWorkTree: true,
          successMessage: '已创建回滚提交。',
          conflictMessage: '回滚遇到冲突。请解决并暂存冲突后，从“动作”菜单继续或中止回滚。',
          run: (repository, cancellation) => _writer.revertCommit(
            repository,
            objectId: objectId,
            mainlineParent: mainlineParent,
            cancellationToken: cancellation,
          ),
        ),
      );

  /// Applies a loaded commit to the checked-out branch and records its source.
  /// 中文：将已加载提交遴选到当前分支，并记录来源提交。
  Future<bool> cherryPickCommit(String objectId, {int? mainlineParent}) =>
      _trackBooleanGitTask(
        () => _runHistoryMutation(
          objectId: objectId,
          requireCleanWorkTree: true,
          successMessage: '已遴选提交。',
          conflictMessage: '遴选遇到冲突。请解决并暂存冲突后，从“动作”菜单继续或中止遴选。',
          run: (repository, cancellation) => _writer.cherryPickCommit(
            repository,
            objectId: objectId,
            mainlineParent: mainlineParent,
            cancellationToken: cancellation,
          ),
        ),
      );

  /// Exports one loaded commit as a patch without changing Git _sessionState.
  /// 中文：将一个已加载提交导出为补丁，不修改 Git 仓库状态。
  Future<bool> createPatchForCommit(
    String objectId, {
    required String outputPath,
  }) => createPatches(
    [objectId],
    outputPath: outputPath,
    createSeparateFiles: false,
  );

  /// Revalidates selected tracked work-tree rows and exports their combined
  /// _sessionState relative to HEAD without changing the repository.
  /// 中文：重新验证所选已跟踪工作区行，并将它们相对 HEAD 的合并状态导出为
  /// 补丁，不修改仓库。
  Future<bool> createPatchForWorkingTreeChanges(
    List<RepositoryChangeViewData> changes, {
    required String outputPath,
  }) async {
    if (!_isInsideTrackedGitTask) {
      return _trackBooleanGitTask(
        () => createPatchForWorkingTreeChanges(changes, outputPath: outputPath),
      );
    }
    if (changes.isEmpty ||
        _sessionState.phase != RepositorySessionPhase.ready ||
        _sessionState.isWorkingTreeBusy ||
        _sessionState.operationState != GitRepositoryOperationState.none ||
        changes.any(
          (change) =>
              !change.isActionEnabled ||
              !change.isPathValidUtf8 ||
              change.kind == RepositoryChangeKind.untracked ||
              change.kind == RepositoryChangeKind.conflicted,
        )) {
      return false;
    }
    await refresh();
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    if (repository == null ||
        status == null ||
        _sessionState.phase != RepositorySessionPhase.ready) {
      return false;
    }
    final paths = <GitPath>[];
    for (final change in changes) {
      final entry = status.displayEntries
          .where(
            (candidate) =>
                candidate.path.display == change.path &&
                (change.isStaged
                    ? candidate.hasStagedChange
                    : candidate.hasWorkTreeChange),
          )
          .firstOrNull;
      if (entry == null ||
          entry.isConflicted ||
          !entry.path.isValidUtf8 ||
          entry.kind == GitFileStatusKind.untracked) {
        return false;
      }
      if (!paths.contains(entry.path)) paths.add(entry.path);
      final originalPath = entry.originalPath;
      if (originalPath != null && !paths.contains(originalPath)) {
        paths.add(originalPath);
      }
    }
    final cancellation = GitCancellationToken();
    _historyMutationCancellation = cancellation;
    final operation = _startOperation(RepositoryOperationKind.history);
    try {
      await _writer.createWorkingTreePatch(
        repository,
        paths: paths,
        outputPath: outputPath,
        compareAgainstEmptyTree: status.branch.isUnborn,
        cancellationToken: cancellation,
      );
      _completeOperation(
        operation,
        outcome: RepositoryOperationOutcome.succeeded,
        message: '已创建工作区补丁。',
      );
      return true;
    } on Object catch (error, stackTrace) {
      final message = _friendlyError(error);
      _sessionState = _sessionState.copyWith(
        message: message,
        technicalDetails: _technicalDetails(error, stackTrace),
      );
      _completeOperation(
        operation,
        outcome: _operationOutcomeForError(error),
        message: message,
      );
      return false;
    } finally {
      if (identical(_historyMutationCancellation, cancellation)) {
        _historyMutationCancellation = null;
      }
    }
  }

  /// Reads the exact two layers represented by one selected working-tree row:
  /// HEAD/index for staged changes or index/worktree for unstaged changes.
  /// 中文：读取一个工作区选择行所代表的两个精确层级：已暂存为 HEAD/index，
  /// 未暂存为 index/worktree；读取前会刷新并复核 Git 状态。
  Future<WorkingTreeFileComparison> readWorkingTreeFileComparison(
    RepositoryChangeViewData change, {
    int maxBytesPerSide = 16 * 1024 * 1024,
  }) async {
    if (!_isInsideTrackedGitTask) {
      return _trackRequiredGitTask(
        () => readWorkingTreeFileComparison(
          change,
          maxBytesPerSide: maxBytesPerSide,
        ),
      );
    }
    if (maxBytesPerSide <= 0) {
      throw RangeError.value(
        maxBytesPerSide,
        'maxBytesPerSide',
        'Must be positive.',
      );
    }
    if (_sessionState.phase != RepositorySessionPhase.ready ||
        _sessionState.isWorkingTreeBusy ||
        _sessionState.operationState != GitRepositoryOperationState.none ||
        !change.isActionEnabled ||
        !change.isPathValidUtf8 ||
        !change.canExternalDiff ||
        change.kind == RepositoryChangeKind.untracked ||
        change.kind == RepositoryChangeKind.conflicted) {
      throw StateError('当前文件不支持外部差异比对。');
    }
    await refresh();
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    if (repository == null ||
        status == null ||
        _sessionState.phase != RepositorySessionPhase.ready ||
        _sessionState.isWorkingTreeBusy ||
        _sessionState.operationState != GitRepositoryOperationState.none) {
      throw StateError('仓库状态不可用。');
    }
    final entry = status.displayEntries.where((candidate) {
      if (candidate.path.display != change.path) return false;
      return change.isStaged
          ? candidate.hasStagedChange
          : candidate.hasWorkTreeChange;
    }).firstOrNull;
    if (entry == null ||
        entry.isConflicted ||
        !entry.path.isValidUtf8 ||
        entry.submodule?.isSubmodule == true) {
      throw StateError('文件选择或 Git 状态已变化。');
    }
    final generation = _repositoryGeneration;
    Future<Uint8List> blobOrEmpty(String? objectId) {
      if (objectId == null || RegExp(r'^0+$').hasMatch(objectId)) {
        return Future<Uint8List>.value(Uint8List(0));
      }
      return _reader.readBlob(
        repository,
        objectId: objectId,
        maxBytes: maxBytesPerSide,
      );
    }

    final Uint8List beforeBytes;
    final Uint8List afterBytes;
    if (change.isStaged) {
      beforeBytes = await blobOrEmpty(entry.headObjectId);
      afterBytes = await blobOrEmpty(entry.indexObjectId);
    } else {
      beforeBytes = await blobOrEmpty(entry.indexObjectId);
      if (entry.workTreeStatus == GitChangeType.deleted) {
        afterBytes = Uint8List(0);
      } else {
        final root = repository.workTreeRoot;
        if (root == null) {
          throw StateError('当前文件类型不支持外部差异比对。');
        }
        final localPath = path_utils.normalize(
          path_utils.join(root, entry.path.display),
        );
        if (path_utils.isAbsolute(entry.path.display) ||
            !path_utils.isWithin(root, localPath)) {
          throw StateError('工作区文件已失效。');
        }
        final canonicalRoot = await Directory(root).resolveSymbolicLinks();
        final canonicalParent = await Directory(
          path_utils.dirname(localPath),
        ).resolveSymbolicLinks();
        if (canonicalParent != canonicalRoot &&
            !path_utils.isWithin(canonicalRoot, canonicalParent)) {
          throw StateError('工作区文件位于仓库之外。');
        }
        final type = await FileSystemEntity.type(localPath, followLinks: false);
        if (type != FileSystemEntityType.file &&
            type != FileSystemEntityType.link) {
          throw StateError('工作区文件已失效。');
        }
        if (type == FileSystemEntityType.link) {
          afterBytes = Uint8List.fromList(
            utf8.encode(await Link(localPath).target()),
          );
          if (afterBytes.length > maxBytesPerSide) {
            throw const GitException(
              'The work-tree link exceeds the configured output limit.',
            );
          }
        } else {
          final file = await File(localPath).open();
          try {
            if (await file.length() > maxBytesPerSide) {
              throw const GitException(
                'The work-tree file exceeds the configured output limit.',
              );
            }
            afterBytes = await file.read(maxBytesPerSide + 1);
            if (afterBytes.length > maxBytesPerSide) {
              throw const GitException(
                'The work-tree file exceeds the configured output limit.',
              );
            }
          } finally {
            await file.close();
          }
        }
      }
    }
    if (!_providerRef.mounted ||
        generation != _repositoryGeneration ||
        _sessionState.repository?.id != repository.id) {
      throw StateError('仓库已切换，无法进行外部差异比对。');
    }
    return WorkingTreeFileComparison(
      beforeBytes: beforeBytes,
      afterBytes: afterBytes,
    );
  }

  /// Exports loaded commits as one patch or individual patch files.
  /// 中文：将已加载提交导出为一个补丁或多个独立补丁文件，不修改 Git 仓库状态。
  Future<bool> createPatches(
    List<String> objectIds, {
    required String outputPath,
    required bool createSeparateFiles,
  }) async {
    if (!_isInsideTrackedGitTask) {
      return _trackBooleanGitTask(
        () => createPatches(
          objectIds,
          outputPath: outputPath,
          createSeparateFiles: createSeparateFiles,
        ),
      );
    }
    final repository = _sessionState.repository;
    final normalizedIds = objectIds
        .map((objectId) => objectId.trim())
        .where((objectId) => objectId.isNotEmpty)
        .toList(growable: false);
    if (repository == null ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        normalizedIds.isEmpty ||
        normalizedIds.toSet().length != normalizedIds.length ||
        normalizedIds.any(
          (objectId) => !_sessionState.historyCommits.any(
            (commit) => commit.objectId == objectId,
          ),
        )) {
      return false;
    }
    final cancellation = GitCancellationToken();
    _historyMutationCancellation = cancellation;
    final operation = _startOperation(RepositoryOperationKind.history);
    try {
      await _writer.createPatches(
        repository,
        objectIds: normalizedIds,
        outputPath: outputPath,
        createSeparateFiles: createSeparateFiles,
        cancellationToken: cancellation,
      );
      _completeOperation(
        operation,
        outcome: RepositoryOperationOutcome.succeeded,
        message: '已创建补丁。',
      );
      return true;
    } on Object catch (error, stackTrace) {
      final message = _friendlyError(error);
      _sessionState = _sessionState.copyWith(
        message: message,
        technicalDetails: _technicalDetails(error, stackTrace),
      );
      _completeOperation(
        operation,
        outcome: _operationOutcomeForError(error),
        message: message,
      );
      return false;
    } finally {
      if (identical(_historyMutationCancellation, cancellation)) {
        _historyMutationCancellation = null;
      }
    }
  }

  /// Applies or validates a selected patch, then refreshes Git-backed _sessionState.
  /// 中文：应用或验证用户选择的补丁；完成后刷新以 Git 为准的仓库状态。
  Future<bool> applyPatchFile({
    required String patchPath,
    required int? stripLevel,
    required String basePath,
    required bool checkOnly,
  }) async {
    if (!_isInsideTrackedGitTask) {
      return _trackBooleanGitTask(
        () => applyPatchFile(
          patchPath: patchPath,
          stripLevel: stripLevel,
          basePath: basePath,
          checkOnly: checkOnly,
        ),
      );
    }
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    if (repository == null ||
        status == null ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        _sessionState.operationState != GitRepositoryOperationState.none ||
        status.conflictedEntries.isNotEmpty) {
      return false;
    }
    final cancellation = GitCancellationToken();
    _historyMutationCancellation = cancellation;
    final operation = _startOperation(RepositoryOperationKind.history);
    try {
      await _writer.applyPatch(
        repository,
        patchPath: patchPath,
        stripLevel: stripLevel,
        basePath: basePath,
        checkOnly: checkOnly,
        cancellationToken: cancellation,
      );
      // A dry run does not mutate Git, but a refresh keeps all asynchronous
      // snapshots coherent. Do not put the whole workspace into `loading`: a
      // rejected patch must not blank the repository behind this local dialog.
      await refresh();
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded
            ? (checkOnly ? '补丁检查通过。' : '已应用补丁。')
            : '补丁可能已应用，但本地刷新失败；请刷新确认工作区状态。',
      );
      return succeeded;
    } on Object catch (error, stackTrace) {
      if (!checkOnly) await refresh();
      final message = _friendlyError(error);
      _sessionState = _sessionState.copyWith(
        isDiffLoading: false,
        message: message,
        technicalDetails: _technicalDetails(error, stackTrace),
      );
      _completeOperation(
        operation,
        outcome: _operationOutcomeForError(error),
        message: message,
      );
      return false;
    } finally {
      if (identical(_historyMutationCancellation, cancellation)) {
        _historyMutationCancellation = null;
      }
    }
  }

  Future<bool> _runHistoryMutation({
    required String objectId,
    required bool requireCleanWorkTree,
    required String successMessage,
    String? conflictMessage,
    required Future<void> Function(GitRepository, GitCancellationToken) run,
  }) async {
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    final normalizedId = objectId.trim();
    if (repository == null ||
        status == null ||
        status.branch.head == null ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        _sessionState.operationState != GitRepositoryOperationState.none ||
        status.conflictedEntries.isNotEmpty ||
        (requireCleanWorkTree && !status.isClean) ||
        !_sessionState.historyCommits.any(
          (commit) => commit.objectId == normalizedId,
        )) {
      return false;
    }
    final cancellation = GitCancellationToken();
    _historyMutationCancellation = cancellation;
    final operation = _startOperation(RepositoryOperationKind.history);
    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    try {
      await run(repository, cancellation);
      await refresh();
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded ? successMessage : '操作可能已完成，但本地刷新失败；请刷新确认当前仓库状态。',
      );
      return succeeded;
    } on Object catch (error, stackTrace) {
      await refresh();
      final hasConflicts =
          _sessionState.status?.conflictedEntries.isNotEmpty ?? false;
      final message = hasConflicts && conflictMessage != null
          ? conflictMessage
          : _friendlyError(error);
      _sessionState = _sessionState.copyWith(
        phase: RepositorySessionPhase.error,
        isDiffLoading: false,
        message: message,
        technicalDetails: _technicalDetails(error, stackTrace),
      );
      _completeOperation(
        operation,
        outcome: _operationOutcomeForError(error),
        message: message,
      );
      return false;
    } finally {
      if (identical(_historyMutationCancellation, cancellation)) {
        _historyMutationCancellation = null;
      }
    }
  }
}
