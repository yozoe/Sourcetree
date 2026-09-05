import 'package:flutter/material.dart';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/presentation/presentation.dart';

void main() {
  testWidgets('shows a three-pane skeleton while initially loading', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: RepositoryOverview(
          data: RepositoryOverviewViewData.loading(
            title: '正在读取仓库',
            message: '/tmp/playground',
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('repository-loading-skeleton')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('loading-skeleton-navigation')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('loading-skeleton-history')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('loading-skeleton-details')),
      findsOneWidget,
    );
    expect(find.text('正在读取仓库'), findsOneWidget);
    expect(find.text('/tmp/playground'), findsOneWidget);
    expect(find.byType(Card), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('uses a compact loading skeleton in a narrow dark window', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(700, 520));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: const RepositoryOverview(
          data: RepositoryOverviewViewData.loading(message: '/tmp/playground'),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('loading-skeleton-history')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('loading-skeleton-navigation')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('loading-skeleton-details')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps cancel clone available from the loading skeleton', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    RepositoryAction? action;

    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: const RepositoryOverviewViewData.loading(
            message: '/tmp/playground',
            canCancelOperation: true,
          ),
          callbacks: RepositoryOverviewCallbacks(
            onAction: (RepositoryAction value) => action = value,
          ),
        ),
      ),
    );

    final Finder cancel = find.byKey(
      const ValueKey<String>('loading-skeleton-cancel'),
    );
    expect(cancel, findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('loading-skeleton-navigation')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('loading-skeleton-details')),
      findsNothing,
    );

    await tester.tap(cancel);

    expect(action, RepositoryAction.cancelClone);
  });

  testWidgets('shows every toolbar action vertically without scrolling', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(760, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: const RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'playground',
              path: '/tmp/playground',
              currentBranch: 'main',
            ),
          ),
          callbacks: const RepositoryOverviewCallbacks(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final toolbar = find.byKey(const ValueKey<String>('repository-toolbar'));
    expect(toolbar, findsOneWidget);
    expect(
      find.descendant(
        of: toolbar,
        matching: find.byType(SingleChildScrollView),
      ),
      findsNothing,
    );
    for (final label in <String>[
      '提交',
      '贮藏',
      '拉取',
      '推送',
      '获取',
      '分支',
      '合并',
      '刷新',
      '打开仓库',
    ]) {
      expect(
        find.descendant(of: toolbar, matching: find.text(label)),
        findsOneWidget,
      );
    }

    final commitIcon = find.descendant(
      of: toolbar,
      matching: find.byIcon(Icons.check_circle_outline),
    );
    final commitLabel = find.descendant(of: toolbar, matching: find.text('提交'));
    expect(
      tester.getTopLeft(commitIcon).dy,
      lessThan(tester.getTopLeft(commitLabel).dy),
    );
  });

  testWidgets('shows ahead commit count and enables push like Sourcetree', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    RepositoryAction? action;

    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: const RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'playground',
              path: '/tmp/playground',
              currentBranch: 'main',
              ahead: 3,
              behind: 0,
            ),
          ),
          callbacks: RepositoryOverviewCallbacks(
            onAction: (value) => action = value,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final pushButton = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '推送'),
    );
    expect(pushButton.onPressed, isNotNull);
    expect(find.widgetWithText(Badge, '3'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '推送'));
    expect(action, RepositoryAction.push);
  });

  testWidgets('shows uncommitted changes above history without leaving it', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var uncommittedChangesSelected = false;

    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: const RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'playground',
              path: '/tmp/playground',
              currentBranch: 'main',
              isWorkingTreeClean: false,
              refs: [
                RepositoryRefViewData(
                  id: 'history',
                  label: '历史',
                  kind: RepositoryRefKind.workspace,
                  isSelected: true,
                ),
              ],
              changes: [
                RepositoryChangeViewData(
                  path: 'hello_sourcetree.py',
                  kind: RepositoryChangeKind.untracked,
                ),
              ],
            ),
          ),
          callbacks: RepositoryOverviewCallbacks(
            onUncommittedChangesSelected: () =>
                uncommittedChangesSelected = true,
          ),
        ),
      ),
    );

    expect(find.text('Uncommitted changes'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('uncommitted-changes-row')),
      findsOneWidget,
    );
    expect(find.text('暂无提交'), findsNothing);

    await tester.tap(find.text('Uncommitted changes'));
    await tester.pump();

    expect(uncommittedChangesSelected, isTrue);
    expect(find.text('历史'), findsWidgets);
  });

  testWidgets('separates staged and unstaged files into labeled groups', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: RepositoryOverview(
          data: RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'playground',
              path: '/tmp/playground',
              currentBranch: 'main',
              isWorkingTreeClean: false,
              changes: [
                RepositoryChangeViewData(
                  path: 'hello_sourcetree.py',
                  kind: RepositoryChangeKind.added,
                  isStaged: true,
                  isSelected: true,
                ),
              ],
              selectedChange: RepositoryChangeViewData(
                path: 'hello_sourcetree.py',
                kind: RepositoryChangeKind.added,
                isStaged: true,
                isSelected: true,
              ),
              diff: DiffViewData(
                path: 'hello_sourcetree.py',
                lines: [
                  DiffLineViewData(
                    kind: DiffLineKind.addition,
                    text: '+print("ready")',
                    newLineNumber: 1,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('已暂存文件'), findsOneWidget);
    expect(find.text('未暂存文件'), findsOneWidget);
    expect(find.byKey(const ValueKey('staged-files-header')), findsOneWidget);
    expect(find.byKey(const ValueKey('unstaged-files-header')), findsOneWidget);
    expect(find.text('hello_sourcetree.py'), findsNWidgets(2));
  });

  testWidgets('stages an unstaged file from its checkbox', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    RepositoryChangeViewData? toggled;

    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: const RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'playground',
              path: '/tmp/playground',
              currentBranch: 'main',
              isWorkingTreeClean: false,
              changes: [
                RepositoryChangeViewData(
                  path: 'hello.py',
                  kind: RepositoryChangeKind.untracked,
                ),
              ],
            ),
          ),
          callbacks: RepositoryOverviewCallbacks(
            onChangeStageToggled: (change) async => toggled = change,
          ),
        ),
      ),
    );

    await tester.tap(find.byType(Checkbox).last);
    await tester.pump();

    expect(toggled?.path, 'hello.py');
  });

  testWidgets('shows staging progress without greying a checked checkbox', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: RepositoryOverview(
          data: RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'playground',
              path: '/tmp/playground',
              currentBranch: 'main',
              isWorkingTreeClean: false,
              isWorkingTreeBusy: true,
              changes: [
                RepositoryChangeViewData(
                  path: 'staged.txt',
                  kind: RepositoryChangeKind.modified,
                  isStaged: true,
                  canToggleStage: false,
                  isActionEnabled: false,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final stagedHeader = find.byKey(const ValueKey('staged-files-header'));
    final checkbox = tester.widget<Checkbox>(
      find.descendant(of: stagedHeader, matching: find.byType(Checkbox)),
    );
    final colors = Theme.of(tester.element(stagedHeader)).colorScheme;

    expect(checkbox.value, isTrue);
    expect(checkbox.onChanged, isNull);
    expect(
      checkbox.fillColor?.resolve(const {
        WidgetState.disabled,
        WidgetState.selected,
      }),
      colors.primary,
    );
    expect(
      find.byKey(const ValueKey('working-tree-status-progress')),
      findsOneWidget,
    );
    expect(find.text('正在更新'), findsOneWidget);
    expect(find.text('1 已暂存 · 0 未暂存'), findsNothing);
  });

  testWidgets('keeps empty staged group unchecked and resizable', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: RepositoryOverview(
          data: RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'playground',
              path: '/tmp/playground',
              currentBranch: 'main',
              isWorkingTreeClean: false,
              changes: [
                RepositoryChangeViewData(
                  path: 'hello.py',
                  kind: RepositoryChangeKind.untracked,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final stagedHeader = find.byKey(const ValueKey('staged-files-header'));
    expect(
      tester
          .widget<Checkbox>(
            find.descendant(of: stagedHeader, matching: find.byType(Checkbox)),
          )
          .value,
      isFalse,
    );

    final divider = find.bySemanticsLabel('调整已暂存文件区域高度');
    expect(divider, findsOneWidget);
    final before = tester.getTopLeft(find.text('未暂存文件')).dy;
    await tester.drag(divider, const Offset(0, 24));
    await tester.pump();
    expect(tester.getTopLeft(find.text('未暂存文件')).dy, greaterThan(before));

    final widthDivider = find.bySemanticsLabel('调整文件列表宽度');
    expect(widthDivider, findsOneWidget);
    final beforeWidth = tester.getCenter(widthDivider).dx;
    await tester.drag(widthDivider, const Offset(80, 0));
    await tester.pump();
    expect(tester.getCenter(widthDivider).dx, greaterThan(beforeWidth));
  });

  testWidgets('stages every unstaged file from the group checkbox', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    List<RepositoryChangeViewData>? staged;
    var stage = false;

    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: const RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'playground',
              path: '/tmp/playground',
              currentBranch: 'main',
              isWorkingTreeClean: false,
              changes: [
                RepositoryChangeViewData(
                  path: 'one.py',
                  kind: RepositoryChangeKind.untracked,
                ),
                RepositoryChangeViewData(
                  path: 'two.py',
                  kind: RepositoryChangeKind.modified,
                ),
              ],
            ),
          ),
          callbacks: RepositoryOverviewCallbacks(
            onChangeGroupStageToggled: (changes, shouldStage) {
              staged = changes;
              stage = shouldStage;
            },
          ),
        ),
      ),
    );

    final header = find.byKey(const ValueKey('unstaged-files-header'));
    await tester.tap(
      find.descendant(of: header, matching: find.byType(Checkbox)),
    );
    await tester.pump();

    expect(stage, isTrue);
    expect(
      staged?.map((change) => change.path),
      containsAll(<String>['one.py', 'two.py']),
    );
  });

  testWidgets('offers conflict resolution actions from a file context menu', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    RepositoryConflictAction? selectedAction;
    const conflict = RepositoryChangeViewData(
      path: 'hello_sourcetree.py',
      kind: RepositoryChangeKind.conflicted,
      canToggleStage: false,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: const RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'playground',
              path: '/tmp/playground',
              currentBranch: 'main',
              isRebaseInProgress: true,
              isWorkingTreeClean: false,
              changes: [conflict],
            ),
          ),
          callbacks: RepositoryOverviewCallbacks(
            onConflictAction: (_, action) => selectedAction = action,
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('hello_sourcetree.py')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('解决冲突'), findsOneWidget);
    expect(find.text('打开内部 Diff 工具'), findsNothing);

    await tester.tap(find.text('解决冲突'));
    await tester.pumpAndSettle();

    expect(find.text('打开内部 Diff 工具'), findsOneWidget);
    expect(find.textContaining('使用当前基线版本解决'), findsOneWidget);
    expect(find.textContaining('使用待应用版本解决'), findsOneWidget);
    expect(find.text('重新合并'), findsOneWidget);
    expect(find.text('标记为已解决'), findsOneWidget);
    expect(find.text('标记为未解决'), findsOneWidget);

    await tester.tap(find.textContaining('使用当前基线版本解决'));
    await tester.pumpAndSettle();
    expect(selectedAction, RepositoryConflictAction.useOurs);
  });

  testWidgets('paused operation blocks ordinary workspace writes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const tracked = RepositoryChangeViewData(
      path: 'tracked.dart',
      kind: RepositoryChangeKind.modified,
      isStaged: true,
      isSelected: true,
    );
    const conflict = RepositoryChangeViewData(
      path: 'conflict.dart',
      kind: RepositoryChangeKind.conflicted,
      canToggleStage: false,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: const RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'playground',
              path: '/tmp/playground',
              currentBranch: 'main',
              isRebaseInProgress: true,
              isWorkingTreeClean: false,
              changes: [tracked, conflict],
              selectedChange: tracked,
              diff: DiffViewData(
                path: 'tracked.dart',
                hunkActions: [RepositoryDiffHunkAction.unstage],
                lines: [
                  DiffLineViewData(
                    kind: DiffLineKind.hunkHeader,
                    text: '@@ -1 +1 @@',
                    hunkIndex: 0,
                  ),
                ],
              ),
            ),
          ),
          callbacks: RepositoryOverviewCallbacks(
            onChangeStageToggled: (_) {},
            onChangeGroupStageToggled: (_, _) {},
            onChangeRemove: (_) {},
            onChangeStopTracking: (_) {},
            onChangeReset: (_) {},
            onDiffHunkAction: (_, _) {},
            onConflictAction: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final stagedHeader = find.byKey(const ValueKey('staged-files-header'));
    expect(
      tester
          .widget<Checkbox>(
            find.descendant(of: stagedHeader, matching: find.byType(Checkbox)),
          )
          .onChanged,
      isNull,
    );
    final trackedTile = find.byKey(
      const ValueKey('change-tile-staged-tracked.dart'),
    );
    expect(
      tester
          .widget<Checkbox>(
            find.descendant(of: trackedTile, matching: find.byType(Checkbox)),
          )
          .onChanged,
      isNull,
    );
    expect(find.text('取消暂存区块'), findsNothing);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('tracked.dart').first),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    for (final label in ['从索引中取消暂存', '移除', '停止追踪', '重置…']) {
      expect(
        tester
            .widget<MenuItemButton>(find.widgetWithText(MenuItemButton, label))
            .onPressed,
        isNull,
        reason: label,
      );
    }
  });

  testWidgets(
    'shows the historical-file context menu and forwards its action',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      CommitFileViewData? selectedFile;
      RepositoryCommitFileContextAction? selectedAction;
      const commitFile = CommitFileViewData(
        path: 'lib/main.dart',
        kind: RepositoryChangeKind.modified,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: RepositoryOverview(
            data: const RepositoryOverviewViewData.ready(
              RepositoryViewData(
                name: 'playground',
                path: '/tmp/playground',
                currentBranch: 'main',
                selectedCommit: CommitDetailsViewData(
                  oid: '0123456789abcdef',
                  subject: 'Add historical file menu',
                  author: 'Test User',
                  authoredAt: '2026-08-25 12:00',
                ),
                commitChanges: [commitFile],
              ),
            ),
            callbacks: RepositoryOverviewCallbacks(
              onCommitFileSelected: (file) => selectedFile = file,
              onCommitFileContextAction: (file, action) {
                selectedFile = file;
                selectedAction = action;
              },
            ),
          ),
        ),
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('main.dart')),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.up();
      await tester.pumpAndSettle();

      for (final label in <String>[
        '查看选中的修改日志…',
        '审查选定的项目（待实现）',
        '重置到提交…（待实现）',
        '打开当前版本（待实现）',
        '打开已选定版本（待实现）',
        '在 Finder 中显示（待实现）',
        '复制路径到剪贴板（待实现）',
        '快速查看（待实现）',
        '外部差异比对（待实现）',
        '自定义操作（待实现）',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      expect(selectedFile, commitFile);

      await tester.tap(find.text('打开当前版本（待实现）'));
      await tester.pumpAndSettle();

      expect(selectedFile, commitFile);
      expect(
        selectedAction,
        RepositoryCommitFileContextAction.openCurrentVersion,
      );
    },
  );

  testWidgets('marks file history pending for a non-UTF-8 Git path', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    RepositoryCommitFileContextAction? selectedAction;

    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: const RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'playground',
              path: '/tmp/playground',
              currentBranch: 'main',
              selectedCommit: CommitDetailsViewData(
                oid: '0123456789abcdef',
                subject: 'Non UTF-8 path',
                author: 'Test User',
                authoredAt: '2026-08-26 12:00',
              ),
              commitChanges: [
                CommitFileViewData(
                  path: 'invalid�.txt',
                  kind: RepositoryChangeKind.modified,
                  isPathValidUtf8: false,
                ),
              ],
            ),
          ),
          callbacks: RepositoryOverviewCallbacks(
            onCommitFileContextAction: (_, action) => selectedAction = action,
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('invalid�.txt')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    final pending = find.text('查看选中的修改日志…（待实现）');
    expect(pending, findsOneWidget);
    await tester.tap(pending);
    await tester.pumpAndSettle();
    expect(selectedAction, isNull);
  });

  testWidgets('command-click keeps multiple working-tree files selected', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final selected = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: const RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'playground',
              path: '/tmp/playground',
              currentBranch: 'main',
              isWorkingTreeClean: false,
              changes: [
                RepositoryChangeViewData(
                  path: 'one.py',
                  kind: RepositoryChangeKind.modified,
                ),
                RepositoryChangeViewData(
                  path: 'two.py',
                  kind: RepositoryChangeKind.untracked,
                ),
              ],
            ),
          ),
          callbacks: RepositoryOverviewCallbacks(
            onChangeSelected: (change) {
              if (change != null) selected.add(change.path);
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('one.py'));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.tap(find.text('two.py'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await tester.pump();

    expect(selected, containsAll(<String>['one.py', 'two.py']));
    expect(selected, hasLength(2));
  });

  testWidgets('working-tree context menu stages all selected files', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    List<RepositoryChangeViewData>? staged;

    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: const RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'playground',
              path: '/tmp/playground',
              currentBranch: 'main',
              isWorkingTreeClean: false,
              changes: [
                RepositoryChangeViewData(
                  path: 'one.py',
                  kind: RepositoryChangeKind.modified,
                ),
                RepositoryChangeViewData(
                  path: 'two.py',
                  kind: RepositoryChangeKind.untracked,
                ),
              ],
            ),
          ),
          callbacks: RepositoryOverviewCallbacks(
            onChangeGroupStageToggled: (changes, stage) {
              staged = changes;
              expect(stage, isTrue);
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('one.py'));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.tap(find.text('two.py'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('two.py')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('添加到索引'), findsOneWidget);
    await tester.tap(find.text('添加到索引'));
    await tester.pumpAndSettle();
    expect(
      staged?.map((change) => change.path),
      containsAll(<String>['one.py', 'two.py']),
    );
  });

  testWidgets('working-tree context menu removes files from either group', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    List<RepositoryChangeViewData>? removed;

    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: const RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'playground',
              path: '/tmp/playground',
              currentBranch: 'main',
              isWorkingTreeClean: false,
              changes: [
                RepositoryChangeViewData(
                  path: 'scratch.txt',
                  kind: RepositoryChangeKind.untracked,
                ),
                RepositoryChangeViewData(
                  path: 'working.txt',
                  kind: RepositoryChangeKind.modified,
                ),
                RepositoryChangeViewData(
                  path: 'staged.txt',
                  kind: RepositoryChangeKind.modified,
                  isStaged: true,
                ),
              ],
            ),
          ),
          callbacks: RepositoryOverviewCallbacks(
            onChangeRemove: (changes) => removed = changes,
          ),
        ),
      ),
    );

    for (final path in ['scratch.txt', 'working.txt', 'staged.txt']) {
      final gesture = await tester.startGesture(
        tester.getCenter(find.text(path)),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.up();
      await tester.pumpAndSettle();

      await tester.tap(find.text('移除'));
      await tester.pumpAndSettle();

      expect(removed?.map((change) => change.path), [path]);
    }
  });

  testWidgets('marks removal pending for a non-UTF-8 working-tree path', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    List<RepositoryChangeViewData>? removed;

    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: const RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'playground',
              path: '/tmp/playground',
              currentBranch: 'main',
              isWorkingTreeClean: false,
              changes: [
                RepositoryChangeViewData(
                  path: 'invalid�.txt',
                  kind: RepositoryChangeKind.untracked,
                  isPathValidUtf8: false,
                ),
              ],
            ),
          ),
          callbacks: RepositoryOverviewCallbacks(
            onChangeRemove: (changes) => removed = changes,
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('invalid�.txt')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('移除（待实现）'), findsOneWidget);
    expect(find.text('移除'), findsNothing);
    await tester.tap(find.text('移除（待实现）'));
    await tester.pumpAndSettle();
    expect(removed, isNull);
  });

  testWidgets('working-tree context menu stops tracking selected files', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    List<RepositoryChangeViewData>? stoppedTracking;

    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: const RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'playground',
              path: '/tmp/playground',
              currentBranch: 'main',
              isWorkingTreeClean: false,
              changes: [
                RepositoryChangeViewData(
                  path: 'config/local.json',
                  kind: RepositoryChangeKind.modified,
                ),
              ],
            ),
          ),
          callbacks: RepositoryOverviewCallbacks(
            onChangeStopTracking: (changes) => stoppedTracking = changes,
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('local.json')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.text('停止追踪'));
    await tester.pumpAndSettle();

    expect(stoppedTracking?.map((change) => change.path), [
      'config/local.json',
    ]);
  });

  testWidgets('shows stage and discard actions for an unstaged hunk', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final actions = <(RepositoryDiffHunkAction, int)>[];

    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: const RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'playground',
              path: '/tmp/playground',
              currentBranch: 'main',
              isWorkingTreeClean: false,
              changes: [
                RepositoryChangeViewData(
                  path: 'README.md',
                  kind: RepositoryChangeKind.modified,
                  isSelected: true,
                ),
              ],
              selectedChange: RepositoryChangeViewData(
                path: 'README.md',
                kind: RepositoryChangeKind.modified,
                isSelected: true,
              ),
              diff: DiffViewData(
                path: 'README.md',
                hunkActions: [
                  RepositoryDiffHunkAction.stage,
                  RepositoryDiffHunkAction.discard,
                ],
                lines: [
                  DiffLineViewData(
                    kind: DiffLineKind.hunkHeader,
                    text: '@@ -1 +1 @@',
                    hunkIndex: 0,
                  ),
                  DiffLineViewData(
                    kind: DiffLineKind.deletion,
                    text: '-before',
                    oldLineNumber: 1,
                    hunkIndex: 0,
                  ),
                  DiffLineViewData(
                    kind: DiffLineKind.addition,
                    text: '+after',
                    newLineNumber: 1,
                    hunkIndex: 0,
                  ),
                ],
              ),
            ),
          ),
          callbacks: RepositoryOverviewCallbacks(
            onDiffHunkAction: (action, hunkIndex) =>
                actions.add((action, hunkIndex)),
          ),
        ),
      ),
    );

    expect(find.text('暂存区块'), findsOneWidget);
    expect(find.text('放弃区块'), findsOneWidget);
    expect(find.text('取消暂存区块'), findsNothing);
    expect(find.text('回滚区块'), findsNothing);
    await tester.tap(find.text('暂存区块'));
    await tester.tap(find.text('放弃区块'));
    expect(actions, [
      (RepositoryDiffHunkAction.stage, 0),
      (RepositoryDiffHunkAction.discard, 0),
    ]);
  });

  testWidgets('shows only unstage for a staged hunk', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    (RepositoryDiffHunkAction, int)? selectedAction;

    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: const RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'playground',
              path: '/tmp/playground',
              currentBranch: 'main',
              isWorkingTreeClean: false,
              changes: [
                RepositoryChangeViewData(
                  path: 'README.md',
                  kind: RepositoryChangeKind.modified,
                  isStaged: true,
                  isSelected: true,
                ),
              ],
              selectedChange: RepositoryChangeViewData(
                path: 'README.md',
                kind: RepositoryChangeKind.modified,
                isStaged: true,
                isSelected: true,
              ),
              diff: DiffViewData(
                path: 'README.md',
                hunkActions: [RepositoryDiffHunkAction.unstage],
                lines: [
                  DiffLineViewData(
                    kind: DiffLineKind.hunkHeader,
                    text: '@@ -1 +1 @@',
                    hunkIndex: 0,
                  ),
                  DiffLineViewData(
                    kind: DiffLineKind.deletion,
                    text: '-before',
                    oldLineNumber: 1,
                    hunkIndex: 0,
                  ),
                  DiffLineViewData(
                    kind: DiffLineKind.addition,
                    text: '+after',
                    newLineNumber: 1,
                    hunkIndex: 0,
                  ),
                ],
              ),
            ),
          ),
          callbacks: RepositoryOverviewCallbacks(
            onDiffHunkAction: (action, hunkIndex) =>
                selectedAction = (action, hunkIndex),
          ),
        ),
      ),
    );

    expect(find.text('取消暂存区块'), findsOneWidget);
    expect(find.text('暂存区块'), findsNothing);
    expect(find.text('放弃区块'), findsNothing);
    expect(find.text('回滚区块'), findsNothing);
    await tester.tap(find.text('取消暂存区块'));
    expect(selectedAction, (RepositoryDiffHunkAction.unstage, 0));
  });

  testWidgets('shows only revert for a committed hunk', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    (RepositoryDiffHunkAction, int)? selectedAction;

    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: const RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'playground',
              path: '/tmp/playground',
              currentBranch: 'main',
              selectedCommit: CommitDetailsViewData(
                oid: '0123456789abcdef',
                subject: 'Committed change',
                author: 'Test User',
                authoredAt: '2026-08-26 12:00',
              ),
              commitChanges: [
                CommitFileViewData(
                  path: 'README.md',
                  kind: RepositoryChangeKind.modified,
                  isSelected: true,
                ),
              ],
              selectedCommitFile: CommitFileViewData(
                path: 'README.md',
                kind: RepositoryChangeKind.modified,
                isSelected: true,
              ),
              commitDiff: DiffViewData(
                path: 'README.md',
                hunkActions: [RepositoryDiffHunkAction.revertCommitted],
                lines: [
                  DiffLineViewData(
                    kind: DiffLineKind.hunkHeader,
                    text: '@@ -1 +1 @@',
                    hunkIndex: 0,
                  ),
                  DiffLineViewData(
                    kind: DiffLineKind.deletion,
                    text: '-before',
                    oldLineNumber: 1,
                    hunkIndex: 0,
                  ),
                  DiffLineViewData(
                    kind: DiffLineKind.addition,
                    text: '+after',
                    newLineNumber: 1,
                    hunkIndex: 0,
                  ),
                ],
              ),
            ),
          ),
          callbacks: RepositoryOverviewCallbacks(
            onDiffHunkAction: (action, hunkIndex) =>
                selectedAction = (action, hunkIndex),
          ),
        ),
      ),
    );

    expect(find.text('回滚区块'), findsOneWidget);
    expect(find.text('暂存区块'), findsNothing);
    expect(find.text('放弃区块'), findsNothing);
    expect(find.text('取消暂存区块'), findsNothing);
    await tester.tap(find.text('回滚区块'));
    expect(selectedAction, (RepositoryDiffHunkAction.revertCommitted, 0));
  });

  testWidgets('context menu stops tracking selected staged new files', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    List<RepositoryChangeViewData>? stoppedTracking;

    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: const RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'playground',
              path: '/tmp/playground',
              currentBranch: 'main',
              isWorkingTreeClean: false,
              changes: [
                RepositoryChangeViewData(
                  path: 'config/local.json',
                  kind: RepositoryChangeKind.added,
                  isStaged: true,
                ),
              ],
            ),
          ),
          callbacks: RepositoryOverviewCallbacks(
            onChangeStopTracking: (changes) => stoppedTracking = changes,
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('local.json')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.text('停止追踪'));
    await tester.pumpAndSettle();

    expect(stoppedTracking?.map((change) => change.path), [
      'config/local.json',
    ]);
  });

  testWidgets('context menu resets selected staged tracked files', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    List<RepositoryChangeViewData>? resetChanges;

    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: const RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'playground',
              path: '/tmp/playground',
              currentBranch: 'main',
              isWorkingTreeClean: false,
              changes: [
                RepositoryChangeViewData(
                  path: 'config/local.json',
                  kind: RepositoryChangeKind.modified,
                  isStaged: true,
                ),
              ],
            ),
          ),
          callbacks: RepositoryOverviewCallbacks(
            onChangeReset: (changes) => resetChanges = changes,
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('local.json')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.text('重置…'));
    await tester.pumpAndSettle();

    expect(resetChanges?.map((change) => change.path), ['config/local.json']);
  });

  testWidgets('shows stop-tracking results in normal Git status groups', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: const RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'playground',
              path: '/tmp/playground',
              currentBranch: 'main',
              isWorkingTreeClean: false,
              changes: [
                RepositoryChangeViewData(
                  path: 'config/local.json',
                  kind: RepositoryChangeKind.deleted,
                  isStaged: true,
                ),
                RepositoryChangeViewData(
                  path: 'config/local.json',
                  kind: RepositoryChangeKind.untracked,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.text('已暂存文件'), findsOneWidget);
    expect(find.text('未暂存文件'), findsOneWidget);
    expect(find.text('已停止追踪（待提交）'), findsNothing);
    expect(find.text('local.json'), findsNWidgets(2));
  });
}
