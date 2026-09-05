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

  test(
    'neutralizes inherited AskPass variables unless explicitly enabled',
    () async {
      final runner = GitRunner(
        executable: '/usr/bin/env',
        baseEnvironment: const {
          'GIT_ASKPASS': '/tmp/untrusted-askpass',
          'SSH_ASKPASS': '/tmp/untrusted-ssh-askpass',
          'GIT_ASKPASS_REQUIRE': 'force',
          'SSH_ASKPASS_REQUIRE': 'force',
        },
      );

      final result = await runner.run(GitInvocation(arguments: const []));

      expect(result.stdoutText, contains('GIT_ASKPASS=\n'));
      expect(result.stdoutText, contains('SSH_ASKPASS=\n'));
      expect(result.stdoutText, contains('GIT_ASKPASS_REQUIRE=never'));
      expect(result.stdoutText, contains('SSH_ASKPASS_REQUIRE=never'));
      expect(result.stdoutText, isNot(contains('/tmp/untrusted-askpass')));
    },
  );

  test('allows an operation-scoped AskPass environment', () async {
    final runner = GitRunner(executable: '/usr/bin/env');
    final result = await runner.run(
      GitInvocation(
        arguments: const [],
        environment: const {
          'GIT_ASKPASS': '/app/git-desktop-askpass',
          'GIT_ASKPASS_REQUIRE': 'force',
        },
      ),
    );

    expect(result.stdoutText, contains('GIT_ASKPASS=/app/git-desktop-askpass'));
    expect(result.stdoutText, contains('GIT_ASKPASS_REQUIRE=force'));
  });

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

  test(
    'escalates cancellation for a running process that ignores TERM',
    () async {
      if (Platform.isWindows) return;
      final cancellationToken = GitCancellationToken();
      final stopwatch = Stopwatch()..start();
      final future = GitRunner(executable: '/bin/sh').run(
        GitInvocation(
          arguments: const ['-c', 'trap "" TERM; sleep 30'],
          cancellationToken: cancellationToken,
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));
      cancellationToken.cancel();
      final result = await future.timeout(const Duration(seconds: 4));

      expect(result.wasCancelled, isTrue);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 4)));
    },
  );

  test('force-kills a descendant that survives its parent TERM', () async {
    if (Platform.isWindows) return;
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'git-runner-descendant-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final marker = File('${temporaryDirectory.path}/child.pid');
    final cancellationToken = GitCancellationToken();
    final future = GitRunner(executable: '/bin/sh').run(
      GitInvocation(
        arguments: [
          '-c',
          'trap "exit 0" TERM; '
              r'''/bin/sh -c 'trap "" TERM; echo $$ > '''
              '${marker.path}; '
              r'''while :; do sleep 1; done' & wait''',
        ],
        cancellationToken: cancellationToken,
      ),
    );
    while (!await marker.exists()) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final childPid = int.parse((await marker.readAsString()).trim());
    addTearDown(() => Process.killPid(childPid, ProcessSignal.sigkill));

    cancellationToken.cancel();
    final result = await future.timeout(const Duration(seconds: 4));

    expect(result.wasCancelled, isTrue);
    expect(Process.killPid(childPid, ProcessSignal.sigcont), isFalse);
  });

  test(
    'kills a tracked descendant after its intermediate parent exits',
    () async {
      if (!Platform.isMacOS && !Platform.isLinux) return;
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'git-runner-reparented-descendant-',
      );
      addTearDown(() => temporaryDirectory.delete(recursive: true));
      final marker = File('${temporaryDirectory.path}/child.pid');
      final cancellationToken = GitCancellationToken();
      final future = GitRunner(executable: '/bin/sh').run(
        GitInvocation(
          arguments: [
            '-c',
            'trap "" TERM; '
                r'''( /bin/sh -c 'trap "" TERM; echo $$ > '''
                '${marker.path}; '
                r'''while :; do sleep 1; done' & sleep 0.06 ) & '''
                'while :; do sleep 1; done',
          ],
          cancellationToken: cancellationToken,
        ),
      );
      while (!await marker.exists()) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final childPid = int.parse((await marker.readAsString()).trim());
      addTearDown(() => Process.killPid(childPid, ProcessSignal.sigkill));

      // Let the intermediate shell exit and the long-lived child be reparented.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      cancellationToken.cancel();
      final result = await future.timeout(const Duration(seconds: 4));

      expect(result.wasCancelled, isTrue);
      expect(Process.killPid(childPid, ProcessSignal.sigcont), isFalse);
    },
  );

  test('cancels every process owned by one runner during shutdown', () async {
    if (Platform.isWindows) return;
    final runner = GitRunner(executable: '/bin/sh');
    final first = runner.run(
      GitInvocation(arguments: const ['-c', 'trap "" TERM; sleep 30']),
    );
    final second = runner.run(
      GitInvocation(arguments: const ['-c', 'trap "" TERM; sleep 30']),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(
      await runner.cancelAllAndWait(timeout: const Duration(seconds: 4)),
      isTrue,
    );
    expect((await first).exitCode, isNot(0));
    expect((await second).exitCode, isNot(0));
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
