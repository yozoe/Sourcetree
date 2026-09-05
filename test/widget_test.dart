import 'dart:io';
import 'dart:ui' show PointerDeviceKind, SemanticsAction, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:git_desktop/src/app/git_askpass_prompt_coordinator.dart';
import 'package:git_desktop/src/app/git_desktop_app.dart';
import 'package:git_desktop/src/app/repository_library_controller.dart';
import 'package:git_desktop/src/app/repository_session_store.dart';
import 'package:git_desktop/src/app/theme_preferences.dart';
import 'package:git_desktop/src/git/git.dart';
import 'package:git_desktop/src/presentation/presentation.dart';

final class _MemoryThemePreferencesStore
    implements GitDesktopThemePreferencesStore {
  final List<GitDesktopThemePreferences> saved = [];

  @override
  Future<GitDesktopThemePreferences> load() async =>
      GitDesktopThemePreferences.defaults;

  @override
  Future<void> save(GitDesktopThemePreferences preferences) async {
    saved.add(preferences);
  }
}

final class _CountingSessionStore implements RepositorySessionStore {
  int loadCount = 0;

  @override
  Future<RepositorySessionSnapshot> load() async {
    loadCount++;
    return const RepositorySessionSnapshot(
      openRepositoryPaths: ['/tmp/should-not-restore'],
      activeRepositoryPath: '/tmp/should-not-restore',
    );
  }

  @override
  Future<void> save(RepositorySessionSnapshot snapshot) async {}
}

final class _FailingAfterRestoreSessionStore implements RepositorySessionStore {
  var saveCount = 0;

  @override
  Future<RepositorySessionSnapshot> load() async {
    return const RepositorySessionSnapshot(
      openRepositoryPaths: ['/tmp/library-one', '/tmp/library-two'],
      activeRepositoryPath: '/tmp/library-one',
    );
  }

  @override
  Future<void> save(RepositorySessionSnapshot snapshot) async {
    saveCount++;
    if (saveCount > 1) throw const FileSystemException('private store path');
  }
}

void main() {
  testWidgets('reports recoverable failures from ordinary library saves', (
    tester,
  ) async {
    final store = _FailingAfterRestoreSessionStore();
    final container = ProviderContainer(
      overrides: [repositorySessionStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: RepositoryLibraryWindow()),
      ),
    );
    await tester.pumpAndSettle();
    expect(store.saveCount, 1);

    container
        .read(repositoryLibraryProvider.notifier)
        .select('/tmp/library-two');
    await tester.pumpAndSettle();

    expect(find.textContaining('已保留在当前窗口，但尚未写入磁盘'), findsOneWidget);
    expect(find.textContaining('private store path'), findsNothing);
  });

  test('repository mutation boundary covers every live and paused state', () {
    const runningStates = <RepositoryViewData>[
      RepositoryViewData(
        name: 'example',
        path: '/tmp/example',
        currentBranch: 'main',
        isRefreshing: true,
      ),
      RepositoryViewData(
        name: 'example',
        path: '/tmp/example',
        currentBranch: 'main',
        isWorkingTreeBusy: true,
      ),
      RepositoryViewData(
        name: 'example',
        path: '/tmp/example',
        currentBranch: 'main',
        isFetching: true,
      ),
      RepositoryViewData(
        name: 'example',
        path: '/tmp/example',
        currentBranch: 'main',
        isPulling: true,
      ),
      RepositoryViewData(
        name: 'example',
        path: '/tmp/example',
        currentBranch: 'main',
        isPushing: true,
      ),
      RepositoryViewData(
        name: 'example',
        path: '/tmp/example',
        currentBranch: 'main',
        isStashing: true,
      ),
      RepositoryViewData(
        name: 'example',
        path: '/tmp/example',
        currentBranch: 'main',
        footer: RepositoryFooterViewData(operationLabel: '读取 Diff'),
      ),
    ];
    const pausedStates = <RepositoryViewData>[
      RepositoryViewData(
        name: 'example',
        path: '/tmp/example',
        currentBranch: 'main',
        isMergeInProgress: true,
      ),
      RepositoryViewData(
        name: 'example',
        path: '/tmp/example',
        currentBranch: 'main',
        isRebaseInProgress: true,
      ),
      RepositoryViewData(
        name: 'example',
        path: '/tmp/example',
        currentBranch: 'main',
        isCherryPickInProgress: true,
      ),
      RepositoryViewData(
        name: 'example',
        path: '/tmp/example',
        currentBranch: 'main',
        isRevertInProgress: true,
      ),
    ];

    for (final repository in runningStates) {
      expect(repository.hasRunningRepositoryTask, isTrue);
      expect(repository.blocksRepositoryMutations, isTrue);
    }
    for (final repository in pausedStates) {
      expect(repository.hasRunningRepositoryTask, isFalse);
      expect(repository.blocksRepositoryMutations, isTrue);
    }
  });

  test('uses operation-aware conflict version labels', () {
    const branch = 'feature/topic';
    expect(
      conflictVersionLabels(
        GitRepositoryOperationState.merge,
        currentBranch: branch,
      ),
      ('当前分支版本 · feature/topic', '合并来源版本'),
    );
    expect(
      conflictVersionLabels(
        GitRepositoryOperationState.rebase,
        currentBranch: branch,
      ),
      ('变基目标基线版本', '正在重放的提交版本'),
    );
    expect(
      conflictVersionLabels(
        GitRepositoryOperationState.cherryPick,
        currentBranch: branch,
      ),
      ('当前分支版本 · feature/topic', '遴选提交版本'),
    );
    expect(
      conflictVersionLabels(
        GitRepositoryOperationState.revert,
        currentBranch: branch,
      ),
      ('当前分支版本 · feature/topic', '待应用的回滚版本'),
    );
    expect(
      conflictVersionLabels(
        GitRepositoryOperationState.none,
        currentBranch: branch,
      ),
      ('当前基线版本', '待应用版本'),
    );
  });

  testWidgets('shows supported actions on first launch', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: GitDesktopApp()));

    expect(find.text('打开一个 Git 仓库'), findsOneWidget);
    expect(find.text('打开仓库'), findsOneWidget);
    expect(find.text('克隆仓库'), findsOneWidget);
    expect(find.text('初始化仓库'), findsOneWidget);
  });

  testWidgets('keeps cherry-pick recovery actions available in the toolbar', (
    tester,
  ) async {
    final actions = <RepositoryAction>[];
    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: RepositoryOverviewViewData.ready(
            const RepositoryViewData(
              name: 'example',
              path: '/tmp/example',
              currentBranch: 'main',
              isCherryPickInProgress: true,
            ),
          ),
          callbacks: RepositoryOverviewCallbacks(onAction: actions.add),
        ),
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey('repository-action-continueSequencer')),
    );
    await tester.tap(
      find.byKey(const ValueKey('repository-action-abortSequencer')),
    );

    expect(
      actions,
      containsAll([
        RepositoryAction.continueSequencer,
        RepositoryAction.abortSequencer,
      ]),
    );
  });

  testWidgets(
    'enlarged text expands dense toolbars and rows without overflow',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: RepositoryOverview(
              data: RepositoryOverviewViewData.ready(
                const RepositoryViewData(
                  name: 'example',
                  path: '/tmp/example',
                  currentBranch: 'main',
                  commits: [
                    CommitViewData(
                      oid: '0123456789abcdef',
                      shortOid: '0123456',
                      subject: 'Scaled history row',
                      author: 'Test User',
                      relativeDate: '今天',
                    ),
                  ],
                ),
              ),
              callbacks: const RepositoryOverviewCallbacks(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        tester
            .getSize(find.byKey(const ValueKey<String>('repository-toolbar')))
            .height,
        greaterThan(54),
      );
      expect(find.text('Scaled history row'), findsOneWidget);
    },
  );

  testWidgets('model selection replaces stale local change highlighting', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late StateSetter update;
    var selectSecond = false;

    RepositoryChangeViewData change(String path, bool selected) =>
        RepositoryChangeViewData(
          path: path,
          kind: RepositoryChangeKind.modified,
          isStaged: true,
          isSelected: selected,
        );

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            final first = change('first.dart', !selectSecond);
            final second = change('second.dart', selectSecond);
            return RepositoryOverview(
              data: RepositoryOverviewViewData.ready(
                RepositoryViewData(
                  name: 'example',
                  path: '/tmp/example',
                  currentBranch: 'main',
                  refs: const [
                    RepositoryRefViewData(
                      id: 'workspace',
                      label: '文件状态',
                      kind: RepositoryRefKind.workspace,
                      isSelected: true,
                    ),
                  ],
                  changes: [first, second],
                  selectedChange: selectSecond ? second : first,
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .getSemantics(
            find.byKey(const ValueKey('change-tile-staged-first.dart')),
          )
          .flagsCollection
          .isSelected,
      Tristate.isTrue,
    );
    update(() => selectSecond = true);
    await tester.pump();

    expect(
      tester
          .getSemantics(
            find.byKey(const ValueKey('change-tile-staged-first.dart')),
          )
          .flagsCollection
          .isSelected,
      Tristate.isFalse,
    );
    expect(
      tester
          .getSemantics(
            find.byKey(const ValueKey('change-tile-staged-second.dart')),
          )
          .flagsCollection
          .isSelected,
      Tristate.isTrue,
    );
  });

  testWidgets('workspace windows do not restore the global repository list', (
    tester,
  ) async {
    final store = _CountingSessionStore();
    final container = ProviderContainer(
      overrides: [repositorySessionStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const GitDesktopApp(isWorkspaceWindow: true),
      ),
    );
    await tester.pump();

    expect(store.loadCount, 0);
    expect(container.read(repositoryLibraryProvider).repositories, isEmpty);
    expect(find.byKey(const ValueKey('theme-menu-button')), findsOneWidget);
  });

  testWidgets('switches and persists shared theme preferences', (tester) async {
    final store = _MemoryThemePreferencesStore();
    final container = ProviderContainer(
      overrides: [
        gitDesktopThemePreferencesStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const GitDesktopApp(),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('theme-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('theme-mode-dark')));
    await tester.pumpAndSettle();
    final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(materialApp.themeMode, ThemeMode.dark);
    expect(store.saved.last.mode, ThemeMode.dark);
  });

  testWidgets('groups, filters and opens local repositories on double-click', (
    tester,
  ) async {
    String? selectedPath;
    List<String>? reorderedPaths;
    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryLibraryPage(
          repositories: const [
            RepositoryLibraryItem(path: '/work/alpha/api', label: 'api'),
            RepositoryLibraryItem(path: '/work/beta/app', label: 'app'),
            RepositoryLibraryItem(path: '/work/alpha/web', label: 'web'),
          ],
          activePath: '/work/alpha/web',
          onRepositorySelected: (path) async => selectedPath = path,
          onRepositoriesReordered: (paths) => reorderedPaths = paths,
        ),
      ),
    );

    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('beta'), findsOneWidget);
    expect(find.text('当前'), findsOneWidget);
    final filter = tester.widget<TextField>(find.byType(TextField));
    expect(filter.textAlignVertical, TextAlignVertical.center);
    expect(
      filter.decoration!.prefixIconConstraints,
      const BoxConstraints.tightFor(width: 38, height: 36),
    );
    expect(find.byTooltip('拖动以排序'), findsNWidgets(3));

    await tester.enterText(find.byType(TextField), 'web');
    await tester.pumpAndSettle();
    expect(find.text('api'), findsNothing);
    expect(find.text('web'), findsAtLeastNWidgets(1));
    expect(find.byTooltip('拖动以排序'), findsNothing);

    await tester.tap(
      find.byKey(
        const ValueKey<String>('repository-library-tile:/work/alpha/web'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));
    expect(selectedPath, isNull);

    final tile = find.byKey(
      const ValueKey<String>('repository-library-tile:/work/alpha/web'),
    );
    await tester.tap(tile);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(tile);
    await tester.pump();
    expect(selectedPath, '/work/alpha/web');
    expect(reorderedPaths, isNull);
    await tester.pumpAndSettle();
  });

  testWidgets(
    'keeps equal parent basenames separate and supports keyboard open',
    (tester) async {
      String? selectedPath;
      await tester.pumpWidget(
        MaterialApp(
          home: RepositoryLibraryPage(
            repositories: const [
              RepositoryLibraryItem(path: '/work/team/repo-a', label: 'repo-a'),
              RepositoryLibraryItem(
                path: '/archive/team/repo-b',
                label: 'repo-b',
              ),
            ],
            activePath: null,
            onRepositorySelected: (path) async => selectedPath = path,
            onRepositoriesReordered: (_) {},
          ),
        ),
      );

      expect(find.text('/work/team'), findsOneWidget);
      expect(find.text('/archive/team'), findsOneWidget);
      final tile = find.byKey(
        const ValueKey<String>('repository-library-tile:/work/team/repo-a'),
      );
      await tester.tap(tile);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(selectedPath, '/work/team/repo-a');

      selectedPath = null;
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(selectedPath, '/work/team/repo-a');
      await tester.pumpAndSettle();
    },
  );

  test('uses icon.png at the repository root as the custom icon path', () {
    const RepositoryLibraryItem repository = RepositoryLibraryItem(
      path: '/work/alpha/sample',
      label: 'sample',
    );

    expect(repository.iconPath, '/work/alpha/sample/icon.png');
  });

  test('bounds the custom repository icon decode dimensions', () {
    expect(repositoryLibraryIconCacheDimension(1), 36);
    expect(repositoryLibraryIconCacheDimension(2), 72);
    expect(repositoryLibraryIconCacheDimension(8), 144);
  });

  testWidgets('shows branch and changed-file status in the library row', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryLibraryPage(
          repositories: const [
            RepositoryLibraryItem(
              path: '/work/alpha/sample',
              label: 'sample',
              branchName: 'feature/library-status',
              changedFileCount: 3,
              hasStatus: true,
            ),
          ],
          activePath: null,
          onRepositorySelected: (path) async {},
        ),
      ),
    );

    expect(find.text('feature/library-status'), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey<String>(
          'repository-library-change-count:/work/alpha/sample',
        ),
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('当前分支 feature/library-status'), findsOneWidget);
  });

  testWidgets('routes sequential AskPass requests through the controlled UI', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const GitDesktopApp(isWorkspaceWindow: true),
      ),
    );

    final answer = container
        .read(gitAskPassPromptCoordinatorProvider.notifier)
        .request(
          GitAskPassRequest.decode(
            '{"nonce":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","prompt":"Password for https://example.test:"}',
          ),
        );
    await tester.pumpAndSettle();

    expect(find.text('需要密码'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'not-retained');
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();

    expect(await answer, 'not-retained');
    expect(container.read(gitAskPassPromptCoordinatorProvider), isNull);

    final usernameAnswer = container
        .read(gitAskPassPromptCoordinatorProvider.notifier)
        .request(
          GitAskPassRequest.decode(
            '{"nonce":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","prompt":"Username for https://example.test:"}',
          ),
        );
    await tester.pumpAndSettle();
    expect(find.text('需要用户名'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'git-user');
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    expect(await usernameAnswer, 'git-user');
  });

  testWidgets('dismisses the AskPass UI when its operation is cancelled', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const GitDesktopApp(isWorkspaceWindow: true),
      ),
    );

    final coordinator = container.read(
      gitAskPassPromptCoordinatorProvider.notifier,
    );
    final answer = coordinator.request(
      GitAskPassRequest.decode(
        '{"nonce":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","prompt":"Password:"}',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('需要密码'), findsOneWidget);

    coordinator.cancel();
    await tester.pumpAndSettle();

    expect(find.text('需要密码'), findsNothing);
    expect(await answer, isNull);
  });

  testWidgets(
    'keeps workspace controls in the Git toolbar without a tab strip',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: RepositoryOverview(
            data: RepositoryOverviewViewData.ready(
              const RepositoryViewData(
                name: 'example',
                path: '/tmp/example',
                currentBranch: 'main',
              ),
            ),
            toolbarTrailing: IconButton(
              key: const ValueKey('workspace-settings'),
              onPressed: () {},
              icon: const Icon(Icons.settings_outlined),
            ),
          ),
        ),
      );

      expect(find.byKey(const ValueKey('repository-toolbar')), findsOneWidget);
      expect(find.byKey(const ValueKey('workspace-settings')), findsOneWidget);
      expect(find.byKey(const ValueKey('repository-tab-strip')), findsNothing);
    },
  );

  testWidgets('history search keeps focus while its query updates', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var query = '';
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => RepositoryOverview(
            data: RepositoryOverviewViewData.ready(
              RepositoryViewData(
                name: 'example',
                path: '/tmp/example',
                currentBranch: 'main',
                commits: const [
                  CommitViewData(
                    oid: '0123456789abcdef',
                    shortOid: '01234567',
                    subject: 'Initial commit',
                    author: 'Test',
                    relativeDate: '刚刚',
                  ),
                ],
                searchQuery: query,
              ),
            ),
            callbacks: RepositoryOverviewCallbacks(
              onSearchChanged: (value) => setState(() => query = value),
            ),
          ),
        ),
      ),
    );

    final graphCanvas = find.byKey(
      const ValueKey<String>('commit-graph-canvas'),
    );
    expect(graphCanvas, findsOneWidget);
    expect(tester.getSize(graphCanvas).width, 96);
    expect(tester.getSize(graphCanvas).height, greaterThan(0));

    final field = find.byType(TextFormField);
    final splitBar = find.byKey(const ValueKey<String>('history-split-bar'));
    final searchSlot = find.byKey(
      const ValueKey<String>('history-search-slot'),
    );
    final commitAction = find.byKey(
      const ValueKey<String>('repository-action-commit'),
    );

    expect(splitBar, findsOneWidget);
    expect(searchSlot, findsOneWidget);
    expect(commitAction, findsOneWidget);
    expect(
      tester.getCenter(searchSlot).dx,
      greaterThan(tester.getCenter(splitBar).dx),
    );
    expect(
      tester.getTopLeft(commitAction).dy,
      lessThan(tester.getTopLeft(splitBar).dy),
    );

    await tester.tap(field);
    await tester.enterText(field, 'initial');
    await tester.pump();

    expect(tester.binding.focusManager.primaryFocus?.hasFocus, isTrue);
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).controller.text,
      'initial',
    );
  });

  testWidgets('loads more history from the list footer', (tester) async {
    var loadMoreCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'example',
              path: '/tmp/example',
              currentBranch: 'main',
              hasMoreHistory: true,
              commits: const [
                CommitViewData(
                  oid: '0123456789abcdef',
                  shortOid: '01234567',
                  subject: 'Initial commit',
                  author: 'Test',
                  relativeDate: '刚刚',
                ),
              ],
            ),
          ),
          callbacks: RepositoryOverviewCallbacks(
            onLoadMoreHistory: () => loadMoreCalls++,
          ),
        ),
      ),
    );

    expect(find.text('加载更多提交'), findsOneWidget);
    await tester.tap(find.text('加载更多提交'));
    expect(loadMoreCalls, 1);
  });

  testWidgets('keeps load more available when filtered commits are empty', (
    tester,
  ) async {
    var loadMoreCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: const RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'example',
              path: '/tmp/example',
              currentBranch: 'main',
              searchQuery: 'older matching commit',
              hasMoreHistory: true,
            ),
          ),
          callbacks: RepositoryOverviewCallbacks(
            onLoadMoreHistory: () => loadMoreCalls++,
          ),
        ),
      ),
    );

    expect(find.text('加载更多提交'), findsOneWidget);
    expect(find.text('暂无提交'), findsNothing);
    await tester.tap(find.text('加载更多提交'));
    expect(loadMoreCalls, 1);
  });

  testWidgets('branch context menu exposes checkout and merge actions', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    RepositoryRefViewData? selectedReference;
    RepositoryRefContextAction? selectedAction;
    const featureBranch = RepositoryRefViewData(
      id: 'local:feature/menu',
      label: 'feature/menu',
      kind: RepositoryRefKind.localBranch,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'example',
              path: '/tmp/example',
              currentBranch: 'main',
              isWorkingTreeClean: false,
              changes: [
                const RepositoryChangeViewData(
                  path: 'untracked.txt',
                  kind: RepositoryChangeKind.untracked,
                ),
              ],
              refs: const [
                RepositoryRefViewData(
                  id: 'local:main',
                  label: 'main',
                  kind: RepositoryRefKind.localBranch,
                  isCurrent: true,
                ),
                featureBranch,
              ],
            ),
          ),
          callbacks: RepositoryOverviewCallbacks(
            onRefContextAction: (reference, action) {
              selectedReference = reference;
              selectedAction = action;
            },
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('menu')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('切换到此分支'), findsOneWidget);
    expect(find.text('合并到当前分支'), findsOneWidget);
    expect(find.text('从此分支创建新分支'), findsOneWidget);
    expect(find.text('重命名分支'), findsOneWidget);
    expect(find.text('删除分支'), findsOneWidget);
    expect(
      tester
          .widget<PopupMenuItem<RepositoryRefContextAction>>(
            find.widgetWithText(
              PopupMenuItem<RepositoryRefContextAction>,
              '切换到此分支',
            ),
          )
          .enabled,
      isTrue,
    );
    expect(
      tester
          .widget<PopupMenuItem<RepositoryRefContextAction>>(
            find.widgetWithText(
              PopupMenuItem<RepositoryRefContextAction>,
              '重命名分支',
            ),
          )
          .enabled,
      isTrue,
    );
    expect(
      tester
          .widget<PopupMenuItem<RepositoryRefContextAction>>(
            find.widgetWithText(
              PopupMenuItem<RepositoryRefContextAction>,
              '删除分支',
            ),
          )
          .enabled,
      isTrue,
    );

    await tester.tap(find.text('合并到当前分支'));
    await tester.pumpAndSettle();

    expect(selectedReference, featureBranch);
    expect(selectedAction, RepositoryRefContextAction.mergeIntoCurrent);
  });

  testWidgets('rename branch dialog selects the current branch name', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<String>(
              context: context,
              builder: (context) =>
                  const RenameBranchDialog(oldName: 'feature/menu'),
            ),
            child: const Text('打开重命名'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开重命名'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byKey(const ValueKey<String>('rename-branch-dialog')),
      findsOneWidget,
    );
    expect(find.text('新分支名称：'), findsOneWidget);
    final renameField = tester.widget<TextFormField>(
      find.byKey(const ValueKey<String>('rename-branch-name')),
    );
    expect(renameField.controller!.text, 'feature/menu');
    expect(renameField.controller!.selection.start, 0);
    expect(
      renameField.controller!.selection.end,
      renameField.controller!.text.length,
    );
  });

  testWidgets('delete branch dialog exposes explicit deletion scopes', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<DeleteLocalBranchDialogResult>(
              context: context,
              builder: (context) => const DeleteLocalBranchDialog(
                branchName: 'feature/menu',
                remoteBranchName: null,
              ),
            ),
            child: const Text('打开删除'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开删除'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byKey(const ValueKey<String>('delete-branch-dialog')),
      findsOneWidget,
    );
    expect(find.text('您确定要删除以下分支吗？'), findsOneWidget);
    expect(find.text('强制删除'), findsOneWidget);
    final remoteDelete = tester.widget<CheckboxListTile>(
      find.byKey(const ValueKey<String>('delete-branch-remote')),
    );
    expect(remoteDelete.onChanged, isNull);
    await tester.tap(find.byKey(const ValueKey<String>('delete-branch-force')));
    await tester.pump();
    expect(find.textContaining('未合并提交可能无法再通过分支引用找回'), findsOneWidget);
  });

  testWidgets('commit context menu restores supported history actions', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    CommitViewData? selectedCommit;
    RepositoryCommitContextAction? selectedAction;
    const commit = CommitViewData(
      oid: '4f5e6b7c8d9e0f1a2b3c4d5e6f708192a3b4c5d6',
      shortOid: '4f5e6b7c',
      subject: 'Release candidate',
      author: 'tester',
      relativeDate: '今天',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: const RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'example',
              path: '/tmp/example',
              currentBranch: 'main',
              isWorkingTreeClean: true,
              commits: [commit],
            ),
          ),
          callbacks: RepositoryOverviewCallbacks(
            onCommitContextAction: (nextCommit, action) {
              selectedCommit = nextCommit;
              selectedAction = action;
            },
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Release candidate')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('检出…'), findsOneWidget);
    expect(find.text('合并…'), findsOneWidget);
    expect(find.text('标签…'), findsOneWidget);
    expect(find.text('分支…'), findsOneWidget);
    expect(find.text('复制 SHA-1 到剪贴板'), findsOneWidget);
    for (final label in const [
      '推送修订版本…',
      '变基…',
      '交互式变基…',
      '将当前分支重置到此次提交',
      '提交回滚',
      '创建补丁…',
      '遴选',
    ]) {
      expect(find.text(label), findsOneWidget);
      expect(
        tester
            .widget<PopupMenuItem<RepositoryCommitContextAction>>(
              find.widgetWithText(
                PopupMenuItem<RepositoryCommitContextAction>,
                label,
              ),
            )
            .enabled,
        isTrue,
      );
    }

    await tester.tap(find.text('标签…'));
    await tester.pumpAndSettle();

    expect(selectedCommit, commit);
    expect(selectedAction, RepositoryCommitContextAction.tag);
  });

  testWidgets('repository operation disables commit mutation actions', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const commit = CommitViewData(
      oid: '4f5e6b7c8d9e0f1a2b3c4d5e6f708192a3b4c5d6',
      shortOid: '4f5e6b7c',
      subject: 'Paused operation',
      author: 'tester',
      relativeDate: '今天',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: const RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'example',
              path: '/tmp/example',
              currentBranch: 'main',
              isRebaseInProgress: true,
              commits: [commit],
            ),
          ),
          callbacks: RepositoryOverviewCallbacks(
            onCommitActivated: (_) {},
            onCommitContextAction: (_, _) {},
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Paused operation')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    for (final label in ['检出…', '合并…', '变基…', '将当前分支重置到此次提交', '遴选']) {
      final item = tester.widget<PopupMenuItem<RepositoryCommitContextAction>>(
        find.widgetWithText(
          PopupMenuItem<RepositoryCommitContextAction>,
          label,
        ),
      );
      expect(item.enabled, isFalse, reason: label);
    }
    expect(
      tester
          .widget<PopupMenuItem<RepositoryCommitContextAction>>(
            find.widgetWithText(
              PopupMenuItem<RepositoryCommitContextAction>,
              '复制 SHA-1 到剪贴板',
            ),
          )
          .enabled,
      isTrue,
    );
  });

  testWidgets('paused operation disables reference refresh and checkout', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    RepositoryRefViewData? activatedRef;
    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: const RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'example',
              path: '/tmp/example',
              currentBranch: 'main',
              isMergeInProgress: true,
              disabledActions: {RepositoryAction.refresh},
              refs: [
                RepositoryRefViewData(
                  id: 'refs/heads/feature/nested',
                  label: 'feature/nested',
                  kind: RepositoryRefKind.localBranch,
                ),
              ],
            ),
          ),
          callbacks: RepositoryOverviewCallbacks(
            onRefActivated: (ref) => activatedRef = ref,
            onRefContextAction: (_, _) {},
          ),
        ),
      ),
    );
    await tester.tap(find.text('nested'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('nested'));
    await tester.pumpAndSettle();
    expect(activatedRef, isNull);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('nested')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    for (final label in ['切换到此分支', '刷新仓库']) {
      expect(
        tester
            .widget<PopupMenuItem<RepositoryRefContextAction>>(
              find.widgetWithText(
                PopupMenuItem<RepositoryRefContextAction>,
                label,
              ),
            )
            .enabled,
        isFalse,
      );
    }
  });

  testWidgets('single-click selects a branch and double-click activates it', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    RepositoryRefViewData? selectedReference;
    RepositoryRefViewData? activatedReference;
    const featureBranch = RepositoryRefViewData(
      id: 'refs/heads/feature/select',
      label: 'feature/select',
      kind: RepositoryRefKind.localBranch,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'example',
              path: '/tmp/example',
              currentBranch: 'main',
              refs: const [
                RepositoryRefViewData(
                  id: 'refs/heads/main',
                  label: 'main',
                  kind: RepositoryRefKind.localBranch,
                  isCurrent: true,
                ),
                featureBranch,
              ],
            ),
          ),
          callbacks: RepositoryOverviewCallbacks(
            onRefSelected: (reference) => selectedReference = reference,
            onRefActivated: (reference) => activatedReference = reference,
            onRefContextAction: (_, _) {},
          ),
        ),
      ),
    );

    final feature = find.text('select');
    await tester.tap(feature);
    await tester.pumpAndSettle();

    expect(selectedReference, featureBranch);
    expect(activatedReference, isNull);
    final selectedTile = find.ancestor(
      of: feature,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Container &&
            widget.constraints?.minHeight == 31 &&
            widget.constraints?.maxHeight == 31,
      ),
    );
    expect(tester.widget<Container>(selectedTile).color, isNotNull);

    await tester.tap(feature);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(feature);
    await tester.pumpAndSettle();

    expect(activatedReference, featureBranch);

    activatedReference = null;
    final shortcuts = tester.widget<CallbackShortcuts>(
      find
          .ancestor(of: feature, matching: find.byType(CallbackShortcuts))
          .first,
    );
    shortcuts.bindings[const SingleActivator(LogicalKeyboardKey.enter)]!();
    expect(activatedReference, featureBranch);
    final refSemantics = tester
        .getSemantics(find.bySemanticsLabel('分支 select'))
        .getSemanticsData();
    expect(refSemantics.hasAction(SemanticsAction.longPress), isTrue);
    shortcuts.bindings[const SingleActivator(
      LogicalKeyboardKey.f10,
      shift: true,
    )]!();
    await tester.pumpAndSettle();
    expect(find.text('切换到此分支'), findsOneWidget);
  });

  testWidgets('renders slash-delimited branches as a collapsible directory', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: RepositoryOverview(
          data: RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'example',
              path: '/tmp/example',
              currentBranch: 'Detached HEAD',
              primaryLocalBranch: 'main',
              isDetachedHead: true,
              refs: [
                RepositoryRefViewData(
                  id: 'HEAD',
                  label: 'HEAD',
                  kind: RepositoryRefKind.localBranch,
                  isCurrent: true,
                ),
                RepositoryRefViewData(
                  id: 'refs/heads/codex/conflict-demo',
                  label: 'codex/conflict-demo',
                  kind: RepositoryRefKind.localBranch,
                ),
                RepositoryRefViewData(
                  id: 'refs/heads/main',
                  label: 'main',
                  kind: RepositoryRefKind.localBranch,
                ),
                RepositoryRefViewData(
                  id: 'refs/heads/release',
                  label: 'release',
                  kind: RepositoryRefKind.localBranch,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.text('codex'), findsOneWidget);
    expect(find.text('conflict-demo'), findsOneWidget);
    expect(find.text('codex/conflict-demo'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('ref-directory:codex')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Icon>(find.byKey(const ValueKey<String>('ref-nav-icon:HEAD')))
          .color,
      const Color(0xFFF28C00),
    );
    expect(
      tester
          .widget<Icon>(
            find.byKey(
              const ValueKey<String>(
                'ref-nav-icon:refs/heads/codex/conflict-demo',
              ),
            ),
          )
          .color,
      const Color(0xFFF28C00),
    );
    expect(
      tester
          .widget<Icon>(
            find.byKey(const ValueKey<String>('ref-nav-icon:refs/heads/main')),
          )
          .color,
      const Color(0xFF0B6FCB),
    );
    expect(
      tester
          .widget<Icon>(
            find.byKey(
              const ValueKey<String>('ref-nav-icon:refs/heads/release'),
            ),
          )
          .color,
      const Color(0xFF2FA86F),
    );

    await tester.tap(find.text('codex'));
    await tester.pumpAndSettle();

    expect(find.text('conflict-demo'), findsNothing);
  });

  testWidgets('double-clicking a commit requests checkout activation', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    CommitViewData? activatedCommit;
    const commit = CommitViewData(
      oid: '4f5e6b7c8d9e0f1a2b3c4d5e6f708192a3b4c5d6',
      shortOid: '4f5e6b7c',
      subject: '测试提交',
      author: 'tester',
      relativeDate: '今天',
      refs: ['HEAD'],
      isHead: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: const RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'example',
              path: '/tmp/example',
              currentBranch: 'main',
              headOid: '4f5e6b7c8d9e0f1a2b3c4d5e6f708192a3b4c5d6',
              isDetachedHead: true,
              refs: [
                RepositoryRefViewData(
                  id: 'HEAD',
                  label: 'HEAD',
                  kind: RepositoryRefKind.localBranch,
                  isCurrent: true,
                ),
              ],
              commits: [commit],
            ),
          ),
          callbacks: RepositoryOverviewCallbacks(
            onCommitActivated: (value) => activatedCommit = value,
            onCommitContextAction: (_, _) {},
          ),
        ),
      ),
    );

    expect(find.text('HEAD'), findsNWidgets(2));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('commit-ref-HEAD')),
        matching: find.byIcon(Icons.sell_outlined),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('测试提交'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('测试提交'));
    await tester.pumpAndSettle();

    expect(activatedCommit, commit);

    activatedCommit = null;
    final commitShortcuts = tester.widget<CallbackShortcuts>(
      find
          .ancestor(
            of: find.text('测试提交'),
            matching: find.byType(CallbackShortcuts),
          )
          .first,
    );
    commitShortcuts.bindings[const SingleActivator(
      LogicalKeyboardKey.enter,
    )]!();
    expect(activatedCommit, commit);
    final commitSemantics = tester
        .getSemantics(find.bySemanticsLabel(RegExp('提交 4f5e6b7c')))
        .getSemanticsData();
    expect(commitSemantics.hasAction(SemanticsAction.longPress), isTrue);
    commitShortcuts.bindings[const SingleActivator(
      LogicalKeyboardKey.contextMenu,
    )]!();
    await tester.pumpAndSettle();
    expect(find.text('检出…'), findsOneWidget);
  });

  testWidgets(
    'keeps history rows readable while resizing columns from body handles',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      const commit = CommitViewData(
        oid: '4f5e6b7c8d9e0f1a2b3c4d5e6f708192a3b4c5d6',
        shortOid: '4f5e6b7c',
        subject: '测试提交',
        author: 'tester',
        relativeDate: '今天',
        refs: ['main', 'origin/main', 'feature/very-long-name'],
        remoteRefs: ['origin/main'],
        isHead: true,
        isMerge: true,
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: RepositoryOverview(
            data: RepositoryOverviewViewData.ready(
              RepositoryViewData(
                name: 'example',
                path: '/tmp/example',
                currentBranch: 'main',
                headOid: '4f5e6b7c8d9e0f1a2b3c4d5e6f708192a3b4c5d6',
                refs: [
                  RepositoryRefViewData(
                    id: 'main',
                    label: 'main',
                    kind: RepositoryRefKind.localBranch,
                    isCurrent: true,
                  ),
                ],
                commits: [commit],
              ),
            ),
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey<String>('history-column-header')),
        findsOneWidget,
      );
      expect(find.text('当前分支'), findsNothing);
      final historyHeader = find.byKey(
        const ValueKey<String>('history-column-header'),
      );
      for (final label in const ['图表', '描述', '提交', '作者', '日期']) {
        expect(
          find.descendant(of: historyHeader, matching: find.text(label)),
          findsOneWidget,
        );
      }
      expect(
        tester
            .widget<Text>(
              find.descendant(of: historyHeader, matching: find.text('日期')),
            )
            .textAlign,
        TextAlign.start,
      );
      expect(tester.widget<Text>(find.text('今天')).textAlign, TextAlign.start);

      final graphCanvas = find.byKey(
        const ValueKey<String>('commit-graph-canvas'),
      );
      expect(tester.getSize(graphCanvas).height, closeTo(24, 1));
      final historyRow = find
          .ancestor(of: graphCanvas, matching: find.byType(Container))
          .first;
      expect(tester.widget<Container>(historyRow).decoration, isNull);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('commit-ref-main')),
          matching: find.byIcon(Icons.call_split),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('commit-ref-origin/main')),
          matching: find.byIcon(Icons.cloud_outlined),
        ),
        findsOneWidget,
      );

      for (final label in const ['调整图表列宽度', '调整描述列宽度', '调整提交列宽度', '调整作者列宽度']) {
        final divider = find.bySemanticsLabel(label);
        expect(divider, findsOneWidget);
        final semantics = tester.getSemantics(divider).getSemanticsData();
        expect(semantics.hasAction(SemanticsAction.increase), isTrue);
        expect(semantics.hasAction(SemanticsAction.decrease), isTrue);
        final before = tester.getCenter(divider).dx;
        await tester.drag(divider, const Offset(20, 0));
        await tester.pump();
        expect(tester.getCenter(divider).dx, greaterThan(before));
        final primary = Theme.of(tester.element(divider)).colorScheme.primary;
        expect(
          find.descendant(
            of: divider,
            matching: find.byWidgetPredicate(
              (widget) => widget is Container && widget.color == primary,
            ),
          ),
          findsOneWidget,
        );
        final afterDrag = tester.getCenter(divider).dx;
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(tester.getCenter(divider).dx, greaterThan(afterDrag));
      }

      final descriptionDivider = find.bySemanticsLabel('调整描述列宽度');
      final beforeCompression = tester.getCenter(descriptionDivider).dx;
      await tester.drag(descriptionDivider, const Offset(-1500, 0));
      await tester.pump();
      expect(
        tester.getCenter(descriptionDivider).dx,
        lessThan(beforeCompression - 200),
      );
    },
  );

  testWidgets('reuses the history table with workflow-local multi-selection', (
    tester,
  ) async {
    const first = CommitViewData(
      oid: '1111111111111111111111111111111111111111',
      shortOid: '11111111',
      subject: 'First patch commit',
      author: 'tester',
      relativeDate: '今天',
    );
    const second = CommitViewData(
      oid: '2222222222222222222222222222222222222222',
      shortOid: '22222222',
      subject: 'Second patch commit',
      author: 'tester',
      relativeDate: '昨天',
    );
    CommitViewData? tapped;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 900,
          height: 500,
          child: RepositoryHistoryPane(
            repository: const RepositoryViewData(
              name: 'example',
              path: '/tmp/example',
              currentBranch: 'main',
              commits: [first, second],
            ),
            selectedCommitIds: const {
              '1111111111111111111111111111111111111111',
              '2222222222222222222222222222222222222222',
            },
            showPaneHeader: false,
            includeUncommittedChanges: false,
            onSelected: (commit) => tapped = commit,
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('history-column-header')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('commit-graph-canvas')),
      findsNWidgets(2),
    );
    expect(find.text('历史'), findsNothing);

    await tester.tap(find.text('Second patch commit'));
    await tester.pump();
    expect(tapped, second);
  });

  testWidgets('renders commit tags with the tag icon instead of branch icon', (
    tester,
  ) async {
    const commit = CommitViewData(
      oid: '4f5e6b7c8d9e0f1a2b3c4d5e6f708192a3b4c5d6',
      shortOid: '4f5e6b7c',
      subject: '测试标签图标',
      author: 'tester',
      relativeDate: '今天',
      references: [
        CommitReferenceViewData(
          label: 'testtag',
          kind: CommitReferenceKind.tag,
        ),
      ],
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: RepositoryOverview(
          data: RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'example',
              path: '/tmp/example',
              currentBranch: 'main',
              commits: [commit],
            ),
          ),
        ),
      ),
    );

    final tagLabel = find.byKey(const ValueKey<String>('commit-ref-testtag'));
    expect(tagLabel, findsOneWidget);
    expect(
      find.descendant(of: tagLabel, matching: find.byIcon(Icons.sell_outlined)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tagLabel, matching: find.byIcon(Icons.call_split)),
      findsNothing,
    );
  });

  testWidgets('keeps same-named commit branches and tags distinct', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const commit = CommitViewData(
      oid: '4f5e6b7c8d9e0f1a2b3c4d5e6f708192a3b4c5d6',
      shortOid: '4f5e6b7c',
      subject: '同名引用',
      author: 'tester',
      relativeDate: '今天',
      references: [
        CommitReferenceViewData(
          label: 'v1.0.0',
          kind: CommitReferenceKind.localBranch,
        ),
        CommitReferenceViewData(label: 'v1.0.0', kind: CommitReferenceKind.tag),
      ],
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: RepositoryOverview(
          data: RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'example',
              path: '/tmp/example',
              currentBranch: 'main',
              commits: [commit],
            ),
          ),
        ),
      ),
    );

    final sameNamedReferences = find.byKey(
      const ValueKey<String>('commit-ref-v1.0.0'),
    );
    expect(sameNamedReferences, findsNWidgets(2));
    expect(
      find.descendant(
        of: sameNamedReferences,
        matching: find.byIcon(Icons.call_split),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: sameNamedReferences,
        matching: find.byIcon(Icons.sell_outlined),
      ),
      findsOneWidget,
    );
  });

  testWidgets('shows side-branch commits after removing the scope toolbar', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const baseOid = '1111111111111111111111111111111111111111';
    const headOid = '2222222222222222222222222222222222222222';
    const sideOid = '3333333333333333333333333333333333333333';
    await tester.pumpWidget(
      const MaterialApp(
        home: RepositoryOverview(
          data: RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'example',
              path: '/tmp/example',
              currentBranch: 'Detached HEAD',
              primaryLocalBranch: 'main',
              headOid: headOid,
              ahead: 3,
              isDetachedHead: true,
              commits: [
                CommitViewData(
                  oid: headOid,
                  shortOid: '22222222',
                  subject: 'main tip',
                  author: 'tester',
                  relativeDate: '刚刚',
                  refs: ['main'],
                  parents: [baseOid],
                ),
                CommitViewData(
                  oid: sideOid,
                  shortOid: '33333333',
                  subject: 'side branch tip',
                  author: 'tester',
                  relativeDate: '刚刚',
                  refs: ['codex/conflict-demo'],
                  parents: [baseOid],
                ),
                CommitViewData(
                  oid: baseOid,
                  shortOid: '11111111',
                  subject: 'shared base',
                  author: 'tester',
                  relativeDate: '昨天',
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.text('main tip'), findsOneWidget);
    expect(find.text('side branch tip'), findsOneWidget);
    expect(find.text('shared base'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('commit-graph-canvas')),
      findsNWidgets(3),
    );
    final mainRef = find.byKey(const ValueKey<String>('commit-ref-main'));
    final conflictRef = find.byKey(
      const ValueKey<String>('commit-ref-codex/conflict-demo'),
    );
    final mainDecoration = tester.widget<Container>(mainRef).decoration!;
    final conflictDecoration = tester
        .widget<Container>(conflictRef)
        .decoration!;
    expect(mainDecoration, isA<BoxDecoration>());
    expect(conflictDecoration, isA<BoxDecoration>());
    expect(
      (mainDecoration as BoxDecoration).color,
      isNot((conflictDecoration as BoxDecoration).color),
    );
    expect(
      ((mainDecoration.border! as Border).top).color,
      const Color(0xFF0B6FCB),
    );
    expect(
      ((conflictDecoration.border! as Border).top).color,
      const Color(0xFFF28C00),
    );
    expect(find.text('超前3个版本'), findsOneWidget);
    expect(tester.getSize(conflictRef).width, greaterThan(100));
  });

  testWidgets('matches nested branch labels to stable graph lane colors', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: RepositoryOverview(
          data: RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'graph-demo',
              path: '/tmp/graph-demo',
              currentBranch: 'main',
              primaryLocalBranch: 'main',
              headOid: 'merge-ui',
              commits: [
                CommitViewData(
                  oid: 'merge-ui',
                  shortOid: 'merge-ui',
                  subject: 'merge UI',
                  author: 'tester',
                  relativeDate: '刚刚',
                  refs: ['main'],
                  parents: ['merge-foundation', 'ui-merge'],
                ),
                CommitViewData(
                  oid: 'ui-merge',
                  shortOid: 'ui-merge',
                  subject: 'merge docs into UI',
                  author: 'tester',
                  relativeDate: '刚刚',
                  refs: ['demo/graph-ui'],
                  parents: ['ui', 'docs'],
                ),
                CommitViewData(
                  oid: 'docs',
                  shortOid: 'docs',
                  subject: 'docs node',
                  author: 'tester',
                  relativeDate: '刚刚',
                  refs: ['demo/graph-docs'],
                  parents: ['foundation-base'],
                ),
                CommitViewData(
                  oid: 'ui',
                  shortOid: 'ui',
                  subject: 'UI node',
                  author: 'tester',
                  relativeDate: '刚刚',
                  parents: ['foundation-base'],
                ),
                CommitViewData(
                  oid: 'merge-foundation',
                  shortOid: 'merge-f',
                  subject: 'merge foundation',
                  author: 'tester',
                  relativeDate: '刚刚',
                  parents: ['old-main', 'foundation-merge'],
                ),
                CommitViewData(
                  oid: 'foundation-merge',
                  shortOid: 'found-m',
                  subject: 'merge API into foundation',
                  author: 'tester',
                  relativeDate: '刚刚',
                  refs: ['demo/graph-foundation'],
                  parents: ['foundation-base', 'api-2'],
                ),
                CommitViewData(
                  oid: 'api-2',
                  shortOid: 'api-2',
                  subject: 'API two',
                  author: 'tester',
                  relativeDate: '刚刚',
                  refs: ['demo/graph-api'],
                  parents: ['api-1'],
                ),
                CommitViewData(
                  oid: 'api-1',
                  shortOid: 'api-1',
                  subject: 'API one',
                  author: 'tester',
                  relativeDate: '刚刚',
                  parents: ['foundation-base'],
                ),
                CommitViewData(
                  oid: 'foundation-base',
                  shortOid: 'found-b',
                  subject: 'foundation base',
                  author: 'tester',
                  relativeDate: '刚刚',
                  parents: ['old-main'],
                ),
                CommitViewData(
                  oid: 'old-main',
                  shortOid: 'old-main',
                  subject: 'old main',
                  author: 'tester',
                  relativeDate: '刚刚',
                ),
              ],
            ),
          ),
        ),
      ),
    );

    Color borderColor(String ref) {
      final decoration =
          tester
                  .widget<Container>(
                    find.byKey(ValueKey<String>('commit-ref-$ref')),
                  )
                  .decoration!
              as BoxDecoration;
      return (decoration.border! as Border).top.color;
    }

    expect(borderColor('main'), const Color(0xFF0B6FCB));
    expect(borderColor('demo/graph-ui'), const Color(0xFFF28C00));
    expect(borderColor('demo/graph-docs'), const Color(0xFFD8452A));
    expect(borderColor('demo/graph-foundation'), const Color(0xFF2FA86F));
    expect(borderColor('demo/graph-api'), const Color(0xFF6254B8));
  });

  testWidgets('keeps loaded history visible when the current tip is absent', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const older = CommitViewData(
      oid: '1111111111111111111111111111111111111111',
      shortOid: '11111111',
      subject: '历史提交',
      author: 'tester',
      relativeDate: '昨天',
    );
    const newer = CommitViewData(
      oid: '2222222222222222222222222222222222222222',
      shortOid: '22222222',
      subject: '最近提交',
      author: 'tester',
      relativeDate: '今天',
      parents: ['1111111111111111111111111111111111111111'],
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: RepositoryOverview(
          data: RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'example',
              path: '/tmp/example',
              currentBranch: 'main',
              headOid: 'missing',
              commits: [newer, older],
            ),
          ),
        ),
      ),
    );

    expect(find.text('最近提交'), findsOneWidget);
    expect(find.text('历史提交'), findsOneWidget);
  });

  testWidgets('external refresh resets the locally highlighted reference', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var selectedRefId = 'workspace';
    var selectionCount = 0;
    late StateSetter rebuild;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return RepositoryOverview(
              data: RepositoryOverviewViewData.ready(
                RepositoryViewData(
                  name: 'example',
                  path: '/tmp/example',
                  currentBranch: 'main',
                  refs: [
                    RepositoryRefViewData(
                      id: 'workspace',
                      label: '文件状态',
                      kind: RepositoryRefKind.workspace,
                      isSelected: selectedRefId == 'workspace',
                    ),
                    RepositoryRefViewData(
                      id: 'refs/heads/feature/refresh',
                      label: 'feature/refresh',
                      kind: RepositoryRefKind.localBranch,
                      isSelected: selectedRefId == 'refs/heads/feature/refresh',
                    ),
                  ],
                ),
              ),
              callbacks: RepositoryOverviewCallbacks(
                onRefSelected: (reference) {
                  selectionCount++;
                  setState(() => selectedRefId = reference.id);
                },
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('refresh'));
    await tester.pumpAndSettle();
    expect(selectionCount, 1);

    rebuild(() => selectedRefId = 'workspace');
    await tester.pumpAndSettle();
    await tester.tap(find.text('refresh'));
    await tester.pumpAndSettle();

    expect(selectionCount, 2);
  });

  testWidgets('history scrolls to the selected branch tip', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final commits = List<CommitViewData>.generate(40, (index) {
      final oid = index.toRadixString(16).padLeft(40, '0');
      return CommitViewData(
        oid: oid,
        shortOid: oid.substring(0, 8),
        subject: index == 35 ? 'target branch tip' : 'commit $index',
        author: 'Test',
        relativeDate: '刚刚',
        isSelected: index == 35,
      );
    });
    final targetId = commits[35].oid;

    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'example',
              path: '/tmp/example',
              currentBranch: 'main',
              focusedRefCommitId: targetId,
              commits: commits,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('target branch tip'), findsOneWidget);
  });

  testWidgets(
    'current branch context menu disables unavailable pull and push',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: RepositoryOverview(
            data: RepositoryOverviewViewData.ready(
              RepositoryViewData(
                name: 'example',
                path: '/tmp/example',
                currentBranch: 'main',
                refs: const [
                  RepositoryRefViewData(
                    id: 'local:main',
                    label: 'main',
                    kind: RepositoryRefKind.localBranch,
                    isCurrent: true,
                  ),
                ],
                disabledActions: const {
                  RepositoryAction.pull,
                  RepositoryAction.push,
                },
              ),
            ),
            callbacks: RepositoryOverviewCallbacks(
              onRefContextAction: (_, _) {},
            ),
          ),
        ),
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('main').last),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.up();
      await tester.pumpAndSettle();

      final pullItem = tester.widget<PopupMenuItem<RepositoryRefContextAction>>(
        find.widgetWithText(
          PopupMenuItem<RepositoryRefContextAction>,
          '拉取当前分支',
        ),
      );
      final pushItem = tester.widget<PopupMenuItem<RepositoryRefContextAction>>(
        find.widgetWithText(
          PopupMenuItem<RepositoryRefContextAction>,
          '推送当前分支',
        ),
      );
      expect(pullItem.enabled, isFalse);
      expect(pushItem.enabled, isFalse);
    },
  );

  testWidgets('groups remote refs under origin and exposes remote actions', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    RepositoryRefViewData? actionReference;
    RepositoryRefContextAction? action;

    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: const RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'example',
              path: '/tmp/example',
              currentBranch: 'main',
              refs: [
                RepositoryRefViewData(
                  id: 'remotes/origin',
                  label: 'origin',
                  kind: RepositoryRefKind.remote,
                ),
                RepositoryRefViewData(
                  id: 'refs/remotes/origin/HEAD',
                  label: 'origin/HEAD',
                  kind: RepositoryRefKind.remoteBranch,
                  isSymbolicRemote: true,
                ),
                RepositoryRefViewData(
                  id: 'refs/remotes/origin/main',
                  label: 'origin/main',
                  kind: RepositoryRefKind.remoteBranch,
                ),
              ],
            ),
          ),
          callbacks: RepositoryOverviewCallbacks(
            onRefContextAction: (reference, next) {
              actionReference = reference;
              action = next;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('origin'), findsOneWidget);
    expect(find.text('HEAD'), findsOneWidget);
    expect(find.text('main'), findsWidgets);
    expect(find.text('origin/main'), findsNothing);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('origin')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    for (final label in [
      '从 origin 获取',
      '从 origin 拉取…',
      '推送到 origin…',
      '移除 origin',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.byType(PopupMenuDivider), findsNothing);

    await tester.tap(find.text('从 origin 获取'));
    await tester.pumpAndSettle();
    expect(actionReference?.kind, RepositoryRefKind.remote);
    expect(action, RepositoryRefContextAction.fetchOrigin);
  });

  testWidgets(
    'selects one remote group at a time and targets the owning remote branch',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      RepositoryRefViewData? actionReference;

      await tester.pumpWidget(
        MaterialApp(
          home: RepositoryOverview(
            data: const RepositoryOverviewViewData.ready(
              RepositoryViewData(
                name: 'example',
                path: '/tmp/example',
                currentBranch: 'main',
                refs: [
                  RepositoryRefViewData(
                    id: 'remotes/origin',
                    label: 'origin',
                    kind: RepositoryRefKind.remote,
                  ),
                  RepositoryRefViewData(
                    id: 'remotes/upstream',
                    label: 'upstream',
                    kind: RepositoryRefKind.remote,
                  ),
                  RepositoryRefViewData(
                    id: 'refs/remotes/origin/main',
                    label: 'origin/main',
                    kind: RepositoryRefKind.remoteBranch,
                  ),
                  RepositoryRefViewData(
                    id: 'refs/remotes/upstream/release',
                    label: 'upstream/release',
                    kind: RepositoryRefKind.remoteBranch,
                  ),
                ],
              ),
            ),
            callbacks: RepositoryOverviewCallbacks(
              onRefContextAction: (reference, _) => actionReference = reference,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('origin'));
      await tester.pump();
      await tester.tap(find.text('upstream'));
      await tester.pump();
      // The first selection collapses the initially expanded group; expand
      // it again before opening the nested branch menu.
      await tester.tap(find.text('upstream'));
      await tester.pump();

      final originSemantics = find.byWidgetPredicate(
        (widget) =>
            widget is Semantics && widget.properties.label == '远端 origin',
      );
      final upstreamSemantics = find.byWidgetPredicate(
        (widget) =>
            widget is Semantics && widget.properties.label == '远端 upstream',
      );
      expect(
        tester
            .getSemantics(originSemantics)
            .getSemanticsData()
            .flagsCollection
            .isSelected,
        Tristate.isFalse,
      );
      expect(
        tester
            .getSemantics(upstreamSemantics)
            .getSemanticsData()
            .flagsCollection
            .isSelected,
        Tristate.isTrue,
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('release')),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.up();
      await tester.pumpAndSettle();

      expect(find.text('获取 upstream'), findsOneWidget);
      expect(find.text('获取 origin'), findsNothing);
      await tester.tap(find.text('获取 upstream'));
      await tester.pumpAndSettle();
      expect(actionReference?.label, 'upstream/release');
    },
  );

  testWidgets('stash navigation can request creation repeatedly', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final selectedReferences = <RepositoryRefViewData>[];

    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: const RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'example',
              path: '/tmp/example',
              currentBranch: 'main',
              refs: [
                RepositoryRefViewData(
                  id: 'refs/stash',
                  label: '已贮藏',
                  kind: RepositoryRefKind.stash,
                ),
              ],
            ),
          ),
          callbacks: RepositoryOverviewCallbacks(
            onRefSelected: selectedReferences.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('已贮藏'));
    await tester.pump();
    await tester.tap(find.text('已贮藏'));
    await tester.pump();

    expect(selectedReferences, hasLength(2));
    expect(selectedReferences, everyElement(isA<RepositoryRefViewData>()));
  });

  testWidgets('stash navigation is disabled when stash is unavailable', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var requested = false;

    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: const RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'example',
              path: '/tmp/example',
              currentBranch: 'main',
              refs: [
                RepositoryRefViewData(
                  id: 'refs/stash',
                  label: '已贮藏',
                  kind: RepositoryRefKind.stash,
                ),
              ],
              disabledActions: {RepositoryAction.stash},
            ),
          ),
          callbacks: RepositoryOverviewCallbacks(
            onRefSelected: (_) => requested = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('已贮藏'));
    await tester.pump();

    expect(requested, isFalse);
    expect(
      tester
          .widget<Opacity>(
            find.ancestor(of: find.text('已贮藏'), matching: find.byType(Opacity)),
          )
          .opacity,
      0.5,
    );
  });

  testWidgets('renders listed stashes beneath the stashes entry', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    RepositoryRefViewData? selected;

    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: const RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'example',
              path: '/tmp/example',
              currentBranch: 'main',
              refs: [
                RepositoryRefViewData(
                  id: 'refs/stash',
                  label: '已贮藏',
                  kind: RepositoryRefKind.stash,
                ),
                RepositoryRefViewData(
                  id: 'refs/stash/0123456',
                  label: 'On main: test stash',
                  kind: RepositoryRefKind.stash,
                  stashReference: 'stash@{0}',
                ),
              ],
            ),
          ),
          callbacks: RepositoryOverviewCallbacks(
            onRefSelected: (reference) => selected = reference,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final semantics = tester.ensureSemantics();

    expect(find.text('已贮藏'), findsOneWidget);
    expect(find.text('On main: test stash'), findsOneWidget);
    final stashSemantics = find.byWidgetPredicate(
      (widget) =>
          widget is Semantics &&
          widget.properties.label == '贮藏 On main: test stash',
    );
    expect(stashSemantics, findsOneWidget);
    expect(
      tester
          .getSemantics(stashSemantics)
          .getSemanticsData()
          .hasAction(SemanticsAction.tap),
      isTrue,
    );

    await tester.tap(find.text('On main: test stash'));
    await tester.pump();
    expect(selected?.stashReference, 'stash@{0}');
    semantics.dispose();
  });

  testWidgets(
    'context menu disables remote actions while the repository loads',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: RepositoryOverview(
            data: RepositoryOverviewViewData.ready(
              RepositoryViewData(
                name: 'example',
                path: '/tmp/example',
                currentBranch: 'main',
                isRefreshing: true,
                refs: const [
                  RepositoryRefViewData(
                    id: 'local:main',
                    label: 'main',
                    kind: RepositoryRefKind.localBranch,
                    isCurrent: true,
                  ),
                ],
              ),
            ),
            callbacks: RepositoryOverviewCallbacks(
              onRefContextAction: (_, _) {},
            ),
          ),
        ),
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('main').last),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      for (final label in ['获取 origin', '拉取当前分支', '推送当前分支']) {
        final item = tester.widget<PopupMenuItem<RepositoryRefContextAction>>(
          find.widgetWithText(PopupMenuItem<RepositoryRefContextAction>, label),
        );
        expect(item.enabled, isFalse);
      }
    },
  );

  testWidgets('exposes the operation log from the status bar', (tester) async {
    RepositoryAction? action;
    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'example',
              path: '/tmp/example',
              currentBranch: 'main',
              footer: RepositoryFooterViewData(
                operations: [
                  RepositoryOperationViewData(
                    id: 'operation-1',
                    label: '正在获取远端更新',
                    state: RepositoryOperationState.running,
                    startedAt: DateTime(2026, 8, 20, 9),
                  ),
                ],
              ),
            ),
          ),
          callbacks: RepositoryOverviewCallbacks(
            onAction: (next) => action = next,
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('查看操作日志'));
    expect(action, RepositoryAction.showOperationLog);
  });

  testWidgets('stash preview fills the workspace beside refs', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: RepositoryOverview(
          data: RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'example',
              path: '/tmp/example',
              currentBranch: 'main',
              refs: [
                RepositoryRefViewData(
                  id: 'refs/stash',
                  label: '已贮藏',
                  kind: RepositoryRefKind.stash,
                ),
                RepositoryRefViewData(
                  id: 'refs/stash/0123456',
                  label: 'On main: test stash',
                  kind: RepositoryRefKind.stash,
                  stashReference: 'stash@{0}',
                  isSelected: true,
                ),
              ],
              selectedCommit: CommitDetailsViewData(
                oid: '0123456',
                subject: 'On main: test stash',
                author: 'Test User',
                authoredAt: '2026-08-23 12:00',
              ),
              commitChanges: [
                CommitFileViewData(
                  path: 'test_hello_sourcetree.py',
                  kind: RepositoryChangeKind.added,
                  isSelected: true,
                ),
              ],
              selectedCommitFile: CommitFileViewData(
                path: 'test_hello_sourcetree.py',
                kind: RepositoryChangeKind.added,
                isSelected: true,
              ),
              commitDiff: DiffViewData(
                path: 'test_hello_sourcetree.py',
                lines: [
                  DiffLineViewData(
                    kind: DiffLineKind.addition,
                    text: '+print("stashed")',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('贮藏改动'), findsOneWidget);
    expect(find.text('test_hello_sourcetree.py'), findsNWidgets(2));
    expect(find.text('+print("stashed")'), findsOneWidget);
    expect(find.text('历史'), findsNothing);
  });

  testWidgets('file status fills the workspace beside refs', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    RepositoryAction? action;
    const change = RepositoryChangeViewData(
      path: 'lib/example.dart',
      kind: RepositoryChangeKind.modified,
      isStaged: true,
    );
    final longDiffLine =
        '+final value = "${List.filled(80, 'long-value-').join()}";';
    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'example',
              path: '/tmp/example',
              currentBranch: 'main',
              refs: const [
                RepositoryRefViewData(
                  id: 'workspace',
                  label: '文件状态',
                  kind: RepositoryRefKind.workspace,
                  isSelected: true,
                ),
              ],
              changes: const [change],
              selectedChange: change,
              diff: DiffViewData(
                path: 'lib/example.dart',
                lines: [
                  DiffLineViewData(
                    kind: DiffLineKind.addition,
                    text: longDiffLine,
                  ),
                ],
              ),
            ),
          ),
          callbacks: RepositoryOverviewCallbacks(
            onAction: (next) => action = next,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('文件状态'), findsWidgets);
    expect(find.text('lib/example.dart'), findsOneWidget);
    final horizontal = find.byKey(const ValueKey('diff-horizontal-scroll'));
    expect(horizontal, findsOneWidget);
    final scrollable = find.descendant(
      of: horizontal,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.right,
      ),
    );
    expect(
      tester.state<ScrollableState>(scrollable).position.maxScrollExtent,
      greaterThan(0),
    );
    await tester.drag(horizontal, const Offset(-240, 0));
    await tester.pump();
    expect(
      tester.state<ScrollableState>(scrollable).position.pixels,
      greaterThan(0),
    );
    expect(find.text('提交信息'), findsOneWidget);
    expect(find.text('历史'), findsNothing);
    expect(find.text('提交详情'), findsNothing);

    await tester.tap(find.byType(TextField));
    expect(action, RepositoryAction.commit);
  });
}
