import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/app/repository_change_monitor.dart';
import 'package:git_desktop/src/app/external_tool_configuration.dart';
import 'package:git_desktop/src/app/external_tool_configuration_store.dart';
import 'package:git_desktop/src/app/git_flow_semantics.dart';
import 'package:git_desktop/src/app/repository_session.dart';
import 'package:git_desktop/src/app/repository_library_controller.dart';
import 'package:git_desktop/src/app/repository_session_store.dart';
import 'package:git_desktop/src/app/repository_view_mapper.dart';
import 'package:git_desktop/src/app/repository_trust.dart';
import 'package:git_desktop/src/git/git.dart';
import 'package:git_desktop/src/presentation/presentation.dart';

import '../support/git_test_repository.dart';

void main() {
  test(
    'hides selected working-tree entries only in the current session view',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('README.md', 'base\n');
      await repository.commit('base');
      await repository.writeFile('README.md', 'changed\n');
      await repository.writeFile('new.txt', 'new\n');

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);
      controller.selectUncommittedChanges();
      final before = mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!;
      expect(before.changes, hasLength(2));
      expect(before.visibleChanges, hasLength(2));

      controller.hideChanges([before.visibleChanges.first]);
      final hidden = mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!;
      expect(hidden.changes, hasLength(2));
      expect(hidden.visibleChanges, hasLength(1));
      expect(hidden.stagedChangeCount + hidden.unstagedChangeCount, 1);

      controller.clearHiddenChanges();
      final restored = mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!;
      expect(restored.visibleChanges, hasLength(2));

      controller.hideChanges(restored.visibleChanges);
      expect(
        mapRepositoryOverview(
          container.read(repositorySessionProvider),
        ).repository!.visibleChanges,
        isEmpty,
      );
      await controller.refresh();
      expect(
        container.read(repositorySessionProvider).hiddenChangeKeys,
        isEmpty,
      );
      expect(
        mapRepositoryOverview(
          container.read(repositorySessionProvider),
        ).repository!.visibleChanges,
        hasLength(2),
      );
    },
  );

  test(
    'keeps the workspace navigable while a remote task is running',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('README.md', 'workspace\n');
      await repository.commit('Initial commit');

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);

      final loading = container
          .read(repositorySessionProvider)
          .copyWith(
            phase: RepositorySessionPhase.loading,
            isFetchRunning: true,
          );
      final overview = mapRepositoryOverview(loading);

      expect(overview.state, RepositoryOverviewState.ready);
      expect(overview.repository, isNotNull);
      expect(overview.repository!.refs, isNotEmpty);
      expect(overview.repository!.isRefreshing, isTrue);
    },
  );

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

  test(
    'adds an ignore rule after revalidating the selected Git status row',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('README.md', 'tracked\n');
      await repository.commit('Initial commit');
      await repository.writeFile('output.log', 'generated\n');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);
      controller.selectUncommittedChanges();
      final overview = mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!;
      final output = overview.changes.singleWhere(
        (change) => change.path == 'output.log',
      );

      final result = await controller.ignoreChanges(
        [output],
        patternKind: GitIgnorePatternKind.exactPath,
        destination: GitIgnoreDestination.repositoryGitignore,
      );

      expect(result?.addedPatterns, ['/output.log']);
      expect(
        await File(
          '${repository.workingDirectory.path}/.gitignore',
        ).readAsString(),
        '/output.log\n',
      );
      expect(
        container
            .read(repositorySessionProvider)
            .status!
            .entries
            .any((entry) => entry.path.display == 'output.log'),
        isFalse,
      );
    },
  );

  test(
    'refuses an ignore request after its selected file disappears',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('README.md', 'tracked\n');
      await repository.commit('Initial commit');
      await repository.writeFile('stale.log', 'generated\n');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);
      controller.selectUncommittedChanges();
      final stale = mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!.changes.singleWhere((change) => change.path == 'stale.log');
      await File('${repository.workingDirectory.path}/stale.log').delete();

      final result = await controller.ignoreChanges(
        [stale],
        patternKind: GitIgnorePatternKind.exactPath,
        destination: GitIgnoreDestination.repositoryGitignore,
      );

      expect(result, isNull);
      expect(
        await File('${repository.workingDirectory.path}/.gitignore').exists(),
        isFalse,
      );
    },
  );

  test('copies selected files and refreshes the repository session', () async {
    if (!Platform.isMacOS) return;
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'tracked\n');
    await repository.commit('Initial commit');
    await repository.writeFile('output.log', 'generated\n');
    final destination = await Directory.systemTemp.createTemp(
      'git-desktop-session-copy-',
    );
    addTearDown(() => destination.delete(recursive: true));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    controller.selectUncommittedChanges();
    final output = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!.changes.singleWhere((change) => change.path == 'output.log');

    final result = await controller.copyChanges([
      output,
    ], destinationDirectory: destination.path);

    expect(result?.copiedPaths, ['output.log']);
    expect(
      await File('${destination.path}/output.log').readAsString(),
      'generated\n',
    );
    expect(
      container.read(repositorySessionProvider).phase,
      RepositorySessionPhase.ready,
    );
  });

  test('refuses copying a selection whose Git source changed', () async {
    if (!Platform.isMacOS) return;
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'tracked\n');
    await repository.commit('Initial commit');
    await repository.writeFile('stale.txt', 'temporary\n');
    final destination = await Directory.systemTemp.createTemp(
      'git-desktop-session-copy-stale-',
    );
    addTearDown(() => destination.delete(recursive: true));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    controller.selectUncommittedChanges();
    final stale = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!.changes.singleWhere((change) => change.path == 'stale.txt');
    await repository.runGit(['add', '--', 'stale.txt']);

    final result = await controller.copyChanges([
      stale,
    ], destinationDirectory: destination.path);

    expect(result, isNull);
    expect(await destination.list().isEmpty, isTrue);
  });

  test('moves selected files and refreshes the repository session', () async {
    if (!Platform.isMacOS) return;
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'tracked\n');
    await repository.commit('Initial commit');
    final source = await repository.writeFile('moving.log', 'generated\n');
    final destination = await Directory.systemTemp.createTemp(
      'git-desktop-session-move-',
    );
    addTearDown(() => destination.delete(recursive: true));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    controller.selectUncommittedChanges();
    final moving = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!.changes.singleWhere((change) => change.path == 'moving.log');

    final result = await controller.moveChanges([
      moving,
    ], destinationDirectory: destination.path);

    expect(result?.movedPaths, ['moving.log']);
    expect(await source.exists(), isFalse);
    expect(
      await File('${destination.path}/moving.log').readAsString(),
      'generated\n',
    );
    expect(
      container.read(repositorySessionProvider).phase,
      RepositorySessionPhase.ready,
    );
  });

  test('refuses moving a selection that became deleted', () async {
    if (!Platform.isMacOS) return;
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    final source = await repository.writeFile('stale.txt', 'tracked\n');
    await repository.commit('Initial commit');
    await source.writeAsString('changed\n');
    final destination = await Directory.systemTemp.createTemp(
      'git-desktop-session-move-stale-',
    );
    addTearDown(() => destination.delete(recursive: true));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    controller.selectUncommittedChanges();
    final stale = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!.changes.singleWhere((change) => change.path == 'stale.txt');
    await source.delete();

    final result = await controller.moveChanges([
      stale,
    ], destinationDirectory: destination.path);

    expect(result, isNull);
    expect(await destination.list().isEmpty, isTrue);
  });

  test('reads a working-tree review without changing its selection', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'before\n');
    await repository.commit('Initial commit');
    await repository.writeFile('README.md', 'after\n');
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    controller.selectUncommittedChanges();
    final change = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!.changes.singleWhere((change) => change.path == 'README.md');
    final selectionBefore = container
        .read(repositorySessionProvider)
        .selectedChange;

    final diff = await controller.readWorkingTreeReviewDiff(
      change,
      cancellationToken: GitCancellationToken(),
    );

    expect(diff.text, contains('-before'));
    expect(diff.text, contains('+after'));
    expect(
      container.read(repositorySessionProvider).selectedChange,
      same(selectionBefore),
    );

    final cancellation = GitCancellationToken()..cancel();
    await expectLater(
      controller.readWorkingTreeReviewDiff(
        change,
        cancellationToken: cancellation,
      ),
      throwsA(isA<GitCancelledException>()),
    );
  });

  test('rejects a working-tree review whose selected source changed', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'before\n');
    await repository.commit('Initial commit');
    await repository.writeFile('README.md', 'after\n');
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    controller.selectUncommittedChanges();
    final unstaged =
        mapRepositoryOverview(
          container.read(repositorySessionProvider),
        ).repository!.changes.singleWhere(
          (change) => change.path == 'README.md' && !change.isStaged,
        );
    await repository.runGit(['add', '--', 'README.md']);

    await expectLater(
      controller.readWorkingTreeReviewDiff(
        unstaged,
        cancellationToken: GitCancellationToken(),
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('reads a commit review without changing the main commit Diff', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'reviewed\n');
    await repository.commit('Reviewed commit');
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    final session = container.read(repositorySessionProvider);
    final commit = session.commits.first;
    final selectedDiffBefore = session.commitDiff;

    final diff = await controller.readCommitReviewDiff(
      commit,
      path: 'README.md',
      cancellationToken: GitCancellationToken(),
    );

    expect(diff.text, contains('+reviewed'));
    expect(
      container.read(repositorySessionProvider).commitDiff,
      same(selectedDiffBefore),
    );

    final cancellation = GitCancellationToken()..cancel();
    await expectLater(
      controller.readCommitReviewDiff(
        commit,
        path: 'README.md',
        cancellationToken: cancellation,
      ),
      throwsA(isA<GitCancelledException>()),
    );
  });

  test(
    'reads selected historical file bytes without changing selection',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      final binary = <int>[0, 255, 1, 10, 128];
      final binaryFile = File(
        '${repository.workingDirectory.path}${Platform.pathSeparator}archive'
        '${Platform.pathSeparator}data.bin',
      );
      await binaryFile.parent.create(recursive: true);
      await binaryFile.writeAsBytes(binary);
      final commit = await repository.commit('Add binary file');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);
      await controller.selectCommit(commit);

      final bytes = await controller.readSelectedCommitFileBytes();
      final comparison = await controller.readSelectedCommitFileComparison();

      expect(bytes, binary);
      expect(comparison.beforeBytes, isEmpty);
      expect(comparison.afterBytes, binary);
      final selected = container.read(repositorySessionProvider);
      expect(selected.selectedCommitId, commit);
      expect(
        selected.selectedCommitFile?.file.path.display,
        'archive/data.bin',
      );
    },
  );

  test('rejects opening a file from its deleting commit', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('removed.txt', 'before\n');
    await repository.commit('Add file');
    await File(
      '${repository.workingDirectory.path}${Platform.pathSeparator}removed.txt',
    ).delete();
    final deletion = await repository.commit('Delete file');
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    await controller.selectCommit(deletion);

    await expectLater(
      controller.readSelectedCommitFileBytes(),
      throwsA(isA<StateError>()),
    );
    final comparison = await controller.readSelectedCommitFileComparison();
    expect(comparison.beforeBytes, utf8.encode('before\n'));
    expect(comparison.afterBytes, isEmpty);
  });

  test(
    'exports revalidated selected working-tree changes as a patch',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('selected.txt', 'before\n');
      await repository.writeFile('other.txt', 'base\n');
      await repository.commit('Base');
      await repository.writeFile('selected.txt', 'after\n');
      await repository.writeFile('other.txt', 'excluded\n');
      final outputDirectory = await Directory.systemTemp.createTemp(
        'git-desktop-session-working-patch-',
      );
      addTearDown(() => outputDirectory.delete(recursive: true));
      final outputPath = '${outputDirectory.path}/selected.patch';
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);
      final overview = mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!;
      final selected = overview.changes.singleWhere(
        (change) => change.path == 'selected.txt' && !change.isStaged,
      );

      expect(
        await controller.createPatchForWorkingTreeChanges([
          selected,
        ], outputPath: outputPath),
        isTrue,
      );
      final patch = await File(outputPath).readAsString();
      expect(patch, contains('+after'));
      expect(patch, isNot(contains('excluded')));
    },
  );

  test('reads exact staged and unstaged layers for external diff', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('layered.txt', 'head\n');
    await repository.commit('Base');
    await repository.writeFile('layered.txt', 'index\n');
    await repository.runGit(['add', '--', 'layered.txt']);
    await repository.writeFile('layered.txt', 'worktree\n');
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    final changes = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!.changes.where((change) => change.path == 'layered.txt');

    final stagedComparison = await controller.readWorkingTreeFileComparison(
      changes.singleWhere((change) => change.isStaged),
    );
    expect(utf8.decode(stagedComparison.beforeBytes), 'head\n');
    expect(utf8.decode(stagedComparison.afterBytes), 'index\n');

    final unstagedComparison = await controller.readWorkingTreeFileComparison(
      changes.singleWhere((change) => !change.isStaged),
    );
    expect(utf8.decode(unstagedComparison.beforeBytes), 'index\n');
    expect(utf8.decode(unstagedComparison.afterBytes), 'worktree\n');
  });

  test('uses empty snapshots for added and deleted tracked files', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('removed.txt', 'to remove\n');
    await repository.commit('Base');
    await repository.runGit(['rm', '--', 'removed.txt']);
    await repository.writeFile('added.txt', 'new file\n');
    await repository.runGit(['add', '--', 'added.txt']);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    final changes = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!.changes;

    final removed = changes.singleWhere(
      (change) => change.path == 'removed.txt' && change.isStaged,
    );
    final removedComparison = await controller.readWorkingTreeFileComparison(
      removed,
    );
    expect(utf8.decode(removedComparison.beforeBytes), 'to remove\n');
    expect(removedComparison.afterBytes, isEmpty);

    final added = changes.singleWhere(
      (change) => change.path == 'added.txt' && change.isStaged,
    );
    final addedComparison = await controller.readWorkingTreeFileComparison(
      added,
    );
    expect(addedComparison.beforeBytes, isEmpty);
    expect(utf8.decode(addedComparison.afterBytes), 'new file\n');
  });

  test(
    'automatically refreshes external work-tree changes without reloading history',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('README.md', 'base\n');
      await repository.commit('Base');
      final events = StreamController<FileSystemEvent>.broadcast();
      addTearDown(events.close);
      final monitor = RepositoryChangeMonitor(
        debounceDelay: const Duration(milliseconds: 10),
        maximumDelay: const Duration(milliseconds: 30),
        watchDirectory: (_, _) => events.stream,
      );
      final container = ProviderContainer(
        overrides: [repositoryChangeMonitorProvider.overrideWithValue(monitor)],
      );
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.enableAutomaticRefresh();
      await controller.openRepository(repository.workingDirectory.path);
      final original = container.read(repositorySessionProvider);
      final originalHistory = original.historyCommits;
      final originalCommitId = original.selectedCommitId;
      final originalCommitChanges = original.commitChanges;
      final originalCommitDiff = original.commitDiff;
      final phases = <RepositorySessionPhase>[];
      final subscription = container.listen<RepositorySessionState>(
        repositorySessionProvider,
        (_, next) => phases.add(next.phase),
      );
      addTearDown(subscription.close);

      await repository.writeFile('README.md', 'changed externally\n');
      events.add(
        FileSystemModifyEvent(
          '${repository.workingDirectory.path}${Platform.pathSeparator}README.md',
          false,
          true,
        ),
      );

      await _waitUntil(
        () =>
            container
                .read(repositorySessionProvider)
                .status
                ?.entries
                .any((entry) => entry.path.display == 'README.md') ??
            false,
      );
      final refreshed = container.read(repositorySessionProvider);
      expect(phases, isNotEmpty);
      expect(
        phases.every((phase) => phase == RepositorySessionPhase.ready),
        isTrue,
      );
      expect(identical(refreshed.historyCommits, originalHistory), isTrue);
      expect(refreshed.selectedCommitId, originalCommitId);
      expect(identical(refreshed.commitChanges, originalCommitChanges), isTrue);
      expect(identical(refreshed.commitDiff, originalCommitDiff), isTrue);
      expect(refreshed.status!.isClean, isFalse);
    },
  );

  test('suppresses unchanged automatic work-tree refresh publications', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    await repository.commit('Base');
    final events = StreamController<FileSystemEvent>.broadcast();
    addTearDown(events.close);
    final monitor = RepositoryChangeMonitor(
      debounceDelay: const Duration(milliseconds: 10),
      maximumDelay: const Duration(milliseconds: 30),
      watchDirectory: (_, _) => events.stream,
    );
    final container = ProviderContainer(
      overrides: [repositoryChangeMonitorProvider.overrideWithValue(monitor)],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.enableAutomaticRefresh();
    await controller.openRepository(repository.workingDirectory.path);
    final original = container.read(repositorySessionProvider);
    final emitted = <RepositorySessionState>[];
    final subscription = container.listen<RepositorySessionState>(
      repositorySessionProvider,
      (_, next) => emitted.add(next),
    );
    addTearDown(subscription.close);

    events.add(
      FileSystemModifyEvent(
        '${repository.workingDirectory.path}${Platform.pathSeparator}build-output.tmp',
        false,
        true,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(emitted, isEmpty);
    expect(
      identical(container.read(repositorySessionProvider), original),
      isTrue,
    );
  });

  test('automatically reloads history after external HEAD changes', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    await repository.commit('Base');
    final events = StreamController<FileSystemEvent>.broadcast();
    addTearDown(events.close);
    final monitor = RepositoryChangeMonitor(
      debounceDelay: const Duration(milliseconds: 10),
      maximumDelay: const Duration(milliseconds: 30),
      watchDirectory: (_, _) => events.stream,
    );
    final container = ProviderContainer(
      overrides: [repositoryChangeMonitorProvider.overrideWithValue(monitor)],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.enableAutomaticRefresh();
    await controller.openRepository(repository.workingDirectory.path);

    await repository.writeFile('README.md', 'external commit\n');
    final externalCommit = await repository.commit('External commit');
    final watchedGitDirectory = container
        .read(repositorySessionProvider)
        .repository!
        .gitDirectory;
    events.add(
      FileSystemModifyEvent(
        '$watchedGitDirectory${Platform.pathSeparator}HEAD',
        false,
        true,
      ),
    );

    await _waitUntil(
      () =>
          container
              .read(repositorySessionProvider)
              .historyCommits
              .firstOrNull
              ?.objectId ==
          externalCommit,
      diagnostic: () {
        final state = container.read(repositorySessionProvider);
        return 'phase=${state.phase}, message=${state.message}, '
            'head=${state.status?.branch.objectId}, '
            'history=${state.historyCommits.map((commit) => commit.objectId).toList()}';
      },
    );
    final refreshed = container.read(repositorySessionProvider);
    expect(refreshed.status!.branch.objectId, externalCommit);
    expect(refreshed.selectedCommitId, externalCommit);
  });

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
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
    'runs structured history queries through Git and resets pagination',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('README.md', 'base\n');
      await repository.commit('base');
      await repository.writeFile('lib/query.dart', 'query\n');
      await repository.commit('query change');
      await repository.writeFile('docs/other.md', 'other\n');
      await repository.commit('other change');

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);

      controller.setSearchQuery(
        'path:lib/query.dart after:2026-01-01 before:2027-01-01',
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await _waitUntil(
        () => !container.read(repositorySessionProvider).isHistoryLoading,
        diagnostic: () =>
            container.read(repositorySessionProvider).historyLoadError ?? '',
      );

      final state = container.read(repositorySessionProvider);
      expect(state.historyCommits, hasLength(1));
      expect(state.historyCommits.single.subject, 'query change');
      expect(state.historyOffset, 1);
      expect(state.hasMoreHistory, isFalse);
    },
  );

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
            view.repository!.isWorkingTreeBusy &&
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
    expect(
      container.read(repositorySessionProvider).operations.first.outcome,
      RepositoryOperationOutcome.succeeded,
    );
  });

  test('marks a completed stage uncertain when refresh fails', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('stage-me.txt', 'stage me\n');
    var failNextRefresh = true;
    final container = ProviderContainer(
      overrides: [
        repositoryRefreshHookForTestingProvider.overrideWithValue(() async {
          if (failNextRefresh) {
            failNextRefresh = false;
            throw StateError('injected stage refresh failure');
          }
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    final change = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!.changes.single;

    await controller.toggleStage(change);
    final state = container.read(repositorySessionProvider);
    expect(
      state.operations.first.outcome,
      RepositoryOperationOutcome.uncertain,
    );
    expect(state.message, contains('写入已完成'));
    expect(
      (await repository.runGit(['diff', '--cached', '--name-only'])).stdout,
      contains('stage-me.txt'),
    );
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
    expect(state.operations.first.kind, RepositoryOperationKind.file);
    expect(
      state.operations.first.outcome,
      RepositoryOperationOutcome.succeeded,
    );
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

  test('marks stop tracking uncertain when refresh fails', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('local.txt', 'base\n');
    await repository.commit('Add local file');
    await repository.writeFile('local.txt', 'changed\n');

    var armed = false;
    var armedRefreshCount = 0;
    final container = ProviderContainer(
      overrides: [
        repositoryRefreshHookForTestingProvider.overrideWithValue(() async {
          if (armed) {
            armedRefreshCount += 1;
          }
          if (armedRefreshCount == 2) {
            throw StateError('injected stop tracking refresh failure');
          }
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    final change = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!.changes.single;
    armed = true;
    expect(await controller.stopTrackingChanges([change]), isFalse);
    final state = container.read(repositorySessionProvider);
    final operation = state.operations.firstWhere(
      (entry) => entry.kind == RepositoryOperationKind.file,
    );
    expect(operation.outcome, RepositoryOperationOutcome.uncertain);
    expect(state.message, contains('写入已完成'));
    expect(
      await File('${repository.workingDirectory.path}/local.txt').exists(),
      isTrue,
    );
  });

  test('marks historical stop tracking uncertain when refresh fails', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('local.txt', 'base\n');
    final commit = await repository.commit('Add local file');
    final container = ProviderContainer(
      overrides: [
        repositoryRefreshHookForTestingProvider.overrideWithValue(() async {
          final staged = await repository.runGit([
            'diff',
            '--cached',
            '--quiet',
          ], throwOnError: false);
          if (staged.exitCode != 0) {
            throw StateError(
              'injected historical stop tracking refresh failure',
            );
          }
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    await controller.selectCommit(commit);
    expect(await controller.stopTrackingSelectedCommitFile(), isFalse);
    final state = container.read(repositorySessionProvider);
    final operation = state.operations.firstWhere(
      (entry) => entry.kind == RepositoryOperationKind.file,
    );
    expect(operation.outcome, RepositoryOperationOutcome.uncertain);
    expect(state.message, contains('写入已完成'));
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
    expect(state.operations.first.kind, RepositoryOperationKind.file);
    expect(
      state.operations.first.outcome,
      RepositoryOperationOutcome.succeeded,
    );
    expect(state.selectedRefId, 'history');
    expect(state.selectedCommitId, isNotNull);
    expect(state.selectedChange, isNull);
    expect(state.diff, isNull);
  });

  test('resets unstaged tracked files to HEAD in index and work tree', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('modified.txt', 'base\n');
    await repository.writeFile('deleted.txt', 'keep me\n');
    await repository.commit('Add tracked files');
    await repository.writeFile('modified.txt', 'changed\n');
    await File(
      '${repository.workingDirectory.path}${Platform.pathSeparator}deleted.txt',
    ).delete();

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    final overview = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!;
    final unstaged = overview.changes
        .where((change) => !change.isStaged)
        .toList(growable: false);

    expect(unstaged, hasLength(2));
    expect(unstaged.every((change) => change.canResetToHead), isTrue);
    controller.selectUncommittedChanges();
    expect(await controller.resetChangesToHead(unstaged), isTrue);
    expect(
      await File(
        '${repository.workingDirectory.path}${Platform.pathSeparator}modified.txt',
      ).readAsString(),
      'base\n',
    );
    expect(
      await File(
        '${repository.workingDirectory.path}${Platform.pathSeparator}deleted.txt',
      ).readAsString(),
      'keep me\n',
    );
    expect(container.read(repositorySessionProvider).status!.isClean, isTrue);
  });

  test(
    'restores a selected historical file over staged and unstaged content',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('tracked.txt', 'historical\n');
      final historical = await repository.commit('Historical version');
      await repository.writeFile('tracked.txt', 'current\n');
      final head = await repository.commit('Current version');
      await repository.writeFile('tracked.txt', 'staged\n');
      await repository.runGit(['add', '--', 'tracked.txt']);
      await repository.writeFile('tracked.txt', 'unstaged\n');

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);
      await controller.selectCommit(historical);

      expect(
        await controller.resetSelectedCommitFileToCommit(
          objectId: historical,
          path: 'tracked.txt',
        ),
        isTrue,
      );
      expect(
        await File(
          '${repository.workingDirectory.path}${Platform.pathSeparator}'
          'tracked.txt',
        ).readAsString(),
        'historical\n',
      );
      expect(
        (await repository.runGit(['show', ':tracked.txt'])).stdout.toString(),
        'historical\n',
      );
      expect(
        (await repository.runGit([
          'rev-parse',
          'HEAD',
        ])).stdout.toString().trim(),
        head,
      );
      final state = container.read(repositorySessionProvider);
      expect(state.selectedCommitId, historical);
      expect(state.selectedCommitFile?.file.path.display, 'tracked.txt');
    },
  );

  test('restores a path from an added commit while HEAD is detached', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('added.txt', 'added version\n');
    final added = await repository.commit('Add path');
    await repository.writeFile('added.txt', 'later version\n');
    final head = await repository.commit('Change path');
    await repository.runGit(['switch', '--detach', head]);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    await controller.selectCommit(added);

    expect(
      await controller.resetSelectedCommitFileToCommit(
        objectId: added,
        path: 'added.txt',
      ),
      isTrue,
    );
    expect(
      await File(
        '${repository.workingDirectory.path}${Platform.pathSeparator}added.txt',
      ).readAsString(),
      'added version\n',
    );
    expect(
      (await repository.runGit(['rev-parse', 'HEAD'])).stdout.toString().trim(),
      head,
    );
  });

  test('marks historical file restore uncertain when refresh fails', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('tracked.txt', 'historical\n');
    final historical = await repository.commit('Historical version');
    await repository.writeFile('tracked.txt', 'current\n');
    await repository.commit('Current version');

    var failNextRefresh = false;
    final container = ProviderContainer(
      overrides: [
        repositoryRefreshHookForTestingProvider.overrideWithValue(() async {
          if (failNextRefresh) {
            failNextRefresh = false;
            throw StateError('injected historical restore refresh failure');
          }
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    await controller.selectCommit(historical);
    failNextRefresh = true;

    expect(
      await controller.resetSelectedCommitFileToCommit(
        objectId: historical,
        path: 'tracked.txt',
      ),
      isFalse,
    );
    final operation = container
        .read(repositorySessionProvider)
        .operations
        .firstWhere((entry) => entry.kind == RepositoryOperationKind.file);
    expect(operation.outcome, RepositoryOperationOutcome.uncertain);
    expect(
      await File(
        '${repository.workingDirectory.path}${Platform.pathSeparator}tracked.txt',
      ).readAsString(),
      'historical\n',
    );
  });

  test(
    'restoring a path from its deleting commit removes the current path',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('removed.txt', 'old\n');
      await repository.commit('Add path');
      await File(
        '${repository.workingDirectory.path}${Platform.pathSeparator}removed.txt',
      ).delete();
      final deleted = await repository.commit('Delete path');
      await repository.writeFile('removed.txt', 'current\n');
      await repository.commit('Restore path later');

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);
      await controller.selectCommit(deleted);

      expect(
        await controller.resetSelectedCommitFileToCommit(
          objectId: deleted,
          path: 'removed.txt',
        ),
        isTrue,
      );
      expect(
        await File(
          '${repository.workingDirectory.path}${Platform.pathSeparator}removed.txt',
        ).exists(),
        isFalse,
      );
      final status = container.read(repositorySessionProvider).status!;
      expect(status.entries.single.indexStatus, GitChangeType.deleted);
    },
  );

  test('rejects a stale historical file confirmation', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('first.txt', 'first\n');
    final first = await repository.commit('First');
    await repository.writeFile('second.txt', 'second\n');
    final second = await repository.commit('Second');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    await controller.selectCommit(first);
    await controller.selectCommit(second);

    expect(
      await controller.resetSelectedCommitFileToCommit(
        objectId: first,
        path: 'first.txt',
      ),
      isFalse,
    );
    expect(container.read(repositorySessionProvider).status!.isClean, isTrue);
  });

  test('rejects historical file restore when a Git operation starts', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('conflict.txt', 'base\n');
    await repository.commit('Base');
    await repository.runGit(['switch', '-c', 'feature']);
    await repository.writeFile('conflict.txt', 'feature\n');
    await repository.commit('Feature');
    await repository.runGit(['switch', 'main']);
    await repository.writeFile('conflict.txt', 'main\n');
    final mainCommit = await repository.commit('Main');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    await controller.selectCommit(mainCommit);

    final merge = await repository.runGit([
      'merge',
      'feature',
    ], throwOnError: false);
    expect(merge.exitCode, isNot(0));
    expect(
      await controller.resetSelectedCommitFileToCommit(
        objectId: mainCommit,
        path: 'conflict.txt',
      ),
      isFalse,
    );
    final state = container.read(repositorySessionProvider);
    expect(state.operationState, GitRepositoryOperationState.merge);
    expect(state.status!.entries.single.isConflicted, isTrue);
  });

  test('mixed-resets the current branch to a loaded commit', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('tracked.txt', 'first\n');
    final firstCommit = await repository.commit('First');
    await repository.writeFile('tracked.txt', 'second\n');
    await repository.commit('Second');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);

    expect(
      await controller.resetCurrentBranchToCommit(
        firstCommit,
        mode: GitResetMode.mixed,
      ),
      isTrue,
    );
    expect(
      (await repository.runGit(['rev-parse', 'HEAD'])).stdout.toString().trim(),
      firstCommit,
    );
    expect(
      await File(
        '${repository.workingDirectory.path}${Platform.pathSeparator}tracked.txt',
      ).readAsString(),
      'second\n',
    );
    expect(container.read(repositorySessionProvider).status!.isClean, isFalse);
  });

  test('refuses branch reset while HEAD is detached', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('tracked.txt', 'first\n');
    final firstCommit = await repository.commit('First');
    await repository.writeFile('tracked.txt', 'second\n');
    final secondCommit = await repository.commit('Second');
    await repository.runGit(['switch', '--detach', secondCommit]);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);

    expect(
      await controller.resetCurrentBranchToCommit(
        firstCommit,
        mode: GitResetMode.hard,
      ),
      isFalse,
    );
    expect(
      (await repository.runGit(['rev-parse', 'HEAD'])).stdout.toString().trim(),
      secondCommit,
    );
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
    'reloads a selected Diff with whitespace filtering and hides hunk writes',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('spacing.dart', 'final value = 1;\n');
      await repository.commit('Base');
      await repository.writeFile('spacing.dart', 'final   value   =   1;\n');

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);
      controller.selectUncommittedChanges();
      var overview = mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!;
      await controller.selectChange(overview.changes.single);

      overview = mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!;
      expect(overview.diff.hunkActions, isNotEmpty);
      expect(overview.diff.whitespaceMode, DiffWhitespaceMode.preserve);

      await controller.setDiffWhitespaceMode(GitDiffWhitespaceMode.ignoreAll);
      final filteredState = container.read(repositorySessionProvider);
      overview = mapRepositoryOverview(filteredState).repository!;
      expect(
        filteredState.diff?.whitespaceMode,
        GitDiffWhitespaceMode.ignoreAll,
      );
      expect(overview.diff.whitespaceMode, DiffWhitespaceMode.ignoreAll);
      expect(overview.diff.hunkActions, isEmpty);
      expect(
        overview.diff.lines.where(
          (line) => line.kind == DiffLineKind.hunkHeader,
        ),
        isEmpty,
      );
    },
  );

  test('marks staged diff hunk uncertain when refresh fails', () async {
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
    var failNextRefresh = false;
    final container = ProviderContainer(
      overrides: [
        repositoryRefreshHookForTestingProvider.overrideWithValue(() async {
          if (failNextRefresh) {
            failNextRefresh = false;
            throw StateError('injected stage hunk refresh failure');
          }
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    controller.selectUncommittedChanges();
    final change = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!.changes.single;
    await controller.selectChange(change);
    failNextRefresh = true;

    expect(await controller.stageSelectedDiffHunk(0), isFalse);
    final state = container.read(repositorySessionProvider);
    final operation = state.operations.firstWhere(
      (entry) => entry.kind == RepositoryOperationKind.file,
    );
    expect(operation.outcome, RepositoryOperationOutcome.uncertain);
    expect(state.message, contains('写入已完成'));
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

  test('marks discarded diff hunk uncertain when refresh fails', () async {
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
    var failNextRefresh = false;
    final container = ProviderContainer(
      overrides: [
        repositoryRefreshHookForTestingProvider.overrideWithValue(() async {
          if (failNextRefresh) {
            failNextRefresh = false;
            throw StateError('injected discard hunk refresh failure');
          }
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    controller.selectUncommittedChanges();
    final change = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!.changes.single;
    await controller.selectChange(change);
    failNextRefresh = true;

    expect(await controller.revertSelectedDiffHunk(0), isFalse);
    final state = container.read(repositorySessionProvider);
    final operation = state.operations.firstWhere(
      (entry) => entry.kind == RepositoryOperationKind.file,
    );
    expect(operation.outcome, RepositoryOperationOutcome.uncertain);
    expect(state.message, contains('写入已完成'));
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

  test('marks committed diff hunk revert uncertain when refresh fails', () async {
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
    var failNextRefresh = false;
    final container = ProviderContainer(
      overrides: [
        repositoryRefreshHookForTestingProvider.overrideWithValue(() async {
          if (failNextRefresh) {
            failNextRefresh = false;
            throw StateError('injected committed hunk refresh failure');
          }
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    failNextRefresh = true;

    expect(await controller.revertSelectedCommitDiffHunk(0), isFalse);
    final state = container.read(repositorySessionProvider);
    final operation = state.operations.firstWhere(
      (entry) => entry.kind == RepositoryOperationKind.file,
    );
    expect(operation.outcome, RepositoryOperationOutcome.uncertain);
    expect(state.message, contains('写入已完成'));
    expect(state.selectedCommitId, changed);
  });

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
    'refuses reset when an unstaged selection was staged after confirmation',
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
      final overview = mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!;
      final previouslyUnstaged = overview.changes.single;
      controller.selectUncommittedChanges();

      await repository.runGit(['add', '--', 'config/local.json']);

      expect(
        await controller.resetChangesToHead([previouslyUnstaged]),
        isFalse,
      );
      expect(
        await File(
          '${repository.workingDirectory.path}${Platform.pathSeparator}config'
          '${Platform.pathSeparator}local.json',
        ).readAsString(),
        '{"version": 2}\n',
      );
      expect(
        container
            .read(repositorySessionProvider)
            .status!
            .entries
            .single
            .hasStagedChange,
        isTrue,
      );
    },
  );

  test(
    'refuses reset when an unstaged modification became a deletion',
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
      final overview = mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!;
      final previouslyModified = overview.changes.single;
      controller.selectUncommittedChanges();
      final file = File(
        '${repository.workingDirectory.path}${Platform.pathSeparator}config'
        '${Platform.pathSeparator}local.json',
      );

      await file.delete();

      expect(
        await controller.resetChangesToHead([previouslyModified]),
        isFalse,
      );
      expect(await file.exists(), isFalse);
      expect(
        container
            .read(repositorySessionProvider)
            .status!
            .entries
            .single
            .workTreeStatus,
        GitChangeType.deleted,
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

  test('toggles and restores a favorite repository', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    final store = _MemoryRepositorySessionStore();
    final container = ProviderContainer(
      overrides: [repositorySessionStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositoryLibraryProvider.notifier);

    await controller.add(repository.workingDirectory.path);
    final path = container
        .read(repositoryLibraryProvider)
        .repositories
        .single
        .path;
    controller.toggleFavorite(path);
    expect(
      container.read(repositoryLibraryProvider).repositories.single.isFavorite,
      isTrue,
    );
    await controller.flushPendingWrites();
    expect(store.snapshot.favoriteRepositoryPaths, [path]);

    final restoredContainer = ProviderContainer(
      overrides: [repositorySessionStoreProvider.overrideWithValue(store)],
    );
    addTearDown(restoredContainer.dispose);
    await restoredContainer.read(repositoryLibraryProvider.notifier).restore();
    expect(
      restoredContainer
          .read(repositoryLibraryProvider)
          .repositories
          .single
          .isFavorite,
      isTrue,
    );
  });

  test(
    'creates, assigns, renames, deletes, and restores workspace groups',
    () async {
      final firstRepository = await GitTestRepository.create();
      addTearDown(firstRepository.dispose);
      final secondRepository = await GitTestRepository.create();
      addTearDown(secondRepository.dispose);
      final store = _MemoryRepositorySessionStore();
      final container = ProviderContainer(
        overrides: [repositorySessionStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);
      final controller = container.read(repositoryLibraryProvider.notifier);
      await controller.restore();
      await controller.add(firstRepository.workingDirectory.path);
      await controller.add(secondRepository.workingDirectory.path);

      expect(controller.createWorkspaceGroup('Clients'), isTrue);
      expect(controller.createWorkspaceGroup('Clients'), isFalse);
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
      expect(
        controller.assignRepositoryToWorkspaceGroup(firstPath, 'Clients'),
        isTrue,
      );
      expect(
        container
            .read(repositoryLibraryProvider)
            .repositories
            .firstWhere((tab) => tab.path == firstPath)
            .workspaceGroup,
        'Clients',
      );
      expect(controller.renameWorkspaceGroup('Clients', 'Customer'), isTrue);
      expect(
        container
            .read(repositoryLibraryProvider)
            .repositories
            .firstWhere((tab) => tab.path == firstPath)
            .workspaceGroup,
        'Customer',
      );
      await controller.flushPendingWrites();

      final restoredContainer = ProviderContainer(
        overrides: [repositorySessionStoreProvider.overrideWithValue(store)],
      );
      addTearDown(restoredContainer.dispose);
      await restoredContainer
          .read(repositoryLibraryProvider.notifier)
          .restore();
      final restored = restoredContainer.read(repositoryLibraryProvider);
      expect(restored.workspaceGroups, ['Customer']);
      expect(
        restored.repositories
            .firstWhere((tab) => tab.path == firstPath)
            .workspaceGroup,
        'Customer',
      );

      final restoredController = restoredContainer.read(
        repositoryLibraryProvider.notifier,
      );
      expect(
        restoredController.assignRepositoryToWorkspaceGroup(
          secondPath,
          'Customer',
        ),
        isTrue,
      );
      expect(restoredController.deleteWorkspaceGroup('Customer'), isTrue);
      expect(
        restoredContainer
            .read(repositoryLibraryProvider)
            .repositories
            .every((tab) => tab.workspaceGroup == null),
        isTrue,
      );
    },
  );

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
      expect(state.operations.single.kind, RepositoryOperationKind.commit);
      expect(
        state.operations.single.outcome,
        RepositoryOperationOutcome.succeeded,
      );
    },
  );

  test('commit all excludes a purely untracked file', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('tracked.txt', 'base\n');
    await repository.commit('Initial commit');
    await repository.writeFile('tracked.txt', 'changed\n');
    await repository.writeFile('untracked.txt', 'excluded\n');
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);

    expect(
      await controller.createCommitFromAllTracked('Commit tracked changes'),
      isTrue,
    );

    expect(
      (await repository.runGit(['show', 'HEAD:tracked.txt'])).stdout,
      'changed\n',
    );
    final state = container.read(repositorySessionProvider);
    expect(state.status!.entries.single.path.display, 'untracked.txt');
  });

  test(
    'commit all revalidates that its previewed scope still exists',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('tracked.txt', 'base\n');
      final originalHead = await repository.commit('Initial commit');
      await repository.writeFile('tracked.txt', 'previewed change\n');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);
      await repository.runGit(['restore', '--', 'tracked.txt']);

      expect(
        await controller.createCommitFromAllTracked('Stale commit all'),
        isFalse,
      );

      expect(
        (await repository.runGit([
          'rev-parse',
          'HEAD',
        ])).stdout.toString().trim(),
        originalHead,
      );
      expect(
        container.read(repositorySessionProvider).phase,
        RepositorySessionPhase.ready,
      );
    },
  );

  test('commit selection excludes an unrelated staged file', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('selected.txt', 'base\n');
    await repository.writeFile('other.txt', 'base\n');
    await repository.commit('Initial commit');
    await repository.writeFile('selected.txt', 'selected change\n');
    await repository.writeFile('other.txt', 'other change\n');
    await repository.runGit(['add', '--', 'other.txt']);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    final selected =
        mapRepositoryOverview(container.read(repositorySessionProvider))
            .repository!
            .changes
            .singleWhere((change) => change.path == 'selected.txt');

    expect(
      await controller.createCommitFromSelection('Commit selection', [
        selected,
      ]),
      isTrue,
    );

    expect(
      (await repository.runGit(['show', 'HEAD:selected.txt'])).stdout,
      'selected change\n',
    );
    expect(
      (await repository.runGit(['show', 'HEAD:other.txt'])).stdout,
      'base\n',
    );
    final state = container.read(repositorySessionProvider);
    expect(state.status!.stagedEntries.single.path.display, 'other.txt');
  });

  test('commit selection includes both sides of a staged rename', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('old-name.txt', 'content\n');
    await repository.commit('Initial commit');
    await repository.runGit(['mv', '--', 'old-name.txt', 'new-name.txt']);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    final selected = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!.changes.single;

    expect(
      await controller.createCommitFromSelection('Commit rename', [selected]),
      isTrue,
    );

    expect(
      (await repository.runGit(['show', 'HEAD:new-name.txt'])).stdout,
      'content\n',
    );
    expect(
      (await repository.runGit([
        'cat-file',
        '-e',
        'HEAD:old-name.txt',
      ], throwOnError: false)).exitCode,
      isNot(0),
    );
    expect(container.read(repositorySessionProvider).status!.entries, isEmpty);
  });

  test(
    'failed selected new-file commit refreshes intent-to-add state',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('tracked.txt', 'base\n');
      final originalHead = await repository.commit('Initial commit');
      await repository.writeFile('new.txt', 'new content\n');
      final hook = File(
        '${repository.workingDirectory.path}/.git/hooks/pre-commit',
      );
      await hook.writeAsString('#!/bin/sh\nexit 1\n', flush: true);
      final chmod = await Process.run('/bin/chmod', ['0755', hook.path]);
      expect(chmod.exitCode, 0, reason: chmod.stderr.toString());
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);
      final selected = mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!.changes.single;

      expect(
        await controller.createCommitFromSelection('Rejected by hook', [
          selected,
        ]),
        isFalse,
      );

      expect(
        (await repository.runGit([
          'rev-parse',
          'HEAD',
        ])).stdout.toString().trim(),
        originalHead,
      );
      final state = container.read(repositorySessionProvider);
      expect(state.phase, RepositorySessionPhase.error);
      expect(state.status!.entries.single.path.display, 'new.txt');
      expect(state.status!.entries.single.hasWorkTreeChange, isTrue);
    },
  );

  test('commit selection rejects a file changed after its preview', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('selected.txt', 'base\n');
    final originalHead = await repository.commit('Initial commit');
    await repository.writeFile('selected.txt', 'previewed change\n');
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    final selected = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!.changes.single;
    await repository.runGit(['restore', '--', 'selected.txt']);

    expect(
      await controller.createCommitFromSelection('Stale selection', [selected]),
      isFalse,
    );
    expect(
      (await repository.runGit(['rev-parse', 'HEAD'])).stdout.toString().trim(),
      originalHead,
    );
    expect(
      container.read(repositorySessionProvider).phase,
      RepositorySessionPhase.ready,
    );
  });

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

  test(
    'starts Git-flow feature by creating and checking out a local branch',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('README.md', '# Git Desktop\n');
      await repository.commit('Initial commit');

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);

      final result = validateGitFlowStart(
        kind: GitFlowBranchKind.feature,
        name: 'billing/invoice',
        baseBranch: 'main',
        existingBranches: container
            .read(repositorySessionProvider)
            .localBranches
            .map((branch) => branch.name),
        isAttachedHead: true,
        isWorkingTreeClean: true,
        hasActiveOperation: false,
      );
      final plan = result.plan;
      expect(result.error, isNull);
      expect(plan, isNotNull);

      final execution = await controller.startGitFlowBranch(plan!);
      expect(execution?.succeeded, isTrue);
      expect(
        (await repository.runGit([
          'branch',
          '--show-current',
        ])).stdout.toString().trim(),
        'feature/billing/invoice',
      );
      expect(
        container.read(repositorySessionProvider).operations.first.outcome,
        RepositoryOperationOutcome.succeeded,
      );
      expect(
        container.read(repositorySessionProvider).operations.first.kind,
        RepositoryOperationKind.ref,
      );
    },
  );

  test('refuses Git-flow Start for dirty or detached workspaces', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', '# Git Desktop\n');
    await repository.commit('Initial commit');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    await repository.writeFile('README.md', 'dirty\n');
    await controller.refresh();

    final dirtyPlan = GitFlowStartPlan(
      kind: GitFlowBranchKind.feature,
      name: 'dirty',
      branchName: 'feature/dirty',
      baseBranch: 'main',
      version: null,
    );
    final dirtyResult = await controller.startGitFlowBranch(dirtyPlan);
    expect(dirtyResult?.succeeded, isFalse);
    expect(dirtyResult?.message, contains('干净的工作区'));
    expect(
      (await repository.runGit([
        'branch',
        '--show-current',
      ])).stdout.toString().trim(),
      'main',
    );

    await repository.runGit(['restore', '--', 'README.md']);
    await repository.runGit(['switch', '--detach', 'HEAD']);
    await controller.refresh();
    final detachedResult = await controller.startGitFlowBranch(dirtyPlan);
    expect(detachedResult?.succeeded, isFalse);
    expect(detachedResult?.message, contains('附着'));
    expect(
      (await repository.runGit([
        'branch',
        '--show-current',
      ])).stdout.toString().trim(),
      isEmpty,
    );
  });

  test(
    'finishes a Git-flow feature into an explicit target without cleanup',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('README.md', 'base\n');
      await repository.commit('base');
      await repository.runGit(['switch', '-c', 'feature/invoice']);
      await repository.writeFile('invoice.txt', 'feature\n');
      await repository.commit('feature change');
      await repository.runGit(['switch', 'main']);
      await repository.writeFile('main.txt', 'main\n');
      await repository.commit('main change');
      await repository.runGit(['switch', 'feature/invoice']);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);
      final state = container.read(repositorySessionProvider);
      final validation = validateGitFlowFinish(
        sourceBranch: 'feature/invoice',
        targetBranch: 'main',
        existingBranches: state.localBranches.map((branch) => branch.name),
        isAttachedHead: true,
        isWorkingTreeClean: true,
        hasActiveOperation: false,
      );
      expect(validation.error, isNull);

      final execution = await controller.finishGitFlowBranch(validation.plan!);
      expect(execution?.merged, isTrue);
      expect(
        (await repository.runGit([
          'branch',
          '--show-current',
        ])).stdout.toString().trim(),
        'main',
      );
      expect(
        (await repository.runGit([
          'show-ref',
          '--verify',
          '--quiet',
          'refs/heads/feature/invoice',
        ], throwOnError: false)).exitCode,
        0,
      );
      expect(
        (await repository.runGit([
          'log',
          '-1',
          '--format=%s',
        ])).stdout.toString().trim(),
        'Merge branch \'refs/heads/feature/invoice\'',
      );
      expect(
        container.read(repositorySessionProvider).operations.first.outcome,
        RepositoryOperationOutcome.succeeded,
      );
      expect(
        container.read(repositorySessionProvider).operations.first.kind,
        RepositoryOperationKind.ref,
      );
    },
  );

  test('finishes valid release and hotfix branches into main', () async {
    for (final source in const ['release/1.2.3', 'hotfix/2.0.0']) {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('README.md', 'base\n');
      await repository.commit('base');
      await repository.runGit(['switch', '-c', source]);
      await repository.writeFile('CHANGELOG.md', '$source\n');
      await repository.commit(source);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);
      final plan = validateGitFlowFinish(
        sourceBranch: source,
        targetBranch: 'main',
        existingBranches: container
            .read(repositorySessionProvider)
            .localBranches
            .map((branch) => branch.name),
        isAttachedHead: true,
        isWorkingTreeClean: true,
        hasActiveOperation: false,
      ).plan!;
      final result = await controller.finishGitFlowBranch(plan);
      expect(result?.merged, isTrue, reason: source);
      expect(
        (await repository.runGit([
          'branch',
          '--show-current',
        ])).stdout.toString().trim(),
        'main',
      );
    }
  });

  test('rejects a stale Git-flow Finish preview before any write', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    await repository.commit('base');
    await repository.runGit(['switch', '-c', 'feature/stale']);
    await repository.writeFile('feature.txt', 'feature\n');
    await repository.commit('feature');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    final plan = validateGitFlowFinish(
      sourceBranch: 'feature/stale',
      targetBranch: 'main',
      existingBranches: container
          .read(repositorySessionProvider)
          .localBranches
          .map((branch) => branch.name),
      isAttachedHead: true,
      isWorkingTreeClean: true,
      hasActiveOperation: false,
    ).plan!;

    await repository.runGit(['switch', 'main']);
    await controller.refresh();
    final result = await controller.finishGitFlowBranch(plan);

    expect(result?.merged, isFalse);
    expect(result?.message, contains('当前分支已从 feature/stale 变为 main'));
    expect(
      (await repository.runGit([
        'branch',
        '--show-current',
      ])).stdout.toString().trim(),
      'main',
    );
    expect(
      (await repository.runGit([
        'log',
        '-1',
        '--format=%s',
      ])).stdout.toString().trim(),
      'base',
    );
  });

  test(
    'marks Git-flow Finish uncertain when the post-merge refresh fails',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('README.md', 'base\n');
      await repository.commit('base');
      await repository.runGit(['switch', '-c', 'feature/refresh-failure']);
      await repository.writeFile('feature.txt', 'feature\n');
      await repository.commit('feature');
      await repository.runGit(['switch', 'main']);
      await repository.runGit(['switch', 'feature/refresh-failure']);

      var refreshCalls = 0;
      final container = ProviderContainer(
        overrides: [
          repositoryRefreshHookForTestingProvider.overrideWithValue(() async {
            refreshCalls++;
            if (refreshCalls == 2) {
              throw StateError('injected Git-flow Finish refresh failure');
            }
          }),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);
      final plan = validateGitFlowFinish(
        sourceBranch: 'feature/refresh-failure',
        targetBranch: 'main',
        existingBranches: container
            .read(repositorySessionProvider)
            .localBranches
            .map((branch) => branch.name),
        isAttachedHead: true,
        isWorkingTreeClean: true,
        hasActiveOperation: false,
      ).plan!;

      final result = await controller.finishGitFlowBranch(plan);
      expect(result?.merged, isFalse);
      final state = container.read(repositorySessionProvider);
      expect(state.message, contains('写入已完成'));
      expect(
        state.operations.first.outcome,
        RepositoryOperationOutcome.uncertain,
      );
      expect(
        (await repository.runGit([
          'branch',
          '--show-current',
        ])).stdout.toString().trim(),
        'main',
      );
    },
  );

  test('keeps Git conflict state when Git-flow Finish cannot merge', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    await repository.commit('base');
    await repository.runGit(['switch', '-c', 'feature/conflict']);
    await repository.writeFile('README.md', 'feature\n');
    await repository.commit('feature conflict');
    await repository.runGit(['switch', 'main']);
    await repository.writeFile('README.md', 'main\n');
    await repository.commit('main conflict');
    await repository.runGit(['switch', 'feature/conflict']);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    final plan = validateGitFlowFinish(
      sourceBranch: 'feature/conflict',
      targetBranch: 'main',
      existingBranches: container
          .read(repositorySessionProvider)
          .localBranches
          .map((branch) => branch.name),
      isAttachedHead: true,
      isWorkingTreeClean: true,
      hasActiveOperation: false,
    ).plan!;

    final result = await controller.finishGitFlowBranch(plan);
    expect(result?.merged, isFalse);
    expect(result?.message, contains('冲突'));
    expect(
      (await repository.runGit([
        'branch',
        '--show-current',
      ])).stdout.toString().trim(),
      'main',
    );
    final status = await repository.runGit(['status', '--porcelain=v1']);
    expect(status.stdout.toString(), contains('UU README.md'));
  });

  test(
    'finishes Git-flow sources, tags release, and safely deletes sources',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('README.md', 'base\n');
      await repository.commit('base');
      await repository.runGit(['switch', '-c', 'feature/one']);
      await repository.writeFile('one.txt', 'one\n');
      await repository.commit('one');
      await repository.runGit(['switch', 'main']);
      await repository.runGit(['switch', '-c', 'release/1.2.3']);
      await repository.writeFile('release.txt', 'release\n');
      await repository.commit('release');
      await repository.runGit(['switch', 'main']);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);
      final state = container.read(repositorySessionProvider);
      final validation = validateGitFlowBatchFinish(
        sourceBranches: const ['feature/one', 'release/1.2.3'],
        targetBranch: 'main',
        existingBranches: state.localBranches.map((branch) => branch.name),
        isAttachedHead: state.status?.branch.isDetached == false,
        isWorkingTreeClean: state.status?.isClean == true,
        hasActiveOperation:
            state.operationState != GitRepositoryOperationState.none,
        deleteSourceBranches: true,
        releaseTag: 'v1.2.3',
      );
      expect(validation.error, isNull);
      final result = await controller.finishGitFlowBatch(validation.plan!);
      expect(result?.succeeded, isTrue);
      expect(result?.tagCreated, isTrue);
      expect(result?.items.every((item) => item.deleted), isTrue);
      final branches = await repository.runGit([
        'branch',
        '--format=%(refname:short)',
      ]);
      expect(branches.stdout.toString(), isNot(contains('feature/one')));
      expect(branches.stdout.toString(), isNot(contains('release/1.2.3')));
      final tag = await repository.runGit(['show-ref', '--tags', 'v1.2.3']);
      expect(tag.exitCode, 0);
    },
  );

  test('writes back a successful external Merge result safely', () async {
    if (Platform.isWindows) return;
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    await repository.commit('base');
    await repository.runGit(['switch', '-c', 'feature/external-merge']);
    await repository.writeFile('README.md', 'ours\n');
    await repository.commit('ours');
    await repository.runGit(['switch', 'main']);
    await repository.writeFile('README.md', 'theirs\n');
    await repository.commit('theirs');
    try {
      await repository.runGit([
        'merge',
        '--no-edit',
        '--no-ff',
        'feature/external-merge',
      ]);
      fail('Expected the merge to conflict.');
    } on Object {
      // The conflicted index is the fixture for the external Merge path.
    }

    final executable = File('${repository.rootDirectory.path}/merge.sh');
    await executable.writeAsString(r'''#!/bin/sh
cat "$4" > "$8"
''');
    final chmod = await Process.run('chmod', ['+x', executable.path]);
    expect(chmod.exitCode, 0);
    final mergeConfiguration = ExternalToolConfiguration(
      displayName: 'Test Merge',
      executablePath: executable.path,
      kind: ExternalToolKind.mergeWriteBack,
      arguments: const [
        '--base',
        '{base}',
        '--ours',
        '{ours}',
        '--theirs',
        '{theirs}',
        '--result',
        '{result}',
      ],
      enabled: true,
    );
    final container = ProviderContainer(
      overrides: [
        externalToolConfigurationStoreProvider.overrideWithValue(
          _FixedExternalToolConfigurationStore(mergeConfiguration),
        ),
        repositoryTrustStoreProvider.overrideWithValue(
          _FixedRepositoryTrustStore(),
        ),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    final session = container.read(repositorySessionProvider);
    final gitRepository = session.repository!;
    await container
        .read(repositoryTrustProvider.notifier)
        .loadRepository(
          RepositoryTrustId(
            commonDirectory: gitRepository.commonDirectory,
            workTreeRoot: gitRepository.workTreeRoot,
          ),
        );
    await container
        .read(repositoryTrustProvider.notifier)
        .setStatus(RepositoryTrustStatus.trusted);
    await container.read(externalToolConfigurationProvider.notifier).load();
    final change = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!.changes.single;
    expect(change.kind, RepositoryChangeKind.conflicted);

    expect(await controller.resolveConflictWithExternalMerge(change), isTrue);
    expect(
      await File(
        '${repository.workingDirectory.path}/README.md',
      ).readAsString(),
      'theirs\n',
    );
    final status = await repository.runGit(['status', '--porcelain=v1']);
    expect(status.stdout.toString(), isNot(contains('UU README.md')));
  });

  test(
    'cancels Git-flow Finish during the merge and does not delete source',
    () async {
      if (Platform.isWindows) return;
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('README.md', 'base\n');
      await repository.commit('base');
      await repository.runGit(['switch', '-c', 'feature/delayed']);
      await repository.writeFile('feature.txt', 'feature\n');
      await repository.commit('feature');
      await repository.runGit(['switch', 'main']);

      final marker = File('${repository.rootDirectory.path}/merge-started');
      final hook = File(
        '${repository.workingDirectory.path}/.git/hooks/pre-merge-commit',
      );
      await hook.writeAsString('''#!/bin/sh
printf started > "${marker.path}"
sleep 10
exit 0
''');
      final chmod = await Process.run('chmod', ['+x', hook.path]);
      expect(chmod.exitCode, 0);
      await repository.runGit(['switch', 'feature/delayed']);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);
      final plan = validateGitFlowFinish(
        sourceBranch: 'feature/delayed',
        targetBranch: 'main',
        existingBranches: container
            .read(repositorySessionProvider)
            .localBranches
            .map((branch) => branch.name),
        isAttachedHead: true,
        isWorkingTreeClean: true,
        hasActiveOperation: false,
      ).plan!;
      final task = controller.finishGitFlowBranch(plan);
      for (
        var attempt = 0;
        attempt < 200 && !await marker.exists();
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(await marker.exists(), isTrue);
      controller.cancelGitFlowFinish();
      final result = await task;
      expect(result?.merged, isFalse);
      expect(
        (await repository.runGit([
          'show-ref',
          '--verify',
          '--quiet',
          'refs/heads/feature/delayed',
        ], throwOnError: false)).exitCode,
        0,
      );
      expect(
        (await repository.runGit([
          'branch',
          '--show-current',
        ])).stdout.toString().trim(),
        'main',
      );
    },
  );

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
    expect(state.operations, hasLength(1));
    expect(
      state.operations.single.outcome,
      RepositoryOperationOutcome.partiallySucceeded,
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
    expect(state.operations.first.kind, RepositoryOperationKind.ref);
    expect(
      state.operations.first.outcome,
      RepositoryOperationOutcome.succeeded,
    );
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
      final remoteOperation = state.operations.firstWhere(
        (operation) => operation.kind == RepositoryOperationKind.remote,
      );
      expect(remoteOperation.outcome, RepositoryOperationOutcome.succeeded);
    },
  );

  test('adds a remote and refreshes the navigation state', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', '# Git Desktop\n');
    await repository.commit('Initial commit');
    final remoteDirectory = await Directory.systemTemp.createTemp(
      'git-desktop-add-remote-target-',
    );
    addTearDown(() => remoteDirectory.delete(recursive: true));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);

    expect(
      await controller.addRemote('upstream', remoteDirectory.path),
      isTrue,
    );

    final state = container.read(repositorySessionProvider);
    expect(state.phase, RepositorySessionPhase.ready);
    expect(state.remoteNames, contains('upstream'));
    final remoteOperation = state.operations.firstWhere(
      (operation) => operation.kind == RepositoryOperationKind.remote,
    );
    expect(remoteOperation.outcome, RepositoryOperationOutcome.succeeded);
    expect(await controller.readRemoteUrl('upstream'), remoteDirectory.path);
    expect(
      await controller.addRemote('upstream', remoteDirectory.path),
      isFalse,
    );
  });

  test('marks a completed ref write uncertain when refresh fails', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', '# Git Desktop\n');
    await repository.commit('Initial commit');

    var failNextRefresh = true;
    final container = ProviderContainer(
      overrides: [
        repositoryRefreshHookForTestingProvider.overrideWithValue(() async {
          if (failNextRefresh) {
            failNextRefresh = false;
            throw StateError('injected refresh failure');
          }
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);

    expect(
      await controller.createLocalBranch('after-refresh-failure'),
      isFalse,
    );
    final state = container.read(repositorySessionProvider);
    final operation = state.operations.firstWhere(
      (entry) => entry.kind == RepositoryOperationKind.ref,
    );
    expect(operation.outcome, RepositoryOperationOutcome.uncertain);
    expect(state.message, contains('写入已完成'));
    final branches = await repository.runGit(['branch', '--list']);
    expect(branches.stdout.toString(), contains('after-refresh-failure'));
  });

  test('marks a completed merge uncertain when refresh fails', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    await repository.commit('Initial commit');
    await repository.runGit(['branch', 'feature/refresh-failure']);
    await repository.runGit(['switch', 'feature/refresh-failure']);
    await repository.writeFile('feature.txt', 'feature\n');
    await repository.commit('Feature commit');
    await repository.runGit(['switch', 'main']);

    var failNextRefresh = true;
    final container = ProviderContainer(
      overrides: [
        repositoryRefreshHookForTestingProvider.overrideWithValue(() async {
          if (failNextRefresh) {
            failNextRefresh = false;
            throw StateError('injected merge refresh failure');
          }
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);

    expect(
      await controller.mergeLocalBranch('feature/refresh-failure'),
      isFalse,
    );
    final state = container.read(repositorySessionProvider);
    final operation = state.operations.firstWhere(
      (entry) => entry.kind == RepositoryOperationKind.history,
    );
    expect(operation.outcome, RepositoryOperationOutcome.uncertain);
    expect(state.message, contains('写入已完成'));
    expect(
      await File('${repository.workingDirectory.path}/feature.txt').exists(),
      isTrue,
    );
  });

  test('marks a completed stash uncertain when refresh fails', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    await repository.commit('Initial commit');
    await repository.writeFile('README.md', 'changed\n');

    var failNextRefresh = true;
    final container = ProviderContainer(
      overrides: [
        repositoryRefreshHookForTestingProvider.overrideWithValue(() async {
          if (failNextRefresh) {
            failNextRefresh = false;
            throw StateError('injected stash refresh failure');
          }
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);

    expect(await controller.createStash('refresh failure'), isFalse);
    final state = container.read(repositorySessionProvider);
    final operation = state.operations.firstWhere(
      (entry) => entry.kind == RepositoryOperationKind.stash,
    );
    expect(operation.outcome, RepositoryOperationOutcome.uncertain);
    expect(state.message, contains('写入已完成'));
    expect(
      (await repository.runGit(['stash', 'list'])).stdout,
      contains('refresh failure'),
    );
  });

  test('marks a completed revert uncertain when refresh fails', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    await repository.commit('Initial commit');
    await repository.writeFile('README.md', 'changed\n');
    final changedCommit = await repository.commit('Change');

    var failNextRefresh = true;
    final container = ProviderContainer(
      overrides: [
        repositoryRefreshHookForTestingProvider.overrideWithValue(() async {
          if (failNextRefresh) {
            failNextRefresh = false;
            throw StateError('injected revert refresh failure');
          }
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);

    expect(await controller.revertCommit(changedCommit), isFalse);
    final state = container.read(repositorySessionProvider);
    final operation = state.operations.firstWhere(
      (entry) => entry.kind == RepositoryOperationKind.history,
    );
    expect(operation.outcome, RepositoryOperationOutcome.uncertain);
    expect(state.message, contains('写入已完成'));
    expect(
      (await repository.runGit(['log', '--format=%s', '-2'])).stdout,
      contains('Revert "Change"'),
    );
  });

  test('marks continued revert uncertain when refresh fails', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    await repository.commit('Initial commit');
    await repository.writeFile('README.md', 'feature\n');
    final targetCommit = await repository.commit('Feature change');
    await repository.writeFile('README.md', 'main\n');
    await repository.commit('Main change');

    var failNextRefresh = false;
    final container = ProviderContainer(
      overrides: [
        repositoryRefreshHookForTestingProvider.overrideWithValue(() async {
          if (failNextRefresh) {
            failNextRefresh = false;
            throw StateError('injected continue revert refresh failure');
          }
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    expect(await controller.revertCommit(targetCommit), isFalse);
    await repository.writeFile('README.md', 'resolved revert\n');
    await repository.runGit(['add', '--', 'README.md']);
    await controller.refresh();
    failNextRefresh = true;

    expect(await controller.continueRevert(), isFalse);
    final state = container.read(repositorySessionProvider);
    final operation = state.operations.firstWhere(
      (entry) => entry.kind == RepositoryOperationKind.history,
    );
    expect(operation.outcome, RepositoryOperationOutcome.uncertain);
    expect(state.message, contains('写入已完成'));
  });

  test('marks aborted revert uncertain when refresh fails', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    await repository.commit('Initial commit');
    await repository.writeFile('README.md', 'feature\n');
    final targetCommit = await repository.commit('Feature change');
    await repository.writeFile('README.md', 'main\n');
    await repository.commit('Main change');

    var failNextRefresh = false;
    final container = ProviderContainer(
      overrides: [
        repositoryRefreshHookForTestingProvider.overrideWithValue(() async {
          if (failNextRefresh) {
            failNextRefresh = false;
            throw StateError('injected abort revert refresh failure');
          }
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    expect(await controller.revertCommit(targetCommit), isFalse);
    failNextRefresh = true;

    expect(await controller.abortRevert(), isFalse);
    final state = container.read(repositorySessionProvider);
    final operation = state.operations.firstWhere(
      (entry) => entry.kind == RepositoryOperationKind.history,
    );
    expect(operation.outcome, RepositoryOperationOutcome.uncertain);
    expect(state.message, contains('写入已完成'));
  });

  test('marks a completed cherry-pick uncertain when refresh fails', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    await repository.commit('Initial commit');
    await repository.runGit(['switch', '-c', 'feature/cherry-refresh']);
    await repository.writeFile('cherry.txt', 'cherry\n');
    final sourceCommit = await repository.commit('Cherry source');
    await repository.runGit(['switch', 'main']);

    var failNextRefresh = true;
    final container = ProviderContainer(
      overrides: [
        repositoryRefreshHookForTestingProvider.overrideWithValue(() async {
          if (failNextRefresh) {
            failNextRefresh = false;
            throw StateError('injected cherry-pick refresh failure');
          }
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);

    expect(await controller.cherryPickCommit(sourceCommit), isFalse);
    final state = container.read(repositorySessionProvider);
    final operation = state.operations.firstWhere(
      (entry) => entry.kind == RepositoryOperationKind.history,
    );
    expect(operation.outcome, RepositoryOperationOutcome.uncertain);
    expect(state.message, contains('写入已完成'));
    expect(
      await File('${repository.workingDirectory.path}/cherry.txt').exists(),
      isTrue,
    );
  });

  test('marks continued cherry-pick uncertain when refresh fails', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    await repository.commit('Initial commit');
    await repository.runGit(['switch', '-c', 'feature/cherry-conflict']);
    await repository.writeFile('README.md', 'feature\n');
    final sourceCommit = await repository.commit('Feature change');
    await repository.runGit(['switch', 'main']);
    await repository.writeFile('README.md', 'main\n');
    await repository.commit('Main change');

    var failNextRefresh = false;
    final container = ProviderContainer(
      overrides: [
        repositoryRefreshHookForTestingProvider.overrideWithValue(() async {
          if (failNextRefresh) {
            failNextRefresh = false;
            throw StateError('injected continue cherry-pick refresh failure');
          }
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    expect(await controller.cherryPickCommit(sourceCommit), isFalse);
    await repository.writeFile('README.md', 'resolved cherry\n');
    await repository.runGit(['add', '--', 'README.md']);
    await controller.refresh();
    failNextRefresh = true;

    expect(await controller.continueCherryPick(), isFalse);
    final state = container.read(repositorySessionProvider);
    final operation = state.operations.firstWhere(
      (entry) => entry.kind == RepositoryOperationKind.history,
    );
    expect(operation.outcome, RepositoryOperationOutcome.uncertain);
    expect(state.message, contains('写入已完成'));
  });

  test('marks aborted cherry-pick uncertain when refresh fails', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    await repository.commit('Initial commit');
    await repository.runGit(['switch', '-c', 'feature/cherry-abort']);
    await repository.writeFile('README.md', 'feature\n');
    final sourceCommit = await repository.commit('Feature change');
    await repository.runGit(['switch', 'main']);
    await repository.writeFile('README.md', 'main\n');
    await repository.commit('Main change');

    var failNextRefresh = false;
    final container = ProviderContainer(
      overrides: [
        repositoryRefreshHookForTestingProvider.overrideWithValue(() async {
          if (failNextRefresh) {
            failNextRefresh = false;
            throw StateError('injected abort cherry-pick refresh failure');
          }
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    expect(await controller.cherryPickCommit(sourceCommit), isFalse);
    failNextRefresh = true;

    expect(await controller.abortCherryPick(), isFalse);
    final state = container.read(repositorySessionProvider);
    final operation = state.operations.firstWhere(
      (entry) => entry.kind == RepositoryOperationKind.history,
    );
    expect(operation.outcome, RepositoryOperationOutcome.uncertain);
    expect(state.message, contains('写入已完成'));
  });

  test('skips a paused cherry-pick and refreshes the session', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    await repository.commit('Initial commit');
    await repository.runGit(['switch', '-c', 'feature/cherry-skip']);
    await repository.writeFile('README.md', 'feature\n');
    final sourceCommit = await repository.commit('Feature change');
    await repository.runGit(['switch', 'main']);
    await repository.writeFile('README.md', 'main\n');
    await repository.commit('Main change');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    expect(await controller.cherryPickCommit(sourceCommit), isFalse);
    expect(
      container.read(repositorySessionProvider).operationState,
      GitRepositoryOperationState.cherryPick,
    );

    expect(await controller.skipCherryPick(), isTrue);
    final state = container.read(repositorySessionProvider);
    expect(state.phase, RepositorySessionPhase.ready);
    expect(state.operationState, GitRepositoryOperationState.none);
    expect(
      (await repository.runGit([
        'log',
        '-1',
        '--format=%s',
      ])).stdout.toString().trim(),
      'Main change',
    );
  });

  test('skips a paused revert and refreshes the session', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    await repository.commit('Initial commit');
    await repository.writeFile('README.md', 'target\n');
    final sourceCommit = await repository.commit('Revert source');
    await repository.writeFile('README.md', 'conflicting feature\n');
    await repository.commit('Conflicting feature');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    expect(await controller.revertCommit(sourceCommit), isFalse);
    expect(
      container.read(repositorySessionProvider).operationState,
      GitRepositoryOperationState.revert,
    );

    expect(await controller.skipRevert(), isTrue);
    final state = container.read(repositorySessionProvider);
    expect(state.phase, RepositorySessionPhase.ready);
    expect(state.operationState, GitRepositoryOperationState.none);
    expect(
      (await repository.runGit([
        'log',
        '-1',
        '--format=%s',
      ])).stdout.toString().trim(),
      'Conflicting feature',
    );
  });

  test('marks a completed file reset uncertain when refresh fails', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    await repository.commit('Initial commit');
    await repository.writeFile('README.md', 'changed\n');

    var failNextRefresh = true;
    final container = ProviderContainer(
      overrides: [
        repositoryRefreshHookForTestingProvider.overrideWithValue(() async {
          if (failNextRefresh) {
            failNextRefresh = false;
            throw StateError('injected file reset refresh failure');
          }
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    final change = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    ).repository!.changes.single;

    expect(await controller.resetChangesToHead([change]), isFalse);
    final state = container.read(repositorySessionProvider);
    final operation = state.operations.firstWhere(
      (entry) => entry.kind == RepositoryOperationKind.file,
    );
    expect(operation.outcome, RepositoryOperationOutcome.uncertain);
    expect(state.message, contains('写入已完成'));
    expect(
      await File(
        '${repository.workingDirectory.path}/README.md',
      ).readAsString(),
      'base\n',
    );
  });

  test(
    'marks a completed conflict resolution uncertain when refresh fails',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('README.md', 'base\n');
      await repository.commit('Initial commit');
      await repository.runGit(['branch', 'feature/conflict-refresh']);
      await repository.runGit(['switch', 'feature/conflict-refresh']);
      await repository.writeFile('README.md', 'feature\n');
      await repository.commit('Feature change');
      await repository.runGit(['switch', 'main']);
      await repository.writeFile('README.md', 'main\n');
      await repository.commit('Main change');

      var failNextRefresh = false;
      final container = ProviderContainer(
        overrides: [
          repositoryRefreshHookForTestingProvider.overrideWithValue(() async {
            if (failNextRefresh) {
              failNextRefresh = false;
              throw StateError('injected conflict refresh failure');
            }
          }),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);
      expect(
        await controller.mergeLocalBranch('feature/conflict-refresh'),
        isFalse,
      );
      final conflict =
          mapRepositoryOverview(
            container.read(repositorySessionProvider),
          ).repository!.changes.singleWhere(
            (change) => change.kind == RepositoryChangeKind.conflicted,
          );

      failNextRefresh = true;

      expect(
        await controller.resolveConflictWithContent(conflict, 'resolved\n'),
        isFalse,
      );
      final state = container.read(repositorySessionProvider);
      final operation = state.operations.firstWhere(
        (entry) => entry.kind == RepositoryOperationKind.file,
      );
      expect(operation.outcome, RepositoryOperationOutcome.uncertain);
      expect(state.message, contains('写入已完成'));
      expect(
        await File(
          '${repository.workingDirectory.path}/README.md',
        ).readAsString(),
        'resolved\n',
      );
    },
  );

  test('marks conflict side selection uncertain when refresh fails', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    await repository.commit('Initial commit');
    await repository.runGit(['branch', 'feature/side-refresh']);
    await repository.runGit(['switch', 'feature/side-refresh']);
    await repository.writeFile('README.md', 'feature\n');
    await repository.commit('Feature change');
    await repository.runGit(['switch', 'main']);
    await repository.writeFile('README.md', 'main\n');
    await repository.commit('Main change');

    var failNextRefresh = false;
    final container = ProviderContainer(
      overrides: [
        repositoryRefreshHookForTestingProvider.overrideWithValue(() async {
          if (failNextRefresh) {
            failNextRefresh = false;
            throw StateError('injected conflict side refresh failure');
          }
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    expect(await controller.mergeLocalBranch('feature/side-refresh'), isFalse);
    final conflict =
        mapRepositoryOverview(
          container.read(repositorySessionProvider),
        ).repository!.changes.singleWhere(
          (change) => change.kind == RepositoryChangeKind.conflicted,
        );
    failNextRefresh = true;

    expect(
      await controller.resolveConflict(
        conflict,
        RepositoryConflictAction.useOurs,
      ),
      isFalse,
    );
    final state = container.read(repositorySessionProvider);
    final operation = state.operations.firstWhere(
      (entry) => entry.kind == RepositoryOperationKind.file,
    );
    expect(operation.outcome, RepositoryOperationOutcome.uncertain);
    expect(state.message, contains('写入已完成'));
    expect(
      await File(
        '${repository.workingDirectory.path}/README.md',
      ).readAsString(),
      'main\n',
    );
  });

  test('marks a completed rebase uncertain when refresh fails', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    await repository.commit('Initial commit');
    await repository.runGit(['switch', '-c', 'onto']);
    await repository.writeFile('onto.txt', 'onto\n');
    final ontoCommit = await repository.commit('Onto commit');
    await repository.runGit(['switch', 'main']);
    await repository.writeFile('main.txt', 'main\n');
    await repository.commit('Main commit');

    var failNextRefresh = true;
    final container = ProviderContainer(
      overrides: [
        repositoryRefreshHookForTestingProvider.overrideWithValue(() async {
          if (failNextRefresh) {
            failNextRefresh = false;
            throw StateError('injected rebase refresh failure');
          }
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);

    expect(await controller.rebaseOntoCommit(ontoCommit), isFalse);
    final state = container.read(repositorySessionProvider);
    final operation = state.operations.firstWhere(
      (entry) => entry.kind == RepositoryOperationKind.history,
    );
    expect(operation.outcome, RepositoryOperationOutcome.uncertain);
    expect(state.message, contains('写入已完成'));
    expect(
      await File('${repository.workingDirectory.path}/onto.txt').exists(),
      isTrue,
    );
  });

  test('marks aborted rebase uncertain when refresh fails', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    await repository.commit('Initial commit');
    await repository.runGit(['switch', '-c', 'feature/rebase-abort']);
    await repository.writeFile('README.md', 'feature\n');
    await repository.commit('Feature change');
    await repository.runGit(['switch', 'main']);
    await repository.writeFile('README.md', 'main\n');
    final mainCommit = await repository.commit('Main change');
    await repository.runGit(['switch', 'feature/rebase-abort']);

    var failNextRefresh = false;
    final container = ProviderContainer(
      overrides: [
        repositoryRefreshHookForTestingProvider.overrideWithValue(() async {
          if (failNextRefresh) {
            failNextRefresh = false;
            throw StateError('injected abort rebase refresh failure');
          }
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    expect(await controller.rebaseOntoCommit(mainCommit), isFalse);
    failNextRefresh = true;

    expect(await controller.abortRebase(), isFalse);
    final state = container.read(repositorySessionProvider);
    final operation = state.operations.firstWhere(
      (entry) => entry.kind == RepositoryOperationKind.pull,
    );
    expect(operation.outcome, RepositoryOperationOutcome.uncertain);
    expect(state.message, contains('写入已完成'));
  });

  test('marks continued rebase uncertain when refresh fails', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    await repository.commit('Initial commit');
    await repository.runGit(['switch', '-c', 'feature/rebase-continue']);
    await repository.writeFile('README.md', 'feature\n');
    await repository.commit('Feature change');
    await repository.runGit(['switch', 'main']);
    await repository.writeFile('README.md', 'main\n');
    final mainCommit = await repository.commit('Main change');
    await repository.runGit(['switch', 'feature/rebase-continue']);

    var failNextRefresh = false;
    final container = ProviderContainer(
      overrides: [
        repositoryRefreshHookForTestingProvider.overrideWithValue(() async {
          if (failNextRefresh) {
            failNextRefresh = false;
            throw StateError('injected continue rebase refresh failure');
          }
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    expect(await controller.rebaseOntoCommit(mainCommit), isFalse);
    await repository.writeFile('README.md', 'resolved rebase\n');
    await repository.runGit(['add', '--', 'README.md']);
    await controller.refresh();
    failNextRefresh = true;

    expect(await controller.continueRebase(), isFalse);
    final state = container.read(repositorySessionProvider);
    final operation = state.operations.firstWhere(
      (entry) => entry.kind == RepositoryOperationKind.pull,
    );
    expect(operation.outcome, RepositoryOperationOutcome.uncertain);
    expect(state.message, contains('写入已完成'));
  });

  test('marks skipped rebase uncertain when refresh fails', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    await repository.commit('Initial commit');
    await repository.runGit(['switch', '-c', 'feature/rebase-skip-uncertain']);
    await repository.writeFile('README.md', 'feature\n');
    await repository.commit('Feature change');
    await repository.runGit(['switch', 'main']);
    await repository.writeFile('README.md', 'main\n');
    final mainCommit = await repository.commit('Main change');
    await repository.runGit(['switch', 'feature/rebase-skip-uncertain']);

    var failNextRefresh = false;
    final container = ProviderContainer(
      overrides: [
        repositoryRefreshHookForTestingProvider.overrideWithValue(() async {
          if (failNextRefresh) {
            failNextRefresh = false;
            throw StateError('injected skip rebase refresh failure');
          }
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    expect(await controller.rebaseOntoCommit(mainCommit), isFalse);
    failNextRefresh = true;

    expect(await controller.skipRebase(), isFalse);
    final state = container.read(repositorySessionProvider);
    final operation = state.operations.firstWhere(
      (entry) => entry.kind == RepositoryOperationKind.pull,
    );
    expect(operation.outcome, RepositoryOperationOutcome.uncertain);
    expect(state.message, contains('写入已完成'));
  });

  test(
    'skips the current commit in a paused rebase and refreshes the session',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('README.md', 'base\n');
      await repository.commit('Initial commit');
      await repository.runGit(['switch', '-c', 'feature/rebase-skip']);
      await repository.writeFile('README.md', 'feature\n');
      await repository.commit('Feature change');
      await repository.runGit(['switch', 'main']);
      await repository.writeFile('README.md', 'main\n');
      final mainCommit = await repository.commit('Main change');
      await repository.runGit(['switch', 'feature/rebase-skip']);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);

      expect(await controller.rebaseOntoCommit(mainCommit), isFalse);
      expect(
        container.read(repositorySessionProvider).operationState,
        GitRepositoryOperationState.rebase,
      );
      expect(await controller.skipRebase(), isTrue);
      final state = container.read(repositorySessionProvider);
      expect(state.operationState, GitRepositoryOperationState.none);
      expect(state.phase, RepositorySessionPhase.ready);
      expect(
        (await repository.runGit([
          'rev-parse',
          'HEAD',
        ])).stdout.toString().trim(),
        mainCommit,
      );
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
    expect(state.operations.single.kind, RepositoryOperationKind.ref);
    expect(
      state.operations.single.outcome,
      RepositoryOperationOutcome.succeeded,
    );
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

  test('verifies tag signatures and compares tags with a remote', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    final commit = await repository.commit('Initial commit');
    await repository.createBareOrigin();
    await repository.runGit(['tag', '-a', 'v1.0.0', '-m', 'release', commit]);
    await repository.runGit(['push', 'origin', 'refs/tags/v1.0.0']);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);

    expect(
      await controller.verifyTagSignature('v1.0.0'),
      GitTagSignatureStatus.unsigned,
    );
    expect(
      await controller.readRemoteTagStatus('v1.0.0', remoteName: 'origin'),
      GitTagRemoteStatus.matching,
    );

    final state = container.read(repositorySessionProvider);
    final tag = state.tags.singleWhere((item) => item.name == 'v1.0.0');
    expect(tag.signatureStatus, GitTagSignatureStatus.unsigned);
    expect(state.tagRemoteStatuses['v1.0.0'], GitTagRemoteStatus.matching);
    expect(state.tagRemoteNames['v1.0.0'], 'origin');
    final ref = mapRepositoryOverview(
      state,
    ).repository!.refs.singleWhere((item) => item.label == 'v1.0.0');
    expect(ref.secondaryLabel, contains('未签名'));
    expect(ref.secondaryLabel, contains('远端一致'));
  });

  test('batch-verifies tags and compares all tags with a remote', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    final commit = await repository.commit('Initial commit');
    await repository.createBareOrigin();
    await repository.runGit(['tag', 'v1.0.0', commit]);
    await repository.runGit(['tag', '-a', 'v2.0.0', '-m', 'release', commit]);
    await repository.runGit(['push', 'origin', 'refs/tags/v1.0.0']);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);

    final signatures = await controller.verifyAllTagSignatures();
    expect(
      container.read(repositorySessionProvider).isTagInspectionRunning,
      isFalse,
    );
    expect(signatures['v1.0.0'], GitTagSignatureStatus.notAnnotated);
    expect(signatures['v2.0.0'], GitTagSignatureStatus.unsigned);
    final remote = await controller.readAllRemoteTagStatuses(
      remoteName: 'origin',
    );
    expect(
      container.read(repositorySessionProvider).isTagInspectionRunning,
      isFalse,
    );
    expect(remote['v1.0.0'], GitTagRemoteStatus.matching);
    expect(remote['v2.0.0'], GitTagRemoteStatus.missing);
  });

  test(
    'deletes selected local tags with per-item results and one refresh',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('README.md', 'base\n');
      final commit = await repository.commit('Initial commit');
      await repository.runGit(['tag', 'v1.0.0', commit]);
      await repository.runGit(['tag', 'v2.0.0', commit]);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);

      final result = await controller.deleteTags(['v1.0.0', 'v2.0.0']);
      expect(result, isNotNull);
      expect(result!.deletedNames, containsAll(['v1.0.0', 'v2.0.0']));
      expect(result.missingNames, isEmpty);
      expect(result.failedNames, isEmpty);
      expect(container.read(repositorySessionProvider).tags, isEmpty);
      expect(
        container.read(repositorySessionProvider).operations.first.outcome,
        RepositoryOperationOutcome.succeeded,
      );
      expect(
        (await repository.runGit(['tag'])).stdout.toString().trim(),
        isEmpty,
      );
    },
  );

  test(
    'pushes selected local tags to one remote with per-item results',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('README.md', 'base\n');
      final commit = await repository.commit('Initial commit');
      await repository.createBareOrigin();
      await repository.runGit(['tag', 'v1.0.0', commit]);
      await repository.runGit(['tag', 'v2.0.0', commit]);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);

      final result = await controller.pushTags([
        'v1.0.0',
        'v2.0.0',
      ], remoteName: 'origin');
      expect(result, isNotNull);
      expect(result!.pushedNames, containsAll(['v1.0.0', 'v2.0.0']));
      expect(result.missingNames, isEmpty);
      expect(result.failedNames, isEmpty);
      expect(
        container.read(repositorySessionProvider).operations.first.outcome,
        RepositoryOperationOutcome.succeeded,
      );
      final remoteTags = (await repository.runGit([
        '--git-dir',
        '${repository.rootDirectory.path}/remotes/origin.git',
        'tag',
      ])).stdout.toString();
      expect(remoteTags, contains('v1.0.0'));
      expect(remoteTags, contains('v2.0.0'));
    },
  );

  test('deletes selected remote tags without deleting local tags', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    final commit = await repository.commit('Initial commit');
    await repository.createBareOrigin();
    await repository.runGit(['tag', 'v1.0.0', commit]);
    await repository.runGit(['tag', 'v2.0.0', commit]);
    await repository.runGit(['push', 'origin', 'refs/tags/v1.0.0']);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);

    final remoteNames = await controller.readRemoteTagNames(
      remoteName: 'origin',
    );
    expect(remoteNames, contains('v1.0.0'));
    expect(remoteNames, isNot(contains('v2.0.0')));
    final result = await controller.deleteRemoteTags([
      'v1.0.0',
      'v2.0.0',
    ], remoteName: 'origin');

    expect(result, isNotNull);
    expect(result!.remoteName, 'origin');
    expect(result.deletedNames, ['v1.0.0']);
    expect(result.missingNames, ['v2.0.0']);
    expect(result.failedNames, isEmpty);
    expect(
      container.read(repositorySessionProvider).tags.map((tag) => tag.name),
      containsAll(['v1.0.0', 'v2.0.0']),
    );
    expect(
      container.read(repositorySessionProvider).operations.first.outcome,
      RepositoryOperationOutcome.partiallySucceeded,
    );
    final remoteTags = (await repository.runGit([
      '--git-dir',
      '${repository.rootDirectory.path}/remotes/origin.git',
      'tag',
    ])).stdout.toString();
    expect(remoteTags.trim(), isEmpty);
  });

  test(
    'revalidates remote tags after confirmation when one was deleted externally',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('README.md', 'base\n');
      final commit = await repository.commit('Initial commit');
      final origin = await repository.createBareOrigin();
      await repository.runGit(['tag', 'v1.0.0', commit]);
      await repository.runGit(['push', 'origin', 'refs/tags/v1.0.0']);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);
      expect(
        await controller.readRemoteTagNames(remoteName: 'origin'),
        contains('v1.0.0'),
      );
      await repository.runGit([
        'update-ref',
        '-d',
        'refs/tags/v1.0.0',
      ], workingDirectory: origin);

      final result = await controller.deleteRemoteTags([
        'v1.0.0',
      ], remoteName: 'origin');
      expect(result, isNotNull);
      expect(result!.deletedNames, isEmpty);
      expect(result.missingNames, ['v1.0.0']);
      expect(result.failedNames, isEmpty);
      expect(
        (await repository.runGit(['tag'])).stdout.toString().trim(),
        'v1.0.0',
      );
    },
  );

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
    'keeps earlier remote tag deletions when a later remote deletion fails',
    () async {
      final repository = await GitTestRepository.create();
      addTearDown(repository.dispose);
      await repository.writeFile('README.md', 'base\n');
      final commit = await repository.commit('Initial commit');
      final origin = await repository.createBareOrigin();
      await repository.runGit(['tag', 'v1.0.0', commit]);
      await repository.runGit(['tag', 'v2.0.0', commit]);
      await repository.runGit([
        'push',
        'origin',
        'refs/tags/v1.0.0',
        'refs/tags/v2.0.0',
      ]);
      final hook = File('${origin.path}/hooks/pre-receive');
      await hook.writeAsString('''#!/bin/sh
while read old new ref; do
  case "\$ref" in
    refs/tags/v2.0.0) echo "protected tag" >&2; exit 1 ;;
  esac
done
exit 0
''');
      final chmod = await Process.run('chmod', ['+x', hook.path]);
      expect(chmod.exitCode, 0);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);
      final result = await controller.deleteRemoteTags([
        'v1.0.0',
        'v2.0.0',
      ], remoteName: 'origin');

      expect(result, isNotNull);
      expect(result!.deletedNames, ['v1.0.0']);
      expect(result.missingNames, isEmpty);
      expect(result.failedNames.keys, ['v2.0.0']);
      expect(
        container.read(repositorySessionProvider).operations.first.outcome,
        RepositoryOperationOutcome.partiallySucceeded,
      );
      final remoteTags = (await repository.runGit([
        '--git-dir',
        origin.path,
        'tag',
      ])).stdout.toString();
      expect(remoteTags, contains('v2.0.0'));
      expect(remoteTags, isNot(contains('v1.0.0')));
    },
  );

  test('cancels remote tag deletion without starting later refs', () async {
    if (Platform.isWindows) return;
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    final commit = await repository.commit('Initial commit');
    await repository.createBareOrigin();
    await repository.runGit(['tag', 'v1.0.0', commit]);
    await repository.runGit(['tag', 'v2.0.0', commit]);
    await repository.runGit([
      'push',
      'origin',
      'refs/tags/v1.0.0',
      'refs/tags/v2.0.0',
    ]);
    final marker = File('${repository.rootDirectory.path}/remote-tag-cancel');
    final helper = File('${repository.rootDirectory.path}/delayed-git');
    await helper.writeAsString('''#!/bin/sh
for argument in "\$@"; do
  if [ "\$argument" = "ls-remote" ]; then
    printf started > "${marker.path}"
    sleep 10
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
    final deletion = controller.deleteRemoteTags([
      'v1.0.0',
      'v2.0.0',
    ], remoteName: 'origin');
    for (var attempt = 0; attempt < 200 && !await marker.exists(); attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await marker.exists(), isTrue);
    controller.cancelRemoteTagDeletion();

    final result = await deletion;
    expect(result, isNotNull);
    expect(result!.deletedNames, isEmpty);
    expect(result.missingNames, isEmpty);
    expect(result.failedNames, isEmpty);
    expect(
      container.read(repositorySessionProvider).operations.first.outcome,
      RepositoryOperationOutcome.cancelled,
    );
  });

  test('does not mark tag creation failure as partial push success', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    final commit = await repository.commit('Initial commit');
    await repository.createBareOrigin();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    await repository.runGit(['tag', 'raced-tag', commit]);

    expect(
      await controller.createTag(
        GitCreateTagOptions(
          name: 'raced-tag',
          objectId: commit,
          pushRemoteName: 'origin',
        ),
      ),
      isFalse,
    );
    final operation = container
        .read(repositorySessionProvider)
        .operations
        .firstWhere((entry) => entry.kind == RepositoryOperationKind.ref);
    expect(operation.outcome, RepositoryOperationOutcome.failed);
  });

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
    expect(
      state.operations
          .firstWhere(
            (operation) => operation.kind == RepositoryOperationKind.history,
          )
          .outcome,
      RepositoryOperationOutcome.failed,
    );
    final overview = mapRepositoryOverview(state).repository!;
    expect(overview.disabledActions, contains(RepositoryAction.mergeBranch));
    expect(await controller.mergeLocalBranch('feature/conflict'), isFalse);

    final conflict = overview.changes.singleWhere(
      (change) => change.kind == RepositoryChangeKind.conflicted,
    );
    final versions = await controller.readConflictVersions(conflict);
    expect(versions, isNotNull);
    expect(versions!.hasBaseVersion, isTrue);
    expect(versions.baseText, 'base\n');
    expect(versions.oursText, 'main\n');
    expect(versions.theirsText, 'feature\n');
    expect(versions.workingText, contains('<<<<<<<'));
    final didResolve = await controller.resolveConflictWithContent(
      conflict,
      'merged in internal diff\n',
    );
    expect(
      didResolve,
      isTrue,
      reason: container.read(repositorySessionProvider).technicalDetails,
    );
    expect(
      container.read(repositorySessionProvider).status!.conflictedEntries,
      isEmpty,
    );
    final resolutionOperation = container
        .read(repositorySessionProvider)
        .operations
        .firstWhere(
          (operation) => operation.kind == RepositoryOperationKind.file,
        );
    expect(resolutionOperation.outcome, RepositoryOperationOutcome.succeeded);
    expect(
      await File(
        '${repository.workingDirectory.path}${Platform.pathSeparator}README.md',
      ).readAsString(),
      'merged in internal diff\n',
    );
    expect(
      container.read(repositorySessionProvider).operationState,
      GitRepositoryOperationState.merge,
    );

    expect(await controller.continueMerge(), isTrue);

    final completed = container.read(repositorySessionProvider);
    expect(completed.phase, RepositorySessionPhase.ready);
    expect(completed.operationState, GitRepositoryOperationState.none);
    expect(completed.commits.first.parentIds, hasLength(2));
    expect(
      completed.operations
          .firstWhere(
            (operation) => operation.kind == RepositoryOperationKind.history,
          )
          .outcome,
      RepositoryOperationOutcome.succeeded,
    );
  });

  test(
    'aborts a conflicted merge and refreshes the repository session',
    () async {
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
      final mainHead = await repository.commit('Main change');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(repository.workingDirectory.path);
      expect(await controller.mergeLocalBranch('feature/conflict'), isFalse);

      expect(await controller.abortMerge(), isTrue);

      final state = container.read(repositorySessionProvider);
      expect(state.phase, RepositorySessionPhase.ready);
      expect(state.operationState, GitRepositoryOperationState.none);
      expect(state.status!.isClean, isTrue);
      expect(state.status!.branch.objectId, mainHead);
      expect(
        state.operations
            .firstWhere(
              (operation) => operation.kind == RepositoryOperationKind.history,
            )
            .outcome,
        RepositoryOperationOutcome.succeeded,
      );
      expect(
        await File(
          '${repository.workingDirectory.path}${Platform.pathSeparator}README.md',
        ).readAsString(),
        'main\n',
      );
    },
  );

  test('marks continued merge uncertain when refresh fails', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    await repository.commit('Initial commit');
    await repository.runGit(['branch', 'feature/continue-refresh']);
    await repository.runGit(['switch', 'feature/continue-refresh']);
    await repository.writeFile('README.md', 'feature\n');
    await repository.commit('Feature change');
    await repository.runGit(['switch', 'main']);
    await repository.writeFile('README.md', 'main\n');
    await repository.commit('Main change');

    var failNextRefresh = false;
    final container = ProviderContainer(
      overrides: [
        repositoryRefreshHookForTestingProvider.overrideWithValue(() async {
          if (failNextRefresh) {
            failNextRefresh = false;
            throw StateError('injected continue merge refresh failure');
          }
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    expect(
      await controller.mergeLocalBranch('feature/continue-refresh'),
      isFalse,
    );
    await repository.writeFile('README.md', 'resolved\n');
    await repository.runGit(['add', '--', 'README.md']);
    await controller.refresh();
    failNextRefresh = true;

    expect(await controller.continueMerge(), isFalse);
    final state = container.read(repositorySessionProvider);
    final operation = state.operations.firstWhere(
      (entry) => entry.kind == RepositoryOperationKind.history,
    );
    expect(operation.outcome, RepositoryOperationOutcome.uncertain);
    expect(state.message, contains('写入已完成'));
  });

  test('marks aborted merge uncertain when refresh fails', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('README.md', 'base\n');
    await repository.commit('Initial commit');
    await repository.runGit(['branch', 'feature/abort-refresh']);
    await repository.runGit(['switch', 'feature/abort-refresh']);
    await repository.writeFile('README.md', 'feature\n');
    await repository.commit('Feature change');
    await repository.runGit(['switch', 'main']);
    await repository.writeFile('README.md', 'main\n');
    await repository.commit('Main change');

    var failNextRefresh = false;
    final container = ProviderContainer(
      overrides: [
        repositoryRefreshHookForTestingProvider.overrideWithValue(() async {
          if (failNextRefresh) {
            failNextRefresh = false;
            throw StateError('injected abort merge refresh failure');
          }
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    expect(await controller.mergeLocalBranch('feature/abort-refresh'), isFalse);
    failNextRefresh = true;

    expect(await controller.abortMerge(), isFalse);
    final state = container.read(repositorySessionProvider);
    final operation = state.operations.firstWhere(
      (entry) => entry.kind == RepositoryOperationKind.history,
    );
    expect(operation.outcome, RepositoryOperationOutcome.uncertain);
    expect(state.message, contains('写入已完成'));
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
      final operation = state.operations.firstWhere(
        (operation) => operation.kind == RepositoryOperationKind.fetch,
      );
      expect(operation.outcome, RepositoryOperationOutcome.uncertain);
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
      expect(await controller.updateFromUpstream(), isTrue);
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

Future<void> _waitUntil(
  bool Function() predicate, {
  String Function()? diagnostic,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      final details = diagnostic?.call();
      fail(
        'Timed out waiting for the automatic repository refresh.'
        '${details == null ? '' : ' $details'}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
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

final class _FixedExternalToolConfigurationStore
    implements ExternalToolConfigurationStore {
  _FixedExternalToolConfigurationStore(this.configuration);

  final ExternalToolConfiguration configuration;

  @override
  Future<ExternalToolConfiguration?> load() async => configuration;

  @override
  Future<void> save(ExternalToolConfiguration? configuration) async {}
}

final class _FixedRepositoryTrustStore implements RepositoryTrustStore {
  @override
  Future<RepositoryTrustStatus> load(RepositoryTrustId repository) async =>
      RepositoryTrustStatus.unconfirmed;

  @override
  Future<void> save(
    RepositoryTrustId repository,
    RepositoryTrustStatus status,
  ) async {}
}
