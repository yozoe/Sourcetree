import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path_utils;
import 'package:path_provider/path_provider.dart';

import 'external_tool_configuration.dart';

/// Persists the application-owned external Diff/Merge configuration only.
///
/// 中文：仅持久化应用自有的外部 Diff 配置；仓库信任、凭据和远端信息不属于此接口。
abstract interface class ExternalToolConfigurationStore {
  /// Loads a valid configuration, or null for missing, malformed, or unsafe data.
  /// 中文：读取有效配置；文件缺失、损坏或不安全时返回 null。
  Future<ExternalToolConfiguration?> load();

  /// Atomically saves or clears the configuration record.
  /// 中文：原子保存或清除配置记录。
  Future<void> save(ExternalToolConfiguration? configuration);
}

/// A small atomically replaced store for one external Diff/Merge template.
///
/// 中文：保存一个只读外部 Diff 模板的小型原子替换存储。
final class FileExternalToolConfigurationStore
    implements ExternalToolConfigurationStore {
  FileExternalToolConfigurationStore({File? file, Random? random})
    : _fixedFile = file,
      _random = random ?? Random.secure();

  static const _fileName = 'external-tool-configuration.json';
  static const _maxFileBytes = 64 * 1024;
  final File? _fixedFile;
  final Random _random;

  @override
  Future<ExternalToolConfiguration?> load() async {
    try {
      final file = await _file();
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return null;
      }
      if (await file.length() > _maxFileBytes) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['version'] != 1) return null;
      return ExternalToolConfiguration.fromJson(decoded['configuration']);
    } on Object {
      return null;
    }
  }

  @override
  Future<void> save(ExternalToolConfiguration? configuration) async {
    if (configuration != null && configuration.validate().isNotEmpty) {
      throw ArgumentError.value(
        configuration,
        'configuration',
        'Configuration must pass validation before persistence.',
      );
    }
    final file = await _file();
    await file.parent.create(recursive: true);
    File? temporaryFile;
    try {
      temporaryFile = File('${file.path}.tmp.$pid.${_randomToken()}');
      await temporaryFile.create(exclusive: true);
      await temporaryFile.writeAsString(
        '${jsonEncode(<String, Object?>{'version': 1, 'configuration': configuration?.toJson()})}\n',
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

/// Supplies external Diff configuration storage for the current Engine.
/// 中文：为当前 Flutter Engine 提供外部 Diff 配置存储。
final externalToolConfigurationStoreProvider =
    Provider<ExternalToolConfigurationStore>(
      (Ref ref) => FileExternalToolConfigurationStore(),
    );

/// The current Engine's external Diff configuration and persistence status.
///
/// 中文：当前 Engine 的外部 Diff 配置及持久化状态。
final class ExternalToolConfigurationState {
  const ExternalToolConfigurationState({
    this.configuration,
    this.isLoading = false,
    this.saveFailureCount = 0,
  });

  final ExternalToolConfiguration? configuration;
  final bool isLoading;
  final int saveFailureCount;

  ExternalToolConfigurationState copyWith({
    ExternalToolConfiguration? configuration,
    bool clearConfiguration = false,
    bool? isLoading,
    int? saveFailureCount,
  }) => ExternalToolConfigurationState(
    configuration: clearConfiguration
        ? null
        : configuration ?? this.configuration,
    isLoading: isLoading ?? this.isLoading,
    saveFailureCount: saveFailureCount ?? this.saveFailureCount,
  );
}

/// Loads, validates, and serializes the app-owned external Diff/Merge configuration.
///
/// 中文：加载、校验并顺序持久化应用自有的外部 Diff 配置。配置读取或写入失败
/// 都回退为不可用状态，不会绕过信任门槛或自动启用外部进程。
final class ExternalToolConfigurationController
    extends Notifier<ExternalToolConfigurationState> {
  Future<void> _saveTail = Future<void>.value();
  var _loadVersion = 0;

  @override
  ExternalToolConfigurationState build() {
    ref.onDispose(() => unawaited(_saveTail));
    return const ExternalToolConfigurationState();
  }

  /// Loads the persisted configuration and discards late results from an older request.
  /// 中文：读取持久化配置，并丢弃旧请求的迟到结果。
  Future<void> load() async {
    final request = ++_loadVersion;
    state = state.copyWith(isLoading: true);
    try {
      final configuration = await ref
          .read(externalToolConfigurationStoreProvider)
          .load();
      if (!ref.mounted || request != _loadVersion) return;
      state = ExternalToolConfigurationState(configuration: configuration);
    } on Object {
      if (!ref.mounted || request != _loadVersion) return;
      state = const ExternalToolConfigurationState();
    }
  }

  /// Queues one validated configuration write and publishes failures visibly.
  /// 中文：排队保存一个已校验配置，并以失败计数暴露持久化错误。
  Future<bool> save(ExternalToolConfiguration? configuration) async {
    if (configuration != null && configuration.validate().isNotEmpty) {
      return false;
    }
    final previous = state;
    state = state.copyWith(
      configuration: configuration,
      clearConfiguration: configuration == null,
      isLoading: false,
    );
    final write = _saveTail.then<void>((_) async {
      await ref
          .read(externalToolConfigurationStoreProvider)
          .save(configuration);
    });
    _saveTail = write.catchError((Object error, StackTrace stackTrace) {
      // The original [write] future remains the error observed by this caller;
      // this recovery future only keeps later queued writes usable.
      final stillCurrent = configuration == null
          ? state.configuration == null
          : identical(state.configuration, configuration);
      if (ref.mounted && stillCurrent) {
        state = previous.copyWith(
          saveFailureCount: previous.saveFailureCount + 1,
        );
      }
      // Keep the queue usable for a later retry; the current caller awaits
      // [write] below and still observes the failure.
    });
    try {
      await write;
      return true;
    } on Object {
      return false;
    }
  }

  /// Waits for all queued configuration writes before Engine shutdown.
  /// 中文：Engine 关闭前等待全部已排队的配置写入完成。
  Future<void> prepareForShutdown() => _saveTail;
}

/// Exposes the current Engine's external Diff configuration controller.
/// 中文：暴露当前 Engine 的外部 Diff 配置 controller。
final externalToolConfigurationProvider =
    NotifierProvider<
      ExternalToolConfigurationController,
      ExternalToolConfigurationState
    >(ExternalToolConfigurationController.new);
