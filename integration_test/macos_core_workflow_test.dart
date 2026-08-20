import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:git_desktop/src/app/git_desktop_app.dart';
import 'package:git_desktop/src/app/repository_session.dart';
import 'package:integration_test/integration_test.dart';

import '../test/support/git_test_repository.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'macOS workspace stages, commits, creates a branch and pushes through UI',
    (tester) async {
      final source = await GitTestRepository.create();
      addTearDown(source.dispose);
      await source.writeFile('README.md', '# Git Desktop\n');
      await source.commit('Initial commit');
      final origin = await source.createBareOrigin();
      await source.runGit(['push', '--set-upstream', 'origin', 'main']);

      final target = await GitTestRepository.cloneFrom(origin);
      addTearDown(target.dispose);
      await target.writeFile('workflow.md', 'validated by macOS UI E2E\n');

      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const GitDesktopApp(),
        ),
      );
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(target.workingDirectory.path);
      await tester.pumpAndSettle();

      expect(find.text('workflow.md'), findsOneWidget);
      await tester.tap(find.byTooltip('暂存 workflow.md'));
      await tester.pumpAndSettle();
      expect(
        container.read(repositorySessionProvider).status!.stagedEntries,
        hasLength(1),
      );

      await tester.tap(find.byTooltip('提交'));
      await tester.pumpAndSettle();
      final commitDialog = find.byType(AlertDialog);
      expect(find.text('创建提交'), findsOneWidget);
      await tester.enterText(
        find.descendant(of: commitDialog, matching: find.byType(TextFormField)),
        'Validate macOS UI workflow',
      );
      await tester.tap(
        find.descendant(of: commitDialog, matching: find.text('提交')),
      );
      await tester.pumpAndSettle();
      expect(
        container.read(repositorySessionProvider).commits.first.subject,
        'Validate macOS UI workflow',
      );

      await tester.tap(find.byTooltip('分支'));
      await tester.pumpAndSettle();
      final branchDialog = find.byType(AlertDialog);
      expect(find.text('创建本地分支'), findsOneWidget);
      await tester.enterText(
        find.descendant(of: branchDialog, matching: find.byType(TextFormField)),
        'feature/macos-e2e',
      );
      await tester.tap(
        find.descendant(of: branchDialog, matching: find.text('创建')),
      );
      await tester.pumpAndSettle();
      expect(
        (await target.runGit([
          'branch',
          '--show-current',
        ])).stdout.toString().trim(),
        'main',
      );
      await target.runGit([
        'show-ref',
        '--verify',
        '--quiet',
        'refs/heads/feature/macos-e2e',
      ]);

      await tester.tap(find.byTooltip('推送'));
      await tester.pumpAndSettle();
      final pushDialog = find.byType(AlertDialog);
      expect(find.text('推送提交'), findsOneWidget);
      await tester.tap(
        find.descendant(of: pushDialog, matching: find.text('推送')),
      );
      await tester.pumpAndSettle();

      final localHead = (await target.runGit([
        'rev-parse',
        'HEAD',
      ])).stdout.toString().trim();
      final remoteHead = (await source.runGit([
        'rev-parse',
        'refs/heads/main',
      ], workingDirectory: origin)).stdout.toString().trim();
      expect(remoteHead, localHead);
      expect(container.read(repositorySessionProvider).status!.branch.ahead, 0);
    },
  );
}
