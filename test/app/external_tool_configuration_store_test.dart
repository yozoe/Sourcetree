import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/app/external_tool_configuration.dart';
import 'package:git_desktop/src/app/external_tool_configuration_store.dart';

void main() {
  test('persists a valid read-only configuration atomically', () async {
    final directory = await Directory.systemTemp.createTemp(
      'external-tool-store-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/external-tool.json');
    final store = FileExternalToolConfigurationStore(file: file);
    final expected = ExternalToolConfiguration(
      displayName: 'Diff Tool',
      executablePath: '/Applications/Diff Tool',
      arguments: const ['{before}', '{after}', '{path}'],
      enabled: true,
    );

    await store.save(expected);

    final loaded = await store.load();
    expect(loaded, isNotNull);
    expect(loaded!.toJson(), expected.toJson());
    expect(await file.readAsString(), contains('"version":1'));
    expect(
      await directory
          .list()
          .where((entry) => entry.path.contains('.tmp.'))
          .toList(),
      isEmpty,
    );
  });

  test('malformed, oversized, and unsafe records fall back to null', () async {
    final directory = await Directory.systemTemp.createTemp(
      'external-tool-store-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/external-tool.json');
    final store = FileExternalToolConfigurationStore(file: file);

    await file.writeAsString(
      '{"version":1,"configuration":{"kind":"mergeWriteBack"}}',
    );
    expect(await store.load(), isNull);
    await file.writeAsString(
      jsonEncode(<String, Object>{
        'version': 1,
        'configuration': <String, Object>{
          'displayName': 'bad',
          'executablePath': 'relative/tool',
          'arguments': const ['{before}', '{after}'],
          'kind': 'readOnlyDiff',
          'enabled': true,
        },
      }),
    );
    expect(await store.load(), isNull);
    await file.writeAsString(List<String>.filled(70 * 1024, 'x').join());
    expect(await store.load(), isNull);
  });

  test('does not persist merge write-back or invalid configurations', () async {
    final directory = await Directory.systemTemp.createTemp(
      'external-tool-store-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final store = FileExternalToolConfigurationStore(
      file: File('${directory.path}/external-tool.json'),
    );
    final merge = ExternalToolConfiguration(
      displayName: 'Merge',
      executablePath: '/tool',
      arguments: const ['{before}', '{after}'],
      kind: ExternalToolKind.mergeWriteBack,
    );
    await expectLater(store.save(merge), throwsArgumentError);
    await expectLater(
      store.save(
        ExternalToolConfiguration(
          displayName: 'Invalid',
          executablePath: 'relative/tool',
          arguments: const ['{before}', '{after}'],
        ),
      ),
      throwsArgumentError,
    );
  });

  test('clearing configuration is an explicit atomic record', () async {
    final directory = await Directory.systemTemp.createTemp(
      'external-tool-store-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/external-tool.json');
    final store = FileExternalToolConfigurationStore(file: file);
    await store.save(null);
    expect(await store.load(), isNull);
    expect(await file.readAsString(), contains('"configuration":null'));
  });

  test('controller loads and saves only validated configuration', () async {
    final store = _RecordingStore();
    final container = ProviderContainer(
      overrides: [
        externalToolConfigurationStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(
      externalToolConfigurationProvider.notifier,
    );
    await controller.load();
    expect(
      container.read(externalToolConfigurationProvider).configuration,
      isNull,
    );

    final configuration = _configuration();
    expect(await controller.save(configuration), isTrue);
    expect(store.saved?.toJson(), configuration.toJson());
    expect(
      container.read(externalToolConfigurationProvider).configuration?.toJson(),
      configuration.toJson(),
    );
    expect(
      await controller.save(
        ExternalToolConfiguration(
          displayName: 'Invalid',
          executablePath: 'relative/tool',
          arguments: const ['{before}', '{after}'],
        ),
      ),
      isFalse,
    );
  });

  test(
    'controller exposes save failure without enabling a failed config',
    () async {
      final container = ProviderContainer(
        overrides: [
          externalToolConfigurationStoreProvider.overrideWithValue(
            _FailingStore(),
          ),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(
        externalToolConfigurationProvider.notifier,
      );

      expect(await controller.save(_configuration()), isFalse);
      final state = container.read(externalToolConfigurationProvider);
      expect(state.configuration, isNull);
      expect(state.saveFailureCount, 1);
    },
  );

  test('controller shutdown waits for queued configuration writes', () async {
    final store = _DelayedStore();
    final container = ProviderContainer(
      overrides: [
        externalToolConfigurationStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(
      externalToolConfigurationProvider.notifier,
    );
    final save = controller.save(_configuration());
    final shutdown = controller.prepareForShutdown();
    var finished = false;
    shutdown.then((_) => finished = true);
    await Future<void>.delayed(Duration.zero);
    expect(finished, isFalse);
    store.release();
    await save;
    await shutdown;
    expect(finished, isTrue);
  });
}

ExternalToolConfiguration _configuration() => ExternalToolConfiguration(
  displayName: 'Diff Tool',
  executablePath: '/Applications/Diff Tool',
  arguments: const ['{before}', '{after}', '{path}'],
  enabled: true,
);

final class _RecordingStore implements ExternalToolConfigurationStore {
  ExternalToolConfiguration? saved;

  @override
  Future<ExternalToolConfiguration?> load() async => saved;

  @override
  Future<void> save(ExternalToolConfiguration? configuration) async {
    saved = configuration;
  }
}

final class _FailingStore implements ExternalToolConfigurationStore {
  @override
  Future<ExternalToolConfiguration?> load() async => null;

  @override
  Future<void> save(ExternalToolConfiguration? configuration) async {
    throw StateError('configuration storage unavailable');
  }
}

final class _DelayedStore implements ExternalToolConfigurationStore {
  final Completer<void> _release = Completer<void>();

  void release() => _release.complete();

  @override
  Future<ExternalToolConfiguration?> load() async => null;

  @override
  Future<void> save(ExternalToolConfiguration? configuration) async {
    await _release.future;
  }
}
