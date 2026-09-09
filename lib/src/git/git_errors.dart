import 'git_runner.dart';

/// Stable categories used to classify Git process and command failures.
///
/// 中文：用于归类 Git 进程与命令失败的稳定错误类型。
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

/// A classified non-zero Git command result.
///
/// 中文：已分类的非零 Git 命令结果。
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

/// Base exception for safe Git operations.
///
/// 中文：安全 Git 操作使用的基础异常类型。
class GitException implements Exception {
  const GitException(this.message);

  final String message;

  /// 中文：返回该对象的字符串表示。
  /// English: Returns this object's string representation.
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
