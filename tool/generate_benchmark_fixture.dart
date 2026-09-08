import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Generates a deterministic, offline Git repository for performance samples.
///
/// The target must be absent or empty. Generation uses an isolated Git
/// configuration and an empty template directory, so global configuration,
/// credential helpers, hooks, remotes, and network access are never used.
Future<void> main(List<String> arguments) async {
  final options = _FixtureOptions.parse(arguments);
  if (options == null) {
    stderr.writeln(_FixtureOptions.usage);
    exitCode = 64;
    return;
  }

  final target = Directory(options.outputPath).absolute;
  if (await target.exists()) {
    final entries = await target.list(followLinks: false).take(1).toList();
    if (entries.isNotEmpty) {
      stderr.writeln(
        'Target directory must be absent or empty: ${target.path}',
      );
      exitCode = 73;
      return;
    }
  } else {
    await target.create(recursive: true);
  }

  final temporaryRoot = await Directory.systemTemp.createTemp(
    'git-desktop-benchmark-',
  );
  try {
    final templateDirectory = Directory('${temporaryRoot.path}/template');
    await templateDirectory.create();
    final environment = <String, String>{
      ...Platform.environment,
      'GIT_CONFIG_NOSYSTEM': '1',
      'GIT_CONFIG_GLOBAL': '/dev/null',
      'GIT_CONFIG_SYSTEM': '/dev/null',
      'GIT_TERMINAL_PROMPT': '0',
      'GIT_PAGER': 'cat',
    };
    await _git(target.path, environment, [
      '-c',
      'init.templateDir=${templateDirectory.path}',
      'init',
      '--initial-branch=main',
    ]);
    await _git(target.path, environment, ['config', 'user.name', 'Benchmark']);
    await _git(target.path, environment, [
      'config',
      'user.email',
      'benchmark@example.invalid',
    ]);

    await _writeHistoryWithFastImport(
      target.path,
      environment,
      profile: options.profile,
      seed: options.seed,
    );
    // The target was verified absent or empty before initialization. Populate
    // its work tree from the imported index without ever addressing a user
    // repository; otherwise every tracked file would look deleted to status.
    await _git(target.path, environment, ['reset', '--hard', 'HEAD']);

    for (var index = 0; index < options.profile.refs; index += 1) {
      await _git(target.path, environment, [
        'tag',
        'benchmark-${index.toString().padLeft(5, '0')}',
      ]);
    }
    for (var index = 0; index < options.profile.changes; index += 1) {
      final relativePath =
          'changes/change-${index.toString().padLeft(5, '0')}.txt';
      final file = File('${target.path}${Platform.pathSeparator}$relativePath');
      await file.parent.create(recursive: true);
      await file.writeAsString('uncommitted fixture change $index\n');
    }
    stdout.writeln(
      'Created ${options.profile.name} fixture at ${target.path} '
      '(seed ${options.seed}).',
    );
  } finally {
    await temporaryRoot.delete(recursive: true);
  }
}

String _relativePath(int index) =>
    'files/${(index ~/ 100).toString().padLeft(4, '0')}/'
    'file-${index.toString().padLeft(6, '0')}.txt';

Future<void> _git(
  String workingDirectory,
  Map<String, String> environment,
  List<String> arguments,
) async {
  final result = await Process.run(
    'git',
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
    runInShell: false,
  );
  if (result.exitCode == 0) return;
  throw ProcessException(
    'git',
    arguments,
    'Fixture generation failed: ${result.stderr}',
    result.exitCode,
  );
}

/// Streams deterministic history into one isolated Git process.
///
/// `fast-import` does not invoke ordinary commit hooks; the caller also uses
/// an isolated configuration, so fixture generation cannot consume user
/// credentials, remotes, hooks, or global configuration.
Future<void> _writeHistoryWithFastImport(
  String workingDirectory,
  Map<String, String> environment, {
  required _FixtureProfile profile,
  required int seed,
}) async {
  final process = await Process.start(
    'git',
    const ['fast-import', '--quiet'],
    workingDirectory: workingDirectory,
    environment: environment,
    runInShell: false,
  );
  final stderrFuture = process.stderr.transform(utf8.decoder).join();
  final stdoutDrain = process.stdout.drain<void>();
  final input = process.stdin;
  final random = Random(seed);
  for (var index = 0; index < profile.commits; index += 1) {
    final relativePath = _relativePath(index % profile.files);
    final message = 'fixture commit ${index + 1}';
    final content =
        'fixture=${profile.name}\nseed=$seed\nrevision=${index + 1}\n'
        'noise=${random.nextInt(1 << 32)}\n';
    final timestamp = 1700000000 + index;
    input.write('commit refs/heads/main\n');
    input.write('mark :${index + 1}\n');
    input.write(
      'author Benchmark <benchmark@example.invalid> $timestamp +0000\n',
    );
    input.write(
      'committer Benchmark <benchmark@example.invalid> $timestamp +0000\n',
    );
    input.write('data ${utf8.encode(message).length}\n$message\n');
    input.write('M 100644 inline $relativePath\n');
    input.write('data ${utf8.encode(content).length}\n$content\n');
    if ((index + 1) % 1000 == 0 || index + 1 == profile.commits) {
      stdout.writeln('Queued ${index + 1}/${profile.commits} commits.');
      await input.flush();
    }
  }
  input.write('done\n');
  await input.close();
  final exitCode = await process.exitCode;
  await stdoutDrain;
  final stderr = await stderrFuture;
  if (exitCode != 0) {
    throw ProcessException(
      'git',
      const ['fast-import', '--quiet'],
      'Fixture generation failed: $stderr',
      exitCode,
    );
  }
}

enum _FixtureProfile {
  small('small', commits: 1000, files: 1000, refs: 20, changes: 0),
  medium('medium', commits: 10000, files: 10000, refs: 200, changes: 0),
  stress('stress', commits: 100000, files: 100000, refs: 1000, changes: 10000);

  const _FixtureProfile(
    this.name, {
    required this.commits,
    required this.files,
    required this.refs,
    required this.changes,
  });

  final String name;
  final int commits;
  final int files;
  final int refs;
  final int changes;

  static _FixtureProfile? parse(String value) {
    for (final profile in values) {
      if (profile.name == value) return profile;
    }
    return null;
  }
}

final class _FixtureOptions {
  const _FixtureOptions({
    required this.profile,
    required this.outputPath,
    required this.seed,
  });

  static const usage = '''Usage:
  dart run tool/generate_benchmark_fixture.dart <small|medium|stress> <output-directory> [seed]

The target directory must be absent or empty. The default seed is 20260907.''';

  final _FixtureProfile profile;
  final String outputPath;
  final int seed;

  static _FixtureOptions? parse(List<String> arguments) {
    if (arguments.length < 2 || arguments.length > 3) return null;
    final profile = _FixtureProfile.parse(arguments[0]);
    final outputPath = arguments[1].trim();
    final seed = arguments.length == 3 ? int.tryParse(arguments[2]) : 20260907;
    if (profile == null || outputPath.isEmpty || seed == null) return null;
    return _FixtureOptions(
      profile: profile,
      outputPath: outputPath,
      seed: seed,
    );
  }
}
