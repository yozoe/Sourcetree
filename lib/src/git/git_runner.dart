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
         'GIT_PAGER': 'cat',
         'GIT_TERMINAL_PROMPT': '0',
         'LC_ALL': 'C',
         'LANG': 'C',
         'NO_COLOR': '1',
         ...baseEnvironment,
       });

  final String executable;
  final GitProcessTerminator processTerminator;
  final Map<String, String> baseEnvironment;

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
    final registration = cancellationToken?.register(() {
      if (processHasExited) {
        return;
      }
      terminationRequested = true;
      unawaited(Future<void>.sync(() => processTerminator.terminate(process)));
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

    final exitCode = await process.exitCode;
    processHasExited = true;
    registration?.dispose();
    await Future.wait<void>([stdoutDone, stderrDone]);
    stopwatch.stop();

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
}

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

  Uint8List takeBytes() => _builder.takeBytes();
}
