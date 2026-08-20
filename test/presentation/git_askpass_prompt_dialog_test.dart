import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/git/git.dart';
import 'package:git_desktop/src/presentation/presentation.dart';

void main() {
  const nonce =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  testWidgets('redacts the raw prompt and disables password conveniences', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: _DialogHarness(
          request: GitAskPassRequest.decode(
            '{"nonce":"$nonce","prompt":"Password for https://user:token@example.test/private:"}',
          ),
        ),
      ),
    );

    await tester.tap(find.text('显示认证提示'));
    await tester.pumpAndSettle();

    expect(find.text('需要密码'), findsOneWidget);
    expect(find.textContaining('example.test'), findsNothing);
    expect(find.textContaining('user:token'), findsNothing);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.obscureText, isTrue);
    expect(field.enableSuggestions, isFalse);
    expect(field.autocorrect, isFalse);
    expect(field.enableInteractiveSelection, isFalse);
    expect(field.autofillHints, isNull);
  });

  testWidgets('returns a username only after explicit submission', (
    tester,
  ) async {
    String? answer;
    await tester.pumpWidget(
      MaterialApp(
        home: _DialogHarness(
          request: GitAskPassRequest.decode(
            '{"nonce":"$nonce","prompt":"Username for https://example.test:"}',
          ),
          onResult: (result) => answer = result,
        ),
      ),
    );

    await tester.tap(find.text('显示认证提示'));
    await tester.pumpAndSettle();
    final field = find.byType(TextField);
    expect(tester.widget<TextField>(field).obscureText, isFalse);
    await tester.enterText(field, 'octavia');
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();

    expect(answer, 'octavia');
  });

  testWidgets('returns null when the user cancels', (tester) async {
    String? answer = 'not completed';
    await tester.pumpWidget(
      MaterialApp(
        home: _DialogHarness(
          request: GitAskPassRequest.decode(
            '{"nonce":"$nonce","prompt":"Password:"}',
          ),
          onResult: (result) => answer = result,
        ),
      ),
    );

    await tester.tap(find.text('显示认证提示'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(answer, isNull);
  });
}

final class _DialogHarness extends StatefulWidget {
  const _DialogHarness({required this.request, this.onResult});

  final GitAskPassRequest request;
  final ValueChanged<String?>? onResult;

  @override
  State<_DialogHarness> createState() => _DialogHarnessState();
}

final class _DialogHarnessState extends State<_DialogHarness> {
  Future<void> _show() async {
    final result = await showGitAskPassPromptDialog(context, widget.request);
    widget.onResult?.call(result);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: FilledButton(onPressed: _show, child: const Text('显示认证提示')),
      ),
    );
  }
}
