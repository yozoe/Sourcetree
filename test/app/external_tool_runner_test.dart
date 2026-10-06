import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/app/external_tool_configuration.dart';
import 'package:git_desktop/src/app/external_tool_runner.dart';
import 'package:git_desktop/src/app/repository_session.dart';
import 'package:git_desktop/src/app/repository_trust.dart';
import 'package:git_desktop/src/git/git_cancellation.dart';

import '../support/git_test_repository.dart';

void main() {
  test('launches literal argv and removes snapshots only on close', () async {
    if (Platform.isWindows) return;
    final root = await Directory.systemTemp.createTemp('external-tool-runner-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final marker = File('${root.path}/argv.txt');
    final beforeCopy = File('${root.path}/before-copy');
    final afterCopy = File('${root.path}/after-copy');
    final executable = await _writeScript(root, 'record.sh', '''#!/bin/sh
printf '%s\\n' "\$@" > "${marker.path}"
cat "\$2" > "${beforeCopy.path}"
cat "\$4" > "${afterCopy.path}"
''');
    final run = await ExternalToolRunner().startReadOnlyDiff(
      configuration: _configuration(executable),
      trustStatus: RepositoryTrustStatus.trusted,
      repositoryRoot: root.path,
      repositoryRelativePath: 'lib/a file.dart',
      beforeBytes: <int>[1, 2, 3],
      afterBytes: <int>[4, 5, 6],
    );

    expect(await run.exitCode, 0);
    final argv = await marker.readAsLines();
    expect(argv, hasLength(6));
    expect(argv[0], '--before');
    expect(argv[1], contains('/before.dart'));
    expect(argv[2], '--after');
    expect(argv[3], contains('/after.dart'));
    expect(argv[4], '--path');
    expect(argv[5], 'lib/a file.dart');
    expect(await beforeCopy.readAsBytes(), <int>[1, 2, 3]);
    expect(await afterCopy.readAsBytes(), <int>[4, 5, 6]);
    final snapshotDirectory = run.snapshotDirectory;
    expect(await snapshotDirectory.exists(), isTrue);
    await run.close();
    expect(await snapshotDirectory.exists(), isFalse);
  });

  test('cancellation terminates the process and cleans snapshots', () async {
    if (Platform.isWindows) return;
    final root = await Directory.systemTemp.createTemp('external-tool-cancel-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final marker = File('${root.path}/started');
    final executable = await _writeScript(root, 'wait.sh', '''#!/bin/sh
printf started > "${marker.path}"
sleep 10
''');
    final token = GitCancellationToken();
    final run = await ExternalToolRunner().startReadOnlyDiff(
      configuration: _configuration(executable),
      trustStatus: RepositoryTrustStatus.trusted,
      repositoryRoot: root.path,
      repositoryRelativePath: 'README.md',
      beforeBytes: <int>[1],
      afterBytes: <int>[2],
      cancellationToken: token,
    );
    for (var attempt = 0; attempt < 100 && !await marker.exists(); attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await marker.exists(), isTrue);
    final snapshotDirectory = run.snapshotDirectory;
    token.cancel();
    await run.close();
    expect(run.isClosed, isTrue);
    expect(await snapshotDirectory.exists(), isFalse);
  });

  test('closeAll provides the workspace shutdown lifecycle boundary', () async {
    if (Platform.isWindows) return;
    final root = await Directory.systemTemp.createTemp(
      'external-tool-close-all-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final executable = await _writeScript(
      root,
      'quick.sh',
      '#!/bin/sh\nexit 0\n',
    );
    final runner = ExternalToolRunner();
    final run = await runner.startReadOnlyDiff(
      configuration: _configuration(executable),
      trustStatus: RepositoryTrustStatus.trusted,
      repositoryRoot: root.path,
      repositoryRelativePath: 'README.md',
      beforeBytes: <int>[1],
      afterBytes: <int>[2],
    );
    final snapshotDirectory = run.snapshotDirectory;
    await runner.closeAll();
    expect(await snapshotDirectory.exists(), isFalse);
    expect(run.isClosed, isTrue);
  });

  test('closeAll waits for an in-flight process start', () async {
    if (Platform.isWindows) return;
    final root = await Directory.systemTemp.createTemp('external-tool-race-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final executable = await _writeScript(
      root,
      'wait.sh',
      '#!/bin/sh\nsleep 10\n',
    );
    final startGate = Completer<void>();
    final runner = ExternalToolRunner(
      processStarter: (executable, arguments, {workingDirectory}) async {
        await startGate.future;
        return Process.start(
          executable,
          arguments,
          workingDirectory: workingDirectory,
          runInShell: false,
        );
      },
    );
    final start = runner.startReadOnlyDiff(
      configuration: _configuration(executable),
      trustStatus: RepositoryTrustStatus.trusted,
      repositoryRoot: root.path,
      repositoryRelativePath: 'README.md',
      beforeBytes: <int>[1],
      afterBytes: <int>[2],
    );
    final closing = runner.closeAll();
    startGate.complete();

    await expectLater(start, throwsStateError);
    await closing;
  });

  test('repository shutdown closes Engine-owned external Diff runs', () async {
    if (Platform.isWindows) return;
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    await repository.commit('base');
    final executable = await _writeScript(
      repository.rootDirectory,
      'wait-for-shutdown.sh',
      '#!/bin/sh\nsleep 10\n',
    );
    final runner = ExternalToolRunner();
    final container = ProviderContainer(
      overrides: [externalToolRunnerProvider.overrideWithValue(runner)],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    final run = await runner.startReadOnlyDiff(
      configuration: _configuration(executable),
      trustStatus: RepositoryTrustStatus.trusted,
      repositoryRoot: repository.workingDirectory.path,
      repositoryRelativePath: 'README.md',
      beforeBytes: <int>[1],
      afterBytes: <int>[2],
    );
    final snapshotDirectory = run.snapshotDirectory;
    await controller.prepareForShutdown();
    expect(run.isClosed, isTrue);
    expect(await snapshotDirectory.exists(), isFalse);
  });

  test(
    'requires trust and explicit opt-in before creating snapshots',
    () async {
      final root = await Directory.systemTemp.createTemp('external-tool-gate-');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final executable = Platform.isWindows ? r'C:\tool.exe' : '/tool';
      final runner = ExternalToolRunner();
      await expectLater(
        runner.startReadOnlyDiff(
          configuration: _configuration(executable),
          trustStatus: RepositoryTrustStatus.unconfirmed,
          repositoryRoot: root.path,
          repositoryRelativePath: 'README.md',
          beforeBytes: <int>[1],
          afterBytes: <int>[2],
        ),
        throwsStateError,
      );
    },
  );

  test(
    'rejects a Merge configuration from the read-only Diff entry point',
    () async {
      final runner = ExternalToolRunner();
      final executable = Platform.isWindows ? r'C:\tool.exe' : '/tool';
      await expectLater(
        runner.startReadOnlyDiff(
          configuration: _mergeConfiguration(executable),
          trustStatus: RepositoryTrustStatus.trusted,
          repositoryRoot: Platform.isWindows ? r'C:\repo' : '/repo',
          repositoryRelativePath: 'README.md',
          beforeBytes: const <int>[1],
          afterBytes: const <int>[2],
        ),
        throwsStateError,
      );
    },
  );

  test(
    'rejects snapshots above the configured limit before starting',
    () async {
      final runner = ExternalToolRunner();
      final executable = Platform.isWindows ? r'C:\tool.exe' : '/tool';
      await expectLater(
        runner.startReadOnlyDiff(
          configuration: _configuration(executable),
          trustStatus: RepositoryTrustStatus.trusted,
          repositoryRoot: Platform.isWindows ? r'C:\repo' : '/repo',
          repositoryRelativePath: 'README.md',
          beforeBytes: List<int>.filled(
            ExternalToolConfiguration.snapshotByteLimit + 1,
            0,
          ),
          afterBytes: const <int>[2],
        ),
        throwsStateError,
      );
    },
  );
  test('reads a successful UTF-8 merge result and cleans snapshots', () async {
    if (Platform.isWindows) return;
    final root = await Directory.systemTemp.createTemp('external-merge-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final executable = await _writeScript(root, 'merge.sh', r'''#!/bin/sh
cat "$4" > "$8"
''');
    final run = await ExternalToolRunner().startMergeWriteBack(
      configuration: _mergeConfiguration(executable),
      trustStatus: RepositoryTrustStatus.trusted,
      repositoryRoot: root.path,
      repositoryRelativePath: 'README.md',
      baseBytes: utf8.encode('base\n'),
      oursBytes: utf8.encode('ours\n'),
      theirsBytes: utf8.encode('theirs\n'),
    );
    final snapshotDirectory = run.snapshotDirectory;
    expect(await run.readResultUtf8(), 'ours\n');
    await run.close();
    expect(await snapshotDirectory.exists(), isFalse);
  });

  test('rejects malformed merge results', () async {
    if (Platform.isWindows) return;
    final root = await Directory.systemTemp.createTemp(
      'external-merge-invalid-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final executable = await _writeScript(root, 'invalid.sh', r'''#!/bin/sh
printf "\377" > "$8"
''');
    final run = await ExternalToolRunner().startMergeWriteBack(
      configuration: _mergeConfiguration(executable),
      trustStatus: RepositoryTrustStatus.trusted,
      repositoryRoot: root.path,
      repositoryRelativePath: 'README.md',
      baseBytes: const <int>[],
      oursBytes: const <int>[1],
      theirsBytes: const <int>[2],
    );
    await expectLater(run.readResultUtf8(), throwsStateError);
    await run.close();
  });
}

ExternalToolConfiguration _configuration(
  String executable, {
  List<String>? arguments,
}) => ExternalToolConfiguration(
  displayName: 'Test Diff',
  executablePath: executable,
  arguments:
      arguments ??
      const ['--before', '{before}', '--after', '{after}', '--path', '{path}'],
  enabled: true,
);

ExternalToolConfiguration _mergeConfiguration(String executable) =>
    ExternalToolConfiguration(
      displayName: 'Test Merge',
      executablePath: executable,
      kind: ExternalToolKind.mergeWriteBack,
      arguments: const [
        '--base',
        '{base}',
        '--ours',
        '{ours}',
        '--theirs',
        '{theirs}',
        '--result',
        '{result}',
      ],
      enabled: true,
    );

Future<String> _writeScript(Directory root, String name, String source) async {
  final file = File('${root.path}/$name');
  await file.writeAsString(source);
  final result = await Process.run('chmod', <String>['+x', file.path]);
  expect(result.exitCode, 0);
  return file.path;
}
