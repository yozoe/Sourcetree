import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as path_utils;

@immutable
final class GitDesktopThemePreferences {
  const GitDesktopThemePreferences({required this.mode});

  static const defaults = GitDesktopThemePreferences(mode: ThemeMode.system);

  final ThemeMode mode;

  /// 中文：复制偏好并可替换显示模式；不保留已移除的旧主题色字段。
  ///
  /// English: Copies preferences while optionally replacing the display mode;
  /// removed legacy color-preset fields are not retained.
  GitDesktopThemePreferences copyWith({ThemeMode? mode}) =>
      GitDesktopThemePreferences(mode: mode ?? this.mode);

  /// 中文：将当前偏好转换为可原子写入本地文件的 JSON 数据。
  ///
  /// English: Converts the current preferences to JSON data for atomic local
  /// persistence.
  Map<String, Object> toJson() => <String, Object>{'themeMode': mode.name};

  /// 中文：从本地 JSON 恢复显示模式，忽略已废弃的颜色预设字段。
  ///
  /// English: Restores the display mode from local JSON and ignores the
  /// retired color-preset field.
  factory GitDesktopThemePreferences.fromJson(Object? value) {
    if (value is! Map) return defaults;
    return GitDesktopThemePreferences(
      mode: ThemeMode.values.firstWhere(
        (candidate) => candidate.name == value['themeMode'],
        orElse: () => defaults.mode,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GitDesktopThemePreferences && other.mode == mode;

  @override
  int get hashCode => mode.hashCode;
}

abstract interface class GitDesktopThemePreferencesStore {
  Future<GitDesktopThemePreferences> load();

  Future<void> save(GitDesktopThemePreferences preferences);
}

abstract interface class WatchableGitDesktopThemePreferencesStore
    implements GitDesktopThemePreferencesStore {
  Stream<GitDesktopThemePreferences> watch();
}

final class FileGitDesktopThemePreferencesStore
    implements WatchableGitDesktopThemePreferencesStore {
  FileGitDesktopThemePreferencesStore({File? file, Random? random})
    : _fixedFile = file,
      _random = random ?? Random.secure();

  final File? _fixedFile;
  final Random _random;

  @override
  Future<GitDesktopThemePreferences> load() async {
    try {
      final file = _file();
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return GitDesktopThemePreferences.defaults;
      }
      if (await file.length() > 64 * 1024) {
        return GitDesktopThemePreferences.defaults;
      }
      return GitDesktopThemePreferences.fromJson(
        jsonDecode(await file.readAsString()),
      );
    } on Object {
      return GitDesktopThemePreferences.defaults;
    }
  }

  @override
  Future<void> save(GitDesktopThemePreferences preferences) async {
    final file = _file();
    await file.parent.create(recursive: true);
    File? temporaryFile;
    try {
      temporaryFile = File('${file.path}.tmp.$pid.${_randomToken()}');
      await temporaryFile.create(exclusive: true);
      await temporaryFile.writeAsString(
        '${jsonEncode(preferences.toJson())}\n',
        flush: true,
      );
      await temporaryFile.rename(file.path);
      temporaryFile = null;
    } finally {
      if (temporaryFile != null) {
        try {
          if (await temporaryFile.exists()) await temporaryFile.delete();
        } on Object {
          // Preserve the write failure when temporary cleanup also fails.
        }
      }
    }
  }

  @override
  Stream<GitDesktopThemePreferences> watch() async* {
    final file = _file();
    await file.parent.create(recursive: true);
    await for (final event in file.parent.watch()) {
      final targetsPreferenceFile =
          path_utils.equals(event.path, file.path) ||
          (event is FileSystemMoveEvent &&
              event.destination != null &&
              path_utils.equals(event.destination!, file.path));
      if (!targetsPreferenceFile) continue;
      // Coalesce the destination rename with adjacent filesystem events.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      yield await load();
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
    return File('$directory${Platform.pathSeparator}ui-preferences.json');
  }

  String _randomToken() => List<int>.generate(
    12,
    (_) => _random.nextInt(256),
    growable: false,
  ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
}

class GitDesktopThemeMenuButton extends StatelessWidget {
  const GitDesktopThemeMenuButton({
    super.key,
    required this.preferences,
    required this.onThemeModeChanged,
  });

  final GitDesktopThemePreferences preferences;
  final ValueChanged<ThemeMode> onThemeModeChanged;

  /// 中文：构建只提供系统、浅色和深色模式的主题菜单。
  /// 用户选择后立即回调，不持有或写入任何窗口状态。
  ///
  /// English: Builds the theme menu containing only system, light, and dark
  /// modes. Selection is reported immediately without owning window state.
  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_ThemeAction>(
      key: const ValueKey('theme-menu-button'),
      tooltip: '显示模式：${preferences.mode.label}',
      icon: Icon(preferences.mode.icon, size: 20),
      onSelected: (action) {
        final mode = action.mode;
        if (mode != null) onThemeModeChanged(mode);
      },
      itemBuilder: (context) => <PopupMenuEntry<_ThemeAction>>[
        const PopupMenuItem(enabled: false, child: Text('显示模式')),
        for (final action in _ThemeAction.values.where(
          (action) => action.mode != null,
        ))
          CheckedPopupMenuItem(
            key: ValueKey('theme-mode-${action.mode!.name}'),
            value: action,
            checked: action.mode == preferences.mode,
            child: Text(action.mode!.label),
          ),
      ],
    );
  }
}

enum _ThemeAction {
  system(mode: ThemeMode.system),
  light(mode: ThemeMode.light),
  dark(mode: ThemeMode.dark);

  const _ThemeAction({this.mode});

  final ThemeMode? mode;
}

extension on ThemeMode {
  String get label => switch (this) {
    ThemeMode.system => '跟随系统',
    ThemeMode.light => '浅色',
    ThemeMode.dark => '深色',
  };

  IconData get icon => switch (this) {
    ThemeMode.system => Icons.brightness_auto_outlined,
    ThemeMode.light => Icons.light_mode_outlined,
    ThemeMode.dark => Icons.dark_mode_outlined,
  };
}
