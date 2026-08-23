import 'package:flutter/material.dart';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/presentation/presentation.dart';

void main() {
  testWidgets('shows uncommitted changes above history and opens workspace', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    RepositoryRefViewData? selectedReference;
    const workspace = RepositoryRefViewData(
      id: 'workspace',
      label: '文件状态',
      kind: RepositoryRefKind.workspace,
      isSelected: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryOverview(
          data: const RepositoryOverviewViewData.ready(
            RepositoryViewData(
              name: 'playground',
              path: '/tmp/playground',
              currentBranch: 'main',
              isWorkingTreeClean: false,
              refs: [workspace],
              changes: [
                RepositoryChangeViewData(
                  path: 'hello_sourcetree.py',
                  kind: RepositoryChangeKind.untracked,
                ),
              ],
            ),
          ),
          callbacks: RepositoryOverviewCallbacks(
            onRefSelected: (reference) => selectedReference = reference,
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

    expect(selectedReference, workspace);
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
    expect(find.textContaining('使用“我的”版本解决'), findsOneWidget);
    expect(find.textContaining('使用“他们的”版本解决'), findsOneWidget);
    expect(find.text('重新合并'), findsOneWidget);
    expect(find.text('标记为已解决'), findsOneWidget);
    expect(find.text('标记为未解决'), findsOneWidget);

    await tester.tap(find.textContaining('使用“我的”版本解决'));
    await tester.pumpAndSettle();
    expect(selectedAction, RepositoryConflictAction.useOurs);
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

  testWidgets('working-tree context menu removes selected untracked files', (
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
      tester.getCenter(find.text('scratch.txt')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();

    expect(removed?.map((change) => change.path), ['scratch.txt']);
  });
}
