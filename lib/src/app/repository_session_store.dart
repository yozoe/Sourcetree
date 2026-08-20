import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path_utils;
import 'package:path_provider/path_provider.dart';

/// The non-sensitive workspace state retained between application launches.
final class RepositorySessionSnapshot {
  const RepositorySessionSnapshot({
    this.openRepositoryPaths = const [],
    this.activeRepositoryPath,
  });

  final List<String> openRepositoryPaths;
  final String? activeRepositoryPath;
}

abstract interface class RepositorySessionStore {
  Future<RepositorySessionSnapshot> load();

  Future<void> save(RepositorySessionSnapshot snapshot);
}

/// Stores the last successfully opened repositories in the app support folder.
final class FileRepositorySessionStore implements RepositorySessionStore {
  static const _fileName = 'repository-session.json';

  @override
  Future<RepositorySessionSnapshot> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) {
        return const RepositorySessionSnapshot();
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        return const RepositorySessionSnapshot();
      }
      final rawPaths = decoded['openRepositoryPaths'];
      if (rawPaths is! List<Object?>) {
        return const RepositorySessionSnapshot();
      }
      final paths = <String>[];
      final seenPaths = <String>{};
      for (final rawPath in rawPaths) {
        if (rawPath is! String) continue;
        final normalizedPath = rawPath.trim();
        if (normalizedPath.isNotEmpty && seenPaths.add(normalizedPath)) {
          paths.add(normalizedPath);
        }
      }
      final rawActivePath = decoded['activeRepositoryPath'];
      final activePath =
          rawActivePath is String && paths.contains(rawActivePath)
          ? rawActivePath
          : null;
      return RepositorySessionSnapshot(
        openRepositoryPaths: List<String>.unmodifiable(paths),
        activeRepositoryPath: activePath,
      );
    } on Object {
      return const RepositorySessionSnapshot();
    }
  }

  @override
  Future<void> save(RepositorySessionSnapshot snapshot) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({
        'openRepositoryPaths': snapshot.openRepositoryPaths,
        'activeRepositoryPath': snapshot.activeRepositoryPath,
      }),
      flush: true,
    );
  }

  Future<File> _file() async {
    final directory = await getApplicationSupportDirectory();
    return File(path_utils.join(directory.path, _fileName));
  }
}
