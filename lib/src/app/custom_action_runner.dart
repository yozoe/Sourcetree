import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../git/git_cancellation.dart';
import '../git/git_errors.dart';
import 'custom_action_configuration.dart';
import 'repository_trust.dart';

/// Starts one custom-action process with explicit environment semantics.
///
/// 中文：按明确的环境继承策略启动一个自定义操作进程；实现不得经由 Shell。
typedef CustomActionProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
      required bool includeParentEnvironment,
    });

/// Runs configured custom actions without exposing a menu or implicit target.
///
/// 中文：执行已配置的自定义操作，但不负责菜单展示或隐式选择目标；调用方必须
/// 提供逐次确认和最新仓库 capability 复核。
final class CustomActionRunner {
  CustomActionRunner({
    CustomActionProcessStarter? processStarter,
    GitProcessTerminator? processTerminator,
    this.outputLimit = 1024 * 1024,
  }) : _processStarter = processStarter ?? _startProcess,
       _processTerminator =
           processTerminator ?? const DefaultGitProcessTerminator() {
    if (outputLimit < 0) {
      throw ArgumentError.value(outputLimit, 'outputLimit');
    }
  }

  final CustomActionProcessStarter _processStarter;
  final GitProcessTerminator _processTerminator;
  final int outputLimit;
  final Set<CustomActionRun> _activeRuns = <CustomActionRun>{};
  int _pendingStarts = 0;
  Completer<void>? _pendingStartsCompleter;
  Future<void>? _closeAllFuture;
  bool _isClosing = false;

  /// Starts one trusted, explicitly enabled action for the exact target.
  ///
  /// 中文：为精确目标启动一个已信任且明确启用的操作；启动前校验配置、目标和
  /// 取消状态，不继承桌面应用环境，也不通过 Shell 解释参数。
  Future<CustomActionRun> start({
    required CustomActionConfiguration configuration,
    required RepositoryTrustStatus trustStatus,
    required CustomActionTarget target,
    GitCancellationToken? cancellationToken,
  }) async {
    if (_isClosing) {
      throw StateError('Custom action runner is closing.');
    }
    if (!canActivateCustomAction(
      trustStatus: trustStatus,
      configuration: configuration,
    )) {
      throw StateError('Custom action is not trusted and explicitly enabled.');
    }
    if (cancellationToken?.isCancelled ?? false) {
      throw const GitCancelledException();
    }
    final invocation = configuration.buildInvocation(target);
    _beginStart();
    try {
      final process = await _processStarter(
        invocation.executablePath,
        invocation.arguments,
        workingDirectory: invocation.workingDirectory,
        environment: invocation.environment,
        includeParentEnvironment: invocation.includeParentEnvironment,
      );
      late final CustomActionRun run;
      run = CustomActionRun._(
        process: process,
        processTerminator: _processTerminator,
        outputLimit: outputLimit,
        onClosed: () => _activeRuns.remove(run),
      );
      _activeRuns.add(run);
      run._attachCancellation(cancellationToken);
      if (_isClosing) {
        await run.close();
        throw StateError('Custom action runner is closing.');
      }
      return run;
    } finally {
      _endStart();
    }
  }

  /// Closes every process started by this runner.
  ///
  /// 中文：关闭此 Runner 启动的全部进程并等待输出流收尾；窗口关闭或 Engine
  /// 销毁时必须调用此边界。
  Future<void> closeAll() async {
    final existing = _closeAllFuture;
    if (existing != null) return existing;
    final future = _closeAll();
    _closeAllFuture = future;
    return future;
  }

  void _beginStart() {
    _pendingStarts += 1;
  }

  void _endStart() {
    _pendingStarts -= 1;
    if (_pendingStarts == 0) {
      _pendingStartsCompleter?.complete();
      _pendingStartsCompleter = null;
    }
  }

  Future<void> _waitForPendingStarts() {
    if (_pendingStarts == 0) return Future<void>.value();
    return (_pendingStartsCompleter ??= Completer<void>()).future;
  }

  Future<void> _closeAll() async {
    _isClosing = true;
    try {
      await _waitForPendingStarts();
      await Future.wait<void>([
        for (final run in List<CustomActionRun>.of(_activeRuns)) run.close(),
      ]);
    } finally {
      _isClosing = false;
      _closeAllFuture = null;
    }
  }

  /// Starts a process with literal argv and no inherited environment by default.
  /// 中文：按字面 argv 启动进程，默认不继承父环境且不经过 Shell。
  static Future<Process> _startProcess(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    required bool includeParentEnvironment,
  }) => Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
    includeParentEnvironment: includeParentEnvironment,
    runInShell: false,
    mode: ProcessStartMode.normal,
  );
}

/// Provides the Engine-owned custom-action process lifecycle.
///
/// 中文：提供当前 Flutter Engine 所拥有的自定义操作进程生命周期；Provider 销毁
/// 时执行最后的尽力关闭，正常窗口关闭应优先显式调用 [CustomActionRunner.closeAll]。
final customActionRunnerProvider = Provider<CustomActionRunner>((Ref ref) {
  final runner = CustomActionRunner();
  ref.onDispose(() => unawaited(runner.closeAll()));
  return runner;
});

/// Owns one custom-action process and its bounded output streams.
///
/// 中文：拥有一个自定义操作进程及其有上限的输出流；关闭时终止进程并等待流收尾。
final class CustomActionRun {
  CustomActionRun._({
    required Process process,
    required GitProcessTerminator processTerminator,
    required int outputLimit,
    required void Function() onClosed,
  }) : _process = process,
       _processTerminator = processTerminator,
       _onClosed = onClosed,
       _stdout = _collect(process.stdout, outputLimit),
       _stderr = _collect(process.stderr, outputLimit) {
    _exitCode = _process.exitCode.then((code) {
      _hasExited = true;
      return code;
    });
  }

  final Process _process;
  final GitProcessTerminator _processTerminator;
  final void Function() _onClosed;
  final Future<CustomActionOutput> _stdout;
  final Future<CustomActionOutput> _stderr;
  late final Future<int> _exitCode;
  GitCancellationRegistration? _cancellationRegistration;
  Future<void>? _closeFuture;
  bool _hasExited = false;

  /// Completes with the process exit code.
  /// 中文：返回进程退出码。
  Future<int> get exitCode => _exitCode;

  /// Completes with bounded standard output after the process exits.
  /// 中文：进程退出后返回受上限保护的标准输出。
  Future<CustomActionOutput> get stdout => _stdout;

  /// Completes with bounded standard error after the process exits.
  /// 中文：进程退出后返回受上限保护的标准错误输出。
  Future<CustomActionOutput> get stderr => _stderr;

  /// Whether termination and cleanup have started.
  /// 中文：是否已经开始终止和清理。
  bool get isClosed => _closeFuture != null;

  /// Requests termination and waits for output streams to finish.
  ///
  /// 中文：请求终止进程并等待输出流收尾；可重复调用，是取消、切换仓库和窗口关闭
  /// 时必须经过的生命周期边界。
  Future<void> close() => _closeFuture ??= _closeAndWait();

  /// Connects a caller cancellation token to this run.
  /// 中文：将调用方取消令牌连接到当前进程生命周期。
  void _attachCancellation(GitCancellationToken? token) {
    _cancellationRegistration = token?.register(() {
      unawaited(close());
    });
  }

  Future<void> _closeAndWait() async {
    _cancellationRegistration?.dispose();
    _cancellationRegistration = null;
    try {
      if (!_hasExited) await _processTerminator.terminate(_process);
      await _exitCode;
      await Future.wait<void>([_stdout, _stderr]);
    } finally {
      _onClosed();
    }
  }

  static Future<CustomActionOutput> _collect(
    Stream<List<int>> stream,
    int limit,
  ) async {
    final builder = BytesBuilder(copy: false);
    var truncated = false;
    await for (final chunk in stream) {
      if (builder.length >= limit) {
        truncated = true;
        continue;
      }
      final remaining = limit - builder.length;
      if (chunk.length <= remaining) {
        builder.add(chunk);
      } else {
        builder.add(chunk.sublist(0, remaining));
        truncated = true;
      }
    }
    return CustomActionOutput(
      text: utf8.decode(builder.takeBytes(), allowMalformed: true),
      truncated: truncated,
    );
  }
}

/// Bounded decoded output captured from one custom-action stream.
///
/// 中文：从自定义操作单个输出流捕获的有上限解码结果；截断状态会显式保留。
final class CustomActionOutput {
  const CustomActionOutput({required this.text, required this.truncated});

  final String text;
  final bool truncated;
}
