import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/app/git_desktop_app.dart';
import 'package:git_desktop/src/app/repository_session.dart';
import 'package:git_desktop/src/git/git.dart';
import 'package:git_desktop/src/presentation/presentation.dart';

void main() {
  test(
    'native mutation menus follow running and paused repository boundaries',
    () {
      final signature = GitSignature(
        name: 'Author',
        email: 'author@example.com',
        when: DateTime.utc(2026),
      );
      final session = RepositorySessionState(
        phase: RepositorySessionPhase.ready,
        commits: [
          GitCommit(
            objectId: 'head123',
            parentIds: const ['base123'],
            author: signature,
            committer: signature,
            subject: 'HEAD',
            body: '',
          ),
          GitCommit(
            objectId: 'base123',
            parentIds: const [],
            author: signature,
            committer: signature,
            subject: 'Base',
            body: '',
          ),
          GitCommit(
            objectId: 'side123',
            parentIds: const [],
            author: signature,
            committer: signature,
            subject: 'Side branch',
            body: '',
          ),
        ],
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
          changes: [
            RepositoryChangeViewData(
              path: 'lib/example.dart',
              kind: RepositoryChangeKind.modified,
            ),
          ],
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
      const untrackedSelection = RepositoryOverviewViewData.ready(
        RepositoryViewData(
          name: 'example',
          path: '/tmp/example',
          currentBranch: 'main',
          changes: [
            RepositoryChangeViewData(
              path: 'new.txt',
              kind: RepositoryChangeKind.untracked,
            ),
          ],
          selectedChange: RepositoryChangeViewData(
            path: 'new.txt',
            kind: RepositoryChangeKind.untracked,
          ),
        ),
      );
      const nonUtf8TrackedSelection = RepositoryOverviewViewData.ready(
        RepositoryViewData(
          name: 'example',
          path: '/tmp/example',
          currentBranch: 'main',
          changes: [
            RepositoryChangeViewData(
              path: 'invalid-�.txt',
              kind: RepositoryChangeKind.modified,
              isPathValidUtf8: false,
            ),
          ],
          selectedChange: RepositoryChangeViewData(
            path: 'invalid-�.txt',
            kind: RepositoryChangeKind.modified,
            isPathValidUtf8: false,
          ),
        ),
      );
      const rebaseSelection = RepositoryOverviewViewData.ready(
        RepositoryViewData(
          name: 'example',
          path: '/tmp/example',
          currentBranch: 'main',
          headOid: 'head123',
          commits: [
            CommitViewData(
              oid: 'base123',
              shortOid: 'base123',
              subject: 'Base',
              author: 'Author',
              relativeDate: 'now',
            ),
          ],
          selectedCommit: CommitDetailsViewData(
            oid: 'base123',
            subject: 'Base',
            author: 'Author',
            authoredAt: 'now',
          ),
        ),
      );
      const sideBranchRebaseSelection = RepositoryOverviewViewData.ready(
        RepositoryViewData(
          name: 'example',
          path: '/tmp/example',
          currentBranch: 'main',
          headOid: 'head123',
          commits: [
            CommitViewData(
              oid: 'side123',
              shortOid: 'side123',
              subject: 'Side branch',
              author: 'Author',
              relativeDate: 'now',
            ),
          ],
          selectedCommit: CommitDetailsViewData(
            oid: 'side123',
            subject: 'Side branch',
            author: 'Author',
            authoredAt: 'now',
          ),
        ),
      );
      const localCheckoutTarget = RepositoryOverviewViewData.ready(
        RepositoryViewData(
          name: 'example',
          path: '/tmp/example',
          currentBranch: 'main',
          refs: [
            RepositoryRefViewData(
              id: 'refs/heads/main',
              label: 'main',
              kind: RepositoryRefKind.localBranch,
              isCurrent: true,
            ),
            RepositoryRefViewData(
              id: 'refs/heads/feature',
              label: 'feature',
              kind: RepositoryRefKind.localBranch,
            ),
          ],
        ),
      );
      const dirtyRemoteOnlyCheckoutTarget = RepositoryOverviewViewData.ready(
        RepositoryViewData(
          name: 'example',
          path: '/tmp/example',
          currentBranch: 'main',
          isWorkingTreeClean: false,
          refs: [
            RepositoryRefViewData(
              id: 'refs/remotes/origin/feature',
              label: 'origin/feature',
              kind: RepositoryRefKind.remoteBranch,
            ),
          ],
        ),
      );
      const conflictingRemoteOnlyCheckoutTarget =
          RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'example',
              path: '/tmp/example',
              currentBranch: 'main',
              refs: [
                RepositoryRefViewData(
                  id: 'refs/heads/feature',
                  label: 'feature',
                  kind: RepositoryRefKind.localBranch,
                  isCurrent: true,
                ),
                RepositoryRefViewData(
                  id: 'refs/remotes/origin/feature',
                  label: 'origin/feature',
                  kind: RepositoryRefKind.remoteBranch,
                ),
              ],
            ),
          );

      expect(
        nativeWorkspaceMenuAvailability(session, available).canApplyPatch,
        isTrue,
      );
      expect(
        nativeWorkspaceMenuAvailability(session, available).canAddRemote,
        isTrue,
      );
      expect(
        nativeWorkspaceMenuAvailability(session, available).canCheckout,
        isFalse,
      );
      expect(
        nativeWorkspaceMenuAvailability(session, available).canCommitAll,
        isFalse,
      );
      expect(
        nativeWorkspaceMenuAvailability(session, available).canCommitSelected,
        isFalse,
      );
      expect(
        nativeWorkspaceMenuAvailability(
          session,
          localCheckoutTarget,
        ).canCheckout,
        isTrue,
      );
      expect(
        nativeWorkspaceMenuAvailability(
          session,
          dirtyRemoteOnlyCheckoutTarget,
        ).canCheckout,
        isFalse,
      );
      expect(
        nativeWorkspaceMenuAvailability(
          session,
          conflictingRemoteOnlyCheckoutTarget,
        ).canCheckout,
        isFalse,
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
        nativeWorkspaceMenuAvailability(
          session,
          available,
        ).canInteractiveRebase,
        isFalse,
      );
      expect(
        nativeWorkspaceMenuAvailability(
          session,
          rebaseSelection,
        ).canInteractiveRebase,
        isTrue,
      );
      expect(
        nativeWorkspaceMenuAvailability(
          session,
          sideBranchRebaseSelection,
        ).canInteractiveRebase,
        isFalse,
      );
      for (final blockedRepository in [
        const RepositoryViewData(
          name: 'example',
          path: '/tmp/example',
          currentBranch: 'main',
          headOid: 'head123',
          isWorkingTreeClean: false,
          commits: [
            CommitViewData(
              oid: 'base123',
              shortOid: 'base123',
              subject: 'Base',
              author: 'Author',
              relativeDate: 'now',
            ),
          ],
          selectedCommit: CommitDetailsViewData(
            oid: 'base123',
            subject: 'Base',
            author: 'Author',
            authoredAt: 'now',
          ),
        ),
        const RepositoryViewData(
          name: 'example',
          path: '/tmp/example',
          currentBranch: 'HEAD',
          headOid: 'head123',
          isDetachedHead: true,
          commits: [
            CommitViewData(
              oid: 'base123',
              shortOid: 'base123',
              subject: 'Base',
              author: 'Author',
              relativeDate: 'now',
            ),
          ],
          selectedCommit: CommitDetailsViewData(
            oid: 'base123',
            subject: 'Base',
            author: 'Author',
            authoredAt: 'now',
          ),
        ),
        const RepositoryViewData(
          name: 'example',
          path: '/tmp/example',
          currentBranch: 'main',
          headOid: 'head123',
          commits: [
            CommitViewData(
              oid: 'head123',
              shortOid: 'head123',
              subject: 'HEAD',
              author: 'Author',
              relativeDate: 'now',
            ),
          ],
          selectedCommit: CommitDetailsViewData(
            oid: 'head123',
            subject: 'HEAD',
            author: 'Author',
            authoredAt: 'now',
          ),
        ),
      ]) {
        expect(
          nativeWorkspaceMenuAvailability(
            session,
            RepositoryOverviewViewData.ready(blockedRepository),
          ).canInteractiveRebase,
          isFalse,
        );
      }
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
        ).canCommitAll,
        isTrue,
      );
      expect(
        nativeWorkspaceMenuAvailability(
          session,
          unstagedSelection,
        ).canCommitSelected,
        isTrue,
      );
      expect(
        nativeWorkspaceMenuAvailability(
          session,
          untrackedSelection,
        ).canCommitAll,
        isFalse,
      );
      expect(
        nativeWorkspaceMenuAvailability(
          session,
          untrackedSelection,
        ).canCommitSelected,
        isTrue,
      );
      expect(
        nativeWorkspaceMenuAvailability(
          session,
          nonUtf8TrackedSelection,
        ).canCommitAll,
        isTrue,
      );
      expect(
        nativeWorkspaceMenuAvailability(
          session,
          nonUtf8TrackedSelection,
        ).canCommitSelected,
        isFalse,
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
        canAddRemote: false,
        canApplyPatch: false,
        canAbortOperation: false,
        canCheckout: false,
        canCommitAll: false,
        canCommitSelected: false,
        canCommit: false,
        canContinueOperation: false,
        canCreateBranch: false,
        canFetch: false,
        canInteractiveRebase: false,
        canMarkConflictResolved: false,
        canMerge: false,
        canPull: false,
        canPush: false,
        canRemoveSelected: false,
        canStageSelected: false,
        canStash: false,
        canStopTracking: false,
        canTag: false,
        canUnstageSelected: false,
        canUseConflictStage2: false,
        canUseConflictStage3: false,
      ));
    },
  );

  test('native recovery menus follow the active Git operation', () {
    const repository = GitRepository(
      id: GitRepositoryId(
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
      operationState: GitRepositoryOperationState.rebase,
      status: GitStatusSnapshot(
        branch: const GitBranchStatus(head: 'main', objectId: 'head123'),
        entries: const [],
      ),
    );
    const overview = RepositoryOverviewViewData.ready(
      RepositoryViewData(
        name: 'example',
        path: '/tmp/example',
        currentBranch: 'main',
        isRebaseInProgress: true,
      ),
    );

    final available = nativeWorkspaceMenuAvailability(session, overview);

    expect(available.canContinueOperation, isTrue);
    expect(available.canAbortOperation, isTrue);
    final conflicted = nativeWorkspaceMenuAvailability(
      session.copyWith(
        status: GitStatusSnapshot(
          branch: const GitBranchStatus(head: 'main', objectId: 'head123'),
          entries: [
            GitStatusEntry(
              kind: GitFileStatusKind.unmerged,
              path: GitPath.fromString('conflicted.txt'),
              indexStatus: GitChangeType.unmerged,
              workTreeStatus: GitChangeType.unmerged,
            ),
          ],
        ),
      ),
      overview,
    );
    expect(conflicted.canContinueOperation, isFalse);
    expect(conflicted.canAbortOperation, isTrue);
    final loading = nativeWorkspaceMenuAvailability(
      session.copyWith(phase: RepositorySessionPhase.loading),
      overview,
    );
    expect(loading.canContinueOperation, isFalse);
    expect(loading.canAbortOperation, isFalse);
  });

  test('native conflict menu requires one current unmerged selection', () {
    const repository = GitRepository(
      id: GitRepositoryId(
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
    final entry = GitStatusEntry(
      kind: GitFileStatusKind.unmerged,
      path: GitPath.fromString('conflicted.txt'),
      indexStatus: GitChangeType.unmerged,
      workTreeStatus: GitChangeType.unmerged,
      stage2ObjectId: 'ours123',
    );
    final session = RepositorySessionState(
      phase: RepositorySessionPhase.ready,
      repository: repository,
      operationState: GitRepositoryOperationState.merge,
      status: GitStatusSnapshot(
        branch: const GitBranchStatus(head: 'main', objectId: 'head123'),
        entries: [entry],
      ),
    );
    const conflict = RepositoryChangeViewData(
      path: 'conflicted.txt',
      kind: RepositoryChangeKind.conflicted,
    );
    const overview = RepositoryOverviewViewData.ready(
      RepositoryViewData(
        name: 'example',
        path: '/tmp/example',
        currentBranch: 'main',
        changes: [conflict],
        selectedChange: conflict,
      ),
    );

    final available = nativeWorkspaceMenuAvailability(
      session,
      overview,
      selectedChanges: const [conflict],
    );

    expect(available.canUseConflictStage2, isTrue);
    expect(available.canUseConflictStage3, isFalse);
    expect(available.canMarkConflictResolved, isTrue);

    final noSelection = nativeWorkspaceMenuAvailability(
      session,
      overview,
      selectedChanges: const [],
    );
    expect(noSelection.canUseConflictStage2, isFalse);
    expect(noSelection.canMarkConflictResolved, isFalse);
  });

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
