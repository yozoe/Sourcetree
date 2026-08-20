import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/app/git_desktop_app.dart';
import 'src/app/repository_session.dart';

/// 中文：启动桌面应用。
/// English: Starts the desktop application.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final container = ProviderContainer();
  unawaited(
    container.read(repositorySessionProvider.notifier).restoreSession(),
  );
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const GitDesktopApp(),
    ),
  );
}
