import 'dart:io';
import 'dart:ffi' as ffi;

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

  test('refuses removal through a symlinked work-tree parent', () async {
    if (!Platform.isMacOS) return;
    final outside = await Directory.systemTemp.createTemp(
      'git-desktop-removal-outside-',
    );
    addTearDown(() => outside.delete(recursive: true));
    final outsideFile = File('${outside.path}/keep.txt');
    await outsideFile.writeAsString('keep\n');
    await Link('${fixture.workingDirectory.path}/linked').create(outside.path);
    final repository = (await inspector.inspect(
      fixture.workingDirectory.path,
    ))!;

    await expectLater(
      writer.removeWorkingTreePath(
        repository,
        GitPath.fromString('linked/keep.txt'),
      ),
      throwsA(isA<GitException>()),
    );

    expect(await outsideFile.readAsString(), 'keep\n');
  });

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

  test('stages one working-tree hunk without touching another hunk', () async {
    await fixture.writeFile(
      'README.md',
      '${List<String>.generate(16, (index) => 'line ${index + 1}').join('\n')}\n',
    );
    await fixture.commit('Base');
    await fixture.writeFile(
      'README.md',
      '${List<String>.generate(16, (index) => switch (index + 1) {
        2 => 'changed 2',
        14 => 'changed 14',
        _ => 'line ${index + 1}',
      }).join('\n')}\n',
    );
    final repository = (await inspector.inspect(
      fixture.workingDirectory.path,
    ))!;
    final diff = await reader.readUnifiedDiff(repository, path: 'README.md');

    await writer.stageDiffHunk(repository, diff: diff, hunkIndex: 0);

    final staged = await reader.readUnifiedDiff(
      repository,
      path: 'README.md',
      source: GitDiffSource.staged,
    );
    final unstaged = await reader.readUnifiedDiff(
      repository,
      path: 'README.md',
    );
    expect(staged.text, contains('changed 2'));
    expect(staged.text, isNot(contains('changed 14')));
    expect(unstaged.text, isNot(contains('changed 2')));
    expect(unstaged.text, contains('changed 14'));
  });

  test(
    'rejects hunk writes when a text diff also changes executable mode',
    () async {
      await fixture.writeFile(
        'README.md',
        '${List<String>.generate(16, (index) => 'line ${index + 1}').join('\n')}\n',
      );
      await fixture.commit('Base');
      await fixture.runGit(['update-index', '--chmod=+x', '--', 'README.md']);
      await fixture.runGit(['checkout-index', '--force', '--', 'README.md']);
      await fixture.runGit(['reset', 'HEAD', '--', 'README.md']);
      await fixture.writeFile(
        'README.md',
        '${List<String>.generate(16, (index) => switch (index + 1) {
          2 => 'changed 2',
          14 => 'changed 14',
          _ => 'line ${index + 1}',
        }).join('\n')}\n',
      );
      final file = File(
        '${fixture.workingDirectory.path}${Platform.pathSeparator}README.md',
      );
      final repository = (await inspector.inspect(
        fixture.workingDirectory.path,
      ))!;
      final diff = await reader.readUnifiedDiff(repository, path: 'README.md');
      final contentBefore = await file.readAsString();
      final modeBefore = (await file.stat()).mode;

      expect(diff.changesFileMode, isTrue);
      expect(diff.text, contains('old mode 100644'));
      expect(diff.text, contains('new mode 100755'));
      await expectLater(
        writer.stageDiffHunk(repository, diff: diff, hunkIndex: 0),
        throwsArgumentError,
      );
      await expectLater(
        writer.revertDiffHunk(repository, diff: diff, hunkIndex: 0),
        throwsArgumentError,
      );
      expect(await file.readAsString(), contentBefore);
      expect((await file.stat()).mode, modeBefore);
    },
  );

  test('discards one working-tree hunk without touching another hunk', () async {
    await fixture.writeFile(
      'README.md',
      '${List<String>.generate(16, (index) => 'line ${index + 1}').join('\n')}\n',
    );
    await fixture.commit('Base');
    await fixture.writeFile(
      'README.md',
      '${List<String>.generate(16, (index) => switch (index + 1) {
        2 => 'changed 2',
        14 => 'changed 14',
        _ => 'line ${index + 1}',
      }).join('\n')}\n',
    );
    final repository = (await inspector.inspect(
      fixture.workingDirectory.path,
    ))!;
    final diff = await reader.readUnifiedDiff(repository, path: 'README.md');

    await writer.revertDiffHunk(repository, diff: diff, hunkIndex: 0);

    final content = await File(
      '${fixture.workingDirectory.path}${Platform.pathSeparator}README.md',
    ).readAsString();
    expect(content, contains('line 2\n'));
    expect(content, contains('changed 14\n'));
    final remaining = await reader.readUnifiedDiff(
      repository,
      path: 'README.md',
    );
    expect(remaining.text, isNot(contains('changed 2')));
    expect(remaining.text, contains('changed 14'));
  });

  test(
    'unstages one staged hunk while retaining its work-tree content',
    () async {
      await fixture.writeFile(
        'README.md',
        '${List<String>.generate(16, (index) => 'line ${index + 1}').join('\n')}\n',
      );
      await fixture.commit('Base');
      await fixture.writeFile(
        'README.md',
        '${List<String>.generate(16, (index) => switch (index + 1) {
          2 => 'changed 2',
          14 => 'changed 14',
          _ => 'line ${index + 1}',
        }).join('\n')}\n',
      );
      final repository = (await inspector.inspect(
        fixture.workingDirectory.path,
      ))!;
      final entry = (await reader.readStatus(repository)).entries.single;
      await writer.stagePath(repository, entry.path);
      final staged = await reader.readUnifiedDiff(
        repository,
        path: 'README.md',
        source: GitDiffSource.staged,
      );

      await writer.revertDiffHunk(repository, diff: staged, hunkIndex: 0);

      final stagedAfter = await reader.readUnifiedDiff(
        repository,
        path: 'README.md',
        source: GitDiffSource.staged,
      );
      final workTreeAfter = await reader.readUnifiedDiff(
        repository,
        path: 'README.md',
      );
      expect(stagedAfter.text, isNot(contains('changed 2')));
      expect(stagedAfter.text, contains('changed 14'));
      expect(workTreeAfter.text, contains('changed 2'));
    },
  );

  test(
    'reverse-applies one committed hunk without rewriting the commit',
    () async {
      await fixture.writeFile(
        'README.md',
        '${List<String>.generate(16, (index) => 'line ${index + 1}').join('\n')}\n',
      );
      final base = await fixture.commit('Base');
      await fixture.writeFile(
        'README.md',
        '${List<String>.generate(16, (index) => switch (index + 1) {
          2 => 'changed 2',
          14 => 'changed 14',
          _ => 'line ${index + 1}',
        }).join('\n')}\n',
      );
      final changed = await fixture.commit('Change two hunks');
      final repository = (await inspector.inspect(
        fixture.workingDirectory.path,
      ))!;
      final diff = await reader.readCommitUnifiedDiff(
        repository,
        objectId: changed,
        parentObjectId: base,
        path: 'README.md',
      );

      await writer.revertDiffHunk(repository, diff: diff, hunkIndex: 0);

      final content = await File(
        '${fixture.workingDirectory.path}${Platform.pathSeparator}README.md',
      ).readAsString();
      expect(content, contains('line 2\n'));
      expect(content, contains('changed 14\n'));
      expect(
        (await fixture.runGit(['rev-parse', 'HEAD'])).stdout.toString().trim(),
        changed,
      );
    },
  );

  test(
    'reverse-applies a committed new-file hunk as a working-tree deletion',
    () async {
      await fixture.writeFile('new-file.txt', 'first\nsecond\nthird\n');
      final added = await fixture.commit('Add file');
      final repository = (await inspector.inspect(
        fixture.workingDirectory.path,
      ))!;
      final diff = await reader.readCommitUnifiedDiff(
        repository,
        objectId: added,
        path: 'new-file.txt',
      );

      await writer.revertDiffHunk(repository, diff: diff, hunkIndex: 0);

      expect(
        await File(
          '${fixture.workingDirectory.path}${Platform.pathSeparator}new-file.txt',
        ).exists(),
        isFalse,
      );
      expect(
        (await fixture.runGit(['rev-parse', 'HEAD'])).stdout.toString().trim(),
        added,
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

  test(
    'stops tracking a file while preserving its work-tree content',
    () async {
      await fixture.writeFile('config/local.json', '{"version": 1}\n');
      await fixture.commit('Add local config');
      await fixture.writeFile('config/local.json', '{"version": 2}\n');

      final repository = (await inspector.inspect(
        fixture.workingDirectory.path,
      ))!;
      final before = await reader.readStatus(repository);

      await writer.stopTrackingPaths(repository, [before.entries.single.path]);

      final after = await reader.readStatus(repository);
      expect(
        after.entries.any(
          (entry) =>
              entry.path.display == 'config/local.json' &&
              entry.indexStatus == GitChangeType.deleted,
        ),
        isTrue,
      );
      expect(
        after.entries.any(
          (entry) =>
              entry.path.display == 'config/local.json' &&
              entry.kind == GitFileStatusKind.untracked,
        ),
        isTrue,
      );
      expect(
        await File(
          '${fixture.workingDirectory.path}${Platform.pathSeparator}config'
          '${Platform.pathSeparator}local.json',
        ).readAsString(),
        '{"version": 2}\n',
      );
    },
  );

  test('resolves a conflicted file using the selected side', () async {
    final repository = await _createContentConflict(fixture, inspector);
    final conflicted = (await reader.readStatus(repository)).entries.single;

    await writer.resolveConflictUsingSide(
      repository,
      conflicted.path,
      useOurs: true,
    );

    final resolved = await reader.readStatus(repository);
    expect(resolved.conflictedEntries, isEmpty);
    expect(resolved.entries, isEmpty);
    expect(
      await File(
        '${fixture.workingDirectory.path}${Platform.pathSeparator}conflict.txt',
      ).readAsString(),
      'main version\n',
    );
  });

  test('writes and stages a custom internal Diff conflict result', () async {
    final repository = await _createContentConflict(fixture, inspector);
    final conflicted = (await reader.readStatus(repository)).entries.single;

    await writer.resolveConflictWithContent(
      repository,
      conflicted.path,
      'custom merged result\n',
    );

    final resolved = await reader.readStatus(repository);
    expect(resolved.conflictedEntries, isEmpty);
    expect(resolved.stagedEntries, hasLength(1));
    expect(
      await File(
        '${fixture.workingDirectory.path}${Platform.pathSeparator}conflict.txt',
      ).readAsString(),
      'custom merged result\n',
    );
    expect(
      await Directory(fixture.workingDirectory.path)
          .list()
          .where(
            (entity) => entity.path
                .split(Platform.pathSeparator)
                .last
                .startsWith('.git-desktop-resolve.'),
          )
          .isEmpty,
      isTrue,
    );
  });

  test('keeps the original conflict file when publication fails', () async {
    if (!Platform.isMacOS) return;
    final repository = await _createContentConflict(fixture, inspector);
    final conflicted = (await reader.readStatus(repository)).entries.single;
    final conflictFile = File(
      '${fixture.workingDirectory.path}${Platform.pathSeparator}conflict.txt',
    );
    final original = await conflictFile.readAsBytes();
    final failingWriter = GitRepositoryWriter(
      GitRunner(),
      beforeConflictResultPublicationForTesting: () {
        throw const FileSystemException('injected publication failure');
      },
    );

    await expectLater(
      failingWriter.resolveConflictWithContent(
        repository,
        conflicted.path,
        'must never replace the original\n',
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(await conflictFile.readAsBytes(), original);
    expect((await reader.readStatus(repository)).conflictedEntries, isNotEmpty);
    expect(
      await Directory(fixture.workingDirectory.path)
          .list()
          .where(
            (entity) => entity.path
                .split(Platform.pathSeparator)
                .last
                .startsWith('.git-desktop-resolve.'),
          )
          .isEmpty,
      isTrue,
    );
  });

  test(
    'does not overwrite a conflict path replaced before publication',
    () async {
      if (!Platform.isMacOS) return;
      final repository = await _createContentConflict(fixture, inspector);
      final conflicted = (await reader.readStatus(repository)).entries.single;
      final conflictFile = File(
        '${fixture.workingDirectory.path}${Platform.pathSeparator}conflict.txt',
      );
      final displacedFile = File('${conflictFile.path}.displaced');
      final racingWriter = GitRepositoryWriter(
        GitRunner(),
        beforeConflictResultPublicationForTesting: () async {
          await conflictFile.rename(displacedFile.path);
          await conflictFile.writeAsString('concurrent replacement\n');
        },
      );

      await expectLater(
        racingWriter.resolveConflictWithContent(
          repository,
          conflicted.path,
          'must not overwrite replacement\n',
        ),
        throwsA(isA<GitException>()),
      );

      expect(await conflictFile.readAsString(), 'concurrent replacement\n');
      expect(await displacedFile.exists(), isTrue);
    },
  );

  test('preserves an executable conflict file mode on macOS', () async {
    if (!Platform.isMacOS) return;
    final repository = await _createContentConflict(fixture, inspector);
    final conflicted = (await reader.readStatus(repository)).entries.single;
    final conflictFile = File(
      '${fixture.workingDirectory.path}${Platform.pathSeparator}conflict.txt',
    );
    final chmod = await Process.run('/bin/chmod', ['0751', conflictFile.path]);
    expect(chmod.exitCode, 0, reason: chmod.stderr);

    await writer.resolveConflictWithContent(
      repository,
      conflicted.path,
      'mode-preserving result\n',
    );

    expect((await conflictFile.stat()).mode & 0x1ff, 0x1e9);
  });

  test('applies the process umask when recreating a conflict file', () async {
    if (!Platform.isMacOS) return;
    final repository = await _createContentConflict(fixture, inspector);
    final conflicted = (await reader.readStatus(repository)).entries.single;
    final conflictFile = File(
      '${fixture.workingDirectory.path}${Platform.pathSeparator}conflict.txt',
    );
    await conflictFile.delete();
    final umask = ffi.DynamicLibrary.process()
        .lookupFunction<ffi.Uint16 Function(ffi.Uint16), int Function(int)>(
          'umask',
        );
    final previousUmask = umask(0x3f);
    try {
      await writer.resolveConflictWithContent(
        repository,
        conflicted.path,
        'recreated securely\n',
      );
    } finally {
      umask(previousUmask);
    }

    expect((await conflictFile.stat()).mode & 0x1ff, 0x180);
  });

  test(
    'marks a resolved file unresolved and rebuilds conflict markers',
    () async {
      final repository = await _createContentConflict(fixture, inspector);
      final conflicted = (await reader.readStatus(repository)).entries.single;
      await writer.stagePath(repository, conflicted.path);
      expect((await reader.readStatus(repository)).conflictedEntries, isEmpty);

      await writer.markConflictUnresolved(repository, conflicted.path);
      expect(
        (await reader.readStatus(repository)).conflictedEntries,
        hasLength(1),
      );

      await writer.restartConflictMerge(repository, conflicted.path);
      final contents = await File(
        '${fixture.workingDirectory.path}${Platform.pathSeparator}conflict.txt',
      ).readAsString();
      expect(contents, contains('<<<<<<<'));
      expect(contents, contains('main version'));
      expect(contents, contains('feature version'));
    },
  );

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

  test(
    'creates, lists, applies and pops a stash with its staged index',
    () async {
      await fixture.writeFile('README.md', '# Git Desktop\n');
      await fixture.commit('Initial commit');
      await fixture.writeFile('README.md', '# Git Desktop\nStaged change\n');
      await fixture.writeFile('draft.txt', 'untracked draft\n');
      final repository = (await inspector.inspect(
        fixture.workingDirectory.path,
      ))!;
      final before = await reader.readStatus(repository);
      await writer.stagePath(
        repository,
        before.entries
            .singleWhere((entry) => entry.path.display == 'README.md')
            .path,
      );

      await writer.createStash(
        repository,
        message: 'save staged work',
        includeUntracked: true,
      );

      expect((await reader.readStatus(repository)).entries, isEmpty);
      final stashes = await reader.readStashes(repository);
      expect(stashes, hasLength(1));
      expect(stashes.single.reference, 'stash@{0}');
      expect(stashes.single.message, contains('save staged work'));

      await writer.applyStash(
        repository,
        stashReference: stashes.single.reference,
      );
      final applied = await reader.readStatus(repository);
      expect(
        applied.entries
            .singleWhere((entry) => entry.path.display == 'README.md')
            .hasStagedChange,
        isTrue,
      );
      expect(
        applied.entries.map((entry) => entry.path.display),
        contains('draft.txt'),
      );
      expect(await reader.readStashes(repository), hasLength(1));

      await writer.dropStash(
        repository,
        stashReference: stashes.single.reference,
      );
      expect(await reader.readStashes(repository), isEmpty);
      await writer.createStash(
        repository,
        message: 'restore and pop',
        includeUntracked: true,
      );
      final popEntry = (await reader.readStashes(repository)).single;
      await writer.popStash(repository, stashReference: popEntry.reference);
      expect(await reader.readStashes(repository), isEmpty);
      expect(
        (await reader.readStatus(repository)).entries
            .singleWhere((entry) => entry.path.display == 'README.md')
            .hasStagedChange,
        isTrue,
      );
    },
  );

  test('drops a selected stash and rejects non-stash references', () async {
    await fixture.writeFile('README.md', '# Git Desktop\n');
    await fixture.commit('Initial commit');
    await fixture.writeFile('README.md', '# Git Desktop\nSaved\n');
    final repository = (await inspector.inspect(
      fixture.workingDirectory.path,
    ))!;
    await writer.createStash(repository, message: 'discard later');
    final entry = (await reader.readStashes(repository)).single;

    await writer.dropStash(repository, stashReference: entry.reference);
    expect(await reader.readStashes(repository), isEmpty);
    expect(
      () => writer.applyStash(repository, stashReference: 'HEAD'),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('keeps staged changes when creating a stash with keep-index', () async {
    await fixture.writeFile('README.md', '# Git Desktop\n');
    await fixture.commit('Initial commit');
    await fixture.writeFile('README.md', '# Git Desktop\nStaged\n');
    final repository = (await inspector.inspect(
      fixture.workingDirectory.path,
    ))!;
    final changed = (await reader.readStatus(repository)).entries.single;
    await writer.stagePath(repository, changed.path);

    await writer.createStash(
      repository,
      message: 'keep staged',
      keepIndex: true,
    );

    final after = await reader.readStatus(repository);
    expect(after.stagedEntries, hasLength(1));
    expect(
      (await reader.readStashes(repository)).single.message,
      contains('keep staged'),
    );
  });

  test('amends the current commit from the staged index', () async {
    await fixture.writeFile('README.md', '# Git Desktop\n');
    await fixture.commit('Initial commit');
    await fixture.writeFile('README.md', '# Git Desktop\nAmended\n');
    await fixture.writeFile('draft.txt', 'leave unstaged\n');
    final repository = (await inspector.inspect(
      fixture.workingDirectory.path,
    ))!;
    final status = await reader.readStatus(repository);
    await writer.stagePath(
      repository,
      status.entries
          .singleWhere((entry) => entry.path.display == 'README.md')
          .path,
    );

    await writer.createCommit(
      repository,
      message: 'Amended commit',
      amend: true,
    );

    final after = await reader.readStatus(repository);
    final history = await reader.readRecentHistory(repository);
    expect(
      after.entries.map((entry) => entry.path.display),
      contains('draft.txt'),
    );
    expect(history, hasLength(1));
    expect(history.single.subject, 'Amended commit');
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

  test('creates, pushes, and deletes one explicit tag', () async {
    await fixture.writeFile('README.md', '# Tags\n');
    final commit = await fixture.commit('Initial commit');
    final bare = await fixture.createBareOrigin();
    final repository = (await inspector.inspect(
      fixture.workingDirectory.path,
    ))!;

    await writer.createTag(
      repository,
      name: 'v1.0.0',
      objectId: commit,
      annotation: 'First release',
    );
    final tags = await reader.readTags(repository);
    expect(
      tags.singleWhere((tag) => tag.name == 'v1.0.0'),
      predicate<GitTag>(
        (tag) => tag.isAnnotated && tag.targetObjectId == commit,
      ),
    );

    await writer.pushTag(repository, remoteName: 'origin', tagName: 'v1.0.0');
    expect(
      (await fixture.runGit([
        '--git-dir=${bare.path}',
        'show-ref',
        '--verify',
        '--quiet',
        'refs/tags/v1.0.0',
      ])).exitCode,
      0,
    );

    await writer.deleteRemoteTag(
      repository,
      remoteName: 'origin',
      tagName: 'v1.0.0',
    );
    await writer.deleteTag(repository, name: 'v1.0.0');
    expect(await reader.readTags(repository), isEmpty);
    expect(
      (await fixture.runGit([
        '--git-dir=${bare.path}',
        'show-ref',
        '--verify',
        '--quiet',
        'refs/tags/v1.0.0',
      ], throwOnError: false)).exitCode,
      isNot(0),
    );
  });

  test(
    'creates an annotated tag with an empty message without opening an editor',
    () async {
      await fixture.writeFile('README.md', '# Empty annotation\n');
      final commit = await fixture.commit('Initial commit');
      final repository = (await inspector.inspect(
        fixture.workingDirectory.path,
      ))!;

      await writer.createTag(
        repository,
        name: 'v1.0.1',
        objectId: commit,
        annotation: '',
        annotated: true,
      );

      final tag = (await reader.readTags(
        repository,
      )).singleWhere((candidate) => candidate.name == 'v1.0.1');
      expect(tag.isAnnotated, isTrue);
      expect(tag.targetObjectId, commit);
    },
  );

  test('rejects unsafe tag names before running Git', () async {
    final repository = (await inspector.inspect(
      fixture.workingDirectory.path,
    ))!;

    await expectLater(
      writer.createTag(
        repository,
        name: '--invalid',
        objectId: '0123456789abcdef',
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('creates a local branch from the selected local branch ref', () async {
    await fixture.writeFile('README.md', 'base\n');
    await fixture.commit('Initial commit');
    await fixture.runGit(['branch', 'feature/source']);
    await fixture.runGit(['switch', 'feature/source']);
    await fixture.writeFile('feature.txt', 'feature\n');
    final sourceCommit = await fixture.commit('Feature commit');
    await fixture.runGit(['switch', 'main']);
    final repository = (await inspector.inspect(
      fixture.workingDirectory.path,
    ))!;

    await writer.createLocalBranchFromLocalBranch(
      repository,
      name: 'feature/copied',
      sourceName: 'feature/source',
    );

    expect(
      (await fixture.runGit([
        'rev-parse',
        'refs/heads/feature/copied',
      ])).stdout.toString().trim(),
      sourceCommit,
    );
  });

  test('renames a local branch without overwriting another ref', () async {
    await fixture.writeFile('README.md', 'base\n');
    await fixture.commit('Initial commit');
    await fixture.runGit(['branch', 'feature/old-name']);
    final repository = (await inspector.inspect(
      fixture.workingDirectory.path,
    ))!;

    await writer.renameLocalBranch(
      repository,
      oldName: 'feature/old-name',
      newName: 'feature/new-name',
    );

    await fixture.runGit([
      'show-ref',
      '--verify',
      '--quiet',
      'refs/heads/feature/new-name',
    ]);
    final oldRef = await fixture.runGit([
      'show-ref',
      '--verify',
      '--quiet',
      'refs/heads/feature/old-name',
    ], throwOnError: false);
    expect(oldRef.exitCode, isNot(0));
  });

  test('safely deletes only a merged local branch', () async {
    await fixture.writeFile('README.md', 'base\n');
    await fixture.commit('Initial commit');
    await fixture.runGit(['branch', 'feature/merged']);
    final repository = (await inspector.inspect(
      fixture.workingDirectory.path,
    ))!;

    await writer.deleteMergedLocalBranch(repository, name: 'feature/merged');

    final deletedRef = await fixture.runGit([
      'show-ref',
      '--verify',
      '--quiet',
      'refs/heads/feature/merged',
    ], throwOnError: false);
    expect(deletedRef.exitCode, isNot(0));
  });

  test('refuses to delete a local branch with unmerged commits', () async {
    await fixture.writeFile('README.md', 'base\n');
    await fixture.commit('Initial commit');
    await fixture.runGit(['branch', 'feature/unmerged']);
    await fixture.runGit(['switch', 'feature/unmerged']);
    await fixture.writeFile('feature.txt', 'unmerged\n');
    await fixture.commit('Unmerged feature commit');
    await fixture.runGit(['switch', 'main']);
    final repository = (await inspector.inspect(
      fixture.workingDirectory.path,
    ))!;

    await expectLater(
      writer.deleteMergedLocalBranch(repository, name: 'feature/unmerged'),
      throwsA(isA<GitCommandException>()),
    );

    await fixture.runGit([
      'show-ref',
      '--verify',
      '--quiet',
      'refs/heads/feature/unmerged',
    ]);
  });

  test('force deletes an unmerged local branch only when requested', () async {
    await fixture.writeFile('README.md', 'base\n');
    await fixture.commit('Initial commit');
    await fixture.runGit(['branch', 'feature/force-delete']);
    await fixture.runGit(['switch', 'feature/force-delete']);
    await fixture.writeFile('feature.txt', 'unmerged\n');
    await fixture.commit('Unmerged feature commit');
    await fixture.runGit(['switch', 'main']);
    final repository = (await inspector.inspect(
      fixture.workingDirectory.path,
    ))!;

    await writer.deleteLocalBranch(
      repository,
      name: 'feature/force-delete',
      force: true,
    );

    final deletedRef = await fixture.runGit([
      'show-ref',
      '--verify',
      '--quiet',
      'refs/heads/feature/force-delete',
    ], throwOnError: false);
    expect(deletedRef.exitCode, isNot(0));
  });

  test('deletes a selected remote-tracking branch from its remote', () async {
    await fixture.writeFile('README.md', 'base\n');
    await fixture.commit('Initial commit');
    final origin = await fixture.createBareOrigin();
    await fixture.runGit(['push', 'origin', 'main']);
    await fixture.runGit(['branch', 'feature/remote-delete']);
    await fixture.runGit(['push', 'origin', 'feature/remote-delete']);
    final repository = (await inspector.inspect(
      fixture.workingDirectory.path,
    ))!;

    await writer.deleteRemoteBranch(
      repository,
      remoteName: 'origin/feature/remote-delete',
    );

    final remoteRef = await Process.run('git', [
      'show-ref',
      '--verify',
      '--quiet',
      'refs/heads/feature/remote-delete',
    ], workingDirectory: origin.path);
    expect(remoteRef.exitCode, isNot(0));
  });

  test('rejects an option-shaped remote when deleting a branch', () async {
    final repository = (await inspector.inspect(
      fixture.workingDirectory.path,
    ))!;
    await expectLater(
      writer.deleteRemoteBranch(repository, remoteName: '--mirror/topic'),
      throwsArgumentError,
    );
  });

  test('removes only the local configuration for a remote', () async {
    await fixture.writeFile('README.md', 'base\n');
    await fixture.commit('Initial commit');
    final origin = await fixture.createBareOrigin();
    final repository = (await inspector.inspect(
      fixture.workingDirectory.path,
    ))!;

    await writer.removeRemote(repository, 'origin');

    final remotes = (await fixture.runGit([
      'remote',
    ])).stdout.toString().split('\n').where((name) => name.isNotEmpty);
    expect(remotes, isNot(contains('origin')));
    expect(await Directory(origin.path).exists(), isTrue);
  });

  test('rejects an option-shaped remote name before invoking Git', () async {
    final repository = (await inspector.inspect(
      fixture.workingDirectory.path,
    ))!;

    await expectLater(
      writer.removeRemote(repository, '--help'),
      throwsArgumentError,
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
    'merges a historical commit without resolving an unrelated ref name',
    () async {
      await fixture.writeFile('README.md', 'base\n');
      await fixture.commit('Initial commit');
      await fixture.runGit(['switch', '-c', 'feature/commit-source']);
      await fixture.writeFile('feature.txt', 'feature\n');
      final featureCommit = await fixture.commit('Feature commit');
      await fixture.runGit(['switch', 'main']);
      await fixture.writeFile('main.txt', 'main\n');
      await fixture.commit('Main commit');
      final repository = (await inspector.inspect(
        fixture.workingDirectory.path,
      ))!;

      await writer.mergeCommit(repository, objectId: featureCommit);

      final parents = (await reader.readRecentHistory(
        repository,
      )).first.parentIds;
      expect(parents, contains(featureCommit));
      expect(parents, hasLength(2));
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

  test('rejects clone URLs containing credentials or query data', () async {
    final directory = await Directory.systemTemp.createTemp(
      'git-desktop-clone-credentials-',
    );
    addTearDown(() => directory.delete(recursive: true));

    for (final remoteUrl in const [
      'https://user:top-secret@example.test/repository.git',
      'https://example.test/repository.git?access_token=top-secret',
      'ftp://user:top-secret@example.test/repository.git',
      'ssh://user:top-secret@example.test/repository.git',
      'ssh://user%3Atop-secret@example.test/repository.git',
      'ssh://git@example.test/repository.git#top-secret',
      'user:top-secret@example.test:repository.git',
    ]) {
      await expectLater(
        writer.cloneRepository(
          remoteUrl: remoteUrl,
          directoryPath: directory.path,
        ),
        throwsA(
          isA<GitException>().having(
            (error) => error.toString(),
            'message',
            isNot(contains('top-secret')),
          ),
        ),
      );
    }
    expect(await directory.list().isEmpty, isTrue);
  });

  test('allows a normal SCP-style SSH clone URL through validation', () async {
    final directory = await Directory.systemTemp.createTemp(
      'git-desktop-clone-ssh-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final recordingWriter = GitRepositoryWriter(
      GitRunner(executable: '/usr/bin/true'),
    );

    await recordingWriter.cloneRepository(
      remoteUrl: 'git@example.test:owner/repository.git',
      directoryPath: directory.path,
    );
    await recordingWriter.cloneRepository(
      remoteUrl: 'ssh://git@example.test/owner/repository.git',
      directoryPath: directory.path,
    );
  });

  test('rejects clone URLs that invoke Git remote helpers', () async {
    final directory = await Directory.systemTemp.createTemp(
      'git-desktop-clone-helper-',
    );
    addTearDown(() => directory.delete(recursive: true));

    for (final remoteUrl in const [
      'ext::sh -c id',
      'unknown::payload',
      'javascript://example.test/repository.git',
    ]) {
      await expectLater(
        writer.cloneRepository(
          remoteUrl: remoteUrl,
          directoryPath: directory.path,
        ),
        throwsA(isA<GitException>()),
      );
    }
    expect(await directory.list().isEmpty, isTrue);
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

  test(
    'fetches all remotes while pruning refs and retrieving every tag',
    () async {
      await fixture.writeFile('README.md', '# Git Desktop\n');
      await fixture.commit('Initial commit');
      final origin = await fixture.createBareOrigin();
      await fixture.runGit(['push', 'origin', 'main']);
      await fixture.runGit(['branch', 'feature/prune']);
      await fixture.runGit(['push', 'origin', 'feature/prune']);
      final directory = await Directory.systemTemp.createTemp(
        'git-desktop-fetch-options-',
      );
      addTearDown(() => directory.delete(recursive: true));
      await writer.cloneRepository(
        remoteUrl: origin.path,
        directoryPath: directory.path,
      );
      await fixture.runGit(['switch', 'feature/prune']);
      await fixture.writeFile('tag-only.txt', 'tag target\n');
      await fixture.commit('Tag-only commit');
      await fixture.runGit(['tag', 'v2.0.0']);
      await fixture.runGit(['push', 'origin', 'refs/tags/v2.0.0']);
      await fixture.runGit(['push', 'origin', '--delete', 'feature/prune']);
      final repository = (await inspector.inspect(directory.path))!;

      await writer.fetch(
        repository,
        options: const GitFetchOptions(
          pruneDeletedTrackingBranches: true,
          fetchAllTags: true,
        ),
      );

      final prunedRef = await writer.runner.run(
        GitInvocation(
          arguments: const [
            'show-ref',
            '--verify',
            '--quiet',
            'refs/remotes/origin/feature/prune',
          ],
          workingDirectory: directory.path,
        ),
      );
      expect(prunedRef.exitCode, isNot(0));
      await writer.runner.run(
        GitInvocation(
          arguments: const [
            'show-ref',
            '--verify',
            '--quiet',
            'refs/tags/v2.0.0',
          ],
          workingDirectory: directory.path,
        ),
      );
    },
  );

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

  test('pulls with rebase options and keeps a linear history', () async {
    await fixture.writeFile('README.md', '# Git Desktop\n');
    await fixture.commit('Initial commit');
    final origin = await fixture.createBareOrigin();
    await fixture.runGit(['push', 'origin', 'main']);

    final directory = await Directory.systemTemp.createTemp(
      'git-desktop-rebase-pull-',
    );
    addTearDown(() async {
      if (directory.existsSync()) await directory.delete(recursive: true);
    });
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
      result.throwIfFailed(operation: 'Configuring rebase test repository');
    }

    await File(
      '${directory.path}${Platform.pathSeparator}local.txt',
    ).writeAsString('local\n');
    await writer.stagePath(repository, GitPath.fromString('local.txt'));
    await writer.createCommit(repository, message: 'Local commit');

    await fixture.writeFile('remote.txt', 'remote\n');
    await fixture.commit('Remote commit');
    await fixture.runGit(['push', 'origin', 'main']);

    await writer.pull(
      repository,
      options: const GitPullOptions(
        remoteName: 'origin',
        remoteBranch: 'main',
        rebase: true,
      ),
    );

    final count = await writer.runner.run(
      GitInvocation(
        arguments: const ['rev-list', '--count', 'HEAD'],
        workingDirectory: directory.path,
      ),
    );
    count.throwIfFailed(operation: 'Reading rebase test commit count');
    expect(count.stdoutText.trim(), '3');

    final log = await writer.runner.run(
      GitInvocation(
        arguments: const ['log', '--format=%P', '-3'],
        workingDirectory: directory.path,
      ),
    );
    log.throwIfFailed(operation: 'Reading rebase test history');
    final parentLines = log.stdoutText
        .trim()
        .split('\n')
        .where((line) => line.isNotEmpty)
        .toList();
    expect(parentLines, hasLength(2));
    expect(
      parentLines.every(
        (line) => line.trim().split(RegExp(r'\s+')).length <= 1,
      ),
      isTrue,
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

  test('creates a same-named origin branch on first push', () async {
    await fixture.writeFile('README.md', '# First push\n');
    final localHead = await fixture.commit('Initial commit');
    final origin = await fixture.createBareOrigin();
    final repository = (await inspector.inspect(
      fixture.workingDirectory.path,
    ))!;

    await writer.pushUpstream(repository);

    expect(
      (await fixture.runGit([
        'rev-parse',
        'refs/heads/main',
      ], workingDirectory: origin)).stdout.toString().trim(),
      localHead,
    );
    expect(
      (await fixture.runGit([
        'config',
        '--get',
        'branch.main.remote',
      ])).stdout.toString().trim(),
      'origin',
    );
    expect(
      (await fixture.runGit([
        'config',
        '--get',
        'branch.main.merge',
      ])).stdout.toString().trim(),
      'refs/heads/main',
    );
  });

  test(
    'pushes selected branch mappings, tags, and tracking without force',
    () async {
      await fixture.writeFile('README.md', '# Multi push\n');
      await fixture.commit('Initial commit');
      final origin = await fixture.createBareOrigin();
      await fixture.runGit(['branch', 'feature/release']);
      await fixture.runGit(['switch', 'feature/release']);
      await fixture.writeFile('release.txt', 'release\n');
      final featureHead = await fixture.commit('Release preparation');
      await fixture.runGit(['tag', 'v1.0.0']);
      await fixture.runGit(['switch', 'main']);
      final repository = (await inspector.inspect(
        fixture.workingDirectory.path,
      ))!;

      await writer.pushBranches(
        repository,
        options: const GitPushOptions(
          remoteName: 'origin',
          branches: [
            GitPushBranch(
              localBranch: 'feature/release',
              remoteBranch: 'releases/first',
              trackRemote: true,
            ),
          ],
          pushTags: true,
        ),
      );

      expect(
        (await fixture.runGit([
          'rev-parse',
          'refs/heads/releases/first',
        ], workingDirectory: origin)).stdout.toString().trim(),
        featureHead,
      );
      await fixture.runGit([
        'show-ref',
        '--verify',
        '--quiet',
        'refs/tags/v1.0.0',
      ], workingDirectory: origin);
      expect(
        (await fixture.runGit([
          'config',
          '--get',
          'branch.feature/release.remote',
        ])).stdout.toString().trim(),
        'origin',
      );
      expect(
        (await fixture.runGit([
          'config',
          '--get',
          'branch.feature/release.merge',
        ])).stdout.toString().trim(),
        'refs/heads/releases/first',
      );
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
    'verifies the explicitly selected local branch while HEAD is detached',
    () async {
      await fixture.writeFile('README.md', '# Git Desktop\n');
      await fixture.commit('Initial commit');
      await fixture.createBareOrigin();
      await fixture.runGit(['push', '--set-upstream', 'origin', 'main']);
      await fixture.writeFile('CHANGELOG.md', '# Changes\n');
      final localHead = await fixture.commit('Add changelog');
      await fixture.runGit(['switch', '--detach', 'origin/main']);
      final repository = (await inspector.inspect(
        fixture.workingDirectory.path,
      ))!;

      expect(
        await writer.verifyUpstream(repository, localBranchName: 'main'),
        isFalse,
      );
      await writer.pushUpstream(repository, localBranchName: 'main');
      expect(
        await writer.verifyUpstream(repository, localBranchName: 'main'),
        isTrue,
      );
      expect(
        (await fixture.runGit([
          'rev-parse',
          'refs/heads/main',
        ])).stdout.toString().trim(),
        localHead,
      );
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

  test('resets the checked-out branch to a selected commit', () async {
    await fixture.writeFile('README.md', '# One\n');
    final first = await fixture.commit('First');
    await fixture.writeFile('README.md', '# Two\n');
    await fixture.commit('Second');
    final repository = (await inspector.inspect(
      fixture.workingDirectory.path,
    ))!;

    await writer.resetToCommit(
      repository,
      objectId: first,
      mode: GitResetMode.mixed,
    );

    expect(
      (await fixture.runGit(['rev-parse', 'HEAD'])).stdout.toString().trim(),
      first,
    );
    expect((await reader.readStatus(repository)).entries, isNotEmpty);
  });

  test('reverts and cherry-picks selected commits', () async {
    await fixture.writeFile('README.md', '# Base\n');
    await fixture.commit('Base');
    await fixture.writeFile('README.md', '# Changed\n');
    final change = await fixture.commit('Change README');
    final repository = (await inspector.inspect(
      fixture.workingDirectory.path,
    ))!;

    await writer.revertCommit(repository, objectId: change);
    expect(
      (await reader.readRecentHistory(repository)).first.subject,
      'Revert "Change README"',
    );

    await fixture.runGit(['switch', '-c', 'feature/cherry']);
    await fixture.writeFile('feature.txt', 'cherry\n');
    final featureCommit = await fixture.commit('Feature cherry');
    await fixture.runGit(['switch', 'main']);
    await writer.cherryPickCommit(repository, objectId: featureCommit);
    expect(
      (await reader.readRecentHistory(repository)).first.subject,
      'Feature cherry',
    );
  });

  test('exports a selected commit as a binary-safe patch', () async {
    await fixture.writeFile('README.md', '# Patch\n');
    final commit = await fixture.commit('Patch subject');
    final repository = (await inspector.inspect(
      fixture.workingDirectory.path,
    ))!;
    final patchPath =
        '${fixture.workingDirectory.path}${Platform.pathSeparator}change.patch';

    await writer.createPatch(
      repository,
      objectId: commit,
      outputPath: patchPath,
    );

    expect(
      await File(patchPath).readAsString(),
      contains('Subject: [PATCH] Patch subject'),
    );
  });

  test(
    'checks and applies an exported patch with the default strip level',
    () async {
      await fixture.writeFile('README.md', '# Base\n');
      final base = await fixture.commit('Base');
      await fixture.writeFile('README.md', '# Changed\n');
      final change = await fixture.commit('Change README');
      final repository = (await inspector.inspect(
        fixture.workingDirectory.path,
      ))!;
      final patchPath =
          '${fixture.workingDirectory.path}${Platform.pathSeparator}change.patch';
      await writer.createPatch(
        repository,
        objectId: change,
        outputPath: patchPath,
      );
      await writer.resetToCommit(
        repository,
        objectId: base,
        mode: GitResetMode.hard,
      );

      await writer.applyPatch(
        repository,
        patchPath: patchPath,
        checkOnly: true,
      );
      await writer.applyPatch(repository, patchPath: patchPath);

      expect(
        await File(
          '${fixture.workingDirectory.path}${Platform.pathSeparator}README.md',
        ).readAsString(),
        '# Changed\n',
      );
    },
  );

  test(
    'applies a path-without-prefix patch with an explicit strip level of 0',
    () async {
      await fixture.writeFile('README.md', 'before\n');
      await fixture.commit('Base');
      final repository = (await inspector.inspect(
        fixture.workingDirectory.path,
      ))!;
      final patchPath =
          '${fixture.workingDirectory.path}${Platform.pathSeparator}plain.diff';
      await File(patchPath).writeAsString('''diff --git README.md README.md
index 0000000..0000000 100644
--- README.md
+++ README.md
@@ -1 +1 @@
-before
+after
''');

      await writer.applyPatch(
        repository,
        patchPath: patchPath,
        stripLevel: 0,
        checkOnly: true,
      );
      await writer.applyPatch(repository, patchPath: patchPath, stripLevel: 0);

      expect(
        await File(
          '${fixture.workingDirectory.path}${Platform.pathSeparator}README.md',
        ).readAsString(),
        'after\n',
      );
    },
  );

  test(
    'exports multiple commits as separate patches without overwriting',
    () async {
      await fixture.writeFile('README.md', '# Base\n');
      await fixture.commit('Base');
      await fixture.writeFile('first.txt', 'first\n');
      final first = await fixture.commit('First');
      await fixture.writeFile('second.txt', 'second\n');
      final second = await fixture.commit('Second');
      final repository = (await inspector.inspect(
        fixture.workingDirectory.path,
      ))!;
      final outputDirectory = Directory(
        '${fixture.workingDirectory.path}${Platform.pathSeparator}patches',
      );
      await outputDirectory.create();

      await writer.createPatches(
        repository,
        objectIds: [first, second],
        outputPath: outputDirectory.path,
        createSeparateFiles: true,
      );

      final patches = await outputDirectory
          .list()
          .where((entity) => entity is File)
          .cast<File>()
          .toList();
      expect(patches, hasLength(2));
      final firstPatch = patches.singleWhere(
        (patch) =>
            patch.path.split(Platform.pathSeparator).last.startsWith('0001-'),
      );
      final secondPatch = patches.singleWhere(
        (patch) =>
            patch.path.split(Platform.pathSeparator).last.startsWith('0002-'),
      );
      expect(
        await firstPatch.readAsString(),
        contains('Subject: [PATCH] First'),
      );
      expect(
        await secondPatch.readAsString(),
        contains('Subject: [PATCH] Second'),
      );
      await expectLater(
        writer.createPatches(
          repository,
          objectIds: [first, second],
          outputPath: outputDirectory.path,
          createSeparateFiles: true,
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'keeps an in-place modified published patch when the batch fails',
    () async {
      final commits = <String>[];
      for (var index = 0; index < 12; index++) {
        await fixture.writeFile('file-$index.txt', 'content $index\n');
        commits.add(await fixture.commit('Rollback patch $index'));
      }
      final repository = (await inspector.inspect(
        fixture.workingDirectory.path,
      ))!;
      final outputDirectory = await Directory.systemTemp.createTemp(
        'git-desktop-patch-ownership-',
      );
      addTearDown(() => outputDirectory.delete(recursive: true));
      final firstPath =
          '${outputDirectory.path}/0001-${commits.first.substring(0, 12)}.patch';
      final lastPath =
          '${outputDirectory.path}/0012-${commits.last.substring(0, 12)}.patch';
      final watcher = await Process.start('/bin/sh', [
        '-c',
        'while [ ! -e "\$1" ]; do :; done; '
            'printf "%s\\n" "concurrent user content" > "\$1"; '
            ': > "\$2"',
        'patch-race-watcher',
        firstPath,
        lastPath,
      ]);
      addTearDown(() => watcher.kill());

      await expectLater(
        writer.createPatches(
          repository,
          objectIds: commits,
          outputPath: outputDirectory.path,
          createSeparateFiles: true,
        ),
        throwsArgumentError,
      );
      expect(await watcher.exitCode.timeout(const Duration(seconds: 5)), 0);
      expect(await File(firstPath).readAsString(), 'concurrent user content\n');
    },
  );

  test('uses the edited interactive rebase todo order and actions', () async {
    await fixture.writeFile('README.md', '# Base\n');
    final base = await fixture.commit('Base');
    await fixture.runGit(['branch', 'feature/rebase']);
    await fixture.writeFile('main.txt', 'main\n');
    final upstream = await fixture.commit('Main change');
    await fixture.runGit(['switch', 'feature/rebase']);
    await fixture.writeFile('one.txt', 'one\n');
    final dropped = await fixture.commit('Drop this');
    await fixture.writeFile('two.txt', 'two\n');
    final kept = await fixture.commit('Keep this');
    final repository = (await inspector.inspect(
      fixture.workingDirectory.path,
    ))!;

    await writer.interactiveRebaseOnto(
      repository,
      objectId: upstream,
      instructions: [
        GitInteractiveRebaseInstruction(
          objectId: dropped,
          subject: 'Drop this',
          action: GitInteractiveRebaseAction.drop,
        ),
        GitInteractiveRebaseInstruction(objectId: kept, subject: 'Keep this'),
      ],
    );

    expect(
      (await fixture.runGit([
        'rev-list',
        '--parents',
        '-1',
        'HEAD',
      ])).stdout.toString(),
      contains(upstream),
    );
    expect(
      await File('${fixture.workingDirectory.path}/one.txt').exists(),
      isFalse,
    );
    expect(
      await File('${fixture.workingDirectory.path}/two.txt').exists(),
      isTrue,
    );
    expect(base, isNot(upstream));
  });

  test(
    'uses a selected mainline parent for merge reverts and cherry-picks',
    () async {
      await fixture.writeFile('README.md', '# Base\n');
      final base = await fixture.commit('Base');
      await fixture.runGit(['branch', 'feature/merge-parent']);
      await fixture.writeFile('main.txt', 'main\n');
      await fixture.commit('Main side');
      await fixture.runGit(['switch', 'feature/merge-parent']);
      await fixture.writeFile('feature.txt', 'feature\n');
      await fixture.commit('Feature side');
      await fixture.runGit(['switch', 'main']);
      await fixture.runGit([
        'merge',
        '--no-ff',
        '--no-edit',
        'feature/merge-parent',
      ]);
      final mergeCommit = (await fixture.runGit([
        'rev-parse',
        'HEAD',
      ])).stdout.toString().trim();
      final repository = (await inspector.inspect(
        fixture.workingDirectory.path,
      ))!;

      await writer.revertCommit(
        repository,
        objectId: mergeCommit,
        mainlineParent: 1,
      );
      expect(
        await File('${fixture.workingDirectory.path}/feature.txt').exists(),
        isFalse,
      );

      await fixture.runGit(['switch', '-c', 'replay/merge', base]);
      await writer.cherryPickCommit(
        repository,
        objectId: mergeCommit,
        mainlineParent: 1,
      );
      expect(
        await File('${fixture.workingDirectory.path}/feature.txt').exists(),
        isTrue,
      );
    },
  );
}

Future<GitRepository> _createContentConflict(
  GitTestRepository fixture,
  GitRepositoryInspector inspector,
) async {
  await fixture.writeFile('conflict.txt', 'base\n');
  await fixture.commit('Base');
  await fixture.runGit(['branch', 'feature/conflict-actions']);
  await fixture.runGit(['switch', 'feature/conflict-actions']);
  await fixture.writeFile('conflict.txt', 'feature version\n');
  await fixture.commit('Feature version');
  await fixture.runGit(['switch', 'main']);
  await fixture.writeFile('conflict.txt', 'main version\n');
  await fixture.commit('Main version');
  final merge = await fixture.runGit([
    'merge',
    '--no-edit',
    'feature/conflict-actions',
  ], throwOnError: false);
  expect(merge.exitCode, isNot(0));
  final repository = (await inspector.inspect(fixture.workingDirectory.path))!;
  expect(
    (await GitRepositoryReader(
      GitRunner(),
    ).readStatus(repository)).conflictedEntries,
    hasLength(1),
  );
  return repository;
}
