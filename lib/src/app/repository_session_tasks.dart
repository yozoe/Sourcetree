part of 'repository_session.dart';

/// Engine-owned task and shutdown state for [RepositorySessionController].
///
/// 中文：保存 [RepositorySessionController] 的 Engine 专属任务与关闭状态。
/// 此 part 与 facade 共用私有 library 边界，避免将 generation、取消令牌或任务集合
/// 暴露给 UI 或其他应用层模块。
final Object _trackedGitTaskZoneKey = Object();

extension on RepositorySessionController {
  bool get _isInsideTrackedGitTask =>
      Zone.current[_trackedGitTaskZoneKey] == this;

  /// Executes the shutdown barrier owned by the controller facade.
  ///
  /// 中文：执行由 controller facade 持有的关闭屏障。
  Future<void> _prepareForShutdown({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final deadline = DateTime.now().add(timeout);
    Duration remaining() {
      final value = deadline.difference(DateTime.now());
      return value.isNegative ? Duration.zero : value;
    }

    _isShuttingDown = true;
    _repositoryGeneration++;
    _historyGeneration++;
    _diffGeneration++;
    _commitGeneration++;
    _commitDiffGeneration++;
    _cancelActiveGitOperations();

    if (remaining() > Duration.zero) {
      try {
        await _changeMonitor.stop().timeout(remaining());
      } on TimeoutException {
        // Provider disposal makes a final best-effort cancellation attempt.
      }
    }

    await _runner.cancelAllAndWait(timeout: remaining());
    if (_activeGitTasks.isNotEmpty && remaining() > Duration.zero) {
      try {
        await Future.wait<void>(
          _activeGitTasks.toList(growable: false),
        ).timeout(remaining());
      } on TimeoutException {
        // The outer native host also has a bounded watchdog. A final runner
        // sweep below escalates any process still owned by this Engine.
      }
    }
    // A tracked flow may perform a final Git refresh after its mutation exits.
    await _runner.cancelAllAndWait(timeout: remaining());
  }

  /// Runs one application-layer Git flow under the Engine shutdown barrier.
  ///
  /// 中文：在 Engine 关闭屏障内执行一个应用层 Git 流程；关闭开始后
  /// 不再启动新流程，已开始的流程完成前不释放 Engine。
  Future<T?> _trackGitTask<T>(Future<T> Function() run) {
    if (_isShuttingDown) return Future<T?>.value();
    late final Future<void> completion;
    final operation = runZoned(
      run,
      zoneValues: <Object?, Object?>{_trackedGitTaskZoneKey: this},
    );
    completion = operation
        .then<void>((_) {}, onError: (Object error, StackTrace stackTrace) {})
        .whenComplete(() => _activeGitTasks.remove(completion));
    _activeGitTasks.add(completion);
    return operation;
  }

  /// Runs a boolean Git entry point exactly once inside the shutdown barrier.
  ///
  /// 中文：确保返回布尔值的 Git 入口只在关闭屏障内执行一次；嵌套调用复用当前任务。
  Future<bool> _trackBooleanGitTask(Future<bool> Function() run) async {
    if (_isInsideTrackedGitTask) return run();
    return await _trackGitTask<bool>(run) ?? false;
  }

  /// Runs a void Git entry point inside the shutdown barrier.
  ///
  /// 中文：确保无返回值的 Git 入口在关闭屏障内执行，嵌套读取复用当前任务。
  Future<void> _trackVoidGitTask(Future<void> Function() run) async {
    if (_isInsideTrackedGitTask) return run();
    await _trackGitTask<void>(run);
  }

  /// Runs a value-producing Git entry point or reports shutdown cancellation.
  ///
  /// 中文：在关闭屏障内执行必须返回值的 Git 入口；关闭后新请求以取消错误结束。
  Future<T> _trackRequiredGitTask<T>(Future<T> Function() run) async {
    if (_isInsideTrackedGitTask) return run();
    final result = await _trackGitTask<T>(run);
    if (result == null) throw const GitCancelledException();
    return result;
  }

  void _cancelActiveGitOperations() {
    _cloneCancellation?.cancel();
    _fetchCancellation?.cancel();
    _pullCancellation?.cancel();
    _pushCancellation?.cancel();
    _pushVerificationCancellation?.cancel();
    _stashCancellation?.cancel();
    _historyMutationCancellation?.cancel();
    _repositoryDetailsCancellation?.cancel();
  }
}

extension on RepositorySessionController {
  GitCancellationToken? get _cloneCancellation =>
      _taskTracker.cloneCancellation;
  set _cloneCancellation(GitCancellationToken? value) =>
      _taskTracker.cloneCancellation = value;

  GitCancellationToken? get _fetchCancellation =>
      _taskTracker.fetchCancellation;
  set _fetchCancellation(GitCancellationToken? value) =>
      _taskTracker.fetchCancellation = value;

  GitCancellationToken? get _pullCancellation => _taskTracker.pullCancellation;
  set _pullCancellation(GitCancellationToken? value) =>
      _taskTracker.pullCancellation = value;

  GitCancellationToken? get _pushCancellation => _taskTracker.pushCancellation;
  set _pushCancellation(GitCancellationToken? value) =>
      _taskTracker.pushCancellation = value;

  GitCancellationToken? get _pushVerificationCancellation =>
      _taskTracker.pushVerificationCancellation;
  set _pushVerificationCancellation(GitCancellationToken? value) =>
      _taskTracker.pushVerificationCancellation = value;

  GitCancellationToken? get _stashCancellation =>
      _taskTracker.stashCancellation;
  set _stashCancellation(GitCancellationToken? value) =>
      _taskTracker.stashCancellation = value;

  GitCancellationToken? get _historyMutationCancellation =>
      _taskTracker.historyMutationCancellation;
  set _historyMutationCancellation(GitCancellationToken? value) =>
      _taskTracker.historyMutationCancellation = value;

  GitCancellationToken? get _repositoryDetailsCancellation =>
      _taskTracker.repositoryDetailsCancellation;
  set _repositoryDetailsCancellation(GitCancellationToken? value) =>
      _taskTracker.repositoryDetailsCancellation = value;

  Set<Future<void>> get _activeGitTasks => _taskTracker.activeGitTasks;
  bool get _isShuttingDown => _taskTracker.isShuttingDown;
  set _isShuttingDown(bool value) => _taskTracker.isShuttingDown = value;
}

/// Private, Engine-scoped ownership of cancellable Git work.
///
/// 中文：可取消 Git 任务的私有 Engine 级所有者。它不暴露应用层接口，所有访问仍由
/// [RepositorySessionController] 的关闭屏障统一协调。
final class _RepositoryTaskTracker {
  GitCancellationToken? cloneCancellation;
  GitCancellationToken? fetchCancellation;
  GitCancellationToken? pullCancellation;
  GitCancellationToken? pushCancellation;
  GitCancellationToken? pushVerificationCancellation;
  GitCancellationToken? stashCancellation;
  GitCancellationToken? historyMutationCancellation;
  GitCancellationToken? repositoryDetailsCancellation;
  final Set<Future<void>> activeGitTasks = <Future<void>>{};
  var isShuttingDown = false;
}
