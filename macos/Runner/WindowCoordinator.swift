import Cocoa
import FlutterMacOS
import QuickLookUI

final class WindowCoordinator {
  private weak var repositoryLibraryWindow: MainFlutterWindow?
  private var repositoryLibraryChannel: FlutterMethodChannel?
  private let workspaceIndex =
    GitDesktopWorkspaceIndex<WorkspaceFlutterWindowController>()
  private let workspaceHistory =
    GitDesktopWorkspaceHistory<WorkspaceFlutterWindowController>()
  private let windowFocusHistory = GitDesktopWindowFocusHistory<MainFlutterWindow>()
  private let workspaceRestoreStore: GitDesktopWorkspaceRestoreStore
  private let repositoryLibraryPendingStore:
    GitDesktopRepositoryLibraryPendingStore
  private let windowSizeStore: GitDesktopWindowSizeStore
  private var repositoryLibraryResizeObserver: NSObjectProtocol?
  private var repositoryLibraryCloseObserver: NSObjectProtocol?
  private var screenParametersObserver: NSObjectProtocol?
  private var unregisteredWorkspaces: [
    ObjectIdentifier: WorkspaceFlutterWindowController
  ] = [:]
  /// Each entry is one independent merged-window group.
  /// 中文：每个元素代表一个相互独立的合并窗口组。
  private var mergedWorkspaceGroups: [[ObjectIdentifier]] = []
  private var activeMergedWorkspaceGroupIndex = 0
  private weak var selectedMergedWorkspaceWindow: MainFlutterWindow?
  private var isMergedWorkspaceTabStripVisible = true
  private var isActivatingMergedWorkspace = false
  private var workspaceTabOverviewController:
    GitDesktopWorkspaceTabOverviewWindowController?
  private let workspaceRestorationGate =
    GitDesktopWorkspaceRestorationGate()
  private var workspaceRestorationTimeoutWorkItem: DispatchWorkItem?
  private var didRequestWorkspaceRestoration = false
  private var isTerminating = false
  private var restoredMergedWorkspacePathGroups: [[String]] = []

  /// The currently selected merged group, kept as a computed compatibility
  /// surface for the existing tab-management code.
  /// 中文：当前选中的合并组，作为现有标签管理代码的兼容访问面。
  private var mergedWorkspaceOrder: [ObjectIdentifier] {
    get {
      guard mergedWorkspaceGroups.indices.contains(activeMergedWorkspaceGroupIndex)
      else { return [] }
      return mergedWorkspaceGroups[activeMergedWorkspaceGroupIndex]
    }
    set {
      guard !mergedWorkspaceGroups.isEmpty else {
        guard !newValue.isEmpty else { return }
        mergedWorkspaceGroups = [newValue]
        activeMergedWorkspaceGroupIndex = 0
        return
      }
      if newValue.isEmpty {
        mergedWorkspaceGroups.remove(at: activeMergedWorkspaceGroupIndex)
        activeMergedWorkspaceGroupIndex = min(
          activeMergedWorkspaceGroupIndex,
          max(0, mergedWorkspaceGroups.count - 1)
        )
        return
      }
      mergedWorkspaceGroups[activeMergedWorkspaceGroupIndex] = newValue
      if newValue.count < 2 {
        mergedWorkspaceGroups.remove(at: activeMergedWorkspaceGroupIndex)
        activeMergedWorkspaceGroupIndex = min(
          activeMergedWorkspaceGroupIndex,
          max(0, mergedWorkspaceGroups.count - 1)
        )
      }
    }
  }

  /// 中文：创建窗口协调器，并注入可独立测试的恢复、登记与尺寸偏好存储。
  ///
  /// English: Creates the window coordinator with independently testable
  /// restoration, registration, and size-preference stores.
  init(
    workspaceRestoreStore: GitDesktopWorkspaceRestoreStore =
      GitDesktopWorkspaceRestoreStore(),
    repositoryLibraryPendingStore: GitDesktopRepositoryLibraryPendingStore =
      GitDesktopRepositoryLibraryPendingStore(),
    windowSizeStore: GitDesktopWindowSizeStore = GitDesktopWindowSizeStore()
  ) {
    self.workspaceRestoreStore = workspaceRestoreStore
    self.repositoryLibraryPendingStore = repositoryLibraryPendingStore
    self.windowSizeStore = windowSizeStore
    screenParametersObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.recoverWindowsAfterScreenParametersChange()
    }
  }

  deinit {
    removeRepositoryLibraryWindowObservers()
    if let screenParametersObserver {
      NotificationCenter.default.removeObserver(screenParametersObserver)
    }
  }

  /// 中文：连接首页 Engine，恢复仓库浏览器尺寸并安装有界的尺寸保存监听。
  ///
  /// English: Attaches the home Engine, restores the repository-library size,
  /// and installs bounded size-persistence observers.
  func attachRepositoryLibrary(
    window: MainFlutterWindow,
    flutterViewController: FlutterViewController
  ) {
    repositoryLibraryChannel?.setMethodCallHandler(nil)
    removeRepositoryLibraryWindowObservers()
    repositoryLibraryWindow = window
    window.configure(role: .repositoryLibrary)
    restoreContentSize(of: window, for: .repositoryLibrary)
    window.center()
    repositoryLibraryResizeObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didEndLiveResizeNotification,
      object: window,
      queue: .main
    ) { [weak self, weak window] _ in
      guard let self, let window else {
        return
      }
      self.saveContentSize(of: window, for: .repositoryLibrary)
    }
    repositoryLibraryCloseObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification,
      object: window,
      queue: .main
    ) { [weak self, weak window] _ in
      guard let self, let window else {
        return
      }
      self.saveContentSize(of: window, for: .repositoryLibrary)
    }

    let channel = FlutterMethodChannel(
      name: "com.yeknom.git_desktop/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    window.directoryDragStateHandler = { isActive in
      channel.invokeMethod(
        "repositoryDirectoryDragState",
        arguments: ["isActive": isActive]
      )
    }
    window.directoriesDroppedHandler = { paths in
      channel.invokeMethod(
        "repositoryDirectoriesDropped",
        arguments: ["paths": paths]
      )
    }
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(
          FlutterError(
            code: "window_host_unavailable",
            message: "The macOS window host is unavailable.",
            details: nil
          )
        )
        return
      }
      let arguments = call.arguments as? [String: Any]
      switch call.method {
      case "openWorkspace":
        self.openWorkspace(
          repositoryPath: arguments?["repositoryPath"] as? String,
          initialAction: arguments?["initialAction"] as? String
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
      case "repositoryLibraryReady":
        self.flushPendingRepositoryLibraryRegistrations()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    repositoryLibraryChannel = channel
    restoreOpenWorkspacesAfterLaunch()
  }

  /// 中文：按窗口角色恢复内容区尺寸，并限制在当前屏幕可见范围内。
  ///
  /// English: Restores a role-specific content size constrained to the current
  /// screen's visible bounds.
  func restoreContentSize(
    of window: NSWindow,
    for role: GitDesktopWindowRole
  ) {
    let defaultSize = NSSize(width: 1280, height: 800)
    let minimumSize = NSSize(width: 900, height: 600)
    let maximumSize = (window.screen ?? NSScreen.main).map { screen in
      window.contentRect(forFrameRect: screen.visibleFrame).size
    }
    window.setContentSize(
      windowSizeStore.restoredSize(
        for: role,
        default: defaultSize,
        minimum: minimumSize,
        maximum: maximumSize
      )
    )
  }

  /// 中文：保存指定角色窗口的当前内容区尺寸，供后续启动恢复。
  ///
  /// English: Saves a role-specific window's current content size for a later
  /// launch.
  func saveContentSize(
    of window: NSWindow,
    for role: GitDesktopWindowRole
  ) {
    windowSizeStore.save(window.contentLayoutRect.size, for: role)
  }

  /// 中文：移除旧首页窗口的尺寸监听，防止重建首页后收到失效回调。
  ///
  /// English: Removes size observers for the old home window so a replacement
  /// cannot receive stale callbacks.
  private func removeRepositoryLibraryWindowObservers() {
    if let repositoryLibraryResizeObserver {
      NotificationCenter.default.removeObserver(repositoryLibraryResizeObserver)
      self.repositoryLibraryResizeObserver = nil
    }
    if let repositoryLibraryCloseObserver {
      NotificationCenter.default.removeObserver(repositoryLibraryCloseObserver)
      self.repositoryLibraryCloseObserver = nil
    }
  }

  func openWorkspace(
    repositoryPath: String?,
    initialAction: String?,
    restoresPreviouslyOpenWorkspace: Bool = false,
    restoresMergedWorkspace: Bool = false,
    completion: @escaping (Error?) -> Void
  ) {
    let canonicalPath = gitDesktopCanonicalRepositoryPath(repositoryPath)
    if let canonicalPath,
       let existing = workspaceIndex.host(for: canonicalPath) {
      workspaceHistory.markRecent(existing)
      if restoresPreviouslyOpenWorkspace {
        existing.showForRestoration()
      } else {
        existing.showAndActivate()
      }
      completion(nil)
      return
    }

    do {
      let controller = try WorkspaceFlutterWindowController(
        repositoryPath: canonicalPath,
        initialAction: initialAction,
        restoresPreviouslyOpenWorkspace: restoresPreviouslyOpenWorkspace,
        restoresMergedWorkspace: restoresMergedWorkspace,
        coordinator: self
      )
      if let canonicalPath {
        workspaceIndex.register(controller, for: canonicalPath)
      } else {
        unregisteredWorkspaces[ObjectIdentifier(controller)] = controller
      }
      workspaceHistory.markRecent(controller)
      if restoresPreviouslyOpenWorkspace {
        controller.showForRestoration()
      } else {
        controller.showAndActivate()
      }
      completion(nil)
    } catch {
      completion(error)
    }
  }

  /// Sends a menu action only to the workspace that currently owns keyboard
  /// focus. A repository-library window must never mutate a background repo.
  func performWorkspaceAction(_ action: String) {
    currentWorkspaceController?.performWorkspaceAction(action)
  }

  /// Read-only file targets for the workspace that currently owns focus.
  /// 中文：当前获得焦点的工作区提供的只读文件目标。
  var currentWorkspaceFileMenuTargets: GitDesktopWorkspaceFileMenuTargets? {
    currentWorkspaceController?.fileMenuTargets
  }

  /// 中文：当前选择是否可由系统默认应用打开。
  /// English: Whether the current selection can be opened by its default app.
  var canOpenSelectedFileFromMenu: Bool {
    currentWorkspaceFileMenuTargets?.existingSelectedURLs().count == 1
  }

  /// 中文：当前文件选择或仓库根目录是否可在 Finder 中定位。
  /// English: Whether Finder can reveal the selection or repository root.
  var canRevealFileFromMenu: Bool {
    guard let targets = currentWorkspaceFileMenuTargets else { return false }
    if targets.hasFileSelection {
      return !targets.existingSelectedURLs().isEmpty
    }
    return targets.existingRepositoryRootURL() != nil
  }

  /// 中文：当前工作区是否有可安全传给 Terminal 的单一目录。
  /// English: Whether the workspace exposes one safe directory to Terminal.
  var canOpenTerminalFromMenu: Bool {
    currentWorkspaceFileMenuTargets?.terminalDirectoryURL() != nil
  }

  /// 中文：当前选择是否包含可由 Quick Look 预览的现存文件。
  /// English: Whether the selection contains existing Quick Look targets.
  var canQuickLookSelectedFilesFromMenu: Bool {
    !(currentWorkspaceFileMenuTargets?.existingSelectedURLs().isEmpty ?? true)
  }

  /// Whether the native Action menu can safely address the key workspace.
  var canPerformWorkspaceAction: Bool {
    currentWorkspaceController != nil
  }

  /// Whether the key workspace has a Flutter-validated tracked file selected.
  /// 中文：当前前台工作区是否已由 Flutter 校验出可停止追踪的已跟踪文件。
  var canStopTrackingFromMenu: Bool {
    gitDesktopCanPerformStopTrackingMenuAction(
      hasKeyWorkspace: currentWorkspaceController != nil,
      hasValidatedTrackedSelection:
        currentWorkspaceController?.canStopTrackingFromMenu == true
    )
  }

  /// Whether the key workspace currently permits applying a patch.
  /// 中文：当前前台工作区是否已由 Flutter 校验为允许应用补丁。
  var canApplyPatchFromMenu: Bool {
    gitDesktopCanPerformApplyPatchMenuAction(
      hasKeyWorkspace: currentWorkspaceController != nil,
      hasRepositoryMutationCapability:
        currentWorkspaceController?.canApplyPatchFromMenu == true
    )
  }

  /// Whether the key workspace currently permits adding a local Git remote.
  /// 中文：当前前台工作区是否允许添加一个本地 Git 远端配置。
  var canAddRemoteFromMenu: Bool {
    currentWorkspaceController?.canAddRemoteFromMenu == true
  }

  /// Whether the key workspace currently offers a safe checkout target.
  /// 中文：当前前台工作区是否至少有一个可选择的安全检出目标。
  var canCheckoutFromMenu: Bool {
    currentWorkspaceController?.canCheckoutFromMenu == true
  }

  /// Whether the key workspace has tracked content for Commit All.
  /// 中文：当前前台工作区是否有可供“提交所有”处理的已跟踪内容。
  var canCommitAllFromMenu: Bool {
    currentWorkspaceController?.canCommitAllFromMenu == true
  }

  /// Whether the key workspace has a validated visible file selection.
  /// 中文：当前前台工作区是否有经过校验、可用于提交的可见文件选择。
  var canCommitSelectedFromMenu: Bool {
    currentWorkspaceController?.canCommitSelectedFromMenu == true
  }

  /// The key workspace's active recoverable Git operation.
  /// 中文：当前前台工作区正在进行、可恢复的 Git 操作。
  var activeRepositoryOperationFromMenu: GitDesktopRepositoryOperation? {
    currentWorkspaceController?.activeRepositoryOperationFromMenu
  }

  /// Whether the active Git operation can continue after conflict resolution.
  /// 中文：当前 Git 操作是否可在冲突解决后继续。
  var canContinueOperationFromMenu: Bool {
    activeRepositoryOperationFromMenu != nil &&
      currentWorkspaceController?.canContinueOperationFromMenu == true
  }

  /// Whether the active Git operation can skip its current commit.
  /// 中文：当前 Git 操作是否可以跳过当前提交。
  var canSkipOperationFromMenu: Bool {
    gitDesktopCanPerformSkipOperationMenuAction(
      hasKeyWorkspace: currentWorkspaceController != nil,
      operation: activeRepositoryOperationFromMenu,
      hasValidatedSkipCapability:
        currentWorkspaceController?.canSkipOperationFromMenu == true
    )
  }

  /// Whether the active Git operation can be aborted.
  /// 中文：当前 Git 操作是否可中止。
  var canAbortOperationFromMenu: Bool {
    activeRepositoryOperationFromMenu != nil &&
      currentWorkspaceController?.canAbortOperationFromMenu == true
  }

  /// Whether stage 2 exists for the selected unmerged path.
  /// 中文：当前单个未合并路径是否存在可选的索引第二阶段版本。
  var canUseConflictStage2FromMenu: Bool {
    currentWorkspaceController?.canUseConflictStage2FromMenu == true
  }

  /// Whether stage 3 exists for the selected unmerged path.
  /// 中文：当前单个未合并路径是否存在可选的索引第三阶段版本。
  var canUseConflictStage3FromMenu: Bool {
    currentWorkspaceController?.canUseConflictStage3FromMenu == true
  }

  /// Whether the selected unmerged path can be staged as resolved.
  /// 中文：当前单个未合并路径是否可暂存并标记为已解决。
  var canMarkConflictResolvedFromMenu: Bool {
    currentWorkspaceController?.canMarkConflictResolvedFromMenu == true
  }

  var conflictStage2LabelFromMenu: String {
    currentWorkspaceController?.conflictStage2LabelFromMenu ?? "当前基线版本"
  }

  var conflictStage3LabelFromMenu: String {
    currentWorkspaceController?.conflictStage3LabelFromMenu ?? "待应用版本"
  }

  /// Whether the key workspace currently permits opening the Fetch workflow.
  /// 中文：当前前台工作区是否已由 Flutter 校验为允许打开抓取工作流。
  var canFetchFromMenu: Bool {
    currentWorkspaceController?.canFetchFromMenu == true
  }

  /// Whether the key workspace permits interactive rebase from its selection.
  /// 中文：当前前台工作区是否允许以当前选中提交作为交互式变基基点。
  var canInteractiveRebaseFromMenu: Bool {
    currentWorkspaceController?.canInteractiveRebaseFromMenu == true
  }

  /// Whether the key workspace currently permits opening the Merge workflow.
  /// 中文：当前前台工作区是否已由 Flutter 校验为允许打开分支合并流程。
  var canMergeFromMenu: Bool {
    currentWorkspaceController?.canMergeFromMenu == true
  }

  /// Whether the key workspace currently permits opening the Commit workflow.
  /// 中文：当前前台工作区是否已由 Flutter 校验为允许打开提交工作流。
  var canCommitFromMenu: Bool {
    currentWorkspaceController?.canCommitFromMenu == true
  }

  /// Whether the key workspace currently permits opening the Pull workflow.
  /// 中文：当前前台工作区是否已由 Flutter 校验为允许打开拉取工作流。
  var canPullFromMenu: Bool {
    currentWorkspaceController?.canPullFromMenu == true
  }

  /// Whether the key workspace currently permits opening the Push workflow.
  /// 中文：当前前台工作区是否已由 Flutter 校验为允许打开推送工作流。
  var canPushFromMenu: Bool {
    currentWorkspaceController?.canPushFromMenu == true
  }

  /// Whether the key workspace currently permits opening Branch management.
  /// 中文：当前前台工作区是否已由 Flutter 校验为允许打开分支管理。
  var canCreateBranchFromMenu: Bool {
    currentWorkspaceController?.canCreateBranchFromMenu == true
  }

  /// Whether the key workspace currently permits the frozen Git-flow Start.
  /// 中文：当前前台工作区是否允许打开已冻结语义的 Git-flow Start。
  var canStartGitFlowFromMenu: Bool {
    currentWorkspaceController?.canStartGitFlowFromMenu == true
  }

  /// Whether the key workspace currently permits opening Stash creation.
  /// 中文：当前前台工作区是否已由 Flutter 校验为允许打开贮藏创建。
  var canStashFromMenu: Bool {
    currentWorkspaceController?.canStashFromMenu == true
  }

  /// Whether the key workspace currently has a valid target for tag management.
  /// 中文：当前前台工作区是否有可供标签管理使用的有效提交目标。
  var canTagFromMenu: Bool {
    currentWorkspaceController?.canTagFromMenu == true
  }

  /// Whether the key workspace can show history for its current file.
  /// 中文：当前前台工作区是否可显示所选文件的修改日志。
  var canViewSelectedFileHistoryFromMenu: Bool {
    gitDesktopCanPerformSelectedChangeMenuAction(
      hasKeyWorkspace: currentWorkspaceController != nil,
      hasValidatedSelection:
        currentWorkspaceController?.canViewSelectedFileHistoryFromMenu == true
    )
  }

  /// Whether the key workspace can open a read-only external Diff for its
  /// single selected file.
  /// 中文：当前前台工作区是否可为单个所选文件打开只读外部差异比对。
  var canExternalDiffSelectedFromMenu: Bool {
    gitDesktopCanPerformSelectedChangeMenuAction(
      hasKeyWorkspace: currentWorkspaceController != nil,
      hasValidatedSelection:
        currentWorkspaceController?.canExternalDiffSelectedFromMenu == true
    )
  }

  /// Whether the key workspace can add ignore rules for its current selection.
  /// 中文：当前前台工作区是否可为当前选择添加忽略规则。
  var canIgnoreSelectedFromMenu: Bool {
    gitDesktopCanPerformSelectedChangeMenuAction(
      hasKeyWorkspace: currentWorkspaceController != nil,
      hasValidatedSelection:
        currentWorkspaceController?.canIgnoreSelectedFromMenu == true
    )
  }

  /// Whether the key workspace can copy every currently selected local file.
  /// 中文：当前前台工作区是否可复制全部当前选中的本地文件。
  var canCopySelectedFromMenu: Bool {
    guard gitDesktopCanPerformSelectedChangeMenuAction(
      hasKeyWorkspace: currentWorkspaceController != nil,
      hasValidatedSelection:
        currentWorkspaceController?.canCopySelectedFromMenu == true
    ), let targets = currentWorkspaceFileMenuTargets else {
      return false
    }
    return !targets.existingRegularFileURLs().isEmpty
  }

  /// Whether the key workspace can move every currently selected local file.
  /// 中文：当前前台工作区是否可移动全部当前选中的本地文件。
  var canMoveSelectedFromMenu: Bool {
    guard gitDesktopCanPerformSelectedChangeMenuAction(
      hasKeyWorkspace: currentWorkspaceController != nil,
      hasValidatedSelection:
        currentWorkspaceController?.canMoveSelectedFromMenu == true
    ), let targets = currentWorkspaceFileMenuTargets else {
      return false
    }
    return !targets.existingRegularFileURLs().isEmpty
  }

  /// Whether the key workspace can open the Flutter-owned read-only review.
  /// 中文：当前前台工作区是否可打开由 Flutter 持有的只读审查。
  var canReviewSelectedFromMenu: Bool {
    gitDesktopCanPerformSelectedChangeMenuAction(
      hasKeyWorkspace: currentWorkspaceController != nil,
      hasValidatedSelection:
        currentWorkspaceController?.canReviewSelectedFromMenu == true
    )
  }

  /// Whether the key workspace has a Flutter-validated unstaged selection.
  /// 中文：当前前台工作区是否有经 Flutter 校验、可加入索引的未暂存选择。
  var canStageSelectedFromMenu: Bool {
    gitDesktopCanPerformSelectedChangeMenuAction(
      hasKeyWorkspace: currentWorkspaceController != nil,
      hasValidatedSelection:
        currentWorkspaceController?.canStageSelectedFromMenu == true
    )
  }

  /// Whether the key workspace has a Flutter-validated staged selection.
  /// 中文：当前前台工作区是否有经 Flutter 校验、可从索引取消暂存的选择。
  var canUnstageSelectedFromMenu: Bool {
    gitDesktopCanPerformSelectedChangeMenuAction(
      hasKeyWorkspace: currentWorkspaceController != nil,
      hasValidatedSelection:
        currentWorkspaceController?.canUnstageSelectedFromMenu == true
    )
  }

  /// Whether the key workspace has a Flutter-validated removable selection.
  /// 中文：当前前台工作区是否有经 Flutter 校验、可确认移除的工作区文件选择。
  var canRemoveSelectedFromMenu: Bool {
    gitDesktopCanPerformSelectedChangeMenuAction(
      hasKeyWorkspace: currentWorkspaceController != nil,
      hasValidatedSelection:
        currentWorkspaceController?.canRemoveSelectedFromMenu == true
    )
  }

  /// Whether the key workspace can open the repository reset target picker.
  /// 中文：当前前台工作区是否可打开仓库重置目标选择器。
  var canResetRepositoryFromMenu: Bool {
    currentWorkspaceController?.canResetRepositoryFromMenu == true
  }

  /// Whether the key workspace can reset all selected paths to HEAD.
  /// 中文：当前前台工作区是否可将全部所选路径恢复到 HEAD。
  var canResetSelectedFromMenu: Bool {
    gitDesktopCanPerformSelectedChangeMenuAction(
      hasKeyWorkspace: currentWorkspaceController != nil,
      hasValidatedSelection:
        currentWorkspaceController?.canResetSelectedFromMenu == true
    )
  }

  /// Whether the key workspace can reset to its selected history commit.
  /// 中文：当前前台工作区是否可重置到当前选择的历史提交。
  var canResetToSelectedCommitFromMenu: Bool {
    currentWorkspaceController?.canResetToSelectedCommitFromMenu == true
  }

  /// Resolves a key window only when it is still owned by this coordinator.
  /// Closed Engines and unrelated app windows therefore cannot contribute a
  /// stale menu snapshot.
  ///
  /// 中文：仅当 key window 仍由本协调器持有时返回工作区控制器；
  /// 已关闭 Engine 和无关窗口无法提供过期菜单快照。
  func workspaceController(
    forKeyWindow keyWindow: NSWindow?
  ) -> WorkspaceFlutterWindowController? {
    guard let keyWindow = keyWindow as? MainFlutterWindow,
          keyWindow.role == .workspace else {
      return nil
    }
    return workspaceControllers().first { $0.window === keyWindow }
  }

  private var currentWorkspaceController: WorkspaceFlutterWindowController? {
    workspaceController(forKeyWindow: NSApp.keyWindow)
  }

  func registerRepository(
    _ repositoryPath: String,
    for controller: WorkspaceFlutterWindowController
  ) {
    // A workspace can switch repositories while an older Flutter state
    // notification is still in flight. Ignore that stale notification rather
    // than treating the current controller as a duplicate and closing it.
    if let currentPath = controller.repositoryPath,
       currentPath != repositoryPath,
       controller.hasVerifiedRepository {
      return
    }
    if let existing = workspaceIndex.host(for: repositoryPath),
       existing !== controller {
      // Automatic refreshes can re-report the current repository after the
      // workspace has already been verified. That is a state notification,
      // not a second open request; never close a live verified workspace for
      // it. Only an unverified placeholder can be safely deduplicated here.
      if controller.hasVerifiedRepository {
        return
      }
      workspaceHistory.markRecent(existing)
      existing.showAndActivate()
      reportRepositoryOpenedToLibrary(repositoryPath: repositoryPath)
      // Let the reporting MethodChannel reply before shutting down its Engine.
      DispatchQueue.main.async {
        controller.requestClose()
      }
      return
    }

    workspaceIndex.remove(controller)
    unregisteredWorkspaces.removeValue(forKey: ObjectIdentifier(controller))
    controller.repositoryPath = repositoryPath
    controller.markRepositoryVerified()
    controller.window?.title = "\(URL(fileURLWithPath: repositoryPath).lastPathComponent) (Git)"
    if let window = controller.window as? MainFlutterWindow,
       selectMergedWorkspaceGroup(containing: window) {
      refreshMergedWorkspaceTabStrips()
    }
    workspaceIndex.register(controller, for: repositoryPath)
    if controller.restoresPreviouslyOpenWorkspace {
      if controller.restoresMergedWorkspace &&
          !workspaceRestorationGate.isWaiting {
        mergeVerifiedRestoredWorkspaceGroupIfPossible()
      }
    } else {
      mergeNewWorkspaceIntoExistingMergedGroupIfNeeded(controller)
    }
    if !resolveRestoredRepository(repositoryPath) {
      persistOpenWorkspaces()
    }
    reportRepositoryOpenedToLibrary(repositoryPath: repositoryPath)
  }

  /// Forwards a status refresh without re-registering or deduplicating a window.
  /// 中文：仅转发状态刷新，不重新登记工作区，也不触发窗口去重关闭。
  func reportRepositoryStatus(_ repositoryPath: String) {
    reportRepositoryOpenedToLibrary(repositoryPath: repositoryPath)
  }

  /// Removes a restored path that Flutter could no longer verify as a Git
  /// repository, then closes only the failed workspace that reported it.
  func discardFailedRestoredRepository(
    _ repositoryPath: String,
    for controller: WorkspaceFlutterWindowController
  ) {
    guard workspaceIndex.host(for: repositoryPath) === controller else {
      return
    }
    workspaceIndex.remove(controller)
    workspaceHistory.remove(controller)
    if !resolveRestoredRepository(repositoryPath) {
      persistOpenWorkspaces()
    }
    DispatchQueue.main.async {
      controller.requestClose()
    }
  }

  /// 中文：把全部工作区收拢到一个可见窗口位置，并以自绘标签切换。
  ///
  /// English: Collects all workspaces into one visible window position and
  /// switches them through the custom strip. Every workspace remains a real
  /// NSWindow with its own Flutter Engine and close lifecycle.
  func mergeAllWorkspaceWindows() {
    mergeWorkspaceWindows(workspaceControllers())
  }

  /// 中文：只把指定工作区收拢为自绘标签组，不改变批次外的独立窗口。
  ///
  /// English: Collects only the specified workspaces into the custom strip,
  /// leaving windows outside that batch independent.
  func mergeWorkspaceWindows(
    _ controllers: [WorkspaceFlutterWindowController]
  ) {
    guard controllers.count > 1 else {
      return
    }
    dismissWorkspaceTabOverview()
    let windows = controllers.compactMap { $0.window as? MainFlutterWindow }
    guard windows.count > 1,
          let primary = activeWorkspaceWindow(from: controllers),
          windows.contains(where: { $0 === primary }) else {
      return
    }
    let newOrder = windows.map(ObjectIdentifier.init)
    let windowIdentifiers = Set(windows.map(ObjectIdentifier.init))
    let overlappingGroups = mergedWorkspaceGroups.filter { group in
      !Set(group).isDisjoint(with: windowIdentifiers)
    }
    for previousIdentifier in overlappingGroups.flatMap({ $0 })
    where !windowIdentifiers.contains(previousIdentifier) {
      if let previousWindow = workspaceControllers().first(where: {
        $0.window.map(ObjectIdentifier.init) == previousIdentifier
      })?.window as? MainFlutterWindow {
        previousWindow.removeWorkspaceTabStrip()
        if !previousWindow.isVisible {
          previousWindow.orderFront(nil)
        }
      }
    }
    // A workspace can belong to only one group. Remove any old groups that
    // overlap this new set, then append the requested group independently.
    mergedWorkspaceGroups = mergedWorkspaceGroups.enumerated().compactMap {
      index, group in
      let remaining = group.filter { !windowIdentifiers.contains($0) }
      guard remaining.count > 1 else { return nil }
      return remaining
    }
    mergedWorkspaceGroups.append(newOrder)
    activeMergedWorkspaceGroupIndex = mergedWorkspaceGroups.count - 1
    selectedMergedWorkspaceWindow = primary
    isMergedWorkspaceTabStripVisible = true
    let sharedFrame = primary.frame
    windows.forEach { $0.cancelPendingBringToFront() }
    for window in windows where window !== primary {
      window.setFrame(sharedFrame, display: false)
      window.orderOut(nil)
    }
    refreshMergedWorkspaceTabStrips()
    primary.bringToFrontImmediately()
    persistOpenWorkspaces()
  }

  /// Returns whether at least two live workspaces still need to be merged.
  var canMergeAllWorkspaceWindows: Bool {
    let controllers = workspaceControllers()
    let windows = controllers.compactMap(\.window)
    guard windows.count > 1 else {
      return false
    }
    let mergedIdentifiers = Set(mergedWorkspaceGroups.flatMap { $0 })
    return windows.contains { !mergedIdentifiers.contains(ObjectIdentifier($0)) }
  }

  func workspaceWillClose(_ controller: WorkspaceFlutterWindowController) {
    dismissWorkspaceTabOverview()
    let closingWindow = controller.window as? MainFlutterWindow
    closingWindow?.cancelPendingBringToFront()
    let closingFrame = closingWindow?.frame
    let closingIdentifier = closingWindow.map(ObjectIdentifier.init)
    let closingGroupIndex = closingIdentifier.flatMap { identifier in
      mergedWorkspaceGroups.firstIndex { $0.contains(identifier) }
    }
    let closingIndex = closingIdentifier.flatMap { identifier in
      closingGroupIndex.flatMap {
        mergedWorkspaceGroups[$0].firstIndex(of: identifier)
      }
    }
    let wasSelected = closingWindow === selectedMergedWorkspaceWindow
    var remainingClosingGroupIdentifiers: [ObjectIdentifier] = []
    if let closingIdentifier {
      if let closingGroupIndex {
        remainingClosingGroupIdentifiers = mergedWorkspaceGroups[
          closingGroupIndex
        ].filter { $0 != closingIdentifier }
        if remainingClosingGroupIdentifiers.count > 1 {
          mergedWorkspaceGroups[closingGroupIndex] =
            remainingClosingGroupIdentifiers
        } else {
          mergedWorkspaceGroups.remove(at: closingGroupIndex)
        }
      } else {
        mergedWorkspaceGroups = mergedWorkspaceGroups.compactMap { group in
          let remaining = group.filter { $0 != closingIdentifier }
          return remaining.count > 1 ? remaining : nil
        }
      }
      activeMergedWorkspaceGroupIndex = min(
        activeMergedWorkspaceGroupIndex,
        max(0, mergedWorkspaceGroups.count - 1)
      )
    }
    workspaceIndex.remove(controller)
    unregisteredWorkspaces.removeValue(forKey: ObjectIdentifier(controller))
    workspaceHistory.remove(controller)
    guard !isTerminating else {
      return
    }
    let liveWindowByIdentifier = Dictionary(
      uniqueKeysWithValues: workspaceControllers().compactMap { controller in
        (controller.window as? MainFlutterWindow).map {
          (ObjectIdentifier($0), $0)
        }
      }
    )
    let remainingMergedWindows = remainingClosingGroupIdentifiers.compactMap {
      liveWindowByIdentifier[$0]
    }
    if remainingClosingGroupIdentifiers.count < 2 {
      remainingMergedWindows.forEach { $0.removeWorkspaceTabStrip() }
      selectedMergedWorkspaceWindow = nil
      isMergedWorkspaceTabStripVisible = true
      if wasSelected, let fallback = workspaceHistory.mostRecent?.window {
        fallback.orderFrontRegardless()
      }
    } else if wasSelected {
      let nextIndex = min(closingIndex ?? 0, remainingMergedWindows.count - 1)
      let nextWindow = remainingMergedWindows[nextIndex]
      if let closingFrame {
        nextWindow.setFrame(closingFrame, display: false)
      }
      selectedMergedWorkspaceWindow = nextWindow
      DispatchQueue.main.async { [weak self, weak nextWindow] in
        guard let self, let nextWindow else {
          return
        }
        self.activateMergedWorkspace(nextWindow)
      }
    } else {
      refreshMergedWorkspaceTabStrips()
    }
    if let repositoryPath = controller.repositoryPath,
       resolveRestoredRepository(repositoryPath) {
      return
    }
    persistOpenWorkspaces()
  }

  /// Prevents normal window teardown during app termination from clearing the
  /// workspace list that must be restored by the next process.
  func beginApplicationTermination() {
    isTerminating = true
    workspaceRestorationTimeoutWorkItem?.cancel()
    workspaceRestorationTimeoutWorkItem = nil
  }

  /// Collects every live workspace once, including workspaces not yet bound to
  /// a repository path.
  private func workspaceControllers() -> [WorkspaceFlutterWindowController] {
    let candidates = workspaceIndex.allHosts
      + Array(unregisteredWorkspaces.values)
    var controllers: [WorkspaceFlutterWindowController] = []
    var seen: Set<ObjectIdentifier> = []
    for controller in candidates {
      if seen.insert(ObjectIdentifier(controller)).inserted {
        controllers.append(controller)
      }
    }
    return controllers
  }

  /// 中文：按标签显示顺序解析仍存活的合并工作区窗口。
  ///
  /// English: Resolves the live merged workspace windows in visible tab order.
  private var mergedWorkspaceWindows: [MainFlutterWindow] {
    let liveWindows = workspaceControllers().compactMap {
      $0.window as? MainFlutterWindow
    }
    let windowByIdentifier = Dictionary(
      uniqueKeysWithValues: liveWindows.map { (ObjectIdentifier($0), $0) }
    )
    return mergedWorkspaceOrder.compactMap { windowByIdentifier[$0] }
  }

  /// Selects the independent merged group containing [window], if any.
  /// 中文：选择包含指定窗口的独立合并组。
  @discardableResult
  private func selectMergedWorkspaceGroup(
    containing window: MainFlutterWindow
  ) -> Bool {
    guard let index = mergedWorkspaceGroups.firstIndex(where: {
      $0.contains(ObjectIdentifier(window))
    }) else {
      return false
    }
    activeMergedWorkspaceGroupIndex = index
    selectedMergedWorkspaceWindow = mergedWorkspaceGroups[index].first.flatMap {
      identifier in
      workspaceControllers().compactMap { $0.window as? MainFlutterWindow }
        .first(where: { ObjectIdentifier($0) == identifier })
    }
    return true
  }

  /// Removes a window from every persisted/in-memory group and drops groups
  /// that no longer contain two windows.
  /// 中文：从所有组移除窗口，并丢弃不足两个窗口的组。
  private func removeWindowFromMergedWorkspaceGroups(
    _ identifier: ObjectIdentifier
  ) {
    mergedWorkspaceGroups = mergedWorkspaceGroups.compactMap { group in
      let remaining = group.filter { $0 != identifier }
      return remaining.count > 1 ? remaining : nil
    }
    activeMergedWorkspaceGroupIndex = min(
      activeMergedWorkspaceGroupIndex,
      max(0, mergedWorkspaceGroups.count - 1)
    )
  }

  /// 中文：若已有合并标签组，将刚完成仓库验证的新窗口追加到该组。
  ///
  /// English: Appends a newly verified workspace to an existing merged group,
  /// while leaving unrelated standalone workspaces independent.
  private func mergeNewWorkspaceIntoExistingMergedGroupIfNeeded(
    _ controller: WorkspaceFlutterWindowController
  ) {
    guard let newWindow = controller.window as? MainFlutterWindow else {
      return
    }
    let controllers = workspaceControllers()
    if let selectedMergedWorkspaceWindow {
      _ = selectMergedWorkspaceGroup(containing: selectedMergedWorkspaceWindow)
    }
    let controllerByWindowIdentifier = Dictionary(
      uniqueKeysWithValues: controllers.compactMap { candidate in
        (candidate.window as? MainFlutterWindow).map {
          (ObjectIdentifier($0), candidate)
        }
      }
    )
    guard let mergedOrder = gitDesktopMergedWorkspaceOrderByAddingWindow(
      existingOrder: mergedWorkspaceOrder,
      liveWindowIdentifiers: Set(controllerByWindowIdentifier.keys),
      newWindowIdentifier: ObjectIdentifier(newWindow)
    ) else {
      return
    }
    let mergedControllers = mergedOrder.compactMap {
      controllerByWindowIdentifier[$0]
    }
    guard mergedControllers.count == mergedOrder.count else {
      return
    }
    mergeWorkspaceWindows(mergedControllers)
  }

  /// 中文：将恢复快照中明确属于同一组且已验证的窗口重新合并。
  ///
  /// English: Re-merges verified windows explicitly listed in the restored
  /// group, without absorbing independently restored workspaces.
  private func mergeVerifiedRestoredWorkspaceGroupIfPossible() {
    for group in restoredMergedWorkspacePathGroups {
      let controllers = group.compactMap {
        workspaceIndex.host(for: $0)
      }.filter(\.hasVerifiedRepository)
      if controllers.count > 1 {
        mergeWorkspaceWindows(controllers)
      }
    }
  }

  /// Selects the current workspace as tab host, falling back to the most
  /// recently used live workspace.
  private func activeWorkspaceWindow(
    from controllers: [WorkspaceFlutterWindowController]
  ) -> MainFlutterWindow? {
    if let keyWindow = NSApp.keyWindow as? MainFlutterWindow,
       keyWindow.role == .workspace,
       controllers.contains(where: { $0.window === keyWindow }) {
      return keyWindow
    }
    if let mostRecent = workspaceHistory.mostRecent?.window as? MainFlutterWindow,
       controllers.contains(where: { $0.window === mostRecent }) {
      return mostRecent
    }
    return controllers.first?.window as? MainFlutterWindow
  }

  func windowDidBecomeKey(_ window: MainFlutterWindow) {
    windowFocusHistory.markFrontmost(window)
    guard window.role == .workspace else {
      return
    }
    if selectMergedWorkspaceGroup(containing: window),
       selectedMergedWorkspaceWindow !== window,
       !isActivatingMergedWorkspace {
      activateMergedWorkspace(window)
    }
    let candidates = workspaceIndex.allHosts
      + Array(unregisteredWorkspaces.values)
    if let controller = candidates.first(where: { $0.window === window }) {
      workspaceHistory.markRecent(controller)
    }
  }

  /// 中文：在自定义合并组中循环选择相邻工作区。
  ///
  /// English: Selects the adjacent workspace in the custom merged set,
  /// wrapping at both ends to preserve native tab keyboard expectations.
  func selectAdjacentMergedWorkspace(
    from window: MainFlutterWindow,
    offset: Int
  ) -> Bool {
    guard selectMergedWorkspaceGroup(containing: window) else {
      return false
    }
    let windows = mergedWorkspaceWindows
    guard windows.count > 1,
          let currentIndex = windows.firstIndex(where: { $0 === window }) else {
      return false
    }
    guard let targetIndex = gitDesktopAdjacentTabIndex(
      currentIndex: currentIndex,
      tabCount: windows.count,
      offset: offset
    ) else {
      return false
    }
    activateMergedWorkspace(windows[targetIndex])
    return true
  }

  /// Presents an accessible overview for the current merged workspace group.
  ///
  /// 中文：为当前合并工作区组显示可键盘访问的标签总览。
  func showCurrentMergedWorkspaceOverview() -> Bool {
    guard let window = currentWorkspaceController?.window as? MainFlutterWindow
    else {
      return false
    }
    return showMergedWorkspaceOverview(from: window)
  }

  /// Presents the overview for [window]'s group; exposed to lifecycle tests
  /// so selection and stale-window cleanup can be verified without launching
  /// the application.
  ///
  /// 中文：显示 [window] 所在组的总览；对生命周期测试开放，以便在
  /// 不启动应用的情况下验证选择和过期窗口清理。
  @discardableResult
  func showMergedWorkspaceOverview(from window: MainFlutterWindow) -> Bool {
    guard selectMergedWorkspaceGroup(containing: window) else {
      return false
    }
    let windows = mergedWorkspaceWindows
    guard windows.count > 1,
          windows.contains(where: { $0 === window }),
          let selectedWindow = selectedMergedWorkspaceWindow,
          windows.contains(where: { $0 === selectedWindow }) else {
      return false
    }
    dismissWorkspaceTabOverview()
    let controller = GitDesktopWorkspaceTabOverviewWindowController(
      hostWindow: selectedWindow,
      windows: windows,
      selectedWindow: selectedWindow,
      selectionHandler: { [weak self] requestedWindow in
        self?.dismissWorkspaceTabOverview()
        self?.activateMergedWorkspace(requestedWindow)
      }
    )
    controller.onClose = { [weak self, weak controller] in
      guard let self, self.workspaceTabOverviewController === controller else {
        return
      }
      self.workspaceTabOverviewController = nil
    }
    workspaceTabOverviewController = controller
    controller.present()
    return true
  }

  /// Dismisses a transient overview before its group changes or shuts down.
  /// 中文：在标签组变更或关闭前退出短期总览，避免保留过期窗口。
  private func dismissWorkspaceTabOverview() {
    let controller = workspaceTabOverviewController
    workspaceTabOverviewController = nil
    controller?.dismiss()
  }

  /// 中文：从当前 key workspace 循环切换到相邻的合并标签。
  /// English: Selects an adjacent merged tab from the current key workspace.
  func selectAdjacentMergedWorkspaceFromMenu(offset: Int) -> Bool {
    guard let window = currentWorkspaceController?.window as? MainFlutterWindow
    else {
      return false
    }
    return selectAdjacentMergedWorkspace(from: window, offset: offset)
  }

  /// 中文：当前 key workspace 是否属于至少包含两个窗口的合并标签组。
  /// English: Whether the key workspace belongs to a merged group of at least
  /// two live windows.
  var canManageCurrentMergedWorkspace: Bool {
    guard let window = currentWorkspaceController?.window as? MainFlutterWindow
    else {
      return false
    }
    return canManageMergedWorkspace(window)
  }

  /// 中文：判断指定工作区窗口是否属于可操作的合并标签组。
  /// English: Returns whether a workspace window belongs to a manageable
  /// merged group.
  private func canManageMergedWorkspace(_ window: MainFlutterWindow) -> Bool {
    guard selectMergedWorkspaceGroup(containing: window) else { return false }
    return mergedWorkspaceWindows.count > 1
  }

  /// 中文：当前合并工作区是否显示自绘标签栏。
  /// English: Whether the current merged workspace group shows its custom tab
  /// strip.
  var showsCurrentMergedWorkspaceTabStrip: Bool {
    canManageCurrentMergedWorkspace && isMergedWorkspaceTabStripVisible
  }

  /// 中文：切换当前合并组的标签栏可见性，不改变窗口或 Engine 所有权。
  /// English: Toggles the custom strip for the current merged group without
  /// changing window or Engine ownership.
  func toggleCurrentMergedWorkspaceTabStrip() -> Bool {
    guard let window = currentWorkspaceController?.window as? MainFlutterWindow
    else {
      return false
    }
    return toggleMergedWorkspaceTabStrip(from: window)
  }

  /// 中文：切换指定合并工作区的标签栏，供菜单和生命周期测试共用。
  /// English: Toggles the specified merged workspace's tab strip for both menu
  /// routing and lifecycle tests.
  @discardableResult
  func toggleMergedWorkspaceTabStrip(from window: MainFlutterWindow) -> Bool {
    guard canManageMergedWorkspace(window) else { return false }
    isMergedWorkspaceTabStripVisible.toggle()
    refreshMergedWorkspaceTabStrips()
    return true
  }

  /// 中文：将当前标签从合并组移为独立窗口，同时保留其 Engine 和仓库会话。
  ///
  /// English: Detaches the current tab into a standalone window while keeping
  /// its Flutter Engine and repository session alive.
  func detachCurrentWorkspaceFromMergedGroup() -> Bool {
    guard let detachedWindow = currentWorkspaceController?.window
            as? MainFlutterWindow else {
      return false
    }
    return detachMergedWorkspace(detachedWindow)
  }

  /// 中文：将指定工作区从合并组移出，供菜单和生命周期测试共用。
  /// English: Detaches a specified workspace from its merged group for both
  /// menu routing and lifecycle tests.
  @discardableResult
  func detachMergedWorkspace(_ detachedWindow: MainFlutterWindow) -> Bool {
    guard canManageMergedWorkspace(detachedWindow),
          let detachedIndex = mergedWorkspaceOrder.firstIndex(
            of: ObjectIdentifier(detachedWindow)
          ) else {
      return false
    }

    dismissWorkspaceTabOverview()
    let detachedRepositoryPath = workspaceControllers().first {
      $0.window === detachedWindow
    }?.repositoryPath
    restoredMergedWorkspacePathGroups = restoredMergedWorkspacePathGroups.map {
      gitDesktopMergedWorkspacePaths(
        $0,
        afterDetaching: detachedRepositoryPath
      )
    }.filter { $0.count > 1 }
    let sharedFrame = detachedWindow.frame
    // Capture the group's live windows before changing the compatibility
    // order. When removing the final tab, the order setter drops the group,
    // so resolving `mergedWorkspaceWindows` afterwards would lose the last
    // remaining window whose strip still needs to be removed.
    let currentGroupWindows = mergedWorkspaceWindows
    mergedWorkspaceOrder.remove(at: detachedIndex)
    detachedWindow.removeWorkspaceTabStrip()
    let remainingWindows = mergedWorkspaceWindows
    if remainingWindows.count > 1 {
      let nextIndex = min(detachedIndex, remainingWindows.count - 1)
      let nextWindow = remainingWindows[nextIndex]
      selectedMergedWorkspaceWindow = nextWindow
      nextWindow.setFrame(sharedFrame, display: false)
      refreshMergedWorkspaceTabStrips()
      nextWindow.orderFront(nil)
    } else {
      currentGroupWindows.forEach { $0.removeWorkspaceTabStrip() }
      if mergedWorkspaceGroups.indices.contains(activeMergedWorkspaceGroupIndex) {
        mergedWorkspaceGroups.remove(at: activeMergedWorkspaceGroupIndex)
      }
      activeMergedWorkspaceGroupIndex = min(
        activeMergedWorkspaceGroupIndex,
        max(0, mergedWorkspaceGroups.count - 1)
      )
      selectedMergedWorkspaceWindow = nil
      isMergedWorkspaceTabStripVisible = true
      if let remainingWindow = remainingWindows.first {
        remainingWindow.setFrame(sharedFrame, display: false)
        remainingWindow.orderFront(nil)
      }
    }

    let detachedFrame = gitDesktopDetachedWindowFrame(
      currentFrame: sharedFrame,
      visibleFrame: (detachedWindow.screen ?? NSScreen.main)?.visibleFrame
        ?? sharedFrame
    )
    detachedWindow.setFrame(detachedFrame, display: false)
    detachedWindow.bringToFrontImmediately()
    persistOpenWorkspaces()
    return true
  }

  /// 中文：把一个工作区移动到合并标签组的新索引，并立即保存恢复顺序。
  ///
  /// English: Moves a workspace to a new merged-tab index and immediately
  /// persists the resulting restoration order.
  func moveMergedWorkspace(
    _ window: MainFlutterWindow,
    to destinationIndex: Int
  ) {
    dismissWorkspaceTabOverview()
    guard selectMergedWorkspaceGroup(containing: window) else {
      return
    }
    let windowIdentifier = ObjectIdentifier(window)
    guard let sourceIndex = mergedWorkspaceOrder.firstIndex(
      of: windowIdentifier
    ),
      mergedWorkspaceOrder.indices.contains(destinationIndex),
      sourceIndex != destinationIndex else {
      return
    }
    mergedWorkspaceOrder = gitDesktopMovingItem(
      in: mergedWorkspaceOrder,
      from: sourceIndex,
      to: destinationIndex
    )
    refreshMergedWorkspaceTabStrips()
    persistOpenWorkspaces()
  }

  /// 中文：激活合并组中的一个工作区，并复用当前可见窗口的位置与尺寸。
  ///
  /// English: Activates one workspace in the merged set while reusing the
  /// currently visible window's frame.
  private func activateMergedWorkspace(_ window: MainFlutterWindow) {
    guard selectMergedWorkspaceGroup(containing: window) else {
      window.bringToFront()
      return
    }
    guard !isActivatingMergedWorkspace else {
      return
    }
    isActivatingMergedWorkspace = true
    let previousWindow = selectedMergedWorkspaceWindow
    let sharedFrame = previousWindow?.frame ?? window.frame
    if previousWindow !== window {
      previousWindow?.cancelPendingBringToFront()
      previousWindow?.orderOut(nil)
      window.setFrame(sharedFrame, display: false)
    }
    selectedMergedWorkspaceWindow = window
    refreshMergedWorkspaceTabStrips()
    window.bringToFrontImmediately()
    isActivatingMergedWorkspace = false
  }

  /// 中文：刷新合并组所有窗口顶部的单行矩形标签条。
  ///
  /// English: Refreshes the single rectangular strip hosted by every workspace
  /// in the custom merged set.
  private func refreshMergedWorkspaceTabStrips() {
    let liveWindows = workspaceControllers().compactMap {
      $0.window as? MainFlutterWindow
    }
    let windowByIdentifier = Dictionary(
      uniqueKeysWithValues: liveWindows.map { (ObjectIdentifier($0), $0) }
    )
    for (index, group) in mergedWorkspaceGroups.enumerated() {
      let windows = group.compactMap { windowByIdentifier[$0] }
      guard windows.count > 1 else {
        windows.forEach { $0.removeWorkspaceTabStrip() }
        continue
      }
      let selectedWindow: MainFlutterWindow
      if index == activeMergedWorkspaceGroupIndex,
         let current = selectedMergedWorkspaceWindow,
         windows.contains(where: { $0 === current }) {
        selectedWindow = current
      } else {
        selectedWindow = windows[0]
      }
      if index == activeMergedWorkspaceGroupIndex &&
          !isMergedWorkspaceTabStripVisible {
        windows.forEach { $0.removeWorkspaceTabStrip() }
        continue
      }
      windows.forEach { candidate in
        candidate.configureWorkspaceTabStrip(
          windows: windows,
          selectedWindow: selectedWindow,
          selectionHandler: { [weak self] requestedWindow in
            self?.activateMergedWorkspace(requestedWindow)
          },
          reorderHandler: { [weak self] movedWindow, destinationIndex in
            self?.moveMergedWorkspace(movedWindow, to: destinationIndex)
          }
        )
      }
    }
  }

  func toggleRepositoryWindow(from sourceWindow: MainFlutterWindow?) {
    if sourceWindow?.role == .workspace {
      showRepositoryLibrary()
      return
    }
    guard let lastWorkspace = workspaceHistory.mostRecent,
          lastWorkspace.window != nil else {
      NSSound.beep()
      return
    }
    lastWorkspace.showAndActivate()
  }

  func showRepositoryLibrary() {
    guard let repositoryLibraryWindow else {
      NSSound.beep()
      return
    }
    repositoryLibraryWindow.bringToFront()
  }

  /// Restores the window that was last key before the app was hidden.
  ///
  /// Falls back to the workspace MRU list when that window has been closed,
  /// then to the repository library when no workspace remains.
  func restoreMostRecentlyActiveWindow() {
    if let frontmostWindow = windowFocusHistory.frontmost {
      frontmostWindow.bringToFront()
      return
    }
    if let lastWorkspace = workspaceHistory.mostRecent,
       lastWorkspace.window != nil {
      lastWorkspace.showAndActivate()
      return
    }
    showRepositoryLibrary()
  }

  /// 中文：保存全部窗口尺寸，并等待各 Engine 完成有界的退出清理。
  ///
  /// English: Saves every live window size and waits for each Engine's bounded
  /// termination cleanup.
  func prepareForApplicationTermination(completion: @escaping () -> Void) {
    // Persist the latest verified workspace order and merged-group flag before
    // Engine shutdown begins. This covers restarts that happen before a prior
    // tab or merge interaction has flushed its snapshot.
    persistOpenWorkspaces()

    let registered = workspaceIndex.allHosts
    let unregistered = Array(unregisteredWorkspaces.values)
    var controllers: [WorkspaceFlutterWindowController] = []
    var seen: Set<ObjectIdentifier> = []
    for controller in registered + unregistered {
      if seen.insert(ObjectIdentifier(controller)).inserted {
        controllers.append(controller)
      }
    }

    if let repositoryLibraryWindow {
      saveContentSize(of: repositoryLibraryWindow, for: .repositoryLibrary)
    }
    if let window = workspaceHistory.mostRecent?.window {
      saveContentSize(of: window, for: .workspace)
    }

    let group = DispatchGroup()
    for controller in controllers {
      group.enter()
      controller.prepareForApplicationTermination {
        group.leave()
      }
    }
    if let repositoryLibraryChannel {
      group.enter()
      prepareRepositoryLibrary(
        channel: repositoryLibraryChannel,
        completion: group.leave
      )
    }
    group.notify(queue: .main, execute: completion)
  }

  func shutDownWorkspaces() {
    guard !isTerminating else {
      return
    }
    isTerminating = true
    dismissWorkspaceTabOverview()
    let registered = workspaceIndex.allHosts
    let unregistered = Array(unregisteredWorkspaces.values)
    var seen: Set<ObjectIdentifier> = []
    for controller in registered + unregistered {
      let identifier = ObjectIdentifier(controller)
      if seen.insert(identifier).inserted {
        controller.close()
      }
    }
    workspaceIndex.removeAll()
    unregisteredWorkspaces.removeAll()
    workspaceHistory.removeAll()
    mergedWorkspaceGroups.removeAll()
    activeMergedWorkspaceGroupIndex = 0
    selectedMergedWorkspaceWindow = nil
    repositoryLibraryChannel?.setMethodCallHandler(nil)
  }

  /// Reopens the workspaces that were still open at the previous app exit.
  ///
  /// This runs only after the repository-library Flutter Engine is attached,
  /// so restored workspaces can report their verified repository state back to
  /// the library through the existing channel. Paths that no longer name a
  /// readable directory are pruned before any window is created.
  private func restoreOpenWorkspacesAfterLaunch() {
    guard !didRequestWorkspaceRestoration else {
      return
    }
    didRequestWorkspaceRestoration = true
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.isTerminating else {
        return
      }
      let savedSnapshot = self.workspaceRestoreStore.snapshot
      let restorablePaths = savedSnapshot.paths.filter {
        self.isReadableDirectory(at: $0)
      }
      let restorablePathSet = Set(restorablePaths)
      let mergedWorkspaceGroups = savedSnapshot.mergedWorkspaceGroups.map {
        $0.filter { restorablePathSet.contains($0) }
      }.filter { $0.count > 1 }
      self.restoredMergedWorkspacePathGroups = mergedWorkspaceGroups
      self.workspaceRestoreStore.save(
        paths: restorablePaths,
        mergedWorkspaceGroups: mergedWorkspaceGroups
      )
      self.workspaceRestorationGate.begin(
        paths: restorablePaths,
        mergedGroups: mergedWorkspaceGroups
      )
      self.scheduleWorkspaceRestorationTimeout()
      for repositoryPath in restorablePaths {
        self.openWorkspace(
          repositoryPath: repositoryPath,
          initialAction: nil,
          restoresPreviouslyOpenWorkspace: true,
          restoresMergedWorkspace: mergedWorkspaceGroups.contains {
            $0.contains(repositoryPath)
          }
        ) { [weak self] error in
          guard error != nil else {
            return
          }
          _ = self?.resolveRestoredRepository(repositoryPath)
        }
      }
    }
  }

  /// 中文：完成一个恢复仓库的验证；全部完成后才合并并持久化最终窗口状态。
  ///
  /// English: Completes verification for one restored repository, merging and
  /// persisting the final window state only after the entire batch resolves.
  @discardableResult
  private func resolveRestoredRepository(_ repositoryPath: String) -> Bool {
    switch workspaceRestorationGate.resolve(repositoryPath) {
    case .unrelated:
      return false
    case .waiting:
      return true
    case let .finished(completion):
      finishWorkspaceRestoration(completion)
      return true
    }
  }

  /// 中文：为恢复批次安排有界等待，避免卡住的 Git 读取永久阻塞窗口状态。
  ///
  /// English: Bounds the restore batch so a stalled Git read cannot block
  /// window-state persistence indefinitely.
  private func scheduleWorkspaceRestorationTimeout() {
    workspaceRestorationTimeoutWorkItem?.cancel()
    workspaceRestorationTimeoutWorkItem = nil
    guard workspaceRestorationGate.isWaiting else {
      return
    }
    let workItem = DispatchWorkItem { [weak self] in
      guard let self, !self.isTerminating,
            let completion = self.workspaceRestorationGate.finishPending()
      else {
        return
      }
      self.finishWorkspaceRestoration(completion)
    }
    workspaceRestorationTimeoutWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + gitDesktopWorkspaceRestorationTimeout,
      execute: workItem
    )
  }

  /// 中文：完成恢复批次，只合并已验证成员；超时成员继续保持可见，允许迟到的
  /// 仓库验证完成登记，避免后台初始化延迟擅自关闭用户窗口。
  ///
  /// English: Finishes a restore batch by merging only verified members while
  /// keeping timed-out members visible so late repository validation can
  /// still register them instead of closing a user-owned window.
  private func finishWorkspaceRestoration(
    _ completion: GitDesktopWorkspaceRestorationCompletion
  ) {
    workspaceRestorationTimeoutWorkItem?.cancel()
    workspaceRestorationTimeoutWorkItem = nil

    if completion.shouldMerge {
      for group in completion.mergedGroupsToRestore {
        let restoredControllers = group.compactMap {
          workspaceIndex.host(for: $0)
        }
        guard restoredControllers.count > 1 else { continue }
        mergeWorkspaceWindows(restoredControllers)
      }
      if completion.mergedGroupsToRestore.isEmpty {
        persistOpenWorkspaces()
      }
    } else {
      persistOpenWorkspaces()
    }
  }

  /// Returns whether [path] still points at a directory the process can read.
  private func isReadableDirectory(at path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(
      atPath: path,
      isDirectory: &isDirectory
    ) && isDirectory.boolValue && FileManager.default.isReadableFile(atPath: path)
  }

  /// Saves the live, registered workspaces in their existing restore order.
  /// Empty/new workspaces are intentionally excluded until Flutter confirms a
  /// repository has opened through `repositoryOpened`.
  private func persistOpenWorkspaces() {
    guard !workspaceRestorationGate.isWaiting else {
      return
    }
    let controllers = workspaceIndex.allHosts.filter { controller in
      controller.hasVerifiedRepository ||
        (isTerminating && controller.repositoryPath != nil)
    }
    let controllerByWindowIdentifier = Dictionary(
      uniqueKeysWithValues: controllers.compactMap { controller in
        controller.window.map {
          (ObjectIdentifier($0), controller)
        }
      }
    )
    let mergedControllerGroups = mergedWorkspaceGroups.map { group in
      group.compactMap { controllerByWindowIdentifier[$0] }
    }.filter { $0.count > 1 }
    let mergedControllerIdentifiers = Set(
      mergedControllerGroups.flatMap { $0 }.map(ObjectIdentifier.init)
    )
    let controllersInRestoreOrder = mergedControllerGroups.flatMap { $0 } +
      controllers.filter {
        !mergedControllerIdentifiers.contains(ObjectIdentifier($0))
      }
    workspaceRestoreStore.save(
      paths: controllersInRestoreOrder.compactMap(\.repositoryPath),
      mergedWorkspaceGroups: mergedControllerGroups.map {
        $0.compactMap(\.repositoryPath)
      }
    )
  }

  /// 中文：显示器拔出或排列变化后恢复所有应用窗口的可见边界。
  ///
  /// English: Recovers every app window into the visible bounds after a
  /// display is removed or the display arrangement changes.
  private func recoverWindowsAfterScreenParametersChange() {
    guard !isTerminating else { return }
    var changed = false
    var windows: [MainFlutterWindow] = []
    if let repositoryLibraryWindow {
      windows.append(repositoryLibraryWindow)
    }
    windows.append(contentsOf: workspaceControllers().compactMap {
      $0.window as? MainFlutterWindow
    })
    var seen: Set<ObjectIdentifier> = []
    for window in windows where seen.insert(ObjectIdentifier(window)).inserted {
      guard gitDesktopShouldRecoverWindowFrame(window) else {
        continue
      }
      guard let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame
      else {
        continue
      }
      let recovered = gitDesktopRecoveredWindowFrame(
        currentFrame: window.frame,
        visibleFrame: visibleFrame
      )
      guard recovered != window.frame else { continue }
      window.setFrame(recovered, display: window.isVisible, animate: false)
      saveContentSize(of: window, for: window.role)
      changed = true
    }
    if changed {
      persistOpenWorkspaces()
    }
  }

  private func prepareRepositoryLibrary(
    channel: FlutterMethodChannel,
    completion: @escaping () -> Void
  ) {
    var didComplete = false
    let finish = {
      guard !didComplete else {
        return
      }
      didComplete = true
      completion()
    }
    channel.invokeMethod("prepareToClose", arguments: nil) { result in
      if let error = result as? FlutterError {
        NSLog("Repository library cleanup failed: %@", error.message ?? error.code)
      }
      finish()
    }
    DispatchQueue.main.asyncAfter(
      deadline: .now() + gitDesktopEngineCleanupTimeout,
      execute: finish
    )
  }

  /// Persists an unacknowledged registration before delivering it to Dart.
  ///
  /// 中文：首页窗口不可用时保留工作区的仓库登记；首页再次就绪后会重放，直到
  /// Dart 成功确认已处理。
  private func reportRepositoryOpenedToLibrary(repositoryPath: String) {
    repositoryLibraryPendingStore.add(repositoryPath)
    notifyRepositoryLibrary(repositoryPath: repositoryPath)
  }

  /// Replays every registration not yet confirmed by the home Engine. The
  /// pending store remains unchanged until the MethodChannel reply succeeds.
  private func flushPendingRepositoryLibraryRegistrations() {
    for repositoryPath in repositoryLibraryPendingStore.paths {
      notifyRepositoryLibrary(repositoryPath: repositoryPath)
    }
  }

  private func notifyRepositoryLibrary(repositoryPath: String) {
    repositoryLibraryChannel?.invokeMethod(
      "repositoryOpened",
      arguments: ["repositoryPath": repositoryPath]
    ) { [weak self] result in
      guard result == nil else {
        return
      }
      self?.repositoryLibraryPendingStore.remove(repositoryPath)
    }
  }
}
