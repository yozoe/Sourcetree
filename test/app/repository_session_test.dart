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
}
