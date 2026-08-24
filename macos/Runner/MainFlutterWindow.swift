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
let gitDesktopWorkspaceTabStripHeight: CGFloat = 29

/// 中文：保存至多一个延迟窗口动作，并保证取消后的旧动作不会执行。
///
/// English: Owns at most one delayed window action and prevents a cancelled
/// stale action from executing.
final class GitDesktopDelayedWindowActivation {
  private var pendingWorkItem: DispatchWorkItem?
  private var pendingToken: UUID?

  /// 中文：替换并安排下一次延迟窗口动作。
  ///
  /// English: Replaces and schedules the next delayed window action.
  func schedule(
    after delay: TimeInterval = 0.2,
    action: @escaping () -> Void
  ) {
    cancel()
    let token = UUID()
    pendingToken = token
    let workItem = DispatchWorkItem { [weak self] in
      guard let self, self.pendingToken == token else {
        return
      }
      self.pendingWorkItem = nil
      self.pendingToken = nil
      action()
    }
    pendingWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + delay,
      execute: workItem
    )
  }

  /// 中文：取消尚未执行的窗口动作，并使已经排队的回调失效。
  ///
  /// English: Cancels the pending window action and invalidates its queued
  /// callback.
  func cancel() {
    pendingWorkItem?.cancel()
    pendingWorkItem = nil
    pendingToken = nil
  }
}

/// 中文：绘制工作区标签条中的单个等宽矩形标签，并把点击交还给窗口协调器。
///
/// English: Draws one equal-width rectangular workspace tab while the window
/// coordinator preserves each workspace's independent lifecycle.
final class GitDesktopWorkspaceTabButton: NSButton {
  let isSelectedTab: Bool
  let drawsLeadingDivider: Bool
  private var isPointerInside = false

  init(
    title: String,
    isSelected: Bool,
    drawsLeadingDivider: Bool,
    action: @escaping () -> Void
  ) {
    isSelectedTab = isSelected
    self.drawsLeadingDivider = drawsLeadingDivider
    self.actionHandler = action
    super.init(frame: .zero)
    self.title = title
    toolTip = title
    isBordered = false
    bezelStyle = .regularSquare
    focusRingType = .none
    setButtonType(.momentaryChange)
    target = self
    self.action = #selector(activateTab)
    setAccessibilityLabel(title)
    setAccessibilityRole(.radioButton)
    setAccessibilityValue(isSelected)
  }

  required init?(coder: NSCoder) {
    nil
  }

  private let actionHandler: () -> Void

  @objc private func activateTab() {
    actionHandler()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(
      NSTrackingArea(
        rect: bounds,
        options: [.activeInKeyWindow, .mouseEnteredAndExited],
        owner: self,
        userInfo: nil
      )
    )
  }

  override func mouseEntered(with event: NSEvent) {
    isPointerInside = true
    needsDisplay = true
  }

  override func mouseExited(with event: NSEvent) {
    isPointerInside = false
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let backgroundColor: NSColor
    if isDark {
      backgroundColor = isSelectedTab
        ? NSColor(calibratedRed: 0.17, green: 0.19, blue: 0.20, alpha: 1)
        : isPointerInside
          ? NSColor(calibratedRed: 0.14, green: 0.16, blue: 0.17, alpha: 1)
          : NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.12, alpha: 1)
    } else {
      backgroundColor = isSelectedTab
        ? NSColor(calibratedWhite: 0.88, alpha: 1)
        : isPointerInside
          ? NSColor(calibratedWhite: 0.93, alpha: 1)
          : NSColor(calibratedWhite: 0.96, alpha: 1)
    }
    backgroundColor.setFill()
    bounds.fill()

    if drawsLeadingDivider {
      let dividerColor = isDark
        ? NSColor(calibratedWhite: 0.03, alpha: 1)
        : NSColor(calibratedWhite: 0.72, alpha: 1)
      dividerColor.setFill()
      NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    }

    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .center
    paragraphStyle.lineBreakMode = .byTruncatingTail
    let font = NSFont.systemFont(
      ofSize: 11,
      weight: isSelectedTab ? .semibold : .regular
    )
    let foregroundColor: NSColor
    if isDark {
      foregroundColor = isSelectedTab
        ? NSColor(calibratedWhite: 0.94, alpha: 1)
        : NSColor(calibratedWhite: 0.58, alpha: 1)
    } else {
      foregroundColor = isSelectedTab
        ? NSColor(calibratedWhite: 0.12, alpha: 1)
        : NSColor(calibratedWhite: 0.38, alpha: 1)
    }
    let textHeight = ceil(font.ascender - font.descender)
    let textRect = NSRect(
      x: 12,
      y: floor((bounds.height - textHeight) / 2),
      width: max(0, bounds.width - 24),
      height: textHeight
    )
    title.draw(
      with: textRect,
      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
      attributes: [
        .font: font,
        .foregroundColor: foregroundColor,
        .paragraphStyle: paragraphStyle,
      ]
    )
  }
}

/// 中文：描述一个矩形标签的可见状态与选择动作，不持有原生窗口生命周期。
///
/// English: Describes one rectangular tab's visible state and selection action
/// without owning an NSWindow lifecycle.
struct GitDesktopWorkspaceTabDefinition {
  let title: String
  let isSelected: Bool
  let action: () -> Void
}

/// 中文：按窗口组顺序等分整行宽度，组成与 Sourcetree 一致的矩形标签条。
///
/// English: Divides the full row equally in merged-window order to match
/// Sourcetree's compact rectangular workspace strip.
final class GitDesktopWorkspaceTabStripView: NSView {
  private(set) var tabButtons: [GitDesktopWorkspaceTabButton] = []
  private let stackView = NSStackView()

  convenience init(
    windows: [MainFlutterWindow],
    selectedWindow: MainFlutterWindow,
    selectionHandler: @escaping (MainFlutterWindow) -> Void = { window in
      window.makeKeyAndOrderFront(nil)
    }
  ) {
    let tabs = windows.map { window in
      GitDesktopWorkspaceTabDefinition(
        title: window.title,
        isSelected: window === selectedWindow
      ) { [weak window] in
        guard let window else {
          return
        }
        selectionHandler(window)
      }
    }
    self.init(tabs: tabs)
  }

  init(tabs: [GitDesktopWorkspaceTabDefinition]) {
    super.init(
      frame: NSRect(
        x: 0,
        y: 0,
        width: 1,
        height: gitDesktopWorkspaceTabStripHeight
      )
    )
    wantsLayer = true

    stackView.orientation = .horizontal
    stackView.alignment = .height
    stackView.distribution = .fillEqually
    stackView.spacing = 0
    stackView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stackView)
    NSLayoutConstraint.activate([
      stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
      stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
      stackView.topAnchor.constraint(equalTo: topAnchor),
      stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
      heightAnchor.constraint(equalToConstant: gitDesktopWorkspaceTabStripHeight),
    ])

    for (index, tab) in tabs.enumerated() {
      let button = GitDesktopWorkspaceTabButton(
        title: tab.title,
        isSelected: tab.isSelected,
        drawsLeadingDivider: index > 0
      ) {
        tab.action()
      }
      tabButtons.append(button)
      stackView.addArrangedSubview(button)
    }
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let borderColor = isDark
      ? NSColor(calibratedWhite: 0.03, alpha: 1)
      : NSColor(calibratedWhite: 0.70, alpha: 1)
    borderColor.setFill()
    NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
  }
}

/// 中文：返回 Dock 图标在运行时 tile 中的绘制区域。图标资源自身已包含
/// 光学安全边距，因此这里不再添加第二层缩进。
///
/// English: Returns the runtime drawing frame for the Dock icon. The asset
/// already contains its optical safe area, so no second inset is applied.
func gitDesktopDockIconFrame(for bounds: NSRect) -> NSRect {
  bounds
}

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
    // 中文：DockIcon PNG 已包含 macOS 光学安全边距，运行时必须占满
    // Dock tile，避免 flutter run 再次缩进而比相邻应用图标更小。
    //
    // English: DockIcon already contains its macOS optical safe area. Fill
    // the Dock tile so flutter run does not apply a second inset and render
    // the application smaller than neighboring icons.
    imageView.frame = gitDesktopDockIconFrame(for: bounds)
  }
}

/// Receives Finder directory drops without taking normal pointer events away
/// from Flutter's child view.
private final class RepositoryDirectoryDropView: NSView {
  var acceptsDirectoryDrops = false
  var directoryDragStateHandler: ((Bool) -> Void)?
  var directoriesDroppedHandler: (([String]) -> Void)?
  private weak var hostedContentView: NSView?
  private var workspaceTabStripView: GitDesktopWorkspaceTabStripView?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    registerForDraggedTypes([.fileURL])
  }

  required init?(coder: NSCoder) {
    nil
  }

  func installHostedContentView(_ contentView: NSView) {
    hostedContentView?.removeFromSuperview()
    hostedContentView = contentView
    addSubview(contentView)
    needsLayout = true
  }

  func setWorkspaceTabStripView(_ tabStripView: GitDesktopWorkspaceTabStripView?) {
    workspaceTabStripView?.removeFromSuperview()
    workspaceTabStripView = tabStripView
    if let tabStripView {
      addSubview(tabStripView)
    }
    needsLayout = true
  }

  override func layout() {
    super.layout()
    let tabStripHeight = workspaceTabStripView == nil
      ? 0
      : gitDesktopWorkspaceTabStripHeight
    hostedContentView?.frame = NSRect(
      x: 0,
      y: 0,
      width: bounds.width,
      height: max(0, bounds.height - tabStripHeight)
    )
    workspaceTabStripView?.frame = NSRect(
      x: 0,
      y: max(0, bounds.height - tabStripHeight),
      width: bounds.width,
      height: tabStripHeight
    )
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
  var workspaceTabStripView: GitDesktopWorkspaceTabStripView? {
    get { nil }
    set { dropView.setWorkspaceTabStripView(newValue) }
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
    flutterView.autoresizingMask = []
    dropView.installHostedContentView(flutterView)
    view = dropView
  }
}

class MainFlutterWindow: NSWindow {
  private(set) var role = GitDesktopWindowRole.repositoryLibrary
  private(set) var workspaceTabStripView: GitDesktopWorkspaceTabStripView?
  private let delayedBringToFrontActivation =
    GitDesktopDelayedWindowActivation()
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

  /// 中文：为当前合并窗口组安装等分、直角的工作区标签条。
  ///
  /// English: Installs an equal-width rectangular strip for the current merged
  /// window set while preserving each workspace's independent Flutter Engine.
  func configureWorkspaceTabStrip(
    windows: [MainFlutterWindow],
    selectedWindow: MainFlutterWindow,
    selectionHandler: @escaping (MainFlutterWindow) -> Void = { window in
      window.makeKeyAndOrderFront(nil)
    }
  ) {
    guard role == .workspace, windows.count > 1 else {
      removeWorkspaceTabStrip()
      return
    }
    tab.title = title
    tab.toolTip = title
    tab.attributedTitle = nil
    tab.accessoryView = nil

    let tabStripView = GitDesktopWorkspaceTabStripView(
      windows: windows,
      selectedWindow: selectedWindow,
      selectionHandler: selectionHandler
    )
    workspaceTabStripView = tabStripView
    directoryDropContainer?.workspaceTabStripView = tabStripView
  }

  /// 中文：移除已拆分或只剩单窗口时不再需要的自定义标签条。
  ///
  /// English: Removes the custom strip after a group is split or reduced to a
  /// single window.
  func removeWorkspaceTabStrip() {
    guard workspaceTabStripView != nil else {
      return
    }
    workspaceTabStripView = nil
    directoryDropContainer?.workspaceTabStripView = nil
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
    container.workspaceTabStripView = workspaceTabStripView
    contentViewController = container
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if let appDelegate = NSApp.delegate as? AppDelegate,
       appDelegate.handleShortcut(event) {
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  override func selectNextTab(_ sender: Any?) {
    if let appDelegate = NSApp.delegate as? AppDelegate,
       appDelegate.selectAdjacentMergedWorkspace(from: self, offset: 1) {
      return
    }
    super.selectNextTab(sender)
  }

  override func selectPreviousTab(_ sender: Any?) {
    if let appDelegate = NSApp.delegate as? AppDelegate,
       appDelegate.selectAdjacentMergedWorkspace(from: self, offset: -1) {
      return
    }
    super.selectPreviousTab(sender)
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

  /// 中文：取消尚未执行的二次置前，避免窗口隐藏或切换后重新抢占焦点。
  ///
  /// English: Cancels a pending second activation so a hidden or switched
  /// window cannot reclaim focus later.
  func cancelPendingBringToFront() {
    delayedBringToFrontActivation.cancel()
  }

  /// 中文：仅执行一次窗口激活，用于自绘合并标签之间的确定性切换。
  ///
  /// English: Activates the window once without scheduling a second focus
  /// attempt, making custom merged-tab switches deterministic.
  func bringToFrontImmediately() {
    cancelPendingBringToFront()
    if isMiniaturized {
      deminiaturize(nil)
    }
    collectionBehavior.insert(.moveToActiveSpace)
    NSApp.unhide(nil)
    level = .normal
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
    orderFrontRegardless()
  }

  /// 中文：激活普通独立窗口，并在短暂延迟后再置前一次以处理跨空间唤醒。
  ///
  /// English: Activates a standalone window and retries once after a short
  /// delay to handle wake-up across macOS Spaces.
  func bringToFront() {
    cancelPendingBringToFront()
    if isMiniaturized {
      deminiaturize(nil)
    }
    collectionBehavior.insert(.moveToActiveSpace)
    NSApp.unhide(nil)
    level = .floating
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
    orderFrontRegardless()

    delayedBringToFrontActivation.schedule { [weak self] in
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
