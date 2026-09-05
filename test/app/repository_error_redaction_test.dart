import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/app/repository_session.dart';
import 'package:git_desktop/src/git/git.dart';

void main() {
  test(
    'session messages and technical details redact Git credentials',
    () async {
      if (Platform.isWindows) return;
      final directory = await Directory.systemTemp.createTemp(
        'git-error-redaction-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final helper = File('${directory.path}/fake-git');
      await helper.writeAsString('''#!/bin/sh
printf '%s\n' 'failed https://alice:secret@example.invalid/repo.git?token=token-value' >&2
exit 1
''');
      final chmod = await Process.run('chmod', ['+x', helper.path]);
      expect(chmod.exitCode, 0);
      final container = ProviderContainer(
        overrides: [
          gitRunnerProvider.overrideWithValue(
            GitRunner(executable: helper.path),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(repositorySessionProvider.notifier)
          .openRepository(directory.path);

      final state = container.read(repositorySessionProvider);
      expect(state.phase, RepositorySessionPhase.error);
      expect(state.message, isNot(contains('secret')));
      expect(state.message, isNot(contains('token-value')));
      expect(state.technicalDetails, isNot(contains('secret')));
      expect(state.technicalDetails, isNot(contains('token-value')));
      expect('${state.message}\n${state.technicalDetails}', contains('***'));
    },
  );
}
