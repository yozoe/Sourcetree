import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/hosting/github_keychain.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.yeknom.git_desktop/github_auth');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'readAccessToken' ? 'ghp_from_keychain' : null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('reads, writes and deletes through the dedicated channel', () async {
    final store = MacOSGitHubAccessTokenStore(channel: channel);

    expect(await store.read(), 'ghp_from_keychain');
    await store.write('ghp_explicit_token');
    await store.delete();

    expect(calls.map((call) => call.method), [
      'readAccessToken',
      'writeAccessToken',
      'deleteAccessToken',
    ]);
    expect(calls[1].arguments, {'token': 'ghp_explicit_token'});
  });

  test(
    'rejects empty, padded and control-character tokens before IPC',
    () async {
      final store = MacOSGitHubAccessTokenStore(channel: channel);

      for (final token in <String>['', ' token', 'token ', 'token\n']) {
        await expectLater(store.write(token), throwsA(isA<FormatException>()));
      }
      expect(calls, isEmpty);
    },
  );
}
