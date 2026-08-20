import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/app/git_askpass_prompt_coordinator.dart';
import 'package:git_desktop/src/git/git.dart';

void main() {
  test('rejects a pending prompt when its provider is disposed', () async {
    final container = ProviderContainer();
    final answer = container
        .read(gitAskPassPromptCoordinatorProvider.notifier)
        .request(
          GitAskPassRequest.decode(
            '{"nonce":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","prompt":"Password:"}',
          ),
        );

    container.dispose();

    expect(await answer, isNull);
  });
}
