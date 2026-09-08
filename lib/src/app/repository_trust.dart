import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path_utils;
import 'package:path_provider/path_provider.dart';

/// The explicit application-level permission state for one repository.
///
/// This never changes Git configuration. `unconfirmed` and `restricted`
/// require app-owned executable extensions to stay disabled; `trusted` only
/// permits extensions that the user has separately enabled in the app.
///
/// 中文：一个仓库的显式应用级权限状态。本状态不会修改 Git 配置；未确认和受限
/// 状态必须关闭应用自有的可执行扩展，信任状态也只允许用户另行启用的应用扩展。
enum RepositoryTrustStatus { unconfirmed, trusted, restricted }

/// A repository identity supplied by the Git inspection layer, never inferred
/// from a directory prefix or user name.
///
/// 中文：由 Git 检查层提供的仓库身份，不会从目录前缀或用户名推断。
final class RepositoryTrustId {
  const RepositoryTrustId({
    required this.commonDirectory,
    required this.workTreeRoot,
  });

  final String commonDirectory;
  final String? workTreeRoot;

  String get storageKey => jsonEncode(<String, String?>{
    'commonDirectory': commonDirectory,
    'workTreeRoot': workTreeRoot,
  });
}

abstract interface class RepositoryTrustStore {
  /// Loads the recorded trust status, defaulting to [RepositoryTrustStatus.unconfirmed].
  ///
  /// 中文：读取记录的信任状态；没有记录时默认为 [RepositoryTrustStatus.unconfirmed]。
  Future<RepositoryTrustStatus> load(RepositoryTrustId repository);

  /// Persists an explicit trust choice for exactly one Git repository identity.
  ///
  /// 中文：为一个精确的 Git 仓库身份持久化明确的信任选项。
  Future<void> save(RepositoryTrustId repository, RepositoryTrustStatus status);
}

/// A small, atomically replaced local store for app-owned trust decisions.
///
/// It deliberately stores no Git command, credential, hook, SSH, or remote
/// URL data. Tests may supply [file] and [random].
///
/// 中文：应用自有信任选项的小型原子本地存储。它刻意不保存 Git 命令、凭据、hooks、
/// SSH 或远端 URL；测试可注入 [file] 与 [random]。
final class FileRepositoryTrustStore implements RepositoryTrustStore {
  FileRepositoryTrustStore({File? file, Random? random})
    : _fixedFile = file,
      _random = random ?? Random.secure();

  static const _fileName = 'repository-trust.json';
  final File? _fixedFile;
  final Random _random;

  @override
  Future<RepositoryTrustStatus> load(RepositoryTrustId repository) async {
    final records = await _readRecords();
    return _statusFromName(records[repository.storageKey]);
  }

  @override
  Future<void> save(
    RepositoryTrustId repository,
    RepositoryTrustStatus status,
  ) async {
    final records = await _readRecords();
    records[repository.storageKey] = status.name;
    final file = await _file();
    await file.parent.create(recursive: true);
    File? temporaryFile;
    try {
      temporaryFile = File('${file.path}.tmp.$pid.${_randomToken()}');
      await temporaryFile.create(exclusive: true);
      await temporaryFile.writeAsString(
        '${jsonEncode(<String, Object>{'records': records})}\n',
        flush: true,
      );
      await temporaryFile.rename(file.path);
      temporaryFile = null;
    } finally {
      if (temporaryFile != null) {
        try {
          if (await temporaryFile.exists()) await temporaryFile.delete();
        } on Object {
          // Preserve the original write failure.
        }
      }
    }
  }

  Future<Map<String, String>> _readRecords() async {
    final file = await _file();
    try {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return <String, String>{};
      }
      if (await file.length() > 256 * 1024) return <String, String>{};
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['records'] is! Map) {
        return <String, String>{};
      }
      return <String, String>{
        for (final entry in (decoded['records'] as Map).entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: entry.value as String,
      };
    } on Object {
      return <String, String>{};
    }
  }

  RepositoryTrustStatus _statusFromName(String? value) =>
      RepositoryTrustStatus.values.firstWhere(
        (status) => status.name == value,
        orElse: () => RepositoryTrustStatus.unconfirmed,
      );

  Future<File> _file() async {
    final fixedFile = _fixedFile;
    if (fixedFile != null) return fixedFile;
    final directory = await getApplicationSupportDirectory();
    return File(path_utils.join(directory.path, _fileName));
  }

  String _randomToken() => List<int>.generate(
    12,
    (_) => _random.nextInt(256),
    growable: false,
  ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
}

/// Returns whether an application-owned external executable may be invoked.
///
/// Git core reads and writes remain governed by Git itself; this guard is only
/// for extensions the application chooses to expose, such as custom actions,
/// external diff, and textconv.
///
/// 中文：返回是否可以调用应用自有的外部可执行程序。Git 核心读写仍由 Git 本身
/// 决定；此 guard 仅适用于应用选择暴露的自定义操作、外部 Diff 与 textconv 等扩展。
bool canRunRepositoryExtension(RepositoryTrustStatus status) =>
    status == RepositoryTrustStatus.trusted;

/// Supplies app-owned trust persistence for the current Flutter Engine.
///
/// 中文：为当前 Flutter Engine 提供应用自有的信任持久化。
final repositoryTrustStoreProvider = Provider<RepositoryTrustStore>(
  (Ref ref) => FileRepositoryTrustStore(),
);

/// The trust status currently displayed for one repository workspace.
///
/// 中文：当前仓库工作区显示的信任状态。
final class RepositoryTrustState {
  const RepositoryTrustState({
    this.repository,
    this.status = RepositoryTrustStatus.unconfirmed,
    this.isLoading = false,
    this.saveFailureCount = 0,
  });

  final RepositoryTrustId? repository;
  final RepositoryTrustStatus status;
  final bool isLoading;
  final int saveFailureCount;

  RepositoryTrustState copyWith({
    RepositoryTrustId? repository,
    RepositoryTrustStatus? status,
    bool? isLoading,
    int? saveFailureCount,
  }) => RepositoryTrustState(
    repository: repository ?? this.repository,
    status: status ?? this.status,
    isLoading: isLoading ?? this.isLoading,
    saveFailureCount: saveFailureCount ?? this.saveFailureCount,
  );
}

/// Loads and persists explicit per-repository trust choices without touching Git.
///
/// 中文：加载和保存明确的逐仓库信任选项，不触碰 Git 配置。
final class RepositoryTrustController extends Notifier<RepositoryTrustState> {
  var _requestVersion = 0;

  @override
  RepositoryTrustState build() => const RepositoryTrustState();

  /// Makes [repository] current and discards a late result for an older window.
  ///
  /// 中文：将 [repository] 设为当前仓库，并丢弃旧窗口的迟到读取结果。若本地
  /// 存储不可用则恢复为安全的未确认状态，不阻塞仓库详情界面。
  ///
  /// English: Makes [repository] current and discards late results from older
  /// requests. If local storage is unavailable, it falls back to the safe
  /// unconfirmed state so the repository-details UI remains usable.
  Future<void> loadRepository(RepositoryTrustId repository) async {
    if (state.repository?.storageKey == repository.storageKey &&
        !state.isLoading) {
      return;
    }
    final request = ++_requestVersion;
    state = RepositoryTrustState(repository: repository, isLoading: true);
    try {
      final status = await ref
          .read(repositoryTrustStoreProvider)
          .load(repository);
      if (!ref.mounted || request != _requestVersion) return;
      state = RepositoryTrustState(repository: repository, status: status);
    } on Object {
      // Trust is an app-local convenience. If platform storage is unavailable,
      // recover to the safe default so the details view does not remain stuck
      // in a disabled loading state; extensions remain disallowed.
      if (!ref.mounted || request != _requestVersion) return;
      state = RepositoryTrustState(
        repository: repository,
        status: RepositoryTrustStatus.unconfirmed,
      );
    }
  }

  /// Records an explicit, reversible status for the currently loaded repository.
  ///
  /// 中文：为当前已加载仓库记录明确且可撤销的状态。
  Future<void> setStatus(RepositoryTrustStatus status) async {
    final repository = state.repository;
    if (repository == null || state.isLoading || state.status == status) return;
    final previous = state;
    state = state.copyWith(status: status);
    try {
      await ref.read(repositoryTrustStoreProvider).save(repository, status);
    } on Object {
      if (!ref.mounted ||
          state.repository?.storageKey != repository.storageKey) {
        return;
      }
      state = previous.copyWith(
        saveFailureCount: previous.saveFailureCount + 1,
      );
    }
  }
}

final repositoryTrustProvider =
    NotifierProvider<RepositoryTrustController, RepositoryTrustState>(
      RepositoryTrustController.new,
    );
