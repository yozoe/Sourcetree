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
  static FutureOr<void> Function(List<String> directoryPaths)?
  _repositoryDirectoriesDroppedHandler;
  static void Function(bool isActive)? _repositoryDirectoryDragStateHandler;
  static FutureOr<void> Function()? _prepareToCloseHandler;
  static FutureOr<void> Function(String action)? _workspaceActionHandler;

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

  /// Confirms that the home Engine can receive deferred repository
  /// registrations from active workspace windows.
  ///
  /// 中文：首页 Engine 已安装仓库回调，可接收工作区延迟登记的仓库。
  static Future<void> repositoryLibraryReady() {
    return _channel.invokeMethod<void>('repositoryLibraryReady');
  }

  /// Updates native workspace-menu availability from Flutter's current state.
  ///
  /// 中文：将 Flutter 已校验的工作区菜单可用状态同步给当前 macOS 窗口；原生
  /// 菜单只使用该快照控制可点击性，实际执行前仍由应用层重新校验 Git 状态。
  static Future<void> setWorkspaceMenuState({required bool canStopTracking}) {
    return _channel.invokeMethod<void>('setWorkspaceMenuState', <String, bool>{
      'canStopTracking': canStopTracking,
    });
  }

  /// 中文：报告启动恢复的仓库已无法由 Git 验证，以便原生宿主清除恢复记录并关闭该窗口。
  /// English: Reports that a restored repository can no longer be verified so
  /// the native host removes its restore record and closes that workspace.
  static Future<void> repositoryRestoreFailed(String repositoryPath) {
    return _channel.invokeMethod<void>(
      'repositoryRestoreFailed',
      <String, Object>{'repositoryPath': repositoryPath},
    );
  }

  /// Receives repositories opened by independent workspace Engines.
  static void setRepositoryOpenedHandler(
    FutureOr<void> Function(String repositoryPath)? handler,
  ) {
    _repositoryOpenedHandler = handler;
    _updateMethodCallHandler();
  }

  /// 中文：注册首页接收原生目录拖放后的回调。
  ///
  /// English: Registers the library callback for directories dropped by the
  /// native macOS window host.
  static void setRepositoryDirectoryDropHandlers({
    FutureOr<void> Function(List<String> directoryPaths)? onDirectoriesDropped,
    void Function(bool isActive)? onDragStateChanged,
  }) {
    _repositoryDirectoriesDroppedHandler = onDirectoriesDropped;
    _repositoryDirectoryDragStateHandler = onDragStateChanged;
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

  /// Registers menu actions delivered by the native macOS workspace menu.
  /// 中文：注册由原生 macOS 工作区菜单投递的动作。
  static void setWorkspaceActionHandler(
    FutureOr<void> Function(String action)? handler,
  ) {
    _workspaceActionHandler = handler;
    _updateMethodCallHandler();
  }

  /// 中文：根据当前回调集合安装或移除原生调用处理器。
  /// English: Installs or removes the native call handler for active callbacks.
  static void _updateMethodCallHandler() {
    if (_repositoryOpenedHandler == null &&
        _repositoryDirectoriesDroppedHandler == null &&
        _repositoryDirectoryDragStateHandler == null &&
        _prepareToCloseHandler == null &&
        _workspaceActionHandler == null) {
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
      case 'workspaceAction':
        final action = call.arguments is Map
            ? (call.arguments as Map)['action'] as String?
            : null;
        final handler = _workspaceActionHandler;
        if (handler != null && action != null && action.isNotEmpty) {
          await handler(action);
        }
        return;
      case 'repositoryDirectoriesDropped':
        final arguments = call.arguments;
        final paths = arguments is Map ? arguments['paths'] : null;
        final directoryPaths = paths is List
            ? paths
                  .whereType<String>()
                  .where((path) => path.trim().isNotEmpty)
                  .toList(growable: false)
            : const <String>[];
        final handler = _repositoryDirectoriesDroppedHandler;
        if (handler != null && directoryPaths.isNotEmpty) {
          await handler(directoryPaths);
        }
        return;
      case 'repositoryDirectoryDragState':
        final arguments = call.arguments;
        final isActive = arguments is Map && arguments['isActive'] == true;
        _repositoryDirectoryDragStateHandler?.call(isActive);
        return;
      default:
        throw MissingPluginException('Unknown window method: ${call.method}');
    }
  }
}
