import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/app/desktop_window_bridge.dart';
import 'src/app/git_desktop_app.dart';
import 'src/app/repository_session.dart';
import 'src/app/theme_preferences.dart';

/// 中文：启动桌面应用。
/// English: Starts the desktop application.
Future<void> main(List<String> arguments) async {
  await _runGitDesktop(
    isWorkspaceWindow: arguments.contains('--git-desktop-workspace'),
    initialRepositoryPath: _argumentValue(
      arguments,
      '--git-desktop-repository=',
    ),
    initialWorkspaceAction: _argumentValue(arguments, '--git-desktop-action='),
  );
}

/// Builds one Flutter Engine UI for either the library or a workspace window.
Future<void> _runGitDesktop({
  required bool isWorkspaceWindow,
  String? initialRepositoryPath,
  String? initialWorkspaceAction,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  final container = ProviderContainer();
  final themeStore = FileGitDesktopThemePreferencesStore();
  final themePreferences = await themeStore.load();
  Future<void>? shutdownFuture;
  DesktopWindowBridge.setPrepareToCloseHandler(
    () => shutdownFuture ??= _prepareEngineToClose(container),
  );
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: GitDesktopApp(
        isWorkspaceWindow: isWorkspaceWindow,
        initialRepositoryPath: initialRepositoryPath,
        initialWorkspaceAction: initialWorkspaceAction,
        initialThemePreferences: themePreferences,
        themePreferencesStore: themeStore,
      ),
    ),
  );
}

/// 中文：在原生窗口宿主销毁 Flutter Engine 前取消任务并释放 Riverpod 容器。
///
/// English: Cancels Engine-owned work and releases its Riverpod container
/// before the native window host destroys the Flutter Engine.
Future<void> _prepareEngineToClose(ProviderContainer container) async {
  await container.read(repositorySessionProvider.notifier).prepareForShutdown();
  runApp(const SizedBox.shrink());
  try {
    await WidgetsBinding.instance.endOfFrame.timeout(
      const Duration(milliseconds: 500),
    );
  } on TimeoutException {
    // Native shutdown also has a bounded timeout. Provider cleanup must still
    // run when the window is no longer producing frames.
  }
  DesktopWindowBridge.setPrepareToCloseHandler(null);
  container.dispose();
}

/// Returns a value passed by the native host to this Flutter Engine.
String? _argumentValue(List<String> arguments, String prefix) {
  for (final argument in arguments) {
    if (argument.startsWith(prefix)) return argument.substring(prefix.length);
  }
  return null;
}
