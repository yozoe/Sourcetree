import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/app/repository_change_monitor.dart';
import 'package:git_desktop/src/git/git.dart';
import 'package:path/path.dart' as path_utils;

void main() {
  test(
    'coalesces work-tree events and promotes Git metadata changes',
    () async {
      final root = await Directory.systemTemp.createTemp('repo-monitor-');
      addTearDown(() => root.delete(recursive: true));
      final gitDirectory = await Directory(
        path_utils.join(root.path, '.git'),
      ).create();
      final events = StreamController<FileSystemEvent>();
      addTearDown(events.close);
      final monitor = RepositoryChangeMonitor(
        debounceDelay: const Duration(milliseconds: 20),
        maximumDelay: const Duration(milliseconds: 80),
        watchDirectory: (_, _) => events.stream,
      );
      addTearDown(monitor.stop);
      final repository = GitRepository(
        id: GitRepositoryId(
          commonDirectory: gitDirectory.path,
          workTreeRoot: root.path,
        ),
        openedPath: root.path,
        gitDirectory: gitDirectory.path,
        commonDirectory: gitDirectory.path,
        workTreeRoot: root.path,
        isBare: false,
        isInsideWorkTree: true,
      );
      final scopes = <RepositoryExternalChangeScope>[];

      await monitor.start(repository, onChanged: scopes.add);
      events.add(
        FileSystemModifyEvent(
          path_utils.join(root.path, 'README.md'),
          false,
          true,
        ),
      );
      events.add(
        FileSystemModifyEvent(
          path_utils.join(gitDirectory.path, 'index'),
          false,
          true,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 45));

      expect(scopes, [RepositoryExternalChangeScope.workingTree]);

      events.add(
        FileSystemModifyEvent(
          path_utils.join(root.path, 'lib', 'example.dart'),
          false,
          true,
        ),
      );
      events.add(
        FileSystemModifyEvent(
          path_utils.join(gitDirectory.path, 'HEAD'),
          false,
          true,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 45));

      expect(scopes, [
        RepositoryExternalChangeScope.workingTree,
        RepositoryExternalChangeScope.repositoryMetadata,
      ]);

      events.add(
        FileSystemModifyEvent(
          path_utils.join(gitDirectory.path, 'objects', 'ab', 'object-id'),
          false,
          true,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 45));

      expect(scopes, [
        RepositoryExternalChangeScope.workingTree,
        RepositoryExternalChangeScope.repositoryMetadata,
      ]);
    },
  );

  test('stopping the monitor discards pending and later events', () async {
    final root = await Directory.systemTemp.createTemp('repo-monitor-stop-');
    addTearDown(() => root.delete(recursive: true));
    final gitDirectory = await Directory(
      path_utils.join(root.path, '.git'),
    ).create();
    final events = StreamController<FileSystemEvent>.broadcast();
    addTearDown(events.close);
    final monitor = RepositoryChangeMonitor(
      debounceDelay: const Duration(milliseconds: 20),
      maximumDelay: const Duration(milliseconds: 60),
      watchDirectory: (_, _) => events.stream,
    );
    addTearDown(monitor.stop);
    final repository = GitRepository(
      id: GitRepositoryId(
        commonDirectory: gitDirectory.path,
        workTreeRoot: root.path,
      ),
      openedPath: root.path,
      gitDirectory: gitDirectory.path,
      commonDirectory: gitDirectory.path,
      workTreeRoot: root.path,
      isBare: false,
      isInsideWorkTree: true,
    );
    final scopes = <RepositoryExternalChangeScope>[];

    await monitor.start(repository, onChanged: scopes.add);
    events.add(
      FileSystemModifyEvent(
        path_utils.join(root.path, 'pending.txt'),
        false,
        true,
      ),
    );
    await monitor.stop();
    events.add(
      FileSystemModifyEvent(
        path_utils.join(root.path, 'later.txt'),
        false,
        true,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(scopes, isEmpty);
  });

  test(
    'watches linked worktree and shared Git roots without overlap',
    () async {
      final parent = await Directory.systemTemp.createTemp(
        'repo-monitor-worktree-',
      );
      addTearDown(() => parent.delete(recursive: true));
      final workTree = await Directory(
        path_utils.join(parent.path, 'linked'),
      ).create();
      final commonDirectory = await Directory(
        path_utils.join(parent.path, 'main.git'),
      ).create();
      final gitDirectory = await Directory(
        path_utils.join(commonDirectory.path, 'worktrees', 'linked'),
      ).create(recursive: true);
      final streams = <String, StreamController<FileSystemEvent>>{};
      final monitor = RepositoryChangeMonitor(
        debounceDelay: const Duration(milliseconds: 20),
        maximumDelay: const Duration(milliseconds: 60),
        watchDirectory: (path, _) =>
            (streams[path] ??= StreamController<FileSystemEvent>()).stream,
      );
      addTearDown(() async {
        await monitor.stop();
        await Future.wait<void>([
          for (final stream in streams.values) stream.close(),
        ]);
      });
      final repository = GitRepository(
        id: GitRepositoryId(
          commonDirectory: commonDirectory.path,
          workTreeRoot: workTree.path,
        ),
        openedPath: workTree.path,
        gitDirectory: gitDirectory.path,
        commonDirectory: commonDirectory.path,
        workTreeRoot: workTree.path,
        isBare: false,
        isInsideWorkTree: true,
      );
      final scopes = <RepositoryExternalChangeScope>[];

      await monitor.start(repository, onChanged: scopes.add);

      expect(streams.keys, {workTree.path, commonDirectory.path});
      streams[commonDirectory.path]!.add(
        FileSystemModifyEvent(
          path_utils.join('worktrees', 'linked', 'HEAD'),
          false,
          true,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 45));

      expect(scopes, [RepositoryExternalChangeScope.repositoryMetadata]);
    },
  );

  test('a concurrent stop prevents an older start from reattaching', () async {
    final root = await Directory.systemTemp.createTemp(
      'repo-monitor-lifecycle-',
    );
    addTearDown(() => root.delete(recursive: true));
    final gitDirectory = await Directory(
      path_utils.join(root.path, '.git'),
    ).create();
    final cancellationGate = Completer<void>();
    final streams = <StreamController<FileSystemEvent>>[];
    var watchCount = 0;
    final monitor = RepositoryChangeMonitor(
      watchDirectory: (_, _) {
        final stream = StreamController<FileSystemEvent>(
          onCancel: watchCount == 0 ? () => cancellationGate.future : null,
        );
        watchCount++;
        streams.add(stream);
        return stream.stream;
      },
    );
    addTearDown(() async {
      if (!cancellationGate.isCompleted) cancellationGate.complete();
      await monitor.stop();
      await Future.wait<void>([for (final stream in streams) stream.close()]);
    });
    final repository = GitRepository(
      id: GitRepositoryId(
        commonDirectory: gitDirectory.path,
        workTreeRoot: root.path,
      ),
      openedPath: root.path,
      gitDirectory: gitDirectory.path,
      commonDirectory: gitDirectory.path,
      workTreeRoot: root.path,
      isBare: false,
      isInsideWorkTree: true,
    );

    await monitor.start(repository, onChanged: (_) {});
    final staleStart = monitor.start(repository, onChanged: (_) {});
    await Future<void>.delayed(Duration.zero);
    await monitor.stop();
    cancellationGate.complete();
    await staleStart;

    expect(watchCount, 1);
  });
}
