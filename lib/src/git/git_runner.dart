import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'git_cancellation.dart';
import 'git_errors.dart';

enum GitEnvironmentPolicy { inherit, clean }

final class GitOutputLimit {
  const GitOutputLimit({
    this.stdoutBytes = 16 * 1024 * 1024,
    this.stderrBytes = 2 * 1024 * 1024,
  });

  final int stdoutBytes;
  final int stderrBytes;
}

final class GitInvocation {
  GitInvocation({
    required List<String> arguments,
    this.executable,
    this.workingDirectory,
    Map<String, String> environment = const {},
    this.environmentPolicy = GitEnvironmentPolicy.inherit,
    List<int>? stdinBytes,
    this.outputLimit = const GitOutputLimit(),
    this.cancellationToken,
  }) : arguments = List<String>.unmodifiable(arguments),
       environment = Map<String, String>.unmodifiable(environment),
       stdinBytes = stdinBytes == null
           ? null
           : List<int>.unmodifiable(stdinBytes) {
    if (outputLimit.stdoutBytes < 0 || outputLimit.stderrBytes < 0) {
      throw ArgumentError.value(
        outputLimit,
        'outputLimit',
        'Output limits must not be negative.',
      );
    }
  }

  final String? executable;
  final List<String> arguments;
  final String? workingDirectory;
  final Map<String, String> environment;
  final GitEnvironmentPolicy environmentPolicy;
  final List<int>? stdinBytes;
  final GitOutputLimit outputLimit;
  final GitCancellationToken? cancellationToken;
}

final class GitResult {
  GitResult({
    required this.executable,
    required List<String> arguments,
    required this.workingDirectory,
    required this.exitCode,
    required Uint8List stdoutBytes,
    required Uint8List stderrBytes,
    required this.stdoutTruncated,
    required this.stderrTruncated,
    required this.duration,
    required this.wasCancelled,
    required this.error,
  }) : arguments = List<String>.unmodifiable(arguments),
       stdoutBytes = Uint8List.fromList(stdoutBytes),
       stderrBytes = Uint8List.fromList(stderrBytes);

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
  final int exitCode;
  final Uint8List stdoutBytes;
  final Uint8List stderrBytes;
  final bool stdoutTruncated;
  final bool stderrTruncated;
  final Duration duration;
  final bool wasCancelled;
  final GitCommandError? error;

  bool get isSuccess => exitCode == 0 && !wasCancelled;

  String get stdoutText => utf8.decode(stdoutBytes, allowMalformed: true);

  String get stderrText => utf8.decode(stderrBytes, allowMalformed: true);

  /// 中文：当命令失败或被取消时，抛出包含执行上下文的异常。
  ///
  /// English: Throws an exception with the command context when execution
  /// fails or is cancelled.
  void throwIfFailed({String? operation}) {
    if (!isSuccess) {
      throw GitCommandException(this, operation: operation);
    }
  }
}

/// Executes Git without a shell and captures stdout/stderr as raw bytes.
final class GitRunner {
  GitRunner({
    this.executable = 'git',
    this.processTerminator = const DefaultGitProcessTerminator(),
    Map<String, String> baseEnvironment = const {},
  }) : baseEnvironment = Map<String, String>.unmodifiable({
         ...baseEnvironment,
         'GIT_PAGER': 'cat',
         'GIT_TERMINAL_PROMPT': '0',
         // Do not let an IDE or launching terminal redirect credentials to an
         // unrelated helper. Interactive callers must opt in with the explicit
         // invocation environment supplied by GitAskPassSession.
         'GIT_ASKPASS': '',
         'SSH_ASKPASS': '',
         'GIT_ASKPASS_REQUIRE': 'never',
         'SSH_ASKPASS_REQUIRE': 'never',
         'LC_ALL': 'C',
         'LANG': 'C',
         'NO_COLOR': '1',
       });

  final String executable;
  final GitProcessTerminator processTerminator;
  final Map<String, String> baseEnvironment;
  final Set<Process> _activeProcesses = <Process>{};
  final Map<Process, Object> _processTrackingContexts = <Process, Object>{};
  final Map<Process, Future<void>> _terminationFutures =
      <Process, Future<void>>{};

  /// 中文：终止此 Runner 启动的全部活动 Git 进程，并在指定时限内等待退出。
  ///
  /// English: Terminates every active Git process started by this runner and
  /// waits up to [timeout] for their exit.
  Future<bool> cancelAllAndWait({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final processes = List<Process>.of(_activeProcesses);
    if (processes.isEmpty) return true;
    try {
      await Future.wait<void>([
        for (final process in processes)
          Future<void>.sync(() async {
            await _terminateProcess(process);
            await process.exitCode;
          }),
      ]).timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  /// 中文：在不经 Shell 的情况下执行 Git，并在输出上限内收集原始标准输出和错误输出。
  ///
  /// English: Runs Git without a shell and captures raw standard output and
  /// error output within the configured limits.
  Future<GitResult> run(GitInvocation invocation) async {
    final cancellationToken = invocation.cancellationToken;
    if (cancellationToken?.isCancelled ?? false) {
      throw const GitCancelledException();
    }

    final command = invocation.executable ?? executable;
    final stopwatch = Stopwatch()..start();
    final Process process;
    try {
      process = await Process.start(
        command,
        invocation.arguments,
        workingDirectory: invocation.workingDirectory,
        environment: {...baseEnvironment, ...invocation.environment},
        includeParentEnvironment:
            invocation.environmentPolicy == GitEnvironmentPolicy.inherit,
        runInShell: false,
        mode: ProcessStartMode.normal,
      );
      _activeProcesses.add(process);
      final terminator = processTerminator;
      if (terminator is GitTrackedProcessTerminator) {
        _processTrackingContexts[process] =
            (terminator as GitTrackedProcessTerminator).track(process);
      }
    } on ProcessException catch (error) {
      stopwatch.stop();
      throw GitProcessStartException(
        executable: command,
        kind: _classifyStartFailure(
          error,
          workingDirectory: invocation.workingDirectory,
        ),
        message: error.message,
        osErrorCode: error.errorCode,
      );
    }

    var terminationRequested = false;
    var processHasExited = false;
    Future<void>? terminationFuture;
    final registration = cancellationToken?.register(() {
      if (processHasExited) {
        return;
      }
      terminationRequested = true;
      terminationFuture = _terminateProcess(process);
    });

    final stdoutCollector = _LimitedByteCollector(
      invocation.outputLimit.stdoutBytes,
    );
    final stderrCollector = _LimitedByteCollector(
      invocation.outputLimit.stderrBytes,
    );
    final stdoutDone = process.stdout
        .listen(stdoutCollector.add)
        .asFuture<void>();
    final stderrDone = process.stderr
        .listen(stderrCollector.add)
        .asFuture<void>();

    try {
      final stdinBytes = invocation.stdinBytes;
      if (stdinBytes != null && stdinBytes.isNotEmpty) {
        process.stdin.add(stdinBytes);
      }
      await process.stdin.close();
    } on IOException {
      // A command may exit before consuming all stdin. Its exit status and
      // stderr remain the authoritative result.
    } on StateError {
      // The process may already have closed its stdin.
    }

    final int exitCode;
    try {
      exitCode = await process.exitCode;
      processHasExited = true;
      registration?.dispose();
      await terminationFuture;
      await Future.wait<void>([stdoutDone, stderrDone]);
      stopwatch.stop();
    } finally {
      registration?.dispose();
      _activeProcesses.remove(process);
      final trackingContext = _processTrackingContexts.remove(process);
      final terminator = processTerminator;
      if (trackingContext != null &&
          terminator is GitTrackedProcessTerminator) {
        await (terminator as GitTrackedProcessTerminator).stopTracking(
          trackingContext,
        );
      }
      _terminationFutures.remove(process);
    }

    final stdoutBytes = stdoutCollector.takeBytes();
    final stderrBytes = stderrCollector.takeBytes();
    final error = _classifyCommandFailure(
      exitCode: exitCode,
      stderrBytes: stderrBytes,
      wasCancelled: terminationRequested,
    );
    return GitResult(
      executable: command,
      arguments: invocation.arguments,
      workingDirectory: invocation.workingDirectory,
      exitCode: exitCode,
      stdoutBytes: stdoutBytes,
      stderrBytes: stderrBytes,
      stdoutTruncated: stdoutCollector.wasTruncated,
      stderrTruncated: stderrCollector.wasTruncated,
      duration: stopwatch.elapsed,
      wasCancelled: terminationRequested,
      error: error,
    );
  }

  /// 中文：复用同一进程的终止任务，并在可用时携带已提前采集的进程树身份。
  ///
  /// English: Reuses one termination task per process and supplies the
  /// proactively captured process-tree identities when available.
  Future<void> _terminateProcess(Process process) {
    return _terminationFutures.putIfAbsent(process, () async {
      final terminator = processTerminator;
      final context = _processTrackingContexts[process];
      if (context != null && terminator is GitTrackedProcessTerminator) {
        await (terminator as GitTrackedProcessTerminator).terminateTracked(
          process,
          context,
        );
      } else {
        await terminator.terminate(process);
      }
    });
  }
}

/// 中文：对输入结果进行分类。
/// English: Classifies the input result.
GitErrorKind _classifyStartFailure(
  ProcessException error, {
  required String? workingDirectory,
}) {
  final message = error.message.toLowerCase();
  if (workingDirectory != null && !Directory(workingDirectory).existsSync()) {
    return GitErrorKind.workingDirectoryNotFound;
  }
  if (error.errorCode == 2 || message.contains('no such file')) {
    return GitErrorKind.executableNotFound;
  }
  if (error.errorCode == 13 || message.contains('permission denied')) {
    return GitErrorKind.permissionDenied;
  }
  return GitErrorKind.unknown;
}

GitCommandError? _classifyCommandFailure({
  required int exitCode,
  required Uint8List stderrBytes,
  required bool wasCancelled,
}) {
  if (exitCode == 0 && !wasCancelled) {
    return null;
  }
  final message = utf8.decode(stderrBytes, allowMalformed: true).trim();
  final normalized = message.toLowerCase();
  final kind = switch (normalized) {
    _ when wasCancelled => GitErrorKind.cancelled,
    _ when normalized.contains('not a git repository') =>
      GitErrorKind.notARepository,
    _ when normalized.contains('dubious ownership') =>
      GitErrorKind.unsafeRepository,
    _
        when normalized.contains('index.lock') ||
            normalized.contains('another git process') =>
      GitErrorKind.indexLocked,
    _
        when normalized.contains('authentication failed') ||
            normalized.contains('could not read username') ||
            normalized.contains('permission denied (publickey)') =>
      GitErrorKind.authentication,
    _
        when normalized.contains('not authorized') ||
            normalized.contains('authorization failed') ||
            normalized.contains('the requested url returned error: 403') =>
      GitErrorKind.authorization,
    _
        when normalized.contains('could not resolve host') ||
            normalized.contains('failed to connect') ||
            normalized.contains('network is unreachable') =>
      GitErrorKind.network,
    _
        when normalized.contains('conflict') ||
            normalized.contains('unmerged files') =>
      GitErrorKind.conflicts,
    _
        when normalized.contains('unknown revision') ||
            normalized.contains('bad revision') ||
            normalized.contains('ambiguous argument') =>
      GitErrorKind.invalidRevision,
    _ => GitErrorKind.unknown,
  };
  return GitCommandError(
    kind: kind,
    message: message.isEmpty ? 'Git exited with code $exitCode.' : message,
    exitCode: exitCode,
  );
}

final class _LimitedByteCollector {
  _LimitedByteCollector(this.limit);

  final int limit;
  final BytesBuilder _builder = BytesBuilder(copy: false);
  bool wasTruncated = false;

  /// 中文：追加字节块；超过上限时保留已收集内容并标记为截断。
  ///
  /// English: Appends a byte chunk, retaining collected data and marking it
  /// truncated when the configured limit is exceeded.
  void add(List<int> chunk) {
    final remaining = limit - _builder.length;
    if (remaining <= 0) {
      if (chunk.isNotEmpty) {
        wasTruncated = true;
      }
      return;
    }
    if (chunk.length <= remaining) {
      _builder.add(chunk);
      return;
    }
    _builder.add(chunk.take(remaining).toList(growable: false));
    wasTruncated = true;
  }

  /// 中文：取出当前已收集的字节，并重置内部缓冲区。
  ///
  /// English: Returns the collected bytes and clears the internal buffer.
  Uint8List takeBytes() => _builder.takeBytes();
}
