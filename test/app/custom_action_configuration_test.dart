import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/app/custom_action_configuration.dart';
import 'package:git_desktop/src/app/repository_trust.dart';

void main() {
  CustomActionConfiguration configuration({
    String id = 'inspect-repository',
    CustomActionScope scope = CustomActionScope.repository,
    List<String> arguments = const <String>['--repository', '{repository}'],
    Map<String, String> environment = const <String, String>{},
    bool enabled = false,
  }) => CustomActionConfiguration(
    id: id,
    displayName: 'Inspect repository',
    executablePath: '/usr/bin/example-tool',
    arguments: arguments,
    scope: scope,
    environment: environment,
    enabled: enabled,
  );

  test('custom actions are disabled by default and require explicit trust', () {
    final disabled = configuration();
    final enabled = configuration(enabled: true);

    expect(disabled.enabled, isFalse);
    expect(
      canActivateCustomAction(
        trustStatus: RepositoryTrustStatus.trusted,
        configuration: disabled,
      ),
      isFalse,
    );
    expect(
      canActivateCustomAction(
        trustStatus: RepositoryTrustStatus.unconfirmed,
        configuration: enabled,
      ),
      isFalse,
    );
    expect(
      canActivateCustomAction(
        trustStatus: RepositoryTrustStatus.restricted,
        configuration: enabled,
      ),
      isFalse,
    );
    expect(
      canActivateCustomAction(
        trustStatus: RepositoryTrustStatus.trusted,
        configuration: enabled,
      ),
      isTrue,
    );
  });

  test(
    'builds a repository-scoped literal argv without inherited environment',
    () {
      final action = configuration(
        arguments: const <String>[
          '--root={repository}',
          r'--literal=$HOME;echo not-a-shell',
        ],
        environment: const <String, String>{'LANG': 'zh_CN.UTF-8'},
        enabled: true,
      );

      final invocation = action.buildInvocation(
        const CustomActionTarget.repository(repositoryRoot: '/tmp/example'),
      );

      expect(invocation.executablePath, '/usr/bin/example-tool');
      expect(invocation.arguments, <String>[
        '--root=/tmp/example',
        r'--literal=$HOME;echo not-a-shell',
      ]);
      expect(invocation.workingDirectory, '/tmp/example');
      expect(invocation.environment, <String, String>{'LANG': 'zh_CN.UTF-8'});
      expect(invocation.includeParentEnvironment, isFalse);
      expect(invocation.scope, CustomActionScope.repository);
      expect(invocation.repositoryRelativePath, isNull);
    },
  );

  test(
    'selected-file actions require one explicit repository-relative path',
    () {
      final action = configuration(
        scope: CustomActionScope.selectedFile,
        arguments: const <String>['--file', '{path}', '--root', '{repository}'],
        enabled: true,
      );

      final invocation = action.buildInvocation(
        const CustomActionTarget.selectedFile(
          repositoryRoot: '/tmp/example',
          repositoryRelativePath: 'lib/main.dart',
        ),
      );

      expect(invocation.arguments, <String>[
        '--file',
        'lib/main.dart',
        '--root',
        '/tmp/example',
      ]);
      expect(invocation.scope, CustomActionScope.selectedFile);
      expect(invocation.repositoryRelativePath, 'lib/main.dart');
      expect(
        () => action.buildInvocation(
          const CustomActionTarget.selectedFile(
            repositoryRoot: '/tmp/example',
            repositoryRelativePath: '../outside.txt',
          ),
        ),
        throwsArgumentError,
      );
      expect(
        () => action.buildInvocation(
          const CustomActionTarget.repository(repositoryRoot: '/tmp/example'),
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'rejects ambiguous scopes, unknown placeholders, and unsafe environment',
    () {
      expect(
        configuration(arguments: const <String>['{path}']).validate(),
        contains(CustomActionConfigurationIssue.pathPlaceholderNotAllowed),
      );
      expect(
        configuration(
          scope: CustomActionScope.selectedFile,
          arguments: const <String>['--inspect'],
        ).validate(),
        contains(CustomActionConfigurationIssue.missingPathPlaceholder),
      );
      expect(
        configuration(arguments: const <String>['{branch}']).validate(),
        contains(CustomActionConfigurationIssue.unknownPlaceholder),
      );
      expect(
        configuration(
          environment: const <String, String>{'PATH': '/tmp/bin'},
        ).validate(),
        contains(CustomActionConfigurationIssue.environmentVariableNotAllowed),
      );
      expect(
        configuration(
          environment: const <String, String>{'LANG': 'en_US.UTF-8\u0000TOKEN'},
        ).validate(),
        contains(CustomActionConfigurationIssue.invalidEnvironmentValue),
      );
    },
  );

  test('round-trips only validated version-independent configuration data', () {
    final original = configuration(
      scope: CustomActionScope.selectedFile,
      arguments: const <String>['--file={path}'],
      environment: const <String, String>{
        'LANG': 'en_US.UTF-8',
        'LC_ALL': 'en_US.UTF-8',
      },
      enabled: true,
    );

    final restored = CustomActionConfiguration.fromJson(original.toJson());

    expect(restored, isNotNull);
    expect(restored!.displayName, original.displayName);
    expect(restored.id, original.id);
    expect(restored.executablePath, original.executablePath);
    expect(restored.arguments, original.arguments);
    expect(restored.scope, original.scope);
    expect(restored.environment, original.environment);
    expect(restored.enabled, isTrue);
    expect(
      CustomActionConfiguration.fromJson(<String, Object?>{
        ...original.toJson(),
        'scope': 'allOpenRepositories',
      }),
      isNull,
    );
    expect(
      CustomActionConfiguration.fromJson(<String, Object?>{
        ...original.toJson(),
        'environment': <String, String>{'GITHUB_TOKEN': 'secret'},
      }),
      isNull,
    );
  });

  test(
    'rejects a selected file whose symlink resolves outside the repository',
    () async {
      final root = await Directory.systemTemp.createTemp('custom-action-root-');
      final outside = await Directory.systemTemp.createTemp(
        'custom-action-outside-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
        if (await outside.exists()) await outside.delete(recursive: true);
      });
      final outsideFile = File('${outside.path}/secret.txt');
      await outsideFile.writeAsString('secret\n');
      final link = Link('${root.path}/linked.txt');
      await link.create(outsideFile.path);

      final action = configuration(
        scope: CustomActionScope.selectedFile,
        arguments: const <String>['--file', '{path}'],
        enabled: true,
      );

      expect(
        () => action.buildInvocation(
          CustomActionTarget.selectedFile(
            repositoryRoot: root.path,
            repositoryRelativePath: 'linked.txt',
          ),
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'rejects a missing selected file below a symlinked directory outside the repository',
    () async {
      final root = await Directory.systemTemp.createTemp('custom-action-root-');
      final outside = await Directory.systemTemp.createTemp(
        'custom-action-outside-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
        if (await outside.exists()) await outside.delete(recursive: true);
      });
      final link = Link('${root.path}/linked-dir');
      await link.create(outside.path);

      final action = configuration(
        scope: CustomActionScope.selectedFile,
        arguments: const <String>['--file', '{path}'],
        enabled: true,
      );

      expect(
        () => action.buildInvocation(
          CustomActionTarget.selectedFile(
            repositoryRoot: root.path,
            repositoryRelativePath: 'linked-dir/new.txt',
          ),
        ),
        throwsArgumentError,
      );
    },
  );

  test('detects any definition change after confirmation', () {
    final original = configuration(
      environment: const <String, String>{'LANG': 'C'},
      enabled: true,
    );
    expect(original.hasSameDefinitionAs(original), isTrue);
    expect(
      original.hasSameDefinitionAs(
        configuration(
          arguments: const <String>[
            '--repository',
            '{repository}',
            '--verbose',
          ],
          environment: const <String, String>{'LANG': 'C'},
          enabled: true,
        ),
      ),
      isFalse,
    );
    expect(
      original.hasSameDefinitionAs(
        configuration(
          scope: CustomActionScope.selectedFile,
          arguments: const <String>['--file', '{path}'],
          environment: const <String, String>{'LANG': 'C'},
          enabled: true,
        ),
      ),
      isFalse,
    );
  });
}
