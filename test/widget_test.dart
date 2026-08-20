import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:git_desktop/src/app/git_askpass_prompt_coordinator.dart';
import 'package:git_desktop/src/app/git_desktop_app.dart';
import 'package:git_desktop/src/app/repository_session.dart';
import 'package:git_desktop/src/git/git.dart';
import 'package:git_desktop/src/presentation/presentation.dart';

void main() {
  testWidgets('shows supported actions on first launch', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: GitDesktopApp()));

    expect(find.text('打开一个 Git 仓库'), findsOneWidget);
    expect(find.text('打开仓库'), findsOneWidget);
    expect(find.text('克隆仓库'), findsOneWidget);
    expect(find.text('初始化仓库'), findsOneWidget);
  });

  testWidgets('routes a one-time AskPass request through the controlled UI', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const GitDesktopApp(),
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
        child: const GitDesktopApp(),
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
      tester.getCenter(find.text('feature/menu')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('切换到此分支'), findsOneWidget);
    expect(find.text('合并到当前分支'), findsOneWidget);

    await tester.tap(find.text('合并到当前分支'));
    await tester.pumpAndSettle();

    expect(selectedReference, featureBranch);
    expect(selectedAction, RepositoryRefContextAction.mergeIntoCurrent);
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
