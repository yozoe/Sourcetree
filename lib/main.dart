import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/app/git_desktop_app.dart';
import 'src/app/repository_session.dart';

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
