import 'dart:convert';
import 'dart:io';
import 'dart:math';

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

  /// 中文：保存当前数据。
  /// English: Saves the current data.
  Future<void> save(RepositorySessionSnapshot snapshot);
}

enum RepositorySessionLoadFailureKind { invalidData, io }

/// A persisted repository-session snapshot that could not be read safely.
///
/// 中文：持久化仓库会话快照无法安全读取时的分类异常；调用方可区分
/// 数据损坏与 I/O 故障，不得将它们当作“空清单”覆盖。
final class RepositorySessionLoadException implements Exception {
  const RepositorySessionLoadException(this.kind, this.cause);

  final RepositorySessionLoadFailureKind kind;
  final Object cause;

  @override
  String toString() => 'Repository session load failed ($kind): $cause';
}

/// Stores the last successfully opened repositories in the app support folder.
final class FileRepositorySessionStore implements RepositorySessionStore {
  /// 中文：创建文件仓库清单存储；测试可注入固定文件与随机源。
  ///
  /// English: Creates the file-backed repository list store; tests may inject
  /// a fixed file and random source.
  FileRepositorySessionStore({File? file, Random? random})
    : _fixedFile = file,
      _random = random ?? Random.secure();

  static const _fileName = 'repository-session.json';
  final File? _fixedFile;
  final Random _random;

  /// 中文：加载所需的数据。
  /// English: Loads the required data.
  @override
  Future<RepositorySessionSnapshot> load() async {
    final file = await _file();
    try {
      if (!await file.exists()) {
        return const RepositorySessionSnapshot();
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Snapshot root must be a JSON object.');
      }
      final rawPaths = decoded['openRepositoryPaths'];
      if (rawPaths is! List<Object?>) {
        throw const FormatException('openRepositoryPaths must be a list.');
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
    } on FormatException catch (error) {
      throw RepositorySessionLoadException(
        RepositorySessionLoadFailureKind.invalidData,
        error,
      );
    } on FileSystemException catch (error) {
      throw RepositorySessionLoadException(
        RepositorySessionLoadFailureKind.io,
        error,
      );
    }
  }

  /// 中文：保存当前数据。
  /// English: Saves the current data.
  @override
  Future<void> save(RepositorySessionSnapshot snapshot) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    File? temporaryFile;
    try {
      temporaryFile = File('${file.path}.tmp.$pid.${_randomToken()}');
      await temporaryFile.create(exclusive: true);
      await temporaryFile.writeAsString(
        '${jsonEncode({'openRepositoryPaths': snapshot.openRepositoryPaths, 'activeRepositoryPath': snapshot.activeRepositoryPath})}\n',
        flush: true,
      );
      await temporaryFile.rename(file.path);
      temporaryFile = null;
    } finally {
      if (temporaryFile != null) {
        try {
          if (await temporaryFile.exists()) await temporaryFile.delete();
        } on Object {
          // Preserve the original persistence failure.
        }
      }
    }
  }

  /// 中文：返回应用支持目录中保存仓库会话快照的 JSON 文件。
  ///
  /// English: Returns the JSON file in application support that stores the
  /// repository-session snapshot.
  Future<File> _file() async {
    final fixedFile = _fixedFile;
    if (fixedFile != null) return fixedFile;
    final directory = await getApplicationSupportDirectory();
    return File(path_utils.join(directory.path, _fileName));
  }

  /// 中文：生成仅用于区分同进程临时文件的随机路径片段。
  ///
  /// English: Generates a random path fragment used only to distinguish
  /// temporary files in this process.
  String _randomToken() => List<int>.generate(
    12,
    (_) => _random.nextInt(36),
  ).map((value) => value.toRadixString(36)).join();
}
