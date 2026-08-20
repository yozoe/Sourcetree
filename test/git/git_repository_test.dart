import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/git/git.dart';

void main() {
  late Directory temporaryDirectory;
  late GitRunner runner;
  late GitRepositoryInspector inspector;
  late GitRepositoryReader reader;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'git_desktop_test_',
    );
    runner = GitRunner();
    inspector = GitRepositoryInspector(runner);
    reader = GitRepositoryReader(runner);
    await _git(temporaryDirectory.path, ['init', '--quiet']);
    await _git(temporaryDirectory.path, [
      'config',
      'user.name',
      'Git Desktop Test',
    ]);
    await _git(temporaryDirectory.path, [
      'config',
      'user.email',
      'git-desktop@example.invalid',
    ]);
  });

  tearDown(() async {
    if (temporaryDirectory.existsSync()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('recognizes a repository and reads an unborn empty state', () async {
    final nested = Directory(
      '${temporaryDirectory.path}${Platform.pathSeparator}nested',
    )..createSync();

    final repository = await inspector.inspect(nested.path);
    expect(repository, isNotNull);
    expect(repository!.isBare, isFalse);
    expect(repository.isInsideWorkTree, isTrue);
    expect(
      repository.workTreeRoot,
      temporaryDirectory.resolveSymbolicLinksSync(),
    );
    expect(repository.id.commonDirectory, repository.commonDirectory);

    final status = await reader.readStatus(repository);
    expect(status.isClean, isTrue);
    expect(status.branch.isUnborn, isTrue);
    expect(await reader.readRecentHistory(repository), isEmpty);
  });

  test('returns null for a directory outside a repository', () async {
    final outside = await Directory.systemTemp.createTemp(
      'git_desktop_outside_',
    );
    addTearDown(() async {
      if (outside.existsSync()) {
        await outside.delete(recursive: true);
      }
    });

    expect(await inspector.inspect(outside.path), isNull);
    expect(await inspector.isRepository(outside.path), isFalse);
  });

  test('recognizes a bare repository without inventing a worktree', () async {
    final bare = await Directory.systemTemp.createTemp('git_desktop_bare_');
    addTearDown(() async {
      if (bare.existsSync()) {
        await bare.delete(recursive: true);
      }
    });
    await _git(bare.path, ['init', '--quiet', '--bare']);

    final repository = await inspector.inspect(bare.path);
    expect(repository, isNotNull);
    expect(repository!.isBare, isTrue);
    expect(repository.isInsideWorkTree, isFalse);
    expect(repository.workTreeRoot, isNull);
    expect(repository.commandDirectory, repository.commonDirectory);
  });

  test('reads history and literal working tree and staged diffs', () async {
    const fileName = '--literal[abc] ü.txt';
    final file = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}$fileName',
    );
    await file.writeAsString('first\n');
    await _git(temporaryDirectory.path, ['add', '--', fileName]);
    await _git(temporaryDirectory.path, ['commit', '--quiet', '-m', 'first']);
    await file.writeAsString('first\nsecond\n');

    final repository = (await inspector.inspect(temporaryDirectory.path))!;
    final history = await reader.readRecentHistory(repository);
    expect(history, hasLength(1));
    expect(history.single.subject, 'first');
    expect(history.single.parentIds, isEmpty);

    final commitChanges = await reader.readCommitChanges(
      repository,
      objectId: history.single.objectId,
    );
    expect(commitChanges.files, hasLength(1));
    expect(commitChanges.files.single.path.display, fileName);
    expect(commitChanges.files.single.kind, GitCommitChangeKind.added);
    expect(commitChanges.additions, 1);
    expect(commitChanges.deletions, 0);

    final commitDiff = await reader.readCommitUnifiedDiff(
      repository,
      objectId: history.single.objectId,
      path: fileName,
    );
    expect(commitDiff.source, GitDiffSource.commit);
    expect(commitDiff.text, contains('+first'));

    final workingDiff = await reader.readUnifiedDiff(
      repository,
      path: fileName,
    );
    expect(workingDiff.source, GitDiffSource.workingTree);
    expect(workingDiff.text, contains('+second'));
    expect(workingDiff.isTruncated, isFalse);

    await _git(temporaryDirectory.path, ['add', '--', fileName]);
    final stagedDiff = await reader.readUnifiedDiff(
      repository,
      path: fileName,
      source: GitDiffSource.staged,
    );
    expect(stagedDiff.text, contains('+second'));
  });

  test(
    'reads reachable commits from every local branch for the graph',
    () async {
      const fileName = 'graph.txt';
      final file = File(
        '${temporaryDirectory.path}${Platform.pathSeparator}$fileName',
      );
      await file.writeAsString('base\n');
      await _git(temporaryDirectory.path, ['add', '--', fileName]);
      await _git(temporaryDirectory.path, ['commit', '--quiet', '-m', 'base']);

      await _git(temporaryDirectory.path, [
        'checkout',
        '--quiet',
        '-b',
        'feature/history-graph',
      ]);
      await file.writeAsString('feature\n');
      await _git(temporaryDirectory.path, ['add', '--', fileName]);
      await _git(temporaryDirectory.path, [
        'commit',
        '--quiet',
        '-m',
        'feature commit',
      ]);
      await _git(temporaryDirectory.path, ['checkout', '--quiet', '-']);
      await file.writeAsString('main\n');
      await _git(temporaryDirectory.path, ['add', '--', fileName]);
      await _git(temporaryDirectory.path, [
        'commit',
        '--quiet',
        '-m',
        'main commit',
      ]);

      final repository = (await inspector.inspect(temporaryDirectory.path))!;
      final history = await reader.readRecentHistory(repository);

      expect(
        history.map((commit) => commit.subject),
        containsAll(['main commit', 'feature commit', 'base']),
      );
    },
  );

  test('reads merge commit changes against its first parent', () async {
    await File('${temporaryDirectory.path}/base.txt').writeAsString('base\n');
    await _git(temporaryDirectory.path, ['add', '--', 'base.txt']);
    await _git(temporaryDirectory.path, ['commit', '--quiet', '-m', 'base']);
    await _git(temporaryDirectory.path, [
      'checkout',
      '--quiet',
      '-b',
      'feature/merge-diff',
    ]);
    await File(
      '${temporaryDirectory.path}/feature.txt',
    ).writeAsString('feature\n');
    await _git(temporaryDirectory.path, ['add', '--', 'feature.txt']);
    await _git(temporaryDirectory.path, [
      'commit',
      '--quiet',
      '-m',
      'feature change',
    ]);
    await _git(temporaryDirectory.path, ['checkout', '--quiet', '-']);
    await File('${temporaryDirectory.path}/main.txt').writeAsString('main\n');
    await _git(temporaryDirectory.path, ['add', '--', 'main.txt']);
    await _git(temporaryDirectory.path, [
      'commit',
      '--quiet',
      '-m',
      'main change',
    ]);
    await _git(temporaryDirectory.path, [
      'merge',
      '--no-ff',
      '--no-edit',
      'feature/merge-diff',
    ]);

    final repository = (await inspector.inspect(temporaryDirectory.path))!;
    final merge = (await reader.readRecentHistory(
      repository,
    )).firstWhere((commit) => commit.parentIds.length == 2);
    final changes = await reader.readCommitChanges(
      repository,
      objectId: merge.objectId,
      parentObjectId: merge.parentIds.first,
    );
    expect(
      changes.files.map((file) => file.path.display),
      contains('feature.txt'),
    );

    final diff = await reader.readCommitUnifiedDiff(
      repository,
      objectId: merge.objectId,
      parentObjectId: merge.parentIds.first,
      path: 'feature.txt',
    );
    expect(diff.text, contains('+feature'));
  });

  test('reads local branches through for-each-ref', () async {
    const fileName = 'README.md';
    await File(
      '${temporaryDirectory.path}${Platform.pathSeparator}$fileName',
    ).writeAsString('# Git Desktop\n');
    await _git(temporaryDirectory.path, ['add', '--', fileName]);
    await _git(temporaryDirectory.path, ['commit', '--quiet', '-m', 'initial']);
    await _git(temporaryDirectory.path, ['branch', 'feature/list-branches']);

    final repository = (await inspector.inspect(temporaryDirectory.path))!;
    final branches = await reader.readLocalBranches(repository);

    expect(
      branches.map((branch) => branch.name),
      contains('feature/list-branches'),
    );
    expect(branches.every((branch) => branch.objectId.isNotEmpty), isTrue);
  });

  test('marks a diff as truncated at its configured byte limit', () async {
    const fileName = 'large.txt';
    final file = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}$fileName',
    );
    await file.writeAsString('base\n');
    await _git(temporaryDirectory.path, ['add', '--', fileName]);
    await _git(temporaryDirectory.path, ['commit', '--quiet', '-m', 'base']);
    await file.writeAsString('base\n${'changed line\n' * 100}');

    final repository = (await inspector.inspect(temporaryDirectory.path))!;
    final diff = await reader.readUnifiedDiff(
      repository,
      path: fileName,
      maxOutputBytes: 128,
    );

    expect(diff.bytes.length, 128);
    expect(diff.isTruncated, isTrue);
    expect(diff.text, endsWith('… diff output truncated …\n'));
  });
}

Future<void> _git(String workingDirectory, List<String> arguments) async {
  final result = await Process.run(
    'git',
    arguments,
    workingDirectory: workingDirectory,
    runInShell: false,
  );
  if (result.exitCode != 0) {
    throw StateError('git ${arguments.join(' ')} failed: ${result.stderr}');
  }
}
