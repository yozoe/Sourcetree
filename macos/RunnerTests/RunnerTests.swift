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

    store.save(paths: ["/tmp/example"], restoresMergedWorkspaces: true)

    XCTAssertFalse(store.snapshot.restoresMergedWorkspaces)
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
          unresolvedPaths: [],
          shouldMerge: true
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
      completion.unresolvedPaths,
      ["/tmp/first", "/tmp/third"]
    )
    XCTAssertTrue(completion.shouldMerge)
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
}
