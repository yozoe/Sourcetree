import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:git_desktop/src/app/git_askpass_prompt_coordinator.dart';
import 'package:git_desktop/src/app/git_desktop_app.dart';
import 'package:git_desktop/src/app/repository_session.dart';
import 'package:git_desktop/src/app/repository_session_store.dart';
import 'package:git_desktop/src/app/theme_preferences.dart';
import 'package:git_desktop/src/git/git.dart';
import 'package:git_desktop/src/presentation/presentation.dart';
import 'package:yeknom_ui_kit/yeknom_workbench.dart';

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

void main() {
  testWidgets('shows supported actions on first launch', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: GitDesktopApp()));

    expect(find.text('打开一个 Git 仓库'), findsOneWidget);
    expect(find.text('打开仓库'), findsOneWidget);
    expect(find.text('克隆仓库'), findsOneWidget);
    expect(find.text('初始化仓库'), findsOneWidget);
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
    expect(
      container.read(repositorySessionProvider).openRepositoryTabs,
      isEmpty,
    );
  });

  testWidgets('switches and persists shared theme preferences', (tester) async {
    final store = _MemoryThemePreferencesStore();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: GitDesktopApp(themePreferencesStore: store),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('theme-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('theme-mode-dark')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('theme-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('theme-preset-obsidian')));
    await tester.pumpAndSettle();

    final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(materialApp.themeMode, ThemeMode.dark);
    expect(store.saved.last.preset, YeknomColorPreset.obsidian);
  });

  testWidgets('groups, filters and selects local repositories', (tester) async {
    String? selectedPath;
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
        ),
      ),
    );

    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('beta'), findsOneWidget);
    expect(find.text('当前'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'web');
    await tester.pumpAndSettle();
    expect(find.text('api'), findsNothing);
    expect(find.text('web'), findsAtLeastNWidgets(1));

    await tester.tap(
      find.byKey(
        const ValueKey<String>('repository-library-tile:/work/alpha/web'),
      ),
    );
    await tester.pump();
    expect(selectedPath, '/work/alpha/web');
  });

  testWidgets('routes a one-time AskPass request through the controlled UI', (
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
    'switches between opened repositories by clicking workspace tabs',
    (tester) async {
      String? selectedPath;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RepositoryTabStrip(
              tabs: const [
                RepositoryTab(path: '/tmp/alpha', label: 'alpha'),
                RepositoryTab(path: '/tmp/beta', label: 'beta'),
              ],
              activePath: '/tmp/beta',
              onSelected: (path) async => selectedPath = path,
            ),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey<String>('repository-tab-strip')),
        findsOneWidget,
      );

      await tester.tap(find.text('alpha'));
      await tester.pump();

      expect(selectedPath, '/tmp/alpha');
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

    await tester.tap(find.text('合并到当前分支'));
    await tester.pumpAndSettle();

    expect(selectedReference, featureBranch);
    expect(selectedAction, RepositoryRefContextAction.mergeIntoCurrent);
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
              currentBranch: 'main',
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
  });

  testWidgets(
    'keeps history rows compact while resizing columns from body handles',
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
        findsNothing,
      );
      expect(find.text('当前分支'), findsNothing);
      expect(find.text('图表'), findsNothing);

      final graphCanvas = find.byKey(
        const ValueKey<String>('commit-graph-canvas'),
      );
      expect(tester.getSize(graphCanvas).height, closeTo(20, 1));
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
        final before = tester.getCenter(divider).dx;
        await tester.drag(divider, const Offset(20, 0));
        await tester.pump();
        expect(tester.getCenter(divider).dx, greaterThan(before));
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
      const Color(0xFFD8452A),
    );
    expect(find.text('超前3个版本'), findsOneWidget);
    expect(tester.getSize(conflictRef).width, greaterThan(100));
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
}
