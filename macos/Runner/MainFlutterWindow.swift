import Cocoa
import FlutterMacOS

enum GitDesktopWindowRole {
  case repositoryLibrary
  case workspace
}

/// 中文：判断窗口菜单占位动作是否能安全显示在当前应用窗口中。
///
/// English: Returns whether a pending Window-menu action can be presented in
/// the current application window.
func gitDesktopCanPerformWindowMenuAction(_ keyWindow: NSWindow?) -> Bool {
  guard let keyWindow = keyWindow as? MainFlutterWindow else {
    return false
  }
  return keyWindow.attachedSheet == nil
}

private let gitDesktopWorkspaceTabbingIdentifier =
  "com.yeknom.git_desktop.workspace"

/// Returns canonical, readable directory paths from dropped Finder URLs.
func gitDesktopDroppedDirectoryPaths(_ urls: [URL]) -> [String] {
  var paths: [String] = []
  var seen: Set<String> = []
  for url in urls {
    let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
    guard (try? resolvedURL.resourceValues(forKeys: [.isDirectoryKey]))?
      .isDirectory == true else {
      continue
    }
    let path = resolvedURL.path
    if seen.insert(path).inserted {
      paths.append(path)
    }
  }
  return paths
}

private final class DockIconView: NSView {
  private let imageView: NSImageView

  init(icon: NSImage, size: NSSize) {
    imageView = NSImageView()
    super.init(frame: NSRect(origin: .zero, size: size))

    imageView.image = icon
    imageView.imageAlignment = .alignCenter
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.imageFrameStyle = .none
    addSubview(imageView)
    updateImageFrame()
  }

  required init?(coder: NSCoder) {
    nil
  }

  override var isOpaque: Bool {
    false
  }

  override func layout() {
    super.layout()
    updateImageFrame()
  }

  private func updateImageFrame() {
    let inset = min(bounds.width, bounds.height) * 0.11
    imageView.frame = bounds.insetBy(dx: inset, dy: inset)
  }
}

/// Receives Finder directory drops without taking normal pointer events away
/// from Flutter's child view.
private final class RepositoryDirectoryDropView: NSView {
  var acceptsDirectoryDrops = false
  var directoryDragStateHandler: ((Bool) -> Void)?
  var directoriesDroppedHandler: (([String]) -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    registerForDraggedTypes([.fileURL])
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard acceptsDirectoryDrops,
      !droppedDirectoryPaths(from: sender).isEmpty else {
      return []
    }
    directoryDragStateHandler?(true)
    return .copy
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    directoryDragStateHandler?(false)
  }

  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    acceptsDirectoryDrops && !droppedDirectoryPaths(from: sender).isEmpty
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let paths = droppedDirectoryPaths(from: sender)
    directoryDragStateHandler?(false)
    guard !paths.isEmpty else {
      return false
    }
    directoriesDroppedHandler?(paths)
    return true
  }

  private func droppedDirectoryPaths(from sender: NSDraggingInfo) -> [String] {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [
      .urlReadingFileURLsOnly: true,
    ]
    let urls = sender.draggingPasteboard.readObjects(
      forClasses: [NSURL.self],
      options: options
    ) as? [URL] ?? []
    return gitDesktopDroppedDirectoryPaths(urls)
  }
}

/// Hosts Flutter below a native drop destination so ordinary mouse events keep
/// reaching Flutter while AppKit can resolve Finder drag targets through the
/// view hierarchy.
private final class RepositoryDirectoryDropContainerViewController:
  NSViewController {
  private let flutterViewController: FlutterViewController
  private var dropView: RepositoryDirectoryDropView {
    view as! RepositoryDirectoryDropView
  }

  var acceptsDirectoryDrops: Bool {
    get { dropView.acceptsDirectoryDrops }
    set { dropView.acceptsDirectoryDrops = newValue }
  }
  var directoryDragStateHandler: ((Bool) -> Void)? {
    get { dropView.directoryDragStateHandler }
    set { dropView.directoryDragStateHandler = newValue }
  }
  var directoriesDroppedHandler: (([String]) -> Void)? {
    get { dropView.directoriesDroppedHandler }
    set { dropView.directoriesDroppedHandler = newValue }
  }

  init(flutterViewController: FlutterViewController) {
    self.flutterViewController = flutterViewController
    super.init(nibName: nil, bundle: nil)
    addChild(flutterViewController)
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func loadView() {
    let dropView = RepositoryDirectoryDropView(frame: .zero)
    let flutterView = flutterViewController.view
    flutterView.frame = dropView.bounds
    flutterView.autoresizingMask = [.width, .height]
    dropView.addSubview(flutterView)
    view = dropView
  }
}

class MainFlutterWindow: NSWindow {
  private(set) var role = GitDesktopWindowRole.repositoryLibrary
  private var directoryDropContainer:
    RepositoryDirectoryDropContainerViewController?
  var directoryDragStateHandler: ((Bool) -> Void)? {
    didSet {
      directoryDropContainer?.directoryDragStateHandler =
        directoryDragStateHandler
    }
  }
  var directoriesDroppedHandler: (([String]) -> Void)? {
    didSet {
      directoryDropContainer?.directoriesDroppedHandler =
        directoriesDroppedHandler
    }
  }

  func configure(role: GitDesktopWindowRole) {
    self.role = role
    title = role == .workspace ? "Git Desktop — Workspace" : "Git Desktop"
    tabbingIdentifier = role == .workspace
      ? gitDesktopWorkspaceTabbingIdentifier
      : ""
    // Workspaces remain separate until the user explicitly chooses the Window
    // menu action. The coordinator enables tabbing only for that merge.
    tabbingMode = .disallowed
    directoryDropContainer?.acceptsDirectoryDrops =
      role == .repositoryLibrary
  }

  /// Installs the Flutter view below an AppKit drag destination container.
  func installFlutterViewController(_ flutterViewController: FlutterViewController) {
    let container = RepositoryDirectoryDropContainerViewController(
      flutterViewController: flutterViewController
    )
    container.acceptsDirectoryDrops = role == .repositoryLibrary
    container.directoryDragStateHandler = directoryDragStateHandler
    container.directoriesDroppedHandler = directoriesDroppedHandler
    directoryDropContainer = container
    contentViewController = container
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if let appDelegate = NSApp.delegate as? AppDelegate,
       appDelegate.handleShortcut(event) {
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  override func becomeKey() {
    super.becomeKey()
    (NSApp.delegate as? AppDelegate)?.windowDidBecomeKey(self)
  }

  override func awakeFromNib() {
    configure(role: .repositoryLibrary)
    let flutterViewController = FlutterViewController()
    installFlutterViewController(flutterViewController)
    setContentSize(NSSize(width: 1280, height: 800))
    minSize = NSSize(width: 900, height: 600)
    center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()

    (NSApp.delegate as? AppDelegate)?.attachRepositoryLibrary(
      window: self,
      flutterViewController: flutterViewController
    )

    if let icon = NSImage(named: "DockIcon") {
      icon.isTemplate = false
      NSApp.applicationIconImage = icon
      NSApp.dockTile.contentView = DockIconView(
        icon: icon,
        size: NSApp.dockTile.size
      )
    }
    NSApp.dockTile.display()
  }

  func bringToFront() {
    if isMiniaturized {
      deminiaturize(nil)
    }
    collectionBehavior.insert(.moveToActiveSpace)
    NSApp.unhide(nil)
    level = .floating
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
    orderFrontRegardless()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
      guard let self else {
        return
      }
      self.level = .normal
      self.makeKeyAndOrderFront(nil)
      self.orderFrontRegardless()
    }
  }
}

func gitDesktopIsRepositoryWindowToggle(_ event: NSEvent) -> Bool {
  guard event.type == .keyDown, !event.isARepeat else { return false }
  let modifiers = event.modifierFlags.intersection(
    .deviceIndependentFlagsMask
  )
  guard modifiers.contains(.command),
        !modifiers.contains(.control),
        !modifiers.contains(.option) else {
    return false
  }
  return event.keyCode == 50
    || event.charactersIgnoringModifiers == "`"
    || event.charactersIgnoringModifiers == "~"
}

func gitDesktopIsRepositoryLibraryShortcut(_ event: NSEvent) -> Bool {
  guard event.type == .keyDown, !event.isARepeat else { return false }
  let modifiers = event.modifierFlags.intersection(
    .deviceIndependentFlagsMask
  )
  guard modifiers.contains(.command),
        !modifiers.contains(.shift),
        !modifiers.contains(.control),
        !modifiers.contains(.option) else {
    return false
  }
  return event.keyCode == 45
    || event.charactersIgnoringModifiers?.lowercased() == "n"
}
