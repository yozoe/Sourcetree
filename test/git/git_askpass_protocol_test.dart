import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/git/git.dart';

void main() {
  const nonce =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  test(
    'decodes an authenticated password prompt without accepting secrets',
    () {
      final request = GitAskPassRequest.decode(
        '{"nonce":"$nonce","prompt":"Password for https://example.test:"}',
      );

      expect(request.nonce, nonce);
      expect(request.kind, GitAskPassPromptKind.password);
      expect(request.prompt, contains('example.test'));
    },
  );

  test('rejects unexpected IPC fields and invalid nonces', () {
    expect(
      () => GitAskPassRequest.decode(
        '{"nonce":"not-a-nonce","prompt":"Username:","secret":"no"}',
      ),
      throwsFormatException,
    );
  });

  test('rejects empty and oversized prompts', () {
    expect(
      () => GitAskPassRequest.decode('{"nonce":"$nonce","prompt":""}'),
      throwsFormatException,
    );
    final oversized = 'x' * (GitAskPassRequest.maxPromptLength + 1);
    expect(
      () =>
          GitAskPassRequest.decode('{"nonce":"$nonce","prompt":"$oversized"}'),
      throwsFormatException,
    );
  });
}
