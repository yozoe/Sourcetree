import Cocoa
import FlutterMacOS

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
  private var isWorkspaceProcess = false
  private var workspaceRepositoryPath: String?
  private var windowChannel: FlutterMethodChannel?

  deinit {
    DistributedNotificationCenter.default().removeObserver(self)
  }

  override func awakeFromNib() {
    isWorkspaceProcess = ProcessInfo.processInfo.arguments.contains(
      "--git-desktop-workspace"
    )
    workspaceRepositoryPath = gitDesktopCanonicalRepositoryPath(
      gitDesktopArgumentValue("--git-desktop-repository=")
    )
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    self.setContentSize(NSSize(width: 1280, height: 800))
    self.minSize = NSSize(width: 900, height: 600)
    self.center()
    self.title = isWorkspaceProcess
      ? "Git Desktop — Workspace"
      : "Git Desktop"

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()

    if isWorkspaceProcess {
      DistributedNotificationCenter.default().addObserver(
        self,
        selector: #selector(handleWorkspaceActivation(_:)),
        name: gitDesktopWorkspaceActivationNotification,
        object: nil,
        suspensionBehavior: .deliverImmediately
      )
    } else {
      DistributedNotificationCenter.default().addObserver(
        self,
        selector: #selector(handleRepositoryOpened(_:)),
        name: gitDesktopRepositoryOpenedNotification,
        object: nil,
        suspensionBehavior: .deliverImmediately
      )
    }

    windowChannel = FlutterMethodChannel(
      name: "com.yeknom.git_desktop/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    windowChannel?.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      let arguments = call.arguments as? [String: Any]
      let repositoryPath = arguments?["repositoryPath"] as? String
      switch call.method {
      case "openWorkspace":
        let initialAction = arguments?["initialAction"] as? String
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
          result(
            FlutterError(
              code: "window_host_unavailable",
              message: "The macOS window host is unavailable.",
              details: nil
            )
          )
          return
        }
        appDelegate.openWorkspace(
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
        guard self.isWorkspaceProcess,
              let repositoryPath = gitDesktopCanonicalRepositoryPath(
                repositoryPath
              ),
              let appDelegate = NSApp.delegate as? AppDelegate else {
          result(
            FlutterError(
              code: "invalid_repository_registration",
              message: "The workspace repository could not be registered.",
              details: nil
            )
          )
          return
        }
        self.workspaceRepositoryPath = repositoryPath
        appDelegate.registerCurrentWorkspace(repositoryPath: repositoryPath)
        DistributedNotificationCenter.default().postNotificationName(
          gitDesktopRepositoryOpenedNotification,
          object: repositoryPath,
          userInfo: nil,
          deliverImmediately: true
        )
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    DispatchQueue.main.async {
      guard !self.isWorkspaceProcess else {
        // The repository window is a Dock-less accessory process. The launch
        // configuration activates it, and ordering it here ensures the new
        // workspace receives focus as soon as Flutter is ready.
        self.bringWorkspaceToFront()
        return
      }
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
  }

  @objc private func handleWorkspaceActivation(_ notification: Notification) {
    guard let requestedPath = notification.object as? String,
          requestedPath == workspaceRepositoryPath else {
      return
    }
    bringWorkspaceToFront()
  }

  @objc private func handleRepositoryOpened(_ notification: Notification) {
    guard !isWorkspaceProcess,
          let repositoryPath = notification.object as? String else {
      return
    }
    windowChannel?.invokeMethod(
      "repositoryOpened",
      arguments: ["repositoryPath": repositoryPath]
    )
  }

  private func bringWorkspaceToFront() {
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
