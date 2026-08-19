import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:git_desktop/src/app/git_desktop_app.dart';
import 'package:git_desktop/src/presentation/presentation.dart';

void main() {
  testWidgets('shows supported actions on first launch', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: GitDesktopApp()));

    expect(find.text('打开一个 Git 仓库'), findsOneWidget);
    expect(find.text('打开仓库'), findsOneWidget);
    expect(find.text('克隆仓库'), findsNothing);
    expect(find.text('初始化仓库'), findsOneWidget);
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
}
