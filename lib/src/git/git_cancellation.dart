import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';

typedef GitCancellationCallback = void Function();

/// A cooperative cancellation token shared by a caller and [GitRunner].
final class GitCancellationToken {
  final Set<GitCancellationCallback> _callbacks = {};
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  /// 中文：取消当前操作。
  /// English: Cancels the current operation.
  void cancel() {
    if (_isCancelled) {
      return;
    }
    _isCancelled = true;
    for (final callback in List<GitCancellationCallback>.of(_callbacks)) {
      callback();
    }
    _callbacks.clear();
  }

  /// 中文：注册取消回调；若已取消则立即调用，并返回可安全释放的注册项。
  ///
  /// English: Registers a cancellation callback, invoking it immediately if
  /// already cancelled, and returns a safely disposable registration.
  GitCancellationRegistration register(GitCancellationCallback callback) {
    if (_isCancelled) {
      callback();
      return const GitCancellationRegistration._();
    }
    _callbacks.add(callback);
    return GitCancellationRegistration._(() => _callbacks.remove(callback));
  }
}

final class GitCancellationRegistration {
  const GitCancellationRegistration._([this._dispose]);

  final void Function()? _dispose;

  /// 中文：释放当前对象持有的资源。
  /// English: Releases resources held by this object.
  void dispose() => _dispose?.call();
}

/// Platform implementations can replace this to terminate a complete process
/// tree. The default implementation terminates the direct Git process.
abstract interface class GitProcessTerminator {
  /// 中文：终止指定 Git 进程，平台实现可同时清理其子进程树。
  ///
  /// English: Terminates the supplied Git process; platform implementations
  /// may also clean up its child process tree.
  FutureOr<void> terminate(Process process);
}

/// Adds lifecycle tracking for terminators that verify process identity before
/// signalling descendants.
abstract interface class GitTrackedProcessTerminator {
  /// 中文：进程启动后立即开始记录其身份和后代关系，返回本次进程专属的跟踪上下文。
  ///
  /// English: Starts recording process identity and descendants immediately
  /// after launch and returns a context dedicated to this process.
  Object track(Process process);

  /// 中文：使用已记录且重新验证的身份终止进程树，避免向复用的 PID 发送信号。
  ///
  /// English: Terminates a tree using recorded, revalidated identities so a
  /// reused PID is never signalled.
  Future<void> terminateTracked(Process process, Object context);

  /// 中文：停止并释放一次进程树身份跟踪。
  ///
  /// English: Stops and releases one process-tree identity tracker.
  Future<void> stopTracking(Object context);
}

final class DefaultGitProcessTerminator
    implements GitProcessTerminator, GitTrackedProcessTerminator {
  /// 中文：创建默认终止器，并设置从温和终止升级为强制终止前的等待时间。
  ///
  /// English: Creates the default terminator with the grace period before a
  /// soft termination is escalated to a forced kill.
  const DefaultGitProcessTerminator({
    this.gracePeriod = const Duration(milliseconds: 750),
  });

  final Duration gracePeriod;

  /// 中文：终止直接启动的 Git 进程。
  ///
  /// English: Terminates the directly started Git process.
  @override
  Future<void> terminate(Process process) async {
    final tracker = track(process);
    await terminateTracked(process, tracker);
  }

  @override
  Object track(Process process) {
    final tracker = _TrackedProcessTree(process.pid)..start();
    return tracker;
  }

  @override
  Future<void> terminateTracked(Process process, Object context) async {
    final tracker = context as _TrackedProcessTree;
    await tracker.refresh();
    await tracker.signal(ProcessSignal.sigterm);
    if (Platform.isWindows) process.kill(ProcessSignal.sigterm);
    try {
      await Future.wait<void>([
        process.exitCode.then<void>((_) {}),
        tracker.waitForExit(),
      ]).timeout(gracePeriod);
    } on TimeoutException {
      await tracker.refresh();
      await tracker.signal(ProcessSignal.sigkill);
      if (Platform.isWindows) process.kill(ProcessSignal.sigkill);
      await Future.wait<void>([
        process.exitCode.then<void>((_) {}),
        tracker.waitForExit(),
      ]).timeout(gracePeriod);
    } finally {
      await stopTracking(tracker);
    }
  }

  @override
  Future<void> stopTracking(Object context) async {
    await (context as _TrackedProcessTree).stop();
  }
}

final class _TrackedProcessTree {
  _TrackedProcessTree(this.rootPid);

  final int rootPid;
  final Map<int, String> _identities = <int, String>{};
  Timer? _timer;
  Future<void>? _refreshInFlight;
  bool _stopped = false;
  int _startupSnapshotCount = 0;

  /// 中文：立即启动首个身份快照，并以非重叠的低频快照继续跟踪后代。
  ///
  /// English: Starts the first identity snapshot immediately, then continues
  /// tracking descendants with low-frequency, non-overlapping snapshots.
  void start() {
    unawaited(refresh().whenComplete(_scheduleNextSnapshot));
  }

  /// 中文：仅在上次读取完成后安排下一次读取；启动阶段短暂加密，随后降低频率。
  ///
  /// English: Schedules the next read only after the previous one completes,
  /// briefly sampling faster during startup before reducing the frequency.
  void _scheduleNextSnapshot() {
    if (_stopped) return;
    final delay = _startupSnapshotCount < 4
        ? const Duration(milliseconds: 10)
        : const Duration(milliseconds: 100);
    _startupSnapshotCount += 1;
    _timer = Timer(delay, () {
      unawaited(refresh().whenComplete(_scheduleNextSnapshot));
    });
  }

  /// 中文：合并并发刷新，只沿身份未变化的已知成员扩展后代。
  ///
  /// English: Coalesces concurrent refreshes and expands descendants only from
  /// known members whose identities have not changed.
  Future<void> refresh() {
    if (_stopped) return Future<void>.value();
    final activeRefresh = _refreshInFlight;
    if (activeRefresh != null) return activeRefresh;

    final completer = Completer<void>();
    final refresh = completer.future;
    _refreshInFlight = refresh;
    unawaited(() async {
      try {
        await _refreshNow();
        completer.complete();
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      } finally {
        if (identical(_refreshInFlight, refresh)) {
          _refreshInFlight = null;
        }
      }
    }());
    return refresh;
  }

  /// 中文：读取一次进程表并把已验证成员的当前后代加入身份集合。
  ///
  /// English: Reads one process-table snapshot and adds current descendants of
  /// identity-verified members to the tracked set.
  Future<void> _refreshNow() async {
    if (_stopped || Platform.isWindows) return;
    final records = await _readProcessTable();
    if (records.isEmpty) return;
    if (_identities.isEmpty) {
      final root = records[rootPid];
      if (root == null) return;
      _identities[rootPid] = root.identity;
    }
    final children = <int, List<_ProcessRecord>>{};
    for (final record in records.values) {
      children.putIfAbsent(record.parentPid, () => []).add(record);
    }
    final roots = _identities.entries
        .where((entry) => records[entry.key]?.identity == entry.value)
        .map((entry) => entry.key)
        .toList(growable: false);
    final visited = <int>{};
    void visit(int parentPid) {
      if (!visited.add(parentPid)) return;
      for (final child in children[parentPid] ?? const <_ProcessRecord>[]) {
        _identities.putIfAbsent(child.pid, () => child.identity);
        visit(child.pid);
      }
    }

    for (final root in roots) {
      visit(root);
    }
  }

  /// 中文：只向当前身份仍匹配的已记录进程发送信号，并优先处理叶节点。
  ///
  /// English: Signals only recorded processes whose current identities still
  /// match, processing descendants before their parents.
  Future<void> signal(ProcessSignal signal) async {
    if (Platform.isWindows) return;
    final records = await _readProcessTable();
    final living = _identities.entries
        .where((entry) => records[entry.key]?.identity == entry.value)
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final pid in living.reversed) {
      Process.killPid(pid, signal);
    }
  }

  /// 中文：持续验证已记录身份，直到所有后代退出；PID 被复用时视为原进程已退出。
  ///
  /// English: Revalidates recorded identities until every descendant exits;
  /// PID reuse is treated as the original process having exited.
  Future<void> waitForExit() async {
    if (Platform.isWindows) return;
    while (true) {
      await refresh();
      final records = await _readProcessTable();
      if (records.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        continue;
      }
      final hasLivingDescendant = _identities.entries.any(
        (entry) =>
            entry.key != rootPid && records[entry.key]?.identity == entry.value,
      );
      if (!hasLivingDescendant) return;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  /// 中文：停止定时快照并等待最后一次读取完成。
  ///
  /// English: Stops periodic snapshots and waits for the final read to finish.
  Future<void> stop() async {
    _stopped = true;
    _timer?.cancel();
    await _refreshInFlight;
  }

  /// 中文：读取 PID、父 PID 与启动时间；读取失败时返回空表以禁止未经验证的信号。
  ///
  /// English: Reads PID, parent PID, and start time; failures return an empty
  /// table so no unverified signal can be sent.
  static Future<Map<int, _ProcessRecord>> _readProcessTable() async {
    if (Platform.isMacOS) {
      return _DarwinProcessTableReader.read();
    }
    if (Platform.isLinux) {
      return _LinuxProcessTableReader.read();
    }
    try {
      final result = await Process.run('/bin/ps', const [
        '-axo',
        'pid=,ppid=,lstart=,args=',
      ]);
      if (result.exitCode != 0) return const {};
      final records = <int, _ProcessRecord>{};
      for (final line in '${result.stdout}'.split('\n')) {
        final fields = line.trim().split(RegExp(r'\s+'));
        if (fields.length < 7) continue;
        final pid = int.tryParse(fields[0]);
        final parentPid = int.tryParse(fields[1]);
        if (pid == null || parentPid == null) continue;
        records[pid] = _ProcessRecord(
          pid: pid,
          parentPid: parentPid,
          identity: fields.skip(2).join(' '),
        );
      }
      return records;
    } on Object {
      return const {};
    }
  }
}

/// Reads Darwin's kernel process table without spawning a polling subprocess.
final class _DarwinProcessTableReader {
  static const int _procPidTbsdInfo = 3;
  static final ffi.DynamicLibrary _process = ffi.DynamicLibrary.process();
  static final int Function(ffi.Pointer<ffi.Void>, int) _listAllPids = _process
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Int32),
        int Function(ffi.Pointer<ffi.Void>, int)
      >('proc_listallpids');
  static final int Function(int, int, int, ffi.Pointer<ffi.Void>, int)
  _pidInfo = _process
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Int32,
          ffi.Int32,
          ffi.Uint64,
          ffi.Pointer<ffi.Void>,
          ffi.Int32,
        ),
        int Function(int, int, int, ffi.Pointer<ffi.Void>, int)
      >('proc_pidinfo');
  static final ffi.Pointer<ffi.Void> Function(int) _malloc = _process
      .lookupFunction<
        ffi.Pointer<ffi.Void> Function(ffi.IntPtr),
        ffi.Pointer<ffi.Void> Function(int)
      >('malloc');
  static final void Function(ffi.Pointer<ffi.Void>) _free = _process
      .lookupFunction<
        ffi.Void Function(ffi.Pointer<ffi.Void>),
        void Function(ffi.Pointer<ffi.Void>)
      >('free');

  /// 中文：读取 PID、父 PID 和内核提供的微秒级启动时间。
  ///
  /// English: Reads PIDs, parent PIDs, and kernel-provided microsecond start
  /// times.
  static Map<int, _ProcessRecord> read() {
    try {
      final estimatedCount = _listAllPids(ffi.nullptr, 0);
      if (estimatedCount <= 0) return const {};
      final capacity = estimatedCount + 64;
      final byteCount = capacity * ffi.sizeOf<ffi.Int32>();
      final pidBuffer = _malloc(byteCount);
      if (pidBuffer == ffi.nullptr) return const {};
      try {
        final count = _listAllPids(pidBuffer, byteCount);
        if (count <= 0) return const {};
        final pids = pidBuffer.cast<ffi.Int32>();
        final infoBuffer = _malloc(ffi.sizeOf<_ProcBsdInfo>());
        if (infoBuffer == ffi.nullptr) return const {};
        try {
          final infoPointer = infoBuffer.cast<_ProcBsdInfo>();
          final records = <int, _ProcessRecord>{};
          final readableCount = count > capacity ? capacity : count;
          for (var index = 0; index < readableCount; index += 1) {
            final pid = pids[index];
            if (pid <= 0) continue;
            final bytesRead = _pidInfo(
              pid,
              _procPidTbsdInfo,
              0,
              infoBuffer,
              ffi.sizeOf<_ProcBsdInfo>(),
            );
            if (bytesRead != ffi.sizeOf<_ProcBsdInfo>()) continue;
            final info = infoPointer.ref;
            records[pid] = _ProcessRecord(
              pid: pid,
              parentPid: info.parentPid,
              identity: '${info.startSeconds}:${info.startMicroseconds}',
            );
          }
          return records;
        } finally {
          _free(infoBuffer);
        }
      } finally {
        _free(pidBuffer);
      }
    } on Object {
      return const {};
    }
  }
}

/// Darwin `proc_bsdinfo`, as declared by `<libproc.h>`.
final class _ProcBsdInfo extends ffi.Struct {
  @ffi.Uint32()
  external int flags;

  @ffi.Uint32()
  external int status;

  @ffi.Uint32()
  external int exitStatus;

  @ffi.Uint32()
  external int pid;

  @ffi.Uint32()
  external int parentPid;

  @ffi.Array(7)
  external ffi.Array<ffi.Uint32> credentialsAndReserved;

  @ffi.Array(16)
  external ffi.Array<ffi.Char> command;

  @ffi.Array(32)
  external ffi.Array<ffi.Char> name;

  @ffi.Array(6)
  external ffi.Array<ffi.Uint32> processGroupFields;

  @ffi.Uint64()
  external int startSeconds;

  @ffi.Uint64()
  external int startMicroseconds;
}

/// Reads Linux `/proc` identities without spawning a polling subprocess.
final class _LinuxProcessTableReader {
  /// 中文：读取 PID、父 PID 和内核启动时钟 tick，无法读取的进程会被安全跳过。
  ///
  /// English: Reads PIDs, parent PIDs, and kernel start-clock ticks, safely
  /// skipping processes that cannot be inspected.
  static Map<int, _ProcessRecord> read() {
    final records = <int, _ProcessRecord>{};
    try {
      for (final entity in Directory('/proc').listSync(followLinks: false)) {
        final pid = int.tryParse(
          entity.uri.pathSegments.where((segment) => segment.isNotEmpty).last,
        );
        if (pid == null) continue;
        try {
          final stat = File('/proc/$pid/stat').readAsStringSync();
          final commandEnd = stat.lastIndexOf(') ');
          if (commandEnd < 0) continue;
          final fields = stat.substring(commandEnd + 2).split(' ');
          if (fields.length < 20) continue;
          final parentPid = int.tryParse(fields[1]);
          final startClockTicks = int.tryParse(fields[19]);
          if (parentPid == null || startClockTicks == null) continue;
          records[pid] = _ProcessRecord(
            pid: pid,
            parentPid: parentPid,
            identity: '$startClockTicks',
          );
        } on FileSystemException {
          // The process may exit or become inaccessible while /proc is read.
        }
      }
    } on FileSystemException {
      return const {};
    }
    return records;
  }
}

final class _ProcessRecord {
  const _ProcessRecord({
    required this.pid,
    required this.parentPid,
    required this.identity,
  });

  final int pid;
  final int parentPid;
  final String identity;
}
