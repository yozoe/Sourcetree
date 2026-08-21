import 'dart:async';

import 'package:flutter/services.dart';

/// Sends window-management requests from Flutter to the macOS application.
///
/// The native host owns the actual window and Flutter engine so repository
/// workspaces remain independent from the repository library window.
final class DesktopWindowBridge {
  const DesktopWindowBridge._();

  static const MethodChannel _channel = MethodChannel(
    'com.yeknom.git_desktop/window',
  );

  /// Opens a dedicated repository workspace window.
  ///
  /// A null [repositoryPath] creates an empty workspace, where the user can
  /// open, clone or initialize a repository using the existing safe flows.
  static Future<void> openWorkspace({
    String? repositoryPath,
    String? initialAction,
  }) {
    return _channel.invokeMethod<void>('openWorkspace', <String, Object?>{
      'repositoryPath': ?repositoryPath,
      'initialAction': ?initialAction,
    });
  }

  /// Reports the repository currently owned by this workspace process.
  static Future<void> repositoryOpened(String repositoryPath) {
    return _channel.invokeMethod<void>('repositoryOpened', <String, Object>{
      'repositoryPath': repositoryPath,
    });
  }

  /// Receives repositories opened by independent workspace processes.
  static void setRepositoryOpenedHandler(
    FutureOr<void> Function(String repositoryPath)? handler,
  ) {
    if (handler == null) {
      _channel.setMethodCallHandler(null);
      return;
    }
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method != 'repositoryOpened') {
        throw MissingPluginException('Unknown window method: ${call.method}');
      }
      final arguments = call.arguments;
      final repositoryPath = arguments is Map
          ? arguments['repositoryPath'] as String?
          : null;
      if (repositoryPath == null || repositoryPath.trim().isEmpty) return;
      await handler(repositoryPath);
    });
  }
}
