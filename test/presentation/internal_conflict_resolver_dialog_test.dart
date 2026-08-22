import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/presentation/presentation.dart';

void main() {
  testWidgets('compares both sides and returns the edited merge result', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? savedResult;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              savedResult = await showDialog<String>(
                context: context,
                builder: (context) => const InternalConflictResolverDialog(
                  path: 'lib/example.dart',
                  currentBranch: 'main',
                  oursText: 'same\nours\n',
                  theirsText: 'same\ntheirs\n',
                  workingText: 'same\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature\n',
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('解决冲突'), findsOneWidget);
    expect(find.text('我的版本 · main'), findsOneWidget);
    expect(find.text('他们的版本 · 合并来源'), findsOneWidget);
    expect(find.text('ours'), findsOneWidget);
    expect(find.text('theirs'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('conflict-difference-row-1')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('use-theirs-version')));
    await tester.pump();
    var editor = tester.widget<TextField>(
      find.byKey(const ValueKey('conflict-result-editor')),
    );
    expect(editor.controller!.text, 'same\ntheirs\n');

    await tester.enterText(
      find.byKey(const ValueKey('conflict-result-editor')),
      'same\nmerged\n',
    );
    await tester.tap(find.byKey(const ValueKey('save-conflict-result')));
    await tester.pumpAndSettle();

    expect(savedResult, 'same\nmerged\n');
  });

  testWidgets('prevents saving binary conflict contents', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: InternalConflictResolverDialog(
          path: 'image.dat',
          currentBranch: 'main',
          oursText: '',
          theirsText: '',
          workingText: '',
          isBinary: true,
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('conflict-resolver-warning')),
      findsOneWidget,
    );
    final save = tester.widget<FilledButton>(
      find.byKey(const ValueKey('save-conflict-result')),
    );
    expect(save.onPressed, isNull);
  });
}
