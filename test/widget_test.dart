import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:git_desktop/src/app/git_askpass_prompt_coordinator.dart';
import 'package:git_desktop/src/app/git_desktop_app.dart';
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
