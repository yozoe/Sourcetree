import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:git_desktop/src/app/git_desktop_theme.dart';
import 'package:git_desktop/src/app/theme_preferences.dart';

void main() {
  test('file store round-trips display mode selections', () async {
    final directory = await Directory.systemTemp.createTemp('git-theme-');
    addTearDown(() => directory.delete(recursive: true));
    final store = FileGitDesktopThemePreferencesStore(
      file: File('${directory.path}/ui-preferences.json'),
    );
    for (final mode in ThemeMode.values) {
      final expected = GitDesktopThemePreferences(mode: mode);
      await store.save(expected);
      expect(await store.load(), expected);
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
    const expected = GitDesktopThemePreferences(mode: ThemeMode.dark);

    await secondWindow.save(expected);

    expect(await observed.timeout(const Duration(seconds: 2)), expected);
  });

  test('legacy color preset is ignored while preserving display mode', () {
    expect(
      GitDesktopThemePreferences.fromJson(<String, Object>{
        'themeMode': 'dark',
        'colorPreset': 'obsidian',
      }),
      const GitDesktopThemePreferences(mode: ThemeMode.dark),
    );
  });

  test('controller flush waits for queued theme persistence', () async {
    final store = _DelayedThemePreferencesStore();
    final container = ProviderContainer(
      overrides: [
        gitDesktopThemePreferencesStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(
      gitDesktopThemePreferencesProvider.notifier,
    );

    controller.setThemeMode(ThemeMode.dark);
    var didFlush = false;
    final flush = controller.flushPendingWrites().then((_) => didFlush = true);
    await Future<void>.delayed(Duration.zero);
    expect(didFlush, isFalse);

    store.release();
    await flush;
    expect(store.saved, const GitDesktopThemePreferences(mode: ThemeMode.dark));
  });

  test('controller shutdown waits for the theme watcher to cancel', () async {
    final store = _DelayedWatchableThemePreferencesStore();
    final container = ProviderContainer(
      overrides: [
        gitDesktopThemePreferencesStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(
      gitDesktopThemePreferencesProvider.notifier,
    );

    var didFinish = false;
    final shutdown = controller.prepareForShutdown().then(
      (_) => didFinish = true,
    );
    await store.cancellationStarted.future;
    expect(didFinish, isFalse);

    store.releaseCancellation();
    await shutdown;
    expect(didFinish, isTrue);
  });

  test('workbench theme uses the compact graphite palette', () {
    final theme = buildGitDesktopTheme(Brightness.dark);

    expect(theme.colorScheme.surface, const Color(0xFF202528));
    expect(theme.colorScheme.surfaceContainerHigh, const Color(0xFF343C40));
    expect(theme.colorScheme.primary, const Color(0xFF1688D4));
    expect(theme.textTheme.bodySmall?.fontSize, 12);
    expect(theme.textTheme.titleLarge?.fontSize, 16);
    final border = theme.inputDecorationTheme.border! as OutlineInputBorder;
    expect(border.borderRadius, BorderRadius.circular(3));
  });
}

final class _DelayedThemePreferencesStore
    implements GitDesktopThemePreferencesStore {
  final Completer<void> _release = Completer<void>();
  GitDesktopThemePreferences? saved;

  void release() => _release.complete();

  @override
  Future<GitDesktopThemePreferences> load() async =>
      GitDesktopThemePreferences.defaults;

  @override
  Future<void> save(GitDesktopThemePreferences preferences) async {
    await _release.future;
    saved = preferences;
  }
}

final class _DelayedWatchableThemePreferencesStore
    implements WatchableGitDesktopThemePreferencesStore {
  _DelayedWatchableThemePreferencesStore() {
    _controller = StreamController<GitDesktopThemePreferences>(
      onCancel: () async {
        if (!cancellationStarted.isCompleted) cancellationStarted.complete();
        await _cancellationRelease.future;
      },
    );
  }

  late final StreamController<GitDesktopThemePreferences> _controller;
  final Completer<void> cancellationStarted = Completer<void>();
  final Completer<void> _cancellationRelease = Completer<void>();

  void releaseCancellation() => _cancellationRelease.complete();

  @override
  Future<GitDesktopThemePreferences> load() async =>
      GitDesktopThemePreferences.defaults;

  @override
  Future<void> save(GitDesktopThemePreferences preferences) async {}

  @override
  Stream<GitDesktopThemePreferences> watch() => _controller.stream;
}
