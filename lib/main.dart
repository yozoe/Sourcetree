import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/app/git_desktop_app.dart';
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

/// Builds one Flutter application instance for either the library or a
/// workspace window.
Future<void> _runGitDesktop({
  required bool isWorkspaceWindow,
  String? initialRepositoryPath,
  String? initialWorkspaceAction,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  final container = ProviderContainer();
  final themeStore = FileGitDesktopThemePreferencesStore();
  final themePreferences = await themeStore.load();
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

/// Returns a value passed by the native launcher to a workspace process.
String? _argumentValue(List<String> arguments, String prefix) {
  for (final argument in arguments) {
    if (argument.startsWith(prefix)) return argument.substring(prefix.length);
  }
  return null;
}
