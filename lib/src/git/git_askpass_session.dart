import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'git_askpass_protocol.dart';

typedef GitAskPassPromptHandler =
    Future<String?> Function(GitAskPassRequest request);

/// The non-secret state of a one-time AskPass IPC session.
enum GitAskPassSessionStatus {
  waitingForConnection,
  waitingForResponse,
  completed,
  rejected,
  timedOut,
  closed,
}

/// A single-use, local Unix-domain-socket channel for the bundled AskPass
/// helper.
///
/// The session deliberately stores neither prompt answers nor IPC payloads.
/// Its [onPrompt] callback is responsible for presenting a controlled UI and
/// returning an answer once. Calling [close], timing out, or answering a
/// request removes the socket and invalidates [nonce].
final class GitAskPassSession {
  GitAskPassSession._({
    required this.socketPath,
    required this.nonce,
    required this.onPrompt,
    required Directory socketDirectory,
    required ServerSocket? server,
    Process? broker,
    required Duration timeout,
    required String appExecutablePath,
  }) : _socketDirectory = socketDirectory,
       _server = server,
       _broker = broker,
       _timeout = timeout,
       _appExecutablePath = appExecutablePath;

  static const Duration defaultTimeout = Duration(seconds: 60);
  static const int maxSecretBytes = 16 * 1024;
  static const String helperFileName = 'git-desktop-askpass';
  static const int _maxRequestBytes =
      GitAskPassRequest.maxPromptLength * 2 + 256;
  static const int _unixSocketPathLimit = 103;

  /// Whether this process is the signed macOS application layout that ships
  /// the fixed AskPass helper. Development and test runtimes deliberately do
  /// not set `GIT_ASKPASS` to a guessed sibling executable.
  static bool get isBundledHelperAvailableForCurrentRuntime {
    final appExecutablePath = Platform.resolvedExecutable;
    return Platform.isMacOS &&
        _isMacAppBundle(appExecutablePath) &&
        File(_bundledHelperPathForExecutable(appExecutablePath)).existsSync();
  }

  /// Creates a local, single-use endpoint for one AskPass request.
  static Future<GitAskPassSession> start({
    required GitAskPassPromptHandler onPrompt,
    Duration timeout = defaultTimeout,
  }) => _start(
    onPrompt: onPrompt,
    timeout: timeout,
    appExecutablePath: Platform.resolvedExecutable,
    preferNativeBroker: true,
  );

  /// Creates a session with a fixture app executable path.
  ///
  /// This must only be used by tests. Production callers always derive the
  /// helper path from [Platform.resolvedExecutable] through [start].
  @visibleForTesting
  static Future<GitAskPassSession> startForTesting({
    required GitAskPassPromptHandler onPrompt,
    required String appExecutablePath,
    Duration timeout = defaultTimeout,
    bool useNativeBroker = false,
  }) => _start(
    onPrompt: onPrompt,
    timeout: timeout,
    appExecutablePath: appExecutablePath,
    preferNativeBroker: useNativeBroker,
  );

  static Future<GitAskPassSession> _start({
    required GitAskPassPromptHandler onPrompt,
    required Duration timeout,
    required String appExecutablePath,
    required bool preferNativeBroker,
  }) async {
    if (Platform.isWindows) {
      throw UnsupportedError(
        'Unix-domain AskPass sockets are not supported on Windows.',
      );
    }
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'Must be positive.');
    }

    final socketDirectory = await _createPrivateDirectory();
    final socketPath = '${socketDirectory.path}${Platform.pathSeparator}s';
    if (utf8.encode(socketPath).length > _unixSocketPathLimit) {
      await _deleteDirectory(socketDirectory);
      throw StateError(
        'The temporary directory path is too long for a Unix socket.',
      );
    }

    try {
      if (preferNativeBroker && _isMacAppBundle(appExecutablePath)) {
        final nonce = _newNonce();
        return await _startWithNativeBroker(
          onPrompt: onPrompt,
          timeout: timeout,
          appExecutablePath: appExecutablePath,
          socketDirectory: socketDirectory,
          socketPath: socketPath,
          nonce: nonce,
        );
      }
      final server = await ServerSocket.bind(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
        backlog: 1,
      );
      await _setPermissions(socketPath, '0600');
      await _verifyPrivateEndpoint(socketDirectory, socketPath);
      final session = GitAskPassSession._(
        socketPath: socketPath,
        nonce: _newNonce(),
        onPrompt: onPrompt,
        socketDirectory: socketDirectory,
        server: server,
        timeout: timeout,
        appExecutablePath: appExecutablePath,
      );
      session._startListening();
      return session;
    } catch (_) {
      await _deleteDirectory(socketDirectory);
      rethrow;
    }
  }

  final String socketPath;
  final String nonce;
  final GitAskPassPromptHandler onPrompt;
  final Directory _socketDirectory;
  final ServerSocket? _server;
  final Process? _broker;
  final Duration _timeout;
  final String _appExecutablePath;
  final Completer<void> _closedCompleter = Completer<void>();
  final Set<Socket> _clients = <Socket>{};

  StreamSubscription<Socket>? _serverSubscription;
  StreamSubscription<String>? _brokerOutputSubscription;
  Timer? _timeoutTimer;
  Future<void>? _closeFuture;
  GitAskPassSessionStatus _status =
      GitAskPassSessionStatus.waitingForConnection;
  bool _requestAccepted = false;

  GitAskPassSessionStatus get status => _status;

  /// Creates the explicit Git environment for the helper bundled next to the
  /// app executable. This does not enable AskPass by itself: callers must only
  /// pass it to an interactive, user-initiated Git invocation.
  ///
  /// The path is derived from the app bundle layout rather than a repository
  /// setting or remote input, so a repository cannot choose which executable
  /// receives credentials.
  Map<String, String> environmentForBundledHelper() {
    final helperPath = _bundledHelperPathForExecutable(_appExecutablePath);
    return Map<String, String>.unmodifiable(<String, String>{
      'GIT_ASKPASS': helperPath,
      'GIT_TERMINAL_PROMPT': '0',
      'GIT_DESKTOP_ASKPASS_SOCKET': socketPath,
      'GIT_DESKTOP_ASKPASS_NONCE': nonce,
    });
  }

  /// Completes only after the listener, socket file, and private directory
  /// have been closed or removed.
  Future<void> get closed => _closedCompleter.future;

  /// Cancels this session and rejects any current or future AskPass request.
  Future<void> close() => _closeWithStatus(GitAskPassSessionStatus.closed);

  void _startListening() {
    if (_broker != null) return;
    _timeoutTimer = Timer(_timeout, () {
      unawaited(_closeWithStatus(GitAskPassSessionStatus.timedOut));
    });
    _serverSubscription = _server!.listen(
      (client) => unawaited(_handleClient(client)),
      onError: (Object _) =>
          unawaited(_closeWithStatus(GitAskPassSessionStatus.rejected)),
      cancelOnError: true,
    );
  }

  Future<void> _handleClient(Socket client) async {
    if (_closeFuture != null || _requestAccepted) {
      await client.close();
      return;
    }
    _requestAccepted = true;
    _clients.add(client);
    _status = GitAskPassSessionStatus.waitingForResponse;
    await _server?.close();

    try {
      final payload = await _readRequestLine(client);
      if (_closeFuture != null) return;
      final request = GitAskPassRequest.decode(payload);
      if (request.nonce != nonce) {
        await _closeWithStatus(GitAskPassSessionStatus.rejected);
        return;
      }

      final secret = await onPrompt(request);
      if (_closeFuture != null) return;
      if (secret == null) {
        await _closeWithStatus(GitAskPassSessionStatus.rejected);
        return;
      }
      await _sendSecret(client, secret);
      await _closeWithStatus(GitAskPassSessionStatus.completed);
    } on FormatException {
      await _closeWithStatus(GitAskPassSessionStatus.rejected);
    } on SocketException {
      await _closeWithStatus(GitAskPassSessionStatus.rejected);
    } on IOException {
      await _closeWithStatus(GitAskPassSessionStatus.rejected);
    } on ArgumentError {
      await _closeWithStatus(GitAskPassSessionStatus.rejected);
    } catch (_) {
      await _closeWithStatus(GitAskPassSessionStatus.rejected);
    }
  }

  Future<void> _handleBrokerRequest(String payload) async {
    if (_closeFuture != null || _requestAccepted) return;
    _requestAccepted = true;
    _status = GitAskPassSessionStatus.waitingForResponse;
    try {
      final request = GitAskPassRequest.decode(payload);
      if (request.nonce != nonce) {
        await _closeWithStatus(GitAskPassSessionStatus.rejected);
        return;
      }
      final secret = await onPrompt(request);
      if (_closeFuture != null || secret == null) {
        await _closeWithStatus(GitAskPassSessionStatus.rejected);
        return;
      }
      final response = _encodeSecretResponse(secret);
      _broker!.stdin.add(utf8.encode(response));
      await _broker.stdin.flush();
      await _broker.exitCode;
      await _closeWithStatus(GitAskPassSessionStatus.completed);
    } on Object {
      await _closeWithStatus(GitAskPassSessionStatus.rejected);
    }
  }

  Future<void> _sendSecret(Socket client, String secret) async {
    final secretBytes = utf8.encode(secret);
    if (secretBytes.length > maxSecretBytes ||
        _containsControlCharacter(secret)) {
      throw const FormatException('AskPass secret is invalid.');
    }
    final response = _encodeSecretResponse(secret);
    final responseBytes = utf8.encode(response);
    // The current helper reserves 16 KiB for the complete JSON line, not only
    // the secret. Reject instead of truncating a credential.
    if (responseBytes.length > maxSecretBytes) {
      throw const FormatException('AskPass response is too large.');
    }
    client.add(responseBytes);
    await client.flush();
  }

  String _encodeSecretResponse(String secret) {
    final secretBytes = utf8.encode(secret);
    if (secretBytes.length > maxSecretBytes ||
        _containsControlCharacter(secret)) {
      throw const FormatException('AskPass secret is invalid.');
    }
    final response = '${jsonEncode(<String, String>{'secret': secret})}\n';
    if (utf8.encode(response).length > maxSecretBytes) {
      throw const FormatException('AskPass response is too large.');
    }
    return response;
  }

  Future<void> _closeWithStatus(GitAskPassSessionStatus status) {
    return _closeFuture ??= _close(status);
  }

  Future<void> _close(GitAskPassSessionStatus status) async {
    _status = status;
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    try {
      await _serverSubscription?.cancel();
    } catch (_) {
      // The session still owns the endpoint and must continue cleanup.
    }
    try {
      await _server?.close();
    } catch (_) {
      // Closing an already-closed listener is not security relevant.
    }
    await _brokerOutputSubscription?.cancel();
    final broker = _broker;
    if (broker != null) {
      try {
        await broker.stdin.close();
      } on IOException {
        // The broker may already have exited after forwarding a response.
      }
      broker.kill();
    }
    for (final client in _clients) {
      try {
        await client.close();
      } catch (_) {
        // A disconnected helper cannot prevent endpoint cleanup.
      }
    }
    _clients.clear();
    try {
      await _deleteDirectory(_socketDirectory);
    } finally {
      if (!_closedCompleter.isCompleted) {
        _closedCompleter.complete();
      }
    }
  }

  static Future<Directory> _createPrivateDirectory() async {
    final temporaryDirectory = Directory.systemTemp;
    final directory = await temporaryDirectory.createTemp('gda_');
    try {
      await _setPermissions(directory.path, '0700');
      final mode = (await directory.stat()).mode & 0x1ff;
      if (mode != 0x1c0) {
        throw FileSystemException(
          'AskPass directory permissions are not private.',
        );
      }
      return directory;
    } catch (_) {
      await _deleteDirectory(directory);
      rethrow;
    }
  }

  static String _bundledHelperPathForExecutable(String appExecutablePath) {
    final executable = File(appExecutablePath);
    if (!executable.isAbsolute) {
      throw ArgumentError.value(
        appExecutablePath,
        'appExecutablePath',
        'The app executable must be an absolute bundle path.',
      );
    }
    final macosDirectory = executable.parent;
    final contentsDirectory = macosDirectory.parent;
    final appDirectory = contentsDirectory.parent;
    if (!macosDirectory.path.endsWith('${Platform.pathSeparator}MacOS') ||
        !contentsDirectory.path.endsWith('${Platform.pathSeparator}Contents') ||
        !appDirectory.path.endsWith('.app')) {
      throw ArgumentError.value(
        appExecutablePath,
        'appExecutablePath',
        'The app executable must be inside a macOS app bundle.',
      );
    }
    return '${macosDirectory.path}${Platform.pathSeparator}$helperFileName';
  }

  static Future<GitAskPassSession> _startWithNativeBroker({
    required GitAskPassPromptHandler onPrompt,
    required Duration timeout,
    required String appExecutablePath,
    required Directory socketDirectory,
    required String socketPath,
    required String nonce,
  }) async {
    final brokerPath = _bundledBrokerPathForExecutable(appExecutablePath);
    if (!await File(brokerPath).exists()) {
      throw StateError('The bundled AskPass broker is unavailable.');
    }
    final broker = await Process.start(
      brokerPath,
      <String>[socketPath, nonce],
      includeParentEnvironment: false,
      runInShell: false,
    );
    final ready = Completer<void>();
    late final GitAskPassSession session;
    final subscription = broker.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (!ready.isCompleted) {
              if (line == 'READY') {
                ready.complete();
              } else {
                ready.completeError(
                  StateError('The AskPass broker did not become ready.'),
                );
              }
              return;
            }
            unawaited(session._handleBrokerRequest(line));
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!ready.isCompleted) {
              ready.completeError(error, stackTrace);
            } else {
              unawaited(
                session._closeWithStatus(GitAskPassSessionStatus.rejected),
              );
            }
          },
          onDone: () {
            if (!ready.isCompleted) {
              ready.completeError(
                StateError('The AskPass broker exited before becoming ready.'),
              );
            }
          },
        );
    session = GitAskPassSession._(
      socketPath: socketPath,
      nonce: nonce,
      onPrompt: onPrompt,
      socketDirectory: socketDirectory,
      server: null,
      broker: broker,
      timeout: timeout,
      appExecutablePath: appExecutablePath,
    );
    session._brokerOutputSubscription = subscription;
    session._timeoutTimer = Timer(timeout, () {
      unawaited(session._closeWithStatus(GitAskPassSessionStatus.timedOut));
    });
    try {
      await ready.future.timeout(timeout);
      return session;
    } catch (_) {
      await session.close();
      rethrow;
    }
  }

  static String _bundledBrokerPathForExecutable(String appExecutablePath) {
    return '${File(appExecutablePath).parent.path}${Platform.pathSeparator}'
        'git-desktop-askpass-broker';
  }

  static bool _isMacAppBundle(String executablePath) {
    final macosDirectory = File(executablePath).parent;
    return Platform.isMacOS &&
        macosDirectory.path.endsWith('${Platform.pathSeparator}MacOS') &&
        macosDirectory.parent.path.endsWith(
          '${Platform.pathSeparator}Contents',
        ) &&
        macosDirectory.parent.parent.path.endsWith('.app');
  }

  static Future<void> _verifyPrivateEndpoint(
    Directory directory,
    String socketPath,
  ) async {
    final directoryStat = await directory.stat();
    final socketStat = await FileStat.stat(socketPath);
    if ((directoryStat.mode & 0x1ff) != 0x1c0 ||
        socketStat.type != FileSystemEntityType.unixDomainSock ||
        (socketStat.mode & 0x1ff) != 0x180) {
      throw FileSystemException(
        'AskPass socket permissions could not be verified.',
      );
    }
  }

  static Future<void> _setPermissions(String path, String mode) async {
    final result = await Process.run('/bin/chmod', <String>[mode, path]);
    if (result.exitCode != 0) {
      throw FileSystemException('Could not protect AskPass IPC endpoint.');
    }
  }

  static Future<void> _deleteDirectory(Directory directory) async {
    try {
      await directory.delete(recursive: true);
    } on FileSystemException {
      // Cleanup must not replace the real operation result. The directory is
      // private and contains no persisted secret.
    }
  }

  static String _newNonce() {
    final random = Random.secure();
    final buffer = StringBuffer();
    for (var index = 0; index < 32; index += 1) {
      buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  static bool _containsControlCharacter(String value) {
    return value.codeUnits.any((unit) => unit < 0x20);
  }

  static Future<String> _readRequestLine(Socket client) {
    final completer = Completer<String>();
    final bytes = BytesBuilder(copy: false);
    late final StreamSubscription<List<int>> subscription;

    void fail(Object error) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
      unawaited(subscription.cancel());
    }

    subscription = client.listen(
      (chunk) {
        for (var index = 0; index < chunk.length; index += 1) {
          final byte = chunk[index];
          if (byte == 0x0a) {
            if (index != chunk.length - 1 || completer.isCompleted) {
              fail(
                const FormatException('AskPass request contains extra data.'),
              );
              return;
            }
            try {
              completer.complete(utf8.decode(bytes.takeBytes()));
            } on FormatException catch (error) {
              completer.completeError(error);
            }
            unawaited(subscription.cancel());
            return;
          }
          if (bytes.length >= _maxRequestBytes) {
            fail(const FormatException('AskPass request is too large.'));
            return;
          }
          bytes.addByte(byte);
        }
      },
      onError: (Object error, StackTrace _) => fail(error),
      onDone: () {
        if (!completer.isCompleted) {
          fail(
            const FormatException('AskPass request ended before a newline.'),
          );
        }
      },
      cancelOnError: true,
    );
    return completer.future;
  }
}
