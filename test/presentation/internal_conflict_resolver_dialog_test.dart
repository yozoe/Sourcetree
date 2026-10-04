import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/presentation/presentation.dart';

void main() {
  test('aligns insertions without shifting later equal lines', () {
    final lines = alignConflictLines(
      'first\ninserted\nsecond\nthird',
      'first\nsecond\nthird',
    );

    expect(
      lines
          .map(
            (line) => (
              line.oursLineNumber,
              line.oursText,
              line.theirsLineNumber,
              line.theirsText,
            ),
          )
          .toList(),
      [
        (1, 'first', 1, 'first'),
        (2, 'inserted', null, null),
        (3, 'second', 2, 'second'),
        (4, 'third', 3, 'third'),
      ],
    );
  });

  test(
    'parses complete conflict marker regions and preserves line content',
    () {
      final regions = parseConflictMarkerRegions(
        'prefix\n'
        '<<<<<<< HEAD\nours 1\n=======\ntheirs 1\n>>>>>>> feature\n'
        'middle\n'
        '<<<<<<< HEAD\nours 2\n=======\ntheirs 2\n>>>>>>> feature',
      );

      expect(regions, hasLength(2));
      expect(regions[0].oursText, 'ours 1\n');
      expect(regions[0].theirsText, 'theirs 1\n');
      expect(regions[1].oursText, 'ours 2\n');
      expect(regions[1].theirsText, 'theirs 2\n');
    },
  );

  test('does not expose an incomplete marker as a selectable region', () {
    expect(
      parseConflictMarkerRegions('<<<<<<< HEAD\nours\n=======\n'),
      isEmpty,
    );
  });

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
                  oursText: 'same\nours\nsame2\nours2\n',
                  theirsText: 'same\ntheirs\nsame2\ntheirs2\n',
                  workingText:
                      'same\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature\n'
                      'same2\n<<<<<<< HEAD\nours2\n=======\ntheirs2\n>>>>>>> feature\n',
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
    expect(
      find.byKey(const ValueKey('conflict-difference-row-3')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('conflict-equal-row-0')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('next-conflict-difference')));
    await tester.pumpAndSettle();
    expect(find.text('1/2'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('next-conflict-difference')));
    await tester.pumpAndSettle();
    expect(find.text('2/2'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('previous-conflict-difference')),
    );
    await tester.pumpAndSettle();
    expect(find.text('1/2'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('conflict-difference-row-1')));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(find.text('2/2'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('toggle-conflict-differences')));
    await tester.pump();
    expect(find.byTooltip('显示全部（2 处差异）'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('conflict-difference-row-1')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('conflict-equal-row-0')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('use-theirs-version')));
    await tester.pump();
    var editor = tester.widget<TextField>(
      find.byKey(const ValueKey('conflict-result-editor')),
    );
    expect(editor.controller!.text, 'same\ntheirs\nsame2\ntheirs2\n');

    await tester.enterText(
      find.byKey(const ValueKey('conflict-result-editor')),
      'same\nmerged\n',
    );
    await tester.tap(find.byKey(const ValueKey('save-conflict-result')));
    await tester.pumpAndSettle();

    expect(savedResult, 'same\nmerged\n');
  });

  testWidgets('reveals the shared base version on demand', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: InternalConflictResolverDialog(
          path: 'lib/example.dart',
          currentBranch: 'main',
          baseText: 'base line\n',
          hasBaseVersion: true,
          oursText: 'ours\n',
          theirsText: 'theirs\n',
          workingText: 'merged\n',
        ),
      ),
    );

    expect(find.byKey(const ValueKey('conflict-base-preview')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('toggle-conflict-base')));
    await tester.pump();

    expect(find.byKey(const ValueKey('conflict-base-preview')), findsOneWidget);
    expect(find.text('base line\n'), findsOneWidget);
  });

  testWidgets('can seed the merge result from the shared base version', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: InternalConflictResolverDialog(
          path: 'lib/example.dart',
          currentBranch: 'main',
          baseText: 'base line\n',
          hasBaseVersion: true,
          oursText: 'ours\n',
          theirsText: 'theirs\n',
          workingText: 'merged\n',
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('use-base-version')));
    await tester.pump();

    final editor = tester.widget<TextField>(
      find.byKey(const ValueKey('conflict-result-editor')),
    );
    expect(editor.controller!.text, 'base line\n');
  });

  testWidgets('resolves only the selected conflict marker region', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const working =
        'before\n'
        '<<<<<<< HEAD\nours 1\n=======\ntheirs 1\n>>>>>>> feature\n'
        'middle\n'
        '<<<<<<< HEAD\nours 2\n=======\ntheirs 2\n>>>>>>> feature\n'
        'after\n';
    await tester.pumpWidget(
      const MaterialApp(
        home: InternalConflictResolverDialog(
          path: 'lib/example.dart',
          currentBranch: 'main',
          oursText: 'ours\n',
          theirsText: 'theirs\n',
          workingText: working,
        ),
      ),
    );

    expect(find.text('逐段处理（共 2 段）'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('conflict-region-selector')));
    await tester.pumpAndSettle();
    expect(find.text('第 2 段'), findsOneWidget);
    await tester.tap(find.text('第 2 段'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('use-ours-conflict-region')));
    await tester.pump();
    var editor = tester.widget<TextField>(
      find.byKey(const ValueKey('conflict-result-editor')),
    );
    expect(editor.controller!.text, contains('ours 2'));
    expect(editor.controller!.text, isNot(contains('<<<<<<< HEAD\nours 2')));
    expect(editor.controller!.text, contains('<<<<<<< HEAD\nours 1'));

    await tester.tap(find.byKey(const ValueKey('use-theirs-conflict-region')));
    await tester.pump();
    editor = tester.widget<TextField>(
      find.byKey(const ValueKey('conflict-result-editor')),
    );
    expect(editor.controller!.text, contains('theirs 1'));
    expect(editor.controller!.text, isNot(contains('<<<<<<< HEAD\nours 1')));
  });

  testWidgets('allows an empty shared base for add/delete conflicts', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: InternalConflictResolverDialog(
          path: 'lib/example.dart',
          currentBranch: 'main',
          baseText: '',
          hasBaseVersion: true,
          oursText: 'ours\n',
          theirsText: '',
          workingText: 'merged\n',
        ),
      ),
    );

    expect(find.byKey(const ValueKey('conflict-base-preview')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('use-base-version')));
    await tester.pump();

    final editor = tester.widget<TextField>(
      find.byKey(const ValueKey('conflict-result-editor')),
    );
    expect(editor.controller!.text, isEmpty);
  });

  testWidgets('requires confirmation before saving conflict markers', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? savedResult;
    const conflictedText =
        '<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature\n';

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              savedResult = await showDialog<String>(
                context: context,
                builder: (context) => const InternalConflictResolverDialog(
                  path: 'lib/example.dart',
                  currentBranch: 'main',
                  oursText: 'ours\n',
                  theirsText: 'theirs\n',
                  workingText: conflictedText,
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
    await tester.tap(find.byKey(const ValueKey('save-conflict-result')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('conflict-marker-warning-dialog')),
      findsOneWidget,
    );
    expect(savedResult, isNull);

    await tester.tap(
      find.byKey(const ValueKey('confirm-conflict-marker-save')),
    );
    await tester.pumpAndSettle();

    expect(savedResult, conflictedText);
  });

  testWidgets('warns for a partial conflict marker left in the result', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? savedResult;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              savedResult = await showDialog<String>(
                context: context,
                builder: (context) => const InternalConflictResolverDialog(
                  path: 'lib/example.dart',
                  currentBranch: 'main',
                  oursText: 'ours\n',
                  theirsText: 'theirs\n',
                  workingText: 'resolved\n<<<<<<< stale marker\n',
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
    await tester.tap(find.byKey(const ValueKey('save-conflict-result')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('conflict-marker-warning-dialog')),
      findsOneWidget,
    );
    expect(savedResult, isNull);
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

  testWidgets('supports enlarged text without overflowing fixed diff rows', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: const InternalConflictResolverDialog(
          path: 'lib/example.dart',
          currentBranch: 'main',
          oursText: 'same\nours\nafter',
          theirsText: 'same\ntheirs\nafter',
          workingText: 'merged',
        ),
      ),
    );

    final exception = tester.takeException();
    expect(
      exception,
      isNull,
      reason: exception is FlutterError ? exception.toStringDeep() : null,
    );
    expect(
      find.byKey(const ValueKey('conflict-side-by-side-diff')),
      findsOneWidget,
    );
  });

  testWidgets('lays out long version actions at 900px and 200% text scale', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: const InternalConflictResolverDialog(
          path: 'lib/example.dart',
          currentBranch: 'feature/very-long-accessible-branch-name',
          oursText: 'ours',
          theirsText: 'theirs',
          workingText: 'merged',
          oursLabel: '当前分支版本 · feature/very-long-accessible-branch-name',
          theirsLabel: '正在重放的提交版本 · another-long-description',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final layoutException = tester.takeException();
    expect(
      layoutException,
      isNull,
      reason: layoutException is FlutterError
          ? layoutException.toStringDeep()
          : null,
    );
    final ours = find.byKey(const ValueKey('use-ours-version'));
    final theirs = find.byKey(const ValueKey('use-theirs-version'));
    expect(
      tester.getTopLeft(theirs).dx,
      greaterThan(tester.getTopLeft(ours).dx),
    );
  });

  testWidgets(
    'uses operation-aware labels and horizontally exposes long lines',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final longLine = 'value = ${List.filled(300, 'x').join()};';
      await tester.pumpWidget(
        MaterialApp(
          home: InternalConflictResolverDialog(
            path: 'lib/example.dart',
            currentBranch: 'feature',
            oursText: longLine,
            theirsText: '$longLine changed',
            workingText: longLine,
            oursLabel: '变基目标基线版本',
            theirsLabel: '正在重放的提交版本',
          ),
        ),
      );

      expect(find.text('变基目标基线版本'), findsOneWidget);
      expect(find.text('正在重放的提交版本'), findsOneWidget);
      final horizontal = tester.widget<SingleChildScrollView>(
        find.byKey(const ValueKey('conflict-horizontal-scroll')),
      );
      expect(horizontal.scrollDirection, Axis.horizontal);
      final horizontalFinder = find.byKey(
        const ValueKey('conflict-horizontal-scroll'),
      );
      final scrollable = find.descendant(
        of: horizontalFinder,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.right,
        ),
      );
      expect(
        tester.state<ScrollableState>(scrollable).position.maxScrollExtent,
        greaterThan(0),
      );
      await tester.drag(horizontalFinder, const Offset(-240, 0));
      await tester.pump();
      expect(
        tester.state<ScrollableState>(scrollable).position.pixels,
        greaterThan(0),
      );
    },
  );
}
