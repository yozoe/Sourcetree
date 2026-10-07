import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/app/git_desktop_app.dart';
import 'package:git_desktop/src/app/repository_session.dart';
import 'package:integration_test/integration_test.dart';

import '../test/support/git_test_repository.dart';

late final IntegrationTestWidgetsFlutterBinding _binding;

/// Creates the integration binding without re-registering Flutter's native
/// exit extension in a profile `flutter drive` process.
///
/// 中文：在 profile `flutter drive` 进程中，macOS engine 已经提供
/// `ext.flutter.exit`；标准 integration binding 再注册一次会让测试在首个
/// widget 创建前失败。因此 profile 只注册 integration-test driver 扩展，
/// debug 仍使用 Flutter 官方 binding 的完整扩展集合。
IntegrationTestWidgetsFlutterBinding _createPerformanceBinding() {
  if (const bool.fromEnvironment('dart.vm.profile')) {
    return _ProfileIntegrationTestWidgetsFlutterBinding();
  }
  return IntegrationTestWidgetsFlutterBinding.ensureInitialized();
}

/// Profile-only binding that avoids the duplicate native exit extension.
///
/// 中文：仅用于 profile 性能驱动；保留 driver 回调和测试结果上报，避免
/// 调用标准 binding 的 `super.initServiceExtensions()`。
class _ProfileIntegrationTestWidgetsFlutterBinding
    extends IntegrationTestWidgetsFlutterBinding {
  // The profile engine already owns `ext.flutter.exit`; calling super would
  // re-register it and fail before the test starts.
  @override
  // ignore: must_call_super
  void initServiceExtensions() {
    registerServiceExtension(name: 'driver', callback: callback);
  }
}

void main() {
  // Initialize before registering the test so IntegrationTestWidgetsFlutterBinding
  // can install its tearDownAll callback while the test declarer is still open.
  // 中文：在注册测试前初始化 binding，确保它能在测试声明器关闭前安装
  // tearDownAll 回调。
  _binding = _createPerformanceBinding();
  testWidgets('reports macOS startup and history scroll performance', (
    tester,
  ) async {
    final repository = await _createHistoryFixture(commitCount: 120);
    addTearDown(repository.dispose);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final rssBeforeStartup = ProcessInfo.currentRss;
    final startupStopwatch = Stopwatch()..start();

    await _binding.watchPerformance(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const GitDesktopApp(isWorkspaceWindow: true),
        ),
      );
      await container
          .read(repositorySessionProvider.notifier)
          .openRepository(
            repository.workingDirectory.path,
            waitForInitialCommit: false,
          );
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('history-list')),
        findsOneWidget,
      );
      startupStopwatch.stop();
    }, reportKey: 'macos_startup_performance');
    _addFirstFrameMetrics('macos_startup_performance');
    final startupReport = _binding.reportData?['macos_startup_performance'];
    if (startupReport is Map) {
      startupReport['startup_to_interactive_millis'] =
          startupStopwatch.elapsedMicroseconds / 1000;
      startupReport['interactive_definition'] =
          'history_ready_before_initial_commit_preview';
    }

    // Keep scroll and memory sampling comparable after the interactive marker:
    // the initial commit preview is intentionally outside startup timing, but
    // must finish before later measurements begin.
    for (var attempt = 0; attempt < 500; attempt += 1) {
      final session = container.read(repositorySessionProvider);
      if (!session.isCommitLoading && !session.isCommitDiffLoading) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump();
    }
    final previewReadySession = container.read(repositorySessionProvider);
    expect(previewReadySession.isCommitLoading, isFalse);
    expect(previewReadySession.isCommitDiffLoading, isFalse);
    await tester.pumpAndSettle();

    final rssAfterStartup = ProcessInfo.currentRss;
    final heapAfterStartup = _captureHeapSnapshot('after_startup');
    final historyList = find.byKey(const ValueKey<String>('history-list'));
    expect(historyList, findsOneWidget);

    await _binding.watchPerformance(() async {
      // Alternate both directions so every sample traverses real history
      // content instead of repeatedly flinging an already-clamped list.
      // 中文：交替向两个方向滚动，避免列表到达边界后后续样本没有真实内容。
      for (var sample = 0; sample < _historyScrollSamples; sample += 1) {
        final direction = sample.isEven ? 1.0 : -1.0;
        await tester.fling(historyList, Offset(0, 2400 * direction), 4200);
        await tester.pumpAndSettle();
      }
    }, reportKey: 'macos_history_scroll_performance');
    _addP95FrameMetrics('macos_history_scroll_performance');
    final historyReport =
        _binding.reportData?['macos_history_scroll_performance'];
    if (historyReport is Map) {
      historyReport['scroll_samples'] = _historyScrollSamples;
    }

    final rssAfterScroll = ProcessInfo.currentRss;
    final heapAfterScroll = _captureHeapSnapshot('after_history_scroll');

    final searchField = find.byKey(
      const ValueKey<String>('history-search-field'),
    );
    expect(searchField, findsOneWidget);
    final searchStopwatch = Stopwatch()..start();
    await tester.tap(searchField);
    await tester.enterText(searchField, 'Performance fixture 111');
    await tester.pump();
    // Profile `flutter drive` uses the live integration binding, so advancing
    // the test clock with `pump(Duration)` does not reliably fire the real
    // debounce Timer.  Wait on the wall clock before pumping the resulting
    // state back through the widget tree and measuring the complete response.
    await Future<void>.delayed(const Duration(milliseconds: 240));
    await tester.pumpAndSettle();
    // macOS profile drive does not always install a native text-input client
    // for the test VM. Keep the measurement deterministic by applying the
    // same session callback when the platform text event was dropped.
    var usedSearchSessionFallback = false;
    if (container.read(repositorySessionProvider).searchQuery.isEmpty) {
      usedSearchSessionFallback = true;
      container
          .read(repositorySessionProvider.notifier)
          .setSearchQuery('Performance fixture 111');
      await tester.pumpAndSettle();
    }
    searchStopwatch.stop();
    expect(
      container.read(repositorySessionProvider).searchQuery,
      'Performance fixture 111',
    );
    expect(
      find.bySemanticsLabel(RegExp(r'^Performance fixture 111，')),
      findsOneWidget,
    );
    final searchReport = <String, Object>{
      'query': 'Performance fixture 111',
      'elapsedMillis': searchStopwatch.elapsedMicroseconds / 1000,
      'debounceMillis': 220,
      'usedSessionFallback': usedSearchSessionFallback,
    };

    final navigationBranch = find.byKey(
      const ValueKey<String>('ref-nav:refs/heads/perf-navigation'),
    );
    final navigationScrollable = find.descendant(
      of: find.byKey(const ValueKey<String>('refs-navigation-list')),
      matching: find.byType(Scrollable),
    );
    expect(navigationScrollable, findsOneWidget);
    for (
      var attempt = 0;
      attempt < 12 && navigationBranch.evaluate().isEmpty;
      attempt += 1
    ) {
      await tester.drag(navigationScrollable, const Offset(0, -240));
      await tester.pumpAndSettle();
    }
    expect(navigationBranch, findsOneWidget);
    final navigationStopwatch = Stopwatch()..start();
    await tester.tap(navigationBranch);
    await tester.pumpAndSettle();
    navigationStopwatch.stop();
    expect(
      container.read(repositorySessionProvider).selectedRefId,
      'refs/heads/perf-navigation',
    );
    final navigationReport = <String, Object>{
      'branch': 'perf-navigation',
      'elapsedMillis': navigationStopwatch.elapsedMicroseconds / 1000,
    };

    _binding.reportData ??= <String, dynamic>{};
    _binding.reportData!['macos_search_performance'] = searchReport;
    _binding.reportData!['macos_reference_navigation_performance'] =
        navigationReport;
    _binding.reportData!['macos_memory_samples'] = <String, Object>{
      'rssBeforeStartupBytes': rssBeforeStartup,
      'rssAfterStartupBytes': rssAfterStartup,
      'rssAfterHistoryScrollBytes': rssAfterScroll,
      'rssStartupDeltaBytes': rssAfterStartup - rssBeforeStartup,
      'rssScrollDeltaBytes': rssAfterScroll - rssAfterStartup,
    };
    _binding.reportData!['heap_snapshots'] = <String, Object>{
      'afterStartup': heapAfterStartup,
      'afterHistoryScroll': heapAfterScroll,
    };
    // Use the shared temporary root so the host running `flutter test` can
    // collect the report after the macOS app process exits.
    final reportFile = File(
      '/private/tmp/git_desktop_macos_performance_report.json',
    );
    final report = <String, dynamic>{
      'generatedAt': DateTime.now().toIso8601String(),
      'report': _binding.reportData!,
    };
    await reportFile.writeAsString(
      JsonEncoder.withIndent('  ').convert(report),
      flush: true,
    );
    stdout.writeln(
      'macos_performance_memory=${jsonEncode(_binding.reportData!['macos_memory_samples'])}',
    );
    stdout.writeln(
      'macos_performance_heap_snapshots=${jsonEncode(_binding.reportData!['heap_snapshots'])}',
    );
    stdout.writeln('macos_performance_search=${jsonEncode(searchReport)}');
    stdout.writeln(
      'macos_performance_reference_navigation=${jsonEncode(navigationReport)}',
    );
    stdout.writeln('macos_performance_report=${reportFile.path}');
  });
}

/// Captures a native Dart heap snapshot for the current integration-test VM.
/// 中文：为当前 integration test VM 写入原生 Dart 堆快照；若当前 Flutter
/// 运行模式不支持该实验性 API，则将原因写入报告而不是伪造成功。
Map<String, Object> _captureHeapSnapshot(String label) {
  final path =
      '${Directory.systemTemp.path}/'
      'git_desktop_macos_${pid}_$label.heapsnapshot';
  try {
    developer.NativeRuntime.writeHeapSnapshotToFile(path);
    final file = File(path);
    final size = file.existsSync() ? file.lengthSync() : 0;
    return <String, Object>{'supported': true, 'path': path, 'bytes': size};
  } on Object catch (error) {
    return <String, Object>{
      'supported': false,
      'errorType': error.runtimeType.toString(),
      'error': error.toString(),
    };
  }
}

const int _historyScrollSamples = 8;

/// Adds the first startup frame timing to the raw performance report.
///
/// 中文：把启动阶段第一帧构建耗时写入原始性能报告；启动阶段帧数很少，
/// 不把它伪装成稳定的 P95。
void _addFirstFrameMetrics(String reportKey) {
  final raw = _binding.reportData?[reportKey];
  if (raw is! Map) {
    return;
  }
  final rawFrameTimes = raw['frame_build_times'];
  if (rawFrameTimes is! List || rawFrameTimes.isEmpty) {
    return;
  }
  final firstFrame = rawFrameTimes.whereType<num>().firstOrNull;
  if (firstFrame == null) {
    return;
  }
  raw['first_frame_build_time_millis'] = firstFrame.toDouble() / 1000;
}

/// Adds an exact P95 derived from the raw frame timings emitted by
/// `watchPerformance`, whose built-in summary only exposes P90 and P99.
/// 中文：从 `watchPerformance` 的原始帧耗时计算精确 P95；内置摘要只有 P90/P99。
void _addP95FrameMetrics(String reportKey) {
  final raw = _binding.reportData?[reportKey];
  if (raw is! Map) {
    return;
  }
  final rawFrameTimes = raw['frame_build_times'];
  if (rawFrameTimes is! List || rawFrameTimes.isEmpty) {
    return;
  }
  final frameTimesMicros =
      rawFrameTimes.whereType<num>().map((value) => value.toDouble()).toList()
        ..sort();
  if (frameTimesMicros.isEmpty) {
    return;
  }
  final index = ((frameTimesMicros.length * 0.95).ceil() - 1).clamp(
    0,
    frameTimesMicros.length - 1,
  );
  raw['p95_frame_build_time_millis'] = frameTimesMicros[index] / 1000;
}

/// Creates a deterministic local history fixture for Flutter UI measurements.
///
/// 中文：创建用于 Flutter 界面测量的确定性本地历史仓库；测试只写入
/// 临时目录，不读取用户仓库、凭据或远端。
Future<GitTestRepository> _createHistoryFixture({
  required int commitCount,
}) async {
  if (commitCount < 2) {
    throw ArgumentError.value(
      commitCount,
      'commitCount',
      'Must be at least 2.',
    );
  }
  final repository = await GitTestRepository.create();
  await repository.writeFile('history.txt', 'revision 0\n');
  await repository.commit('Performance fixture 0');
  for (var index = 1; index < commitCount; index += 1) {
    await repository.writeFile('history.txt', 'revision $index\n');
    await repository.commit('Performance fixture $index');
  }
  await repository.runGit(['branch', 'perf-navigation']);
  return repository;
}
