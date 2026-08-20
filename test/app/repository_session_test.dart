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
    final operation = container
        .read(repositorySessionProvider)
        .operations
        .single;
    expect(operation.kind, RepositoryOperationKind.clone);
    expect(operation.outcome, RepositoryOperationOutcome.succeeded);
    expect(operation.completedAt, isNotNull);
  });

  test('fetches origin and refreshes ahead-behind state', () async {
    final source = await GitTestRepository.create();
    addTearDown(source.dispose);
    await source.writeFile('README.md', '# Git Desktop\n');
    await source.commit('Initial commit');
    final origin = await source.createBareOrigin();
    await source.runGit(['push', 'origin', 'main']);
    final directory = await Directory.systemTemp.createTemp(
      'git-desktop-fetch-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    expect(
      await controller.cloneRepository(
        remoteUrl: origin.path,
        directoryPath: directory.path,
      ),
      isTrue,
    );
    await source.writeFile('CHANGELOG.md', '# Changes\n');
    await source.commit('Add changelog');
    await source.runGit(['push', 'origin', 'main']);

    expect(await controller.fetchOrigin(), isTrue);
    final state = container.read(repositorySessionProvider);
    expect(state.phase, RepositorySessionPhase.ready);
    expect(state.status!.branch.behind, 1);
    final operation = state.operations.firstWhere(
      (operation) => operation.kind == RepositoryOperationKind.fetch,
    );
    expect(operation.outcome, RepositoryOperationOutcome.succeeded);
  });

  test('does not fetch when origin is not configured', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);

    expect(container.read(repositorySessionProvider).hasOriginRemote, isFalse);
    expect(await controller.fetchOrigin(), isFalse);
  });

  test(
    'fast-forward pulls a configured upstream into a clean work tree',
    () async {
      final source = await GitTestRepository.create();
      addTearDown(source.dispose);
      await source.writeFile('README.md', '# Git Desktop\n');
      await source.commit('Initial commit');
      final origin = await source.createBareOrigin();
      await source.runGit(['push', 'origin', 'main']);
      final directory = await Directory.systemTemp.createTemp(
        'git-desktop-pull-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      expect(
        await controller.cloneRepository(
          remoteUrl: origin.path,
          directoryPath: directory.path,
        ),
        isTrue,
      );
      await source.writeFile('CHANGELOG.md', '# Changes\n');
      await source.commit('Add changelog');
      await source.runGit(['push', 'origin', 'main']);

      expect(await controller.pullFastForward(), isTrue);
      expect(
        container.read(repositorySessionProvider).commits.first.subject,
        'Add changelog',
      );
      expect(
        await File(
          '${directory.path}${Platform.pathSeparator}CHANGELOG.md',
        ).exists(),
        isTrue,
      );
    },
  );

  test('refuses pull while the work tree has uncommitted changes', () async {
    final source = await GitTestRepository.create();
    addTearDown(source.dispose);
    await source.writeFile('README.md', '# Git Desktop\n');
    await source.commit('Initial commit');
    final origin = await source.createBareOrigin();
    await source.runGit(['push', 'origin', 'main']);
    final directory = await Directory.systemTemp.createTemp(
      'git-desktop-pull-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    expect(
      await controller.cloneRepository(
        remoteUrl: origin.path,
        directoryPath: directory.path,
      ),
      isTrue,
    );
    await File(
      '${directory.path}${Platform.pathSeparator}local.txt',
    ).writeAsString('keep\n');
    await controller.refresh();

    expect(await controller.pullFastForward(), isFalse);
    expect(
      container.read(repositorySessionProvider).phase,
      RepositorySessionPhase.ready,
    );
  });

  test('pushes ahead commits and refreshes ahead-behind state', () async {
    final source = await GitTestRepository.create();
    addTearDown(source.dispose);
    await source.writeFile('README.md', '# Git Desktop\n');
    await source.commit('Initial commit');
    final origin = await source.createBareOrigin();
    await source.runGit(['push', '--set-upstream', 'origin', 'main']);
    final target = await GitTestRepository.cloneFrom(origin);
    addTearDown(target.dispose);
    await target.writeFile('CHANGELOG.md', '# Changes\n');
    await target.commit('Add changelog');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(target.workingDirectory.path);

    expect(container.read(repositorySessionProvider).status!.branch.ahead, 1);
    expect(await controller.pushUpstream(), isTrue);
    final state = container.read(repositorySessionProvider);
    expect(state.phase, RepositorySessionPhase.ready);
    expect(state.status!.branch.ahead, 0);
    expect(state.status!.branch.behind, 0);
    expect(state.operations.single.kind, RepositoryOperationKind.push);
    expect(
      state.operations.single.outcome,
      RepositoryOperationOutcome.succeeded,
    );
    expect(
      (await source.runGit([
        'rev-parse',
        'refs/heads/main',
      ], workingDirectory: origin)).stdout.toString().trim(),
      (await target.runGit(['rev-parse', 'HEAD'])).stdout.toString().trim(),
    );
  });

  test('refuses push without an upstream or ahead commits', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);

    expect(await controller.pushUpstream(), isFalse);

    await repository.writeFile('README.md', '# Git Desktop\n');
    await repository.commit('Initial commit');
    await controller.refresh();
    expect(await controller.pushUpstream(), isFalse);
  });
}
