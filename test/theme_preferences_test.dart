import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/app/theme_preferences.dart';
import 'package:yeknom_ui_kit/yeknom_workbench.dart';

void main() {
  test('file store round-trips all theme selections', () async {
    final directory = await Directory.systemTemp.createTemp('git-theme-');
    addTearDown(() => directory.delete(recursive: true));
    final store = FileGitDesktopThemePreferencesStore(
      file: File('${directory.path}/ui-preferences.json'),
    );
    for (final mode in ThemeMode.values) {
      for (final preset in YeknomColorPreset.values) {
        final expected = GitDesktopThemePreferences(mode: mode, preset: preset);
        await store.save(expected);
        expect(await store.load(), expected);
      }
    }
  });

  test('file store publishes changes to other application windows', () async {
    final directory = await Directory.systemTemp.createTemp('git-theme-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/ui-preferences.json');
    final firstWindow = FileGitDesktopThemePreferencesStore(file: file);
    final secondWindow = FileGitDesktopThemePreferencesStore(file: file);
    await file.parent.create(recursive: true);
    final observed = firstWindow.watch().first;
    const expected = GitDesktopThemePreferences(
      mode: ThemeMode.dark,
      preset: YeknomColorPreset.obsidian,
    );

    await secondWindow.save(expected);

    expect(await observed.timeout(const Duration(seconds: 2)), expected);
  });
}
