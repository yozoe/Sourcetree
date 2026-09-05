import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/app/repository_session.dart';
import 'package:git_desktop/src/git/git.dart';

import '../support/git_test_repository.dart';

void main() {
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
