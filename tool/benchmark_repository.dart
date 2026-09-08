import 'dart:convert';
import 'dart:io';

import 'package:git_desktop/src/git/git.dart';

/// Reads one local repository repeatedly and emits JSON timing samples.
///
/// This is a read-only developer benchmark: it never changes refs, index,
/// work-tree files, remotes, configuration, or environment variables.
Future<void> main(List<String> arguments) async {
  final options = _BenchmarkOptions.parse(arguments);
  if (options == null) {
    stderr.writeln(_BenchmarkOptions.usage);
    exitCode = 64;
    return;
  }

  final runner = GitRunner();
  final inspector = GitRepositoryInspector(runner);
  final reader = GitRepositoryReader(runner);
  final repository = await inspector.inspect(options.repositoryPath);
  if (repository == null) {
    stderr.writeln('Not a Git repository: ${options.repositoryPath}');
    exitCode = 66;
    return;
  }

  final samples = <Map<String, Object>>[];
  for (var index = 0; index < options.iterations; index += 1) {
    final statusWatch = Stopwatch()..start();
    final status = await reader.readStatus(repository);
    statusWatch.stop();

    final refsWatch = Stopwatch()..start();
    final refs = await Future.wait([
      reader.readLocalBranches(repository),
      reader.readRemoteBranches(repository),
      reader.readTags(repository),
    ]);
    refsWatch.stop();

    final historyWatch = Stopwatch()..start();
    final snapshot = await reader.readHistoryRevisionSnapshot(repository);
    final history = await reader.readRecentHistory(
      repository,
      limit: 500,
      revisionSnapshot: snapshot,
    );
    historyWatch.stop();

    samples.add({
      'iteration': index + 1,
      'statusMilliseconds': statusWatch.elapsedMilliseconds,
      'refsMilliseconds': refsWatch.elapsedMilliseconds,
      'historyMilliseconds': historyWatch.elapsedMilliseconds,
      'changedFiles': status.entries.length,
      'localBranches': refs[0].length,
      'remoteBranches': refs[1].length,
      'tags': refs[2].length,
      'historyCommits': history.length,
    });
  }

  final metrics = <String, Object>{
    'repository': repository.commandDirectory,
    'iterations': options.iterations,
    'samples': samples,
    'summary': {
      for (final metric in const [
        'statusMilliseconds',
        'refsMilliseconds',
        'historyMilliseconds',
      ])
        metric: _summary(samples.map((sample) => sample[metric]! as int)),
    },
  };
  final encoded = const JsonEncoder.withIndent('  ').convert(metrics);
  final outputPath = options.outputPath;
  if (outputPath != null) {
    await File(outputPath).writeAsString('$encoded\n', flush: true);
  }
  stdout.writeln(encoded);

  final baselinePath = options.baselinePath;
  if (baselinePath == null) return;
  final comparison = await _compareP95(
    baseline: File(baselinePath),
    current: metrics,
  );
  if (comparison.isEmpty) {
    stderr.writeln('Baseline has no compatible P95 metrics: $baselinePath');
    exitCode = 65;
    return;
  }
  for (final result in comparison) {
    stderr.writeln(
      '${result.metric}: baseline ${result.baseline}ms, current '
      '${result.current}ms, ${result.changePercent.toStringAsFixed(1)}%',
    );
  }
  if (comparison.any(
    (result) => result.changePercent > options.maximumRegressionPercent,
  )) {
    stderr.writeln(
      'Performance regression exceeds ${options.maximumRegressionPercent}%.'
      ' Record an approved waiver before updating the baseline.',
    );
    exitCode = 1;
  }
}

Map<String, int> _summary(Iterable<int> values) {
  final sorted = values.toList()..sort();
  return {
    'min': sorted.first,
    'median': sorted[sorted.length ~/ 2],
    'p95': sorted[((sorted.length - 1) * .95).ceil()],
    'max': sorted.last,
  };
}

Future<List<_P95Comparison>> _compareP95({
  required File baseline,
  required Map<String, Object> current,
}) async {
  if (!await baseline.exists()) return const <_P95Comparison>[];
  Object? decoded;
  try {
    decoded = jsonDecode(await baseline.readAsString());
  } on Object {
    return const <_P95Comparison>[];
  }
  if (decoded is! Map || current['summary'] is! Map) {
    return const <_P95Comparison>[];
  }
  final baselineSummary = decoded['summary'];
  final currentSummary = current['summary'];
  if (baselineSummary is! Map || currentSummary is! Map) {
    return const <_P95Comparison>[];
  }
  final comparisons = <_P95Comparison>[];
  for (final metric in const [
    'statusMilliseconds',
    'refsMilliseconds',
    'historyMilliseconds',
  ]) {
    final baselineMetric = baselineSummary[metric];
    final currentMetric = currentSummary[metric];
    if (baselineMetric is! Map || currentMetric is! Map) continue;
    final baselineP95 = baselineMetric['p95'];
    final currentP95 = currentMetric['p95'];
    if (baselineP95 is! num || currentP95 is! num || baselineP95 <= 0) {
      continue;
    }
    comparisons.add(
      _P95Comparison(
        metric: metric,
        baseline: baselineP95.toInt(),
        current: currentP95.toInt(),
      ),
    );
  }
  return comparisons;
}

final class _P95Comparison {
  const _P95Comparison({
    required this.metric,
    required this.baseline,
    required this.current,
  });

  final String metric;
  final int baseline;
  final int current;

  double get changePercent => (current - baseline) * 100 / baseline;
}

final class _BenchmarkOptions {
  const _BenchmarkOptions({
    required this.repositoryPath,
    required this.iterations,
    required this.baselinePath,
    required this.outputPath,
    required this.maximumRegressionPercent,
  });

  static const usage = '''Usage:
  dart run tool/benchmark_repository.dart <repository-path> [iterations]
      [--baseline <json>] [--output <json>] [--max-regression-percent <number>]

The repository is read only. A baseline comparison checks P95 status, refs,
and history timings and exits non-zero above the default 15% regression.''';

  final String repositoryPath;
  final int iterations;
  final String? baselinePath;
  final String? outputPath;
  final double maximumRegressionPercent;

  static _BenchmarkOptions? parse(List<String> arguments) {
    if (arguments.isEmpty) return null;
    final repositoryPath = arguments.first.trim();
    if (repositoryPath.isEmpty) return null;
    var index = 1;
    var iterations = 5;
    if (index < arguments.length && !arguments[index].startsWith('--')) {
      iterations = int.tryParse(arguments[index]) ?? -1;
      index++;
    }
    if (iterations < 1 || iterations > 100) return null;
    String? baselinePath;
    String? outputPath;
    var maximumRegressionPercent = 15.0;
    while (index < arguments.length) {
      if (index + 1 >= arguments.length) return null;
      final value = arguments[index + 1].trim();
      if (value.isEmpty) return null;
      switch (arguments[index]) {
        case '--baseline':
          baselinePath = value;
        case '--output':
          outputPath = value;
        case '--max-regression-percent':
          maximumRegressionPercent = double.tryParse(value) ?? -1;
        default:
          return null;
      }
      index += 2;
    }
    if (maximumRegressionPercent < 0) return null;
    return _BenchmarkOptions(
      repositoryPath: repositoryPath,
      iterations: iterations,
      baselinePath: baselinePath,
      outputPath: outputPath,
      maximumRegressionPercent: maximumRegressionPercent,
    );
  }
}
