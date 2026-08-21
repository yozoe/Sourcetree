import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as path_utils;
import 'package:yeknom_ui_kit/yeknom_workbench.dart';

@immutable
final class GitDesktopThemePreferences {
  const GitDesktopThemePreferences({required this.mode, required this.preset});

  static const defaults = GitDesktopThemePreferences(
    mode: ThemeMode.system,
    preset: YeknomColorPreset.cobalt,
  );

  final ThemeMode mode;
  final YeknomColorPreset preset;

  GitDesktopThemePreferences copyWith({
    ThemeMode? mode,
    YeknomColorPreset? preset,
  }) => GitDesktopThemePreferences(
    mode: mode ?? this.mode,
    preset: preset ?? this.preset,
  );

  Map<String, Object> toJson() => <String, Object>{
    'themeMode': mode.name,
    'colorPreset': preset.name,
  };

  factory GitDesktopThemePreferences.fromJson(Object? value) {
    if (value is! Map) return defaults;
    return GitDesktopThemePreferences(
      mode: ThemeMode.values.firstWhere(
        (candidate) => candidate.name == value['themeMode'],
        orElse: () => defaults.mode,
      ),
      preset: YeknomColorPreset.values.firstWhere(
        (candidate) => candidate.name == value['colorPreset'],
        orElse: () => defaults.preset,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GitDesktopThemePreferences &&
      other.mode == mode &&
      other.preset == preset;

  @override
  int get hashCode => Object.hash(mode, preset);
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
    required this.onThemePresetChanged,
  });

  final GitDesktopThemePreferences preferences;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final ValueChanged<YeknomColorPreset> onThemePresetChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_ThemeAction>(
      key: const ValueKey('theme-menu-button'),
      tooltip: '主题：${preferences.mode.label} · ${preferences.preset.label}',
      icon: Icon(preferences.mode.icon, size: 20),
      onSelected: (action) {
        final mode = action.mode;
        if (mode != null) onThemeModeChanged(mode);
        final preset = action.preset;
        if (preset != null) onThemePresetChanged(preset);
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
        const PopupMenuDivider(),
        const PopupMenuItem(enabled: false, child: Text('主题色')),
        for (final action in _ThemeAction.values.where(
          (action) => action.preset != null,
        ))
          CheckedPopupMenuItem(
            key: ValueKey('theme-preset-${action.preset!.name}'),
            value: action,
            checked: action.preset == preferences.preset,
            child: Text(action.preset!.label),
          ),
      ],
    );
  }
}

enum _ThemeAction {
  system(mode: ThemeMode.system),
  light(mode: ThemeMode.light),
  dark(mode: ThemeMode.dark),
  workbench(preset: YeknomColorPreset.workbench),
  cobalt(preset: YeknomColorPreset.cobalt),
  orchid(preset: YeknomColorPreset.orchid),
  graphite(preset: YeknomColorPreset.graphite),
  obsidian(preset: YeknomColorPreset.obsidian),
  midnight(preset: YeknomColorPreset.midnight),
  blackberry(preset: YeknomColorPreset.blackberry),
  sage(preset: YeknomColorPreset.sage);

  const _ThemeAction({this.mode, this.preset});

  final ThemeMode? mode;
  final YeknomColorPreset? preset;
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

extension on YeknomColorPreset {
  String get label => switch (this) {
    YeknomColorPreset.workbench => '工作台',
    YeknomColorPreset.cobalt => '钴蓝',
    YeknomColorPreset.orchid => '兰紫',
    YeknomColorPreset.graphite => '石墨',
    YeknomColorPreset.obsidian => '黑曜',
    YeknomColorPreset.midnight => '午夜',
    YeknomColorPreset.blackberry => '黑莓',
    YeknomColorPreset.sage => '鼠尾草',
  };
}
