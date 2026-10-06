import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/app/external_tool_configuration.dart';
import 'package:git_desktop/src/app/repository_trust.dart';

void main() {
  final executable = Platform.isWindows
      ? r'C:\Tools\DiffTool.exe'
      : '/Applications/DiffTool.app/Contents/MacOS/DiffTool';
  final repositoryRoot = Platform.isWindows
      ? r'C:\Repositories\example'
      : '/Repositories/example';
  final beforeSnapshot = Platform.isWindows
      ? r'C:\Temp\before snapshot'
      : '/private/tmp/before snapshot';
  final afterSnapshot = Platform.isWindows
      ? r'C:\Temp\after snapshot'
      : '/private/tmp/after snapshot';

  ExternalToolConfiguration configuration({
    bool enabled = true,
    ExternalToolKind kind = ExternalToolKind.readOnlyDiff,
    List<String>? arguments,
    String? executablePath,
  }) => ExternalToolConfiguration(
    displayName: 'Configured Diff',
    executablePath: executablePath ?? executable,
    arguments:
        arguments ??
        const [
          '--before',
          '{before}',
          '--after={after}',
          '--repository',
          '{repository}',
          '--path={path}',
        ],
    kind: kind,
    enabled: enabled,
  );

  test('builds a literal argv invocation without shell interpretation', () {
    final invocation = configuration().buildReadOnlyDiffInvocation(
      beforeSnapshotPath: beforeSnapshot,
      afterSnapshotPath: afterSnapshot,
      repositoryRoot: repositoryRoot,
      repositoryRelativePath: 'lib/a file.dart',
    );

    expect(invocation.executablePath, executable);
    expect(invocation.arguments, [
      '--before',
      beforeSnapshot,
      '--after=$afterSnapshot',
      '--repository',
      repositoryRoot,
      '--path=lib/a file.dart',
    ]);
  });

  test('requires trusted opt-in and a valid read-only Diff template', () {
    final configured = configuration();
    expect(
      canActivateExternalTool(
        trustStatus: RepositoryTrustStatus.unconfirmed,
        configuration: configured,
      ),
      isFalse,
    );
    expect(
      canActivateExternalTool(
        trustStatus: RepositoryTrustStatus.restricted,
        configuration: configured,
      ),
      isFalse,
    );
    expect(
      canActivateExternalTool(
        trustStatus: RepositoryTrustStatus.trusted,
        configuration: configuration(enabled: false),
      ),
      isFalse,
    );
    expect(
      canActivateExternalTool(
        trustStatus: RepositoryTrustStatus.trusted,
        configuration: configured,
      ),
      isTrue,
    );
  });

  test(
    'rejects incomplete, unknown, relative, and validates merge templates',
    () {
      expect(
        configuration(arguments: const ['{before}', '{unknown}']).validate(),
        containsAll([
          ExternalToolConfigurationIssue.unknownPlaceholder,
          ExternalToolConfigurationIssue.missingAfterPlaceholder,
        ]),
      );
      expect(
        configuration(executablePath: 'relative/tool').validate(),
        contains(ExternalToolConfigurationIssue.executableMustBeAbsolute),
      );
      final merge = configuration(
        kind: ExternalToolKind.mergeWriteBack,
        arguments: const ['{base}', '{ours}', '{theirs}', '{result}', '{path}'],
      );
      expect(merge.validate(), isEmpty);
      expect(
        configuration(
          kind: ExternalToolKind.mergeWriteBack,
          arguments: const ['{base}', '{ours}', '{theirs}'],
        ).validate(),
        contains(ExternalToolConfigurationIssue.missingResultPlaceholder),
      );
    },
  );

  test('builds a literal three-way merge invocation', () {
    final merge = configuration(
      kind: ExternalToolKind.mergeWriteBack,
      arguments: const [
        '--base',
        '{base}',
        '--ours',
        '{ours}',
        '--theirs',
        '{theirs}',
        '--result',
        '{result}',
      ],
    );
    final invocation = merge.buildMergeInvocation(
      baseSnapshotPath: '/private/tmp/base',
      oursSnapshotPath: '/private/tmp/ours',
      theirsSnapshotPath: '/private/tmp/theirs',
      resultSnapshotPath: '/private/tmp/result',
      repositoryRoot: repositoryRoot,
      repositoryRelativePath: 'lib/a.dart',
    );
    expect(invocation.arguments, [
      '--base',
      '/private/tmp/base',
      '--ours',
      '/private/tmp/ours',
      '--theirs',
      '/private/tmp/theirs',
      '--result',
      '/private/tmp/result',
    ]);
  });

  test('rejects request paths that escape or are not absolute', () {
    expect(
      () => configuration().buildReadOnlyDiffInvocation(
        beforeSnapshotPath: 'before',
        afterSnapshotPath: afterSnapshot,
        repositoryRoot: repositoryRoot,
        repositoryRelativePath: 'lib/a.dart',
      ),
      throwsArgumentError,
    );
    expect(
      () => configuration().buildReadOnlyDiffInvocation(
        beforeSnapshotPath: beforeSnapshot,
        afterSnapshotPath: afterSnapshot,
        repositoryRoot: repositoryRoot,
        repositoryRelativePath: '../outside.dart',
      ),
      throwsArgumentError,
    );
  });
}
