import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../presentation/presentation.dart';
import 'repository_session.dart';
import 'repository_view_mapper.dart';

class GitDesktopApp extends StatelessWidget {
  const GitDesktopApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Git Desktop',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: const RepositoryWorkspaceScreen(),
    );
  }
}

ThemeData _theme(Brightness brightness) {
  final colors = ColorScheme.fromSeed(
    seedColor: const Color(0xFF2767D8),
    brightness: brightness,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: colors,
    visualDensity: VisualDensity.compact,
    scaffoldBackgroundColor: colors.surface,
    dividerTheme: DividerThemeData(color: colors.outlineVariant, thickness: 1),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 650),
    ),
  );
}

class RepositoryWorkspaceScreen extends ConsumerStatefulWidget {
  const RepositoryWorkspaceScreen({super.key});

  @override
  ConsumerState<RepositoryWorkspaceScreen> createState() =>
      _RepositoryWorkspaceScreenState();
}

class _RepositoryWorkspaceScreenState
    extends ConsumerState<RepositoryWorkspaceScreen> {
  Future<void> _openRepository() async {
    final directory = await getDirectoryPath(confirmButtonText: '打开仓库');
    if (directory == null || !mounted) return;
    await ref
        .read(repositorySessionProvider.notifier)
        .openRepository(directory);
  }

  void _handleAction(RepositoryAction action) {
    switch (action) {
      case RepositoryAction.openRepository:
        _openRepository();
      case RepositoryAction.refresh:
      case RepositoryAction.retry:
        ref.read(repositorySessionProvider.notifier).refresh();
      default:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('此写操作将在下一个安全里程碑中开放。'),
            duration: Duration(seconds: 2),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(repositorySessionProvider);
    final controller = ref.read(repositorySessionProvider.notifier);
    return Scaffold(
      body: RepositoryOverview(
        data: mapRepositoryOverview(session),
        callbacks: RepositoryOverviewCallbacks(
          onAction: _handleAction,
          onSearchChanged: controller.setSearchQuery,
          onCommitSelected: (commit) => controller.selectCommit(commit.oid),
          onChangeSelected: controller.selectChange,
        ),
      ),
    );
  }
}
