import 'package:flutter/material.dart';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
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
}
