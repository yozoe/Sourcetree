import Cocoa
import FlutterMacOS
import XCTest
@testable import Git_Desktop

class RunnerTests: XCTestCase {
  private final class TestWorkspace {}

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

  func testWorkspaceEngineStartsAfterItsViewControllerIsAttached() throws {
    let controller = try WorkspaceFlutterWindowController(
      repositoryPath: nil,
      initialAction: nil,
      coordinator: WindowCoordinator()
    )
    defer {
      controller.close()
    }

    let contentSize = try XCTUnwrap(controller.window).contentLayoutRect.size
    XCTAssertEqual(contentSize.width, 1280, accuracy: 1)
    XCTAssertEqual(contentSize.height, 800, accuracy: 1)
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
}
