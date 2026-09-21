import Cocoa
import FlutterMacOS
import XCTest
@testable import Git_Desktop

class RunnerTests: XCTestCase {
  private final class TestWorkspace {}

  func testRuntimeDockIconDoesNotApplyASecondSafeAreaInset() {
    let bounds = NSRect(x: 0, y: 0, width: 128, height: 128)

    XCTAssertEqual(gitDesktopDockIconFrame(for: bounds), bounds)
  }

  func testStopTrackingMenuRequiresKeyWorkspaceAndValidatedSelection() {
    XCTAssertFalse(
      gitDesktopCanPerformStopTrackingMenuAction(
        hasKeyWorkspace: false,
        hasValidatedTrackedSelection: true
      )
    )
    XCTAssertFalse(
      gitDesktopCanPerformStopTrackingMenuAction(
        hasKeyWorkspace: true,
        hasValidatedTrackedSelection: false
      )
    )
    XCTAssertTrue(
      gitDesktopCanPerformStopTrackingMenuAction(
        hasKeyWorkspace: true,
        hasValidatedTrackedSelection: true
      )
    )
  }

  func testApplyPatchMenuRequiresKeyWorkspaceAndMutationCapability() {
    XCTAssertFalse(
      gitDesktopCanPerformApplyPatchMenuAction(
        hasKeyWorkspace: false,
        hasRepositoryMutationCapability: true
      )
    )
    XCTAssertFalse(
      gitDesktopCanPerformApplyPatchMenuAction(
        hasKeyWorkspace: true,
        hasRepositoryMutationCapability: false
      )
    )
    XCTAssertTrue(
      gitDesktopCanPerformApplyPatchMenuAction(
        hasKeyWorkspace: true,
        hasRepositoryMutationCapability: true
      )
    )
  }

  func testSelectedChangeMenuRequiresKeyWorkspaceAndValidatedSelection() {
    XCTAssertFalse(
      gitDesktopCanPerformSelectedChangeMenuAction(
        hasKeyWorkspace: false,
        hasValidatedSelection: true
      )
    )
    XCTAssertFalse(
      gitDesktopCanPerformSelectedChangeMenuAction(
        hasKeyWorkspace: true,
        hasValidatedSelection: false
      )
    )
    XCTAssertTrue(
      gitDesktopCanPerformSelectedChangeMenuAction(
        hasKeyWorkspace: true,
        hasValidatedSelection: true
      )
    )
  }

  func testRepositoryOperationMenuNamesUseStableProtocolIdentifiers() {
    XCTAssertEqual(GitDesktopRepositoryOperation(rawValue: "merge")?.menuName, "合并")
    XCTAssertEqual(GitDesktopRepositoryOperation(rawValue: "rebase")?.menuName, "变基")
    XCTAssertEqual(
      GitDesktopRepositoryOperation(rawValue: "cherryPick")?.menuName,
      "遴选"
    )
    XCTAssertEqual(GitDesktopRepositoryOperation(rawValue: "revert")?.menuName, "回滚")
    XCTAssertNil(GitDesktopRepositoryOperation(rawValue: "unknown"))
  }

  func testWorkspaceFileMenuTargetsValidateExistenceAndRepositoryBoundary() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "git-desktop-native-file-menu-\(UUID().uuidString)",
      isDirectory: true
    )
    let nested = root.appendingPathComponent("Sources", isDirectory: true)
    let file = nested.appendingPathComponent("main.swift")
    try FileManager.default.createDirectory(
      at: nested,
      withIntermediateDirectories: true
    )
    try Data("test".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: root) }

    let selected = GitDesktopWorkspaceFileMenuTargets(
      repositoryRootPath: root.path,
      selectedFilePaths: [file.path],
      hasFileSelection: true
    )
    XCTAssertEqual(selected.existingSelectedURLs(), [file])
    XCTAssertEqual(selected.existingRegularFileURLs(), [file])
    XCTAssertEqual(selected.terminalDirectoryURL(), nested)

    let link = nested.appendingPathComponent("linked.swift")
    try FileManager.default.createSymbolicLink(
      atPath: link.path,
      withDestinationPath: file.path
    )
    let linkedSelection = GitDesktopWorkspaceFileMenuTargets(
      repositoryRootPath: root.path,
      selectedFilePaths: [link.path],
      hasFileSelection: true
    )
    XCTAssertTrue(linkedSelection.existingRegularFileURLs().isEmpty)

    let noneSelected = GitDesktopWorkspaceFileMenuTargets(
      repositoryRootPath: root.path,
      selectedFilePaths: [],
      hasFileSelection: false
    )
    XCTAssertEqual(noneSelected.existingRepositoryRootURL(), root)
    XCTAssertEqual(noneSelected.terminalDirectoryURL(), root)

    let escaped = GitDesktopWorkspaceFileMenuTargets(
      repositoryRootPath: root.path,
      selectedFilePaths: [root.deletingLastPathComponent().path],
      hasFileSelection: true
    )
    XCTAssertTrue(escaped.selectedFilePaths.isEmpty)
    XCTAssertTrue(escaped.existingSelectedURLs().isEmpty)
    XCTAssertNil(escaped.terminalDirectoryURL())
  }

  func testWorkspaceFileMenuTargetsRejectPartialAndStaleSelections() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "git-desktop-native-file-stale-\(UUID().uuidString)",
      isDirectory: true
    )
    let existing = root.appendingPathComponent("exists.txt")
    let missing = root.appendingPathComponent("missing.txt")
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    try Data().write(to: existing)
    defer { try? FileManager.default.removeItem(at: root) }

    let targets = GitDesktopWorkspaceFileMenuTargets(
      repositoryRootPath: root.path,
      selectedFilePaths: [existing.path, missing.path],
      hasFileSelection: true
    )

    XCTAssertTrue(targets.existingSelectedURLs().isEmpty)
    XCTAssertNil(targets.terminalDirectoryURL())
  }

  func testWorkspaceArgumentsIdentifyTheEngineAndInitialRepository() {
    XCTAssertEqual(
      gitDesktopWorkspaceArguments(
        repositoryPath: "/tmp/example",
        initialAction: "cloneRepository"
      ),
      [
        "--git-desktop-workspace",
        "--git-desktop-repository=/tmp/example",
        "--git-desktop-action=cloneRepository",
      ]
    )
    XCTAssertEqual(
      gitDesktopWorkspaceArguments(
        repositoryPath: "/tmp/example",
        initialAction: nil,
        restoresPreviouslyOpenWorkspace: true
      ),
      [
        "--git-desktop-workspace",
        "--git-desktop-repository=/tmp/example",
        "--git-desktop-restored-workspace",
      ]
    )
    XCTAssertEqual(
      gitDesktopWorkspaceArguments(
        repositoryPath: nil,
        initialAction: nil
      ),
      ["--git-desktop-workspace"]
    )
  }

  func testDroppedDirectoryPathsIgnoreFilesAndRemoveDuplicates() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "git-desktop-drop-test-\(UUID().uuidString)",
      isDirectory: true
    )
    let directory = root.appendingPathComponent("repository", isDirectory: true)
    let file = root.appendingPathComponent("not-a-directory.txt")
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    try Data().write(to: file)
    defer {
      try? FileManager.default.removeItem(at: root)
    }

    XCTAssertEqual(
      gitDesktopDroppedDirectoryPaths([file, directory, directory]),
      [directory.standardizedFileURL.path]
    )
  }

  func testWorkspaceEngineRestoresSavedContentSizeAfterAttachment() throws {
    let suiteName = "git-desktop-window-controller-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }
    let sizeStore = GitDesktopWindowSizeStore(defaults: defaults)
    sizeStore.save(NSSize(width: 1110, height: 710), for: .workspace)
    let coordinator = WindowCoordinator(windowSizeStore: sizeStore)
    let controller = try WorkspaceFlutterWindowController(
      repositoryPath: nil,
      initialAction: nil,
      coordinator: coordinator
    )
    defer {
      controller.close()
    }

    let contentSize = try XCTUnwrap(controller.window).contentLayoutRect.size
    XCTAssertEqual(contentSize.width, 1110, accuracy: 1)
    XCTAssertEqual(contentSize.height, 710, accuracy: 1)

    let window = try XCTUnwrap(controller.window)
    window.setContentSize(NSSize(width: 1180, height: 740))
    controller.windowDidEndLiveResize(
      Notification(name: NSWindow.didEndLiveResizeNotification, object: window)
    )
    XCTAssertEqual(
      sizeStore.restoredSize(
        for: .workspace,
        default: NSSize(width: 1280, height: 800),
        minimum: NSSize(width: 900, height: 600)
      ),
      NSSize(width: 1180, height: 740)
    )
  }

  func testClosingOlderWorkspaceDoesNotOverwriteMostRecentResize() throws {
    let suiteName = "git-desktop-window-close-size-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }
    let sizeStore = GitDesktopWindowSizeStore(defaults: defaults)
    let coordinator = WindowCoordinator(windowSizeStore: sizeStore)
    let olderController = try WorkspaceFlutterWindowController(
      repositoryPath: nil,
      initialAction: nil,
      coordinator: coordinator
    )
    let recentController = try WorkspaceFlutterWindowController(
      repositoryPath: nil,
      initialAction: nil,
      coordinator: coordinator
    )
    defer {
      olderController.close()
      recentController.close()
    }

    let olderWindow = try XCTUnwrap(olderController.window)
    olderWindow.setContentSize(NSSize(width: 1000, height: 650))
    let recentWindow = try XCTUnwrap(recentController.window)
    recentWindow.setContentSize(NSSize(width: 1200, height: 760))
    recentController.windowDidEndLiveResize(
      Notification(
        name: NSWindow.didEndLiveResizeNotification,
        object: recentWindow
      )
    )

    olderController.windowWillClose(
      Notification(name: NSWindow.willCloseNotification, object: olderWindow)
    )

    XCTAssertEqual(
      sizeStore.restoredSize(
        for: .workspace,
        default: NSSize(width: 1280, height: 800),
        minimum: NSSize(width: 900, height: 600)
      ),
      NSSize(width: 1200, height: 760)
    )
  }

  func testWorkspaceWindowsUseOneNativeTabbingIdentifier() throws {
    let controller = try WorkspaceFlutterWindowController(
      repositoryPath: nil,
      initialAction: nil,
      coordinator: WindowCoordinator()
    )
    defer {
      controller.close()
    }

    let window = try XCTUnwrap(controller.window)
    XCTAssertEqual(window.tabbingMode, .disallowed)
    XCTAssertEqual(
      window.tabbingIdentifier,
      "com.yeknom.git_desktop.workspace"
    )
  }

  func testWorkspaceTabStripUsesEqualRectangularSegments() {
    var requestedIndex: Int?
    var closedIndex: Int?
    let strip = GitDesktopWorkspaceTabStripView(tabs: [
      GitDesktopWorkspaceTabDefinition(
        title: "Alpha (Git)",
        isSelected: false,
        closeAction: { closedIndex = 0 },
        action: { requestedIndex = 0 }
      ),
      GitDesktopWorkspaceTabDefinition(
        title: "Beta (Git)",
        isSelected: true,
        closeAction: { closedIndex = 1 },
        action: { requestedIndex = 1 }
      ),
      GitDesktopWorkspaceTabDefinition(
        title: "Gamma (Git)",
        isSelected: false,
        closeAction: { closedIndex = 2 },
        action: { requestedIndex = 2 }
      ),
    ])
    strip.frame = NSRect(
      x: 0,
      y: 0,
      width: 900,
      height: gitDesktopWorkspaceTabStripHeight
    )
    strip.layoutSubtreeIfNeeded()

    XCTAssertEqual(strip.frame.height, 29)
    XCTAssertEqual(strip.tabButtons.map(\.title), [
      "Alpha (Git)",
      "Beta (Git)",
      "Gamma (Git)",
    ])
    XCTAssertEqual(strip.tabButtons.map(\.isSelectedTab), [false, true, false])
    strip.tabButtons[0].updateSelection(true)
    strip.tabButtons[1].updateSelection(false)
    XCTAssertEqual(strip.tabButtons.map(\.isSelectedTab), [true, false, false])
    XCTAssertEqual(strip.tabButtons[0].frame.width, 300, accuracy: 0.5)
    XCTAssertEqual(strip.tabButtons[1].frame.width, 300, accuracy: 0.5)
    XCTAssertEqual(strip.tabButtons[2].frame.width, 300, accuracy: 0.5)
    XCTAssertEqual(strip.tabButtons[0].frame.minY, 0, accuracy: 0.5)
    XCTAssertEqual(strip.tabButtons[1].frame.minY, 0, accuracy: 0.5)
    XCTAssertEqual(strip.tabButtons[2].frame.minY, 0, accuracy: 0.5)
    XCTAssertEqual(strip.tabButtons[0].frame.height, 29, accuracy: 0.5)
    XCTAssertEqual(strip.tabButtons[1].frame.height, 29, accuracy: 0.5)
    XCTAssertEqual(strip.tabButtons[2].frame.height, 29, accuracy: 0.5)
    XCTAssertFalse(strip.tabButtons[0].drawsLeadingDivider)
    XCTAssertTrue(strip.tabButtons[1].drawsLeadingDivider)
    strip.tabButtons[2].performClick(nil)
    XCTAssertEqual(requestedIndex, 2)
    strip.tabButtons[0].closeButton.performClick(nil)
    XCTAssertEqual(closedIndex, 0)
    XCTAssertEqual(requestedIndex, 2)
    XCTAssertEqual(
      strip.tabButtons[0].closeButton.toolTip,
      "关闭 Alpha (Git)"
    )
  }

  func testWorkspaceTabDropIndexAndMovePreserveExpectedOrder() {
    XCTAssertEqual(
      gitDesktopWorkspaceTabDropIndex(
        locationX: 295,
        stripWidth: 300,
        tabCount: 3,
        sourceIndex: 0
      ),
      2
    )
    XCTAssertEqual(
      gitDesktopWorkspaceTabDropIndex(
        locationX: 5,
        stripWidth: 300,
        tabCount: 3,
        sourceIndex: 2
      ),
      0
    )
    XCTAssertEqual(
      gitDesktopMovingItem(
        in: ["Alpha", "Beta", "Gamma"],
        from: 0,
        to: 2
      ),
      ["Beta", "Gamma", "Alpha"]
    )
    XCTAssertEqual(
      gitDesktopMovingItem(
        in: ["Alpha", "Beta", "Gamma"],
        from: 2,
        to: 0
      ),
      ["Gamma", "Alpha", "Beta"]
    )
  }

  func testAdjacentTabIndexWrapsInBothDirections() {
    XCTAssertEqual(
      gitDesktopAdjacentTabIndex(currentIndex: 0, tabCount: 3, offset: -1),
      2
    )
    XCTAssertEqual(
      gitDesktopAdjacentTabIndex(currentIndex: 2, tabCount: 3, offset: 1),
      0
    )
    XCTAssertEqual(
      gitDesktopAdjacentTabIndex(currentIndex: 1, tabCount: 3, offset: 4),
      2
    )
    XCTAssertNil(
      gitDesktopAdjacentTabIndex(currentIndex: 0, tabCount: 1, offset: 1)
    )
  }

  func testDetachedWindowFrameStaysInsideVisibleScreen() {
    XCTAssertEqual(
      gitDesktopDetachedWindowFrame(
        currentFrame: NSRect(x: -1180, y: 80, width: 900, height: 650),
        visibleFrame: NSRect(x: -1280, y: 25, width: 1280, height: 775)
      ),
      NSRect(x: -1156, y: 56, width: 900, height: 650)
    )
    XCTAssertEqual(
      gitDesktopDetachedWindowFrame(
        currentFrame: NSRect(x: 0, y: 0, width: 1600, height: 1000),
        visibleFrame: NSRect(x: 0, y: 25, width: 1280, height: 775)
      ),
      NSRect(x: 0, y: 25, width: 1280, height: 775)
    )
  }

  func testMovingWindowBetweenDisplaysPreservesRelativeCenterAndBounds() {
    let moved = gitDesktopWindowFrame(
      moving: NSRect(x: 480, y: 200, width: 960, height: 700),
      from: NSRect(x: 0, y: 25, width: 1920, height: 1055),
      to: NSRect(x: 1920, y: 0, width: 1280, height: 800)
    )

    XCTAssertEqual(moved.width, 960, accuracy: 0.01)
    XCTAssertEqual(moved.height, 700, accuracy: 0.01)
    XCTAssertEqual(moved.midX, 2560, accuracy: 0.01)
    XCTAssertEqual(moved.midY, 398.1, accuracy: 0.1)
    XCTAssertGreaterThanOrEqual(moved.minX, 1920)
    XCTAssertLessThanOrEqual(moved.maxX, 3200)
    XCTAssertGreaterThanOrEqual(moved.minY, 0)
    XCTAssertLessThanOrEqual(moved.maxY, 800)

    XCTAssertEqual(
      gitDesktopWindowFrame(
        moving: NSRect(x: 0, y: 25, width: 1600, height: 1000),
        from: NSRect(x: 0, y: 25, width: 1920, height: 1055),
        to: NSRect(x: -1024, y: 0, width: 1024, height: 700)
      ).size,
      NSSize(width: 1024, height: 700)
    )
  }

  func testMergedWorkspaceTabToggleAndDetachmentKeepEnginesAlive() throws {
    let suiteName = "git-desktop-tab-detach-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let coordinator = WindowCoordinator(
      workspaceRestoreStore: GitDesktopWorkspaceRestoreStore(defaults: defaults),
      repositoryLibraryPendingStore:
        GitDesktopRepositoryLibraryPendingStore(defaults: defaults),
      windowSizeStore: GitDesktopWindowSizeStore(defaults: defaults)
    )
    let controllers = try (0..<3).map { index in
      try WorkspaceFlutterWindowController(
        repositoryPath: nil,
        initialAction: nil,
        coordinator: coordinator
      )
    }
    defer { controllers.forEach { $0.close() } }
    for (index, controller) in controllers.enumerated() {
      coordinator.registerRepository("/tmp/tab-\(index)", for: controller)
    }
    let windows = try controllers.map {
      try XCTUnwrap($0.window as? MainFlutterWindow)
    }

    coordinator.mergeAllWorkspaceWindows()
    XCTAssertTrue(windows.allSatisfy { $0.workspaceTabStripView != nil })

    XCTAssertTrue(coordinator.toggleMergedWorkspaceTabStrip(from: windows[1]))
    XCTAssertTrue(windows.allSatisfy { $0.workspaceTabStripView == nil })
    XCTAssertTrue(coordinator.selectAdjacentMergedWorkspace(from: windows[1], offset: 1))
    XCTAssertTrue(coordinator.toggleMergedWorkspaceTabStrip(from: windows[1]))
    XCTAssertTrue(windows.allSatisfy { $0.workspaceTabStripView != nil })

    XCTAssertTrue(coordinator.detachMergedWorkspace(windows[1]))
    XCTAssertNil(windows[1].workspaceTabStripView)
    XCTAssertNotNil(controllers[1].window)
    XCTAssertEqual(
      windows.filter { $0.workspaceTabStripView != nil }.count,
      2
    )
    let detachedSnapshot = GitDesktopWorkspaceRestoreStore(
      defaults: defaults
    ).snapshot
    XCTAssertEqual(
      Set(detachedSnapshot.paths),
      Set(["/tmp/tab-0", "/tmp/tab-1", "/tmp/tab-2"])
    )
    XCTAssertEqual(
      Set(detachedSnapshot.mergedWorkspacePaths),
      Set(["/tmp/tab-0", "/tmp/tab-2"])
    )
    XCTAssertEqual(
      Array(detachedSnapshot.paths.prefix(2)),
      detachedSnapshot.mergedWorkspacePaths
    )

    let remaining = windows.first { $0 !== windows[1] }!
    XCTAssertTrue(coordinator.detachMergedWorkspace(remaining))
    XCTAssertTrue(windows.allSatisfy { $0.workspaceTabStripView == nil })
    XCTAssertTrue(controllers.allSatisfy { $0.window != nil })
  }

  func testWorkspaceTabOverviewSelectsOneLiveGroupMember() throws {
    let coordinator = WindowCoordinator()
    let controllers = try (0..<3).map { index in
      try WorkspaceFlutterWindowController(
        repositoryPath: nil,
        initialAction: nil,
        coordinator: coordinator
      )
    }
    defer { controllers.forEach { $0.close() } }
    for (index, controller) in controllers.enumerated() {
      coordinator.registerRepository("/tmp/overview-\(index)", for: controller)
    }
    let windows = try controllers.map {
      try XCTUnwrap($0.window as? MainFlutterWindow)
    }

    coordinator.mergeAllWorkspaceWindows()
    let selectedTitle = try XCTUnwrap(
      windows[0].workspaceTabStripView?.tabButtons.first(
        where: \.isSelectedTab
      )?.title
    )
    let selectedWindow = try XCTUnwrap(
      windows.first { $0.title == selectedTitle }
    )
    XCTAssertTrue(coordinator.showMergedWorkspaceOverview(from: selectedWindow))
    let panel = try XCTUnwrap(selectedWindow.childWindows?.first)
    XCTAssertEqual(panel.title, "所有标签页")
    let overview = try XCTUnwrap(
      panel.contentView as? GitDesktopWorkspaceTabOverviewView
    )
    overview.layoutSubtreeIfNeeded()
    XCTAssertEqual(Set(overview.tabButtons.map(\.title)), Set(windows.map(\.title)))
    XCTAssertEqual(overview.tabButtons.filter(\.isSelectedTab).count, 1)
    XCTAssertTrue(overview.tabButtons.allSatisfy { $0.frame.width > 400 })
    XCTAssertTrue(overview.tabButtons.allSatisfy { $0.frame.height == 42 })

    let targetButton = try XCTUnwrap(
      overview.tabButtons.first { $0.title == windows[2].title }
    )
    targetButton.performClick(nil)

    XCTAssertTrue(windows[2].isVisible)
    XCTAssertTrue(selectedWindow.childWindows?.isEmpty ?? true)
    XCTAssertEqual(
      windows[2].workspaceTabStripView?.tabButtons.map(\.isSelectedTab),
      windows[2].workspaceTabStripView?.tabButtons.map { button in
        button.title == windows[2].title
      }
    )
  }

  func testWorkspaceTabOverviewClosesBeforeItsGroupChanges() throws {
    let coordinator = WindowCoordinator()
    let controllers = try (0..<2).map { index in
      try WorkspaceFlutterWindowController(
        repositoryPath: nil,
        initialAction: nil,
        coordinator: coordinator
      )
    }
    defer { controllers.forEach { $0.close() } }
    for (index, controller) in controllers.enumerated() {
      coordinator.registerRepository("/tmp/overview-close-\(index)", for: controller)
    }
    let windows = try controllers.map {
      try XCTUnwrap($0.window as? MainFlutterWindow)
    }

    coordinator.mergeAllWorkspaceWindows()
    XCTAssertTrue(coordinator.showMergedWorkspaceOverview(from: windows[0]))
    XCTAssertFalse(windows[0].childWindows?.isEmpty ?? true)

    XCTAssertTrue(coordinator.detachMergedWorkspace(windows[1]))

    XCTAssertTrue(windows[0].childWindows?.isEmpty ?? true)
    XCTAssertTrue(windows[1].childWindows?.isEmpty ?? true)
    XCTAssertFalse(coordinator.showMergedWorkspaceOverview(from: windows[0]))
  }

  func testWorkspaceWindowInstallsCustomStripWithoutReplacingNativeTitle() throws {
    let controller = try WorkspaceFlutterWindowController(
      repositoryPath: nil,
      initialAction: nil,
      coordinator: WindowCoordinator()
    )
    let secondController = try WorkspaceFlutterWindowController(
      repositoryPath: nil,
      initialAction: nil,
      coordinator: WindowCoordinator()
    )
    let window = try XCTUnwrap(controller.window as? MainFlutterWindow)
    let secondWindow = try XCTUnwrap(
      secondController.window as? MainFlutterWindow
    )
    defer {
      window.removeWorkspaceTabStrip()
      controller.close()
      secondController.close()
    }
    window.title = "Alpha (Git)"
    secondWindow.title = "Beta (Git)"
    window.animationBehavior = .documentWindow

    window.configureWorkspaceTabStrip(
      windows: [window, secondWindow],
      selectedWindow: window
    )

    XCTAssertEqual(window.tab.title, "Alpha (Git)")
    XCTAssertEqual(window.tab.toolTip, "Alpha (Git)")
    XCTAssertNil(window.tab.attributedTitle)
    XCTAssertNil(window.tab.accessoryView)
    XCTAssertNotNil(window.workspaceTabStripView)
    XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty)
    XCTAssertEqual(window.animationBehavior, .none)
    XCTAssertEqual(
      window.workspaceTabStripView?.tabButtons.map(\.isSelectedTab),
      [true, false]
    )

    let initialStrip = try XCTUnwrap(window.workspaceTabStripView)
    secondWindow.title = "Beta Renamed (Git)"
    window.configureWorkspaceTabStrip(
      windows: [window, secondWindow],
      selectedWindow: secondWindow
    )
    XCTAssertTrue(window.workspaceTabStripView === initialStrip)
    XCTAssertEqual(
      window.workspaceTabStripView?.tabButtons.map(\.isSelectedTab),
      [false, true]
    )
    XCTAssertEqual(
      window.workspaceTabStripView?.tabButtons.map(\.title),
      ["Alpha (Git)", "Beta Renamed (Git)"]
    )
    XCTAssertEqual(
      window.workspaceTabStripView?.tabButtons[1].toolTip,
      "Beta Renamed (Git)"
    )
    XCTAssertEqual(
      window.workspaceTabStripView?.tabButtons[1].closeButton.toolTip,
      "关闭 Beta Renamed (Git)"
    )

    window.removeWorkspaceTabStrip()
    XCTAssertEqual(window.animationBehavior, .documentWindow)
  }

  func testCancelledDelayedWindowActivationDoesNotRun() {
    let activation = GitDesktopDelayedWindowActivation()
    let activationExpectation = expectation(
      description: "cancelled activation does not run"
    )
    activationExpectation.isInverted = true
    activation.schedule(after: 0.01) {
      activationExpectation.fulfill()
    }
    activation.cancel()

    wait(for: [activationExpectation], timeout: 0.1)
  }

  func testWorkspaceIndexReplacesAndRemovesOnlyTheOwnedHost() {
    let index = GitDesktopWorkspaceIndex<TestWorkspace>()
    let first = TestWorkspace()
    let replacement = TestWorkspace()

    XCTAssertNil(index.register(first, for: "/tmp/example"))
    XCTAssertTrue(index.host(for: "/tmp/example") === first)
    XCTAssertTrue(
      index.register(replacement, for: "/tmp/example") === first
    )

    index.remove(first)
    XCTAssertTrue(index.host(for: "/tmp/example") === replacement)
    index.remove(replacement)
    XCTAssertNil(index.host(for: "/tmp/example"))
  }

  func testWorkspaceHistoryReturnsThePreviouslyFocusedRemainingWindow() {
    let history = GitDesktopWorkspaceHistory<TestWorkspace>()
    let first = TestWorkspace()
    let second = TestWorkspace()
    let third = TestWorkspace()

    history.markRecent(first)
    history.markRecent(second)
    history.markRecent(third)
    history.markRecent(second)
    XCTAssertTrue(history.mostRecent === second)

    history.remove(second)
    XCTAssertTrue(history.mostRecent === third)
    history.remove(third)
    XCTAssertTrue(history.mostRecent === first)
  }

  func testWindowFocusHistoryRestoresTheLastFrontmostWindow() {
    let history = GitDesktopWindowFocusHistory<TestWorkspace>()
    let library = TestWorkspace()
    let workspace = TestWorkspace()

    history.markFrontmost(library)
    XCTAssertTrue(history.frontmost === library)
    history.markFrontmost(workspace)
    XCTAssertTrue(history.frontmost === workspace)
  }

  func testWorkspaceRestoreStoreKeepsCanonicalUniquePaths() {
    let suiteName = "git-desktop-workspace-restore-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }
    let store = GitDesktopWorkspaceRestoreStore(defaults: defaults)

    store.save(
      paths: ["/tmp/example", "/tmp/example/", "", "/tmp/other"],
      restoresMergedWorkspaces: true
    )

    XCTAssertEqual(store.paths, ["/tmp/example", "/tmp/other"])
    XCTAssertTrue(store.snapshot.restoresMergedWorkspaces)
    XCTAssertEqual(
      store.snapshot.mergedWorkspacePaths,
      ["/tmp/example", "/tmp/other"]
    )

    store.save(
      paths: ["/tmp/example", "/tmp/other", "/tmp/standalone"],
      mergedWorkspacePaths: ["/tmp/other", "/tmp/example"]
    )
    XCTAssertEqual(
      store.snapshot.mergedWorkspacePaths,
      ["/tmp/other", "/tmp/example"]
    )
    XCTAssertTrue(store.snapshot.restoresMergedWorkspaces)

    store.save(paths: ["/tmp/example"], restoresMergedWorkspaces: true)

    XCTAssertFalse(store.snapshot.restoresMergedWorkspaces)
  }

  func testWorkspaceRestoreStoreMigratesLegacyAllMergedSnapshot() {
    let suiteName = "git-desktop-workspace-restore-legacy-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }
    defaults.set(
      ["/tmp/first", "/tmp/second"],
      forKey: "gitDesktopOpenWorkspacePaths"
    )
    defaults.set(true, forKey: "gitDesktopRestoresMergedWorkspaces")

    let snapshot = GitDesktopWorkspaceRestoreStore(defaults: defaults).snapshot

    XCTAssertEqual(snapshot.paths, ["/tmp/first", "/tmp/second"])
    XCTAssertEqual(
      snapshot.mergedWorkspacePaths,
      ["/tmp/first", "/tmp/second"]
    )
  }

  func testDetachedWorkspaceIsRemovedFromPendingRestoredGroup() {
    XCTAssertEqual(
      gitDesktopMergedWorkspacePaths(
        ["/tmp/alpha", "/tmp/beta", "/tmp/gamma"],
        afterDetaching: "/tmp/beta"
      ),
      ["/tmp/alpha", "/tmp/gamma"]
    )
    XCTAssertEqual(
      gitDesktopMergedWorkspacePaths(
        ["/tmp/alpha", "/tmp/gamma"],
        afterDetaching: nil
      ),
      ["/tmp/alpha", "/tmp/gamma"]
    )
  }

  func testPendingRepositoryLibraryStoreRetainsPathsUntilAcknowledged() {
    let suiteName = "git-desktop-pending-library-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }
    let store = GitDesktopRepositoryLibraryPendingStore(defaults: defaults)

    store.add("/tmp/example")
    store.add("/tmp/example/")
    store.add("/tmp/other")

    XCTAssertEqual(store.paths, ["/tmp/example", "/tmp/other"])

    store.remove("/tmp/example/")

    XCTAssertEqual(store.paths, ["/tmp/other"])
  }

  func testWindowSizeStoreKeepsLibraryAndWorkspacePreferencesSeparate() {
    let suiteName = "git-desktop-window-size-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }
    let store = GitDesktopWindowSizeStore(defaults: defaults)
    store.save(NSSize(width: 1024, height: 700), for: .repositoryLibrary)
    store.save(NSSize(width: 1400, height: 900), for: .workspace)

    XCTAssertEqual(
      store.restoredSize(
        for: .repositoryLibrary,
        default: NSSize(width: 1280, height: 800),
        minimum: NSSize(width: 900, height: 600)
      ),
      NSSize(width: 1024, height: 700)
    )
    XCTAssertEqual(
      store.restoredSize(
        for: .workspace,
        default: NSSize(width: 1280, height: 800),
        minimum: NSSize(width: 900, height: 600)
      ),
      NSSize(width: 1400, height: 900)
    )
  }

  func testWindowSizeRestoreRejectsInvalidValuesAndStaysVisible() {
    let suiteName = "git-desktop-window-size-invalid-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }
    let store = GitDesktopWindowSizeStore(defaults: defaults)
    defaults.set(
      ["width": -1.0, "height": 720.0],
      forKey: "gitDesktopWorkspaceWindowContentSize"
    )

    XCTAssertEqual(
      store.restoredSize(
        for: .workspace,
        default: NSSize(width: 1280, height: 800),
        minimum: NSSize(width: 900, height: 600),
        maximum: NSSize(width: 1440, height: 900)
      ),
      NSSize(width: 1280, height: 800)
    )
    XCTAssertEqual(
      gitDesktopConstrainedWindowContentSize(
        NSSize(width: 400, height: 300),
        default: NSSize(width: 1280, height: 800),
        minimum: NSSize(width: 900, height: 600),
        maximum: NSSize(width: 1200, height: 700)
      ),
      NSSize(width: 900, height: 600)
    )
    XCTAssertEqual(
      gitDesktopConstrainedWindowContentSize(
        NSSize(width: 1800, height: 1200),
        default: NSSize(width: 1280, height: 800),
        minimum: NSSize(width: 900, height: 600),
        maximum: NSSize(width: 1200, height: 700)
      ),
      NSSize(width: 1200, height: 700)
    )
  }

  func testNewWorkspaceJoinsAnExistingMergedWindowOrder() {
    let first = NSObject()
    let second = NSObject()
    let newlyOpened = NSObject()
    let stale = NSObject()
    let firstIdentifier = ObjectIdentifier(first)
    let secondIdentifier = ObjectIdentifier(second)
    let newIdentifier = ObjectIdentifier(newlyOpened)

    XCTAssertEqual(
      gitDesktopMergedWorkspaceOrderByAddingWindow(
        existingOrder: [firstIdentifier, ObjectIdentifier(stale), secondIdentifier],
        liveWindowIdentifiers: [firstIdentifier, secondIdentifier, newIdentifier],
        newWindowIdentifier: newIdentifier
      ),
      [firstIdentifier, secondIdentifier, newIdentifier]
    )
    XCTAssertNil(
      gitDesktopMergedWorkspaceOrderByAddingWindow(
        existingOrder: [firstIdentifier],
        liveWindowIdentifiers: [firstIdentifier, newIdentifier],
        newWindowIdentifier: newIdentifier
      )
    )
  }

  func testRestorationGateWaitsForEveryWorkspaceBeforeMerging() {
    let gate = GitDesktopWorkspaceRestorationGate()
    gate.begin(paths: ["/tmp/first", "/tmp/second"], shouldMerge: true)

    XCTAssertTrue(gate.isWaiting)
    XCTAssertEqual(gate.resolve("/tmp/unknown"), .unrelated)
    XCTAssertEqual(gate.resolve("/tmp/first"), .waiting)
    XCTAssertTrue(gate.isWaiting)
    XCTAssertEqual(
      gate.resolve("/tmp/second"),
      .finished(
        GitDesktopWorkspaceRestorationCompletion(
          resolvedPaths: ["/tmp/first", "/tmp/second"],
          timedOutPathsToKeepOpen: [],
          mergedPathsToRestore: ["/tmp/first", "/tmp/second"]
        )
      )
    )
    XCTAssertFalse(gate.isWaiting)
  }

  func testRestorationGateTimeoutKeepsOnlyResolvedBatchMembers() throws {
    let gate = GitDesktopWorkspaceRestorationGate()
    gate.begin(
      paths: ["/tmp/first", "/tmp/second", "/tmp/third"],
      shouldMerge: true
    )

    XCTAssertEqual(gate.resolve("/tmp/second"), .waiting)
    let completion = try XCTUnwrap(gate.finishPending())

    XCTAssertEqual(completion.resolvedPaths, ["/tmp/second"])
    XCTAssertEqual(
      completion.timedOutPathsToKeepOpen,
      ["/tmp/first", "/tmp/third"]
    )
    XCTAssertFalse(completion.shouldMerge)
    XCTAssertFalse(gate.isWaiting)
    XCTAssertEqual(gate.resolve("/tmp/first"), .unrelated)
  }

  func testRestorationGateDoesNotIncludePathsOutsideItsBatch() throws {
    let gate = GitDesktopWorkspaceRestorationGate()
    gate.begin(paths: ["/tmp/first", "/tmp/second"], shouldMerge: true)

    XCTAssertEqual(gate.resolve("/tmp/new-workspace"), .unrelated)
    XCTAssertEqual(gate.resolve("/tmp/first"), .waiting)
    let resolution = gate.resolve("/tmp/second")
    guard case let .finished(completion) = resolution else {
      XCTFail("Expected the restore batch to finish")
      return
    }

    XCTAssertEqual(completion.resolvedPaths, ["/tmp/first", "/tmp/second"])
    XCTAssertFalse(completion.resolvedPaths.contains("/tmp/new-workspace"))
  }

  func testRestorationGateKeepsOnlyExplicitMergedWorkspaceMembers() {
    let gate = GitDesktopWorkspaceRestorationGate()
    gate.begin(
      paths: ["/tmp/first", "/tmp/standalone", "/tmp/third"],
      mergedPaths: ["/tmp/third", "/tmp/first"]
    )

    XCTAssertEqual(gate.resolve("/tmp/first"), .waiting)
    XCTAssertEqual(gate.resolve("/tmp/standalone"), .waiting)
    XCTAssertEqual(
      gate.resolve("/tmp/third"),
      .finished(
        GitDesktopWorkspaceRestorationCompletion(
          resolvedPaths: ["/tmp/first", "/tmp/standalone", "/tmp/third"],
          timedOutPathsToKeepOpen: [],
          mergedPathsToRestore: ["/tmp/first", "/tmp/third"]
        )
      )
    )
  }

  func testRepositoryWindowShortcutRecognition() throws {
    let toggle = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.command, .shift],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "~",
        charactersIgnoringModifiers: "~",
        isARepeat: false,
        keyCode: 50
      )
    )
    let showLibrary = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.command],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "n",
        charactersIgnoringModifiers: "n",
        isARepeat: false,
        keyCode: 45
      )
    )

    XCTAssertTrue(gitDesktopIsRepositoryWindowToggle(toggle))
    XCTAssertTrue(gitDesktopIsRepositoryLibraryShortcut(showLibrary))
  }

  func testRepositoryLibraryShortcutRejectsModifiedCommandN() throws {
    let event = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.command, .shift],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "N",
        charactersIgnoringModifiers: "n",
        isARepeat: false,
        keyCode: 45
      )
    )

    XCTAssertFalse(gitDesktopIsRepositoryLibraryShortcut(event))
  }

  func testPendingWindowMenuSupportsLibraryAndWorkspaceWindows() {
    let library = MainFlutterWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    library.configure(role: .repositoryLibrary)
    let workspace = MainFlutterWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    workspace.configure(role: .workspace)

    XCTAssertTrue(gitDesktopCanPerformWindowMenuAction(library))
    XCTAssertTrue(gitDesktopCanPerformWindowMenuAction(workspace))
    XCTAssertFalse(gitDesktopCanPerformWindowMenuAction(nil))
    XCTAssertFalse(gitDesktopCanPerformWindowMenuAction(NSWindow()))
  }

  func testWindowPlacementRequiresResizableNonFullscreenAppWindow() {
    let resizable = MainFlutterWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
      styleMask: [.titled, .resizable],
      backing: .buffered,
      defer: false
    )
    let fixed = MainFlutterWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    let fullscreen = MainFlutterWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
      styleMask: [.titled, .resizable, .fullScreen],
      backing: .buffered,
      defer: false
    )

    XCTAssertTrue(gitDesktopCanPerformWindowPlacement(resizable))
    XCTAssertFalse(gitDesktopCanPerformWindowPlacement(fixed))
    XCTAssertFalse(gitDesktopCanPerformWindowPlacement(fullscreen))
    XCTAssertFalse(gitDesktopCanPerformWindowPlacement(nil))
  }

  func testWindowPlacementUsesVisibleScreenBoundsAndMinimumWidth() {
    let visibleFrame = NSRect(x: 120, y: 48, width: 1920, height: 1040)
    let currentFrame = NSRect(x: 500, y: 300, width: 1100, height: 700)
    let minimumSize = NSSize(width: 900, height: 600)

    XCTAssertEqual(
      gitDesktopWindowFrame(
        currentFrame: currentFrame,
        visibleFrame: visibleFrame,
        minimumSize: minimumSize,
        placement: .fill
      ),
      visibleFrame
    )
    XCTAssertEqual(
      gitDesktopWindowFrame(
        currentFrame: currentFrame,
        visibleFrame: visibleFrame,
        minimumSize: minimumSize,
        placement: .center
      ),
      NSRect(x: 530, y: 218, width: 1100, height: 700)
    )
    XCTAssertEqual(
      gitDesktopWindowFrame(
        currentFrame: currentFrame,
        visibleFrame: visibleFrame,
        minimumSize: minimumSize,
        placement: .leading
      ),
      NSRect(x: 120, y: 48, width: 960, height: 1040)
    )
    XCTAssertEqual(
      gitDesktopWindowFrame(
        currentFrame: currentFrame,
        visibleFrame: visibleFrame,
        minimumSize: minimumSize,
        placement: .trailing
      ),
      NSRect(x: 1080, y: 48, width: 960, height: 1040)
    )
  }

  func testWindowPlacementKeepsNarrowDisplaysUsable() {
    let visibleFrame = NSRect(x: -1280, y: 25, width: 1280, height: 775)
    let frame = gitDesktopWindowFrame(
      currentFrame: NSRect(x: -1200, y: 100, width: 1000, height: 650),
      visibleFrame: visibleFrame,
      minimumSize: NSSize(width: 900, height: 600),
      placement: .trailing
    )

    XCTAssertEqual(frame, NSRect(x: -900, y: 25, width: 900, height: 775))
  }
}
