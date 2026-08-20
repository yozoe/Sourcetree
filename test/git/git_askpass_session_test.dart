import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/git/git.dart';

void main() {
  test('serves one authenticated prompt and removes its endpoint', () async {
    GitAskPassRequest? received;
    final session = await GitAskPassSession.start(
      onPrompt: (request) async {
        received = request;
        return 'correct horse battery staple';
      },
    );
    addTearDown(session.close);

    final directory = Directory(File(session.socketPath).parent.path);
    expect((await directory.stat()).mode & 0x1ff, 0x1c0);
    expect((await FileStat.stat(session.socketPath)).mode & 0x1ff, 0x180);
    expect(
      (await FileStat.stat(session.socketPath)).type,
      FileSystemEntityType.unixDomainSock,
    );

    final response = await _request(
      session,
      prompt: 'Password for https://example.test:',
    );

    expect(response, '{"secret":"correct horse battery staple"}\n');
    expect(received?.nonce, session.nonce);
    expect(received?.kind, GitAskPassPromptKind.password);
    await session.closed;
    expect(await directory.exists(), isFalse);
    expect(
      (await FileStat.stat(session.socketPath)).type,
      FileSystemEntityType.notFound,
    );
  });

  test(
    'rejects a mismatched nonce without calling the prompt handler',
    () async {
      var promptCalls = 0;
      final session = await GitAskPassSession.start(
        onPrompt: (_) async {
          promptCalls += 1;
          return 'must not be used';
        },
      );
      addTearDown(session.close);

      final socket = await _connect(session.socketPath);
      socket.add(utf8.encode('{"nonce":"${'0' * 64}","prompt":"Password:"}\n'));
      await socket.flush();
      expect(await utf8.decoder.bind(socket).join(), isEmpty);
      await session.closed;

      expect(promptCalls, 0);
      expect(session.status, GitAskPassSessionStatus.rejected);
    },
  );

  test('allows only one connection', () async {
    final promptStarted = Completer<void>();
    final allowResponse = Completer<void>();
    final session = await GitAskPassSession.start(
      onPrompt: (_) async {
        promptStarted.complete();
        await allowResponse.future;
        return 'secret';
      },
    );
    addTearDown(session.close);

    final first = await _connect(session.socketPath);
    first.add(
      utf8.encode('{"nonce":"${session.nonce}","prompt":"Password:"}\n'),
    );
    await first.flush();
    await promptStarted.future;

    await expectLater(
      _connect(session.socketPath),
      throwsA(isA<SocketException>()),
    );
    allowResponse.complete();
    expect(await utf8.decoder.bind(first).join(), '{"secret":"secret"}\n');
    await session.closed;
  });

  test('times out and removes an unused endpoint', () async {
    final session = await GitAskPassSession.start(
      timeout: const Duration(milliseconds: 25),
      onPrompt: (_) async => 'not used',
    );
    final directory = Directory(File(session.socketPath).parent.path);

    await session.closed;

    expect(session.status, GitAskPassSessionStatus.timedOut);
    expect(await directory.exists(), isFalse);
  });

  test('builds AskPass environment only from the bundled app path', () async {
    final session = await GitAskPassSession.start(onPrompt: (_) async => null);
    addTearDown(session.close);

    final environment = session.environmentForBundledHelper(
      appExecutablePath:
          '/Applications/Git Desktop.app/Contents/MacOS/Git Desktop',
    );

    expect(
      environment['GIT_ASKPASS'],
      '/Applications/Git Desktop.app/Contents/MacOS/git-desktop-askpass',
    );
    expect(environment['GIT_TERMINAL_PROMPT'], '0');
    expect(environment['GIT_DESKTOP_ASKPASS_SOCKET'], session.socketPath);
    expect(environment['GIT_DESKTOP_ASKPASS_NONCE'], session.nonce);
    expect(
      () => session.environmentForBundledHelper(
        appExecutablePath: 'not-a-bundle',
      ),
      throwsArgumentError,
    );
    expect(
      () =>
          session.environmentForBundledHelper(appExecutablePath: '/tmp/helper'),
      throwsArgumentError,
    );
  });

  test(
    'treats a cancelled prompt as rejection instead of an empty secret',
    () async {
      final session = await GitAskPassSession.start(
        onPrompt: (_) async => null,
      );
      addTearDown(session.close);

      final response = await _request(session, prompt: 'Password:');

      expect(response, isEmpty);
      await session.closed;
      expect(session.status, GitAskPassSessionStatus.rejected);
    },
  );

  test(
    'close cancels a pending prompt and removes the socket immediately',
    () async {
      final promptStarted = Completer<void>();
      final allowPromptToFinish = Completer<void>();
      final session = await GitAskPassSession.start(
        onPrompt: (_) async {
          promptStarted.complete();
          await allowPromptToFinish.future;
          return 'not sent after close';
        },
      );
      final directory = Directory(File(session.socketPath).parent.path);
      final socket = await _connect(session.socketPath);
      socket.add(
        utf8.encode('{"nonce":"${session.nonce}","prompt":"Password:"}\n'),
      );
      await socket.flush();
      await promptStarted.future;

      await session.close();

      expect(session.status, GitAskPassSessionStatus.closed);
      expect(await directory.exists(), isFalse);
      allowPromptToFinish.complete();
      expect(await utf8.decoder.bind(socket).join(), isEmpty);
    },
  );

  test('rejects a response that would exceed the helper frame limit', () async {
    final session = await GitAskPassSession.start(
      onPrompt: (_) async => '"' * GitAskPassSession.maxSecretBytes,
    );
    addTearDown(session.close);

    final response = await _request(session, prompt: 'Password:');

    expect(response, isEmpty);
    await session.closed;
    expect(session.status, GitAskPassSessionStatus.rejected);
  });
}

Future<Socket> _connect(String path) {
  return Socket.connect(
    InternetAddress(path, type: InternetAddressType.unix),
    0,
  );
}

Future<String> _request(
  GitAskPassSession session, {
  required String prompt,
}) async {
  final socket = await _connect(session.socketPath);
  socket.add(utf8.encode('{"nonce":"${session.nonce}","prompt":"$prompt"}\n'));
  await socket.flush();
  return utf8.decoder.bind(socket).join();
}
