part of 'repository_session.dart';

/// Repository initialization, remote, fetch, pull and push operations owned
/// by [RepositorySessionController].
///
/// 中文：集中维护仓库初始化、远端配置、Fetch/Pull/Push 及其认证/取消边界。
extension RepositorySessionRemoteWrites on RepositorySessionController {
  /// Initializes only an empty directory, then opens the new repository.
  /// 中文：只在空目录中初始化 Git 仓库，然后打开该仓库。
  /// English: Initializes a Git repository only in an empty directory, then
  /// opens it.
  Future<bool> initializeRepository(String path) async =>
      await _trackGitTask<bool>(() => _initializeRepository(path)) ?? false;

  /// 中文：初始化目录并在同一关闭屏障中打开新仓库。
  /// English: Initializes a directory and opens the new repository within the
  /// same shutdown barrier.
  Future<bool> _initializeRepository(String path) async {
    final normalizedPath = path.trim();
    if (normalizedPath.isEmpty ||
        _sessionState.phase == RepositorySessionPhase.loading) {
      return false;
    }
    _repositoryGeneration++;
    _diffGeneration++;
    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      requestedPath: normalizedPath,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    final operation = _startOperation(RepositoryOperationKind.ref);
    try {
      await _writer.initializeRepository(normalizedPath);
      await openRepository(normalizedPath);
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded ? '已初始化仓库。' : '仓库可能已初始化，但打开后刷新失败；请刷新确认状态。',
      );
      return succeeded;
    } on Object catch (error, stackTrace) {
      _sessionState = _sessionState.copyWith(
        phase: RepositorySessionPhase.error,
        isDiffLoading: false,
        message: _friendlyError(error),
        technicalDetails: _technicalDetails(error, stackTrace),
      );
      _completeOperation(
        operation,
        outcome: _operationOutcomeForError(error),
        message: _friendlyError(error),
      );
      return false;
    }
  }

  /// 中文：在空目录克隆仓库，记录可取消的操作并在结束后刷新和打开新仓库。
  ///
  /// English: Clones a repository into an empty directory, records a
  /// cancellable operation, then refreshes and opens the new repository.
  Future<bool> cloneRepository({
    required String remoteUrl,
    required String directoryPath,
  }) async {
    if (!_isInsideTrackedGitTask) {
      return _trackBooleanGitTask(
        () =>
            cloneRepository(remoteUrl: remoteUrl, directoryPath: directoryPath),
      );
    }
    if (remoteUrl.trim().isEmpty ||
        directoryPath.trim().isEmpty ||
        _sessionState.phase == RepositorySessionPhase.loading) {
      return false;
    }
    _repositoryGeneration++;
    _diffGeneration++;
    final cancellation = GitCancellationToken();
    _cloneCancellation = cancellation;
    final operation = _startOperation(RepositoryOperationKind.clone);
    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      requestedPath: directoryPath.trim(),
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
      isCloneRunning: true,
    );
    try {
      await _runWithAskPassSession(
        cancellation: cancellation,
        run: (environment) => _writer.cloneRepository(
          remoteUrl: remoteUrl,
          directoryPath: directoryPath,
          cancellationToken: cancellation,
          environment: environment,
        ),
      );
      await openRepository(directoryPath);
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.failed,
        message: succeeded ? '仓库已克隆并打开。' : _sessionState.message,
      );
      return succeeded;
    } on Object catch (error, stackTrace) {
      final wasCancelled =
          _operationOutcomeForError(error) ==
          RepositoryOperationOutcome.cancelled;
      // Cancellation after Git starts is represented by GitCommandException
      // with a cancelled kind and may leave files behind. GitCancelledException
      // is raised before the process starts, so it cannot create clone residue.
      final recovery = error is GitCommandException
          ? await _cloneRecoveryMessage(
              directoryPath,
              wasCancelled: wasCancelled,
            )
          : error is GitCancelledException
          ? '克隆已取消，未留下文件，可以重试。'
          : null;
      final message = recovery ?? _friendlyError(error);
      _sessionState = _sessionState.copyWith(
        phase: RepositorySessionPhase.error,
        isDiffLoading: false,
        isCloneRunning: false,
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
      if (identical(_cloneCancellation, cancellation)) {
        _cloneCancellation = null;
      }
    }
  }

  /// 中文：在用户选择的存放位置下按远端仓库名创建子目录并克隆。
  ///
  /// English: Clones into a repository-named child of the selected parent.
  Future<bool> cloneRepositoryIntoParent({
    required String remoteUrl,
    required String parentDirectoryPath,
  }) async {
    if (!_isInsideTrackedGitTask) {
      return _trackBooleanGitTask(
        () => cloneRepositoryIntoParent(
          remoteUrl: remoteUrl,
          parentDirectoryPath: parentDirectoryPath,
        ),
      );
    }
    if (remoteUrl.trim().isEmpty || parentDirectoryPath.trim().isEmpty) {
      return false;
    }
    try {
      final targetPath = path_utils.join(
        parentDirectoryPath.trim(),
        cloneRepositoryNameFromRemote(remoteUrl),
      );
      return await cloneRepository(
        remoteUrl: remoteUrl,
        directoryPath: targetPath,
      );
    } on Object catch (error, stackTrace) {
      _sessionState = _sessionState.copyWith(
        phase: RepositorySessionPhase.error,
        requestedPath: parentDirectoryPath.trim(),
        isDiffLoading: false,
        isCloneRunning: false,
        message: _friendlyError(error),
        technicalDetails: _technicalDetails(error, stackTrace),
      );
      return false;
    }
  }

  /// 中文：取消当前操作。
  /// English: Cancels the current operation.
  void cancelClone() => _cloneCancellation?.cancel();

  /// 中文：获取当前仓库的 `origin`，记录操作结果，并在成功后刷新本地引用状态。
  ///
  /// English: Fetches `origin` for the current repository, records the
  /// outcome, and refreshes local reference _sessionState on success.
  Future<bool> fetchOrigin() =>
      fetchWithOptions(const GitFetchOptions(fetchAllRemotes: false));

  /// Fetches one configured remote and refreshes its tracking references.
  /// 中文：获取指定远端并刷新该远端的跟踪引用。
  Future<bool> fetchRemote(String remoteName) => fetchWithOptions(
    GitFetchOptions(fetchAllRemotes: false, remoteName: remoteName),
  );

  /// 中文：按抓取面板选项获取一个或全部远端，并在完成后刷新本地引用状态。
  ///
  /// English: Fetches one or every remote according to the dialog options and
  /// refreshes local references after the operation completes.
  Future<bool> fetchWithOptions(GitFetchOptions options) async {
    if (!_isInsideTrackedGitTask) {
      return _trackBooleanGitTask(() => fetchWithOptions(options));
    }
    final normalizedRemote = options.remoteName.trim();
    final repository = _sessionState.repository;
    final repositoryGeneration = _repositoryGeneration;
    if (repository == null ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        _isShuttingDown ||
        _fetchPreflightInProgress ||
        _fetchCancellation != null) {
      return false;
    }
    _fetchPreflightInProgress = true;
    List<String> remoteNames;
    try {
      remoteNames = await _reader.readRemoteNames(repository);
    } on Object catch (error, stackTrace) {
      if (_isCurrentRepositoryRequest(repository, repositoryGeneration)) {
        _sessionState = _sessionState.copyWith(
          phase: RepositorySessionPhase.error,
          isFetchRunning: false,
          isDiffLoading: false,
          message: _friendlyError(error),
          technicalDetails: _technicalDetails(error, stackTrace),
        );
      }
      return false;
    } finally {
      _fetchPreflightInProgress = false;
    }
    if (!_isCurrentRepositoryRequest(repository, repositoryGeneration) ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        _fetchCancellation != null) {
      return false;
    }
    final hasRemote = options.fetchAllRemotes
        ? remoteNames.isNotEmpty
        : normalizedRemote.isNotEmpty && remoteNames.contains(normalizedRemote);
    if (!hasRemote) return false;
    final cancellation = GitCancellationToken();
    _fetchCancellation = cancellation;
    final operation = _startOperation(RepositoryOperationKind.fetch);
    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isFetchRunning: true,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    try {
      await _runWithAskPassSession(
        cancellation: cancellation,
        run: (environment) => _writer.fetch(
          repository,
          options: options,
          cancellationToken: cancellation,
          environment: environment,
        ),
      );
      await refresh();
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded ? '已更新远端引用。' : '远端获取可能已部分完成，但本地刷新失败；请再次刷新确认。',
      );
      return succeeded;
    } on Object catch (error, stackTrace) {
      // `fetch --all` can update an earlier remote before a later remote
      // fails or cancellation reaches Git. Refresh to expose completed refs.
      await refresh();
      final message = _friendlyError(error);
      _sessionState = _sessionState.copyWith(
        phase: RepositorySessionPhase.error,
        isFetchRunning: false,
        isDiffLoading: false,
        message: message,
        technicalDetails: _technicalDetails(error, stackTrace),
      );
      _completeOperation(
        operation,
        outcome:
            options.fetchAllRemotes &&
                _operationOutcomeForError(error) !=
                    RepositoryOperationOutcome.cancelled
            ? RepositoryOperationOutcome.uncertain
            : _operationOutcomeForError(error),
        message:
            options.fetchAllRemotes &&
                _operationOutcomeForError(error) !=
                    RepositoryOperationOutcome.cancelled
            ? '获取全部远端未能完整确认；请刷新确认各远端引用状态。'
            : message,
      );
      return false;
    } finally {
      if (identical(_fetchCancellation, cancellation)) {
        _fetchCancellation = null;
      }
    }
  }

  /// 中文：取消当前操作。
  /// English: Cancels the current operation.
  void cancelFetch() => _fetchCancellation?.cancel();

  /// Reads a configured remote URL for the pull dialog with credentials
  /// redacted before it reaches UI _sessionState.
  /// 中文：读取拉取对话框所需的远端地址，并在返回前脱敏凭据。
  Future<String?> readRemoteUrl(String remoteName) async {
    if (!_isInsideTrackedGitTask) {
      return _trackGitTask<String?>(() => readRemoteUrl(remoteName));
    }
    final repository = _sessionState.repository;
    if (repository == null) return null;
    final url = await _reader.readRemoteUrl(repository, remoteName: remoteName);
    return url == null ? null : _redactSensitiveText(url);
  }

  /// 中文：读取当前仓库已配置的远端名称，供显式的拉取和推送面板选择。
  ///
  /// English: Reads configured remote names for explicit pull and push dialog
  /// selection in the current repository.
  Future<List<String>> readRemoteNames() async {
    if (!_isInsideTrackedGitTask) {
      return await _trackGitTask<List<String>>(readRemoteNames) ?? const [];
    }
    final repository = _sessionState.repository;
    if (repository == null) return const [];
    return _reader.readRemoteNames(repository);
  }

  /// Adds a new remote after re-reading configured names, then refreshes all
  /// Git-backed repository _sessionState. The operation only changes local config.
  ///
  /// 中文：重新读取远端名称并确认无重名后添加远端，再刷新全部 Git 仓库状态；
  /// 此操作只修改本地配置，不连接远端或抓取引用。
  Future<bool> addRemote(String remoteName, String remoteUrl) async {
    if (!_isInsideTrackedGitTask) {
      return _trackBooleanGitTask(() => addRemote(remoteName, remoteUrl));
    }
    final repository = _sessionState.repository;
    final repositoryGeneration = _repositoryGeneration;
    final normalizedName = remoteName.trim();
    final normalizedUrl = remoteUrl.trim();
    if (repository == null ||
        normalizedName.isEmpty ||
        normalizedUrl.isEmpty ||
        _sessionState.operationState != GitRepositoryOperationState.none ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        _isShuttingDown ||
        _remoteConfigurationPreflightInProgress) {
      return false;
    }
    _remoteConfigurationPreflightInProgress = true;
    RepositoryOperationRecord? operation;
    try {
      final remoteNames = await _reader.readRemoteNames(repository);
      if (_isShuttingDown ||
          !identical(_sessionState.repository, repository) ||
          _sessionState.phase == RepositorySessionPhase.loading ||
          remoteNames.contains(normalizedName)) {
        return false;
      }
      _sessionState = _sessionState.copyWith(
        phase: RepositorySessionPhase.loading,
        clearMessage: true,
      );
      operation = _startOperation(RepositoryOperationKind.remote);
      await _writer.addRemote(
        repository,
        remoteName: normalizedName,
        remoteUrl: normalizedUrl,
      );
      await refresh();
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded
            ? '已添加远端 $normalizedName。'
            : '远端可能已添加，但本地刷新失败；请刷新确认配置。',
      );
      return succeeded;
    } on Object catch (error, stackTrace) {
      if (_isCurrentRepositoryRequest(repository, repositoryGeneration)) {
        _sessionState = _sessionState.copyWith(
          phase: RepositorySessionPhase.error,
          isDiffLoading: false,
          message: _friendlyError(error),
          technicalDetails: _technicalDetails(error, stackTrace),
        );
      }
      if (operation != null) {
        _completeOperation(
          operation,
          outcome: _operationOutcomeForError(error),
          message: _friendlyError(error),
        );
      }
      return false;
    } finally {
      _remoteConfigurationPreflightInProgress = false;
    }
  }

  /// Removes one configured remote after verifying it still exists, then
  /// reloads all repository _sessionState from Git.
  ///
  /// 中文：确认远端仍存在后移除其本地配置，并重新从 Git 读取完整仓库状态。
  Future<bool> removeRemote(String remoteName) async {
    if (!_isInsideTrackedGitTask) {
      return _trackBooleanGitTask(() => removeRemote(remoteName));
    }
    final repository = _sessionState.repository;
    final repositoryGeneration = _repositoryGeneration;
    final normalizedName = remoteName.trim();
    if (repository == null ||
        normalizedName.isEmpty ||
        _sessionState.operationState != GitRepositoryOperationState.none ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        _isShuttingDown ||
        _remoteConfigurationPreflightInProgress) {
      return false;
    }
    _remoteConfigurationPreflightInProgress = true;
    RepositoryOperationRecord? operation;
    try {
      final remoteNames = await _reader.readRemoteNames(repository);
      if (_isShuttingDown ||
          !identical(_sessionState.repository, repository) ||
          _sessionState.phase == RepositorySessionPhase.loading ||
          !remoteNames.contains(normalizedName)) {
        return false;
      }
      operation = _startOperation(RepositoryOperationKind.remote);
      await _writer.removeRemote(repository, normalizedName);
      await refresh();
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded
            ? '已移除远端 $normalizedName。'
            : '远端可能已移除，但本地刷新失败；请刷新确认配置。',
      );
      return succeeded;
    } on Object catch (error, stackTrace) {
      if (_isCurrentRepositoryRequest(repository, repositoryGeneration)) {
        _sessionState = _sessionState.copyWith(
          phase: RepositorySessionPhase.error,
          isDiffLoading: false,
          message: _friendlyError(error),
          technicalDetails: _technicalDetails(error, stackTrace),
        );
      }
      if (operation != null) {
        _completeOperation(
          operation,
          outcome: _operationOutcomeForError(error),
          message: _friendlyError(error),
        );
      }
      return false;
    } finally {
      _remoteConfigurationPreflightInProgress = false;
    }
  }

  /// 中文：仅在附着的非 unborn 分支、工作区和索引干净且有上游时快速前进拉取，
  /// 并在失败后刷新引用状态。
  ///
  /// English: Fast-forward pulls only with a clean work tree/index and an
  /// upstream, refreshing reference _sessionState after failure as well.
  Future<bool> pullFastForward() async {
    if (!_isInsideTrackedGitTask) {
      return _trackBooleanGitTask(pullFastForward);
    }
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    if (repository == null ||
        status == null ||
        status.branch.upstream == null ||
        status.branch.isDetached ||
        status.branch.isUnborn ||
        !status.isClean ||
        _sessionState.operationState != GitRepositoryOperationState.none ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        _isShuttingDown ||
        _pullCancellation != null) {
      return false;
    }
    final cancellation = GitCancellationToken();
    _pullCancellation = cancellation;
    final operation = _startOperation(RepositoryOperationKind.pull);
    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isPullRunning: true,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    try {
      await _runWithAskPassSession(
        cancellation: cancellation,
        run: (environment) => _writer.pullFastForward(
          repository,
          cancellationToken: cancellation,
          environment: environment,
        ),
      );
      await refresh();
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded ? '已快速前进拉取。' : '拉取可能已完成，但本地刷新失败；请刷新确认当前分支状态。',
      );
      return succeeded;
    } on Object catch (error, stackTrace) {
      // Pull can fetch successfully before rejecting a non-fast-forward update.
      // Refresh before showing the error so refs and ahead/behind stay accurate.
      await refresh();
      final message = _friendlyError(error);
      _sessionState = _sessionState.copyWith(
        phase: RepositorySessionPhase.error,
        isPullRunning: false,
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
      if (identical(_pullCancellation, cancellation)) {
        _pullCancellation = null;
      }
    }
  }

  /// Updates the attached branch from its configured upstream with `pull
  /// --ff-only`, after the caller has confirmed the fixed safe semantics.
  ///
  /// 中文：按已确认的安全语义，对当前附着分支的已配置 upstream 执行一次
  /// `pull --ff-only`；不创建合并提交、不变基、不推送，并复用取消、认证和刷新边界。
  Future<bool> updateFromUpstream() async {
    if (!_isInsideTrackedGitTask) {
      return _trackBooleanGitTask(updateFromUpstream);
    }
    return pullFastForward();
  }

  /// Runs a configured pull from the Sourcetree-style dialog.
  /// 中文：按 Sourcetree 风格拉取对话框的配置执行拉取。
  Future<bool> pullWithOptions(GitPullOptions options) async {
    if (!_isInsideTrackedGitTask) {
      return _trackBooleanGitTask(() => pullWithOptions(options));
    }
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    final repositoryGeneration = _repositoryGeneration;
    if (repository == null ||
        status == null ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        _isShuttingDown ||
        _pullPreflightInProgress ||
        _pullCancellation != null) {
      return false;
    }
    _pullPreflightInProgress = true;
    List<String> remoteNames;
    try {
      remoteNames = await _reader.readRemoteNames(repository);
    } on Object catch (error, stackTrace) {
      if (_isCurrentRepositoryRequest(repository, repositoryGeneration)) {
        _sessionState = _sessionState.copyWith(
          phase: RepositorySessionPhase.error,
          isPullRunning: false,
          isDiffLoading: false,
          message: _friendlyError(error),
          technicalDetails: _technicalDetails(error, stackTrace),
        );
      }
      return false;
    } finally {
      _pullPreflightInProgress = false;
    }
    if (!_isCurrentRepositoryRequest(repository, repositoryGeneration) ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        _pullCancellation != null) {
      return false;
    }
    if (!remoteNames.contains(options.remoteName.trim())) return false;
    final cancellation = GitCancellationToken();
    _pullCancellation = cancellation;
    final operation = _startOperation(RepositoryOperationKind.pull);
    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isPullRunning: true,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    try {
      await _runWithAskPassSession(
        cancellation: cancellation,
        run: (environment) => _writer.pull(
          repository,
          options: options,
          cancellationToken: cancellation,
          environment: environment,
        ),
      );
      await refresh();
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded ? '已拉取更新。' : '拉取可能已完成，但本地刷新失败；请刷新确认当前分支状态。',
      );
      return succeeded;
    } on Object catch (error, stackTrace) {
      await refresh();
      final message = _friendlyError(error);
      _sessionState = _sessionState.copyWith(
        phase: RepositorySessionPhase.error,
        isPullRunning: false,
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
      if (identical(_pullCancellation, cancellation)) {
        _pullCancellation = null;
      }
    }
  }

  /// Continues the paused rebase after conflict fixes have been staged.
  /// 中文：暂存冲突修复后继续暂停的变基。
  Future<bool> continueRebase() => _trackBooleanGitTask(
    () => _finishPausedRebase(action: _RebaseRecoveryAction.continueRebase),
  );

  /// Skips the current commit in a paused rebase sequence.
  /// 中文：复核暂停的变基状态后跳过当前提交，并刷新真实仓库状态。
  Future<bool> skipRebase() => _trackBooleanGitTask(
    () => _finishPausedRebase(action: _RebaseRecoveryAction.skip),
  );

  /// Aborts the paused rebase and restores the pre-rebase _sessionState.
  /// 中文：中止暂停的变基并恢复变基前状态。
  Future<bool> abortRebase() => _trackBooleanGitTask(
    () => _finishPausedRebase(action: _RebaseRecoveryAction.abort),
  );

  /// Continues a paused merge after all conflict resolutions are staged.
  /// 中文：在所有冲突解决结果已暂存后继续暂停的合并。
  Future<bool> continueMerge() => _trackBooleanGitTask(
    () => _finishPausedRepositoryOperation(
      expectedState: GitRepositoryOperationState.merge,
      successMessage: '已继续合并。',
      conflictMessage: '合并仍有冲突。请解决冲突并暂存后继续，或选择中止合并。',
      run: (repository, cancellation) =>
          _writer.continueMerge(repository, cancellationToken: cancellation),
    ),
  );

  /// Aborts a paused merge and asks Git to restore the pre-merge _sessionState.
  /// 中文：中止暂停的合并，并由 Git 尝试恢复到合并前状态。
  Future<bool> abortMerge() => _trackBooleanGitTask(
    () => _finishPausedRepositoryOperation(
      expectedState: GitRepositoryOperationState.merge,
      successMessage: '已中止合并。',
      conflictMessage: '中止合并失败；请检查当前工作区状态后重试。',
      run: (repository, cancellation) =>
          _writer.abortMerge(repository, cancellationToken: cancellation),
    ),
  );

  Future<bool> _finishPausedRebase({
    required _RebaseRecoveryAction action,
  }) async {
    final repository = _sessionState.repository;
    if (repository == null ||
        _sessionState.operationState != GitRepositoryOperationState.rebase ||
        _sessionState.phase == RepositorySessionPhase.loading) {
      return false;
    }
    final cancellation = GitCancellationToken();
    _pullCancellation = cancellation;
    final operation = _startOperation(RepositoryOperationKind.pull);
    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isPullRunning: true,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    try {
      await _runWithAskPassSession(
        cancellation: cancellation,
        run: (environment) => switch (action) {
          _RebaseRecoveryAction.abort => _writer.abortRebase(
            repository,
            cancellationToken: cancellation,
            environment: environment,
          ),
          _RebaseRecoveryAction.skip => _writer.skipRebase(
            repository,
            cancellationToken: cancellation,
            environment: environment,
          ),
          _RebaseRecoveryAction.continueRebase => _writer.continueRebase(
            repository,
            cancellationToken: cancellation,
            environment: environment,
          ),
        },
      );
      await refresh();
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded
            ? switch (action) {
                _RebaseRecoveryAction.abort => '已中止变基。',
                _RebaseRecoveryAction.skip => '已跳过当前变基提交。',
                _RebaseRecoveryAction.continueRebase => '已继续变基。',
              }
            : '变基恢复可能已完成，但本地刷新失败；请刷新确认当前操作状态。',
      );
      return succeeded;
    } on Object catch (error, stackTrace) {
      await refresh();
      final message =
          error is GitCommandException && error.kind == GitErrorKind.conflicts
          ? '变基仍有冲突。请解决冲突并暂存后继续、跳过当前提交，或选择中止变基。'
          : _friendlyError(error);
      _sessionState = _sessionState.copyWith(
        phase: RepositorySessionPhase.error,
        isPullRunning: false,
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
      if (identical(_pullCancellation, cancellation)) {
        _pullCancellation = null;
      }
    }
  }

  /// Continues a paused cherry-pick after conflict fixes have been staged.
  /// 中文：暂存冲突修复后继续暂停的遴选。
  Future<bool> continueCherryPick() => _trackBooleanGitTask(
    () => _finishPausedRepositoryOperation(
      expectedState: GitRepositoryOperationState.cherryPick,
      successMessage: '已继续遴选。',
      conflictMessage: '遴选仍有冲突。请解决冲突并暂存后继续，或选择中止遴选。',
      run: (repository, cancellation) => _writer.continueCherryPick(
        repository,
        cancellationToken: cancellation,
      ),
    ),
  );

  /// Aborts a paused cherry-pick and restores its pre-pick branch _sessionState.
  /// 中文：中止暂停的遴选并恢复遴选前状态。
  Future<bool> abortCherryPick() => _trackBooleanGitTask(
    () => _finishPausedRepositoryOperation(
      expectedState: GitRepositoryOperationState.cherryPick,
      successMessage: '已中止遴选。',
      conflictMessage: '遴选仍有冲突。',
      run: (repository, cancellation) =>
          _writer.abortCherryPick(repository, cancellationToken: cancellation),
    ),
  );

  /// Skips the current commit in a paused cherry-pick sequence.
  /// 中文：复核遴选暂停状态后跳过当前提交，并刷新真实仓库状态。
  Future<bool> skipCherryPick() => _trackBooleanGitTask(
    () => _finishPausedRepositoryOperation(
      expectedState: GitRepositoryOperationState.cherryPick,
      successMessage: '已跳过当前遴选提交。',
      conflictMessage: '遴选仍有冲突，请处理冲突后重试跳过。',
      run: (repository, cancellation) =>
          _writer.skipCherryPick(repository, cancellationToken: cancellation),
    ),
  );

  /// Continues a paused revert after conflict fixes have been staged.
  /// 中文：暂存冲突修复后继续暂停的回滚。
  Future<bool> continueRevert() => _trackBooleanGitTask(
    () => _finishPausedRepositoryOperation(
      expectedState: GitRepositoryOperationState.revert,
      successMessage: '已继续回滚。',
      conflictMessage: '回滚仍有冲突。请解决冲突并暂存后继续，或选择中止回滚。',
      run: (repository, cancellation) =>
          _writer.continueRevert(repository, cancellationToken: cancellation),
    ),
  );

  /// Aborts a paused revert and restores its pre-revert branch _sessionState.
  /// 中文：中止暂停的回滚并恢复回滚前状态。
  Future<bool> abortRevert() => _trackBooleanGitTask(
    () => _finishPausedRepositoryOperation(
      expectedState: GitRepositoryOperationState.revert,
      successMessage: '已中止回滚。',
      conflictMessage: '回滚仍有冲突。',
      run: (repository, cancellation) =>
          _writer.abortRevert(repository, cancellationToken: cancellation),
    ),
  );

  /// Skips the current commit in a paused revert sequence.
  /// 中文：复核回滚暂停状态后跳过当前提交，并刷新真实仓库状态。
  Future<bool> skipRevert() => _trackBooleanGitTask(
    () => _finishPausedRepositoryOperation(
      expectedState: GitRepositoryOperationState.revert,
      successMessage: '已跳过当前回滚提交。',
      conflictMessage: '回滚仍有冲突，请处理冲突后重试跳过。',
      run: (repository, cancellation) =>
          _writer.skipRevert(repository, cancellationToken: cancellation),
    ),
  );

  /// Runs a paused merge, cherry-pick, or revert recovery command after
  /// revalidating the operation marker, then refreshes authoritative _sessionState.
  ///
  /// 中文：复核操作标记后执行暂停中的合并、遴选或回滚恢复命令，并刷新真实状态。
  Future<bool> _finishPausedRepositoryOperation({
    required GitRepositoryOperationState expectedState,
    required String successMessage,
    required String conflictMessage,
    required Future<void> Function(GitRepository, GitCancellationToken) run,
  }) async {
    final repository = _sessionState.repository;
    if (repository == null ||
        _sessionState.operationState != expectedState ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        _sessionState.isWorkingTreeBusy) {
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
      final message =
          error is GitCommandException && error.kind == GitErrorKind.conflicts
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

  /// 中文：取消当前操作。
  /// English: Cancels the current operation.
  void cancelPull() => _pullCancellation?.cancel();

  /// 中文：推送当前分支到已配置目标；首次推送时创建同名远端分支，即使没有领先提交也允许打开 Sourcetree 风格的推送流程；异常结束后会验证远端是否已包含 HEAD。
  ///
  /// English: Pushes the current branch to its configured target, creating the
  /// matching remote branch on first push. The no-op case is allowed so the
  /// Sourcetree-style toolbar action remains clickable; uncertain outcomes are
  /// verified against the remote.
  Future<bool> pushUpstream() async {
    if (!_isInsideTrackedGitTask) {
      return _trackBooleanGitTask(pushUpstream);
    }
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    final branch = status?.branch;
    final detachedPushBranch = branch?.isDetached == true
        ? selectDetachedPushBranch(_sessionState)
        : null;
    final canPush =
        repository != null &&
        branch != null &&
        branch.objectId != null &&
        ((!branch.isDetached &&
                (branch.upstream != null || _sessionState.hasOriginRemote)) ||
            (branch.isDetached && detachedPushBranch != null));
    if (!canPush ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        _isShuttingDown ||
        _pushPreflightInProgress ||
        _pushCancellation != null) {
      return false;
    }
    final cancellation = GitCancellationToken();
    _pushCancellation = cancellation;
    final operation = _startOperation(RepositoryOperationKind.push);
    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isPushRunning: true,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    try {
      await _runWithAskPassSession(
        cancellation: cancellation,
        run: (environment) => _writer.pushUpstream(
          repository,
          localBranchName: detachedPushBranch?.name,
          cancellationToken: cancellation,
          environment: environment,
        ),
      );
      await refresh();
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded ? '已推送当前分支。' : '推送可能已完成，但本地刷新失败；请 Fetch 刷新确认。',
      );
      return succeeded;
    } on Object catch (error, stackTrace) {
      // A push may reach the remote before the process exits or is cancelled.
      // Verify the target first, then refresh local tracking _sessionState. The
      // verification is read-only and can be cancelled through cancelPush.
      final remoteContainsHead = await _verifyUncertainPush(
        repository,
        localBranchName: detachedPushBranch?.name,
      );
      await refresh();
      final wasCancelled =
          _operationOutcomeForError(error) ==
          RepositoryOperationOutcome.cancelled;
      final message = remoteContainsHead
          ? '推送进程未正常完成，但远端已包含目标分支提交。请 Fetch 刷新 ahead/behind。'
          : _friendlyError(error);
      _sessionState = _sessionState.copyWith(
        phase: RepositorySessionPhase.error,
        isPushRunning: false,
        isDiffLoading: false,
        message: message,
        technicalDetails: _technicalDetails(error, stackTrace),
      );
      _completeOperation(
        operation,
        outcome: remoteContainsHead
            ? RepositoryOperationOutcome.succeeded
            : wasCancelled
            ? RepositoryOperationOutcome.cancelled
            : RepositoryOperationOutcome.uncertain,
        message: message,
      );
      return false;
    } finally {
      if (identical(_pushCancellation, cancellation)) {
        _pushCancellation = null;
      }
    }
  }

  /// 中文：推送用户在面板中明确选择的分支映射，并可同时推送所有标签；完成后刷新 Git 状态。
  ///
  /// English: Pushes branch mappings explicitly selected in the panel and can
  /// include all tags; refreshes the Git-backed _sessionState after completion.
  Future<bool> pushWithOptions(GitPushOptions options) async {
    if (!_isInsideTrackedGitTask) {
      return _trackBooleanGitTask(() => pushWithOptions(options));
    }
    final repository = _sessionState.repository;
    final repositoryGeneration = _repositoryGeneration;
    final selectedLocalBranches = options.branches
        .map((branch) => branch.localBranch.trim())
        .toSet();
    if (repository == null ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        _isShuttingDown ||
        _pushPreflightInProgress ||
        _pushCancellation != null ||
        (selectedLocalBranches.isEmpty && !options.pushTags) ||
        selectedLocalBranches.any((name) => name.isEmpty) ||
        !selectedLocalBranches.every(
          (name) =>
              _sessionState.localBranches.any((branch) => branch.name == name),
        )) {
      return false;
    }
    _pushPreflightInProgress = true;
    late final List<String> remoteNames;
    try {
      remoteNames = await _reader.readRemoteNames(repository);
    } on Object catch (error, stackTrace) {
      if (_isCurrentRepositoryRequest(repository, repositoryGeneration)) {
        _sessionState = _sessionState.copyWith(
          phase: RepositorySessionPhase.error,
          isPushRunning: false,
          isDiffLoading: false,
          message: _friendlyError(error),
          technicalDetails: _technicalDetails(error, stackTrace),
        );
      }
      return false;
    } finally {
      _pushPreflightInProgress = false;
    }
    if (!_isCurrentRepositoryRequest(repository, repositoryGeneration) ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        _pushCancellation != null) {
      return false;
    }
    if (!remoteNames.contains(options.remoteName.trim())) return false;

    final cancellation = GitCancellationToken();
    _pushCancellation = cancellation;
    final operation = _startOperation(RepositoryOperationKind.push);
    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isPushRunning: true,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    try {
      await _runWithAskPassSession(
        cancellation: cancellation,
        run: (environment) => _writer.pushBranches(
          repository,
          options: options,
          cancellationToken: cancellation,
          environment: environment,
        ),
      );
      await refresh();
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded ? '已推送所选引用。' : '所选引用可能已推送，但本地刷新失败；请 Fetch 刷新确认。',
      );
      return succeeded;
    } on Object catch (error, stackTrace) {
      await refresh();
      final message = _friendlyError(error);
      _sessionState = _sessionState.copyWith(
        phase: RepositorySessionPhase.error,
        isPushRunning: false,
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
      if (identical(_pushCancellation, cancellation)) {
        _pushCancellation = null;
      }
    }
  }

  /// 中文：取消当前操作。
  /// English: Cancels the current operation.
  void cancelPush() {
    _pushCancellation?.cancel();
    _pushVerificationCancellation?.cancel();
  }

  /// 中文：仅为明确的远端操作临时启用 AskPass；检查、刷新和推送验证始终保持非交互环境。
  ///
  /// English: Temporarily enables AskPass only for explicit remote operations;
  /// inspection, refresh, and push verification remain non-interactive.
  Future<void> _runWithAskPassSession({
    required GitCancellationToken cancellation,
    required Future<void> Function(Map<String, String> environment) run,
  }) async {
    if (!GitAskPassSession.isBundledHelperAvailableForCurrentRuntime) {
      // Never point GIT_ASKPASS at a guessed development/test binary. Git's
      // existing credential helper and SSH Agent remain available while
      // terminal prompting stays disabled by GitRunner.
      await run(const <String, String>{});
      return;
    }
    final promptCoordinator = _providerRef.read(
      gitAskPassPromptCoordinatorProvider.notifier,
    );
    final session = await GitAskPassSession.start(
      onPrompt: promptCoordinator.request,
    );
    final registration = cancellation.register(() {
      promptCoordinator.cancel();
      unawaited(session.close());
    });
    try {
      await run(session.environmentForBundledHelper());
    } finally {
      registration.dispose();
      promptCoordinator.cancel();
      await session.close();
    }
  }

  /// 中文：验证当前条件。
  /// English: Verifies the current condition.
  Future<bool> _verifyUncertainPush(
    GitRepository repository, {
    String? localBranchName,
  }) async {
    if (_isShuttingDown) return false;
    final cancellation = GitCancellationToken();
    _pushVerificationCancellation = cancellation;
    try {
      return await _writer.verifyUpstream(
        repository,
        localBranchName: localBranchName,
        cancellationToken: cancellation,
      );
    } on Object {
      return false;
    } finally {
      if (identical(_pushVerificationCancellation, cancellation)) {
        _pushVerificationCancellation = null;
      }
    }
  }
}
