import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/app/custom_action_configuration.dart';
import 'package:git_desktop/src/app/custom_action_runner.dart';
import 'package:git_desktop/src/app/repository_trust.dart';
import 'package:git_desktop/src/git/git_cancellation.dart';
import 'package:git_desktop/src/git/git_errors.dart';

void main() {
  test(
    'launches literal argv with an isolated environment and repository cwd',
    () async {
      if (Platform.isWindows) return;
      final root = await Directory.systemTemp.createTemp(
        'custom-action-runner-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final marker = File('${root.path}/argv.txt');
      final cwd = File('${root.path}/cwd.txt');
      final lang = File('${root.path}/lang.txt');
      final inherited = File('${root.path}/inherited.txt');
      final executable = await _writeScript(root, 'record.sh', '''#!/bin/sh
printf '%s\\n' "\$@" > "${marker.path}"
pwd > "${cwd.path}"
printf '%s' "\${LANG-unset}" > "${lang.path}"
printf '%s' "\${CUSTOM_ACTION_TEST_SECRET-unset}" > "${inherited.path}"
''');
      final configuration = _configuration(
        executable,
        arguments: const ['--repository', '{repository}', '--path', '{path}'],
        scope: CustomActionScope.selectedFile,
        environment: const <String, String>{'LANG': 'C'},
      );
      final run = await CustomActionRunner().start(
        configuration: configuration,
        trustStatus: RepositoryTrustStatus.trusted,
        target: CustomActionTarget.selectedFile(
          repositoryRoot: root.path,
          repositoryRelativePath: 'lib/a file.dart',
        ),
      );
      expect(await run.exitCode, 0);
      expect(await marker.readAsLines(), <String>[
        '--repository',
        root.path,
        '--path',
        'lib/a file.dart',
      ]);
      expect(
        (await cwd.readAsString()).trim(),
        await root.resolveSymbolicLinks(),
      );
      expect((await lang.readAsString()).trim(), 'C');
      expect((await inherited.readAsString()).trim(), 'unset');
      expect((await run.stdout).truncated, isFalse);
      await run.close();
    },
  );

  test(
    'cancellation terminates the process and closeAll clears active runs',
    () async {
      if (Platform.isWindows) return;
      final root = await Directory.systemTemp.createTemp(
        'custom-action-cancel-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final marker = File('${root.path}/started');
      final executable = await _writeScript(root, 'wait.sh', '''#!/bin/sh
printf started > "${marker.path}"
sleep 10
''');
      final token = GitCancellationToken();
      final runner = CustomActionRunner();
      final run = await runner.start(
        configuration: _configuration(executable),
        trustStatus: RepositoryTrustStatus.trusted,
        target: CustomActionTarget.repository(repositoryRoot: root.path),
        cancellationToken: token,
      );
      for (
        var attempt = 0;
        attempt < 100 && !await marker.exists();
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(await marker.exists(), isTrue);
      token.cancel();
      await runner.closeAll();
      expect(run.isClosed, isTrue);
    },
  );

  test(
    'closeAll waits for an in-flight start and closes its process',
    () async {
      if (Platform.isWindows) return;
      final root = await Directory.systemTemp.createTemp('custom-action-race-');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final executable = await _writeScript(
        root,
        'wait.sh',
        '#!/bin/sh\nsleep 10\n',
      );
      final startGate = Completer<void>();
      final runner = CustomActionRunner(
        processStarter:
            (
              executable,
              arguments, {
              workingDirectory,
              environment,
              required includeParentEnvironment,
            }) async {
              await startGate.future;
              return Process.start(
                executable,
                arguments,
                workingDirectory: workingDirectory,
                environment: environment,
                includeParentEnvironment: includeParentEnvironment,
                runInShell: false,
              );
            },
      );
      final start = runner.start(
        configuration: _configuration(executable),
        trustStatus: RepositoryTrustStatus.trusted,
        target: CustomActionTarget.repository(repositoryRoot: root.path),
      );
      final closing = runner.closeAll();
      startGate.complete();

      await expectLater(start, throwsStateError);
      await closing;
    },
  );

  test('bounds captured output and preserves truncation', () async {
    if (Platform.isWindows) return;
    final root = await Directory.systemTemp.createTemp('custom-action-output-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final executable = await _writeScript(
      root,
      'output.sh',
      '#!/bin/sh\nprintf \'1234567890\'\nprintf \'error\' >&2\n',
    );
    final run = await CustomActionRunner(outputLimit: 5).start(
      configuration: _configuration(executable),
      trustStatus: RepositoryTrustStatus.trusted,
      target: CustomActionTarget.repository(repositoryRoot: root.path),
    );
    expect(await run.exitCode, 0);
    final stdout = await run.stdout;
    final stderr = await run.stderr;
    expect(stdout.text, '12345');
    expect(stdout.truncated, isTrue);
    expect(stderr.text, 'error');
    expect(stderr.truncated, isFalse);
    await run.close();
  });

  test(
    'requires trust, explicit enablement, and a live cancellation token',
    () async {
      final executable = Platform.isWindows ? r'C:\tool.exe' : '/tool';
      final runner = CustomActionRunner();
      final disabled = CustomActionConfiguration(
        id: 'test-action',
        displayName: 'Test Action',
        executablePath: executable,
        arguments: const <String>['{repository}'],
        scope: CustomActionScope.repository,
        enabled: false,
      );
      await expectLater(
        runner.start(
          configuration: disabled,
          trustStatus: RepositoryTrustStatus.trusted,
          target: CustomActionTarget.repository(repositoryRoot: '/repo'),
        ),
        throwsStateError,
      );
      await expectLater(
        runner.start(
          configuration: _configuration(executable),
          trustStatus: RepositoryTrustStatus.unconfirmed,
          target: CustomActionTarget.repository(repositoryRoot: '/repo'),
        ),
        throwsStateError,
      );
      final token = GitCancellationToken()..cancel();
      await expectLater(
        runner.start(
          configuration: _configuration(executable),
          trustStatus: RepositoryTrustStatus.trusted,
          target: CustomActionTarget.repository(repositoryRoot: '/repo'),
          cancellationToken: token,
        ),
        throwsA(isA<GitCancelledException>()),
      );
    },
  );
}

CustomActionConfiguration _configuration(
  String executable, {
  List<String>? arguments,
  CustomActionScope scope = CustomActionScope.repository,
  Map<String, String> environment = const <String, String>{},
}) => CustomActionConfiguration(
  id: 'test-action',
  displayName: 'Test Action',
  executablePath: executable,
  arguments: arguments ?? const <String>['{repository}'],
  scope: scope,
  environment: environment,
  enabled: true,
);

Future<String> _writeScript(Directory root, String name, String source) async {
  final file = File('${root.path}/$name');
  await file.writeAsString(source);
  final result = await Process.run('chmod', <String>['+x', file.path]);
  expect(result.exitCode, 0);
  return file.path;
}
