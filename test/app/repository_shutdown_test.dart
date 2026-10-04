import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/app/git_flow_semantics.dart';
import 'package:git_desktop/src/app/repository_session.dart';
import 'package:git_desktop/src/app/repository_view_mapper.dart';
import 'package:git_desktop/src/git/git.dart';

import '../support/git_test_repository.dart';

void main() {
  test('shutdown cancels and joins an in-flight file copy', () async {
    if (!Platform.isMacOS) return;
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    await repository.commit('base');
    await repository.writeFile('copy.txt', 'copy me\n');
    final destination = await Directory.systemTemp.createTemp(
      'git-desktop-copy-shutdown-',
    );
    addTearDown(() => destination.delete(recursive: true));
    final copyPrepared = Completer<void>();
    final releaseCopy = Completer<void>();
    final runner = GitRunner();
    final container = ProviderContainer(
      overrides: [
        gitRunnerProvider.overrideWithValue(runner),
        gitRepositoryWriterProvider.overrideWithValue(
          GitRepositoryWriter(
            runner,
            beforeCopyPublicationForTesting: () async {
              copyPrepared.complete();
              await releaseCopy.future;
            },
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    controller.selectUncommittedChanges();
    final selected = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!.changes.singleWhere((change) => change.path == 'copy.txt');

    final copy = controller.copyChanges([
      selected,
    ], destinationDirectory: destination.path);
    await copyPrepared.future;
    final shutdown = controller.prepareForShutdown();
    await Future<void>.delayed(Duration.zero);
    releaseCopy.complete();

    await shutdown;
    expect(await copy, isNull);
    expect(await destination.list().isEmpty, isTrue);
  });

  test('shutdown cancels and joins an in-flight file move', () async {
    if (!Platform.isMacOS) return;
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    await repository.commit('base');
    final source = await repository.writeFile('move.txt', 'move me\n');
    final destination = await Directory.systemTemp.createTemp(
      'git-desktop-move-shutdown-',
    );
    addTearDown(() => destination.delete(recursive: true));
    final movePrepared = Completer<void>();
    final releaseMove = Completer<void>();
    final runner = GitRunner();
    final container = ProviderContainer(
      overrides: [
        gitRunnerProvider.overrideWithValue(runner),
        gitRepositoryWriterProvider.overrideWithValue(
          GitRepositoryWriter(
            runner,
            beforeMovePublicationForTesting: () async {
              movePrepared.complete();
              await releaseMove.future;
            },
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    controller.selectUncommittedChanges();
    final selected = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!.changes.singleWhere((change) => change.path == 'move.txt');

    final move = controller.moveChanges([
      selected,
    ], destinationDirectory: destination.path);
    await movePrepared.future;
    final shutdown = controller.prepareForShutdown();
    await Future<void>.delayed(Duration.zero);
    releaseMove.complete();

    await shutdown;
    expect(await move, isNull);
    expect(await source.readAsString(), 'move me\n');
    expect(await destination.list().isEmpty, isTrue);
  });

  test('shutdown cancels an in-flight remote tag deletion', () async {
    if (Platform.isWindows) return;
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    final commit = await repository.commit('Initial commit');
    await repository.createBareOrigin();
    await repository.runGit(['tag', 'v1.0.0', commit]);
    await repository.runGit(['push', 'origin', 'refs/tags/v1.0.0']);
    final marker = File(
      '${repository.rootDirectory.path}/remote-tag-delete-started',
    );
    final helper = File('${repository.rootDirectory.path}/delayed-git');
    await helper.writeAsString('''#!/bin/sh
for argument in "\$@"; do
  if [ "\$argument" = "ls-remote" ]; then
    printf started > "${marker.path}"
    sleep 10
    break
  fi
done
exec git "\$@"
''');
    final chmod = await Process.run('chmod', ['+x', helper.path]);
    expect(chmod.exitCode, 0);

    final container = ProviderContainer(
      overrides: [
        gitRunnerProvider.overrideWithValue(GitRunner(executable: helper.path)),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    final deletion = controller.deleteRemoteTags([
      'v1.0.0',
    ], remoteName: 'origin');
    for (var attempt = 0; attempt < 200 && !await marker.exists(); attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await marker.exists(), isTrue);
    await controller.prepareForShutdown(timeout: const Duration(seconds: 2));

    final result = await deletion;
    expect(result, isNotNull);
    expect(result!.deletedNames, isEmpty);
    expect(result.missingNames, isEmpty);
    expect(result.failedNames, isEmpty);
    expect(
      container.read(repositorySessionProvider).operations.first.outcome,
      RepositoryOperationOutcome.cancelled,
    );
  });

  test('shutdown cancels an in-flight local tag deletion', () async {
    if (Platform.isWindows) return;
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    final commit = await repository.commit('Initial commit');
    await repository.runGit(['tag', 'v1.0.0', commit]);
    final marker = File(
      '${repository.rootDirectory.path}/local-tag-delete-started',
    );
    final helper = File('${repository.rootDirectory.path}/delayed-git');
    await helper.writeAsString('''#!/bin/sh
for argument in "\$@"; do
  if [ "\$argument" = "for-each-ref" ]; then
    printf started > "${marker.path}"
    sleep 10
    break
  fi
done
exec git "\$@"
''');
    final chmod = await Process.run('chmod', ['+x', helper.path]);
    expect(chmod.exitCode, 0);

    final container = ProviderContainer(
      overrides: [
        gitRunnerProvider.overrideWithValue(GitRunner(executable: helper.path)),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    final deletion = controller.deleteTags(['v1.0.0']);
    for (var attempt = 0; attempt < 200 && !await marker.exists(); attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await marker.exists(), isTrue);
    await controller.prepareForShutdown(timeout: const Duration(seconds: 2));

    final result = await deletion;
    expect(result, isNotNull);
    expect(result!.deletedNames, isEmpty);
    expect(result.missingNames, isEmpty);
    expect(result.failedNames, isEmpty);
    expect(
      container.read(repositorySessionProvider).operations.first.outcome,
      RepositoryOperationOutcome.cancelled,
    );
  });

  test(
    'shutdown cancels and joins an in-flight checkout without a token',
    () async {
      if (Platform.isWindows) return;
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('README.md', 'base\n');
      final baseCommit = await repository.commit('base');
      await repository.writeFile('README.md', 'next\n');
      await repository.commit('next');

      final marker = File('${repository.rootDirectory.path}/checkout-started');
      final helper = File('${repository.rootDirectory.path}/delayed-git');
      await helper.writeAsString('''#!/bin/sh
for argument in "\$@"; do
  if [ "\$argument" = "switch" ]; then
    printf started > "${marker.path}"
    sleep 1
    break
  fi
done
exec git "\$@"
''');
      final chmod = await Process.run('chmod', ['+x', helper.path]);
      expect(chmod.exitCode, 0);

      final container = ProviderContainer(
        overrides: [
          gitRunnerProvider.overrideWithValue(
            GitRunner(executable: helper.path),
          ),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);

      final checkout = controller.checkoutCommit(baseCommit);
      for (
        var attempt = 0;
        attempt < 200 && !await marker.exists();
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(await marker.exists(), isTrue);
      await controller.prepareForShutdown(
        timeout: const Duration(milliseconds: 20),
      );

      expect(await checkout, isFalse);
    },
  );

  test('shutdown cancels Git-flow Start before its checkout phase', () async {
    if (Platform.isWindows) return;
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    await repository.commit('base');

    final branchMarker = File(
      '${repository.rootDirectory.path}/flow-branch-started',
    );
    final switchMarker = File(
      '${repository.rootDirectory.path}/flow-switch-started',
    );
    final helper = File('${repository.rootDirectory.path}/delayed-git');
    await helper.writeAsString('''#!/bin/sh
for argument in "\$@"; do
  if [ "\$argument" = "branch" ]; then
    printf started > "${branchMarker.path}"
    sleep 10
    break
  fi
  if [ "\$argument" = "switch" ]; then
    printf started > "${switchMarker.path}"
  fi
done
exec git "\$@"
''');
    final chmod = await Process.run('chmod', ['+x', helper.path]);
    expect(chmod.exitCode, 0);

    final container = ProviderContainer(
      overrides: [
        gitRunnerProvider.overrideWithValue(GitRunner(executable: helper.path)),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    final plan = validateGitFlowStart(
      kind: GitFlowBranchKind.feature,
      name: 'delayed',
      baseBranch: 'main',
      existingBranches: container
          .read(repositorySessionProvider)
          .localBranches
          .map((branch) => branch.name),
      isAttachedHead: true,
      isWorkingTreeClean: true,
      hasActiveOperation: false,
    ).plan!;

    final start = controller.startGitFlowBranch(plan);
    for (
      var attempt = 0;
      attempt < 200 && !await branchMarker.exists();
      attempt++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await branchMarker.exists(), isTrue);
    await controller.prepareForShutdown(timeout: const Duration(seconds: 2));

    final result = await start;
    expect(result, isNotNull);
    expect(result!.checkedOut, isFalse);
    expect(await switchMarker.exists(), isFalse);
  });

  test(
    'shutdown cancels Git-flow Finish during merge and preserves refs',
    () async {
      if (Platform.isWindows) return;
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('README.md', 'base\n');
      await repository.commit('base');
      await repository.runGit(['switch', '-c', 'feature/shutdown']);
      await repository.writeFile('feature.txt', 'feature\n');
      await repository.commit('feature');
      await repository.runGit(['switch', 'main']);
      await repository.runGit(['switch', 'feature/shutdown']);

      final marker = File('${repository.rootDirectory.path}/flow-finish-merge');
      final helper = File('${repository.rootDirectory.path}/delayed-git');
      await helper.writeAsString('''#!/bin/sh
for argument in "\$@"; do
  if [ "\$argument" = "merge" ]; then
    printf started > "${marker.path}"
    sleep 10
    break
  fi
done
exec git "\$@"
''');
      final chmod = await Process.run('chmod', ['+x', helper.path]);
      expect(chmod.exitCode, 0);

      final container = ProviderContainer(
        overrides: [
          gitRunnerProvider.overrideWithValue(
            GitRunner(executable: helper.path),
          ),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);
      final plan = validateGitFlowFinish(
        sourceBranch: 'feature/shutdown',
        targetBranch: 'main',
        existingBranches: container
            .read(repositorySessionProvider)
            .localBranches
            .map((branch) => branch.name),
        isAttachedHead: true,
        isWorkingTreeClean: true,
        hasActiveOperation: false,
      ).plan!;

      final finish = controller.finishGitFlowBranch(plan);
      for (
        var attempt = 0;
        attempt < 200 && !await marker.exists();
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(await marker.exists(), isTrue);
      await controller.prepareForShutdown(timeout: const Duration(seconds: 2));
      final result = await finish;
      expect(result?.merged, isFalse);
      expect(
        (await repository.runGit([
          'show-ref',
          '--verify',
          '--quiet',
          'refs/heads/feature/shutdown',
        ], throwOnError: false)).exitCode,
        0,
      );
    },
  );

  test('shutdown joins a tracked branch mutation and its cleanup', () async {
    if (Platform.isWindows) return;
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    await repository.commit('base');

    final marker = File('${repository.rootDirectory.path}/branch-started');
    final helper = File('${repository.rootDirectory.path}/delayed-git');
    await helper.writeAsString('''#!/bin/sh
for argument in "\$@"; do
  if [ "\$argument" = "branch" ]; then
    printf started > "${marker.path}"
    sleep 1
    break
  fi
done
exec git "\$@"
''');
    final chmod = await Process.run('chmod', ['+x', helper.path]);
    expect(chmod.exitCode, 0);

    final container = ProviderContainer(
      overrides: [
        gitRunnerProvider.overrideWithValue(GitRunner(executable: helper.path)),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);

    var mutationCompleted = false;
    final mutation = controller
        .createLocalBranch('shutdown-test')
        .whenComplete(() => mutationCompleted = true);
    for (var attempt = 0; attempt < 200 && !await marker.exists(); attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await marker.exists(), isTrue);

    await controller.prepareForShutdown(timeout: const Duration(seconds: 2));

    expect(mutationCompleted, isTrue);
    expect(await mutation, isFalse);
  });

  test('fetch preflight rejects a concurrent second invocation', () async {
    if (Platform.isWindows) return;
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    await repository.commit('base');
    await repository.createBareOrigin();
    await repository.runGit(['push', '-u', 'origin', 'main']);

    final marker = File('${repository.rootDirectory.path}/remote-read');
    final helper = File('${repository.rootDirectory.path}/delayed-git');
    await helper.writeAsString('''#!/bin/sh
for argument in "\$@"; do
  if [ "\$argument" = "remote" ]; then
    printf read >> "${marker.path}"
    sleep 1
    break
  fi
done
exec git "\$@"
''');
    final chmod = await Process.run('chmod', ['+x', helper.path]);
    expect(chmod.exitCode, 0);
    final container = ProviderContainer(
      overrides: [
        gitRunnerProvider.overrideWithValue(GitRunner(executable: helper.path)),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    if (await marker.exists()) await marker.writeAsString('');

    final first = controller.fetchOrigin();
    for (
      var attempt = 0;
      attempt < 200 && (!await marker.exists() || await marker.length() == 0);
      attempt++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(await controller.fetchOrigin(), isFalse);
    expect(await first, isTrue);
    expect(await marker.readAsString(), startsWith('read'));
  });

  test('pull preflight rejects a concurrent second invocation', () async {
    if (Platform.isWindows) return;
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    await repository.commit('base');
    await repository.createBareOrigin();
    await repository.runGit(['push', '-u', 'origin', 'main']);

    final marker = File('${repository.rootDirectory.path}/remote-read');
    final helper = File('${repository.rootDirectory.path}/delayed-git');
    await helper.writeAsString('''#!/bin/sh
for argument in "\$@"; do
  if [ "\$argument" = "remote" ]; then
    printf read >> "${marker.path}"
    sleep 1
    break
  fi
done
exec git "\$@"
''');
    final chmod = await Process.run('chmod', ['+x', helper.path]);
    expect(chmod.exitCode, 0);
    final container = ProviderContainer(
      overrides: [
        gitRunnerProvider.overrideWithValue(GitRunner(executable: helper.path)),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    if (await marker.exists()) await marker.writeAsString('');
    const options = GitPullOptions(remoteName: 'origin', remoteBranch: 'main');

    final first = controller.pullWithOptions(options);
    for (
      var attempt = 0;
      attempt < 200 && (!await marker.exists() || await marker.length() == 0);
      attempt++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(await controller.pullWithOptions(options), isFalse);
    expect(await first, isTrue);
  });

  test('remote removal preflight rejects a concurrent invocation', () async {
    if (Platform.isWindows) return;
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    await repository.commit('base');
    await repository.createBareOrigin();

    final marker = File('${repository.rootDirectory.path}/remote-read');
    final helper = File('${repository.rootDirectory.path}/delayed-git');
    await helper.writeAsString('''#!/bin/sh
for argument in "\$@"; do
  if [ "\$argument" = "remote" ]; then
    printf read >> "${marker.path}"
    sleep 1
    break
  fi
done
exec git "\$@"
''');
    final chmod = await Process.run('chmod', ['+x', helper.path]);
    expect(chmod.exitCode, 0);
    final container = ProviderContainer(
      overrides: [
        gitRunnerProvider.overrideWithValue(GitRunner(executable: helper.path)),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    if (await marker.exists()) await marker.writeAsString('');

    final first = controller.removeRemote('origin');
    for (
      var attempt = 0;
      attempt < 200 && (!await marker.exists() || await marker.length() == 0);
      attempt++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(await controller.removeRemote('origin'), isFalse);
    expect(await first, isTrue);
  });

  test('push preflight rejects a concurrent second invocation', () async {
    if (Platform.isWindows) return;
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    await repository.commit('base');
    await repository.createBareOrigin();

    final marker = File('${repository.rootDirectory.path}/remote-read');
    final helper = File('${repository.rootDirectory.path}/delayed-git');
    await helper.writeAsString('''#!/bin/sh
for argument in "\$@"; do
  if [ "\$argument" = "remote" ]; then
    printf read >> "${marker.path}"
    sleep 1
    break
  fi
done
exec git "\$@"
''');
    final chmod = await Process.run('chmod', ['+x', helper.path]);
    expect(chmod.exitCode, 0);
    final container = ProviderContainer(
      overrides: [
        gitRunnerProvider.overrideWithValue(GitRunner(executable: helper.path)),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    if (await marker.exists()) await marker.writeAsString('');
    const options = GitPushOptions(
      remoteName: 'origin',
      branches: [GitPushBranch(localBranch: 'main', remoteBranch: 'main')],
    );

    final first = controller.pushWithOptions(options);
    for (
      var attempt = 0;
      attempt < 200 && (!await marker.exists() || await marker.length() == 0);
      attempt++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(await controller.pushWithOptions(options), isFalse);
    expect(await first, isTrue);
    expect(await marker.readAsString(), startsWith('read'));
  });
}
