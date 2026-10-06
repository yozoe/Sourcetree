import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
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

    await newer.save(newerLayout);
    await older.save(olderLayout);

    expect(await newer.load(), newerLayout);
  });
}
