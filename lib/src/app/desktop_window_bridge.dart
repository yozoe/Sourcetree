import 'dart:async';

import 'package:flutter/services.dart';

/// Sends window-management requests from Flutter to the macOS application.
///
/// The single native process owns every window and Flutter Engine so repository
/// workspaces remain isolated while sharing one application lifecycle.
final class DesktopWindowBridge {
  const DesktopWindowBridge._();

  static const MethodChannel _channel = MethodChannel(
    'com.yeknom.git_desktop/window',
  );
  static FutureOr<void> Function(String repositoryPath)?
  _repositoryOpenedHandler;
  static FutureOr<void> Function()? _prepareToCloseHandler;

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

  /// Reports the repository currently owned by this workspace window.
  static Future<void> repositoryOpened(String repositoryPath) {
    return _channel.invokeMethod<void>('repositoryOpened', <String, Object>{
      'repositoryPath': repositoryPath,
    });
  }

  /// Receives repositories opened by independent workspace Engines.
  static void setRepositoryOpenedHandler(
    FutureOr<void> Function(String repositoryPath)? handler,
  ) {
    _repositoryOpenedHandler = handler;
    _updateMethodCallHandler();
  }

  /// 中文：注册原生宿主销毁 Engine 前执行的清理；回调必须停止 Git 并释放 Dart 所有者。
  ///
  /// English: Registers cleanup before the native host destroys an Engine. The
  /// callback must stop active Git work and release Dart owners.
  static void setPrepareToCloseHandler(FutureOr<void> Function()? handler) {
    _prepareToCloseHandler = handler;
    _updateMethodCallHandler();
  }

  /// 中文：根据当前回调集合安装或移除原生调用处理器。
  /// English: Installs or removes the native call handler for active callbacks.
  static void _updateMethodCallHandler() {
    if (_repositoryOpenedHandler == null && _prepareToCloseHandler == null) {
      _channel.setMethodCallHandler(null);
      return;
    }
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  /// 中文：把原生窗口事件路由到当前 Engine 注册的 Dart 回调。
  /// English: Routes native window events to this Engine's Dart callbacks.
  static Future<void> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'repositoryOpened':
        final arguments = call.arguments;
        final repositoryPath = arguments is Map
            ? arguments['repositoryPath'] as String?
            : null;
        final handler = _repositoryOpenedHandler;
        if (handler == null ||
            repositoryPath == null ||
            repositoryPath.trim().isEmpty) {
          return;
        }
        await handler(repositoryPath);
        return;
      case 'prepareToClose':
        final handler = _prepareToCloseHandler;
        if (handler != null) await handler();
        return;
      default:
        throw MissingPluginException('Unknown window method: ${call.method}');
    }
  }
}
