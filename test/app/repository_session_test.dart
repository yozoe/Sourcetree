import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/app/repository_session.dart';
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

  test('loads selected commit files, statistics and file diff', () async {
    final repository = await GitTestRepository.create();
    addTearDown(repository.dispose);
    await repository.writeFile('lib/example.dart', 'void main() {}\n');
    await repository.commit('add example');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(repositorySessionProvider.notifier);
    await controller.openRepository(repository.workingDirectory.path);
    final commit = container
        .read(repositorySessionProvider)
        .commits
        .singleWhere((entry) => entry.subject == 'add example');

    await controller.selectCommit(commit.objectId);

    final overview = mapRepositoryOverview(
      container.read(repositorySessionProvider),
    );
    final selected = overview.repository!;
    expect(selected.selectedCommit!.changedFiles, 1);
    expect(selected.selectedCommit!.additions, 1);
    expect(selected.commitChanges.single.path, 'lib/example.dart');
    expect(selected.selectedCommitFile!.path, 'lib/example.dart');
    expect(selected.commitDiff.lines, isNotEmpty);
  });

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
        overview.refs.singleWhere(
          (reference) => reference.kind == RepositoryRefKind.workspace,
        ),
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
            .singleWhere(
              (reference) => reference.kind == RepositoryRefKind.workspace,
            )
            .isSelected,
        isTrue,
      );
    },
  );

  test('restores opened repository tabs and the active repository', () async {
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
      repositorySessionProvider.notifier,
    );

    await firstController.restoreSession();
    await firstController.openRepository(firstRepository.workingDirectory.path);
    await firstController.openRepository(
      secondRepository.workingDirectory.path,
    );
    final firstPath = firstContainer
        .read(repositorySessionProvider)
        .openRepositoryTabs
        .first
        .path;
    await firstController.selectRepositoryTab(firstPath);
    await firstContainer
        .read(repositorySessionProvider.notifier)
        .restoreSession();

    final restoredContainer = ProviderContainer(
      overrides: [repositorySessionStoreProvider.overrideWithValue(store)],
    );
    addTearDown(restoredContainer.dispose);
    await restoredContainer
        .read(repositorySessionProvider.notifier)
        .restoreSession();

    final restoredState = restoredContainer.read(repositorySessionProvider);
    expect(restoredState.phase, RepositorySessionPhase.ready);
    expect(restoredState.openRepositoryTabs, hasLength(2));
    expect(restoredState.activeRepositoryTabPath, firstPath);
    expect(restoredState.repository!.commandDirectory, firstPath);
  });

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
    'reopens an existing repository when its workspace tab is selected',
    () async {
      final firstRepository = await GitTestRepository.create();
      addTearDown(firstRepository.dispose);
      final secondRepository = await GitTestRepository.create();
      addTearDown(secondRepository.dispose);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);

      await controller.openRepository(firstRepository.workingDirectory.path);
      await controller.openRepository(secondRepository.workingDirectory.path);
      final initialTabs = container
          .read(repositorySessionProvider)
          .openRepositoryTabs;
      final firstTab = initialTabs.first;
      final initialLabels = initialTabs.map((tab) => tab.label).toList();

      await controller.selectRepositoryTab(firstTab.path);

      final state = container.read(repositorySessionProvider);
      expect(state.phase, RepositorySessionPhase.ready);
      expect(state.activeRepositoryTabPath, firstTab.path);
      expect(state.repository!.commandDirectory, firstTab.path);
      expect(state.openRepositoryTabs, hasLength(2));
      expect(
        state.openRepositoryTabs.map((tab) => tab.label).toList(),
        initialLabels,
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

    expect(commits.first.graph.hasPreviousNode, isFalse);
    expect(commits[1].graph.hasPreviousNode, isTrue);
    expect(main.graph.activeLanes, containsAll([0, 1]));
    expect(
      main.graph.activeLaneDestinations,
      hasLength(main.graph.activeLanes.length),
    );
    expect(main.graph.activeLaneDestinations, everyElement(isNotNull));
    expect(feature.graph.lane, 1);
    expect(feature.graph.parentLanes, contains(1));
  });

  test(
    'keeps the previously active tab when a selected repository is unavailable',
    () async {
      final firstRepository = await GitTestRepository.create();
      addTearDown(firstRepository.dispose);
      final secondRepository = await GitTestRepository.create();
      addTearDown(secondRepository.dispose);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(repositorySessionProvider.notifier);

      await controller.openRepository(firstRepository.workingDirectory.path);
      await controller.openRepository(secondRepository.workingDirectory.path);
      final stateBeforeSelection = container.read(repositorySessionProvider);
      final unavailableTab = stateBeforeSelection.openRepositoryTabs.first;

      await firstRepository.workingDirectory.delete(recursive: true);
      await controller.selectRepositoryTab(unavailableTab.path);

      final state = container.read(repositorySessionProvider);
      expect(state.phase, RepositorySessionPhase.error);
      expect(state.requestedPath, unavailableTab.path);
      expect(
        state.activeRepositoryTabPath,
        stateBeforeSelection.activeRepositoryTabPath,
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
        containsAll(['origin/main', 'origin/feature/remote']),
      );
      expect(
        overview.refs.map((ref) => ref.label),
        isNot(contains('origin/HEAD')),
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
