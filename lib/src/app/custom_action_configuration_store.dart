import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path_utils;
import 'package:path_provider/path_provider.dart';

import 'custom_action_configuration.dart';

/// Persists application-owned custom-action definitions without repository
/// paths, trust decisions, credentials, or process output.
///
/// 中文：保存应用自有的自定义操作定义，不保存仓库路径、信任决定、凭据或进程
/// 输出；仓库信任在每次加载仓库时独立读取。
abstract interface class CustomActionConfigurationStore {
  /// Loads all valid definitions, returning an empty list for missing or unsafe data.
  ///
  /// 中文：读取全部有效定义；文件缺失、损坏或不安全时返回空列表。
  Future<List<CustomActionConfiguration>> load();

  /// Atomically replaces all definitions after validating the complete set.
  ///
  /// 中文：完整校验后原子替换全部定义；任何重复或不安全项都会拒绝整批写入。
  Future<void> save(List<CustomActionConfiguration> configurations);
}

/// A bounded, atomically replaced store for custom-action definitions.
///
/// 中文：带大小和数量上限、使用原子替换写入的自定义操作定义存储。
final class FileCustomActionConfigurationStore
    implements CustomActionConfigurationStore {
  FileCustomActionConfigurationStore({File? file, Random? random})
    : _fixedFile = file,
      _random = random ?? Random.secure();

  static const int maxConfigurations = 32;
  static const int _maxFileBytes = 256 * 1024;
  final File? _fixedFile;
  final Random _random;

  @override
  Future<List<CustomActionConfiguration>> load() async {
    try {
      final file = await _file();
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return const [];
      }
      if (await file.length() > _maxFileBytes) return const [];
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['version'] != 1) return const [];
      final rawConfigurations = decoded['configurations'];
      if (rawConfigurations is! List ||
          rawConfigurations.length > maxConfigurations) {
        return const [];
      }
      final configurations = <CustomActionConfiguration>[];
      final ids = <String>{};
      for (final raw in rawConfigurations) {
        final configuration = CustomActionConfiguration.fromJson(raw);
        if (configuration == null || !ids.add(configuration.id)) {
          return const [];
        }
        configurations.add(configuration);
      }
      return List<CustomActionConfiguration>.unmodifiable(configurations);
    } on Object {
      return const [];
    }
  }

  @override
  Future<void> save(List<CustomActionConfiguration> configurations) async {
    if (configurations.length > maxConfigurations) {
      throw ArgumentError.value(
        configurations.length,
        'configurations',
        'Too many custom actions.',
      );
    }
    final ids = <String>{};
    for (final configuration in configurations) {
      if (configuration.validate().isNotEmpty || !ids.add(configuration.id)) {
        throw ArgumentError.value(
          configurations,
          'configurations',
          'All custom actions must be valid and have unique IDs.',
        );
      }
    }
    final file = await _file();
    await file.parent.create(recursive: true);
    File? temporaryFile;
    try {
      temporaryFile = File('${file.path}.tmp.$pid.${_randomToken()}');
      await temporaryFile.create(exclusive: true);
      await temporaryFile.writeAsString(
        '${jsonEncode(<String, Object>{
          'version': 1,
          'configurations': [for (final configuration in configurations) configuration.toJson()],
        })}\n',
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
    return File(path_utils.join(directory.path, 'custom-actions.json'));
  }

  String _randomToken() => List<int>.generate(
    12,
    (_) => _random.nextInt(256),
    growable: false,
  ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
}

/// Provides application-owned custom-action storage for the current Engine.
///
/// 中文：为当前 Flutter Engine 提供应用自有的自定义操作存储。
final customActionConfigurationStoreProvider =
    Provider<CustomActionConfigurationStore>(
      (Ref ref) => FileCustomActionConfigurationStore(),
    );

/// The current custom-action definitions and persistence status.
///
/// 中文：当前自定义操作定义及其持久化状态。
final class CustomActionConfigurationState {
  const CustomActionConfigurationState({
    this.configurations = const <CustomActionConfiguration>[],
    this.isLoading = false,
    this.saveFailureCount = 0,
  });

  final List<CustomActionConfiguration> configurations;
  final bool isLoading;
  final int saveFailureCount;

  /// Returns a copy with an immutable configuration list.
  ///
  /// 中文：返回带不可变配置列表的状态副本。
  CustomActionConfigurationState copyWith({
    List<CustomActionConfiguration>? configurations,
    bool? isLoading,
    int? saveFailureCount,
  }) => CustomActionConfigurationState(
    configurations: configurations ?? this.configurations,
    isLoading: isLoading ?? this.isLoading,
    saveFailureCount: saveFailureCount ?? this.saveFailureCount,
  );
}

/// Loads and serializes custom-action definitions without enabling execution.
///
/// 中文：读取并顺序保存自定义操作定义，但不会因保存配置而启用执行。
final class CustomActionConfigurationController
    extends Notifier<CustomActionConfigurationState> {
  Future<void> _saveTail = Future<void>.value();
  var _loadVersion = 0;

  @override
  CustomActionConfigurationState build() {
    ref.onDispose(() => unawaited(_saveTail));
    return const CustomActionConfigurationState();
  }

  /// Loads definitions and discards late results from an older request.
  ///
  /// 中文：读取定义并丢弃旧请求的迟到结果；存储不可用时回退为空配置。
  Future<void> load() async {
    final request = ++_loadVersion;
    state = state.copyWith(isLoading: true);
    try {
      final configurations = await ref
          .read(customActionConfigurationStoreProvider)
          .load();
      if (!ref.mounted || request != _loadVersion) return;
      state = CustomActionConfigurationState(configurations: configurations);
    } on Object {
      if (!ref.mounted || request != _loadVersion) return;
      state = const CustomActionConfigurationState();
    }
  }

  /// Queues one complete validated replacement and exposes persistence errors.
  ///
  /// 中文：排队保存一组完整的已校验定义，并以失败计数暴露持久化错误。
  Future<bool> save(List<CustomActionConfiguration> configurations) async {
    final next = List<CustomActionConfiguration>.unmodifiable(configurations);
    if (!_isValidSet(next)) return false;
    final previous = state;
    state = CustomActionConfigurationState(configurations: next);
    final write = _saveTail.then<void>(
      (_) => ref.read(customActionConfigurationStoreProvider).save(next),
    );
    _saveTail = write.catchError((Object error, StackTrace stackTrace) {
      if (ref.mounted && _sameDefinitions(state.configurations, next)) {
        state = previous.copyWith(
          saveFailureCount: previous.saveFailureCount + 1,
        );
      }
    });
    try {
      await write;
      return true;
    } on Object {
      return false;
    }
  }

  /// Waits for queued writes before Engine shutdown.
  ///
  /// 中文：Engine 关闭前等待已排队的配置写入完成。
  Future<void> prepareForShutdown() => _saveTail;

  bool _isValidSet(List<CustomActionConfiguration> configurations) {
    if (configurations.length >
        FileCustomActionConfigurationStore.maxConfigurations) {
      return false;
    }
    final ids = <String>{};
    return configurations.every(
      (configuration) =>
          configuration.validate().isEmpty && ids.add(configuration.id),
    );
  }

  /// Compares the complete immutable definitions, not only stable IDs.
  ///
  /// 中文：比较完整的不可变配置定义，而不是只比较稳定 ID，避免旧写入失败
  /// 把同一 ID 的较新 argv、范围或环境编辑错误回滚。
  bool _sameDefinitions(
    List<CustomActionConfiguration> first,
    List<CustomActionConfiguration> second,
  ) {
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      if (!first[index].hasSameDefinitionAs(second[index])) return false;
    }
    return true;
  }
}

/// Exposes the current Engine's custom-action configuration controller.
///
/// 中文：暴露当前 Flutter Engine 的自定义操作配置 controller。
final customActionConfigurationProvider =
    NotifierProvider<
      CustomActionConfigurationController,
      CustomActionConfigurationState
    >(CustomActionConfigurationController.new);
