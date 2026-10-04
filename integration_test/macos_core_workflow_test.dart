import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:git_desktop/src/app/git_askpass_prompt_coordinator.dart';
import 'package:git_desktop/src/app/git_desktop_app.dart';
import 'package:git_desktop/src/app/repository_session.dart';
import 'package:git_desktop/src/app/repository_view_mapper.dart';
import 'package:git_desktop/src/git/git.dart';
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
          child: const GitDesktopApp(isWorkspaceWindow: true),
        ),
      );
      final controller = container.read(repositorySessionProvider.notifier);
      await controller.openRepository(target.workingDirectory.path);
      await tester.pumpAndSettle();

      // The workspace opens on the history surface by default. Select the
      // file-status surface before asserting or mutating working-tree files.
      // The desktop integration runner can dispose a tap's asynchronous
      // callback while it is foregrounding the app, so await the same
      // application-layer selection used by the UI callback here.
      final workspaceReference = mapRepositoryOverview(
        container.read(repositorySessionProvider),
      ).repository!.refs.firstWhere((reference) => reference.id == 'workspace');
      await controller.selectReference(workspaceReference);
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();

      expect(find.text('workflow.md'), findsOneWidget);
      await tester.tap(find.byTooltip('暂存 workflow.md'));
      await tester.pumpAndSettle();
      expect(
        container.read(repositorySessionProvider).status!.stagedEntries,
        hasLength(1),
      );

      await tester.tap(find.bySemanticsLabel('打开提交面板'));
      await tester.pumpAndSettle();
      final commitDialog = find.byType(AlertDialog);
      expect(find.text('提交工作区改动'), findsOneWidget);
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
      final branchDialog = find.byKey(
        const ValueKey<String>('branch-manager-dialog'),
      );
      expect(find.text('新建分支'), findsWidgets);
      await tester.enterText(
        find.descendant(
          of: branchDialog,
          matching: find.byKey(const ValueKey<String>('branch-manager-name')),
        ),
        'feature/macos-e2e',
      );
      await tester.pump();
      final createBranchButton = find.byKey(
        const ValueKey<String>('branch-manager-create'),
      );
      await tester.tap(createBranchButton);
      for (var attempt = 0; attempt < 60; attempt += 1) {
        await tester.pump(const Duration(milliseconds: 100));
        if (container
            .read(repositorySessionProvider)
            .localBranches
            .any((branch) => branch.name == 'feature/macos-e2e')) {
          break;
        }
      }
      expect(
        (await target.runGit([
          'branch',
          '--show-current',
        ])).stdout.toString().trim(),
        'feature/macos-e2e',
      );
      await target.runGit([
        'show-ref',
        '--verify',
        '--quiet',
        'refs/heads/feature/macos-e2e',
      ]);
      for (var attempt = 0; attempt < 60; attempt += 1) {
        await tester.pump(const Duration(milliseconds: 100));
        final session = container.read(repositorySessionProvider);
        if (session.phase == RepositorySessionPhase.ready &&
            !session.isWorkingTreeBusy &&
            session.status?.branch.head == 'feature/macos-e2e') {
          break;
        }
      }

      await tester.tap(
        find.byKey(const ValueKey<String>('repository-action-push')),
      );
      await tester.pumpAndSettle();
      final pushDialog = find.byKey(const ValueKey<String>('push-dialog'));
      expect(pushDialog, findsOneWidget);
      await tester.tap(
        find.descendant(of: pushDialog, matching: find.byType(Checkbox)).first,
      );
      await tester.pump();
      await tester.tap(
        find.descendant(of: pushDialog, matching: find.text('确定')),
      );
      final localHead = (await target.runGit([
        'rev-parse',
        'HEAD',
      ])).stdout.toString().trim();
      String? remoteHead;
      for (var attempt = 0; attempt < 60; attempt += 1) {
        await tester.pump(const Duration(milliseconds: 100));
        try {
          remoteHead = (await source.runGit([
            'rev-parse',
            'refs/heads/feature/macos-e2e',
          ], workingDirectory: origin)).stdout.toString().trim();
          if (remoteHead == localHead) break;
        } on GitTestCommandException {
          // The push operation may still be starting or writing the bare ref.
        }
      }
      expect(remoteHead, localHead);
      for (var attempt = 0; attempt < 60; attempt += 1) {
        await tester.pump(const Duration(milliseconds: 100));
        final session = container.read(repositorySessionProvider);
        final hasRunningOperation = session.operations.any(
          (operation) =>
              operation.outcome == RepositoryOperationOutcome.running,
        );
        if (!session.isPushRunning &&
            !session.isWorkingTreeBusy &&
            !hasRunningOperation) {
          break;
        }
      }
      expect(container.read(repositorySessionProvider).status!.branch.ahead, 0);
    },
  );

  testWidgets('macOS app cancels and recovers a native AskPass request', (
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
    final session = await GitAskPassSession.start(
      onPrompt: coordinator.request,
    );
    addTearDown(session.close);

    Future<void> waitForPrompt(String label) async {
      for (var attempt = 0; attempt < 60; attempt += 1) {
        await tester.pump(const Duration(milliseconds: 100));
        if (find.text(label).evaluate().isNotEmpty) return;
      }
      fail('Timed out waiting for AskPass prompt: $label');
    }

    final environment = session.environmentForBundledHelper();
    final helper = environment['GIT_ASKPASS']!;
    expect(File(helper).existsSync(), isTrue);

    final helperProcess = await Process.start(
      helper,
      const ['Password for https://user:token@example.test/private:'],
      environment: <String, String>{...Platform.environment, ...environment},
      runInShell: false,
    );
    await waitForPrompt('需要密码');
    expect(session.status, GitAskPassSessionStatus.waitingForResponse);
    expect(find.textContaining('example.test'), findsNothing);
    expect(find.textContaining('user:token'), findsNothing);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(await helperProcess.exitCode, isNonZero);
    expect(session.status, GitAskPassSessionStatus.rejected);

    final recoverySession = await GitAskPassSession.start(
      onPrompt: coordinator.request,
    );
    addTearDown(recoverySession.close);
    final recoveryEnvironment = recoverySession.environmentForBundledHelper();
    final recoveryProcess = await Process.start(
      recoveryEnvironment['GIT_ASKPASS']!,
      const ['Password for https://private.example.test/retry:'],
      environment: <String, String>{
        ...Platform.environment,
        ...recoveryEnvironment,
      },
      runInShell: false,
    );
    await waitForPrompt('需要密码');
    expect(recoverySession.status, GitAskPassSessionStatus.waitingForResponse);
    await tester.enterText(find.byType(TextField), 'recovered-secret');
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();

    expect(await recoveryProcess.exitCode, 0);
    expect(
      await recoveryProcess.stdout.transform(utf8.decoder).join(),
      'recovered-secret\n',
    );
    expect(recoverySession.status, GitAskPassSessionStatus.completed);
  });

  testWidgets(
    'macOS app completes a real authenticated Git request through the UI',
    (tester) async {
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
      final session = await GitAskPassSession.start(
        onPrompt: coordinator.request,
      );
      addTearDown(session.close);

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      const expectedAuthorization = 'Basic Z2l0dXNlcjpnaXRwYXNz';
      const advertisedObject = '0123456789012345678901234567890123456789';
      var authenticatedRequestCount = 0;
      final serverSubscription = server.listen((request) async {
        if (request.headers.value(HttpHeaders.authorizationHeader) !=
            expectedAuthorization) {
          request.response
            ..statusCode = HttpStatus.unauthorized
            ..headers.set(
              HttpHeaders.wwwAuthenticateHeader,
              'Basic realm="git-desktop-ui-test"',
            )
            ..close();
          return;
        }

        authenticatedRequestCount += 1;
        final body = <int>[
          ...utf8.encode(_gitPktLine('# service=git-upload-pack\n')),
          ...utf8.encode('0000'),
          ...utf8.encode(
            _gitPktLine(
              '$advertisedObject HEAD\u0000symref=HEAD:refs/heads/main\n',
            ),
          ),
          ...utf8.encode('0000'),
        ];
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType(
            'application',
            'x-git-upload-pack-advertisement',
          )
          ..contentLength = body.length
          ..add(body);
        await request.response.close();
      });
      addTearDown(serverSubscription.cancel);

      final home = await Directory.systemTemp.createTemp(
        'git-desktop-ui-askpass-home-',
      );
      addTearDown(() => home.delete(recursive: true));

      final resultFuture = GitRunner().run(
        GitInvocation(
          arguments: <String>[
            'ls-remote',
            'http://127.0.0.1:${server.port}/repo.git',
          ],
          environment: <String, String>{
            ...session.environmentForBundledHelper(),
            'HOME': home.path,
            'GIT_CONFIG_NOSYSTEM': '1',
            'GIT_CONFIG_GLOBAL': '/dev/null',
            'GIT_CONFIG_SYSTEM': '/dev/null',
          },
        ),
      );

      Future<void> waitForPrompt(String label) async {
        for (var attempt = 0; attempt < 60; attempt += 1) {
          await tester.pump(const Duration(milliseconds: 100));
          if (find.text(label).evaluate().isNotEmpty) return;
        }
        fail('Timed out waiting for AskPass prompt: $label');
      }

      await waitForPrompt('需要用户名');
      await tester.enterText(find.byType(TextField), 'gituser');
      await tester.tap(find.text('继续'));
      await tester.pumpAndSettle();

      await waitForPrompt('需要密码');
      await tester.enterText(find.byType(TextField), 'gitpass');
      await tester.tap(find.text('继续'));
      await tester.pumpAndSettle();

      final result = await resultFuture;
      expect(result.isSuccess, isTrue, reason: result.stderrText);
      expect(
        result.stdoutText,
        matches(RegExp(r'^[0-9a-f]{40}\tHEAD\n', multiLine: true)),
      );
      expect(authenticatedRequestCount, greaterThanOrEqualTo(1));
      expect(session.status, GitAskPassSessionStatus.completed);
    },
  );

  testWidgets(
    'macOS app serves sequential username and password AskPass prompts',
    (tester) async {
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
      final session = await GitAskPassSession.start(
        onPrompt: coordinator.request,
      );
      addTearDown(session.close);
      final environment = session.environmentForBundledHelper();
      final helper = environment['GIT_ASKPASS']!;

      final usernameProcess = await Process.start(
        helper,
        const ['Username for https://private.example.test/retry:'],
        environment: <String, String>{...Platform.environment, ...environment},
        runInShell: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('需要用户名'), findsOneWidget);
      expect(session.status, GitAskPassSessionStatus.waitingForResponse);
      await tester.enterText(find.byType(TextField), 'git-user');
      await tester.tap(find.text('继续'));
      await tester.pumpAndSettle();
      expect(await usernameProcess.exitCode, 0);
      expect(
        await usernameProcess.stdout.transform(utf8.decoder).join(),
        'git-user\n',
      );
      expect(session.status, GitAskPassSessionStatus.completed);

      final passwordProcess = await Process.start(
        helper,
        const ['Password for https://private.example.test/retry:'],
        environment: <String, String>{...Platform.environment, ...environment},
        runInShell: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('需要密码'), findsOneWidget);
      expect(session.status, GitAskPassSessionStatus.waitingForResponse);
      await tester.enterText(find.byType(TextField), 'session-secret');
      await tester.tap(find.text('继续'));
      await tester.pumpAndSettle();
      expect(await passwordProcess.exitCode, 0);
      expect(
        await passwordProcess.stdout.transform(utf8.decoder).join(),
        'session-secret\n',
      );
      expect(session.status, GitAskPassSessionStatus.completed);
    },
  );
}

String _gitPktLine(String value) {
  final bytes = utf8.encode(value);
  final length = (bytes.length + 4).toRadixString(16).padLeft(4, '0');
  return '$length$value';
}
