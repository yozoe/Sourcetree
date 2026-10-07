import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:git_desktop/src/app/repository_overview_layout_preferences.dart';
import 'package:git_desktop/src/presentation/models/repository_overview_view_data.dart';

void main() {
  test('round trips the resizable workspace panes', () async {
    final directory = await Directory.systemTemp.createTemp(
      'git-desktop-layout-test-',
    );
    final file = File('${directory.path}/layout.json');
    addTearDown(() => directory.delete(recursive: true));
    final store = FileRepositoryOverviewLayoutStore(file: file);
    const layout = RepositoryOverviewLayout(
      navigationWidth: 280,
      detailsWidth: 420,
      changesHeight: 340,
      changesFileListWidth: 312,
      commitFileListWidth: 336,
    );

    await store.save(layout);

    expect(await store.load(), layout);
  });

  test('invalid layout data falls back to defaults', () async {
    final directory = await Directory.systemTemp.createTemp(
      'git-desktop-layout-invalid-test-',
    );
    final file = File('${directory.path}/layout.json');
    addTearDown(() => directory.delete(recursive: true));
    await file.writeAsString(
      '{"navigationWidth":-1,"detailsWidth":420,"changesHeight":340}',
    );

    final layout = await FileRepositoryOverviewLayoutStore(file: file).load();

    expect(layout, const RepositoryOverviewLayout());
  });

  test(
    'invalid optional width falls back to the complete default layout',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'git-desktop-layout-invalid-optional-test-',
      );
      final file = File('${directory.path}/layout.json');
      addTearDown(() => directory.delete(recursive: true));
      await file.writeAsString(
        '{"navigationWidth":280,"detailsWidth":420,"changesHeight":340,'
        '"changesFileListWidth":-1}',
      );

      final layout = await FileRepositoryOverviewLayoutStore(file: file).load();

      expect(layout, const RepositoryOverviewLayout());
    },
  );

  test('an older cross-window write cannot replace a newer layout', () async {
    final directory = await Directory.systemTemp.createTemp(
      'git-desktop-layout-version-test-',
    );
    final file = File('${directory.path}/layout.json');
    addTearDown(() => directory.delete(recursive: true));
    final newer = FileRepositoryOverviewLayoutStore(
      file: file,
      random: Random(1),
      clock: () => DateTime.fromMicrosecondsSinceEpoch(20),
    );
    final older = FileRepositoryOverviewLayoutStore(
      file: file,
      random: Random(2),
      clock: () => DateTime.fromMicrosecondsSinceEpoch(10),
    );
    const newerLayout = RepositoryOverviewLayout(navigationWidth: 300);
    const olderLayout = RepositoryOverviewLayout(navigationWidth: 240);

    await newer.save(
      newerLayout,
      changedAt: DateTime.fromMicrosecondsSinceEpoch(20),
    );
    await older.save(
      olderLayout,
      changedAt: DateTime.fromMicrosecondsSinceEpoch(10),
    );

    expect(await newer.load(), newerLayout);
  });

  test('coalesces rapid resize events and flushes the final layout', () async {
    final store = _RecordingLayoutStore();
    final container = ProviderContainer(
      overrides: [
        repositoryOverviewLayoutStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(
      repositoryOverviewLayoutProvider.notifier,
    );

    for (var width = 225.0; width <= 324; width += 1) {
      controller.setLayout(RepositoryOverviewLayout(navigationWidth: width));
    }

    expect(store.saved, isEmpty);
    await controller.prepareForShutdown();
    expect(store.saved, hasLength(1));
    expect(store.saved.single.navigationWidth, 324);
  });

  test('persists the final layout after the resize debounce', () async {
    final store = _RecordingLayoutStore();
    final container = ProviderContainer(
      overrides: [
        repositoryOverviewLayoutStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(
      repositoryOverviewLayoutProvider.notifier,
    );

    controller.setLayout(const RepositoryOverviewLayout(detailsWidth: 410));
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await controller.prepareForShutdown();

    expect(store.saved, hasLength(1));
    expect(store.saved.single.detailsWidth, 410);
  });

  test('uses interaction time when a stale write executes later', () async {
    final directory = await Directory.systemTemp.createTemp(
      'git-desktop-layout-interaction-version-test-',
    );
    final file = File('${directory.path}/layout.json');
    addTearDown(() => directory.delete(recursive: true));
    final newer = FileRepositoryOverviewLayoutStore(
      file: file,
      random: Random(3),
      clock: () => DateTime.fromMicrosecondsSinceEpoch(10),
    );
    final delayedOlder = FileRepositoryOverviewLayoutStore(
      file: file,
      random: Random(4),
      clock: () => DateTime.fromMicrosecondsSinceEpoch(30),
    );
    const newerLayout = RepositoryOverviewLayout(detailsWidth: 440);
    const olderLayout = RepositoryOverviewLayout(detailsWidth: 320);

    await newer.save(
      newerLayout,
      changedAt: DateTime.fromMicrosecondsSinceEpoch(20),
    );
    await delayedOlder.save(
      olderLayout,
      changedAt: DateTime.fromMicrosecondsSinceEpoch(10),
    );

    expect(await newer.load(), newerLayout);
  });
}

final class _RecordingLayoutStore implements RepositoryOverviewLayoutStore {
  final List<RepositoryOverviewLayout> saved = [];

  @override
  Future<RepositoryOverviewLayout> load() async =>
      const RepositoryOverviewLayout();

  @override
  Future<void> save(
    RepositoryOverviewLayout layout, {
    DateTime? changedAt,
  }) async {
    saved.add(layout);
  }
}
