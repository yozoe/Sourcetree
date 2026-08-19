import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/app/repository_session.dart';

import '../support/git_test_repository.dart';

void main() {
  test(
    'refresh retries the last requested path after a failed repository switch',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      final nonRepository = await Directory.systemTemp.createTemp(
        'git-desktop-non-repository-',
      );
      addTearDown(() => nonRepository.delete(recursive: true));

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);

      await controller.openRepository(repository.workingDirectory.path);
      expect(
        container.read(repositorySessionProvider).phase,
        RepositorySessionPhase.ready,
      );

      await controller.openRepository(nonRepository.path);
      expect(
        container.read(repositorySessionProvider).phase,
        RepositorySessionPhase.error,
      );

      await controller.refresh();
      final state = container.read(repositorySessionProvider);
      expect(state.phase, RepositorySessionPhase.error);
      expect(state.requestedPath, nonRepository.path);
    },
  );

  test(
    'creates a commit from staged changes and refreshes the session',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('README.md', '# Git Desktop\n');
      await repository.runGit(['add', '--', 'README.md']);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);

      expect(
        container.read(repositorySessionProvider).status!.stagedEntries,
        isNotEmpty,
      );
      expect(await controller.createCommit('Create README'), isTrue);

      final state = container.read(repositorySessionProvider);
      expect(state.phase, RepositorySessionPhase.ready);
      expect(state.status!.entries, isEmpty);
      expect(state.commits.single.subject, 'Create README');
    },
  );

  test('creates a local branch without changing the active branch', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', '# Git Desktop\n');
    await repository.commit('Initial commit');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);

    expect(await controller.createLocalBranch('feature/workflow'), isTrue);
    expect(
      (await repository.runGit([
        'branch',
        '--show-current',
      ])).stdout.toString().trim(),
      'main',
    );
    await repository.runGit([
      'show-ref',
      '--verify',
      '--quiet',
      'refs/heads/feature/workflow',
    ]);
  });

  test('switches branches only while the repository is clean', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', '# Git Desktop\n');
    await repository.commit('Initial commit');
    await repository.runGit(['branch', 'feature/switch-branch']);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);

    expect(
      await controller.switchToLocalBranch('feature/switch-branch'),
      isTrue,
    );
    expect(
      container.read(repositorySessionProvider).status!.branch.head,
      'feature/switch-branch',
    );

    await repository.writeFile('uncommitted.txt', 'do not switch\n');
    await controller.refresh();
    expect(await controller.switchToLocalBranch('main'), isFalse);
    expect(
      (await repository.runGit([
        'branch',
        '--show-current',
      ])).stdout.toString().trim(),
      'feature/switch-branch',
    );
  });

  test('initializes and opens an empty directory', () async {
    final directory = await Directory.systemTemp.createTemp(
      'git-desktop-init-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);

    expect(await controller.initializeRepository(directory.path), isTrue);

    final state = container.read(repositorySessionProvider);
    expect(state.phase, RepositorySessionPhase.ready);
    expect(state.repository!.workTreeRoot, isNotNull);
    expect(state.status!.branch.isUnborn, isTrue);
  });

  test('clones and opens a local bare remote', () async {
    final source = await GitTestRepository.create();
    addTearDown(source.dispose);
    await source.writeFile('README.md', '# Git Desktop\n');
    await source.commit('Initial commit');
    final origin = await source.createBareOrigin();
    await source.runGit(['push', 'origin', 'main']);
    final directory = await Directory.systemTemp.createTemp(
      'git-desktop-clone-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
      await container
          .read(repositorySessionProvider.notifier)
          .cloneRepository(
            remoteUrl: origin.path,
            directoryPath: directory.path,
          ),
      isTrue,
    );
    expect(
      container.read(repositorySessionProvider).commits.single.subject,
      'Initial commit',
    );
  });
}
