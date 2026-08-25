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
/// Internal pasteboard type that confines workspace-tab drags to this app.
/// 中文：限制工作区标签拖动只在本应用标签条内识别的内部剪贴板类型。
private let gitDesktopWorkspaceTabDragType = NSPasteboard.PasteboardType(
  "com.yeknom.git-desktop.workspace-tab"
)

/// 中文：返回标签拖动松手位置对应的最终索引，索引按移除源标签后计算。
///
/// English: Returns the final tab index for a drop location, calculated after
/// removing the source tab from the ordered collection.
func gitDesktopWorkspaceTabDropIndex(
  locationX: CGFloat,
  stripWidth: CGFloat,
  tabCount: Int,
  sourceIndex: Int
) -> Int? {
  guard stripWidth > 0,
        tabCount > 1,
        sourceIndex >= 0,
        sourceIndex < tabCount else {
    return nil
  }
  let segmentWidth = stripWidth / CGFloat(tabCount)
  let boundedX = min(max(0, locationX), stripWidth)
  let insertionIndex = min(
    tabCount,
    max(0, Int(floor((boundedX / segmentWidth) + 0.5)))
  )
  let destinationIndex = insertionIndex > sourceIndex
    ? insertionIndex - 1
    : insertionIndex
  return min(tabCount - 1, max(0, destinationIndex))
}

/// 中文：把一个有序集合中的元素移动到最终索引，无效索引保持原顺序。
///
/// English: Moves one element in an ordered collection to its final index,
/// preserving the original order when either index is invalid.
func gitDesktopMovingItem<Element>(
  in elements: [Element],
  from sourceIndex: Int,
  to destinationIndex: Int
) -> [Element] {
  guard elements.indices.contains(sourceIndex),
        elements.indices.contains(destinationIndex),
        sourceIndex != destinationIndex else {
    return elements
  }
  var result = elements
  let element = result.remove(at: sourceIndex)
  result.insert(element, at: destinationIndex)
  return result
}

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

/// 中文：绘制工作区标签内的独立关闭按钮，并把关闭动作交给对应窗口。
///
/// English: Draws the close control inside a workspace tab and delegates the
/// close action to the represented window.
final class GitDesktopWorkspaceTabCloseButton: NSButton {
  private let actionHandler: () -> Void

  init(tabTitle: String, action: @escaping () -> Void) {
    actionHandler = action
    super.init(frame: .zero)
    title = ""
    image = NSImage(
      systemSymbolName: "xmark",
      accessibilityDescription: nil
    )?.withSymbolConfiguration(
      NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
    )
    imagePosition = .imageOnly
    imageScaling = .scaleProportionallyDown
    contentTintColor = .secondaryLabelColor
    isBordered = false
    focusRingType = .none
    setButtonType(.momentaryPushIn)
    toolTip = "关闭 \(tabTitle)"
    target = self
    self.action = #selector(closeTab)
    setAccessibilityLabel("关闭 \(tabTitle)")
  }

  required init?(coder: NSCoder) {
    nil
  }

  @objc private func closeTab() {
    actionHandler()
  }

  /// 中文：仓库标题变化时同步关闭按钮的提示与辅助功能名称。
  ///
  /// English: Synchronizes the close button's tooltip and accessibility label
  /// after the repository title changes.
  func updateTabTitle(_ tabTitle: String) {
    toolTip = "关闭 \(tabTitle)"
    setAccessibilityLabel("关闭 \(tabTitle)")
  }
}

/// 中文：绘制工作区标签条中的单个等宽矩形标签，并把点击交还给窗口协调器。
///
/// English: Draws one equal-width rectangular workspace tab while the window
/// coordinator preserves each workspace's independent lifecycle.
final class GitDesktopWorkspaceTabButton: NSButton {
  private(set) var isSelectedTab: Bool
  let drawsLeadingDivider: Bool
  private(set) var closeButton: GitDesktopWorkspaceTabCloseButton!
  private var isPointerInside = false
  private let dragAction: ((NSEvent) -> Void)?

  init(
    title: String,
    isSelected: Bool,
    drawsLeadingDivider: Bool,
    closeAction: @escaping () -> Void,
    dragAction: ((NSEvent) -> Void)? = nil,
    action: @escaping () -> Void
  ) {
    isSelectedTab = isSelected
    self.drawsLeadingDivider = drawsLeadingDivider
    self.actionHandler = action
    self.dragAction = dragAction
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

    let closeButton = GitDesktopWorkspaceTabCloseButton(
      tabTitle: title,
      action: closeAction
    )
    closeButton.translatesAutoresizingMaskIntoConstraints = false
    addSubview(closeButton)
    NSLayoutConstraint.activate([
      closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
      closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      closeButton.widthAnchor.constraint(equalToConstant: 18),
      closeButton.heightAnchor.constraint(equalToConstant: 18),
    ])
    self.closeButton = closeButton
  }

  required init?(coder: NSCoder) {
    nil
  }

  private let actionHandler: () -> Void

  @objc private func activateTab() {
    actionHandler()
  }

  /// 中文：区分普通点击和越过阈值的拖动，避免轻微抖动误触排序。
  ///
  /// English: Distinguishes a normal click from a threshold-crossing drag so
  /// small pointer movement does not accidentally reorder tabs.
  override func mouseDown(with event: NSEvent) {
    guard let dragAction, let window else {
      super.mouseDown(with: event)
      return
    }
    let initialLocation = convert(event.locationInWindow, from: nil)
    while let nextEvent = window.nextEvent(
      matching: [.leftMouseUp, .leftMouseDragged]
    ) {
      let location = convert(nextEvent.locationInWindow, from: nil)
      switch nextEvent.type {
      case .leftMouseDragged:
        let distance = hypot(
          location.x - initialLocation.x,
          location.y - initialLocation.y
        )
        if distance >= 4 {
          dragAction(nextEvent)
          return
        }
      case .leftMouseUp:
        if bounds.contains(location) {
          performClick(nil)
        }
        return
      default:
        return
      }
    }
  }

  /// 中文：原位更新标签选中态，避免切换仓库时重建视图层级。
  ///
  /// English: Updates selection in place so repository switches do not
  /// rebuild the tab view hierarchy.
  func updateSelection(_ isSelected: Bool) {
    guard isSelectedTab != isSelected else {
      return
    }
    isSelectedTab = isSelected
    setAccessibilityValue(isSelected)
    needsDisplay = true
  }

  /// 中文：原位同步仓库标题及其提示，不重建标签和 Flutter 内容布局。
  ///
  /// English: Synchronizes the repository title and hints in place without
  /// rebuilding the tab or Flutter content layout.
  func updateTitle(_ title: String) {
    guard self.title != title else {
      return
    }
    self.title = title
    toolTip = title
    setAccessibilityLabel(title)
    closeButton.updateTabTitle(title)
    needsDisplay = true
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
      x: 28,
      y: floor((bounds.height - textHeight) / 2),
      width: max(0, bounds.width - 56),
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
/// Describes one visible workspace tab and its selection, close and reorder
/// callbacks.
///
/// 中文：描述一个可见工作区标签及其选中、关闭和排序回调；回调只引用当前存活的
/// 窗口，避免旧标签条保留已关闭窗口。
struct GitDesktopWorkspaceTabDefinition {
  let title: String
  let isSelected: Bool
  let closeAction: () -> Void
  let moveAction: ((Int) -> Void)?
  let action: () -> Void

  /// Creates an immutable tab definition for one workspace window snapshot.
  ///
  /// 中文：为一个工作区窗口快照创建不可变标签定义；未提供排序回调时该标签不
  /// 接受拖动排序。
  init(
    title: String,
    isSelected: Bool,
    closeAction: @escaping () -> Void,
    moveAction: ((Int) -> Void)? = nil,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.isSelected = isSelected
    self.closeAction = closeAction
    self.moveAction = moveAction
    self.action = action
  }
}

/// Draws the non-interactive insertion marker for an in-strip tab drag.
///
/// 中文：绘制标签条内部拖动时的非交互插入标记，不参与命中测试或改变标签选择。
private final class GitDesktopWorkspaceTabDropIndicatorView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.controlAccentColor.setFill()
    bounds.fill()
  }
}

/// 中文：按窗口组顺序等分整行宽度，组成与 Sourcetree 一致的矩形标签条。
///
/// English: Divides the full row equally in merged-window order to match
/// Sourcetree's compact rectangular workspace strip.
final class GitDesktopWorkspaceTabStripView: NSView, NSDraggingSource {
  private(set) var tabButtons: [GitDesktopWorkspaceTabButton] = []
  private var windowIdentifiers: [ObjectIdentifier]?
  private var moveActions: [((Int) -> Void)?] = []
  private var draggedTabIndex: Int?
  private var dropDestinationIndex: Int?
  private let dragSessionIdentifier = UUID().uuidString
  private let stackView = NSStackView()
  private let dropIndicatorView = GitDesktopWorkspaceTabDropIndicatorView()

  convenience init(
    windows: [MainFlutterWindow],
    selectedWindow: MainFlutterWindow,
    selectionHandler: @escaping (MainFlutterWindow) -> Void = { window in
      window.makeKeyAndOrderFront(nil)
    },
    reorderHandler: @escaping (MainFlutterWindow, Int) -> Void = { _, _ in }
  ) {
    let tabs = windows.map { window in
      GitDesktopWorkspaceTabDefinition(
        title: window.title,
        isSelected: window === selectedWindow,
        closeAction: { [weak window] in
          window?.performClose(nil)
        },
        moveAction: { [weak window] destinationIndex in
          guard let window else {
            return
          }
          reorderHandler(window, destinationIndex)
        }
      ) { [weak window] in
        guard let window else {
          return
        }
        selectionHandler(window)
      }
    }
    self.init(tabs: tabs)
    windowIdentifiers = windows.map(ObjectIdentifier.init)
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
    registerForDraggedTypes([gitDesktopWorkspaceTabDragType])

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

    dropIndicatorView.isHidden = true
    addSubview(dropIndicatorView)

    for (index, tab) in tabs.enumerated() {
      let dragAction: ((NSEvent) -> Void)? = tab.moveAction == nil
        ? nil
        : { [weak self] event in
          self?.beginDraggingTab(at: index, event: event)
        }
      let button = GitDesktopWorkspaceTabButton(
        title: tab.title,
        isSelected: tab.isSelected,
        drawsLeadingDivider: index > 0,
        closeAction: tab.closeAction,
        dragAction: dragAction
      ) {
        tab.action()
      }
      button.translatesAutoresizingMaskIntoConstraints = false
      tabButtons.append(button)
      moveActions.append(tab.moveAction)
      stackView.addArrangedSubview(button)
      button.heightAnchor.constraint(equalTo: stackView.heightAnchor).isActive =
        true
    }
  }

  /// 中文：判断现有标签条是否仍对应相同顺序的工作区窗口。
  ///
  /// English: Returns whether this strip still represents the same ordered
  /// workspace windows.
  func represents(windows: [MainFlutterWindow]) -> Bool {
    windowIdentifiers == windows.map(ObjectIdentifier.init)
  }

  /// 中文：原位同步全部仓库标题与目标窗口选中态，不触发布局或内容缩放。
  ///
  /// English: Synchronizes repository titles and the target selection state
  /// in place without triggering layout or content scaling.
  func updateContent(
    windows: [MainFlutterWindow],
    selectedWindow: MainFlutterWindow
  ) {
    guard let windowIdentifiers,
          let selectedIndex = windowIdentifiers.firstIndex(
            of: ObjectIdentifier(selectedWindow)
          ),
          windows.count == tabButtons.count else {
      return
    }
    for (index, pair) in zip(tabButtons, windows).enumerated() {
      let (button, window) = pair
      button.updateTitle(window.title)
      button.updateSelection(index == selectedIndex)
    }
  }

  required init?(coder: NSCoder) {
    nil
  }

  /// 中文：以当前标签快照开始原生拖动会话，只允许在本标签条内移动。
  ///
  /// English: Begins a native drag session with the current tab snapshot and
  /// permits moves only inside this strip.
  private func beginDraggingTab(at index: Int, event: NSEvent) {
    guard tabButtons.indices.contains(index), moveActions[index] != nil else {
      return
    }
    let button = tabButtons[index]
    guard let representation = button.bitmapImageRepForCachingDisplay(
      in: button.bounds
    ) else {
      return
    }
    button.cacheDisplay(in: button.bounds, to: representation)
    let image = NSImage(size: button.bounds.size)
    image.addRepresentation(representation)

    let pasteboardItem = NSPasteboardItem()
    pasteboardItem.setString(
      dragSessionIdentifier,
      forType: gitDesktopWorkspaceTabDragType
    )
    let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
    draggingItem.setDraggingFrame(
      convert(button.bounds, from: button),
      contents: image
    )
    draggedTabIndex = index
    beginDraggingSession(with: [draggingItem], event: event, source: self)
  }

  /// 中文：声明标签拖动只执行移动，不复制工作区窗口。
  ///
  /// English: Declares that tab drags move rather than copy workspace windows.
  func draggingSession(
    _ session: NSDraggingSession,
    sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    .move
  }

  /// 中文：拖动结束后清除暂存索引和插入位置提示。
  ///
  /// English: Clears the pending indices and insertion indicator when a drag
  /// session ends.
  func draggingSession(
    _ session: NSDraggingSession,
    endedAt screenPoint: NSPoint,
    operation: NSDragOperation
  ) {
    clearDropState(clearSource: true)
  }

  /// 中文：拖动进入标签条时验证来源并计算插入位置。
  /// English: Validates the source and calculates an insertion position when
  /// a tab drag enters this strip.
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    updateDropDestination(sender)
  }

  /// 中文：拖动在标签条内移动时更新插入提示。
  /// English: Updates the insertion marker while the drag moves inside this
  /// strip.
  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    updateDropDestination(sender)
  }

  /// 中文：拖动离开标签条时隐藏插入提示，但保留来源用于可能的重新进入。
  /// English: Hides the insertion marker when a drag leaves this strip while
  /// retaining its source for a possible re-entry.
  override func draggingExited(_ sender: NSDraggingInfo?) {
    clearDropState(clearSource: false)
  }

  /// 中文：仅当来源和目标索引均有效且确实改变顺序时接受拖动。
  /// English: Accepts a drag only when source and destination are valid and
  /// would change the order.
  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    updateDropDestination(sender) == .move &&
      dropDestinationIndex != draggedTabIndex
  }

  /// 中文：提交一次有效排序并将新索引交给窗口协调器持久化。
  /// English: Commits one valid reorder and delegates its new index to the
  /// window coordinator for persistence.
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    guard updateDropDestination(sender) == .move,
          let sourceIndex = draggedTabIndex,
          let destinationIndex = dropDestinationIndex,
          sourceIndex != destinationIndex,
          moveActions.indices.contains(sourceIndex),
          let moveAction = moveActions[sourceIndex] else {
      clearDropState(clearSource: false)
      return false
    }
    clearDropState(clearSource: false)
    moveAction(destinationIndex)
    return true
  }

  /// 中文：验证拖动来源并更新最终目标索引和可见插入线。
  ///
  /// English: Validates the drag source and updates the final destination index
  /// and visible insertion marker.
  private func updateDropDestination(
    _ sender: NSDraggingInfo
  ) -> NSDragOperation {
    guard sender.draggingPasteboard.string(
      forType: gitDesktopWorkspaceTabDragType
    ) == dragSessionIdentifier,
      let sourceIndex = draggedTabIndex,
      let destinationIndex = gitDesktopWorkspaceTabDropIndex(
        locationX: convert(sender.draggingLocation, from: nil).x,
        stripWidth: bounds.width,
        tabCount: tabButtons.count,
        sourceIndex: sourceIndex
      ) else {
      clearDropState(clearSource: false)
      return []
    }
    dropDestinationIndex = destinationIndex
    let segmentWidth = bounds.width / CGFloat(tabButtons.count)
    if destinationIndex == sourceIndex {
      dropIndicatorView.isHidden = true
    } else {
      let indicatorX = destinationIndex > sourceIndex
        ? CGFloat(destinationIndex + 1) * segmentWidth
        : CGFloat(destinationIndex) * segmentWidth
      dropIndicatorView.frame = NSRect(
        x: min(max(0, indicatorX - 1), max(0, bounds.width - 2)),
        y: 0,
        width: 2,
        height: bounds.height
      )
      dropIndicatorView.isHidden = false
    }
    return .move
  }

  /// 中文：清理插入提示；会话真正结束时同时丢弃来源索引。
  /// English: Clears the insertion marker, dropping the source index only
  /// when the drag session has actually ended.
  private func clearDropState(clearSource: Bool) {
    if clearSource {
      draggedTabIndex = nil
    }
    dropDestinationIndex = nil
    dropIndicatorView.isHidden = true
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
  private var animationBehaviorBeforeWorkspaceMerge: AnimationBehavior?
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
    // 工作区在用户从“窗口”菜单明确合并前始终彼此独立；仅协调器可为该合并启用
    // 原生标签能力，避免系统自动合并不同 Flutter Engine。
    tabbingMode = .disallowed
    directoryDropContainer?.acceptsDirectoryDrops =
      role == .repositoryLibrary
  }

  /// 中文：为当前合并窗口组安装等分、直角的工作区标签条。
  ///
  /// English: Installs an equal-width rectangular strip for the current merged
  /// window set while preserving each workspace's independent Flutter Engine
  /// and routing valid reorders back to the coordinator.
  func configureWorkspaceTabStrip(
    windows: [MainFlutterWindow],
    selectedWindow: MainFlutterWindow,
    selectionHandler: @escaping (MainFlutterWindow) -> Void = { window in
      window.makeKeyAndOrderFront(nil)
    },
    reorderHandler: @escaping (MainFlutterWindow, Int) -> Void = { _, _ in }
  ) {
    guard role == .workspace, windows.count > 1 else {
      removeWorkspaceTabStrip()
      return
    }
    tab.title = title
    tab.toolTip = title
    tab.attributedTitle = nil
    tab.accessoryView = nil

    if animationBehaviorBeforeWorkspaceMerge == nil {
      animationBehaviorBeforeWorkspaceMerge = animationBehavior
    }
    animationBehavior = .none

    if let workspaceTabStripView,
       workspaceTabStripView.represents(windows: windows) {
      workspaceTabStripView.updateContent(
        windows: windows,
        selectedWindow: selectedWindow
      )
      return
    }

    let tabStripView = GitDesktopWorkspaceTabStripView(
      windows: windows,
      selectedWindow: selectedWindow,
      selectionHandler: selectionHandler,
      reorderHandler: reorderHandler
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
    if let animationBehaviorBeforeWorkspaceMerge {
      animationBehavior = animationBehaviorBeforeWorkspaceMerge
      self.animationBehaviorBeforeWorkspaceMerge = nil
    }
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
