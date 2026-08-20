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

  test('switches to an existing local branch without creating a ref', () async {
    await fixture.writeFile('README.md', '# Git Desktop\n');
    await fixture.commit('Initial commit');
    final repository = (await inspector.inspect(
      fixture.workingDirectory.path,
    ))!;
    await writer.createLocalBranch(repository, name: 'feature/switch-branch');

    await writer.switchToLocalBranch(repository, name: 'feature/switch-branch');

    expect(
      (await fixture.runGit([
        'branch',
        '--show-current',
      ])).stdout.toString().trim(),
      'feature/switch-branch',
    );
  });

  test(
    'creates and switches to a local tracking branch from a remote ref',
    () async {
      await fixture.writeFile('README.md', '# Git Desktop\n');
      await fixture.commit('Initial commit');
      final origin = await fixture.createBareOrigin();
      await fixture.runGit(['push', 'origin', 'main']);
      await fixture.runGit(['branch', 'feature/remote']);
      await fixture.runGit(['push', 'origin', 'feature/remote']);
      final clone = await GitTestRepository.cloneFrom(origin);
      addTearDown(clone.dispose);
      final repository = (await inspector.inspect(
        clone.workingDirectory.path,
      ))!;

      await writer.switchToRemoteBranch(
        repository,
        remoteName: 'origin/feature/remote',
      );

      expect(
        (await clone.runGit([
          'branch',
          '--show-current',
        ])).stdout.toString().trim(),
        'feature/remote',
      );
      expect(
        (await clone.runGit([
          'config',
          '--get',
          'branch.feature/remote.remote',
        ])).stdout.toString().trim(),
        'origin',
      );
    },
  );

  test(
    'merges a divergent local branch with an explicit merge commit',
    () async {
      await fixture.writeFile('README.md', 'base\n');
      await fixture.commit('Initial commit');
      await fixture.runGit(['branch', 'feature/merge']);
      await fixture.runGit(['switch', 'feature/merge']);
      await fixture.writeFile('feature.txt', 'feature\n');
      await fixture.commit('Feature commit');
      await fixture.runGit(['switch', 'main']);
      await fixture.writeFile('main.txt', 'main\n');
      await fixture.commit('Main commit');
      final repository = (await inspector.inspect(
        fixture.workingDirectory.path,
      ))!;

      await writer.mergeLocalBranch(repository, sourceName: 'feature/merge');

      final status = await reader.readStatus(repository);
      final head = (await reader.readRecentHistory(repository)).first;
      expect(status.isClean, isTrue);
      expect(head.parentIds, hasLength(2));
      expect(
        await File('${fixture.workingDirectory.path}/feature.txt').exists(),
        isTrue,
      );
    },
  );

  test(
    'merges the selected local branch when a tag has the same name',
    () async {
      await fixture.writeFile('README.md', 'base\n');
      await fixture.commit('Initial commit');
      await fixture.runGit(['branch', 'release']);
      await fixture.runGit(['switch', 'release']);
      await fixture.writeFile('branch.txt', 'branch\n');
      final branchCommit = await fixture.commit('Branch release commit');
      await fixture.runGit(['switch', 'main']);
      await fixture.writeFile('tag.txt', 'tag\n');
      final tagCommit = await fixture.commit('Tag release commit');
      await fixture.runGit(['tag', 'release', tagCommit]);
      await fixture.writeFile('main.txt', 'main\n');
      await fixture.commit('Main commit');
      final repository = (await inspector.inspect(
        fixture.workingDirectory.path,
      ))!;

      await writer.mergeLocalBranch(repository, sourceName: 'release');

      final parents = (await reader.readRecentHistory(
        repository,
      )).first.parentIds;
      expect(parents, contains(branchCommit));
      expect(parents, isNot(contains(tagCommit)));
      expect(
        await File('${fixture.workingDirectory.path}/branch.txt').exists(),
        isTrue,
      );
    },
  );

  test('initializes an empty directory without relying on a shell', () async {
    final directory = await Directory.systemTemp.createTemp(
      'git-desktop-init-',
    );
    addTearDown(() => directory.delete(recursive: true));

    await writer.initializeRepository(directory.path);

    final repository = await inspector.inspect(directory.path);
    expect(repository, isNotNull);
    expect((await reader.readStatus(repository!)).branch.isUnborn, isTrue);
  });

  test('refuses to initialize a non-empty directory', () async {
    final directory = await Directory.systemTemp.createTemp(
      'git-desktop-init-',
    );
    addTearDown(() => directory.delete(recursive: true));
    await File(
      '${directory.path}${Platform.pathSeparator}keep.txt',
    ).writeAsString('keep');

    await expectLater(
      writer.initializeRepository(directory.path),
      throwsA(isA<GitException>()),
    );
    expect(await inspector.inspect(directory.path), isNull);
  });

  test('clones a local bare remote into an empty directory', () async {
    await fixture.writeFile('README.md', '# Git Desktop\n');
    await fixture.commit('Initial commit');
    final origin = await fixture.createBareOrigin();
    await fixture.runGit(['push', 'origin', 'main']);
    final directory = await Directory.systemTemp.createTemp(
      'git-desktop-clone-',
    );
    addTearDown(() => directory.delete(recursive: true));

    await writer.cloneRepository(
      remoteUrl: origin.path,
      directoryPath: directory.path,
    );

    final repository = await inspector.inspect(directory.path);
    expect(repository, isNotNull);
    expect(
      (await reader.readRecentHistory(repository!)).single.subject,
      'Initial commit',
    );
  });

  test('fetches origin without changing the checked out branch', () async {
    await fixture.writeFile('README.md', '# Git Desktop\n');
    await fixture.commit('Initial commit');
    final origin = await fixture.createBareOrigin();
    await fixture.runGit(['push', 'origin', 'main']);
    final directory = await Directory.systemTemp.createTemp(
      'git-desktop-fetch-',
    );
    addTearDown(() => directory.delete(recursive: true));
    await writer.cloneRepository(
      remoteUrl: origin.path,
      directoryPath: directory.path,
    );
    await fixture.writeFile('CHANGELOG.md', '# Changes\n');
    final sourceHead = await fixture.commit('Add changelog');
    await fixture.runGit(['push', 'origin', 'main']);
    final repository = (await inspector.inspect(directory.path))!;

    await writer.fetchOrigin(repository);

    final remoteHead = await writer.runner.run(
      GitInvocation(
        arguments: const ['rev-parse', 'refs/remotes/origin/main'],
        workingDirectory: directory.path,
      ),
    );
    expect(remoteHead.stdoutText.trim(), sourceHead);
    expect(
      (await writer.runner.run(
        GitInvocation(
          arguments: const ['branch', '--show-current'],
          workingDirectory: directory.path,
        ),
      )).stdoutText.trim(),
      'main',
    );
  });

  test('honors a cancelled fetch token before starting Git', () async {
    final repository = (await inspector.inspect(
      fixture.workingDirectory.path,
    ))!;
    final cancellation = GitCancellationToken()..cancel();

    await expectLater(
      writer.fetchOrigin(repository, cancellationToken: cancellation),
      throwsA(isA<GitCancelledException>()),
    );
  });

  test('fast-forward pulls origin into a clean checked out branch', () async {
    await fixture.writeFile('README.md', '# Git Desktop\n');
    await fixture.commit('Initial commit');
    final origin = await fixture.createBareOrigin();
    await fixture.runGit(['push', 'origin', 'main']);
    final directory = await Directory.systemTemp.createTemp(
      'git-desktop-pull-',
    );
    addTearDown(() => directory.delete(recursive: true));
    await writer.cloneRepository(
      remoteUrl: origin.path,
      directoryPath: directory.path,
    );
    await fixture.writeFile('CHANGELOG.md', '# Changes\n');
    final sourceHead = await fixture.commit('Add changelog');
    await fixture.runGit(['push', 'origin', 'main']);
    final repository = (await inspector.inspect(directory.path))!;

    await writer.pullFastForward(repository);

    final head = await writer.runner.run(
      GitInvocation(
        arguments: const ['rev-parse', 'HEAD'],
        workingDirectory: directory.path,
      ),
    );
    expect(head.stdoutText.trim(), sourceHead);
    expect(
      await File(
        '${directory.path}${Platform.pathSeparator}CHANGELOG.md',
      ).exists(),
      isTrue,
    );
    expect((await reader.readStatus(repository)).isClean, isTrue);
  });

  test('rejects a diverged pull instead of creating a merge commit', () async {
    await fixture.writeFile('README.md', '# Git Desktop\n');
    await fixture.commit('Initial commit');
    final origin = await fixture.createBareOrigin();
    await fixture.runGit(['push', 'origin', 'main']);
    final directory = await Directory.systemTemp.createTemp(
      'git-desktop-pull-',
    );
    addTearDown(() => directory.delete(recursive: true));
    await writer.cloneRepository(
      remoteUrl: origin.path,
      directoryPath: directory.path,
    );
    final repository = (await inspector.inspect(directory.path))!;
    for (final arguments in const [
      ['config', 'user.name', 'Git Desktop Test'],
      ['config', 'user.email', 'git-desktop-test@example.invalid'],
    ]) {
      final result = await writer.runner.run(
        GitInvocation(arguments: arguments, workingDirectory: directory.path),
      );
      result.throwIfFailed(operation: 'Configuring cloned test repository');
    }
    await File(
      '${directory.path}${Platform.pathSeparator}local.txt',
    ).writeAsString('local\n');
    await writer.stagePath(repository, GitPath.fromString('local.txt'));
    await writer.createCommit(repository, message: 'Local commit');
    await fixture.writeFile('remote.txt', 'remote\n');
    await fixture.commit('Remote commit');
    await fixture.runGit(['push', 'origin', 'main']);

    await expectLater(
      writer.pullFastForward(repository),
      throwsA(isA<GitCommandException>()),
    );
    expect(
      (await writer.runner.run(
        GitInvocation(
          arguments: const ['rev-list', '--count', 'HEAD'],
          workingDirectory: directory.path,
        ),
      )).stdoutText.trim(),
      '2',
    );
  });

  test('honors a cancelled pull token before starting Git', () async {
    final repository = (await inspector.inspect(
      fixture.workingDirectory.path,
    ))!;
    final cancellation = GitCancellationToken()..cancel();

    await expectLater(
      writer.pullFastForward(repository, cancellationToken: cancellation),
      throwsA(isA<GitCancelledException>()),
    );
  });

  test(
    'pushes ahead commits to the configured upstream without force',
    () async {
      await fixture.writeFile('README.md', '# Git Desktop\n');
      await fixture.commit('Initial commit');
      final origin = await fixture.createBareOrigin();
      await fixture.runGit(['push', '--set-upstream', 'origin', 'main']);
      await fixture.writeFile('CHANGELOG.md', '# Changes\n');
      final localHead = await fixture.commit('Add changelog');
      final repository = (await inspector.inspect(
        fixture.workingDirectory.path,
      ))!;

      await writer.pushUpstream(repository);

      final remoteHead = await fixture.runGit([
        'rev-parse',
        'refs/heads/main',
      ], workingDirectory: origin);
      expect(remoteHead.stdout.toString().trim(), localHead);
    },
  );

  test(
    'pushes only the current upstream when push.default is matching',
    () async {
      await fixture.writeFile('README.md', '# Git Desktop\n');
      final initialHead = await fixture.commit('Initial commit');
      final origin = await fixture.createBareOrigin();
      await fixture.runGit(['push', '--set-upstream', 'origin', 'main']);
      await fixture.runGit(['branch', 'release']);
      await fixture.runGit(['push', '--set-upstream', 'origin', 'release']);
      await fixture.runGit(['switch', 'release']);
      await fixture.writeFile('release.txt', 'release\n');
      await fixture.commit('Release commit');
      await fixture.runGit(['switch', 'main']);
      await fixture.writeFile('main.txt', 'main\n');
      final mainHead = await fixture.commit('Main commit');
      await fixture.runGit(['config', 'push.default', 'matching']);
      final repository = (await inspector.inspect(
        fixture.workingDirectory.path,
      ))!;

      await writer.pushUpstream(repository);

      expect(
        (await fixture.runGit([
          'rev-parse',
          'refs/heads/main',
        ], workingDirectory: origin)).stdout.toString().trim(),
        mainHead,
      );
      expect(
        (await fixture.runGit([
          'rev-parse',
          'refs/heads/release',
        ], workingDirectory: origin)).stdout.toString().trim(),
        initialHead,
      );
    },
  );

  test('pushes to an upstream branch with a different name', () async {
    await fixture.writeFile('README.md', '# Git Desktop\n');
    await fixture.commit('Initial commit');
    final origin = await fixture.createBareOrigin();
    await fixture.runGit(['push', 'origin', 'main:release']);
    await fixture.runGit(['switch', '-c', 'feature']);
    await fixture.runGit(['config', 'branch.feature.remote', 'origin']);
    await fixture.runGit([
      'config',
      'branch.feature.merge',
      'refs/heads/release',
    ]);
    await fixture.writeFile('feature.txt', 'feature\n');
    final featureHead = await fixture.commit('Feature commit');
    await fixture.runGit(['config', 'push.default', 'simple']);
    final repository = (await inspector.inspect(
      fixture.workingDirectory.path,
    ))!;

    await writer.pushUpstream(repository);

    expect(
      (await fixture.runGit([
        'rev-parse',
        'refs/heads/release',
      ], workingDirectory: origin)).stdout.toString().trim(),
      featureHead,
    );
  });

  test(
    'verifies whether the configured upstream contains local HEAD',
    () async {
      await fixture.writeFile('README.md', '# Git Desktop\n');
      await fixture.commit('Initial commit');
      await fixture.createBareOrigin();
      await fixture.runGit(['push', '--set-upstream', 'origin', 'main']);
      await fixture.writeFile('CHANGELOG.md', '# Changes\n');
      await fixture.commit('Add changelog');
      final repository = (await inspector.inspect(
        fixture.workingDirectory.path,
      ))!;

      expect(await writer.verifyUpstream(repository), isFalse);
      await writer.pushUpstream(repository);
      expect(await writer.verifyUpstream(repository), isTrue);
    },
  );

  test(
    'honors a cancelled upstream verification token before starting Git',
    () async {
      final repository = (await inspector.inspect(
        fixture.workingDirectory.path,
      ))!;
      final cancellation = GitCancellationToken()..cancel();

      await expectLater(
        writer.verifyUpstream(repository, cancellationToken: cancellation),
        throwsA(isA<GitCancelledException>()),
      );
    },
  );

  test('honors a cancelled push token before starting Git', () async {
    final repository = (await inspector.inspect(
      fixture.workingDirectory.path,
    ))!;
    final cancellation = GitCancellationToken()..cancel();

    await expectLater(
      writer.pushUpstream(repository, cancellationToken: cancellation),
      throwsA(isA<GitCancelledException>()),
    );
  });
}
