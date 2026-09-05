import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/app/repository_library_controller.dart';
import 'package:git_desktop/src/app/repository_session_store.dart';

void main() {
  test(
    'missing session file is empty but malformed data is distinguishable',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'git-session-store-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/repository-session.json');
      final store = FileRepositorySessionStore(file: file);

      expect((await store.load()).openRepositoryPaths, isEmpty);
      await file.writeAsString('{not-json');

      await expectLater(
        store.load(),
        throwsA(
          isA<RepositorySessionLoadException>().having(
            (error) => error.kind,
            'kind',
            RepositorySessionLoadFailureKind.invalidData,
          ),
        ),
      );
    },
  );

  test('session store atomically replaces a complete snapshot', () async {
    final directory = await Directory.systemTemp.createTemp(
      'git-session-store-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/repository-session.json');
    final store = FileRepositorySessionStore(file: file);
    const expected = RepositorySessionSnapshot(
      openRepositoryPaths: ['/tmp/first', '/tmp/second'],
      activeRepositoryPath: '/tmp/second',
    );

    await store.save(expected);

    final restored = await store.load();
    expect(restored.openRepositoryPaths, expected.openRepositoryPaths);
    expect(restored.activeRepositoryPath, expected.activeRepositoryPath);
    expect(
      await directory
          .list()
          .where((entry) => entry.path.contains('.tmp.'))
          .toList(),
      isEmpty,
    );
  });

  test('failed restore never overwrites the prior repository list', () async {
    final store = _FailingLoadStore();
    final container = ProviderContainer(
      overrides: [repositorySessionStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);

    await expectLater(
      container.read(repositoryLibraryProvider.notifier).restore(),
      throwsA(isA<RepositorySessionLoadException>()),
    );
    await container
        .read(repositoryLibraryProvider.notifier)
        .flushPendingWrites();

    expect(store.saveCount, 0);
  });

  test('library flush waits for its queued snapshot write', () async {
    final store = _DelayedSaveStore();
    final container = ProviderContainer(
      overrides: [repositorySessionStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositoryLibraryProvider.notifier);
    var didRestore = false;
    final restore = controller.restore().then((_) => didRestore = true);
    await Future<void>.delayed(Duration.zero);
    expect(didRestore, isFalse);

    store.release();
    await restore;
    await controller.flushPendingWrites();
    expect(store.saveCount, 1);
  });

  test('restore retains a temporarily unavailable repository path', () async {
    final directory = await Directory.systemTemp.createTemp(
      'git-session-offline-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final unavailablePath = '${directory.path}/not-mounted-repository';
    final store = _RecordingStore(
      RepositorySessionSnapshot(
        openRepositoryPaths: [unavailablePath],
        activeRepositoryPath: unavailablePath,
      ),
    );
    final container = ProviderContainer(
      overrides: [repositorySessionStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);

    final controller = container.read(repositoryLibraryProvider.notifier);
    await controller.restore();

    final state = container.read(repositoryLibraryProvider);
    expect(state.repositories.map((repository) => repository.path), [
      unavailablePath,
    ]);
    expect(state.repositories.single.hasStatus, isFalse);
    expect(state.activeRepositoryPath, unavailablePath);
    expect(store.savedSnapshot?.openRepositoryPaths, [unavailablePath]);
  });

  test('save failure remains observable and makes flush fail', () async {
    final store = _FailingSaveStore();
    final container = ProviderContainer(
      overrides: [repositorySessionStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    final controller = container.read(repositoryLibraryProvider.notifier);

    await expectLater(
      controller.restore(),
      throwsA(isA<RepositoryLibraryPersistenceException>()),
    );
    final state = container.read(repositoryLibraryProvider);
    expect(state.persistenceFailureCount, 1);
    expect(state.persistenceError, contains('read-only'));
    await expectLater(
      controller.flushPendingWrites(),
      throwsA(isA<RepositoryLibraryPersistenceException>()),
    );
  });
}

final class _FailingLoadStore implements RepositorySessionStore {
  int saveCount = 0;

  @override
  Future<RepositorySessionSnapshot> load() async {
    throw const RepositorySessionLoadException(
      RepositorySessionLoadFailureKind.io,
      FileSystemException('temporarily unavailable'),
    );
  }

  @override
  Future<void> save(RepositorySessionSnapshot snapshot) async {
    saveCount++;
  }
}

final class _DelayedSaveStore implements RepositorySessionStore {
  final Completer<void> _release = Completer<void>();
  int saveCount = 0;

  void release() => _release.complete();

  @override
  Future<RepositorySessionSnapshot> load() async =>
      const RepositorySessionSnapshot();

  @override
  Future<void> save(RepositorySessionSnapshot snapshot) async {
    await _release.future;
    saveCount++;
  }
}

final class _RecordingStore implements RepositorySessionStore {
  _RecordingStore(this.snapshot);

  final RepositorySessionSnapshot snapshot;
  RepositorySessionSnapshot? savedSnapshot;

  @override
  Future<RepositorySessionSnapshot> load() async => snapshot;

  @override
  Future<void> save(RepositorySessionSnapshot snapshot) async {
    savedSnapshot = snapshot;
  }
}

final class _FailingSaveStore implements RepositorySessionStore {
  @override
  Future<RepositorySessionSnapshot> load() async =>
      const RepositorySessionSnapshot();

  @override
  Future<void> save(RepositorySessionSnapshot snapshot) async {
    throw const FileSystemException('read-only');
  }
}
