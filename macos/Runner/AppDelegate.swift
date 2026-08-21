import Cocoa
import FlutterMacOS

let gitDesktopWorkspaceActivationNotification = Notification.Name(
  "com.yozoe.gitDesktop.activateRepositoryWorkspace"
)
let gitDesktopRepositoryOpenedNotification = Notification.Name(
  "com.yozoe.gitDesktop.repositoryOpened"
)

func gitDesktopArgumentValue(_ prefix: String) -> String? {
  ProcessInfo.processInfo.arguments.first {
    $0.hasPrefix(prefix)
  }.map {
    String($0.dropFirst(prefix.count))
  }
}

func gitDesktopCanonicalRepositoryPath(_ path: String?) -> String? {
  guard let path, !path.isEmpty else {
    return nil
  }
  return URL(fileURLWithPath: path, isDirectory: true)
    .resolvingSymlinksInPath()
    .standardizedFileURL
    .path
}

@main
class AppDelegate: FlutterAppDelegate {
  private let isWorkspaceProcess = ProcessInfo.processInfo.arguments.contains(
    "--git-desktop-workspace"
  )
  private var workspaceRepositoryPath = gitDesktopCanonicalRepositoryPath(
    gitDesktopArgumentValue("--git-desktop-repository=")
  )
  private var workspaceApplications: [String: NSRunningApplication] = [:]
  private var openingWorkspaceCompletions: [String: [(Error?) -> Void]] = [:]

  override init() {
    super.init()

    // Info.plist launches every process as a UI element so LaunchServices
    // never creates a transient Dock tile for repository workspaces. Promote
    // only the repository library process to a regular foreground app.
    NSApp.setActivationPolicy(isWorkspaceProcess ? .accessory : .regular)

    if let workspaceRepositoryPath {
      registerCurrentWorkspace(repositoryPath: workspaceRepositoryPath)
    }
  }

  /// Launches the same application as a distinct workspace process so each
  /// window owns a stable primary Flutter engine.
  func openWorkspace(
    repositoryPath: String?,
    initialAction: String?,
    completion: @escaping (Error?) -> Void
  ) {
    let canonicalRepositoryPath = gitDesktopCanonicalRepositoryPath(
      repositoryPath
    )
    if let canonicalRepositoryPath {
      if let application = existingWorkspaceApplication(
        for: canonicalRepositoryPath
      ) {
        activateWorkspace(
          application,
          repositoryPath: canonicalRepositoryPath
        )
        completion(nil)
        return
      }
      if openingWorkspaceCompletions[canonicalRepositoryPath] != nil {
        openingWorkspaceCompletions[canonicalRepositoryPath]?.append(completion)
        return
      }
      openingWorkspaceCompletions[canonicalRepositoryPath] = [completion]
    }

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.activates = true
    var arguments = ["--git-desktop-workspace"]
    if let canonicalRepositoryPath {
      arguments.append(
        "--git-desktop-repository=\(canonicalRepositoryPath)"
      )
    }
    if let initialAction, !initialAction.isEmpty {
      arguments.append("--git-desktop-action=\(initialAction)")
    }
    configuration.arguments = arguments
    NSWorkspace.shared.openApplication(
      at: Bundle.main.bundleURL,
      configuration: configuration
    ) { [weak self] application, error in
      DispatchQueue.main.async {
        guard let self else {
          return
        }
        let completions: [(Error?) -> Void]
        if let canonicalRepositoryPath {
          completions = self.openingWorkspaceCompletions.removeValue(
            forKey: canonicalRepositoryPath
          ) ?? [completion]
        } else {
          completions = [completion]
        }
        if let error {
          NSLog(
            "Unable to launch repository workspace: %@",
            error.localizedDescription
          )
          completions.forEach { $0(error) }
          return
        }
        guard let application else {
          let error = NSError(
            domain: "com.yozoe.gitDesktop.workspace",
            code: 1,
            userInfo: [
              NSLocalizedDescriptionKey: "LaunchServices returned no workspace application."
            ]
          )
          completions.forEach { $0(error) }
          return
        }
        if let canonicalRepositoryPath {
          self.workspaceApplications[canonicalRepositoryPath] = application
          self.activateWorkspace(
            application,
            repositoryPath: canonicalRepositoryPath
          )
        } else {
          self.activate(application)
        }
        completions.forEach { $0(nil) }
      }
    }
  }

  /// Associates this workspace process with its successfully opened repository.
  func registerCurrentWorkspace(repositoryPath: String) {
    guard isWorkspaceProcess,
          let canonicalPath = gitDesktopCanonicalRepositoryPath(repositoryPath) else {
      return
    }
    workspaceRepositoryPath = canonicalPath
    let application = NSRunningApplication.current
    UserDefaults.standard.set([
      "pid": Int(application.processIdentifier),
      "launchDate": application.launchDate?.timeIntervalSince1970 ?? 0,
    ], forKey: workspaceRegistryKey(canonicalPath))
  }

  private func workspaceRegistryKey(_ repositoryPath: String) -> String {
    "repositoryWorkspacePID:\(repositoryPath)"
  }

  private func existingWorkspaceApplication(
    for repositoryPath: String
  ) -> NSRunningApplication? {
    if let application = workspaceApplications[repositoryPath] {
      if !application.isTerminated {
        return application
      }
      workspaceApplications.removeValue(forKey: repositoryPath)
    }

    let registryKey = workspaceRegistryKey(repositoryPath)
    let registration = UserDefaults.standard.dictionary(forKey: registryKey)
    let processIdentifier = registration?["pid"] as? Int ?? 0
    let registeredLaunchDate = registration?["launchDate"] as? Double ?? 0
    guard processIdentifier > 0,
          registeredLaunchDate > 0,
          let application = NSRunningApplication(
            processIdentifier: pid_t(processIdentifier)
          ),
          !application.isTerminated,
          let launchDate = application.launchDate,
          abs(launchDate.timeIntervalSince1970 - registeredLaunchDate) < 0.001,
          application.bundleIdentifier == Bundle.main.bundleIdentifier,
          application.bundleURL?.standardizedFileURL
            == Bundle.main.bundleURL.standardizedFileURL else {
      UserDefaults.standard.removeObject(forKey: registryKey)
      return nil
    }

    workspaceApplications[repositoryPath] = application
    return application
  }

  private func activateWorkspace(
    _ application: NSRunningApplication,
    repositoryPath: String
  ) {
    DistributedNotificationCenter.default().postNotificationName(
      gitDesktopWorkspaceActivationNotification,
      object: repositoryPath,
      userInfo: nil,
      deliverImmediately: true
    )
    activate(application)
  }

  private func activate(_ application: NSRunningApplication) {
    application.unhide()
    application.activate(
      options: [.activateAllWindows, .activateIgnoringOtherApps]
    )
  }

  override func applicationWillTerminate(_ notification: Notification) {
    if isWorkspaceProcess, let workspaceRepositoryPath {
      let registryKey = workspaceRegistryKey(workspaceRepositoryPath)
      let registration = UserDefaults.standard.dictionary(forKey: registryKey)
      let registeredPID = registration?["pid"] as? Int ?? 0
      if registeredPID == Int(ProcessInfo.processInfo.processIdentifier) {
        UserDefaults.standard.removeObject(forKey: registryKey)
      }
    }
    super.applicationWillTerminate(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
