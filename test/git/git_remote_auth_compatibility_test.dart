import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/git/git_runner.dart';

void main() {
  final remoteUrl = Platform.environment['GIT_DESKTOP_AUTH_TEST_URL']?.trim();
  final expectedRef = Platform.environment['GIT_DESKTOP_AUTH_TEST_EXPECTED_REF']
      ?.trim();
  final authMode = Platform.environment['GIT_DESKTOP_AUTH_TEST_MODE']
      ?.trim()
      .toLowerCase();
  final enabled =
      remoteUrl != null &&
      remoteUrl.isNotEmpty &&
      expectedRef != null &&
      expectedRef.isNotEmpty;

  test(
    'verifies a configured real remote authentication chain',
    () async {
      final url = _requireCredentialFreeRemoteUrl(remoteUrl!);
      final ref = _requireExpectedRef(expectedRef!);
      final mode = authMode == null || authMode.isEmpty
          ? 'unspecified'
          : authMode;
      await _validateAuthMode(mode);
      final result = await GitRunner().run(
        GitInvocation(
          arguments: <String>['--no-pager', 'ls-remote', url],
          environmentPolicy: GitEnvironmentPolicy.inherit,
        ),
      );

      expect(
        result.isSuccess,
        isTrue,
        reason:
            'The configured $mode authentication chain could not read the remote.',
      );
      expect(
        result.stdoutText.split('\n').any((line) {
          final fields = line.split('\t');
          return fields.length == 2 && fields[1].trim() == ref;
        }),
        isTrue,
        reason: 'The authenticated remote did not expose the expected ref.',
      );
    },
    skip: enabled
        ? null
        : 'Set GIT_DESKTOP_AUTH_TEST_URL and '
              'GIT_DESKTOP_AUTH_TEST_EXPECTED_REF to run against a controlled remote.',
  );

  test('rejects credential-bearing and signed remote URL forms', () {
    for (final value in <String>[
      'https://user:password@example.com/repository.git',
      'https://example.com/repository.git?token=secret',
      'https://example.com/repository.git#signed-fragment',
      'ssh://git:password@example.com/repository.git',
      'user:password@example.com:repository.git',
      'https://example.com/repository.git\t',
      'https://example.com/repository.git\u0000',
    ]) {
      expect(
        () => _requireCredentialFreeRemoteUrl(value),
        throwsA(isA<FormatException>()),
        reason: 'Expected unsafe authentication URL to be rejected: $value',
      );
    }
  });

  test('accepts credential-free HTTP and SSH remote URL forms', () {
    expect(
      _requireCredentialFreeRemoteUrl('https://example.com/repository.git'),
      'https://example.com/repository.git',
    );
    expect(
      _requireCredentialFreeRemoteUrl('ssh://git@example.com/repository.git'),
      'ssh://git@example.com/repository.git',
    );
    expect(
      _requireCredentialFreeRemoteUrl('git@example.com:team/repository.git'),
      'git@example.com:team/repository.git',
    );
  });

  test('rejects control characters in the expected ref', () {
    for (final value in <String>[
      'refs/heads/main\n',
      'refs/heads/main\r',
      'refs/heads/main\t',
    ]) {
      expect(
        () => _requireExpectedRef(value),
        throwsA(isA<FormatException>()),
        reason: 'Expected ref must not contain control characters: $value',
      );
    }
    expect(_requireExpectedRef('HEAD'), 'HEAD');
    expect(_requireExpectedRef('refs/heads/main'), 'refs/heads/main');
  });

  test(
    'rejects an unknown authentication mode before contacting Git',
    () async {
      await expectLater(
        _validateAuthMode('browser-token'),
        throwsA(isA<FormatException>()),
      );
    },
  );
}

/// Verifies the locally selected authentication precondition without exposing
/// credentials or remote details in test output.
///
/// 中文：在发起真实远端读取前验证本机选择的认证前置条件；不输出凭据、远端地址
/// 或 Git 错误详情。该检查只证明测试环境已配置，不替代远端成功结果本身。
Future<void> _validateAuthMode(String mode) async {
  switch (mode) {
    case 'unspecified':
      return;
    case 'ssh-agent':
      final socketPath = Platform.environment['SSH_AUTH_SOCK']?.trim();
      if (socketPath == null || socketPath.isEmpty) {
        throw StateError(
          'GIT_DESKTOP_AUTH_TEST_MODE=ssh-agent requires SSH_AUTH_SOCK.',
        );
      }
      final socketType = FileSystemEntity.typeSync(
        socketPath,
        followLinks: true,
      );
      if (socketType != FileSystemEntityType.unixDomainSock) {
        throw StateError(
          'GIT_DESKTOP_AUTH_TEST_MODE=ssh-agent requires a live Unix socket.',
        );
      }
      return;
    case 'keychain':
      final result = await GitRunner().run(
        GitInvocation(
          arguments: const ['config', '--get-all', 'credential.helper'],
          environmentPolicy: GitEnvironmentPolicy.inherit,
        ),
      );
      final helpers = result.stdoutText
          .split('\n')
          .map((line) => line.trim().toLowerCase())
          .where((line) => line.isNotEmpty);
      final hasAppleKeychain = helpers.any(
        (helper) =>
            helper == 'osxkeychain' ||
            helper.endsWith('/git-credential-osxkeychain') ||
            helper.endsWith('git-credential-osxkeychain'),
      );
      if (!result.isSuccess || !hasAppleKeychain) {
        throw StateError(
          'GIT_DESKTOP_AUTH_TEST_MODE=keychain requires the osxkeychain credential helper.',
        );
      }
      return;
    case 'sso':
      // SSO providers expose different helpers and browser flows. The
      // authenticated ls-remote below is the portable verification boundary.
      return;
    default:
      throw FormatException(
        'GIT_DESKTOP_AUTH_TEST_MODE must be keychain, ssh-agent, or sso.',
      );
  }
}

/// Rejects credential-bearing or signed-query URLs before they reach Git.
/// 中文：在受控认证测试把地址传给 Git 前拒绝内嵌凭据和签名查询串，避免验证脚本
/// 反而把秘密写入参数、配置或错误上下文。
String _requireCredentialFreeRemoteUrl(String value) {
  if (RegExp(r'[\x00-\x1F\x7F]').hasMatch(value)) {
    throw const FormatException('The authentication test URL is invalid.');
  }
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw const FormatException('The authentication test URL is invalid.');
  }
  final uri = Uri.tryParse(normalized);
  if (uri != null && uri.hasScheme) {
    final scheme = uri.scheme.toLowerCase();
    final isHttpLike = const {'http', 'https', 'ftp', 'ftps'}.contains(scheme);
    if ((isHttpLike && uri.userInfo.isNotEmpty) ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException(
        'The authentication test URL must not contain credentials or query data.',
      );
    }
    try {
      if (Uri.decodeComponent(uri.userInfo).contains(':')) {
        throw const FormatException(
          'The authentication test URL must not contain a password.',
        );
      }
    } on FormatException {
      throw const FormatException('The authentication test URL is invalid.');
    }
  }
  if (RegExp(r'^[^/@\s:]+:[^/@\s]+@[^/:\s]+:').hasMatch(normalized)) {
    throw const FormatException(
      'The authentication test URL must not contain a password.',
    );
  }
  return normalized;
}

/// Validates the exact ref used by the controlled authentication assertion.
/// 中文：校验受控认证断言使用的精确 ref，拒绝控制字符以避免环境变量造成
/// 多行或不可见断言歧义，但保留 `HEAD` 和普通 `refs/...` 形式。
String _requireExpectedRef(String value) {
  if (RegExp(r'[\x00-\x1F\x7F]').hasMatch(value)) {
    throw const FormatException('The expected ref is invalid.');
  }
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw const FormatException('The expected ref is invalid.');
  }
  return normalized;
}
