import Cocoa
import FlutterMacOS

enum GitDesktopWindowRole {
  case repositoryLibrary
  case workspace
}

private let gitDesktopWorkspaceTabbingIdentifier =
  "com.yeknom.git_desktop.workspace"

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

class MainFlutterWindow: NSWindow {
  private(set) var role = GitDesktopWindowRole.repositoryLibrary

  func configure(role: GitDesktopWindowRole) {
    self.role = role
    title = role == .workspace ? "Git Desktop — Workspace" : "Git Desktop"
    tabbingIdentifier = role == .workspace
      ? gitDesktopWorkspaceTabbingIdentifier
      : ""
    // Workspaces remain separate until the user explicitly chooses the Window
    // menu action. The coordinator enables tabbing only for that merge.
    tabbingMode = .disallowed
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
    contentViewController = flutterViewController
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
