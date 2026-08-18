import 'git_runner.dart';

enum GitErrorKind {
  cancelled,
  executableNotFound,
  workingDirectoryNotFound,
  permissionDenied,
  notARepository,
  invalidRevision,
  indexLocked,
  conflicts,
  authentication,
  authorization,
  network,
  unsafeRepository,
  unknown,
}

final class GitCommandError {
  const GitCommandError({
    required this.kind,
    required this.message,
    required this.exitCode,
  });

  final GitErrorKind kind;
  final String message;
  final int exitCode;
}

class GitException implements Exception {
  const GitException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

final class GitProcessStartException extends GitException {
  const GitProcessStartException({
    required this.executable,
    required this.kind,
    required String message,
    this.osErrorCode,
  }) : super(message);

  final String executable;
  final GitErrorKind kind;
  final int? osErrorCode;
}

final class GitCancelledException extends GitException {
  const GitCancelledException() : super('Git invocation was cancelled.');
}

final class GitCommandException extends GitException {
  GitCommandException(this.result, {String? operation})
    : super(
        [
          if (operation != null) '$operation failed.',
          result.error?.message ?? 'Git exited with code ${result.exitCode}.',
        ].join(' '),
      );

  final GitResult result;

  GitErrorKind get kind => result.error?.kind ?? GitErrorKind.unknown;
}

final class GitParseException extends GitException {
  const GitParseException(super.message, {this.recordIndex});

  final int? recordIndex;
}
