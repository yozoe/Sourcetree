import Cocoa
import FlutterMacOS

private let gitDesktopEngineCleanupTimeout: TimeInterval = 3.5
private let gitDesktopWorkspaceRestorationTimeout: TimeInterval = 30

/// Returns whether the native Stop Tracking command may target its key window.
/// 中文：判断原生“停止追踪”菜单能否安全作用于当前前台工作区。
func gitDesktopCanPerformStopTrackingMenuAction(
  hasKeyWorkspace: Bool,
  hasValidatedTrackedSelection: Bool
) -> Bool {
  hasKeyWorkspace && hasValidatedTrackedSelection
}

func gitDesktopCanonicalRepositoryPath(_ path: String?) -> String? {
  guard let path, !path.isEmpty else {
    return nil
  }
  return URL(fileURLWithPath: path, isDirectory: true)
    .resolvingSymlinksInPath()
    .standardizedFileURL
    .path
}

func gitDesktopWorkspaceArguments(
  repositoryPath: String?,
  initialAction: String?,
  restoresPreviouslyOpenWorkspace: Bool = false
) -> [String] {
  var arguments = ["--git-desktop-workspace"]
  if let repositoryPath {
    arguments.append("--git-desktop-repository=\(repositoryPath)")
  }
  if let initialAction, !initialAction.isEmpty {
    arguments.append("--git-desktop-action=\(initialAction)")
  }
  if restoresPreviouslyOpenWorkspace {
    arguments.append("--git-desktop-restored-workspace")
  }
  return arguments
}

final class GitDesktopWorkspaceIndex<Host: AnyObject> {
  private var hostsByPath: [String: Host] = [:]

  var allHosts: [Host] {
    Array(hostsByPath.values)
  }

  func host(for repositoryPath: String) -> Host? {
    hostsByPath[repositoryPath]
  }

  @discardableResult
  func register(_ host: Host, for repositoryPath: String) -> Host? {
    hostsByPath.updateValue(host, forKey: repositoryPath)
  }

  func remove(_ host: Host) {
    let ownedPaths = hostsByPath.compactMap { repositoryPath, candidate in
      candidate === host ? repositoryPath : nil
    }
    for repositoryPath in ownedPaths {
      hostsByPath.removeValue(forKey: repositoryPath)
    }
  }

  func removeAll() {
    hostsByPath.removeAll()
  }
}

final class GitDesktopWorkspaceHistory<Host: AnyObject> {
  private var hosts: [Host] = []

  var mostRecent: Host? {
    hosts.last
  }

  func markRecent(_ host: Host) {
    hosts.removeAll { $0 === host }
    hosts.append(host)
  }

  func remove(_ host: Host) {
    hosts.removeAll { $0 === host }
  }

  func removeAll() {
    hosts.removeAll()
  }
}

/// Tracks the application window that was most recently placed in front.
///
/// This deliberately includes the repository library and workspaces: Dock
/// reactivation should restore the user's current context, not always the
/// startup window.
final class GitDesktopWindowFocusHistory<Host: AnyObject> {
  private weak var frontmostHost: Host?

  var frontmost: Host? {
    frontmostHost
  }

  func markFrontmost(_ host: Host) {
    frontmostHost = host
  }
}

/// Captures the restorable repository workspaces and merged-strip state.
struct GitDesktopWorkspaceRestoreSnapshot {
  let paths: [String]
  let restoresMergedWorkspaces: Bool
}

struct GitDesktopWorkspaceRestorationCompletion: Equatable {
  let resolvedPaths: [String]
  let unresolvedPaths: [String]
  let shouldMerge: Bool
}

enum GitDesktopWorkspaceRestorationResolution: Equatable {
  case unrelated
  case waiting
  case finished(GitDesktopWorkspaceRestorationCompletion)
}

/// 中文：等待本次启动需要恢复的全部仓库给出成功或失败结果，再允许合并窗口。
///
/// English: Waits for every repository restored during this launch to resolve
/// successfully or unsuccessfully before allowing the windows to merge.
final class GitDesktopWorkspaceRestorationGate {
  private var orderedPaths: [String] = []
  private var pendingPaths: Set<String> = []
  private var resolvedPaths: Set<String> = []
  private var shouldMergeWhenFinished = false

  var isWaiting: Bool {
    !pendingPaths.isEmpty
  }

  /// 中文：开始跟踪一批待验证的恢复路径及其目标合并状态。
  ///
  /// English: Starts tracking a batch of restore paths and its intended merge
  /// state after verification.
  func begin(paths: [String], shouldMerge: Bool) {
    var seen: Set<String> = []
    orderedPaths = paths.filter { seen.insert($0).inserted }
    pendingPaths = Set(orderedPaths)
    resolvedPaths.removeAll()
    shouldMergeWhenFinished = shouldMerge && pendingPaths.count > 1
  }

  /// 中文：记录一个恢复路径已完成，并在最后一个路径完成时返回合并决策。
  ///
  /// English: Resolves one restored path and returns the merge decision only
  /// when the last pending path has completed.
  func resolve(_ path: String) -> GitDesktopWorkspaceRestorationResolution {
    guard pendingPaths.remove(path) != nil else {
      return .unrelated
    }
    resolvedPaths.insert(path)
    guard pendingPaths.isEmpty else {
      return .waiting
    }
    return .finished(finish())
  }

  /// 中文：结束仍在等待的恢复批次，并分别返回已完成与超时路径。
  ///
  /// English: Finishes a still-pending restore batch and returns its resolved
  /// and timed-out paths separately.
  func finishPending() -> GitDesktopWorkspaceRestorationCompletion? {
    guard !pendingPaths.isEmpty else {
      return nil
    }
    return finish()
  }

  private func finish() -> GitDesktopWorkspaceRestorationCompletion {
    let completion = GitDesktopWorkspaceRestorationCompletion(
      resolvedPaths: orderedPaths.filter { resolvedPaths.contains($0) },
      unresolvedPaths: orderedPaths.filter { pendingPaths.contains($0) },
      shouldMerge: shouldMergeWhenFinished
    )
    orderedPaths.removeAll()
    pendingPaths.removeAll()
    resolvedPaths.removeAll()
    shouldMergeWhenFinished = false
    return completion
  }
}

/// Persists only repository workspace paths that were successfully opened.
///
/// The store deliberately lives on the native side because it describes
/// window ownership, rather than Git session state. Closing one workspace
/// removes it from the next-launch restore list; application termination keeps
/// the current list intact for the next process.
final class GitDesktopWorkspaceRestoreStore {
  private static let pathsKey = "gitDesktopOpenWorkspacePaths"
  private static let mergedWorkspacesKey = "gitDesktopRestoresMergedWorkspaces"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var snapshot: GitDesktopWorkspaceRestoreSnapshot {
    guard let rawPaths = defaults.array(forKey: Self.pathsKey) as? [String]
    else {
      return GitDesktopWorkspaceRestoreSnapshot(
        paths: [],
        restoresMergedWorkspaces: false
      )
    }
    let paths = normalizedPaths(rawPaths)
    return GitDesktopWorkspaceRestoreSnapshot(
      paths: paths,
      restoresMergedWorkspaces:
        paths.count > 1 && defaults.bool(forKey: Self.mergedWorkspacesKey)
    )
  }

  var paths: [String] {
    snapshot.paths
  }

  func save(
    paths: [String],
    restoresMergedWorkspaces: Bool = false
  ) {
    let normalized = normalizedPaths(paths)
    defaults.set(normalized, forKey: Self.pathsKey)
    defaults.set(
      normalized.count > 1 && restoresMergedWorkspaces,
      forKey: Self.mergedWorkspacesKey
    )
  }

  private func normalizedPaths(_ candidates: [String]) -> [String] {
    var result: [String] = []
    var seen: Set<String> = []
    for candidate in candidates {
      guard let path = gitDesktopCanonicalRepositoryPath(candidate),
            seen.insert(path).inserted else {
        continue
      }
      result.append(path)
    }
    return result
  }
}

/// 中文：返回追加新工作区后的实时合并窗口顺序；当前不存在合并组时返回 nil。
///
/// English: Returns the live merged-window order after adding a newly opened
/// workspace, or nil when there is no existing merged group to extend.
func gitDesktopMergedWorkspaceOrderByAddingWindow(
  existingOrder: [ObjectIdentifier],
  liveWindowIdentifiers: Set<ObjectIdentifier>,
  newWindowIdentifier: ObjectIdentifier
) -> [ObjectIdentifier]? {
  let liveMergedOrder = existingOrder.filter(liveWindowIdentifiers.contains)
  guard liveMergedOrder.count > 1,
        !liveMergedOrder.contains(newWindowIdentifier) else {
    return nil
  }
  return liveMergedOrder + [newWindowIdentifier]
}

private enum GitDesktopWindowHostError: LocalizedError {
  case engineStartFailed
  case invalidRepositoryRegistration

  var errorDescription: String? {
    switch self {
    case .engineStartFailed:
      return "The Flutter engine for the repository workspace did not start."
    case .invalidRepositoryRegistration:
      return "The workspace repository could not be registered."
    }
  }
}

final class WorkspaceFlutterWindowController: NSWindowController,
  NSWindowDelegate {
  private weak var coordinator: WindowCoordinator?
  private let engine: FlutterEngine
  private let flutterViewController: FlutterViewController
  private let windowChannel: FlutterMethodChannel
  private var didShutDownEngine = false
  private var isPreparingForShutdown = false
  private var isPreparedForShutdown = false
  private var shutdownPreparationCompletions: [() -> Void] = []

  var repositoryPath: String?

  /// Flutter's last validated Stop Tracking availability for this Engine.
  ///
  /// 中文：此 Engine 最近一次由 Flutter 校验的“停止追踪”可用状态；仅供 AppKit
  /// 即时禁用菜单，真正执行前仍由 Flutter 重新读取 Git 状态。
  private(set) var canStopTrackingFromMenu = false

  init(
    repositoryPath: String?,
    initialAction: String?,
    restoresPreviouslyOpenWorkspace: Bool = false,
    coordinator: WindowCoordinator
  ) throws {
    let project = FlutterDartProject()
    project.dartEntrypointArguments = gitDesktopWorkspaceArguments(
      repositoryPath: repositoryPath,
      initialAction: initialAction,
      restoresPreviouslyOpenWorkspace: restoresPreviouslyOpenWorkspace
    )

    let engine = FlutterEngine(
      name: "git-desktop-workspace-\(UUID().uuidString)",
      project: project,
      allowHeadlessExecution: false
    )
    let flutterViewController = FlutterViewController(
      engine: engine,
      nibName: nil,
      bundle: nil
    )
    guard engine.run(withEntrypoint: nil) else {
      engine.shutDownEngine()
      throw GitDesktopWindowHostError.engineStartFailed
    }

    RegisterGeneratedPlugins(registry: flutterViewController)
    let windowChannel = FlutterMethodChannel(
      name: "com.yeknom.git_desktop/window",
      binaryMessenger: engine.binaryMessenger
    )
    let window = MainFlutterWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.configure(role: .workspace)
    window.installFlutterViewController(flutterViewController)
    window.minSize = NSSize(width: 900, height: 600)
    window.setContentSize(NSSize(width: 1280, height: 800))
    window.center()

    self.coordinator = coordinator
    self.engine = engine
    self.flutterViewController = flutterViewController
    self.windowChannel = windowChannel
    self.repositoryPath = repositoryPath
    super.init(window: window)

    window.delegate = self
    installWindowChannelHandler()
  }

  required init?(coder: NSCoder) {
    nil
  }

  deinit {
    shutDownEngine()
  }

  func showAndActivate() {
    showWindow(nil)
    (window as? MainFlutterWindow)?.bringToFront()
  }

  /// 中文：恢复启动时显示窗口但不创建延迟置前任务，让 Flutter 先完成初始化。
  ///
  /// English: Shows a restored workspace without scheduling a delayed focus
  /// retry, allowing Flutter to finish initialization before windows merge.
  func showForRestoration() {
    guard let window = window as? MainFlutterWindow else {
      return
    }
    window.cancelPendingBringToFront()
    window.orderFront(nil)
  }

  /// Delivers a native menu action to this workspace's Flutter Engine.
  func performWorkspaceAction(_ action: String) {
    windowChannel.invokeMethod("workspaceAction", arguments: ["action": action])
  }

  func requestClose() {
    prepareForShutdown { [weak self] in
      guard let self else {
        return
      }
      self.window?.performClose(nil)
    }
  }

  func prepareForApplicationTermination(completion: @escaping () -> Void) {
    prepareForShutdown(completion: completion)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if isPreparedForShutdown || didShutDownEngine {
      return true
    }
    requestClose()
    return false
  }

  func windowWillClose(_ notification: Notification) {
    coordinator?.workspaceWillClose(self)
    shutDownEngine()
  }

  private func installWindowChannelHandler() {
    windowChannel.setMethodCallHandler { [weak self] call, result in
      guard let self, let coordinator = self.coordinator else {
        result(
          FlutterError(
            code: "window_host_unavailable",
            message: "The macOS window host is unavailable.",
            details: nil
          )
        )
        return
      }
      let arguments = call.arguments as? [String: Any]
      let repositoryPath = arguments?["repositoryPath"] as? String
      switch call.method {
      case "openWorkspace":
        let initialAction = arguments?["initialAction"] as? String
        coordinator.openWorkspace(
          repositoryPath: repositoryPath,
          initialAction: initialAction
        ) { error in
          if let error {
            result(
              FlutterError(
                code: "workspace_engine_failed",
                message: error.localizedDescription,
                details: nil
              )
            )
          } else {
            result(nil)
          }
        }
      case "repositoryOpened":
        guard let canonicalPath = gitDesktopCanonicalRepositoryPath(
          repositoryPath
        ) else {
          result(
            FlutterError(
              code: "invalid_repository_registration",
              message: GitDesktopWindowHostError
                .invalidRepositoryRegistration.localizedDescription,
              details: nil
            )
          )
          return
        }
        coordinator.registerRepository(
          canonicalPath,
          for: self
        )
        result(nil)
      case "repositoryRestoreFailed":
        guard let canonicalPath = gitDesktopCanonicalRepositoryPath(
          repositoryPath
        ) else {
          result(
            FlutterError(
              code: "invalid_repository_registration",
              message: GitDesktopWindowHostError
                .invalidRepositoryRegistration.localizedDescription,
              details: nil
            )
          )
          return
        }
        coordinator.discardFailedRestoredRepository(
          canonicalPath,
          for: self
        )
        result(nil)
      case "setWorkspaceMenuState":
        canStopTrackingFromMenu = arguments?["canStopTracking"] as? Bool ?? false
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func prepareForShutdown(completion: @escaping () -> Void) {
    if isPreparedForShutdown || didShutDownEngine {
      completion()
      return
    }
    shutdownPreparationCompletions.append(completion)
    guard !isPreparingForShutdown else {
      return
    }
    isPreparingForShutdown = true

    windowChannel.invokeMethod(
      "prepareToClose",
      arguments: nil
    ) { [weak self] result in
      if let error = result as? FlutterError {
        NSLog("Workspace cleanup failed: %@", error.message ?? error.code)
      }
      self?.finishShutdownPreparation()
    }
    DispatchQueue.main.asyncAfter(
      deadline: .now() + gitDesktopEngineCleanupTimeout
    ) { [weak self] in
      self?.finishShutdownPreparation()
    }
  }

  private func finishShutdownPreparation() {
    guard !isPreparedForShutdown else {
      return
    }
    isPreparedForShutdown = true
    isPreparingForShutdown = false
    let completions = shutdownPreparationCompletions
    shutdownPreparationCompletions.removeAll()
    for completion in completions {
      completion()
    }
  }

  private func shutDownEngine() {
    guard !didShutDownEngine else {
      return
    }
    didShutDownEngine = true
    windowChannel.setMethodCallHandler(nil)
    window?.contentViewController = nil
    engine.shutDownEngine()
  }
}

final class WindowCoordinator {
  private weak var repositoryLibraryWindow: MainFlutterWindow?
  private var repositoryLibraryChannel: FlutterMethodChannel?
  private let workspaceIndex =
    GitDesktopWorkspaceIndex<WorkspaceFlutterWindowController>()
  private let workspaceHistory =
    GitDesktopWorkspaceHistory<WorkspaceFlutterWindowController>()
  private let windowFocusHistory = GitDesktopWindowFocusHistory<MainFlutterWindow>()
  private let workspaceRestoreStore: GitDesktopWorkspaceRestoreStore
  private var unregisteredWorkspaces: [
    ObjectIdentifier: WorkspaceFlutterWindowController
  ] = [:]
  private var mergedWorkspaceOrder: [ObjectIdentifier] = []
  private weak var selectedMergedWorkspaceWindow: MainFlutterWindow?
  private var isActivatingMergedWorkspace = false
  private let workspaceRestorationGate =
    GitDesktopWorkspaceRestorationGate()
  private var workspaceRestorationTimeoutWorkItem: DispatchWorkItem?
  private var didRequestWorkspaceRestoration = false
  private var isTerminating = false

  init(
    workspaceRestoreStore: GitDesktopWorkspaceRestoreStore =
      GitDesktopWorkspaceRestoreStore()
  ) {
    self.workspaceRestoreStore = workspaceRestoreStore
  }

  func attachRepositoryLibrary(
    window: MainFlutterWindow,
    flutterViewController: FlutterViewController
  ) {
    repositoryLibraryChannel?.setMethodCallHandler(nil)
    repositoryLibraryWindow = window
    window.configure(role: .repositoryLibrary)

    let channel = FlutterMethodChannel(
      name: "com.yeknom.git_desktop/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    window.directoryDragStateHandler = { isActive in
      channel.invokeMethod(
        "repositoryDirectoryDragState",
        arguments: ["isActive": isActive]
      )
    }
    window.directoriesDroppedHandler = { paths in
      channel.invokeMethod(
        "repositoryDirectoriesDropped",
        arguments: ["paths": paths]
      )
    }
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(
          FlutterError(
            code: "window_host_unavailable",
            message: "The macOS window host is unavailable.",
            details: nil
          )
        )
        return
      }
      let arguments = call.arguments as? [String: Any]
      switch call.method {
      case "openWorkspace":
        self.openWorkspace(
          repositoryPath: arguments?["repositoryPath"] as? String,
          initialAction: arguments?["initialAction"] as? String
        ) { error in
          if let error {
            result(
              FlutterError(
                code: "workspace_engine_failed",
                message: error.localizedDescription,
                details: nil
              )
            )
          } else {
            result(nil)
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    repositoryLibraryChannel = channel
    restoreOpenWorkspacesAfterLaunch()
  }

  func openWorkspace(
    repositoryPath: String?,
    initialAction: String?,
    restoresPreviouslyOpenWorkspace: Bool = false,
    completion: @escaping (Error?) -> Void
  ) {
    let canonicalPath = gitDesktopCanonicalRepositoryPath(repositoryPath)
    if let canonicalPath,
       let existing = workspaceIndex.host(for: canonicalPath) {
      workspaceHistory.markRecent(existing)
      if restoresPreviouslyOpenWorkspace {
        existing.showForRestoration()
      } else {
        existing.showAndActivate()
      }
      completion(nil)
      return
    }

    do {
      let controller = try WorkspaceFlutterWindowController(
        repositoryPath: canonicalPath,
        initialAction: initialAction,
        restoresPreviouslyOpenWorkspace: restoresPreviouslyOpenWorkspace,
        coordinator: self
      )
      if let canonicalPath {
        workspaceIndex.register(controller, for: canonicalPath)
      } else {
        unregisteredWorkspaces[ObjectIdentifier(controller)] = controller
      }
      workspaceHistory.markRecent(controller)
      if restoresPreviouslyOpenWorkspace {
        controller.showForRestoration()
      } else {
        controller.showAndActivate()
      }
      completion(nil)
    } catch {
      completion(error)
    }
  }

  /// Sends a menu action only to the workspace that currently owns keyboard
  /// focus. A repository-library window must never mutate a background repo.
  func performWorkspaceAction(_ action: String) {
    currentWorkspaceController?.performWorkspaceAction(action)
  }

  /// Whether the native Action menu can safely address the key workspace.
  var canPerformWorkspaceAction: Bool {
    currentWorkspaceController != nil
  }

  /// Whether the key workspace has a Flutter-validated tracked file selected.
  /// 中文：当前前台工作区是否已由 Flutter 校验出可停止追踪的已跟踪文件。
  var canStopTrackingFromMenu: Bool {
    gitDesktopCanPerformStopTrackingMenuAction(
      hasKeyWorkspace: currentWorkspaceController != nil,
      hasValidatedTrackedSelection:
        currentWorkspaceController?.canStopTrackingFromMenu == true
    )
  }

  private var currentWorkspaceController: WorkspaceFlutterWindowController? {
    guard let keyWindow = NSApp.keyWindow as? MainFlutterWindow,
          keyWindow.role == .workspace else {
      return nil
    }
    return workspaceControllers().first { $0.window === keyWindow }
  }

  func registerRepository(
    _ repositoryPath: String,
    for controller: WorkspaceFlutterWindowController
  ) {
    if let existing = workspaceIndex.host(for: repositoryPath),
       existing !== controller {
      workspaceHistory.markRecent(existing)
      existing.showAndActivate()
      notifyRepositoryLibrary(repositoryPath: repositoryPath)
      // Let the reporting MethodChannel reply before shutting down its Engine.
      DispatchQueue.main.async {
        controller.requestClose()
      }
      return
    }

    workspaceIndex.remove(controller)
    unregisteredWorkspaces.removeValue(forKey: ObjectIdentifier(controller))
    controller.repositoryPath = repositoryPath
    controller.window?.title = "\(URL(fileURLWithPath: repositoryPath).lastPathComponent) (Git)"
    if let window = controller.window as? MainFlutterWindow,
       mergedWorkspaceOrder.contains(ObjectIdentifier(window)) {
      refreshMergedWorkspaceTabStrips()
    }
    workspaceIndex.register(controller, for: repositoryPath)
    mergeNewWorkspaceIntoExistingMergedGroupIfNeeded(controller)
    if !resolveRestoredRepository(repositoryPath) {
      persistOpenWorkspaces()
    }
    notifyRepositoryLibrary(repositoryPath: repositoryPath)
  }

  /// Removes a restored path that Flutter could no longer verify as a Git
  /// repository, then closes only the failed workspace that reported it.
  func discardFailedRestoredRepository(
    _ repositoryPath: String,
    for controller: WorkspaceFlutterWindowController
  ) {
    guard workspaceIndex.host(for: repositoryPath) === controller else {
      return
    }
    workspaceIndex.remove(controller)
    workspaceHistory.remove(controller)
    if !resolveRestoredRepository(repositoryPath) {
      persistOpenWorkspaces()
    }
    DispatchQueue.main.async {
      controller.requestClose()
    }
  }

  /// 中文：把全部工作区收拢到一个可见窗口位置，并以自绘标签切换。
  ///
  /// English: Collects all workspaces into one visible window position and
  /// switches them through the custom strip. Every workspace remains a real
  /// NSWindow with its own Flutter Engine and close lifecycle.
  func mergeAllWorkspaceWindows() {
    mergeWorkspaceWindows(workspaceControllers())
  }

  /// 中文：只把指定工作区收拢为自绘标签组，不改变批次外的独立窗口。
  ///
  /// English: Collects only the specified workspaces into the custom strip,
  /// leaving windows outside that batch independent.
  private func mergeWorkspaceWindows(
    _ controllers: [WorkspaceFlutterWindowController]
  ) {
    guard controllers.count > 1 else {
      return
    }
    let windows = controllers.compactMap { $0.window as? MainFlutterWindow }
    guard windows.count > 1,
          let primary = activeWorkspaceWindow(from: controllers),
          windows.contains(where: { $0 === primary }) else {
      return
    }
    let windowIdentifiers = Set(windows.map(ObjectIdentifier.init))
    for previousWindow in mergedWorkspaceWindows
    where !windowIdentifiers.contains(ObjectIdentifier(previousWindow)) {
      previousWindow.removeWorkspaceTabStrip()
      if !previousWindow.isVisible {
        previousWindow.orderFront(nil)
      }
    }
    mergedWorkspaceOrder = windows.map(ObjectIdentifier.init)
    selectedMergedWorkspaceWindow = primary
    let sharedFrame = primary.frame
    windows.forEach { $0.cancelPendingBringToFront() }
    for window in windows where window !== primary {
      window.setFrame(sharedFrame, display: false)
      window.orderOut(nil)
    }
    refreshMergedWorkspaceTabStrips()
    primary.bringToFrontImmediately()
    persistOpenWorkspaces()
  }

  /// Returns whether at least two live workspaces still need to be merged.
  var canMergeAllWorkspaceWindows: Bool {
    let controllers = workspaceControllers()
    let windows = controllers.compactMap(\.window)
    guard windows.count > 1 else {
      return false
    }
    let mergedIdentifiers = Set(mergedWorkspaceOrder)
    return windows.contains { !mergedIdentifiers.contains(ObjectIdentifier($0)) }
  }

  func workspaceWillClose(_ controller: WorkspaceFlutterWindowController) {
    let closingWindow = controller.window as? MainFlutterWindow
    closingWindow?.cancelPendingBringToFront()
    let closingFrame = closingWindow?.frame
    let closingIdentifier = closingWindow.map(ObjectIdentifier.init)
    let closingIndex = closingIdentifier.flatMap {
      mergedWorkspaceOrder.firstIndex(of: $0)
    }
    let wasSelected = closingWindow === selectedMergedWorkspaceWindow
    if let closingIdentifier {
      mergedWorkspaceOrder.removeAll { $0 == closingIdentifier }
    }
    workspaceIndex.remove(controller)
    unregisteredWorkspaces.removeValue(forKey: ObjectIdentifier(controller))
    workspaceHistory.remove(controller)
    guard !isTerminating else {
      return
    }
    let remainingMergedWindows = mergedWorkspaceWindows
    if remainingMergedWindows.count < 2 {
      remainingMergedWindows.forEach { $0.removeWorkspaceTabStrip() }
      mergedWorkspaceOrder.removeAll()
      selectedMergedWorkspaceWindow = nil
      if wasSelected, let remainingWindow = remainingMergedWindows.first {
        if let closingFrame {
          remainingWindow.setFrame(closingFrame, display: false)
        }
        DispatchQueue.main.async {
          remainingWindow.bringToFrontImmediately()
        }
      }
    } else if wasSelected {
      let nextIndex = min(closingIndex ?? 0, remainingMergedWindows.count - 1)
      let nextWindow = remainingMergedWindows[nextIndex]
      if let closingFrame {
        nextWindow.setFrame(closingFrame, display: false)
      }
      selectedMergedWorkspaceWindow = nextWindow
      DispatchQueue.main.async { [weak self, weak nextWindow] in
        guard let self, let nextWindow else {
          return
        }
        self.activateMergedWorkspace(nextWindow)
      }
    } else {
      refreshMergedWorkspaceTabStrips()
    }
    if let repositoryPath = controller.repositoryPath,
       resolveRestoredRepository(repositoryPath) {
      return
    }
    persistOpenWorkspaces()
  }

  /// Prevents normal window teardown during app termination from clearing the
  /// workspace list that must be restored by the next process.
  func beginApplicationTermination() {
    isTerminating = true
    workspaceRestorationTimeoutWorkItem?.cancel()
    workspaceRestorationTimeoutWorkItem = nil
  }

  /// Collects every live workspace once, including workspaces not yet bound to
  /// a repository path.
  private func workspaceControllers() -> [WorkspaceFlutterWindowController] {
    let candidates = workspaceIndex.allHosts
      + Array(unregisteredWorkspaces.values)
    var controllers: [WorkspaceFlutterWindowController] = []
    var seen: Set<ObjectIdentifier> = []
    for controller in candidates {
      if seen.insert(ObjectIdentifier(controller)).inserted {
        controllers.append(controller)
      }
    }
    return controllers
  }

  /// 中文：按标签显示顺序解析仍存活的合并工作区窗口。
  ///
  /// English: Resolves the live merged workspace windows in visible tab order.
  private var mergedWorkspaceWindows: [MainFlutterWindow] {
    let liveWindows = workspaceControllers().compactMap {
      $0.window as? MainFlutterWindow
    }
    let windowByIdentifier = Dictionary(
      uniqueKeysWithValues: liveWindows.map { (ObjectIdentifier($0), $0) }
    )
    return mergedWorkspaceOrder.compactMap { windowByIdentifier[$0] }
  }

  /// 中文：若已有合并标签组，将刚完成仓库验证的新窗口追加到该组。
  ///
  /// English: Appends a newly verified workspace to an existing merged group,
  /// while leaving unrelated standalone workspaces independent.
  private func mergeNewWorkspaceIntoExistingMergedGroupIfNeeded(
    _ controller: WorkspaceFlutterWindowController
  ) {
    guard let newWindow = controller.window as? MainFlutterWindow else {
      return
    }
    let controllers = workspaceControllers()
    let controllerByWindowIdentifier = Dictionary(
      uniqueKeysWithValues: controllers.compactMap { candidate in
        (candidate.window as? MainFlutterWindow).map {
          (ObjectIdentifier($0), candidate)
        }
      }
    )
    guard let mergedOrder = gitDesktopMergedWorkspaceOrderByAddingWindow(
      existingOrder: mergedWorkspaceOrder,
      liveWindowIdentifiers: Set(controllerByWindowIdentifier.keys),
      newWindowIdentifier: ObjectIdentifier(newWindow)
    ) else {
      return
    }
    let mergedControllers = mergedOrder.compactMap {
      controllerByWindowIdentifier[$0]
    }
    guard mergedControllers.count == mergedOrder.count else {
      return
    }
    mergeWorkspaceWindows(mergedControllers)
  }

  /// Selects the current workspace as tab host, falling back to the most
  /// recently used live workspace.
  private func activeWorkspaceWindow(
    from controllers: [WorkspaceFlutterWindowController]
  ) -> MainFlutterWindow? {
    if let keyWindow = NSApp.keyWindow as? MainFlutterWindow,
       keyWindow.role == .workspace,
       controllers.contains(where: { $0.window === keyWindow }) {
      return keyWindow
    }
    if let mostRecent = workspaceHistory.mostRecent?.window as? MainFlutterWindow,
       controllers.contains(where: { $0.window === mostRecent }) {
      return mostRecent
    }
    return controllers.first?.window as? MainFlutterWindow
  }

  func windowDidBecomeKey(_ window: MainFlutterWindow) {
    windowFocusHistory.markFrontmost(window)
    guard window.role == .workspace else {
      return
    }
    if mergedWorkspaceOrder.contains(ObjectIdentifier(window)),
       selectedMergedWorkspaceWindow !== window,
       !isActivatingMergedWorkspace {
      activateMergedWorkspace(window)
    }
    let candidates = workspaceIndex.allHosts
      + Array(unregisteredWorkspaces.values)
    if let controller = candidates.first(where: { $0.window === window }) {
      workspaceHistory.markRecent(controller)
    }
  }

  /// 中文：在自定义合并组中循环选择相邻工作区。
  ///
  /// English: Selects the adjacent workspace in the custom merged set,
  /// wrapping at both ends to preserve native tab keyboard expectations.
  func selectAdjacentMergedWorkspace(
    from window: MainFlutterWindow,
    offset: Int
  ) -> Bool {
    let windows = mergedWorkspaceWindows
    guard windows.count > 1,
          let currentIndex = windows.firstIndex(where: { $0 === window }) else {
      return false
    }
    let targetIndex = (currentIndex + offset + windows.count) % windows.count
    activateMergedWorkspace(windows[targetIndex])
    return true
  }

  /// 中文：把一个工作区移动到合并标签组的新索引，并立即保存恢复顺序。
  ///
  /// English: Moves a workspace to a new merged-tab index and immediately
  /// persists the resulting restoration order.
  func moveMergedWorkspace(
    _ window: MainFlutterWindow,
    to destinationIndex: Int
  ) {
    let windowIdentifier = ObjectIdentifier(window)
    guard let sourceIndex = mergedWorkspaceOrder.firstIndex(
      of: windowIdentifier
    ),
      mergedWorkspaceOrder.indices.contains(destinationIndex),
      sourceIndex != destinationIndex else {
      return
    }
    mergedWorkspaceOrder = gitDesktopMovingItem(
      in: mergedWorkspaceOrder,
      from: sourceIndex,
      to: destinationIndex
    )
    refreshMergedWorkspaceTabStrips()
    persistOpenWorkspaces()
  }

  /// 中文：激活合并组中的一个工作区，并复用当前可见窗口的位置与尺寸。
  ///
  /// English: Activates one workspace in the merged set while reusing the
  /// currently visible window's frame.
  private func activateMergedWorkspace(_ window: MainFlutterWindow) {
    guard mergedWorkspaceOrder.contains(ObjectIdentifier(window)) else {
      window.bringToFront()
      return
    }
    guard !isActivatingMergedWorkspace else {
      return
    }
    isActivatingMergedWorkspace = true
    let previousWindow = selectedMergedWorkspaceWindow
    let sharedFrame = previousWindow?.frame ?? window.frame
    if previousWindow !== window {
      previousWindow?.cancelPendingBringToFront()
      previousWindow?.orderOut(nil)
      window.setFrame(sharedFrame, display: false)
    }
    selectedMergedWorkspaceWindow = window
    refreshMergedWorkspaceTabStrips()
    window.bringToFrontImmediately()
    isActivatingMergedWorkspace = false
  }

  /// 中文：刷新合并组所有窗口顶部的单行矩形标签条。
  ///
  /// English: Refreshes the single rectangular strip hosted by every workspace
  /// in the custom merged set.
  private func refreshMergedWorkspaceTabStrips() {
    let windows = mergedWorkspaceWindows
    guard windows.count > 1,
          let selectedWindow = selectedMergedWorkspaceWindow,
          windows.contains(where: { $0 === selectedWindow }) else {
      windows.forEach { $0.removeWorkspaceTabStrip() }
      return
    }
    windows.forEach { candidate in
      candidate.configureWorkspaceTabStrip(
        windows: windows,
        selectedWindow: selectedWindow,
        selectionHandler: { [weak self] requestedWindow in
          self?.activateMergedWorkspace(requestedWindow)
        },
        reorderHandler: { [weak self] movedWindow, destinationIndex in
          self?.moveMergedWorkspace(movedWindow, to: destinationIndex)
        }
      )
    }
  }

  func toggleRepositoryWindow(from sourceWindow: MainFlutterWindow?) {
    if sourceWindow?.role == .workspace {
      showRepositoryLibrary()
      return
    }
    guard let lastWorkspace = workspaceHistory.mostRecent,
          lastWorkspace.window != nil else {
      NSSound.beep()
      return
    }
    lastWorkspace.showAndActivate()
  }

  func showRepositoryLibrary() {
    guard let repositoryLibraryWindow else {
      NSSound.beep()
      return
    }
    repositoryLibraryWindow.bringToFront()
  }

  /// Restores the window that was last key before the app was hidden.
  ///
  /// Falls back to the workspace MRU list when that window has been closed,
  /// then to the repository library when no workspace remains.
  func restoreMostRecentlyActiveWindow() {
    if let frontmostWindow = windowFocusHistory.frontmost {
      frontmostWindow.bringToFront()
      return
    }
    if let lastWorkspace = workspaceHistory.mostRecent,
       lastWorkspace.window != nil {
      lastWorkspace.showAndActivate()
      return
    }
    showRepositoryLibrary()
  }

  func prepareForApplicationTermination(completion: @escaping () -> Void) {
    let registered = workspaceIndex.allHosts
    let unregistered = Array(unregisteredWorkspaces.values)
    var controllers: [WorkspaceFlutterWindowController] = []
    var seen: Set<ObjectIdentifier> = []
    for controller in registered + unregistered {
      if seen.insert(ObjectIdentifier(controller)).inserted {
        controllers.append(controller)
      }
    }

    let group = DispatchGroup()
    for controller in controllers {
      group.enter()
      controller.prepareForApplicationTermination {
        group.leave()
      }
    }
    if let repositoryLibraryChannel {
      group.enter()
      prepareRepositoryLibrary(
        channel: repositoryLibraryChannel,
        completion: group.leave
      )
    }
    group.notify(queue: .main, execute: completion)
  }

  func shutDownWorkspaces() {
    guard !isTerminating else {
      return
    }
    isTerminating = true
    let registered = workspaceIndex.allHosts
    let unregistered = Array(unregisteredWorkspaces.values)
    var seen: Set<ObjectIdentifier> = []
    for controller in registered + unregistered {
      let identifier = ObjectIdentifier(controller)
      if seen.insert(identifier).inserted {
        controller.close()
      }
    }
    workspaceIndex.removeAll()
    unregisteredWorkspaces.removeAll()
    workspaceHistory.removeAll()
    mergedWorkspaceOrder.removeAll()
    selectedMergedWorkspaceWindow = nil
    repositoryLibraryChannel?.setMethodCallHandler(nil)
  }

  /// Reopens the workspaces that were still open at the previous app exit.
  ///
  /// This runs only after the repository-library Flutter Engine is attached,
  /// so restored workspaces can report their verified repository state back to
  /// the library through the existing channel. Paths that no longer name a
  /// readable directory are pruned before any window is created.
  private func restoreOpenWorkspacesAfterLaunch() {
    guard !didRequestWorkspaceRestoration else {
      return
    }
    didRequestWorkspaceRestoration = true
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.isTerminating else {
        return
      }
      let savedSnapshot = self.workspaceRestoreStore.snapshot
      let restorablePaths = savedSnapshot.paths.filter {
        self.isReadableDirectory(at: $0)
      }
      let restoresMergedWorkspaces =
        savedSnapshot.restoresMergedWorkspaces && restorablePaths.count > 1
      self.workspaceRestoreStore.save(
        paths: restorablePaths,
        restoresMergedWorkspaces: restoresMergedWorkspaces
      )
      self.workspaceRestorationGate.begin(
        paths: restorablePaths,
        shouldMerge: restoresMergedWorkspaces
      )
      self.scheduleWorkspaceRestorationTimeout()
      for repositoryPath in restorablePaths {
        self.openWorkspace(
          repositoryPath: repositoryPath,
          initialAction: nil,
          restoresPreviouslyOpenWorkspace: true
        ) { [weak self] error in
          guard error != nil else {
            return
          }
          _ = self?.resolveRestoredRepository(repositoryPath)
        }
      }
    }
  }

  /// 中文：完成一个恢复仓库的验证；全部完成后才合并并持久化最终窗口状态。
  ///
  /// English: Completes verification for one restored repository, merging and
  /// persisting the final window state only after the entire batch resolves.
  @discardableResult
  private func resolveRestoredRepository(_ repositoryPath: String) -> Bool {
    switch workspaceRestorationGate.resolve(repositoryPath) {
    case .unrelated:
      return false
    case .waiting:
      return true
    case let .finished(completion):
      finishWorkspaceRestoration(completion)
      return true
    }
  }

  /// 中文：为恢复批次安排有界等待，避免卡住的 Git 读取永久阻塞窗口状态。
  ///
  /// English: Bounds the restore batch so a stalled Git read cannot block
  /// window-state persistence indefinitely.
  private func scheduleWorkspaceRestorationTimeout() {
    workspaceRestorationTimeoutWorkItem?.cancel()
    workspaceRestorationTimeoutWorkItem = nil
    guard workspaceRestorationGate.isWaiting else {
      return
    }
    let workItem = DispatchWorkItem { [weak self] in
      guard let self, !self.isTerminating,
            let completion = self.workspaceRestorationGate.finishPending()
      else {
        return
      }
      self.finishWorkspaceRestoration(completion)
    }
    workspaceRestorationTimeoutWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + gitDesktopWorkspaceRestorationTimeout,
      execute: workItem
    )
  }

  /// 中文：完成恢复批次，只合并已验证成员，并关闭超时成员。
  ///
  /// English: Finishes a restore batch by merging only verified members and
  /// closing members that timed out.
  private func finishWorkspaceRestoration(
    _ completion: GitDesktopWorkspaceRestorationCompletion
  ) {
    workspaceRestorationTimeoutWorkItem?.cancel()
    workspaceRestorationTimeoutWorkItem = nil

    for repositoryPath in completion.unresolvedPaths {
      guard let controller = workspaceIndex.host(for: repositoryPath) else {
        continue
      }
      workspaceIndex.remove(controller)
      workspaceHistory.remove(controller)
      (controller.window as? MainFlutterWindow)?.orderOut(nil)
      DispatchQueue.main.async {
        controller.requestClose()
      }
    }

    let restoredControllers = completion.resolvedPaths.compactMap {
      workspaceIndex.host(for: $0)
    }
    if completion.shouldMerge, restoredControllers.count > 1 {
      mergeWorkspaceWindows(restoredControllers)
    } else {
      persistOpenWorkspaces()
    }
  }

  /// Returns whether [path] still points at a directory the process can read.
  private func isReadableDirectory(at path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(
      atPath: path,
      isDirectory: &isDirectory
    ) && isDirectory.boolValue && FileManager.default.isReadableFile(atPath: path)
  }

  /// Saves the live, registered workspaces in their existing restore order.
  /// Empty/new workspaces are intentionally excluded until Flutter confirms a
  /// repository has opened through `repositoryOpened`.
  private func persistOpenWorkspaces() {
    guard !workspaceRestorationGate.isWaiting else {
      return
    }
    let controllers = workspaceIndex.allHosts
    let controllerByWindowIdentifier = Dictionary(
      uniqueKeysWithValues: controllers.compactMap { controller in
        controller.window.map {
          (ObjectIdentifier($0), controller)
        }
      }
    )
    let mergedControllers = mergedWorkspaceOrder.compactMap {
      controllerByWindowIdentifier[$0]
    }
    let mergedControllerIdentifiers = Set(
      mergedControllers.map(ObjectIdentifier.init)
    )
    let controllersInRestoreOrder = mergedControllers + controllers.filter {
      !mergedControllerIdentifiers.contains(ObjectIdentifier($0))
    }
    workspaceRestoreStore.save(
      paths: controllersInRestoreOrder.compactMap(\.repositoryPath),
      restoresMergedWorkspaces: areAllWorkspaceWindowsMerged
    )
  }

  /// Whether every restorable repository workspace belongs to one merged strip.
  private var areAllWorkspaceWindowsMerged: Bool {
    // Empty workspaces are intentionally not persisted, so they must not make
    // a persisted group of repository workspaces look unmerged.
    let windows = workspaceIndex.allHosts.compactMap(\.window)
    guard windows.count > 1 else {
      return false
    }
    let mergedIdentifiers = Set(mergedWorkspaceOrder)
    return windows.allSatisfy {
      mergedIdentifiers.contains(ObjectIdentifier($0))
    }
  }

  private func prepareRepositoryLibrary(
    channel: FlutterMethodChannel,
    completion: @escaping () -> Void
  ) {
    var didComplete = false
    let finish = {
      guard !didComplete else {
        return
      }
      didComplete = true
      completion()
    }
    channel.invokeMethod("prepareToClose", arguments: nil) { result in
      if let error = result as? FlutterError {
        NSLog("Repository library cleanup failed: %@", error.message ?? error.code)
      }
      finish()
    }
    DispatchQueue.main.asyncAfter(
      deadline: .now() + gitDesktopEngineCleanupTimeout,
      execute: finish
    )
  }

  private func notifyRepositoryLibrary(repositoryPath: String) {
    repositoryLibraryChannel?.invokeMethod(
      "repositoryOpened",
      arguments: ["repositoryPath": repositoryPath]
    )
  }
}

@main
class AppDelegate: FlutterAppDelegate {
  let windowCoordinator = WindowCoordinator()
  private var shortcutEventMonitor: Any?
  private var isTerminationPreparationRunning = false
  private var isTerminationPrepared = false

  override init() {
    super.init()
    NSApp.setActivationPolicy(.regular)
    shortcutEventMonitor = NSEvent.addLocalMonitorForEvents(
      matching: .keyDown
    ) { [weak self] event in
      guard let self else {
        return event
      }
      return self.handleShortcut(event) ? nil : event
    }
  }

  deinit {
    if let shortcutEventMonitor {
      NSEvent.removeMonitor(shortcutEventMonitor)
    }
  }

  func attachRepositoryLibrary(
    window: MainFlutterWindow,
    flutterViewController: FlutterViewController
  ) {
    windowCoordinator.attachRepositoryLibrary(
      window: window,
      flutterViewController: flutterViewController
    )
  }

  func windowDidBecomeKey(_ window: MainFlutterWindow) {
    windowCoordinator.windowDidBecomeKey(window)
  }

  func selectAdjacentMergedWorkspace(
    from window: MainFlutterWindow,
    offset: Int
  ) -> Bool {
    windowCoordinator.selectAdjacentMergedWorkspace(
      from: window,
      offset: offset
    )
  }

  func handleShortcut(_ event: NSEvent) -> Bool {
    let sourceWindow = NSApp.keyWindow as? MainFlutterWindow
    if gitDesktopIsRepositoryWindowToggle(event) {
      windowCoordinator.toggleRepositoryWindow(from: sourceWindow)
      return true
    }
    if sourceWindow?.role == .workspace,
       gitDesktopIsRepositoryLibraryShortcut(event) {
      windowCoordinator.showRepositoryLibrary()
      return true
    }
    return false
  }

  /// 中文：将全部仓库工作区收拢为单行矩形标签组。
  ///
  /// English: Collects all live repository workspaces into one rectangular
  /// strip without sharing their Flutter Engine lifecycles.
  @IBAction func mergeAllRepositoryWindows(_ sender: Any?) {
    windowCoordinator.mergeAllWorkspaceWindows()
  }

  @IBAction func createPatchFromMenu(_ sender: Any?) {
    windowCoordinator.performWorkspaceAction("createPatch")
  }

  @IBAction func applyPatchFromMenu(_ sender: Any?) {
    windowCoordinator.performWorkspaceAction("applyPatch")
  }

  @IBAction func repositoryDetailsFromMenu(_ sender: Any?) {
    windowCoordinator.performWorkspaceAction("repositoryDetails")
  }

  @IBAction func repositoryFeaturePendingFromMenu(_ sender: Any?) {
    windowCoordinator.performWorkspaceAction("repositoryFeaturePending")
  }

  /// 中文：将原生“停止追踪”动作投递到当前 key workspace 的 Flutter Engine。
  /// English: Delivers the native Stop Tracking action to the current key
  /// workspace's Flutter Engine.
  @IBAction func stopTrackingFromMenu(_ sender: Any?) {
    windowCoordinator.performWorkspaceAction("stopTracking")
  }

  /// 中文：在当前应用窗口中显示尚未交付的窗口菜单提示，不依赖仓库工作区。
  ///
  /// English: Shows a pending window-menu notice in the current app window
  /// without requiring a repository workspace.
  @IBAction func windowFeaturePendingFromMenu(_ sender: Any?) {
    guard let keyWindow = NSApp.keyWindow,
          gitDesktopCanPerformWindowMenuAction(keyWindow) else {
      NSSound.beep()
      return
    }
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "待实现"
    alert.informativeText = "该窗口菜单功能待实现。"
    alert.addButton(withTitle: "好")
    alert.beginSheetModal(for: keyWindow)
  }

  @IBAction func showRepositoryLibraryFromMenu(_ sender: Any?) {
    windowCoordinator.showRepositoryLibrary()
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(mergeAllRepositoryWindows(_:)) {
      return windowCoordinator.canMergeAllWorkspaceWindows
    }
    if menuItem.action == #selector(windowFeaturePendingFromMenu(_:)) {
      return gitDesktopCanPerformWindowMenuAction(NSApp.keyWindow)
    }
    if menuItem.action == #selector(createPatchFromMenu(_:)) ||
       menuItem.action == #selector(applyPatchFromMenu(_:)) ||
       menuItem.action == #selector(repositoryDetailsFromMenu(_:)) ||
       menuItem.action == #selector(repositoryFeaturePendingFromMenu(_:)) {
      return windowCoordinator.canPerformWorkspaceAction
    }
    if menuItem.action == #selector(stopTrackingFromMenu(_:)) {
      return windowCoordinator.canStopTrackingFromMenu
    }
    return true
  }

  override func applicationWillTerminate(_ notification: Notification) {
    windowCoordinator.shutDownWorkspaces()
    super.applicationWillTerminate(notification)
  }

  override func applicationShouldTerminate(
    _ sender: NSApplication
  ) -> NSApplication.TerminateReply {
    if isTerminationPrepared {
      return .terminateNow
    }
    if !isTerminationPreparationRunning {
      isTerminationPreparationRunning = true
      windowCoordinator.beginApplicationTermination()
      windowCoordinator.prepareForApplicationTermination { [weak self] in
        guard let self else {
          sender.reply(toApplicationShouldTerminate: true)
          return
        }
        self.isTerminationPrepared = true
        self.isTerminationPreparationRunning = false
        sender.reply(toApplicationShouldTerminate: true)
      }
    }
    return .terminateLater
  }

  override func applicationShouldTerminateAfterLastWindowClosed(
    _ sender: NSApplication
  ) -> Bool {
    false
  }

  override func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    windowCoordinator.restoreMostRecentlyActiveWindow()
    return true
  }

  override func applicationSupportsSecureRestorableState(
    _ app: NSApplication
  ) -> Bool {
    true
  }
}
