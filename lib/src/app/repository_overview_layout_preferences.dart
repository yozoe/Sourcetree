import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../presentation/models/repository_overview_view_data.dart';

/// Persists the resizable panes shared by repository workspace windows.
///
/// 中文：持久化所有仓库工作区窗口共享的可调整面板尺寸。
abstract interface class RepositoryOverviewLayoutStore {
  Future<RepositoryOverviewLayout> load();

  Future<void> save(RepositoryOverviewLayout layout, {DateTime? changedAt});
}

/// File-backed layout preferences used by every Flutter Engine.
///
/// 中文：供每个 Flutter Engine 读取和写入的文件布局偏好存储；写入采用
/// 文件锁、时间版本和临时文件替换，避免跨窗口旧布局覆盖新布局或留下半截 JSON。
final class FileRepositoryOverviewLayoutStore
    implements RepositoryOverviewLayoutStore {
  FileRepositoryOverviewLayoutStore({
    File? file,
    Random? random,
    DateTime Function()? clock,
  }) : _fixedFile = file,
       _random = random ?? Random.secure(),
       _clock = clock ?? DateTime.now;

  static const _defaultLayout = RepositoryOverviewLayout();

  final File? _fixedFile;
  final Random _random;
  final DateTime Function() _clock;
  late final String _writerId = _randomToken();

  @override
  Future<RepositoryOverviewLayout> load() async {
    try {
      final file = _file();
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return _defaultLayout;
      }
      if (await file.length() > 64 * 1024) return _defaultLayout;
      return _fromJson(jsonDecode(await file.readAsString()));
    } on Object {
      return _defaultLayout;
    }
  }

  @override
  Future<void> save(
    RepositoryOverviewLayout layout, {
    DateTime? changedAt,
  }) async {
    final file = _file();
    await file.parent.create(recursive: true);
    final lockFile = File('${file.path}.lock');
    final lock = await lockFile.open(mode: FileMode.append);
    var locked = false;
    File? temporaryFile;
    try {
      await lock.lock(FileLock.exclusive);
      locked = true;
      // The version belongs to the user interaction, not to lock acquisition.
      // An older resize delayed by another Engine must not become newer merely
      // because its file write starts later.
      final savedAtMicros = (changedAt ?? _clock()).microsecondsSinceEpoch;
      final existingVersion = await _readVersion(file);
      if (existingVersion != null &&
          (existingVersion.savedAtMicros > savedAtMicros ||
              (existingVersion.savedAtMicros == savedAtMicros &&
                  existingVersion.writerId.compareTo(_writerId) > 0))) {
        return;
      }
      try {
        temporaryFile = File('${file.path}.tmp.$pid.${_randomToken()}');
        await temporaryFile.create(exclusive: true);
        await temporaryFile.writeAsString(
          '${jsonEncode(_toJson(layout, savedAtMicros: savedAtMicros))}\n',
          flush: true,
        );
        await temporaryFile.rename(file.path);
        temporaryFile = null;
      } finally {
        if (temporaryFile != null) {
          try {
            if (await temporaryFile.exists()) await temporaryFile.delete();
          } on Object {
            // Preserve the original write failure when cleanup also fails.
          }
        }
      }
    } finally {
      try {
        if (locked) await lock.unlock();
      } finally {
        await lock.close();
      }
    }
  }

  File _file() {
    final fixedFile = _fixedFile;
    if (fixedFile != null) return fixedFile;
    final home = Platform.environment['HOME']?.trim();
    final String directory;
    if (Platform.isMacOS && home != null && home.isNotEmpty) {
      directory = '$home/Library/Application Support/com.yozoe.gitDesktop';
    } else if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA']?.trim();
      if (appData == null || appData.isEmpty) {
        throw StateError('APPDATA is unavailable.');
      }
      directory = '$appData${Platform.pathSeparator}Git Desktop';
    } else if (home != null && home.isNotEmpty) {
      final configHome = Platform.environment['XDG_CONFIG_HOME']?.trim();
      directory = configHome != null && configHome.isNotEmpty
          ? '$configHome${Platform.pathSeparator}git-desktop'
          : '$home${Platform.pathSeparator}.config${Platform.pathSeparator}git-desktop';
    } else {
      throw StateError('A persistent application directory is unavailable.');
    }
    return File(
      '$directory${Platform.pathSeparator}repository-overview-layout.json',
    );
  }

  String _randomToken() => List<int>.generate(
    12,
    (_) => _random.nextInt(256),
    growable: false,
  ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();

  Map<String, Object> _toJson(
    RepositoryOverviewLayout layout, {
    required int savedAtMicros,
  }) => <String, Object>{
    'navigationWidth': layout.navigationWidth,
    'detailsWidth': layout.detailsWidth,
    'changesHeight': layout.changesHeight,
    '_savedAtMicros': savedAtMicros,
    '_writerId': _writerId,
    if (layout.changesFileListWidth != null)
      'changesFileListWidth': layout.changesFileListWidth!,
    if (layout.commitFileListWidth != null)
      'commitFileListWidth': layout.commitFileListWidth!,
  };

  static Future<_LayoutVersion?> _readVersion(File file) async {
    try {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return null;
      }
      if (await file.length() > 64 * 1024) return null;
      final value = jsonDecode(await file.readAsString());
      if (value is! Map) return null;
      final savedAtMicros = value['_savedAtMicros'];
      final writerId = value['_writerId'];
      if (savedAtMicros is! int || savedAtMicros < 0 || writerId is! String) {
        return null;
      }
      return _LayoutVersion(savedAtMicros, writerId);
    } on Object {
      return null;
    }
  }

  static RepositoryOverviewLayout _fromJson(Object? value) {
    if (value is! Map) return _defaultLayout;
    final navigationWidth = _positiveFinite(value['navigationWidth']);
    final detailsWidth = _positiveFinite(value['detailsWidth']);
    final changesHeight = _positiveFinite(value['changesHeight']);
    final changesFileListWidth = _readOptionalWidth(
      value,
      'changesFileListWidth',
    );
    final commitFileListWidth = _readOptionalWidth(
      value,
      'commitFileListWidth',
    );
    if (navigationWidth == null ||
        detailsWidth == null ||
        changesHeight == null) {
      return _defaultLayout;
    }
    if (changesFileListWidth == _invalidWidth ||
        commitFileListWidth == _invalidWidth) {
      return _defaultLayout;
    }
    return RepositoryOverviewLayout(
      navigationWidth: navigationWidth,
      detailsWidth: detailsWidth,
      changesHeight: changesHeight,
      changesFileListWidth: changesFileListWidth,
      commitFileListWidth: commitFileListWidth,
    );
  }

  static const _invalidWidth = double.negativeInfinity;

  static double? _readOptionalWidth(Map value, String key) {
    final raw = value[key];
    if (raw == null) return null;
    return _positiveFinite(raw) ?? _invalidWidth;
  }

  static double? _positiveFinite(Object? value) {
    final number = value is num ? value.toDouble() : null;
    if (number == null || !number.isFinite || number <= 0) return null;
    return number;
  }
}

final class _LayoutVersion {
  const _LayoutVersion(this.savedAtMicros, this.writerId);

  final int savedAtMicros;
  final String writerId;
}

/// Store used by the current Flutter Engine for workspace layout preferences.
///
/// 中文：当前 Flutter Engine 使用的工作区布局偏好存储。
final repositoryOverviewLayoutStoreProvider =
    Provider<RepositoryOverviewLayoutStore?>((Ref ref) => null);

/// Layout loaded before the current Flutter Engine first renders.
///
/// 中文：当前 Flutter Engine 首次绘制前读取的工作区布局。
final initialRepositoryOverviewLayoutProvider =
    Provider<RepositoryOverviewLayout>(
      (Ref ref) => const RepositoryOverviewLayout(),
    );

/// Owns layout state and serializes writes shared by multiple workspace
/// windows.
///
/// 中文：管理工作区布局状态，并串行化多个窗口产生的偏好写入。
final repositoryOverviewLayoutProvider =
    NotifierProvider<
      RepositoryOverviewLayoutController,
      RepositoryOverviewLayout
    >(RepositoryOverviewLayoutController.new);

final class RepositoryOverviewLayoutController
    extends Notifier<RepositoryOverviewLayout> {
  static const _saveDebounce = Duration(milliseconds: 200);

  Future<void> _saveTail = Future<void>.value();
  Timer? _saveTimer;
  _PendingLayoutWrite? _pendingWrite;

  @override
  RepositoryOverviewLayout build() {
    ref.onDispose(() => _saveTimer?.cancel());
    return ref.watch(initialRepositoryOverviewLayoutProvider);
  }

  /// Updates the live layout and coalesces rapid resize events before saving.
  ///
  /// 中文：立即更新实时布局，并在保存前合并连续拖动产生的高频尺寸变化。
  void setLayout(RepositoryOverviewLayout layout) {
    if (layout == state) return;
    state = layout;
    _pendingWrite = _PendingLayoutWrite(layout, DateTime.now());
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, flushPendingWrite);
  }

  /// Moves the latest pending layout into the ordered persistence queue.
  ///
  /// 中文：把最后一个待保存布局加入顺序写入队列，丢弃已被后续拖动替代的中间尺寸。
  void flushPendingWrite() {
    _saveTimer?.cancel();
    _saveTimer = null;
    final pendingWrite = _pendingWrite;
    _pendingWrite = null;
    final store = ref.read(repositoryOverviewLayoutStoreProvider);
    if (pendingWrite == null || store == null) return;
    _saveTail = _saveTail.then((_) async {
      try {
        await store.save(
          pendingWrite.layout,
          changedAt: pendingWrite.changedAt,
        );
      } on Object {
        // A layout preference is non-critical; keep the live layout usable
        // when the preference directory is temporarily unavailable.
      }
    });
  }

  /// Flushes the latest resize and waits for this Engine's layout writes.
  ///
  /// 中文：立即提交最后一次尺寸变化，并等待当前 Engine 的布局写入完成。
  Future<void> prepareForShutdown() async {
    flushPendingWrite();
    await _saveTail;
  }
}

final class _PendingLayoutWrite {
  const _PendingLayoutWrite(this.layout, this.changedAt);

  final RepositoryOverviewLayout layout;
  final DateTime changedAt;
}
