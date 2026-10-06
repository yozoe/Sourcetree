import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path_utils;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../git/git_cancellation.dart';
import '../git/git_errors.dart';
import 'external_tool_configuration.dart';
import 'repository_trust.dart';

/// Starts an external executable with a literal argument vector.
///
/// 中文：以字面参数数组启动外部可执行文件；实现不得经由 Shell 解释参数。
typedef ExternalToolProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
    });

/// Creates a private directory used for immutable external-tool snapshots.
///
/// 中文：创建用于不可变外部工具快照的私有目录。
typedef ExternalToolTemporaryDirectoryFactory = Future<Directory> Function();

/// Runs one read-only external Diff request and owns its snapshot lifecycle.
///
/// 中文：执行一次只读外部 Diff 请求并负责其快照生命周期。调用方必须在窗口
/// 关闭、仓库切换或用户取消时关闭返回的 [ExternalToolRun]。
final class ExternalToolRunner {
  ExternalToolRunner({
    ExternalToolProcessStarter? processStarter,
    ExternalToolTemporaryDirectoryFactory? temporaryDirectoryFactory,
    GitProcessTerminator? processTerminator,
  }) : _processStarter = processStarter ?? _startProcess,
       _temporaryDirectoryFactory =
           temporaryDirectoryFactory ?? _createTemporaryDirectory,
       _processTerminator =
           processTerminator ?? const DefaultGitProcessTerminator();

  final ExternalToolProcessStarter _processStarter;
  final ExternalToolTemporaryDirectoryFactory _temporaryDirectoryFactory;
  final GitProcessTerminator _processTerminator;
  final Set<ExternalToolRun> _activeRuns = <ExternalToolRun>{};
  int _pendingStarts = 0;
  Completer<void>? _pendingStartsCompleter;
  Future<void>? _closeAllFuture;
  bool _isClosing = false;

  /// Starts a trusted, explicitly enabled read-only Diff process.
  ///
  /// The two byte arrays are written to a private temporary directory before
  /// the process starts. The directory remains until [ExternalToolRun.close]
  /// so GUI tools that outlive their launcher can continue reading snapshots.
  ///
  /// 中文：启动已信任且明确启用的只读 Diff 进程。两个字节数组会在进程启动前
  /// 写入私有临时目录；目录保持到 [ExternalToolRun.close]，以便独立 GUI 工具
  /// 在启动器退出后仍可读取快照。
  Future<ExternalToolRun> startReadOnlyDiff({
    required ExternalToolConfiguration configuration,
    required RepositoryTrustStatus trustStatus,
    required String repositoryRoot,
    required String repositoryRelativePath,
    required List<int> beforeBytes,
    required List<int> afterBytes,
    GitCancellationToken? cancellationToken,
  }) async {
    if (_isClosing) {
      throw StateError('External tool runner is closing.');
    }
    if (configuration.kind != ExternalToolKind.readOnlyDiff) {
      throw StateError('A read-only Diff configuration is required.');
    }
    if (!canActivateExternalTool(
      trustStatus: trustStatus,
      configuration: configuration,
    )) {
      throw StateError('External Diff is not trusted and explicitly enabled.');
    }
    if (beforeBytes.length > ExternalToolConfiguration.snapshotByteLimit ||
        afterBytes.length > ExternalToolConfiguration.snapshotByteLimit) {
      throw StateError(
        'External Diff snapshots exceed the configured size limit.',
      );
    }
    if (cancellationToken?.isCancelled ?? false) {
      throw const GitCancelledException();
    }

    _beginStart();
    Directory? directory;
    try {
      directory = await _temporaryDirectoryFactory();
      if (cancellationToken?.isCancelled ?? false) {
        throw const GitCancelledException();
      }
      final extension = path_utils.extension(repositoryRelativePath);
      final before = File(
        path_utils.join(directory.path, 'before${_safeExtension(extension)}'),
      );
      final after = File(
        path_utils.join(directory.path, 'after${_safeExtension(extension)}'),
      );
      await before.writeAsBytes(beforeBytes, flush: true);
      await after.writeAsBytes(afterBytes, flush: true);
      if (cancellationToken?.isCancelled ?? false) {
        throw const GitCancelledException();
      }
      final invocation = configuration.buildReadOnlyDiffInvocation(
        beforeSnapshotPath: before.path,
        afterSnapshotPath: after.path,
        repositoryRoot: repositoryRoot,
        repositoryRelativePath: repositoryRelativePath,
      );
      final process = await _processStarter(
        invocation.executablePath,
        invocation.arguments,
        workingDirectory: repositoryRoot,
      );
      late final ExternalToolRun run;
      run = ExternalToolRun._(
        process: process,
        snapshotDirectory: directory,
        processTerminator: _processTerminator,
        onClosed: () => _activeRuns.remove(run),
      );
      _activeRuns.add(run);
      run._attachCancellation(cancellationToken);
      if (_isClosing) {
        await run.close();
        throw StateError('External tool runner is closing.');
      }
      return run;
    } on Object {
      if (directory != null) await _deleteDirectory(directory);
      rethrow;
    } finally {
      _endStart();
    }
  }

  /// Starts a trusted three-way merge tool whose result is written to a
  /// private result file and read back only after a successful exit.
  /// 中文：启动受信任的三方合并工具；仅在进程成功退出后读取私有结果文件。
  Future<ExternalMergeToolRun> startMergeWriteBack({
    required ExternalToolConfiguration configuration,
    required RepositoryTrustStatus trustStatus,
    required String repositoryRoot,
    required String repositoryRelativePath,
    required List<int> baseBytes,
    required List<int> oursBytes,
    required List<int> theirsBytes,
    GitCancellationToken? cancellationToken,
  }) async {
    if (configuration.kind != ExternalToolKind.mergeWriteBack) {
      throw StateError('A merge write-back configuration is required.');
    }
    if (_isClosing) throw StateError('External tool runner is closing.');
    if (!canActivateExternalTool(
      trustStatus: trustStatus,
      configuration: configuration,
    )) {
      throw StateError('External Merge is not trusted and explicitly enabled.');
    }
    final snapshots = <List<int>>[baseBytes, oursBytes, theirsBytes];
    if (snapshots.any(
      (bytes) => bytes.length > ExternalToolConfiguration.snapshotByteLimit,
    )) {
      throw StateError(
        'External Merge snapshots exceed the configured size limit.',
      );
    }
    if (cancellationToken?.isCancelled ?? false) {
      throw const GitCancelledException();
    }
    _beginStart();
    Directory? directory;
    try {
      directory = await _temporaryDirectoryFactory();
      if (cancellationToken?.isCancelled ?? false) {
        throw const GitCancelledException();
      }
      final extension = path_utils.extension(repositoryRelativePath);
      final base = File(
        path_utils.join(directory.path, 'base${_safeExtension(extension)}'),
      );
      final ours = File(
        path_utils.join(directory.path, 'ours${_safeExtension(extension)}'),
      );
      final theirs = File(
        path_utils.join(directory.path, 'theirs${_safeExtension(extension)}'),
      );
      final result = File(
        path_utils.join(directory.path, 'result${_safeExtension(extension)}'),
      );
      await base.writeAsBytes(baseBytes, flush: true);
      await ours.writeAsBytes(oursBytes, flush: true);
      await theirs.writeAsBytes(theirsBytes, flush: true);
      final invocation = configuration.buildMergeInvocation(
        baseSnapshotPath: base.path,
        oursSnapshotPath: ours.path,
        theirsSnapshotPath: theirs.path,
        resultSnapshotPath: result.path,
        repositoryRoot: repositoryRoot,
        repositoryRelativePath: repositoryRelativePath,
      );
      final process = await _processStarter(
        invocation.executablePath,
        invocation.arguments,
        workingDirectory: repositoryRoot,
      );
      late final ExternalToolRun run;
      run = ExternalToolRun._(
        process: process,
        snapshotDirectory: directory,
        processTerminator: _processTerminator,
        onClosed: () => _activeRuns.remove(run),
      );
      _activeRuns.add(run);
      run._attachCancellation(cancellationToken);
      if (_isClosing) {
        await run.close();
        throw StateError('External tool runner is closing.');
      }
      return ExternalMergeToolRun._(run: run, resultFile: result);
    } on Object {
      if (directory != null) await _deleteDirectory(directory);
      rethrow;
    } finally {
      _endStart();
    }
  }

  /// Closes every run started by this runner and waits for snapshot cleanup.
  ///
  /// 中文：关闭此 Runner 启动的全部外部工具并等待快照清理；窗口关闭或仓库
  /// Engine 销毁时应调用此边界。
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
        for (final run in List<ExternalToolRun>.of(_activeRuns)) run.close(),
      ]);
    } finally {
      // Repository switches reuse this runner; the barrier only covers this
      // close cycle and must not permanently disable later Diff launches.
      _isClosing = false;
      _closeAllFuture = null;
    }
  }

  /// Starts one process without shell interpretation or argument rewriting.
  /// 中文：不经 Shell 解释或参数改写地启动一个外部进程。
  static Future<Process> _startProcess(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) => Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    runInShell: false,
    mode: ProcessStartMode.normal,
  );

  /// Creates a private per-run snapshot directory.
  /// 中文：创建一次运行专用的私有快照目录。
  static Future<Directory> _createTemporaryDirectory() =>
      Directory.systemTemp.createTemp('git_desktop_external_diff_');

  /// Keeps only a conservative extension for tools that use file type hints.
  /// 中文：仅保留保守的文件扩展名，供依赖类型提示的工具使用。
  static String _safeExtension(String extension) {
    if (extension.isEmpty ||
        extension.length > 32 ||
        !RegExp(r'^\.[A-Za-z0-9._-]+$').hasMatch(extension)) {
      return '';
    }
    return extension;
  }

  /// Best-effort cleanup used when launching a run fails before ownership is transferred.
  /// 中文：启动失败且所有权尚未转移时执行尽力清理。
  static Future<void> _deleteDirectory(Directory directory) async {
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } on Object {
      // Cleanup is best effort when reporting the original launch failure.
    }
  }
}

/// Provides the external-tool lifecycle owned by one Flutter Engine.
///
/// 中文：提供当前 Flutter Engine 所拥有的外部工具生命周期；Provider 销毁时执行
/// 最后的尽力清理，正常窗口关闭应优先调用 [ExternalToolRunner.closeAll]。
final externalToolRunnerProvider = Provider<ExternalToolRunner>((Ref ref) {
  final runner = ExternalToolRunner();
  ref.onDispose(() => unawaited(runner.closeAll()));
  return runner;
});

/// Owns one external Diff process and the snapshots passed to it.
///
/// 中文：拥有一个外部 Diff 进程及其快照；关闭时终止仍在运行的进程并删除快照。
final class ExternalToolRun {
  ExternalToolRun._({
    required Process process,
    required this.snapshotDirectory,
    required GitProcessTerminator processTerminator,
    required void Function() onClosed,
  }) : _process = process,
       _processTerminator = processTerminator,
       _onClosed = onClosed {
    _exitCode = _process.exitCode.then((code) {
      _hasExited = true;
      return code;
    });
    // Always drain both streams so a verbose tool cannot block on a full pipe.
    unawaited(_process.stdout.drain<void>());
    unawaited(_process.stderr.drain<void>());
  }

  final Process _process;
  final GitProcessTerminator _processTerminator;
  final void Function() _onClosed;
  final Directory snapshotDirectory;
  late final Future<int> _exitCode;
  GitCancellationRegistration? _cancellationRegistration;
  Future<void>? _closeFuture;
  bool _hasExited = false;

  /// The process exit code, available even after [close] has been requested.
  ///
  /// 中文：外部进程退出码；即使已请求 [close] 也可等待得到。
  Future<int> get exitCode => _exitCode;

  /// Whether [close] has started terminating this run.
  ///
  /// 中文：是否已经开始关闭本次运行。
  bool get isClosed => _closeFuture != null;

  /// Requests process termination and removes private snapshots.
  ///
  /// Calling this method repeatedly is safe. It is the required lifecycle
  /// boundary for cancellation, repository switching, and window shutdown.
  ///
  /// 中文：请求终止进程并删除私有快照；可重复调用，是取消、切换仓库和窗口关闭
  /// 时必须经过的生命周期边界。
  Future<void> close() {
    return _closeFuture ??= _closeAndCleanup();
  }

  /// Connects the caller's cancellation boundary to this process lifecycle.
  /// 中文：将调用方取消边界连接到本次进程生命周期。
  void _attachCancellation(GitCancellationToken? token) {
    _cancellationRegistration = token?.register(() {
      unawaited(close());
    });
  }

  /// Terminates the process if needed, waits for exit, and removes snapshots.
  /// 中文：必要时终止进程、等待退出并删除快照。
  Future<void> _closeAndCleanup() async {
    _cancellationRegistration?.dispose();
    _cancellationRegistration = null;
    try {
      if (!_hasExited) {
        await _processTerminator.terminate(_process);
      }
      await _exitCode;
    } finally {
      try {
        if (await snapshotDirectory.exists()) {
          await snapshotDirectory.delete(recursive: true);
        }
      } on Object {
        // A failed cleanup remains observable through the filesystem; it must
        // not hide the process exit or cancellation result.
      } finally {
        _onClosed();
      }
    }
  }
}

/// Owns a merge process and validates its UTF-8 result snapshot.
/// 中文：拥有一次合并进程，并校验其 UTF-8 结果快照。
final class ExternalMergeToolRun {
  ExternalMergeToolRun._({
    required ExternalToolRun run,
    required File resultFile,
  }) : _run = run,
       _resultFile = resultFile;

  final ExternalToolRun _run;
  final File _resultFile;

  Future<int> get exitCode => _run.exitCode;
  bool get isClosed => _run.isClosed;
  Directory get snapshotDirectory => _run.snapshotDirectory;

  /// Waits for successful process completion and returns a bounded UTF-8 result.
  /// 中文：等待进程成功退出并返回有大小上限的 UTF-8 结果。
  Future<String> readResultUtf8() async {
    final code = await exitCode;
    if (code != 0) {
      throw StateError('External Merge exited with status $code.');
    }
    if (await FileSystemEntity.type(_resultFile.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw StateError('External Merge did not produce a result file.');
    }
    final length = await _resultFile.length();
    if (length > ExternalToolConfiguration.snapshotByteLimit) {
      throw StateError(
        'External Merge result exceeds the configured size limit.',
      );
    }
    final bytes = await _resultFile.readAsBytes();
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw StateError('External Merge result is not valid UTF-8.');
    }
  }

  Future<void> close() => _run.close();
}
