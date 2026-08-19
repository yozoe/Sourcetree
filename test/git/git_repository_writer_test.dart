import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/git/git.dart';

import '../support/git_test_repository.dart';

void main() {
  late GitTestRepository fixture;
  late GitRepositoryInspector inspector;
  late GitRepositoryReader reader;
  late GitRepositoryWriter writer;

  setUp(() async {
    fixture = await GitTestRepository.create();
    final runner = GitRunner();
    inspector = GitRepositoryInspector(runner);
    reader = GitRepositoryReader(runner);
    writer = GitRepositoryWriter(runner);
  });

  tearDown(() => fixture.dispose());

  test(
    'stages and unstages a tracked file without changing its work tree',
    () async {
      await fixture.writeFile('lib/example.dart', 'const version = 1;\n');
      await fixture.commit('Add example');
      await fixture.writeFile('lib/example.dart', 'const version = 2;\n');

      final repository = (await inspector.inspect(
        fixture.workingDirectory.path,
      ))!;
      final before = await reader.readStatus(repository);
      final beforeEntry = before.entries.single;
      expect(beforeEntry.hasStagedChange, isFalse);
      expect(beforeEntry.hasWorkTreeChange, isTrue);

      await writer.stagePath(repository, beforeEntry.path);
      final staged = await reader.readStatus(repository);
      final stagedEntry = staged.entries.single;
      expect(stagedEntry.hasStagedChange, isTrue);
      expect(stagedEntry.hasWorkTreeChange, isFalse);

      await writer.unstagePath(
        repository,
        stagedEntry.path,
        isUnbornBranch: staged.branch.isUnborn,
      );
      final unstaged = await reader.readStatus(repository);
      final unstagedEntry = unstaged.entries.single;
      expect(unstagedEntry.hasStagedChange, isFalse);
      expect(unstagedEntry.hasWorkTreeChange, isTrue);
      expect(
        await File(
          '${fixture.workingDirectory.path}${Platform.pathSeparator}lib'
          '${Platform.pathSeparator}example.dart',
        ).readAsString(),
        'const version = 2;\n',
      );
    },
  );

  test('unstages an added file in an unborn branch', () async {
    await fixture.writeFile('README.md', '# Unborn branch\n');
    final repository = (await inspector.inspect(
      fixture.workingDirectory.path,
    ))!;
    final untracked = await reader.readStatus(repository);
    expect(untracked.branch.isUnborn, isTrue);

    await writer.stagePath(repository, untracked.entries.single.path);
    final staged = await reader.readStatus(repository);
    final stagedEntry = staged.entries.single;
    expect(stagedEntry.hasStagedChange, isTrue);

    await writer.unstagePath(
      repository,
      stagedEntry.path,
      isUnbornBranch: staged.branch.isUnborn,
    );
    final restored = await reader.readStatus(repository);
    expect(restored.branch.isUnborn, isTrue);
    expect(restored.entries.single.kind, GitFileStatusKind.untracked);
  });

  test('refuses to mutate a path that is not valid UTF-8', () async {
    final repository = (await inspector.inspect(
      fixture.workingDirectory.path,
    ))!;

    await expectLater(
      writer.stagePath(repository, GitPath(const [0xff])),
      throwsA(isA<GitException>()),
    );
  });

  test(
    'creates a commit from the staged index using a stdin message',
    () async {
      await fixture.writeFile('README.md', '# Git Desktop\n');
      final repository = (await inspector.inspect(
        fixture.workingDirectory.path,
      ))!;
      final before = await reader.readStatus(repository);
      await writer.stagePath(repository, before.entries.single.path);

      await writer.createCommit(repository, message: 'Create README');

      final after = await reader.readStatus(repository);
      final history = await reader.readRecentHistory(repository);
      expect(after.entries, isEmpty);
      expect(history, hasLength(1));
      expect(history.single.subject, 'Create README');
      expect((await fixture.runGit(['rev-parse', 'HEAD'])).exitCode, 0);
    },
  );

  test('rejects an empty commit message before running Git', () async {
    final repository = (await inspector.inspect(
      fixture.workingDirectory.path,
    ))!;

    await expectLater(
      writer.createCommit(repository, message: '  \n\t '),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('creates a local branch at HEAD without switching branches', () async {
    await fixture.writeFile('README.md', '# Git Desktop\n');
    await fixture.commit('Initial commit');
    final repository = (await inspector.inspect(
      fixture.workingDirectory.path,
    ))!;

    await writer.createLocalBranch(repository, name: 'feature/create-branch');

    await fixture.runGit([
      'show-ref',
      '--verify',
      '--quiet',
      'refs/heads/feature/create-branch',
    ]);
    expect(
      (await fixture.runGit([
        'branch',
        '--show-current',
      ])).stdout.toString().trim(),
      'main',
    );
  });

  test('rejects an empty local branch name before running Git', () async {
    final repository = (await inspector.inspect(
      fixture.workingDirectory.path,
    ))!;

    await expectLater(
      writer.createLocalBranch(repository, name: ' \t '),
      throwsA(isA<ArgumentError>()),
    );
  });
}
