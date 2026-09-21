import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/app/git_desktop_app.dart';
import 'package:git_desktop/src/app/repository_session.dart';
import 'package:git_desktop/src/git/git.dart';
import 'package:git_desktop/src/presentation/presentation.dart';

void main() {
  test(
    'native mutation menus follow running and paused repository boundaries',
    () {
      const session = RepositorySessionState(
        phase: RepositorySessionPhase.ready,
      );
      const available = RepositoryOverviewViewData.ready(
        RepositoryViewData(
          name: 'example',
          path: '/tmp/example',
          currentBranch: 'main',
        ),
      );
      const fetching = RepositoryOverviewViewData.ready(
        RepositoryViewData(
          name: 'example',
          path: '/tmp/example',
          currentBranch: 'main',
          isFetching: true,
        ),
      );
      const paused = RepositoryOverviewViewData.ready(
        RepositoryViewData(
          name: 'example',
          path: '/tmp/example',
          currentBranch: 'main',
          isRebaseInProgress: true,
        ),
      );
      const unstagedSelection = RepositoryOverviewViewData.ready(
        RepositoryViewData(
          name: 'example',
          path: '/tmp/example',
          currentBranch: 'main',
          selectedChange: RepositoryChangeViewData(
            path: 'lib/example.dart',
            kind: RepositoryChangeKind.modified,
          ),
        ),
      );
      const stagedSelection = RepositoryOverviewViewData.ready(
        RepositoryViewData(
          name: 'example',
          path: '/tmp/example',
          currentBranch: 'main',
          selectedChange: RepositoryChangeViewData(
            path: 'lib/example.dart',
            kind: RepositoryChangeKind.modified,
            isStaged: true,
          ),
        ),
      );

      expect(
        nativeWorkspaceMenuAvailability(session, available).canApplyPatch,
        isTrue,
      );
      expect(
        nativeWorkspaceMenuAvailability(session, available).canFetch,
        isTrue,
      );
      expect(
        nativeWorkspaceMenuAvailability(session, available).canMerge,
        isTrue,
      );
      expect(
        nativeWorkspaceMenuAvailability(session, available).canCommit,
        isTrue,
      );
      expect(
        nativeWorkspaceMenuAvailability(session, available).canPull,
        isTrue,
      );
      expect(
        nativeWorkspaceMenuAvailability(session, available).canPush,
        isTrue,
      );
      expect(
        nativeWorkspaceMenuAvailability(session, available).canCreateBranch,
        isTrue,
      );
      expect(
        nativeWorkspaceMenuAvailability(session, available).canStash,
        isTrue,
      );
      expect(
        nativeWorkspaceMenuAvailability(session, available).canTag,
        isFalse,
      );
      expect(
        nativeWorkspaceMenuAvailability(
          session,
          unstagedSelection,
        ).canStageSelected,
        isTrue,
      );
      expect(
        nativeWorkspaceMenuAvailability(
          session,
          unstagedSelection,
        ).canRemoveSelected,
        isTrue,
      );
      expect(
        nativeWorkspaceMenuAvailability(
          session,
          unstagedSelection,
        ).canUnstageSelected,
        isFalse,
      );
      expect(
        nativeWorkspaceMenuAvailability(
          session,
          stagedSelection,
        ).canStageSelected,
        isFalse,
      );
      expect(
        nativeWorkspaceMenuAvailability(
          session,
          stagedSelection,
        ).canUnstageSelected,
        isTrue,
      );
      final mixedSelection = <RepositoryChangeViewData>[
        unstagedSelection.repository!.selectedChange!,
        stagedSelection.repository!.selectedChange!,
      ];
      expect(
        nativeWorkspaceMenuAvailability(
          session,
          available,
          selectedChanges: mixedSelection,
        ).canStageSelected,
        isTrue,
      );
      expect(
        nativeWorkspaceMenuAvailability(
          session,
          available,
          selectedChanges: mixedSelection,
        ).canUnstageSelected,
        isTrue,
      );
      expect(
        nativeWorkspaceMenuAvailability(
          session,
          available,
          selectedChanges: const [
            RepositoryChangeViewData(
              path: 'invalid',
              kind: RepositoryChangeKind.untracked,
              isPathValidUtf8: false,
            ),
          ],
        ).canRemoveSelected,
        isFalse,
      );
      expect(
        nativeWorkspaceMenuAvailability(session, fetching).canApplyPatch,
        isFalse,
      );
      expect(
        nativeWorkspaceMenuAvailability(session, fetching).canFetch,
        isFalse,
      );
      expect(
        nativeWorkspaceMenuAvailability(session, fetching).canCommit,
        isFalse,
      );
      expect(
        nativeWorkspaceMenuAvailability(session, fetching).canPull,
        isFalse,
      );
      expect(
        nativeWorkspaceMenuAvailability(session, fetching).canPush,
        isFalse,
      );
      expect(
        nativeWorkspaceMenuAvailability(session, fetching).canCreateBranch,
        isFalse,
      );
      expect(
        nativeWorkspaceMenuAvailability(session, fetching).canStash,
        isFalse,
      );
      expect(nativeWorkspaceMenuAvailability(session, paused), (
        canApplyPatch: false,
        canCommit: false,
        canCreateBranch: false,
        canFetch: false,
        canMerge: false,
        canPull: false,
        canPush: false,
        canRemoveSelected: false,
        canStageSelected: false,
        canStash: false,
        canStopTracking: false,
        canTag: false,
        canUnstageSelected: false,
      ));
    },
  );

  test('native file targets stay inside the current work tree', () {
    final repository = GitRepository(
      id: const GitRepositoryId(
        commonDirectory: '/tmp/example/.git',
        workTreeRoot: '/tmp/example',
      ),
      openedPath: '/tmp/example',
      gitDirectory: '/tmp/example/.git',
      commonDirectory: '/tmp/example/.git',
      workTreeRoot: '/tmp/example',
      isBare: false,
      isInsideWorkTree: true,
    );
    final session = RepositorySessionState(
      phase: RepositorySessionPhase.ready,
      repository: repository,
    );
    const overview = RepositoryOverviewViewData.ready(
      RepositoryViewData(
        name: 'example',
        path: '/tmp/example',
        currentBranch: 'main',
      ),
    );

    final valid = nativeWorkspaceMenuFileTargets(
      session,
      overview,
      selectedChanges: const [
        RepositoryChangeViewData(
          path: 'lib/example.dart',
          kind: RepositoryChangeKind.modified,
        ),
      ],
    );
    expect(valid.repositoryRootPath, '/tmp/example');
    expect(valid.selectedFilePaths, ['/tmp/example/lib/example.dart']);
    expect(valid.hasFileSelection, isTrue);

    final escaped = nativeWorkspaceMenuFileTargets(
      session,
      overview,
      selectedChanges: const [
        RepositoryChangeViewData(
          path: '../outside.txt',
          kind: RepositoryChangeKind.modified,
        ),
      ],
    );
    expect(escaped.repositoryRootPath, '/tmp/example');
    expect(escaped.selectedFilePaths, isEmpty);
    expect(escaped.hasFileSelection, isTrue);
  });

  test('native file targets use a UTF-8 historical file selection', () {
    final repository = GitRepository(
      id: const GitRepositoryId(
        commonDirectory: '/tmp/example/.git',
        workTreeRoot: '/tmp/example',
      ),
      openedPath: '/tmp/example',
      gitDirectory: '/tmp/example/.git',
      commonDirectory: '/tmp/example/.git',
      workTreeRoot: '/tmp/example',
      isBare: false,
      isInsideWorkTree: true,
    );
    final session = RepositorySessionState(
      phase: RepositorySessionPhase.ready,
      repository: repository,
      selectedCommitFile: SelectedCommitFile(
        objectId: 'abc123',
        file: GitCommitFileChange(
          path: GitPath.fromString('README.md'),
          kind: GitCommitChangeKind.modified,
        ),
      ),
    );
    const overview = RepositoryOverviewViewData.ready(
      RepositoryViewData(
        name: 'example',
        path: '/tmp/example',
        currentBranch: 'main',
      ),
    );

    final targets = nativeWorkspaceMenuFileTargets(session, overview);
    expect(targets.repositoryRootPath, '/tmp/example');
    expect(targets.selectedFilePaths, ['/tmp/example/README.md']);
    expect(targets.hasFileSelection, isTrue);
  });

  test('native menus discard a hidden working-tree selection', () {
    final repository = GitRepository(
      id: const GitRepositoryId(
        commonDirectory: '/tmp/example/.git',
        workTreeRoot: '/tmp/example',
      ),
      openedPath: '/tmp/example',
      gitDirectory: '/tmp/example/.git',
      commonDirectory: '/tmp/example/.git',
      workTreeRoot: '/tmp/example',
      isBare: false,
      isInsideWorkTree: true,
    );
    final session = RepositorySessionState(
      phase: RepositorySessionPhase.ready,
      repository: repository,
      selectedCommitFile: SelectedCommitFile(
        objectId: 'abc123',
        file: GitCommitFileChange(
          path: GitPath.fromString('README.md'),
          kind: GitCommitChangeKind.modified,
        ),
      ),
    );
    const staleWorkingTreeSelection = RepositoryChangeViewData(
      path: 'lib/old_selection.dart',
      kind: RepositoryChangeKind.modified,
    );
    const overview = RepositoryOverviewViewData.ready(
      RepositoryViewData(
        name: 'example',
        path: '/tmp/example',
        currentBranch: 'main',
        selectedChange: staleWorkingTreeSelection,
        selectedCommit: CommitDetailsViewData(
          oid: 'abc123',
          subject: 'Selected commit',
          author: 'Author',
          authoredAt: 'now',
        ),
      ),
    );

    final availability = nativeWorkspaceMenuAvailability(
      session,
      overview,
      selectedChanges: const [staleWorkingTreeSelection],
    );
    final targets = nativeWorkspaceMenuFileTargets(
      session,
      overview,
      selectedChanges: const [staleWorkingTreeSelection],
    );

    expect(availability.canStageSelected, isFalse);
    expect(availability.canUnstageSelected, isFalse);
    expect(availability.canRemoveSelected, isFalse);
    expect(availability.canStopTracking, isTrue);
    expect(targets.selectedFilePaths, ['/tmp/example/README.md']);
  });

  test('native stop tracking requires every selected working-tree file', () {
    const session = RepositorySessionState(phase: RepositorySessionPhase.ready);
    const overview = RepositoryOverviewViewData.ready(
      RepositoryViewData(
        name: 'example',
        path: '/tmp/example',
        currentBranch: 'main',
      ),
    );

    expect(
      nativeWorkspaceMenuAvailability(
        session,
        overview,
        selectedChanges: const [
          RepositoryChangeViewData(
            path: 'lib/a.dart',
            kind: RepositoryChangeKind.modified,
          ),
          RepositoryChangeViewData(
            path: 'lib/b.dart',
            kind: RepositoryChangeKind.modified,
            isStaged: true,
          ),
        ],
      ).canStopTracking,
      isTrue,
    );
    expect(
      nativeWorkspaceMenuAvailability(
        session,
        overview,
        selectedChanges: const [
          RepositoryChangeViewData(
            path: 'lib/a.dart',
            kind: RepositoryChangeKind.modified,
          ),
          RepositoryChangeViewData(
            path: 'lib/new.dart',
            kind: RepositoryChangeKind.untracked,
          ),
        ],
      ).canStopTracking,
      isFalse,
    );
  });
}
