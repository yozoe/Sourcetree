import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/git/git.dart';

void main() {
  test('passes stdin and captures stdout as bytes', () async {
    final runner = GitRunner();
    final result = await runner.run(
      GitInvocation(
        arguments: const ['hash-object', '--stdin'],
        stdinBytes: const [0, 255, 97, 98, 99],
      ),
    );

    expect(result.isSuccess, isTrue);
    expect(result.stdoutBytes, isNotEmpty);
    expect(
      utf8.decode(result.stdoutBytes).trim(),
      matches(RegExp(r'^[0-9a-f]{40,64}$')),
    );
  });

  test('passes an explicit environment without a shell', () async {
    final runner = GitRunner();
    final result = await runner.run(
      GitInvocation(
        arguments: const ['var', 'GIT_AUTHOR_IDENT'],
        environment: const {
          'GIT_AUTHOR_NAME': 'Environment Author',
          'GIT_AUTHOR_EMAIL': 'environment@example.invalid',
          'GIT_AUTHOR_DATE': '2026-08-18T00:00:00Z',
        },
      ),
    );

    expect(result.isSuccess, isTrue);
    expect(
      result.stdoutText,
      startsWith('Environment Author <environment@example.invalid> '),
    );
  });

  test(
    'preserves an SSH agent socket environment for Git subprocesses',
    () async {
      final runner = GitRunner(
        executable: '/usr/bin/env',
        baseEnvironment: const {'SSH_AUTH_SOCK': '/tmp/git-desktop-test-agent'},
      );
      final result = await runner.run(GitInvocation(arguments: const []));

      expect(result.isSuccess, isTrue);
      expect(
        result.stdoutText,
        contains('SSH_AUTH_SOCK=/tmp/git-desktop-test-agent'),
      );
    },
  );

  test(
    'allows configured credential helpers before terminal prompting',
    () async {
      final result = await GitRunner().run(
        GitInvocation(
          arguments: const [
            '-c',
            'credential.helper=!f() { printf "username=helper-user\\n\\n"; }; f',
            'credential',
            'fill',
          ],
          stdinBytes: utf8.encode('protocol=https\nhost=example.test\n\n'),
        ),
      );

      // The deliberately incomplete helper supplies only a username, after
      // which Git correctly refuses hidden terminal prompting. Its username in
      // the error proves the configured helper ran first.
      expect(result.isSuccess, isFalse);
      expect(result.stderrText, contains('helper-user@example.test'));
      expect(result.stderrText, contains('could not read Password'));
    },
  );

  test('classifies a non-repository failure', () async {
    final outside = await Directory.systemTemp.createTemp(
      'git_runner_outside_',
    );
    addTearDown(() async {
      if (outside.existsSync()) {
        await outside.delete(recursive: true);
      }
    });

    final result = await GitRunner().run(
      GitInvocation(
        arguments: const ['status', '--porcelain=v2'],
        workingDirectory: outside.path,
      ),
    );

    expect(result.isSuccess, isFalse);
    expect(result.error?.kind, GitErrorKind.notARepository);
    expect(
      () => result.throwIfFailed(operation: 'Test status'),
      throwsA(
        isA<GitCommandException>().having(
          (error) => error.kind,
          'kind',
          GitErrorKind.notARepository,
        ),
      ),
    );
  });

  test('does not start when cancellation was already requested', () async {
    final cancellationToken = GitCancellationToken()..cancel();

    expect(
      () => GitRunner().run(
        GitInvocation(
          arguments: const ['--version'],
          cancellationToken: cancellationToken,
        ),
      ),
      throwsA(isA<GitCancelledException>()),
    );
  });

  test('classifies a missing executable at process start', () async {
    final runner = GitRunner(
      executable: 'git-desktop-definitely-not-an-executable',
    );

    expect(
      () => runner.run(GitInvocation(arguments: const ['--version'])),
      throwsA(
        isA<GitProcessStartException>().having(
          (error) => error.kind,
          'kind',
          GitErrorKind.executableNotFound,
        ),
      ),
    );
  });

  test('distinguishes a missing working directory', () async {
    final missingDirectory =
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'git-desktop-directory-that-does-not-exist';

    expect(
      () => GitRunner().run(
        GitInvocation(
          arguments: const ['--version'],
          workingDirectory: missingDirectory,
        ),
      ),
      throwsA(
        isA<GitProcessStartException>().having(
          (error) => error.kind,
          'kind',
          GitErrorKind.workingDirectoryNotFound,
        ),
      ),
    );
  });
}
