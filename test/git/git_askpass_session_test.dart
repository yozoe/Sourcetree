import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/git/git.dart';

void main() {
  test(
    'serves sequential authenticated prompts and removes its endpoint',
    () async {
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

      final passwordResponse = await _request(
        session,
        prompt: 'Password for https://example.test:',
      );
      final usernameResponse = await _request(
        session,
        prompt: 'Username for https://example.test:',
      );

      expect(passwordResponse, '{"secret":"correct horse battery staple"}\n');
      expect(usernameResponse, '{"secret":"correct horse battery staple"}\n');
      expect(received?.nonce, session.nonce);
      expect(received?.kind, GitAskPassPromptKind.username);
      await session.close();
      await session.closed;
      expect(await directory.exists(), isFalse);
      expect(
        (await FileStat.stat(session.socketPath)).type,
        FileSystemEntityType.notFound,
      );
    },
  );

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

  test('rejects malformed UTF-8 without calling the prompt handler', () async {
    var promptCalls = 0;
    final session = await GitAskPassSession.start(
      onPrompt: (_) async {
        promptCalls += 1;
        return 'must not be used';
      },
    );
    addTearDown(session.close);

    final socket = await _connect(session.socketPath);
    socket.add(<int>[0xff, 0x0a]);
    await socket.flush();

    expect(await utf8.decoder.bind(socket).join(), isEmpty);
    await session.closed;
    expect(promptCalls, 0);
    expect(session.status, GitAskPassSessionStatus.rejected);
  });

  test('rejects requests after an operation session closes', () async {
    final session = await GitAskPassSession.start(onPrompt: (_) async => 'one');
    addTearDown(session.close);

    expect(await _request(session, prompt: 'Password:'), '{"secret":"one"}\n');
    await session.close();
    await session.closed;

    await expectLater(
      _connect(session.socketPath),
      throwsA(isA<SocketException>()),
    );
  });

  test('serializes concurrent connections', () async {
    final promptStarted = Completer<void>();
    final allowResponse = Completer<void>();
    final session = await GitAskPassSession.start(
      onPrompt: (_) async {
        if (!promptStarted.isCompleted) {
          promptStarted.complete();
          await allowResponse.future;
        }
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

    final second = await _connect(session.socketPath);
    second.add(
      utf8.encode('{"nonce":"${session.nonce}","prompt":"Username:"}\n'),
    );
    await second.flush();
    allowResponse.complete();
    expect(await utf8.decoder.bind(first).join(), '{"secret":"secret"}\n');
    expect(await utf8.decoder.bind(second).join(), '{"secret":"secret"}\n');
    await session.close();
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

  test('restarts the idle timeout for each sequential prompt', () async {
    final session = await GitAskPassSession.start(
      timeout: const Duration(milliseconds: 300),
      onPrompt: (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 180));
        return 'secret';
      },
    );
    addTearDown(session.close);

    expect(await _request(session, prompt: 'Username:'), isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 180));
    expect(await _request(session, prompt: 'Password:'), isNotEmpty);
    expect(session.status, GitAskPassSessionStatus.completed);
  });

  test(
    'builds AskPass environment only from the session bundle path',
    () async {
      const appExecutablePath =
          '/Applications/Git Desktop.app/Contents/MacOS/Git Desktop';
      final session = await GitAskPassSession.startForTesting(
        onPrompt: (_) async => null,
        appExecutablePath: appExecutablePath,
        timeout: const Duration(seconds: 61),
      );
      addTearDown(session.close);

      final environment = session.environmentForBundledHelper();

      expect(
        environment['GIT_ASKPASS'],
        '/Applications/Git Desktop.app/Contents/MacOS/git-desktop-askpass',
      );
      expect(environment['GIT_TERMINAL_PROMPT'], '0');
      expect(environment['GIT_DESKTOP_ASKPASS_SOCKET'], session.socketPath);
      expect(environment['GIT_DESKTOP_ASKPASS_NONCE'], session.nonce);
      expect(environment['GIT_DESKTOP_ASKPASS_TIMEOUT_SECONDS'], '61');
      expect(session.environmentForBundledHelper, returnsNormally);
    },
  );

  test(
    'the native helper exchanges sequential secrets through the session socket',
    () async {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'git_desktop_askpass_helper_',
      );
      addTearDown(() => temporaryDirectory.delete(recursive: true));
      final macosDirectory = Directory(
        '${temporaryDirectory.path}/Git Desktop.app/Contents/MacOS',
      );
      await macosDirectory.create(recursive: true);
      final helper = File(
        '${macosDirectory.path}/${GitAskPassSession.helperFileName}',
      );
      final source = File(
        '${Directory.current.path}/macos/AskPassHelper/main.c',
      );
      final brokerSource = File(
        '${Directory.current.path}/macos/AskPassBroker/main.c',
      );
      final compilation = await Process.run('/usr/bin/clang', <String>[
        '-std=c11',
        '-O2',
        '-Wall',
        '-Wextra',
        '-Werror',
        source.path,
        '-o',
        helper.path,
      ]);
      expect(compilation.exitCode, 0, reason: compilation.stderr);
      final broker = File('${macosDirectory.path}/git-desktop-askpass-broker');
      final brokerCompilation = await Process.run('/usr/bin/clang', <String>[
        '-std=c11',
        '-O2',
        '-Wall',
        '-Wextra',
        '-Werror',
        brokerSource.path,
        '-o',
        broker.path,
      ]);
      expect(brokerCompilation.exitCode, 0, reason: brokerCompilation.stderr);

      final session = await GitAskPassSession.startForTesting(
        onPrompt: (request) async {
          expect(request.kind, GitAskPassPromptKind.password);
          await Future<void>.delayed(const Duration(milliseconds: 600));
          return 'test-only-secret';
        },
        appExecutablePath: '${macosDirectory.path}/Git Desktop',
        timeout: const Duration(seconds: 1),
        useNativeBroker: true,
      );
      addTearDown(session.close);
      final result = await Process.run(
        helper.path,
        <String>['Password for https://example.test:'],
        environment: session.environmentForBundledHelper(),
        includeParentEnvironment: false,
      );

      expect(result.exitCode, 0, reason: result.stderr);
      expect(result.stdout, 'test-only-secret\n');
      expect(result.stderr, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final secondResult = await Process.run(
        helper.path,
        <String>['Password for https://example.test:'],
        environment: session.environmentForBundledHelper(),
        includeParentEnvironment: false,
      );
      expect(secondResult.exitCode, 0, reason: secondResult.stderr);
      expect(secondResult.stdout, 'test-only-secret\n');
      await session.close();
      await session.closed;
      expect(session.status, GitAskPassSessionStatus.closed);

      final nonSocket = File('${temporaryDirectory.path}/not-a-socket');
      await nonSocket.writeAsString('not an IPC endpoint');
      final rejected = await Process.run(
        helper.path,
        <String>['Password:'],
        environment: <String, String>{
          'GIT_DESKTOP_ASKPASS_SOCKET': nonSocket.path,
          'GIT_DESKTOP_ASKPASS_NONCE': '0' * 64,
          'GIT_DESKTOP_ASKPASS_TIMEOUT_SECONDS': '60',
        },
        includeParentEnvironment: false,
      );
      expect(rejected.exitCode, 1);
      expect(rejected.stdout, isEmpty);

      final wrongNonceSession = await GitAskPassSession.startForTesting(
        onPrompt: (_) async => 'must not be used',
        appExecutablePath: '${macosDirectory.path}/Git Desktop',
      );
      addTearDown(wrongNonceSession.close);
      final wrongNonce = await Process.run(
        helper.path,
        <String>['Password:'],
        environment: <String, String>{
          ...wrongNonceSession.environmentForBundledHelper(),
          'GIT_DESKTOP_ASKPASS_NONCE': '0' * 64,
        },
        includeParentEnvironment: false,
      );
      expect(wrongNonce.exitCode, 1);
      expect(wrongNonce.stdout, isEmpty);
      await wrongNonceSession.closed;
      expect(wrongNonceSession.status, GitAskPassSessionStatus.rejected);
    },
    skip: !Platform.isMacOS,
  );

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
