import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/app/git_desktop_app.dart';
import 'package:git_desktop/src/app/repository_session.dart';
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

      expect(
        nativeWorkspaceMenuAvailability(session, available).canApplyPatch,
        isTrue,
      );
      expect(
        nativeWorkspaceMenuAvailability(session, available).canFetch,
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
        canPull: false,
        canPush: false,
        canStash: false,
        canStopTracking: false,
      ));
    },
  );
}
