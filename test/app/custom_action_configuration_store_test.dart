import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/app/custom_action_configuration.dart';
import 'package:git_desktop/src/app/custom_action_configuration_store.dart';

void main() {
  CustomActionConfiguration configuration(String id) =>
      CustomActionConfiguration(
        id: id,
        displayName: 'Action $id',
        executablePath: '/usr/bin/example-tool',
        arguments: const <String>['--root', '{repository}'],
        scope: CustomActionScope.repository,
      );

  test('stores and restores a validated set atomically', () async {
    final directory = await Directory.systemTemp.createTemp(
      'git-desktop-custom-actions-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final store = FileCustomActionConfigurationStore(
      file: File('${directory.path}${Platform.pathSeparator}actions.json'),
    );

    await store.save([configuration('inspect')]);

    final restored = await store.load();
    expect(restored, hasLength(1));
    expect(restored.single.id, 'inspect');
    expect(restored.single.enabled, isFalse);
  });

  test('rejects duplicate IDs and preserves the previous file', () async {
    final directory = await Directory.systemTemp.createTemp(
      'git-desktop-custom-actions-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}actions.json');
    final store = FileCustomActionConfigurationStore(file: file);
    await store.save([configuration('keep')]);

    await expectLater(
      store.save([configuration('duplicate'), configuration('duplicate')]),
      throwsArgumentError,
    );
    expect((await store.load()).single.id, 'keep');
  });

  test('falls back to an empty set for malformed or unsafe records', () async {
    final directory = await Directory.systemTemp.createTemp(
      'git-desktop-custom-actions-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}actions.json');
    final store = FileCustomActionConfigurationStore(file: file);

    await file.writeAsString('{"version":1,"configurations":[not-json]}');
    expect(await store.load(), isEmpty);

    await file.writeAsString(
      jsonEncode(<String, Object?>{
        'version': 1,
        'configurations': [
          configuration('a').toJson(),
          configuration('a').toJson(),
        ],
      }),
    );
    expect(await store.load(), isEmpty);
  });

  test('rejects more than the bounded number of definitions', () async {
    final directory = await Directory.systemTemp.createTemp(
      'git-desktop-custom-actions-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final store = FileCustomActionConfigurationStore(
      file: File('${directory.path}${Platform.pathSeparator}actions.json'),
    );

    expect(
      () => store.save([
        for (
          var index = 0;
          index <= FileCustomActionConfigurationStore.maxConfigurations;
          index++
        )
          configuration('action-$index'),
      ]),
      throwsArgumentError,
    );
  });

  test(
    'controller serializes complete replacements and can await shutdown',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'git-desktop-custom-actions-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = FileCustomActionConfigurationStore(
        file: File('${directory.path}${Platform.pathSeparator}actions.json'),
      );
      final container = ProviderContainer(
        overrides: [
          customActionConfigurationStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(
        customActionConfigurationProvider.notifier,
      );

      expect(await controller.save([configuration('first')]), isTrue);
      expect(
        container.read(customActionConfigurationProvider).configurations,
        hasLength(1),
      );
      await controller.prepareForShutdown();

      final secondContainer = ProviderContainer(
        overrides: [
          customActionConfigurationStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(secondContainer.dispose);
      final secondController = secondContainer.read(
        customActionConfigurationProvider.notifier,
      );
      await secondController.load();
      expect(
        secondContainer
            .read(customActionConfigurationProvider)
            .configurations
            .single
            .id,
        'first',
      );
    },
  );

  test(
    'a failed older write does not roll back a newer definition with the same ID',
    () async {
      final firstWriteStarted = Completer<void>();
      final releaseFirstWrite = Completer<void>();
      final writes = <List<CustomActionConfiguration>>[];
      final store = _BlockingCustomActionStore(
        onSave: (configurations) async {
          writes.add(configurations);
          if (writes.length == 1) {
            firstWriteStarted.complete();
            await releaseFirstWrite.future;
            throw StateError('first write failed');
          }
        },
      );
      final container = ProviderContainer(
        overrides: [
          customActionConfigurationStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(
        customActionConfigurationProvider.notifier,
      );

      final first = configuration('same-id');
      final second = CustomActionConfiguration(
        id: first.id,
        displayName: first.displayName,
        executablePath: first.executablePath,
        arguments: const <String>['--changed', '{repository}'],
        scope: first.scope,
        enabled: first.enabled,
      );
      final firstSave = controller.save([first]);
      await firstWriteStarted.future;
      final secondSave = controller.save([second]);
      releaseFirstWrite.complete();

      expect(await firstSave, isFalse);
      expect(await secondSave, isTrue);
      final state = container.read(customActionConfigurationProvider);
      expect(state.configurations.single.arguments, second.arguments);
      expect(state.saveFailureCount, 0);
    },
  );
}

final class _BlockingCustomActionStore
    implements CustomActionConfigurationStore {
  _BlockingCustomActionStore({required this.onSave});

  final Future<void> Function(List<CustomActionConfiguration>) onSave;

  @override
  Future<List<CustomActionConfiguration>> load() async => const [];

  @override
  Future<void> save(List<CustomActionConfiguration> configurations) =>
      onSave(configurations);
}
