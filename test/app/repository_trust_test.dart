import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/app/repository_trust.dart';

void main() {
  const first = RepositoryTrustId(
    commonDirectory: '/tmp/example/.git',
    workTreeRoot: '/tmp/example',
  );
  const second = RepositoryTrustId(
    commonDirectory: '/tmp/other/.git',
    workTreeRoot: '/tmp/other',
  );

  test('trust defaults to unconfirmed and never infers from a path', () async {
    final directory = await Directory.systemTemp.createTemp('git-trust-test-');
    addTearDown(() => directory.delete(recursive: true));
    final store = FileRepositoryTrustStore(
      file: File('${directory.path}/repository-trust.json'),
    );

    expect(await store.load(first), RepositoryTrustStatus.unconfirmed);
    expect(
      canRunRepositoryExtension(RepositoryTrustStatus.unconfirmed),
      isFalse,
    );
  });

  test(
    'trust choices are repository-scoped, persistent, and revocable',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'git-trust-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/repository-trust.json');
      final store = FileRepositoryTrustStore(file: file);

      await store.save(first, RepositoryTrustStatus.trusted);
      expect(await store.load(first), RepositoryTrustStatus.trusted);
      expect(await store.load(second), RepositoryTrustStatus.unconfirmed);
      expect(canRunRepositoryExtension(await store.load(first)), isTrue);

      await store.save(first, RepositoryTrustStatus.restricted);
      expect(await store.load(first), RepositoryTrustStatus.restricted);
      expect(canRunRepositoryExtension(await store.load(first)), isFalse);
    },
  );

  test(
    'controller loads and persists only an explicit current repository',
    () async {
      final store = _RecordingTrustStore();
      final container = ProviderContainer(
        overrides: [repositoryTrustStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);
      final controller = container.read(repositoryTrustProvider.notifier);

      await controller.loadRepository(first);
      expect(
        container.read(repositoryTrustProvider).status,
        RepositoryTrustStatus.unconfirmed,
      );

      await controller.setStatus(RepositoryTrustStatus.trusted);
      expect(store.saved[first.storageKey], RepositoryTrustStatus.trusted);
      expect(
        container.read(repositoryTrustProvider).status,
        RepositoryTrustStatus.trusted,
      );
    },
  );

  test(
    'controller recovers to safe default when trust loading fails',
    () async {
      final container = ProviderContainer(
        overrides: [
          repositoryTrustStoreProvider.overrideWithValue(_FailingTrustStore()),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(repositoryTrustProvider.notifier);

      await controller.loadRepository(first);

      final state = container.read(repositoryTrustProvider);
      expect(state.repository?.storageKey, first.storageKey);
      expect(state.status, RepositoryTrustStatus.unconfirmed);
      expect(state.isLoading, isFalse);
      expect(canRunRepositoryExtension(state.status), isFalse);
    },
  );
}

final class _RecordingTrustStore implements RepositoryTrustStore {
  final Map<String, RepositoryTrustStatus> saved =
      <String, RepositoryTrustStatus>{};

  @override
  Future<RepositoryTrustStatus> load(RepositoryTrustId repository) async =>
      saved[repository.storageKey] ?? RepositoryTrustStatus.unconfirmed;

  @override
  Future<void> save(
    RepositoryTrustId repository,
    RepositoryTrustStatus status,
  ) async {
    saved[repository.storageKey] = status;
  }
}

final class _FailingTrustStore implements RepositoryTrustStore {
  @override
  Future<RepositoryTrustStatus> load(RepositoryTrustId repository) async {
    throw StateError('storage unavailable');
  }

  @override
  Future<void> save(
    RepositoryTrustId repository,
    RepositoryTrustStatus status,
  ) async {}
}
