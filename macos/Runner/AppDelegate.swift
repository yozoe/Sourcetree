import Cocoa
import FlutterMacOS

private let gitDesktopEngineCleanupTimeout: TimeInterval = 3.5

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
  initialAction: String?
) -> [String] {
  var arguments = ["--git-desktop-workspace"]
  if let repositoryPath {
    arguments.append("--git-desktop-repository=\(repositoryPath)")
  }
  if let initialAction, !initialAction.isEmpty {
    arguments.append("--git-desktop-action=\(initialAction)")
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

  init(
    repositoryPath: String?,
    initialAction: String?,
    coordinator: WindowCoordinator
  ) throws {
    let project = FlutterDartProject()
    project.dartEntrypointArguments = gitDesktopWorkspaceArguments(
      repositoryPath: repositoryPath,
      initialAction: initialAction
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
  private var unregisteredWorkspaces: [
    ObjectIdentifier: WorkspaceFlutterWindowController
  ] = [:]
  private var isTerminating = false

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
  }

  func openWorkspace(
    repositoryPath: String?,
    initialAction: String?,
    completion: @escaping (Error?) -> Void
  ) {
    let canonicalPath = gitDesktopCanonicalRepositoryPath(repositoryPath)
    if let canonicalPath,
       let existing = workspaceIndex.host(for: canonicalPath) {
      workspaceHistory.markRecent(existing)
      existing.showAndActivate()
      completion(nil)
      return
    }

    do {
      let controller = try WorkspaceFlutterWindowController(
        repositoryPath: canonicalPath,
        initialAction: initialAction,
        coordinator: self
      )
      if let canonicalPath {
        workspaceIndex.register(controller, for: canonicalPath)
      } else {
        unregisteredWorkspaces[ObjectIdentifier(controller)] = controller
      }
      workspaceHistory.markRecent(controller)
      controller.showAndActivate()
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
    workspaceIndex.register(controller, for: repositoryPath)
    notifyRepositoryLibrary(repositoryPath: repositoryPath)
  }

  /// Merges all live repository workspaces into the current native tab group.
  /// Each tab retains its own Flutter Engine and close lifecycle.
  func mergeAllWorkspaceWindows() {
    let controllers = workspaceControllers()
    guard controllers.count > 1,
          let primary = activeWorkspaceWindow(from: controllers) else {
      return
    }
    for controller in controllers {
      guard let candidate = controller.window, candidate !== primary else {
        continue
      }
      let existingTabs = primary.tabbedWindows ?? [primary]
      if !existingTabs.contains(where: { $0 === candidate }) {
        primary.tabbingMode = .preferred
        candidate.tabbingMode = .preferred
        primary.addTabbedWindow(candidate, ordered: .above)
      }
    }
    primary.bringToFront()
  }

  /// Returns whether at least two live workspaces still need to be merged.
  var canMergeAllWorkspaceWindows: Bool {
    let controllers = workspaceControllers()
    let windows = controllers.compactMap(\.window)
    guard windows.count > 1,
          let primary = activeWorkspaceWindow(from: controllers) else {
      return false
    }
    let primaryTabs = primary.tabbedWindows ?? [primary]
    return windows.contains { candidate in
      !primaryTabs.contains(where: { $0 === candidate })
    }
  }

  func workspaceWillClose(_ controller: WorkspaceFlutterWindowController) {
    workspaceIndex.remove(controller)
    unregisteredWorkspaces.removeValue(forKey: ObjectIdentifier(controller))
    workspaceHistory.remove(controller)
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
    let candidates = workspaceIndex.allHosts
      + Array(unregisteredWorkspaces.values)
    if let controller = candidates.first(where: { $0.window === window }) {
      workspaceHistory.markRecent(controller)
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
    repositoryLibraryChannel?.setMethodCallHandler(nil)
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

  /// 中文：将全部仓库工作区合并为当前原生窗口的标签页。
  ///
  /// English: Merges all live repository workspaces into one native macOS tab
  /// group without sharing their Flutter Engine lifecycles.
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

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(mergeAllRepositoryWindows(_:)) {
      return windowCoordinator.canMergeAllWorkspaceWindows
    }
    if menuItem.action == #selector(createPatchFromMenu(_:)) ||
       menuItem.action == #selector(applyPatchFromMenu(_:)) ||
       menuItem.action == #selector(repositoryDetailsFromMenu(_:)) ||
       menuItem.action == #selector(repositoryFeaturePendingFromMenu(_:)) {
      return windowCoordinator.canPerformWorkspaceAction
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
