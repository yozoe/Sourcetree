import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/app/repository_session.dart';
import 'package:git_desktop/src/app/repository_library_controller.dart';
import 'package:git_desktop/src/app/repository_session_store.dart';
import 'package:git_desktop/src/app/repository_view_mapper.dart';
import 'package:git_desktop/src/git/git.dart';
import 'package:git_desktop/src/presentation/presentation.dart';

import '../support/git_test_repository.dart';

void main() {
  test('derives clone directory names from common remote formats', () {
    expect(
      cloneRepositoryNameFromRemote('https://example.com/team/source-tree.git'),
      'source-tree',
    );
    expect(
      cloneRepositoryNameFromRemote('git@example.com:team/source-tree.git'),
      'source-tree',
    );
    expect(
      cloneRepositoryNameFromRemote(
        'ssh://example.com/team/source%20tree.git?ref=main',
      ),
      'source tree',
    );
    expect(
      cloneRepositoryNameFromRemote('/tmp/source-tree.git/'),
      'source-tree',
    );
  });

  test(
    'automatically selects the latest commit and its first file diff',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('README.md', '# Base\n');
      await repository.commit('base');
      await repository.writeFile('lib/example.dart', 'void main() {}\n');
      await repository.commit('add example');

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);

      final overview = mapRepositoryOverview(
        container.read(repositorySessionProvider),
      );
      final selected = overview.repository!;
      expect(selected.selectedCommit!.subject, 'add example');
      expect(selected.selectedCommit!.changedFiles, 1);
      expect(selected.selectedCommit!.additions, 1);
      expect(selected.commitChanges.single.path, 'lib/example.dart');
      expect(selected.selectedCommitFile!.path, 'lib/example.dart');
      expect(selected.commitDiff.lines, isNotEmpty);
    },
  );

  test(
    'keeps uncommitted changes selected throughout a manual refresh',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('first.txt', 'first base\n');
      await repository.writeFile('second.txt', 'second base\n');
      await repository.commit('Base');
      await repository.writeFile('first.txt', 'first changed\n');

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);
      controller.selectUncommittedChanges();
      var overview = mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!;
      await controller.selectChange(overview.changes.single);
      await repository.writeFile('second.txt', 'second changed\n');

      final emitted = <RepositorySessionState>[];
      final subscription = container.listen<RepositorySessionState>(
        repositorySessionProvider,
        (_, next) => emitted.add(next),
      );
      addTearDown(subscription.close);

      await controller.refresh();

      expect(emitted, isNotEmpty);
      expect(
        emitted.every(
          (state) =>
              state.selectedRefId == 'uncommitted' &&
              state.selectedCommitId == null,
        ),
        isTrue,
      );
      final state = container.read(repositorySessionProvider);
      overview = mapRepositoryOverview(state).repository!;
      expect(overview.isUncommittedChangesSelected, isTrue);
      expect(overview.selectedChange?.path, 'first.txt');
      expect(
        overview.changes.map((change) => change.path),
        containsAll(['first.txt', 'second.txt']),
      );
    },
  );

  test('clears a file selection that disappears during refresh', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('first.txt', 'first base\n');
    await repository.writeFile('second.txt', 'second base\n');
    await repository.commit('Base');
    await repository.writeFile('first.txt', 'first changed\n');
    await repository.writeFile('second.txt', 'second changed\n');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    controller.selectUncommittedChanges();
    final overview = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!;
    await controller.selectChange(
      overview.changes.singleWhere((change) => change.path == 'first.txt'),
    );

    await repository.runGit(['restore', '--', 'first.txt']);
    await controller.refresh();

    final state = container.read(repositorySessionProvider);
    final refreshedOverview = mapRepositoryOverview(state).repository!;
    expect(state.selectedRefId, 'uncommitted');
    expect(state.selectedChange, isNull);
    expect(state.diff, isNull);
    expect(refreshedOverview.selectedChange, isNull);
    expect(refreshedOverview.changes.map((change) => change.path), [
      'second.txt',
    ]);
  });

  test('chooses the first UTF-8 commit path for the initial file diff', () {
    final invalid = GitCommitFileChange(
      path: GitPath(<int>[0x69, 0x6e, 0x76, 0x61, 0x6c, 0x69, 0x64, 0xff]),
      kind: GitCommitChangeKind.added,
    );
    final visible = GitCommitFileChange(
      path: GitPath.fromString('visible.txt'),
      kind: GitCommitChangeKind.added,
    );

    expect(firstPreviewableCommitFile([invalid, visible]), same(visible));
    expect(firstPreviewableCommitFile([invalid]), isNull);
  });

  test('patch dry-run returns the session to ready state', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', '# Base\n');
    await repository.commit('Base');
    await repository.writeFile('README.md', '# Changed\n');
    final change = await repository.commit('Change');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    final patchPath =
        '${repository.workingDirectory.path}${Platform.pathSeparator}change.patch';
    expect(
      await controller.createPatchForCommit(change, outputPath: patchPath),
      isTrue,
    );
    await repository.runGit(['reset', '--hard', 'HEAD~1']);

    expect(
      await controller.applyPatchFile(
        patchPath: patchPath,
        stripLevel: null,
        basePath: '',
        checkOnly: true,
      ),
      isTrue,
    );
    expect(
      container.read(repositorySessionProvider).phase,
      RepositorySessionPhase.ready,
    );
  });

  test('loads older history pages and stops at the oldest commit', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    for (var index = 0; index < 102; index++) {
      await repository.writeFile('README.md', 'revision $index\n');
      await repository.commit('commit $index');
    }
    final oldestCommit = (await repository.runGit([
      'rev-parse',
      'HEAD~101',
    ])).stdout.toString().trim();
    await repository.runGit([
      'update-ref',
      'refs/remotes/origin/archive',
      oldestCommit,
    ]);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);

    final firstPage = container.read(repositorySessionProvider);
    expect(firstPage.commits, hasLength(100));
    expect(firstPage.hasMoreHistory, isTrue);
    expect(firstPage.commits.first.subject, 'commit 101');

    await controller.selectReference(
      const RepositoryRefViewData(
        id: 'refs/remotes/origin/archive',
        label: 'origin/archive',
        kind: RepositoryRefKind.remoteBranch,
      ),
    );
    expect(
      container.read(repositorySessionProvider).commits.first.objectId,
      oldestCommit,
    );

    // Move the live branch after page one. Pagination must continue from the
    // original revision snapshot rather than skipping the now-unreachable tail.
    await repository.runGit([
      'update-ref',
      'refs/heads/${repository.initialBranch}',
      'HEAD~2',
    ]);

    await controller.loadMoreHistory();

    final completedHistory = container.read(repositorySessionProvider);
    expect(completedHistory.commits, hasLength(102));
    expect(completedHistory.hasMoreHistory, isFalse);
    expect(completedHistory.isHistoryLoading, isFalse);
    expect(completedHistory.historyOffset, 102);
    expect(
      completedHistory.commits.map((commit) => commit.subject),
      List<String>.generate(102, (index) => 'commit ${101 - index}'),
    );
    expect(
      completedHistory.commits.map((commit) => commit.objectId).toSet(),
      hasLength(102),
    );
  });

  test('always shows the stashes navigation entry below remote refs', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', '# Initial\n');
    await repository.commit('initial');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);

    final refs = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!.refs;
    final stashIndex = refs.indexWhere(
      (reference) => reference.kind == RepositoryRefKind.stash,
    );
    final lastRemoteIndex = refs.lastIndexWhere(
      (reference) => reference.kind == RepositoryRefKind.remoteBranch,
    );
    expect(stashIndex, greaterThan(lastRemoteIndex));
    expect(refs[stashIndex].label, '已贮藏');
    expect(refs[stashIndex].childCount, isNull);

    await repository.writeFile('README.md', '# Initial\nstashed\n');
    await controller.refresh();
    expect(await controller.createStash('sidebar stash'), isTrue);

    final stashedRefs = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!.refs;
    final stashEntry = stashedRefs.singleWhere(
      (reference) => reference.stashReference == 'stash@{0}',
    );
    expect(stashEntry.label, contains('sidebar stash'));
    expect(stashEntry.id, startsWith('refs/stash/'));

    await controller.selectReference(stashEntry);
    final selectedState = container.read(repositorySessionProvider);
    expect(selectedState.selectedRefId, stashEntry.id);
    expect(selectedState.selectedCommitId, isNotNull);
    expect(selectedState.commitChanges, isNotEmpty);
    expect(selectedState.commitDiff?.text, contains('+stashed'));

    await controller.selectReference(stashedRefs.first);
    final returnedState = container.read(repositorySessionProvider);
    expect(returnedState.selectedCommitId, isNull);
    expect(
      returnedState.commits.map((commit) => commit.objectId),
      isNot(contains(stashEntry.id.substring('refs/stash/'.length))),
    );
  });

  test('enables stash navigation only for tracked changes', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', '# Initial\n');
    await repository.commit('initial');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);

    expect(
      mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!.disabledActions,
      contains(RepositoryAction.stash),
    );

    await repository.writeFile('draft.txt', 'untracked\n');
    await controller.refresh();
    expect(
      mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!.disabledActions,
      contains(RepositoryAction.stash),
    );

    await repository.writeFile('README.md', '# Initial\nchanged\n');
    await controller.refresh();
    expect(
      mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!.disabledActions,
      isNot(contains(RepositoryAction.stash)),
    );
  });

  test('creates and restores a stash through the repository session', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', '# Initial\n');
    await repository.commit('initial');
    await repository.writeFile('README.md', '# Initial\nstashed\n');
    await repository.writeFile('draft.txt', 'untracked\n');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);

    expect(
      await controller.createStash('session stash', includeUntracked: true),
      isTrue,
    );
    expect(container.read(repositorySessionProvider).status!.isClean, isTrue);
    final stash = (await controller.readStashes()).single;
    expect(stash.message, contains('session stash'));

    expect(await controller.applyStash(stash), isTrue);
    final restored = container.read(repositorySessionProvider).status!;
    expect(restored.isClean, isFalse);
    expect(
      restored.entries.map((entry) => entry.path.display),
      contains('draft.txt'),
    );
    expect(await controller.readStashes(), hasLength(1));
  });

  test('rejects a stash action when its reflog selector has shifted', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', '# Initial\n');
    await repository.commit('initial');
    await repository.writeFile('README.md', '# Initial\nfirst\n');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    expect(
      await controller.createStash('first', includeUntracked: false),
      isTrue,
    );
    final selected = (await controller.readStashes()).single;

    await repository.writeFile('README.md', '# Initial\nsecond\n');
    await repository.runGit(['stash', 'push', '--message', 'external']);

    expect(await controller.applyStash(selected), isFalse);
    expect(await controller.readStashes(), hasLength(2));
    expect(
      container.read(repositorySessionProvider).message,
      '贮藏列表已发生变化，请重新打开管理面板后再操作。',
    );
  });

  test(
    'does not create an empty stash for an untracked nested repository',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('README.md', '# Initial\n');
      await repository.commit('initial');
      final nested = Directory(
        '${repository.workingDirectory.path}${Platform.pathSeparator}nested',
      );
      await nested.create(recursive: true);
      await repository.runGit(['init', nested.path]);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);

      expect(
        await controller.createStash('nested only', includeUntracked: true),
        isFalse,
      );
      expect(await controller.readStashes(), isEmpty);
    },
  );

  test('previews an untracked file as added content before staging', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile(
      'hello_sourcetree.py',
      'print("Hello, Sourcetree!")\n',
    );

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);

    var overview = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!;
    final untracked = overview.changes.singleWhere(
      (change) => change.path == 'hello_sourcetree.py',
    );
    expect(untracked.kind, RepositoryChangeKind.untracked);

    await controller.selectChange(untracked);

    overview = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!;
    expect(overview.selectedChange?.path, 'hello_sourcetree.py');
    expect(
      overview.diff.lines.where(
        (line) =>
            line.kind == DiffLineKind.addition &&
            line.text == '+print("Hello, Sourcetree!")',
      ),
      hasLength(1),
    );
  });

  test(
    'shows files inside untracked directories without a directory row',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('pull-test/local/result.txt', 'local\n');
      await repository.writeFile('pull-test/peer/result.txt', 'peer\n');

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);

      final changes = mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!.changes;
      expect(
        changes.map((change) => change.path),
        containsAll(<String>[
          'pull-test/local/result.txt',
          'pull-test/peer/result.txt',
        ]),
      );
      expect(changes.any((change) => change.path == 'pull-test/'), isFalse);
    },
  );

  test('hides an untracked nested repository directory', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    final nested = Directory(
      '${repository.workingDirectory.path}${Platform.pathSeparator}pull-test'
      '${Platform.pathSeparator}local',
    );
    await nested.create(recursive: true);
    await repository.runGit(['init', nested.path]);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);

    final session = container.read(repositorySessionProvider);
    final changes = mapRepositoryOverview(session).repository!.changes;
    expect(changes.any((change) => change.path == 'pull-test/local'), isFalse);
    expect(session.status!.entries, isNotEmpty);
    expect(session.status!.displayEntries, isEmpty);
    expect(
      mapRepositoryOverview(session).repository!.isWorkingTreeClean,
      isFalse,
    );
  });

  test(
    'enables commit for a dirty workspace before files are staged',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('draft.txt', 'pending\n');

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);

      final overview = mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!;
      expect(overview.changes, hasLength(1));
      expect(overview.stagedChangeCount, 0);
      expect(
        overview.disabledActions,
        isNot(contains(RepositoryAction.commit)),
      );
    },
  );

  test('keeps a newly staged file selected with its staged diff', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('hello_sourcetree.py', 'print("ready")\n');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);

    var overview = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!;
    await controller.toggleStage(overview.changes.single);

    overview = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!;
    expect(overview.stagedChangeCount, 1);
    expect(overview.unstagedChangeCount, 0);
    expect(overview.selectedChange?.isStaged, isTrue);
    expect(overview.selectedChange?.path, 'hello_sourcetree.py');
    expect(
      overview.diff.lines.any(
        (line) =>
            line.kind == DiffLineKind.addition &&
            line.text == '+print("ready")',
      ),
      isTrue,
    );
  });

  test('keeps the file list visible while staging and unstaging', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('visible.txt', 'keep the row visible\n');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);

    final emitted = <RepositorySessionState>[];
    final subscription = container.listen<RepositorySessionState>(
      repositorySessionProvider,
      (_, next) => emitted.add(next),
    );
    addTearDown(subscription.close);

    var overview = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!;
    await controller.toggleStage(overview.changes.single);

    expect(emitted.any((state) => state.isWorkingTreeBusy), isTrue);
    expect(
      emitted
          .where((state) => state.isWorkingTreeBusy)
          .every((state) => state.phase == RepositorySessionPhase.loading),
      isTrue,
    );
    expect(
      emitted.where((state) => state.isWorkingTreeBusy).every((state) {
        final view = mapRepositoryOverview(state);
        return view.state == RepositoryOverviewState.ready &&
            view.repository!.changes.isNotEmpty;
      }),
      isTrue,
    );

    emitted.clear();
    overview = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!;
    await controller.toggleStage(overview.changes.single);

    expect(emitted.any((state) => state.isWorkingTreeBusy), isTrue);
    expect(
      emitted
          .where((state) => state.isWorkingTreeBusy)
          .every((state) => state.phase == RepositorySessionPhase.loading),
      isTrue,
    );
    final finalOverview = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!;
    expect(finalOverview.changes, hasLength(1));
    expect(finalOverview.changes.single.isStaged, isFalse);
  });

  test('returns to ready after a successful staging retry', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    final staleFile = await repository.writeFile('stale.txt', 'stale\n');
    await repository.writeFile('retry.txt', 'retry\n');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    var overview = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!;
    final stale = overview.changes.singleWhere(
      (change) => change.path == 'stale.txt',
    );
    await staleFile.delete();

    await controller.toggleStage(stale);
    expect(
      container.read(repositorySessionProvider).phase,
      RepositorySessionPhase.error,
    );

    overview = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!;
    final retry = overview.changes.singleWhere(
      (change) => change.path == 'retry.txt',
    );
    await controller.toggleStage(retry);

    final state = container.read(repositorySessionProvider);
    expect(state.phase, RepositorySessionPhase.ready);
    expect(state.isWorkingTreeBusy, isFalse);
    expect(
      state.status!.stagedEntries.map((entry) => entry.path.display),
      contains('retry.txt'),
    );
  });

  test('preserves a newer file selection made during group staging', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('first.txt', 'first\n');
    await repository.writeFile('second.txt', 'second\n');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    final overview = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!;
    final first = overview.changes.singleWhere(
      (change) => change.path == 'first.txt',
    );
    final second = overview.changes.singleWhere(
      (change) => change.path == 'second.txt',
    );
    controller.selectUncommittedChanges();
    await controller.selectChange(first);

    final staging = controller.toggleStageGroup(overview.changes, stage: true);
    expect(container.read(repositorySessionProvider).isWorkingTreeBusy, isTrue);
    final newerSelection = controller.selectChange(second);
    await Future.wait([staging, newerSelection]);

    final state = container.read(repositorySessionProvider);
    final finalOverview = mapRepositoryOverview(state).repository!;
    expect(finalOverview.selectedChange?.path, 'second.txt');
    expect(finalOverview.selectedChange?.isStaged, isTrue);
    expect(state.diff?.path.display, 'second.txt');
    expect(state.diff?.source, GitDiffSource.staged);
  });

  test('stops tracking a selected modified file without deleting it', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('config/local.json', '{"version": 1}\n');
    await repository.commit('Add local config');
    await repository.writeFile('config/local.json', '{"version": 2}\n');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    final change = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!.changes.single;

    expect(await controller.stopTrackingChanges([change]), isTrue);
    expect(
      await File(
        '${repository.workingDirectory.path}${Platform.pathSeparator}config'
        '${Platform.pathSeparator}local.json',
      ).readAsString(),
      '{"version": 2}\n',
    );
    final state = container.read(repositorySessionProvider);
    expect(
      state.status!.entries.any(
        (entry) =>
            entry.path.display == 'config/local.json' &&
            entry.indexStatus == GitChangeType.deleted,
      ),
      isTrue,
    );
    final overview = mapRepositoryOverview(state).repository!;
    expect(overview.changes, hasLength(2));
    expect(
      overview.changes.any(
        (change) =>
            change.path == 'config/local.json' &&
            change.isStaged &&
            change.kind == RepositoryChangeKind.deleted,
      ),
      isTrue,
    );
    expect(
      overview.changes.any(
        (change) =>
            change.path == 'config/local.json' &&
            !change.isStaged &&
            change.kind == RepositoryChangeKind.untracked,
      ),
      isTrue,
    );
  });

  test('stops tracking the file selected from a historical commit', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('config/local.json', '{"version": 1}\n');
    final commit = await repository.commit('Add local config');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    await controller.selectCommit(commit);

    expect(
      container
          .read(repositorySessionProvider)
          .selectedCommitFile
          ?.file
          .path
          .display,
      'config/local.json',
    );
    expect(await controller.stopTrackingSelectedCommitFile(), isTrue);
    expect(
      await File(
        '${repository.workingDirectory.path}${Platform.pathSeparator}config'
        '${Platform.pathSeparator}local.json',
      ).readAsString(),
      '{"version": 1}\n',
    );
    final overview = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!;
    expect(
      overview.changes.any(
        (change) =>
            change.path == 'config/local.json' &&
            change.isStaged &&
            change.kind == RepositoryChangeKind.deleted,
      ),
      isTrue,
    );
  });

  test(
    'stops tracking a file with staged and unstaged modifications',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('config/local.json', '{"version": 1}\n');
      await repository.commit('Add local config');
      await repository.writeFile('config/local.json', '{"version": 2}\n');

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);
      var overview = mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!;
      await controller.toggleStage(overview.changes.single);
      await repository.writeFile('config/local.json', '{"version": 3}\n');
      await controller.refresh();

      overview = mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!;
      final staged = overview.changes.singleWhere((change) => change.isStaged);
      expect(await controller.stopTrackingChanges([staged]), isTrue);
      expect(
        await File(
          '${repository.workingDirectory.path}${Platform.pathSeparator}config'
          '${Platform.pathSeparator}local.json',
        ).readAsString(),
        '{"version": 3}\n',
      );
      final status = container.read(repositorySessionProvider).status!;
      expect(
        status.entries.any(
          (entry) =>
              entry.path.display == 'config/local.json' &&
              entry.indexStatus == GitChangeType.deleted,
        ),
        isTrue,
      );
      expect(
        status.entries.any(
          (entry) =>
              entry.path.display == 'config/local.json' &&
              entry.kind == GitFileStatusKind.untracked,
        ),
        isTrue,
      );
    },
  );

  test('resets a staged tracked file to HEAD in index and work tree', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('config/local.json', '{"version": 1}\n');
    await repository.commit('Add local config');
    await repository.writeFile('config/local.json', '{"version": 2}\n');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    var overview = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!;
    await controller.toggleStage(overview.changes.single);
    await repository.writeFile('config/local.json', '{"version": 3}\n');
    await controller.refresh();

    overview = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!;
    final staged = overview.changes.singleWhere((change) => change.isStaged);
    controller.selectUncommittedChanges();
    await controller.selectChange(staged);
    expect(staged.canResetToHead, isTrue);
    expect(await controller.resetChangesToHead([staged]), isTrue);
    expect(
      await File(
        '${repository.workingDirectory.path}${Platform.pathSeparator}config'
        '${Platform.pathSeparator}local.json',
      ).readAsString(),
      '{"version": 1}\n',
    );
    expect(container.read(repositorySessionProvider).status!.isClean, isTrue);
    final state = container.read(repositorySessionProvider);
    expect(state.selectedRefId, 'history');
    expect(state.selectedCommitId, isNotNull);
    expect(state.selectedChange, isNull);
    expect(state.diff, isNull);
  });

  test(
    'keeps uncommitted changes selected after resetting one of several files',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('first.txt', 'first base\n');
      await repository.writeFile('second.txt', 'second base\n');
      await repository.commit('Base');
      await repository.writeFile('first.txt', 'first changed\n');
      await repository.writeFile('second.txt', 'second changed\n');

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);
      var overview = mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!;
      await controller.toggleStageGroup(overview.changes, stage: true);
      controller.selectUncommittedChanges();
      overview = mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!;
      final first = overview.changes.singleWhere(
        (change) => change.path == 'first.txt' && change.isStaged,
      );
      await controller.selectChange(first);
      final emitted = <RepositorySessionState>[];
      final subscription = container.listen<RepositorySessionState>(
        repositorySessionProvider,
        (_, next) => emitted.add(next),
      );
      addTearDown(subscription.close);

      expect(await controller.resetChangesToHead([first]), isTrue);

      final state = container.read(repositorySessionProvider);
      overview = mapRepositoryOverview(state).repository!;
      expect(emitted, isNotEmpty);
      expect(
        emitted.every((candidate) => candidate.selectedRefId == 'uncommitted'),
        isTrue,
      );
      expect(
        emitted
            .where((candidate) => candidate.isWorkingTreeBusy)
            .every(
              (candidate) =>
                  mapRepositoryOverview(candidate).state ==
                  RepositoryOverviewState.ready,
            ),
        isTrue,
      );
      expect(state.status!.isClean, isFalse);
      expect(state.selectedRefId, 'uncommitted');
      expect(state.selectedCommitId, isNull);
      expect(state.selectedChange, isNull);
      expect(state.diff, isNull);
      expect(overview.isUncommittedChangesSelected, isTrue);
      expect(overview.changes.map((change) => change.path), ['second.txt']);
    },
  );

  test('stages only the selected working-tree diff hunk', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile(
      'README.md',
      '${List<String>.generate(16, (index) => 'line ${index + 1}').join('\n')}\n',
    );
    await repository.commit('Base');
    await repository.writeFile(
      'README.md',
      '${List<String>.generate(16, (index) => switch (index + 1) {
        2 => 'changed 2',
        14 => 'changed 14',
        _ => 'line ${index + 1}',
      }).join('\n')}\n',
    );

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    var overview = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!;
    controller.selectUncommittedChanges();
    await controller.selectChange(overview.changes.single);

    overview = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!;
    expect(overview.diff.hunkActions, const [
      RepositoryDiffHunkAction.stage,
      RepositoryDiffHunkAction.discard,
    ]);
    expect(await controller.stageSelectedDiffHunk(0), isTrue);

    final refreshed = container.read(repositorySessionProvider);
    final entry = refreshed.status!.entries.single;
    expect(entry.hasStagedChange, isTrue);
    expect(entry.hasWorkTreeChange, isTrue);
    expect(refreshed.selectedRefId, 'uncommitted');
    expect(refreshed.selectedChange?.source, GitDiffSource.workingTree);
    expect(refreshed.diff?.text, isNot(contains('changed 2')));
    expect(refreshed.diff?.text, contains('changed 14'));

    overview = mapRepositoryOverview(refreshed).repository!;
    final stagedChange = overview.changes.singleWhere(
      (change) => change.isStaged,
    );
    await controller.selectChange(stagedChange);
    expect(
      mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!.diff.hunkActions,
      const [RepositoryDiffHunkAction.unstage],
    );
  });

  test(
    'hides and rejects working-tree hunk actions when file mode changes',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile(
        'README.md',
        '${List<String>.generate(16, (index) => 'line ${index + 1}').join('\n')}\n',
      );
      await repository.commit('Base');
      await repository.runGit([
        'update-index',
        '--chmod=+x',
        '--',
        'README.md',
      ]);
      await repository.runGit(['checkout-index', '--force', '--', 'README.md']);
      await repository.runGit(['reset', 'HEAD', '--', 'README.md']);
      await repository.writeFile(
        'README.md',
        '${List<String>.generate(16, (index) => switch (index + 1) {
          2 => 'changed 2',
          14 => 'changed 14',
          _ => 'line ${index + 1}',
        }).join('\n')}\n',
      );

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);
      controller.selectUncommittedChanges();
      final change = mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!.changes.single;
      await controller.selectChange(change);

      final state = container.read(repositorySessionProvider);
      final overview = mapRepositoryOverview(state).repository!;
      expect(state.diff?.changesFileMode, isTrue);
      expect(overview.diff.hunkActions, isEmpty);
      expect(await controller.stageSelectedDiffHunk(0), isFalse);
      expect(await controller.revertSelectedDiffHunk(0), isFalse);
    },
  );

  test('discards only the selected working-tree diff hunk', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile(
      'README.md',
      '${List<String>.generate(16, (index) => 'line ${index + 1}').join('\n')}\n',
    );
    await repository.commit('Base');
    await repository.writeFile(
      'README.md',
      '${List<String>.generate(16, (index) => switch (index + 1) {
        2 => 'changed 2',
        14 => 'changed 14',
        _ => 'line ${index + 1}',
      }).join('\n')}\n',
    );

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    final overview = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!;
    controller.selectUncommittedChanges();
    await controller.selectChange(overview.changes.single);

    expect(await controller.revertSelectedDiffHunk(0), isTrue);
    final content = await File(
      '${repository.workingDirectory.path}${Platform.pathSeparator}README.md',
    ).readAsString();
    expect(content, contains('line 2\n'));
    expect(content, contains('changed 14\n'));
    final refreshed = container.read(repositorySessionProvider);
    expect(refreshed.selectedRefId, 'uncommitted');
    expect(refreshed.selectedCommitId, isNull);
    expect(refreshed.selectedChange?.entry.path.display, 'README.md');
    expect(refreshed.diff?.text, contains('changed 14'));
  });

  test(
    'reverse-applies a committed hunk and preserves history selection',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile(
        'README.md',
        '${List<String>.generate(16, (index) => 'line ${index + 1}').join('\n')}\n',
      );
      await repository.commit('Base');
      await repository.writeFile(
        'README.md',
        '${List<String>.generate(16, (index) => switch (index + 1) {
          2 => 'changed 2',
          14 => 'changed 14',
          _ => 'line ${index + 1}',
        }).join('\n')}\n',
      );
      final changed = await repository.commit('Change two hunks');

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);
      final before = mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!;
      expect(before.selectedCommit?.oid, changed);
      expect(before.commitDiff.hunkActions, const [
        RepositoryDiffHunkAction.revertCommitted,
      ]);

      expect(await controller.revertSelectedCommitDiffHunk(0), isTrue);

      final content = await File(
        '${repository.workingDirectory.path}${Platform.pathSeparator}README.md',
      ).readAsString();
      expect(content, contains('line 2\n'));
      expect(content, contains('changed 14\n'));
      final refreshed = container.read(repositorySessionProvider);
      expect(refreshed.selectedCommitId, changed);
      expect(refreshed.selectedCommitFile?.file.path.display, 'README.md');
      expect(refreshed.status!.entries.single.hasWorkTreeChange, isTrue);
      expect(
        (await repository.runGit([
          'rev-parse',
          'HEAD',
        ])).stdout.toString().trim(),
        changed,
      );
    },
  );

  test(
    'offers and applies committed-hunk revert for a newly added file',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('new-file.txt', 'first\nsecond\nthird\n');
      final added = await repository.commit('Add file');

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);
      final before = mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!;
      expect(before.selectedCommit?.oid, added);
      expect(before.selectedCommitFile?.kind, RepositoryChangeKind.added);
      expect(before.commitDiff.hunkActions, const [
        RepositoryDiffHunkAction.revertCommitted,
      ]);

      expect(await controller.revertSelectedCommitDiffHunk(0), isTrue);

      expect(
        await File(
          '${repository.workingDirectory.path}${Platform.pathSeparator}new-file.txt',
        ).exists(),
        isFalse,
      );
      final refreshed = container.read(repositorySessionProvider);
      expect(refreshed.selectedCommitId, added);
      expect(
        refreshed.status!.entries.single.workTreeStatus,
        GitChangeType.deleted,
      );
    },
  );

  test(
    'hides and rejects committed-hunk revert when file mode changes',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile(
        'README.md',
        '${List<String>.generate(16, (index) => 'line ${index + 1}').join('\n')}\n',
      );
      await repository.commit('Base');
      await repository.runGit([
        'update-index',
        '--chmod=+x',
        '--',
        'README.md',
      ]);
      await repository.runGit(['checkout-index', '--force', '--', 'README.md']);
      await repository.writeFile(
        'README.md',
        '${List<String>.generate(16, (index) => switch (index + 1) {
          2 => 'changed 2',
          14 => 'changed 14',
          _ => 'line ${index + 1}',
        }).join('\n')}\n',
      );
      await repository.commit('Change mode and content');

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);

      final state = container.read(repositorySessionProvider);
      final overview = mapRepositoryOverview(state).repository!;
      expect(state.commitDiff?.changesFileMode, isTrue);
      expect(overview.commitDiff.hunkActions, isEmpty);
      expect(await controller.revertSelectedCommitDiffHunk(0), isFalse);
    },
  );

  test(
    'refuses reset when the selected file was unstaged after confirmation',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('config/local.json', '{"version": 1}\n');
      await repository.commit('Add local config');
      await repository.writeFile('config/local.json', '{"version": 2}\n');

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);
      var overview = mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!;
      await controller.toggleStage(overview.changes.single);
      overview = mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!;
      final previouslyStaged = overview.changes.single;
      controller.selectUncommittedChanges();

      await repository.runGit(['reset', '--', 'config/local.json']);
      await repository.writeFile('config/local.json', '{"version": 3}\n');

      expect(await controller.resetChangesToHead([previouslyStaged]), isFalse);
      expect(
        await File(
          '${repository.workingDirectory.path}${Platform.pathSeparator}config'
          '${Platform.pathSeparator}local.json',
        ).readAsString(),
        '{"version": 3}\n',
      );
      expect(
        container.read(repositorySessionProvider).selectedRefId,
        'uncommitted',
      );
    },
  );

  test(
    'removes a staged new file from the index without deleting it',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('config/local.json', '{"version": 1}\n');

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);
      var overview = mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!;
      await controller.toggleStage(overview.changes.single);

      overview = mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!;
      final staged = overview.changes.single;
      expect(staged.kind, RepositoryChangeKind.added);
      expect(staged.isStaged, isTrue);

      expect(await controller.stopTrackingChanges([staged]), isTrue);
      expect(
        await File(
          '${repository.workingDirectory.path}${Platform.pathSeparator}config'
          '${Platform.pathSeparator}local.json',
        ).readAsString(),
        '{"version": 1}\n',
      );
      final status = container.read(repositorySessionProvider).status!;
      expect(status.entries, hasLength(1));
      expect(status.entries.single.kind, GitFileStatusKind.untracked);
    },
  );

  test(
    'removes staged, unstaged, and untracked files without changing the index',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('tracked-unstaged.txt', 'base unstaged\n');
      await repository.writeFile('tracked-staged.txt', 'base staged\n');
      await repository.commit('Base');
      await repository.writeFile(
        'tracked-unstaged.txt',
        'working tree change\n',
      );
      await repository.writeFile('tracked-staged.txt', 'staged change\n');
      await repository.writeFile('untracked.txt', 'local only\n');

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);
      var overview = mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!;
      await controller.toggleStage(
        overview.changes.singleWhere(
          (change) => change.path == 'tracked-staged.txt',
        ),
      );

      overview = mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!;
      final selected = [
        overview.changes.singleWhere(
          (change) => change.path == 'tracked-unstaged.txt',
        ),
        overview.changes.singleWhere(
          (change) => change.path == 'tracked-staged.txt' && change.isStaged,
        ),
        overview.changes.singleWhere(
          (change) => change.path == 'untracked.txt',
        ),
      ];

      final removal = await controller.removeChanges(selected);
      expect(removal, isNotNull);
      expect(
        removal!.removedPaths,
        containsAll([
          'tracked-unstaged.txt',
          'tracked-staged.txt',
          'untracked.txt',
        ]),
      );
      expect(removal.missingPaths, isEmpty);
      expect(removal.failedPaths, isEmpty);
      expect(removal.hasFailures, isFalse);
      for (final path in [
        'tracked-unstaged.txt',
        'tracked-staged.txt',
        'untracked.txt',
      ]) {
        expect(
          await File(
            '${repository.workingDirectory.path}${Platform.pathSeparator}$path',
          ).exists(),
          isFalse,
        );
      }
      expect(
        (await repository.runGit(['show', ':tracked-staged.txt'])).stdout,
        'staged change\n',
      );
      expect(
        (await repository.runGit(['show', 'HEAD:tracked-staged.txt'])).stdout,
        'base staged\n',
      );
      final status = container.read(repositorySessionProvider).status!;
      expect(
        status.entries.map((entry) => entry.path.display),
        containsAll(['tracked-unstaged.txt', 'tracked-staged.txt']),
      );
      expect(
        status.entries.any((entry) => entry.path.display == 'untracked.txt'),
        isFalse,
      );
    },
  );

  test(
    'refuses removal when a selected source changed after confirmation',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      final file = await repository.writeFile('scratch.txt', 'local only\n');

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);
      final untracked = mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!.changes.single;
      controller.selectUncommittedChanges();

      await repository.runGit(['add', '--', 'scratch.txt']);

      expect(await controller.removeChanges([untracked]), isNull);
      expect(await file.readAsString(), 'local only\n');
      expect(
        container.read(repositorySessionProvider).selectedRefId,
        'uncommitted',
      );
    },
  );

  test('refuses to stop tracking an untracked file', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('scratch.txt', 'local only\n');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    final change = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!.changes.single;

    expect(await controller.stopTrackingChanges([change]), isFalse);
    expect(
      await File(
        '${repository.workingDirectory.path}${Platform.pathSeparator}scratch.txt',
      ).readAsString(),
      'local only\n',
    );
    expect(
      container.read(repositorySessionProvider).status!.entries.single.kind,
      GitFileStatusKind.untracked,
    );
  });

  test('stages every file in an unstaged change group', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('pull-test/local', 'local\n');
    await repository.writeFile('pull-test/peer', 'peer\n');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    final overview = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!;
    final unstaged = overview.changes
        .where((change) => !change.isStaged)
        .toList();

    await controller.toggleStageGroup(unstaged, stage: true);

    final refreshed = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!;
    expect(refreshed.stagedChangeCount, 2);
    expect(refreshed.unstagedChangeCount, 0);
  });

  test(
    'selecting a branch focuses its tip and refreshes commit file status',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('README.md', 'base\n');
      await repository.commit('Initial commit');
      await repository.runGit(['branch', 'feature/browse']);
      await repository.runGit(['switch', 'feature/browse']);
      await repository.writeFile('feature.txt', 'feature\n');
      final featureCommit = await repository.commit('Feature commit');
      await repository.runGit(['switch', 'main']);
      await repository.writeFile('main.txt', 'main\n');
      await repository.commit('Main commit');
      await repository.writeFile('draft.txt', 'uncommitted\n');

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);
      var overview = mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!;
      final featureRef = overview.refs.singleWhere(
        (reference) => reference.label == 'feature/browse',
      );

      await controller.selectReference(featureRef);

      final branchState = container.read(repositorySessionProvider);
      overview = mapRepositoryOverview(branchState).repository!;
      expect(branchState.status!.branch.head, 'main');
      expect(branchState.selectedRefId, 'refs/heads/feature/browse');
      expect(branchState.selectedCommitId, featureCommit);
      expect(overview.focusedRefCommitId, featureCommit);
      expect(overview.selectedCommit!.oid, featureCommit);
      expect(overview.commitChanges.single.path, 'feature.txt');
      expect(overview.selectedCommitFile!.path, 'feature.txt');
      expect(
        overview.refs
            .singleWhere((reference) => reference.label == 'feature/browse')
            .isSelected,
        isTrue,
      );
      expect(
        overview.commits
            .singleWhere((commit) => commit.oid == featureCommit)
            .refs,
        contains('feature/browse'),
      );

      await controller.selectReference(
        overview.refs.singleWhere((reference) => reference.id == 'workspace'),
      );

      final workspace = mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!;
      expect(workspace.selectedCommit, isNull);
      expect(
        workspace.changes.map((change) => change.path),
        contains('draft.txt'),
      );
      expect(
        workspace.refs
            .singleWhere((reference) => reference.id == 'workspace')
            .isSelected,
        isTrue,
      );

      controller.selectUncommittedChanges();

      final uncommitted = mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!;
      expect(uncommitted.isUncommittedChangesSelected, isTrue);
      expect(uncommitted.selectedCommit, isNull);
      expect(
        uncommitted.refs
            .singleWhere((reference) => reference.id == 'history')
            .isSelected,
        isTrue,
      );
    },
  );

  test('restores the home library and its active repository', () async {
    final firstRepository = await GitTestRepository.create();
    addTearDown(firstRepository.dispose);
    final secondRepository = await GitTestRepository.create();
    addTearDown(secondRepository.dispose);
    final store = _MemoryRepositorySessionStore();
    final firstContainer = ProviderContainer(
      overrides: [repositorySessionStoreProvider.overrideWithValue(store)],
    );
    addTearDown(firstContainer.dispose);
    final firstController = firstContainer.read(
      repositoryLibraryProvider.notifier,
    );

    await firstController.restore();
    await firstController.add(firstRepository.workingDirectory.path);
    await firstController.add(secondRepository.workingDirectory.path);
    final firstPath = firstContainer
        .read(repositoryLibraryProvider)
        .repositories
        .first
        .path;
    firstController.select(firstPath);
    await Future<void>.delayed(Duration.zero);

    final restoredContainer = ProviderContainer(
      overrides: [repositorySessionStoreProvider.overrideWithValue(store)],
    );
    addTearDown(restoredContainer.dispose);
    await restoredContainer.read(repositoryLibraryProvider.notifier).restore();

    final restoredState = restoredContainer.read(repositoryLibraryProvider);
    expect(restoredState.repositories, hasLength(2));
    expect(restoredState.activeRepositoryPath, firstPath);
  });

  test('adds inspected roots and persists repository library ordering', () async {
    final firstRepository = await GitTestRepository.create();
    addTearDown(firstRepository.dispose);
    await firstRepository.writeFile('uncommitted.txt', 'pending\n');
    final secondRepository = await GitTestRepository.create();
    addTearDown(secondRepository.dispose);
    final store = _MemoryRepositorySessionStore();
    final container = ProviderContainer(
      overrides: [repositorySessionStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositoryLibraryProvider.notifier);

    await controller.restore();
    expect(
      await controller.add(firstRepository.workingDirectory.path),
      RepositoryLibraryRegistrationResult.added,
    );
    final nestedDirectory = Directory(
      '${firstRepository.workingDirectory.path}${Platform.pathSeparator}nested',
    );
    await nestedDirectory.create();
    expect(
      await controller.add(nestedDirectory.path),
      RepositoryLibraryRegistrationResult.alreadyRegistered,
    );
    expect(
      await controller.add(secondRepository.workingDirectory.path),
      RepositoryLibraryRegistrationResult.added,
    );

    final firstPath = container
        .read(repositoryLibraryProvider)
        .repositories
        .first
        .path;
    final secondPath = container
        .read(repositoryLibraryProvider)
        .repositories
        .last
        .path;
    final firstTab = container
        .read(repositoryLibraryProvider)
        .repositories
        .first;
    expect(firstTab.hasStatus, isTrue);
    expect(firstTab.branchName, firstRepository.initialBranch);
    expect(firstTab.changedFileCount, 1);
    expect(firstTab.isUnborn, isTrue);
    controller.reorder([secondPath, firstPath]);
    expect(
      container
          .read(repositoryLibraryProvider)
          .repositories
          .map((tab) => tab.path),
      [secondPath, firstPath],
    );

    await Future<void>.delayed(Duration.zero);
    expect(store.snapshot.openRepositoryPaths, [secondPath, firstPath]);
  });

  test(
    'refreshes an existing library entry when it is reported again',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('uncommitted.txt', 'pending\n');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositoryLibraryProvider.notifier);

      expect(
        await controller.add(repository.workingDirectory.path),
        RepositoryLibraryRegistrationResult.added,
      );
      expect(
        container.read(repositoryLibraryProvider).repositories.single,
        isA<RepositoryTab>()
            .having((tab) => tab.changedFileCount, 'changedFileCount', 1)
            .having((tab) => tab.isUnborn, 'isUnborn', isTrue),
      );

      await repository.commit('initial');
      expect(
        await controller.add(repository.workingDirectory.path),
        RepositoryLibraryRegistrationResult.alreadyRegistered,
      );
      expect(
        container.read(repositoryLibraryProvider).repositories.single,
        isA<RepositoryTab>()
            .having((tab) => tab.changedFileCount, 'changedFileCount', 0)
            .having((tab) => tab.isUnborn, 'isUnborn', isFalse),
      );
    },
  );

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

  test('records the selected repository in the persistent library', () async {
    final firstRepository = await GitTestRepository.create();
    addTearDown(firstRepository.dispose);
    final secondRepository = await GitTestRepository.create();
    addTearDown(secondRepository.dispose);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositoryLibraryProvider.notifier);

    await controller.add(firstRepository.workingDirectory.path);
    await controller.add(secondRepository.workingDirectory.path);
    final initialTabs = container.read(repositoryLibraryProvider).repositories;
    final firstTab = initialTabs.first;
    final initialLabels = initialTabs.map((tab) => tab.label).toList();

    controller.select(firstTab.path);

    final state = container.read(repositoryLibraryProvider);
    expect(state.activeRepositoryPath, firstTab.path);
    expect(state.repositories, hasLength(2));
    expect(state.repositories.map((tab) => tab.label).toList(), initialLabels);
  });

  test('maps sibling branches to persistent graph lanes', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('graph.txt', 'base\n');
    await repository.commit('base');
    await repository.runGit(['branch', 'feature/graph']);
    await repository.runGit(['switch', 'feature/graph']);
    await repository.writeFile('graph.txt', 'feature\n');
    await repository.commit('feature commit');
    await repository.runGit(['switch', 'main']);
    await repository.writeFile('graph.txt', 'main\n');
    await repository.commit('main commit');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container
        .read(repositorySessionProvider.notifier)
        .openRepository(repository.workingDirectory.path);
    final commits = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!.commits;
    final main = commits.firstWhere(
      (commit) => commit.subject == 'main commit',
    );
    final feature = commits.firstWhere(
      (commit) => commit.subject == 'feature commit',
    );
    final base = commits.firstWhere((commit) => commit.subject == 'base');

    expect(commits.first.graph.hasPreviousNode, isFalse);
    expect(commits[1].graph.hasPreviousNode, isTrue);
    expect(main.graph.activeLanes, contains(main.graph.lane));
    expect(
      main.graph.activeLaneDestinations,
      hasLength(main.graph.activeLanes.length),
    );
    expect(main.graph.activeLaneDestinations, everyElement(isNotNull));
    expect(feature.graph.activeLanes, contains(feature.graph.lane));
    expect(main.graph.lane, isNot(feature.graph.lane));
    expect(main.graph.parentLanes, [main.graph.lane]);
    expect(feature.graph.parentLanes, [feature.graph.lane]);
    expect(
      {base.graph.lane, ...base.graph.incomingLanes},
      {main.graph.lane, feature.graph.lane},
    );
  });

  test(
    'creates a local branch from a selected commit without checking it out',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('branch.txt', 'base\n');
      await repository.commit('base commit');
      await repository.writeFile('branch.txt', 'tip\n');
      await repository.commit('tip commit');

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);
      final base = container
          .read(repositorySessionProvider)
          .commits
          .singleWhere((commit) => commit.subject == 'base commit');

      expect(
        await controller.createLocalBranchFromCommit(
          'feature/from-base',
          base.objectId,
        ),
        isTrue,
      );
      final state = container.read(repositorySessionProvider);
      expect(state.status?.branch.head, 'main');
      expect(
        state.localBranches.map((branch) => branch.name),
        contains('feature/from-base'),
      );
    },
  );

  test(
    'keeps the existing library when a reported repository is unavailable',
    () async {
      final firstRepository = await GitTestRepository.create();
      addTearDown(firstRepository.dispose);
      final secondRepository = await GitTestRepository.create();
      addTearDown(secondRepository.dispose);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositoryLibraryProvider.notifier);

      await controller.add(firstRepository.workingDirectory.path);
      await controller.add(secondRepository.workingDirectory.path);
      controller.select(secondRepository.workingDirectory.path);
      final stateBeforeReport = container.read(repositoryLibraryProvider);

      await firstRepository.workingDirectory.delete(recursive: true);

      expect(
        await controller.add(firstRepository.workingDirectory.path),
        anyOf(
          RepositoryLibraryRegistrationResult.notRepository,
          RepositoryLibraryRegistrationResult.failed,
        ),
      );
      final state = container.read(repositoryLibraryProvider);
      expect(state.repositories, stateBeforeReport.repositories);
      expect(
        state.activeRepositoryPath,
        stateBeforeReport.activeRepositoryPath,
      );
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

  test('amends the current commit and refreshes the session', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', '# Git Desktop\n');
    await repository.commit('Initial commit');
    await repository.writeFile('README.md', '# Git Desktop\nAmended\n');
    await repository.runGit(['add', '--', 'README.md']);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);

    expect(
      await controller.createCommit('Amended commit', amend: true),
      isTrue,
    );
    final state = container.read(repositorySessionProvider);
    expect(state.phase, RepositorySessionPhase.ready);
    expect(state.status!.entries, isEmpty);
    expect(state.commits.single.subject, 'Amended commit');

    expect(
      await controller.createCommit('Amended message only', amend: true),
      isTrue,
    );
    expect(
      container.read(repositorySessionProvider).commits.single.subject,
      'Amended message only',
    );
  });

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

  test('manages loaded local branches without forcing deletion', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', '# Git Desktop\n');
    await repository.commit('Initial commit');
    await repository.runGit(['branch', 'feature/source']);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);

    expect(
      await controller.createLocalBranchFromLocalBranch(
        'feature/copied',
        'feature/source',
      ),
      isTrue,
    );
    expect(
      await controller.renameLocalBranch('feature/copied', 'feature/renamed'),
      isTrue,
    );
    expect(await controller.deleteMergedLocalBranch('feature/renamed'), isTrue);
    expect(
      container
          .read(repositorySessionProvider)
          .localBranches
          .map((branch) => branch.name),
      isNot(contains('feature/renamed')),
    );
  });

  test('refreshes refs when a multi-branch deletion partially fails', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', '# Git Desktop\n');
    await repository.commit('Initial commit');
    await repository.runGit(['branch', 'feature/merged']);
    await repository.runGit(['branch', 'feature/unmerged']);
    await repository.runGit(['switch', 'feature/unmerged']);
    await repository.writeFile('unmerged.txt', 'keep this commit\n');
    await repository.commit('Unmerged commit');
    await repository.runGit(['switch', 'main']);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);

    expect(
      await controller.deleteBranches(
        localBranchNames: const ['feature/merged', 'feature/unmerged'],
      ),
      isFalse,
    );
    final state = container.read(repositorySessionProvider);
    expect(state.phase, RepositorySessionPhase.error);
    expect(
      state.localBranches.map((branch) => branch.name),
      isNot(contains('feature/merged')),
    );
    expect(
      state.localBranches.map((branch) => branch.name),
      contains('feature/unmerged'),
    );
  });

  test(
    'renames and safely deletes a non-current branch with dirty files',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('README.md', '# Git Desktop\n');
      await repository.commit('Initial commit');
      await repository.runGit(['branch', 'feature/dirty-management']);
      await repository.writeFile('uncommitted.txt', 'keep this change\n');

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);

      expect(
        container.read(repositorySessionProvider).status!.isClean,
        isFalse,
      );
      expect(
        await controller.renameLocalBranch(
          'feature/dirty-management',
          'feature/renamed-while-dirty',
        ),
        isTrue,
      );
      expect(
        await controller.deleteMergedLocalBranch('feature/renamed-while-dirty'),
        isTrue,
      );
      expect(
        container
            .read(repositorySessionProvider)
            .localBranches
            .map((branch) => branch.name),
        isNot(contains('feature/renamed-while-dirty')),
      );
      expect(
        File(
          '${repository.workingDirectory.path}/uncommitted.txt',
        ).readAsStringSync(),
        'keep this change\n',
      );
    },
  );

  test('switches branches while preserving safe untracked changes', () async {
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
    expect(await controller.switchToLocalBranch('main'), isTrue);
    expect(
      (await repository.runGit([
        'branch',
        '--show-current',
      ])).stdout.toString().trim(),
      'main',
    );
    expect(
      (await repository.runGit(['status', '--short'])).stdout.toString(),
      contains('?? uncommitted.txt'),
    );
  });

  test(
    'refuses switching when the target branch would overwrite changes',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('README.md', 'base\n');
      await repository.commit('Initial commit');
      await repository.runGit(['branch', 'feature/conflict']);
      await repository.runGit(['switch', 'feature/conflict']);
      await repository.writeFile('README.md', 'feature\n');
      await repository.commit('Feature README');
      await repository.runGit(['switch', 'main']);
      await repository.writeFile('README.md', 'local change\n');

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);

      expect(await controller.switchToLocalBranch('feature/conflict'), isFalse);
      expect(
        (await repository.runGit([
          'branch',
          '--show-current',
        ])).stdout.toString().trim(),
        'main',
      );
    },
  );

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

  test('clones into a named child of a selected non-empty parent', () async {
    final source = await GitTestRepository.create();
    addTearDown(source.dispose);
    await source.writeFile('README.md', '# Git Desktop\n');
    await source.commit('Initial commit');
    final origin = await source.createBareOrigin();
    await source.runGit(['push', 'origin', 'main']);
    final parent = await Directory.systemTemp.createTemp(
      'git-desktop-clone-parent-',
    );
    addTearDown(() => parent.delete(recursive: true));
    final existingFile = File(
      '${parent.path}${Platform.pathSeparator}existing-project.txt',
    );
    await existingFile.writeAsString('keep');
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
      await container
          .read(repositorySessionProvider.notifier)
          .cloneRepositoryIntoParent(
            remoteUrl: origin.path,
            parentDirectoryPath: parent.path,
          ),
      isTrue,
    );

    final target = Directory('${parent.path}${Platform.pathSeparator}origin');
    expect(await existingFile.readAsString(), 'keep');
    expect(await File('${target.path}/README.md').exists(), isTrue);
    expect(
      container.read(repositorySessionProvider).repository!.workTreeRoot,
      await target.resolveSymbolicLinks(),
    );
  });

  test('does not overwrite a non-empty same-name clone directory', () async {
    final parent = await Directory.systemTemp.createTemp(
      'git-desktop-clone-conflict-',
    );
    addTearDown(() => parent.delete(recursive: true));
    final target = Directory('${parent.path}${Platform.pathSeparator}project');
    await target.create();
    final existingFile = File('${target.path}/keep.txt');
    await existingFile.writeAsString('keep');
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
      await container
          .read(repositorySessionProvider.notifier)
          .cloneRepositoryIntoParent(
            remoteUrl: 'https://example.com/team/project.git',
            parentDirectoryPath: parent.path,
          ),
      isFalse,
    );

    expect(await existingFile.readAsString(), 'keep');
    expect(
      container.read(repositorySessionProvider).message,
      '只能克隆到空目录，避免覆盖现有文件。',
    );
  });

  test(
    'reports no residue when clone is cancelled before Git starts',
    () async {
      final parent = await Directory.systemTemp.createTemp(
        'git-desktop-clone-cancel-',
      );
      addTearDown(() => parent.delete(recursive: true));
      final target = Directory(
        '${parent.path}${Platform.pathSeparator}project',
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);

      final clone = controller.cloneRepository(
        remoteUrl: 'https://example.invalid/team/project.git',
        directoryPath: target.path,
      );
      controller.cancelClone();

      expect(await clone, isFalse);
      expect(await target.exists(), isFalse);
      final state = container.read(repositorySessionProvider);
      expect(state.message, '克隆已取消，未留下文件，可以重试。');
      expect(
        state.operations.single.outcome,
        RepositoryOperationOutcome.cancelled,
      );
    },
  );

  test('reports partial Git data when a running clone is cancelled', () async {
    if (Platform.isWindows) return;
    final parent = await Directory.systemTemp.createTemp(
      'git-desktop-clone-running-cancel-',
    );
    addTearDown(() => parent.delete(recursive: true));
    final helper = File('${parent.path}/fake-git');
    await helper.writeAsString('''#!/bin/sh
target="\$5"
mkdir -p "\$target/.git"
printf partial > "\$target/.git/partial"
while true; do sleep 1; done
''');
    final chmod = await Process.run('chmod', ['+x', helper.path]);
    expect(chmod.exitCode, 0);
    final target = Directory('${parent.path}/project');
    final marker = File('${target.path}/.git/partial');
    final container = ProviderContainer(
      overrides: [
        gitRunnerProvider.overrideWithValue(GitRunner(executable: helper.path)),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);

    final clone = controller.cloneRepository(
      remoteUrl: 'https://example.invalid/team/project.git',
      directoryPath: target.path,
    );
    for (var attempt = 0; attempt < 200 && !await marker.exists(); attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await marker.exists(), isTrue);
    controller.cancelClone();

    expect(await clone, isFalse);
    final state = container.read(repositorySessionProvider);
    expect(state.message, contains('目标目录保留了部分 Git 数据'));
    expect(
      state.operations.single.outcome,
      RepositoryOperationOutcome.cancelled,
    );
  });

  test('prepares a workspace shutdown by stopping a running clone', () async {
    if (Platform.isWindows) return;
    final parent = await Directory.systemTemp.createTemp(
      'git-desktop-clone-shutdown-',
    );
    addTearDown(() => parent.delete(recursive: true));
    final helper = File('${parent.path}/fake-git');
    await helper.writeAsString('''#!/bin/sh
target="\$5"
mkdir -p "\$target/.git"
printf partial > "\$target/.git/partial"
while true; do sleep 1; done
''');
    final chmod = await Process.run('chmod', ['+x', helper.path]);
    expect(chmod.exitCode, 0);
    final target = Directory('${parent.path}/project');
    final marker = File('${target.path}/.git/partial');
    final container = ProviderContainer(
      overrides: [
        gitRunnerProvider.overrideWithValue(GitRunner(executable: helper.path)),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);

    final clone = controller.cloneRepository(
      remoteUrl: 'https://example.invalid/team/project.git',
      directoryPath: target.path,
    );
    for (var attempt = 0; attempt < 200 && !await marker.exists(); attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await marker.exists(), isTrue);

    await controller.prepareForShutdown(timeout: const Duration(seconds: 5));

    expect(await clone, isFalse);
    expect(
      container.read(repositorySessionProvider).operations.single.outcome,
      RepositoryOperationOutcome.cancelled,
    );
  });

  test(
    'maps every remote-tracking branch into the remote refs section',
    () async {
      final source = await GitTestRepository.create();
      addTearDown(source.dispose);
      await source.writeFile('README.md', '# Git Desktop\n');
      await source.commit('Initial commit');
      final origin = await source.createBareOrigin();
      await source.runGit(['push', 'origin', 'main']);
      await source.runGit(['branch', 'feature/remote']);
      await source.runGit(['push', 'origin', 'feature/remote']);
      final directory = await Directory.systemTemp.createTemp(
        'git-desktop-remote-branches-',
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

      final state = container.read(repositorySessionProvider);
      final overview = mapRepositoryOverview(state).repository!;
      expect(
        state.remoteBranches.map((branch) => branch.name),
        containsAll(['origin/main', 'origin/feature/remote']),
      );
      expect(
        overview.refs
            .where((ref) => ref.kind == RepositoryRefKind.remoteBranch)
            .map((ref) => ref.label),
        containsAll(['origin/HEAD', 'origin/main', 'origin/feature/remote']),
      );
      expect(
        overview.refs
            .where((ref) => ref.kind == RepositoryRefKind.remote)
            .map((ref) => ref.label),
        contains('origin'),
      );
    },
  );

  test(
    'removes a configured remote and refreshes the navigation state',
    () async {
      final source = await GitTestRepository.create();
      addTearDown(source.dispose);
      await source.writeFile('README.md', '# Git Desktop\n');
      await source.commit('Initial commit');
      final origin = await source.createBareOrigin();
      await source.runGit(['push', 'origin', 'main']);
      final directory = await Directory.systemTemp.createTemp(
        'git-desktop-remove-remote-',
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
      expect(await controller.removeRemote('origin'), isTrue);

      final state = container.read(repositorySessionProvider);
      expect(state.phase, RepositorySessionPhase.ready);
      expect(state.remoteNames, isNot(contains('origin')));
      expect(state.remoteBranches, isEmpty);
    },
  );

  test(
    'checks out an existing remote-tracking branch into a local branch',
    () async {
      final source = await GitTestRepository.create();
      addTearDown(source.dispose);
      await source.writeFile('README.md', '# Git Desktop\n');
      await source.commit('Initial commit');
      final origin = await source.createBareOrigin();
      await source.runGit(['push', 'origin', 'main']);
      await source.runGit(['branch', 'feature/checkout']);
      await source.runGit(['push', 'origin', 'feature/checkout']);
      final directory = await Directory.systemTemp.createTemp(
        'git-desktop-remote-checkout-',
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
      expect(
        await controller.switchToRemoteBranch('origin/feature/checkout'),
        isTrue,
      );

      final state = container.read(repositorySessionProvider);
      expect(state.status!.branch.head, 'feature/checkout');
      expect(
        (await Process.run('git', [
          'config',
          '--get',
          'branch.feature/checkout.remote',
        ], workingDirectory: directory.path)).stdout.toString().trim(),
        'origin',
      );
    },
  );

  test('merges a loaded local branch into the current branch', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    await repository.commit('Initial commit');
    await repository.runGit(['branch', 'feature/merge']);
    await repository.runGit(['switch', 'feature/merge']);
    await repository.writeFile('feature.txt', 'feature\n');
    await repository.commit('Feature commit');
    await repository.runGit(['switch', 'main']);
    await repository.writeFile('main.txt', 'main\n');
    await repository.commit('Main commit');
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);

    expect(await controller.mergeLocalBranch('feature/merge'), isTrue);

    final state = container.read(repositorySessionProvider);
    expect(state.phase, RepositorySessionPhase.ready);
    expect(state.status!.branch.head, 'main');
    expect(state.commits.first.parentIds, hasLength(2));
  });

  test(
    'merges the selected historical commit into the current branch',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('README.md', 'base\n');
      await repository.commit('Initial commit');
      await repository.runGit(['switch', '-c', 'feature/commit-source']);
      await repository.writeFile('feature.txt', 'feature\n');
      final featureCommit = await repository.commit('Feature commit');
      await repository.runGit(['switch', 'main']);
      await repository.writeFile('main.txt', 'main\n');
      await repository.commit('Main commit');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);

      expect(await controller.mergeCommit(featureCommit), isTrue);

      final state = container.read(repositorySessionProvider);
      expect(state.phase, RepositorySessionPhase.ready);
      expect(state.commits.first.parentIds, contains(featureCommit));
    },
  );

  test(
    'selects a non-commit tag without trying to load commit details',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('README.md', 'base\n');
      await repository.commit('Initial commit');
      final treeId = (await repository.runGit([
        'write-tree',
      ])).stdout.toString().trim();
      await repository.runGit(['tag', 'tree-snapshot', treeId]);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);
      final overview = mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!;

      await controller.selectReference(
        overview.refs.singleWhere(
          (reference) => reference.label == 'tree-snapshot',
        ),
      );

      final state = container.read(repositorySessionProvider);
      expect(state.phase, RepositorySessionPhase.ready);
      expect(state.selectedRefId, 'refs/tags/tree-snapshot');
      expect(state.selectedCommitId, isNull);
    },
  );

  test('creates a tag and refreshes the repository session', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    final commit = await repository.commit('Initial commit');
    await repository.runGit([
      'update-ref',
      'refs/remotes/origin/v1.0.0',
      commit,
    ]);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);

    expect(
      await controller.createTag(
        GitCreateTagOptions(name: 'origin/v1.0.0', objectId: commit),
      ),
      isTrue,
    );

    final state = container.read(repositorySessionProvider);
    expect(state.phase, RepositorySessionPhase.ready);
    expect(state.tags.map((tag) => tag.name), contains('origin/v1.0.0'));
    expect(
      mapRepositoryOverview(state).repository!.commits
          .singleWhere((entry) => entry.oid == commit)
          .references,
      isA<List<CommitReferenceViewData>>(),
    );
    expect(
      mapRepositoryOverview(state).repository!.commits
          .singleWhere((entry) => entry.oid == commit)
          .references
          .map((reference) => '${reference.kind}:${reference.label}'),
      containsAll([
        'CommitReferenceKind.tag:origin/v1.0.0',
        'CommitReferenceKind.remoteBranch:origin/v1.0.0',
      ]),
    );
  });

  test(
    'reports an invalid tag name without disguising it as a read error',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('README.md', 'base\n');
      final commit = await repository.commit('Initial commit');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);

      expect(
        await controller.createTag(
          GitCreateTagOptions(name: 'release candidate', objectId: commit),
        ),
        isFalse,
      );

      final state = container.read(repositorySessionProvider);
      expect(state.phase, RepositorySessionPhase.ready);
      expect(state.message, startsWith('标签名称无效。'));
      expect(state.tags, isEmpty);
    },
  );

  test(
    'allows merging a local branch with unrelated uncommitted changes',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('README.md', 'base\n');
      await repository.commit('Initial commit');
      await repository.runGit(['branch', 'feature/merge']);
      await repository.runGit(['switch', 'feature/merge']);
      await repository.writeFile('feature.txt', 'feature\n');
      await repository.commit('Feature commit');
      await repository.runGit(['switch', 'main']);
      await repository.writeFile('draft.txt', 'uncommitted\n');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);

      final overview = mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!;
      expect(
        overview.disabledActions,
        isNot(contains(RepositoryAction.mergeBranch)),
      );
      expect(await controller.mergeLocalBranch('feature/merge'), isTrue);

      final state = container.read(repositorySessionProvider);
      expect(state.phase, RepositorySessionPhase.ready);
      expect(state.status!.isClean, isFalse);
      expect(
        await File('${repository.workingDirectory.path}/feature.txt').exists(),
        isTrue,
      );
    },
  );

  test('refreshes conflict state when a branch merge conflicts', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    await repository.commit('Initial commit');
    await repository.runGit(['branch', 'feature/conflict']);
    await repository.runGit(['switch', 'feature/conflict']);
    await repository.writeFile('README.md', 'feature\n');
    await repository.commit('Feature change');
    await repository.runGit(['switch', 'main']);
    await repository.writeFile('README.md', 'main\n');
    await repository.commit('Main change');
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);

    expect(await controller.mergeLocalBranch('feature/conflict'), isFalse);

    final state = container.read(repositorySessionProvider);
    expect(state.phase, RepositorySessionPhase.error);
    expect(state.status!.conflictedEntries, isNotEmpty);
    expect(state.message, contains('合并遇到冲突'));
    final overview = mapRepositoryOverview(state).repository!;
    expect(overview.disabledActions, contains(RepositoryAction.mergeBranch));
    expect(await controller.mergeLocalBranch('feature/conflict'), isFalse);

    final conflict = overview.changes.singleWhere(
      (change) => change.kind == RepositoryChangeKind.conflicted,
    );
    final versions = await controller.readConflictVersions(conflict);
    expect(versions, isNotNull);
    expect(versions!.baseText, 'base\n');
    expect(versions.oursText, 'main\n');
    expect(versions.theirsText, 'feature\n');
    expect(versions.workingText, contains('<<<<<<<'));
    expect(
      await controller.resolveConflictWithContent(
        conflict,
        'merged in internal diff\n',
      ),
      isTrue,
    );
    expect(
      container.read(repositorySessionProvider).status!.conflictedEntries,
      isEmpty,
    );
    expect(
      await File(
        '${repository.workingDirectory.path}${Platform.pathSeparator}README.md',
      ).readAsString(),
      'merged in internal diff\n',
    );
  });

  test(
    'fetches all configured remotes and refreshes ahead-behind state',
    () async {
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

      expect(
        await controller.fetchWithOptions(const GitFetchOptions()),
        isTrue,
      );
      final state = container.read(repositorySessionProvider);
      expect(state.phase, RepositorySessionPhase.ready);
      expect(state.status!.branch.behind, 1);
      final operation = state.operations.firstWhere(
        (operation) => operation.kind == RepositoryOperationKind.fetch,
      );
      expect(operation.outcome, RepositoryOperationOutcome.succeeded);
    },
  );

  test(
    'refreshes refs after one remote succeeds and another fetch fails',
    () async {
      final source = await GitTestRepository.create();
      addTearDown(source.dispose);
      await source.writeFile('README.md', '# Git Desktop\n');
      await source.commit('Initial commit');
      final origin = await source.createBareOrigin();
      await source.runGit(['push', 'origin', 'main']);
      final target = await GitTestRepository.cloneFrom(origin);
      addTearDown(target.dispose);
      await target.runGit([
        'remote',
        'add',
        'broken',
        '${target.workingDirectory.path}${Platform.pathSeparator}missing.git',
      ]);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(target.workingDirectory.path);
      await source.writeFile('CHANGELOG.md', '# Changes\n');
      await source.commit('Add changelog');
      await source.runGit(['push', 'origin', 'main']);

      expect(
        await controller.fetchWithOptions(const GitFetchOptions()),
        isFalse,
      );
      final state = container.read(repositorySessionProvider);
      expect(state.phase, RepositorySessionPhase.error);
      expect(state.status!.branch.behind, 1);
    },
  );

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

  test('supports an explicitly selected remote without origin', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', '# Initial\n');
    await repository.commit('initial');
    await repository.createBareOrigin();
    await repository.runGit(['push', '--set-upstream', 'origin', 'main']);
    await repository.runGit(['remote', 'rename', 'origin', 'upstream']);
    await repository.runGit(['branch', '--unset-upstream']);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);

    final overview = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!;
    expect(container.read(repositorySessionProvider).hasOriginRemote, isFalse);
    expect(container.read(repositorySessionProvider).remoteNames, ['upstream']);
    expect(overview.disabledActions, isNot(contains(RepositoryAction.fetch)));
    expect(overview.disabledActions, isNot(contains(RepositoryAction.pull)));
    expect(overview.disabledActions, isNot(contains(RepositoryAction.push)));

    final upstreamRef = overview.refs.singleWhere(
      (ref) => ref.kind == RepositoryRefKind.remote,
    );
    await controller.selectReference(upstreamRef);
    expect(
      container.read(repositorySessionProvider).selectedRefId,
      'remotes/upstream',
    );
    expect(await controller.fetchRemote('upstream'), isTrue);
    expect(
      await controller.pullWithOptions(
        const GitPullOptions(remoteName: 'upstream', remoteBranch: 'main'),
      ),
      isTrue,
    );
  });

  test(
    'redacts credentials from the remote URL kept in session state',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.runGit([
        'remote',
        'add',
        'origin',
        'https://alice:secret@example.invalid/repository.git',
      ]);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(repositorySessionProvider.notifier)
          .openRepository(repository.workingDirectory.path);

      expect(
        container.read(repositorySessionProvider).originUrl,
        'https://***@example.invalid/repository.git',
      );
    },
  );

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

  test(
    'keeps pull available while the work tree has uncommitted changes',
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
      await File(
        '${directory.path}${Platform.pathSeparator}local.txt',
      ).writeAsString('keep\n');
      await controller.refresh();

      expect(
        mapRepositoryOverview(
          container.read(repositorySessionProvider),
        ).repository!.disabledActions,
        isNot(contains(RepositoryAction.pull)),
      );
      expect(await controller.pullFastForward(), isFalse);
      expect(
        container.read(repositorySessionProvider).phase,
        RepositorySessionPhase.ready,
      );

      await source.writeFile('remote.txt', 'remote change\n');
      await source.commit('Remote change');
      await source.runGit(['push', 'origin', 'main']);
      expect(
        await controller.pullWithOptions(
          const GitPullOptions(remoteName: 'origin', remoteBranch: 'main'),
        ),
        isTrue,
      );
      expect(
        await File(
          '${directory.path}${Platform.pathSeparator}local.txt',
        ).readAsString(),
        'keep\n',
      );
      expect(
        await File(
          '${directory.path}${Platform.pathSeparator}remote.txt',
        ).exists(),
        isTrue,
      );
    },
  );

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

  test(
    'pushes branches selected in the push dialog and records tracking',
    () async {
      final source = await GitTestRepository.create();
      addTearDown(source.dispose);
      await source.writeFile('README.md', '# Git Desktop\n');
      await source.commit('Initial commit');
      final origin = await source.createBareOrigin();
      await source.runGit(['push', '--set-upstream', 'origin', 'main']);
      final target = await GitTestRepository.cloneFrom(origin);
      addTearDown(target.dispose);
      await target.runGit(['branch', 'feature/dialog-push']);
      await target.runGit(['switch', 'feature/dialog-push']);
      await target.writeFile('dialog.txt', 'push this branch\n');
      final featureHead = await target.commit('Prepare dialog push');
      await target.runGit(['switch', 'main']);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(target.workingDirectory.path);

      expect(await controller.readRemoteNames(), contains('origin'));
      expect(
        await controller.pushWithOptions(
          const GitPushOptions(
            remoteName: 'origin',
            branches: [
              GitPushBranch(
                localBranch: 'feature/dialog-push',
                remoteBranch: 'review/dialog',
                trackRemote: true,
              ),
            ],
          ),
        ),
        isTrue,
      );
      final state = container.read(repositorySessionProvider);
      expect(state.phase, RepositorySessionPhase.ready);
      expect(
        state.localBranches
            .singleWhere((branch) => branch.name == 'feature/dialog-push')
            .upstream,
        'origin/review/dialog',
      );
      expect(
        (await source.runGit([
          'rev-parse',
          'refs/heads/review/dialog',
        ], workingDirectory: origin)).stdout.toString().trim(),
        featureHead,
      );
    },
  );

  test(
    'enables and completes first push when configured upstream is gone',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('README.md', '# First push\n');
      final localHead = await repository.commit('Initial commit');
      final origin = await repository.createBareOrigin();
      await repository.runGit(['config', 'branch.main.remote', 'origin']);
      await repository.runGit([
        'config',
        'branch.main.merge',
        'refs/heads/main',
      ]);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);

      var state = container.read(repositorySessionProvider);
      expect(state.status!.branch.isUpstreamGone, isTrue);
      expect(
        mapRepositoryOverview(state).repository!.disabledActions,
        isNot(contains(RepositoryAction.push)),
      );
      expect(await controller.pushUpstream(), isTrue);

      state = container.read(repositorySessionProvider);
      expect(state.status!.branch.isUpstreamGone, isFalse);
      expect(
        (await repository.runGit([
          'rev-parse',
          'refs/heads/main',
        ], workingDirectory: origin)).stdout.toString().trim(),
        localHead,
      );
    },
  );

  test('refuses push without a configured remote target', () async {
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

  test(
    'keeps push available when the configured upstream is already current',
    () async {
      final source = await GitTestRepository.create();
      addTearDown(source.dispose);
      await source.writeFile('README.md', '# Git Desktop\n');
      await source.commit('Initial commit');
      final origin = await source.createBareOrigin();
      await source.runGit(['push', '--set-upstream', 'origin', 'main']);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(source.workingDirectory.path);

      final state = container.read(repositorySessionProvider);
      expect(state.status!.branch.ahead, 0);
      expect(
        mapRepositoryOverview(state).repository!.disabledActions,
        isNot(contains(RepositoryAction.push)),
      );
      expect(await controller.pushUpstream(), isTrue);
      expect(container.read(repositorySessionProvider).status!.branch.ahead, 0);
      // Keep the bare remote alive for the duration of this no-op push test.
      expect(await origin.exists(), isTrue);
    },
  );

  test('pushes the configured local branch while HEAD is detached', () async {
    final source = await GitTestRepository.create();
    addTearDown(source.dispose);
    await source.writeFile('README.md', '# Git Desktop\n');
    await source.commit('Initial commit');
    final origin = await source.createBareOrigin();
    await source.runGit(['push', '--set-upstream', 'origin', 'main']);
    await source.writeFile('CHANGELOG.md', '# Changes\n');
    await source.commit('Add changelog');
    await source.runGit(['switch', '--detach', 'origin/main']);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(source.workingDirectory.path);

    final state = container.read(repositorySessionProvider);
    expect(state.status!.branch.isDetached, isTrue);
    expect(mapRepositoryOverview(state).repository!.primaryLocalBranch, 'main');
    expect(
      mapRepositoryOverview(state).repository!.disabledActions,
      isNot(contains(RepositoryAction.push)),
    );
    expect(await controller.pushUpstream(), isTrue);
    expect(
      (await source.runGit([
        'rev-parse',
        'refs/heads/main',
      ], workingDirectory: origin)).stdout.toString().trim(),
      (await source.runGit([
        'rev-parse',
        'refs/heads/main',
      ])).stdout.toString().trim(),
    );
  });

  test('completes the clone-to-push core workflow with real Git', () async {
    final source = await GitTestRepository.create();
    addTearDown(source.dispose);
    await source.writeFile('README.md', '# Git Desktop\n');
    await source.commit('Initial commit');
    final origin = await source.createBareOrigin();
    await source.runGit(['push', '--set-upstream', 'origin', 'main']);
    final directory = await Directory.systemTemp.createTemp(
      'git-desktop-core-workflow-',
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
      '${directory.path}${Platform.pathSeparator}CHANGELOG.md',
    ).writeAsString('# Changes\n');
    await controller.refresh();
    final change = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!.changes.single;
    await controller.toggleStage(change);
    expect(
      container.read(repositorySessionProvider).status!.stagedEntries,
      hasLength(1),
    );
    expect(await controller.createCommit('Add changelog'), isTrue);
    expect(await controller.createLocalBranch('feature/changelog'), isTrue);
    expect(await controller.pushUpstream(), isTrue);

    final state = container.read(repositorySessionProvider);
    expect(state.status!.branch.head, 'main');
    expect(state.status!.branch.ahead, 0);
    expect(
      (await source.runGit([
        'rev-parse',
        'refs/heads/main',
      ], workingDirectory: origin)).stdout.toString().trim(),
      state.status!.branch.objectId,
    );
    expect(
      state.operations
          .where(
            (operation) =>
                operation.outcome == RepositoryOperationOutcome.succeeded,
          )
          .map((operation) => operation.kind),
      containsAll(<RepositoryOperationKind>[
        RepositoryOperationKind.clone,
        RepositoryOperationKind.push,
      ]),
    );
  });
}

final class _MemoryRepositorySessionStore implements RepositorySessionStore {
  RepositorySessionSnapshot snapshot = const RepositorySessionSnapshot();

  @override
  Future<RepositorySessionSnapshot> load() async => snapshot;

  @override
  Future<void> save(RepositorySessionSnapshot next) async {
    snapshot = next;
  }
}
