import Cocoa
import FlutterMacOS
import QuickLookUI

@main
class AppDelegate: FlutterAppDelegate, NSMenuDelegate {
  let windowCoordinator = WindowCoordinator()
  let quickLookDataSource = GitDesktopQuickLookDataSource()
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
