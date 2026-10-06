part of 'repository_session.dart';

/// Single-tag mutations owned by [RepositorySessionController].
///
/// 中文：集中维护单个标签的创建、可选推送与删除；批量标签操作位于相邻的批量
/// 拆分文件，并继续共享同一取消、刷新和部分成功语义。
extension RepositorySessionTagWrites on RepositorySessionController {
  /// Creates a tag at one loaded historical commit and can push it to a
  /// selected configured remote.
  /// 中文：在当前已加载提交上创建标签，并可将该标签推送到指定远端。
  Future<bool> createTag(GitCreateTagOptions options) async {
    if (!_isInsideTrackedGitTask) {
      return _trackBooleanGitTask(() => createTag(options));
    }
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    final name = options.name.trim();
    final objectId = options.objectId.trim();
    final pushRemote = options.pushRemoteName?.trim();
    if (repository == null ||
        status == null ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        _sessionState.operationState != GitRepositoryOperationState.none ||
        name.isEmpty ||
        objectId.isEmpty ||
        !_sessionState.commits.any((commit) => commit.objectId == objectId) ||
        _sessionState.tags.any((tag) => tag.name == name) ||
        (options.sign && !options.isAnnotated) ||
        (pushRemote != null &&
            (pushRemote.isEmpty ||
                !_sessionState.remoteNames.contains(pushRemote)))) {
      return false;
    }
    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    final operation = _startOperation(RepositoryOperationKind.ref);
    var localTagCreated = false;
    try {
      await _writer.createTag(
        repository,
        name: name,
        objectId: objectId,
        annotation: options.annotation,
        annotated: options.isAnnotated,
        sign: options.sign,
      );
      localTagCreated = true;
      if (pushRemote != null) {
        await _writer.pushTag(
          repository,
          remoteName: pushRemote,
          tagName: name,
        );
      }
      await refresh();
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded ? '已创建标签 $name。' : '标签可能已创建，但本地刷新失败；请刷新确认引用状态。',
      );
      return succeeded;
    } on ArgumentError catch (error, stackTrace) {
      await refresh();
      if (_sessionState.phase != RepositorySessionPhase.ready) {
        return false;
      }
      _sessionState = _sessionState.copyWith(
        isDiffLoading: false,
        message:
            '标签名称无效。请勿使用空白符、~ ^ : ? * [ \\、.. 或 //，'
            '且不能以 -、/ 开头，也不能以 /、. 结尾。',
        technicalDetails: _technicalDetails(error, stackTrace),
      );
      _completeOperation(
        operation,
        outcome: _operationOutcomeForError(error),
        message: _sessionState.message,
      );
      return false;
    } on Object catch (error, stackTrace) {
      await refresh();
      _sessionState = _sessionState.copyWith(
        phase: RepositorySessionPhase.error,
        isDiffLoading: false,
        message: _friendlyError(error),
        technicalDetails: _technicalDetails(error, stackTrace),
      );
      _completeOperation(
        operation,
        outcome: localTagCreated && pushRemote != null
            ? RepositoryOperationOutcome.partiallySucceeded
            : _operationOutcomeForError(error),
        message: _sessionState.message,
      );
      return false;
    }
  }

  /// Deletes one loaded local tag and optionally its matching remote tag.
  /// 中文：删除一个已读取的本地标签，并可先删除指定远端上的同名标签。
  Future<bool> deleteTag(GitDeleteTagOptions options) async {
    if (!_isInsideTrackedGitTask) {
      return _trackBooleanGitTask(() => deleteTag(options));
    }
    final repository = _sessionState.repository;
    final status = _sessionState.status;
    final name = options.name.trim();
    final remote = options.deleteRemoteName?.trim();
    if (repository == null ||
        status == null ||
        _sessionState.phase == RepositorySessionPhase.loading ||
        _sessionState.operationState != GitRepositoryOperationState.none ||
        !_sessionState.tags.any((tag) => tag.name == name) ||
        (remote != null &&
            (remote.isEmpty || !_sessionState.remoteNames.contains(remote)))) {
      return false;
    }
    _sessionState = _sessionState.copyWith(
      phase: RepositorySessionPhase.loading,
      isDiffLoading: false,
      clearDiff: true,
      clearSelectedChange: true,
      clearMessage: true,
    );
    final operation = _startOperation(RepositoryOperationKind.ref);
    var remoteDeleted = false;
    try {
      if (remote != null) {
        await _writer.deleteRemoteTag(
          repository,
          remoteName: remote,
          tagName: name,
        );
        remoteDeleted = true;
      }
      await _writer.deleteTag(repository, name: name);
      await refresh();
      final succeeded = _sessionState.phase == RepositorySessionPhase.ready;
      _completeOperation(
        operation,
        outcome: succeeded
            ? RepositoryOperationOutcome.succeeded
            : RepositoryOperationOutcome.uncertain,
        message: succeeded ? '已删除标签 $name。' : '标签可能已删除，但本地刷新失败；请刷新确认引用状态。',
      );
      return succeeded;
    } on Object catch (error, stackTrace) {
      await refresh();
      _sessionState = _sessionState.copyWith(
        phase: RepositorySessionPhase.error,
        isDiffLoading: false,
        message: remoteDeleted
            ? '远端 $remote 的标签 $name 已删除，但本地标签仍保留：${_friendlyError(error)}'
            : _friendlyError(error),
        technicalDetails: _technicalDetails(error, stackTrace),
      );
      _completeOperation(
        operation,
        outcome: remoteDeleted
            ? RepositoryOperationOutcome.partiallySucceeded
            : _operationOutcomeForError(error),
        message: _sessionState.message,
      );
      return false;
    }
  }
}
