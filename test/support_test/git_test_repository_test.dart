import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/git_test_repository.dart';

void main() {
  group('GitTestRepository', () {
    late GitTestRepository repository;

    setUp(() async {
      repository = await GitTestRepository.create();
    });

    tearDown(() async {
      await repository.dispose();
    });

    test('creates an empty repository with isolated fixed identity', () async {
      final insideWorkTree = await repository.runGit([
        'rev-parse',
        '--is-inside-work-tree',
      ]);
      expect(insideWorkTree.stdout.toString().trim(), 'true');

      final head = await repository.runGit([
        'rev-parse',
        '--verify',
        'HEAD',
      ], throwOnError: false);
      expect(head.exitCode, isNot(0));

      final configuredName = await repository.runGit([
        'config',
        '--local',
        '--get',
        'user.name',
      ]);
      final configuredEmail = await repository.runGit([
        'config',
        '--local',
        '--get',
        'user.email',
      ]);
      expect(
        configuredName.stdout.toString().trim(),
        GitTestRepository.authorName,
      );
      expect(
        configuredEmail.stdout.toString().trim(),
        GitTestRepository.authorEmail,
      );
      expect(
        repository.homeDirectory.path,
        startsWith(repository.rootDirectory.path),
      );

      await repository.runGit([
        'config',
        '--global',
        'fixture.isolated',
        'true',
      ]);
      final isolatedGlobalConfig = File(
        '${repository.homeDirectory.path}'
        '${Platform.pathSeparator}.gitconfig',
      );
      expect(await isolatedGlobalConfig.readAsString(), contains('isolated'));
    });

    test('writes, commits, and reports a clean status', () async {
      await repository.writeFile('docs/readme.txt', 'fixture contents\n');

      final untrackedStatus = await repository.runGit([
        'status',
        '--porcelain',
      ]);
      expect(untrackedStatus.stdout.toString(), contains('?? docs/'));

      final commitId = await repository.commit('Add fixture file');
      expect(commitId, hasLength(40));

      final status = await repository.runGit(['status', '--porcelain']);
      expect(status.stdout.toString(), isEmpty);

      final author = await repository.runGit([
        'show',
        '--quiet',
        '--format=%an <%ae>',
        'HEAD',
      ]);
      expect(
        author.stdout.toString().trim(),
        '${GitTestRepository.authorName} '
        '<${GitTestRepository.authorEmail}>',
      );
    });

    test(
      'creates a usable bare origin that can be pushed and cloned',
      () async {
        await repository.writeFile('README.md', '# Test repository\n');
        final sourceCommit = await repository.commit('Initial commit');
        final origin = await repository.createBareOrigin();
        await repository.runGit(['push', '--set-upstream', 'origin', 'main']);

        final clone = await GitTestRepository.cloneFrom(origin);
        addTearDown(clone.dispose);

        final clonedCommit = await clone.runGit(['rev-parse', 'HEAD']);
        expect(clonedCommit.stdout.toString().trim(), sourceCommit);
        expect(
          await File(
            '${clone.workingDirectory.path}${Platform.pathSeparator}README.md',
          ).readAsString(),
          '# Test repository\n',
        );

        final status = await clone.runGit(['status', '--porcelain']);
        expect(status.stdout.toString(), isEmpty);
      },
    );

    test('does not allow writes outside the fixture work tree', () async {
      await expectLater(
        repository.writeFile('../outside.txt', 'not allowed'),
        throwsArgumentError,
      );
    });
  });
}
