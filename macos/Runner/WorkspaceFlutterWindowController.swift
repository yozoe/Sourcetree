import Cocoa
import FlutterMacOS
import QuickLookUI

final class WorkspaceFlutterWindowController: NSWindowController,
  NSWindowDelegate {
  private weak var coordinator: WindowCoordinator?
  private let engine: FlutterEngine
  private let flutterViewController: FlutterViewController
  private let windowChannel: FlutterMethodChannel
  private let quickLookDataSource = GitDesktopQuickLookDataSource()
  private let historicalFileStore = GitDesktopHistoricalFileStore()
  private var didShutDownEngine = false
  private var isPreparingForShutdown = false
  private var isPreparedForShutdown = false
  private var shutdownPreparationCompletions: [() -> Void] = []

  var repositoryPath: String?
  let restoresPreviouslyOpenWorkspace: Bool
  let restoresMergedWorkspace: Bool

  /// Whether Flutter has successfully validated the repository for this
  /// workspace. Unverified windows remain usable in the current process but
  /// are excluded from the next-launch restore snapshot.
  ///
  /// 中文：Flutter 是否已成功验证此工作区仓库；未验证窗口可以继续留在当前进程，
  /// 但不会写入下次启动恢复快照。
  private(set) var hasVerifiedRepository = false

  /// Marks this workspace as having passed Flutter-side repository validation.
  /// 中文：标记此工作区已通过 Flutter 侧仓库验证；调用方不能直接改写状态。
  func markRepositoryVerified() {
    hasVerifiedRepository = true
  }

  /// Flutter's last validated Stop Tracking availability for this Engine.
  ///
  /// 中文：此 Engine 最近一次由 Flutter 校验的“停止追踪”可用状态；仅供 AppKit
  /// 即时禁用菜单，真正执行前仍由 Flutter 重新读取 Git 状态。
  private(set) var canStopTrackingFromMenu = false

  /// Flutter's last validated Apply Patch availability for this Engine.
  ///
  /// 中文：此 Engine 最近一次由 Flutter 校验的“应用补丁”可用状态；菜单点击后
  /// Flutter 仍会重新读取仓库 capability，避免使用过期快照执行写操作。
  private(set) var canApplyPatchFromMenu = false

  /// Flutter's last validated Add Remote availability for this Engine.
  /// 中文：此 Engine 最近一次由 Flutter 校验的“添加远端”可用状态；实际写入前
  /// Flutter 会重新读取本地远端配置并拒绝重名。
  private(set) var canAddRemoteFromMenu = false

  /// Flutter's last validated Checkout availability for this Engine.
  /// 中文：此 Engine 最近一次由 Flutter 校验的“检出”可用状态；实际分支或提交切换
  /// 仍由 Flutter 显示影响说明并交给 Git 判断工作区改动是否可安全保留。
  private(set) var canCheckoutFromMenu = false

  /// Flutter's last validated Commit All availability for this Engine.
  /// 中文：此 Engine 最近一次由 Flutter 校验的“提交所有”可用状态。
  private(set) var canCommitAllFromMenu = false

  /// Flutter's last validated Commit Selected availability for this Engine.
  /// 中文：此 Engine 最近一次由 Flutter 校验的“提交选中项”可用状态。
  private(set) var canCommitSelectedFromMenu = false

  /// Whether Flutter validated a session-local hide-changes target.
  /// 中文：Flutter 是否校验出可隐藏的当前会话工作区改动选择。
  private(set) var canHideChangesFromMenu = false

  /// Whether Flutter validated a refresh across configured remotes.
  /// 中文：Flutter 是否校验出可刷新当前仓库已配置远端的能力。
  private(set) var canRefreshRemoteStatusFromMenu = false

  /// Whether Flutter validated a safe fast-forward update from upstream.
  /// 中文：Flutter 是否校验出可从当前 upstream 执行安全快进更新的能力。
  private(set) var canUpdateFromUpstreamFromMenu = false

  /// The active recoverable Git operation and its latest validated actions.
  /// 中文：当前可恢复 Git 操作及其最近一次校验的继续、跳过、中止能力。
  private(set) var activeRepositoryOperationFromMenu: GitDesktopRepositoryOperation?
  private(set) var canContinueOperationFromMenu = false
  private(set) var canSkipOperationFromMenu = false
  private(set) var canAbortOperationFromMenu = false

  /// Flutter-validated actions and labels for the selected conflict file.
  /// 中文：Flutter 为当前选中冲突文件校验的动作与版本标签。
  private(set) var canUseConflictStage2FromMenu = false
  private(set) var canUseConflictStage3FromMenu = false
  private(set) var canMarkConflictResolvedFromMenu = false
  private(set) var conflictStage2LabelFromMenu = "当前基线版本"
  private(set) var conflictStage3LabelFromMenu = "待应用版本"

  /// Flutter's last validated Fetch availability for this Engine.
  ///
  /// 中文：此 Engine 最近一次由 Flutter 校验的“抓取”可用状态；实际执行仍由
  /// Flutter 在显示对话框前重读当前会话能力。
  private(set) var canFetchFromMenu = false

  /// Flutter's last validated Interactive Rebase availability for this Engine.
  /// 中文：此 Engine 最近一次由 Flutter 校验的“交互式变基”可用状态；实际执行前
  /// Flutter 会重新解析当前提交，并由 Git 再次验证历史与工作区状态。
  private(set) var canInteractiveRebaseFromMenu = false

  /// Flutter's last validated Merge availability for this Engine.
  /// 中文：此 Engine 最近一次由 Flutter 校验的“合并”可用状态；执行时仍由
  /// Flutter 显示来源与当前分支并交给 Git 判断冲突。
  private(set) var canMergeFromMenu = false

  /// Flutter's last validated Commit availability for this Engine.
  ///
  /// 中文：此 Engine 最近一次由 Flutter 校验的“提交”可用状态；实际写入前仍由
  /// Flutter 的现有提交流程重新校验 Git 状态。
  private(set) var canCommitFromMenu = false

  /// Flutter's last validated Pull availability for this Engine.
  ///
  /// 中文：此 Engine 最近一次由 Flutter 校验的“拉取”可用状态；实际操作仍由
  /// Flutter 的现有拉取确认流程重新校验 Git 状态。
  private(set) var canPullFromMenu = false

  /// Flutter's last validated Push availability for this Engine.
  ///
  /// 中文：此 Engine 最近一次由 Flutter 校验的“推送”可用状态；实际操作仍由
  /// Flutter 的现有推送确认流程重新校验 Git 状态。
  private(set) var canPushFromMenu = false

  /// Flutter's last validated Remove availability for this Engine.
  /// 中文：此 Engine 最近一次由 Flutter 校验的“移除”可用状态；真正删除前仍由
  /// Flutter 显示影响确认并重新读取当前文件状态。
  private(set) var canRemoveSelectedFromMenu = false

  /// Whether Flutter permits choosing a loaded commit for repository reset.
  /// 中文：Flutter 是否允许为仓库级重置选择一个已加载提交。
  private(set) var canResetRepositoryFromMenu = false

  /// Whether every visible work-tree selection can be restored to HEAD.
  /// 中文：当前全部可见工作区选择是否都可恢复到 HEAD。
  private(set) var canResetSelectedFromMenu = false

  /// Whether the visible history selection is a valid reset target.
  /// 中文：当前可见历史提交选择是否是有效的重置目标。
  private(set) var canResetToSelectedCommitFromMenu = false

  /// Flutter's last validated Branch availability for this Engine.
  ///
  /// 中文：此 Engine 最近一次由 Flutter 校验的“分支”可用状态；实际操作仍由
  /// Flutter 的分支管理流程重新校验 Git 状态。
  private(set) var canCreateBranchFromMenu = false

  /// Flutter's last validated Git-flow v1 Start availability for this Engine.
  /// 中文：此 Engine 最近一次由 Flutter 校验的 Git-flow v1 Start 可用状态；实际执行前
  /// Flutter 会重新读取工作区、引用和进行中的 Git 操作。
  private(set) var canStartGitFlowFromMenu = false

  /// Flutter's last validated Stash availability for this Engine.
  ///
  /// 中文：此 Engine 最近一次由 Flutter 校验的“贮藏”可用状态；实际写入前仍由
  /// Flutter 的贮藏创建流程重新校验 Git 状态。
  private(set) var canStashFromMenu = false

  /// Flutter's last validated Tag availability for this Engine.
  /// 中文：此 Engine 最近一次由 Flutter 校验的“标签”可用状态；面板使用当前
  /// 选中提交或 HEAD 作为默认目标，并由应用层执行最终校验。
  private(set) var canTagFromMenu = false

  /// Whether the current single visible file selection has readable history.
  /// 中文：当前单个可见文件选择是否可读取修改日志。
  private(set) var canViewSelectedFileHistoryFromMenu = false

  /// Whether the current single visible file selection supports read-only Diff.
  /// 中文：当前单个可见文件选择是否支持只读外部差异比对。
  private(set) var canExternalDiffSelectedFromMenu = false

  /// The newest Flutter menu snapshot accepted by this Engine.
  ///
  /// 中文：此 Engine 已接受的最新 Flutter 菜单快照序号；更旧的迟到快照会被拒绝。
  private(set) var workspaceMenuGeneration: Int64 = 0

  /// Whether Flutter can safely add ignore rules for the visible selection.
  /// 中文：Flutter 是否可为当前可见选择安全添加忽略规则。
  private(set) var canIgnoreSelectedFromMenu = false

  /// Whether Flutter can safely copy the visible work-tree selection.
  /// 中文：Flutter 是否允许复制当前可见的工作区文件选择。
  private(set) var canCopySelectedFromMenu = false

  /// Whether Flutter can safely move the visible work-tree selection.
  /// 中文：Flutter 是否允许移动当前可见的工作区文件选择。
  private(set) var canMoveSelectedFromMenu = false

  /// Whether Flutter can open the built-in review for the visible selection.
  /// 中文：Flutter 是否允许为当前可见选择打开内置审查。
  private(set) var canReviewSelectedFromMenu = false

  /// Flutter's last validated Stage Selected availability for this Engine.
  /// 中文：此 Engine 最近一次由 Flutter 校验的“添加到索引”可用状态。
  private(set) var canStageSelectedFromMenu = false

  /// Flutter's last validated Unstage Selected availability for this Engine.
  /// 中文：此 Engine 最近一次由 Flutter 校验的“从索引中取消暂存”可用状态。
  private(set) var canUnstageSelectedFromMenu = false

  /// Flutter-validated custom actions shown by the native Action menu.
  /// 中文：由 Flutter 校验并动态展示在原生“动作”菜单中的自定义操作。
  private(set) var customActionMenuItems: [GitDesktopCustomActionMenuItem] = []

  /// Flutter-validated paths used only by read-only native file actions.
  /// 中文：仅供原生只读文件动作使用、由 Flutter 校验的路径快照。
  private(set) var fileMenuTargets = GitDesktopWorkspaceFileMenuTargets(
    repositoryRootPath: nil,
    selectedFilePaths: [],
    hasFileSelection: false
  )

  /// 中文：创建独立工作区 Engine，并恢复共享的工作区窗口尺寸。
  ///
  /// English: Creates an independent workspace Engine and restores the shared
  /// workspace-window size preference.
  init(
    repositoryPath: String?,
    initialAction: String?,
    restoresPreviouslyOpenWorkspace: Bool = false,
    restoresMergedWorkspace: Bool = false,
    coordinator: WindowCoordinator
  ) throws {
    let project = FlutterDartProject()
    project.dartEntrypointArguments = gitDesktopWorkspaceArguments(
      repositoryPath: repositoryPath,
      initialAction: initialAction,
      restoresPreviouslyOpenWorkspace: restoresPreviouslyOpenWorkspace
    )

    let engine = FlutterEngine(
      name: "git-desktop-workspace-\(UUID().uuidString)",
      project: project,
      allowHeadlessExecution: false
    )
    let flutterViewController = FlutterViewController(
      engine: engine,
      nibName: nil,
      bundle: nil
    )
    guard engine.run(withEntrypoint: nil) else {
      engine.shutDownEngine()
      throw GitDesktopWindowHostError.engineStartFailed
    }

    RegisterGeneratedPlugins(registry: flutterViewController)
    let windowChannel = FlutterMethodChannel(
      name: "com.yeknom.git_desktop/window",
      binaryMessenger: engine.binaryMessenger
    )
    let window = MainFlutterWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.configure(role: .workspace)
    window.installFlutterViewController(flutterViewController)
    window.minSize = NSSize(width: 900, height: 600)
    coordinator.restoreContentSize(of: window, for: .workspace)
    window.center()

    self.coordinator = coordinator
    self.engine = engine
    self.flutterViewController = flutterViewController
    self.windowChannel = windowChannel
    self.repositoryPath = repositoryPath
    self.restoresPreviouslyOpenWorkspace = restoresPreviouslyOpenWorkspace
    self.restoresMergedWorkspace = restoresMergedWorkspace
    super.init(window: window)

    window.delegate = self
    installWindowChannelHandler()
  }

  required init?(coder: NSCoder) {
    nil
  }

  deinit {
    shutDownEngine()
  }

  func showAndActivate() {
    showWindow(nil)
    (window as? MainFlutterWindow)?.bringToFront()
  }

  /// 中文：恢复启动时显示窗口但不创建延迟置前任务，让 Flutter 先完成初始化。
  ///
  /// English: Shows a restored workspace without scheduling a delayed focus
  /// retry, allowing Flutter to finish initialization before windows merge.
  func showForRestoration() {
    guard let window = window as? MainFlutterWindow else {
      return
    }
    window.cancelPendingBringToFront()
    window.orderFront(nil)
  }

  /// Delivers a native menu action to this workspace's Flutter Engine.
  func performWorkspaceAction(_ action: GitDesktopWorkspaceActionID) {
    windowChannel.invokeMethod(
      "workspaceAction",
      arguments: ["action": action.rawValue]
    )
  }

  /// Delivers one validated custom-action ID to this workspace's Flutter
  /// Engine; Flutter performs the final trust, selection and Git-state checks.
  /// 中文：将已校验的自定义操作 ID 投递给当前工作区；最终信任、选择和 Git
  /// 状态复核仍由 Flutter 完成。
  func performCustomAction(_ id: String) {
    guard customActionMenuItems.contains(where: { $0.id == id && $0.isEnabled })
    else { return }
    windowChannel.invokeMethod(
      "workspaceAction",
      arguments: ["action": "customAction:\(id)"]
    )
  }

  func requestClose() {
    prepareForShutdown { [weak self] in
      guard let self else {
        return
      }
      self.window?.performClose(nil)
    }
  }

  func prepareForApplicationTermination(completion: @escaping () -> Void) {
    prepareForShutdown(completion: completion)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if isPreparedForShutdown || didShutDownEngine {
      return true
    }
    requestClose()
    return false
  }

  /// 中文：用户结束实时缩放时立即保存工作区内容区尺寸。
  ///
  /// English: Saves the workspace content size when the user finishes a live
  /// resize operation.
  func windowDidEndLiveResize(_ notification: Notification) {
    guard let window else {
      return
    }
    coordinator?.saveContentSize(of: window, for: .workspace)
  }

  /// 中文：关闭窗口时释放此工作区的协调与 Engine 资源。尺寸由用户结束实时
  /// 缩放时保存，避免较旧的工作区关闭时覆盖最近调整的共享尺寸。
  ///
  /// English: Releases this workspace's coordinator and Engine resources on
  /// close. Live resize completion owns persistence so an older workspace
  /// cannot overwrite the most recently adjusted shared size while closing.
  func windowWillClose(_ notification: Notification) {
    coordinator?.workspaceWillClose(self)
    shutDownEngine()
  }

  private func installWindowChannelHandler() {
    windowChannel.setMethodCallHandler { [weak self] call, result in
      guard let self, let coordinator = self.coordinator else {
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
      let repositoryPath = arguments?["repositoryPath"] as? String
      switch call.method {
      case "openWorkspace":
        let initialAction = arguments?["initialAction"] as? String
        coordinator.openWorkspace(
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
        guard let canonicalPath = gitDesktopCanonicalRepositoryPath(
          repositoryPath
        ) else {
          result(
            FlutterError(
              code: "invalid_repository_registration",
              message: GitDesktopWindowHostError
                .invalidRepositoryRegistration.localizedDescription,
              details: nil
            )
          )
          return
        }
        coordinator.registerRepository(
          canonicalPath,
          for: self
        )
        result(nil)
      case "repositoryStatusUpdated":
        guard let canonicalPath = gitDesktopCanonicalRepositoryPath(
          repositoryPath
        ) else {
          result(
            FlutterError(
              code: "invalid_repository_registration",
              message: GitDesktopWindowHostError
                .invalidRepositoryRegistration.localizedDescription,
              details: nil
            )
          )
          return
        }
        // Status refreshes update the home library only; they never mutate
        // workspace ownership and can therefore not close a tab.
        coordinator.reportRepositoryStatus(canonicalPath)
        result(nil)
      case "repositoryRestoreFailed":
        guard let canonicalPath = gitDesktopCanonicalRepositoryPath(
          repositoryPath
        ) else {
          result(
            FlutterError(
              code: "invalid_repository_registration",
              message: GitDesktopWindowHostError
                .invalidRepositoryRegistration.localizedDescription,
              details: nil
            )
          )
          return
        }
        coordinator.discardFailedRestoredRepository(
          canonicalPath,
          for: self
        )
        result(nil)
      case "setWorkspaceMenuState":
        applyWorkspaceMenuState(arguments)
        result(nil)
      case "performFileAction":
        performFileAction(arguments, result: result)
      case "openHistoricalFile":
        openHistoricalFile(arguments, result: result)
      case "openHistoricalDiff":
        openHistoricalDiff(arguments, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Performs a Flutter-requested read-only file action after independently
  /// validating workspace ownership, repository containment, and existence.
  /// 中文：Flutter 请求只读文件动作时，再次验证工作区归属、仓库边界和文件存在性。
  private func performFileAction(
    _ arguments: [String: Any]?,
    result: @escaping FlutterResult
  ) {
    let requestedRoot = gitDesktopCanonicalRepositoryPath(
      arguments?["repositoryRootPath"] as? String
    )
    let ownedRoot = gitDesktopCanonicalRepositoryPath(repositoryPath)
    guard requestedRoot != nil,
          requestedRoot == ownedRoot,
          let filePaths = arguments?["filePaths"] as? [String],
          !filePaths.isEmpty,
          let action = arguments?["action"] as? String else {
      result(
        FlutterError(
          code: "invalid_file_action",
          message: "The requested file action is not owned by this workspace.",
          details: nil
        )
      )
      return
    }
    let targets = GitDesktopWorkspaceFileMenuTargets(
      repositoryRootPath: requestedRoot,
      selectedFilePaths: filePaths,
      hasFileSelection: true
    )
    let urls = targets.existingSelectedURLs()
    guard urls.count == filePaths.count else {
      result(
        FlutterError(
          code: "file_unavailable",
          message: "The selected work-tree path no longer exists.",
          details: nil
        )
      )
      return
    }

    switch action {
    case "open":
      guard urls.count == 1 else {
        result(
          FlutterError(
            code: "invalid_file_action",
            message: "Opening files requires exactly one selected path.",
            details: nil
          )
        )
        return
      }
      let url = urls[0]
      guard NSWorkspace.shared.open(url) else {
        result(
          FlutterError(
            code: "file_open_failed",
            message: "The selected file could not be opened.",
            details: nil
          )
        )
        return
      }
    case "reveal":
      NSWorkspace.shared.activateFileViewerSelecting(urls)
    case "terminal":
      guard let directory = targets.terminalDirectoryURL(),
            let terminal = NSWorkspace.shared.urlForApplication(
              withBundleIdentifier: "com.apple.Terminal"
            ) else {
        result(
          FlutterError(
            code: "terminal_unavailable",
            message: "Terminal or the selected directory is unavailable.",
            details: nil
          )
        )
        return
      }
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = true
      NSWorkspace.shared.open(
        [directory],
        withApplicationAt: terminal,
        configuration: configuration
      ) { _, error in
        DispatchQueue.main.async {
          if let error {
            result(
              FlutterError(
                code: "terminal_open_failed",
                message: error.localizedDescription,
                details: nil
              )
            )
          } else {
            result(nil)
          }
        }
      }
      return
    case "quickLook":
      guard let panel = QLPreviewPanel.shared() else {
        result(
          FlutterError(
            code: "quick_look_unavailable",
            message: "Quick Look is unavailable.",
            details: nil
          )
        )
        return
      }
      quickLookDataSource.urls = urls
      panel.dataSource = quickLookDataSource
      panel.reloadData()
      panel.makeKeyAndOrderFront(nil)
    default:
      result(FlutterMethodNotImplemented)
      return
    }
    result(nil)
  }

  /// Writes historical bytes to a private host-owned temporary file and opens
  /// it with the system default application. The directory is retained until
  /// this workspace shuts down so external applications can finish reading.
  /// 中文：将历史字节写入宿主持有的私有临时文件并用默认应用打开；目录保留到
  /// 当前工作区关闭，确保外部应用有足够时间完成读取。
  private func openHistoricalFile(
    _ arguments: [String: Any]?,
    result: @escaping FlutterResult
  ) {
    let requestedRoot = gitDesktopCanonicalRepositoryPath(
      arguments?["repositoryRootPath"] as? String
    )
    let ownedRoot = gitDesktopCanonicalRepositoryPath(repositoryPath)
    guard requestedRoot != nil,
          requestedRoot == ownedRoot,
          let typedData = arguments?["bytes"] as? FlutterStandardTypedData,
          typedData.data.count <= 16 * 1024 * 1024,
          let requestedName = arguments?["suggestedFileName"] as? String else {
      result(
        FlutterError(
          code: "invalid_historical_file",
          message: "The historical file request is invalid.",
          details: nil
        )
      )
      return
    }
    do {
      let file = try historicalFileStore.createFile(
        suggestedName: requestedName,
        data: typedData.data
      )
      guard NSWorkspace.shared.open(file) else {
        historicalFileStore.removeFile(file)
        result(
          FlutterError(
            code: "historical_file_open_failed",
            message: "The historical file could not be opened.",
            details: nil
          )
        )
        return
      }
      result(nil)
    } catch {
      result(
        FlutterError(
          code: "historical_file_write_failed",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  /// Opens first-parent before/after snapshots in Apple FileMerge. This fixed
  /// system integration never executes repository-configured diff commands.
  /// 中文：在 Apple FileMerge 中打开第一父提交的前后快照；固定系统集成不会
  /// 执行仓库配置的外部 Diff 命令。
  private func openHistoricalDiff(
    _ arguments: [String: Any]?,
    result: @escaping FlutterResult
  ) {
    let requestedRoot = gitDesktopCanonicalRepositoryPath(
      arguments?["repositoryRootPath"] as? String
    )
    let ownedRoot = gitDesktopCanonicalRepositoryPath(repositoryPath)
    guard requestedRoot != nil,
          requestedRoot == ownedRoot,
          let beforeData = arguments?["beforeBytes"] as? FlutterStandardTypedData,
          let afterData = arguments?["afterBytes"] as? FlutterStandardTypedData,
          beforeData.data.count <= 16 * 1024 * 1024,
          afterData.data.count <= 16 * 1024 * 1024,
          let requestedName = arguments?["suggestedFileName"] as? String else {
      result(
        FlutterError(
          code: "invalid_historical_diff",
          message: "The historical diff request is invalid.",
          details: nil
        )
      )
      return
    }
    guard let applicationURL = NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: "com.apple.FileMerge"
    ) else {
      result(
        FlutterError(
          code: "historical_diff_tool_unavailable",
          message: "Apple FileMerge is not installed.",
          details: nil
        )
      )
      return
    }
    do {
      let beforeFile = try historicalFileStore.createFile(
        suggestedName: "before-\(requestedName)",
        data: beforeData.data
      )
      let afterFile: URL
      do {
        afterFile = try historicalFileStore.createFile(
          suggestedName: "after-\(requestedName)",
          data: afterData.data
        )
      } catch {
        historicalFileStore.removeFile(beforeFile)
        throw error
      }
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = true
      NSWorkspace.shared.open(
        [beforeFile, afterFile],
        withApplicationAt: applicationURL,
        configuration: configuration
      ) { [weak self] _, error in
        DispatchQueue.main.async {
          if let error {
            self?.historicalFileStore.removeFile(beforeFile)
            self?.historicalFileStore.removeFile(afterFile)
            result(
              FlutterError(
                code: "historical_diff_open_failed",
                message: error.localizedDescription,
                details: nil
              )
            )
          } else {
            result(nil)
          }
        }
      }
    } catch {
      result(
        FlutterError(
          code: "historical_diff_write_failed",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  /// Replaces this Engine's complete native-menu snapshot atomically. Calls
  /// arriving after Engine shutdown are ignored so stale capability messages
  /// cannot revive actions for a closed workspace.
  ///
  /// 中文：原子替换此 Engine 的完整原生菜单快照；Engine 关闭后到达的
  /// 过期消息会被忽略，不会重新启用已关闭工作区的操作。
  func applyWorkspaceMenuState(_ arguments: [String: Any]?) {
    guard !didShutDownEngine else { return }
    if let generation = (arguments?["generation"] as? NSNumber)?.int64Value {
      guard generation >= workspaceMenuGeneration else { return }
      workspaceMenuGeneration = generation
    }
    canAddRemoteFromMenu = arguments?["canAddRemote"] as? Bool ?? false
    canStopTrackingFromMenu = arguments?["canStopTracking"] as? Bool ?? false
    canApplyPatchFromMenu = arguments?["canApplyPatch"] as? Bool ?? false
    canCheckoutFromMenu = arguments?["canCheckout"] as? Bool ?? false
    canCommitAllFromMenu = arguments?["canCommitAll"] as? Bool ?? false
    canCommitSelectedFromMenu =
      arguments?["canCommitSelected"] as? Bool ?? false
    canHideChangesFromMenu = arguments?["canHideChanges"] as? Bool ?? false
    canRefreshRemoteStatusFromMenu =
      arguments?["canRefreshRemoteStatus"] as? Bool ?? false
    canUpdateFromUpstreamFromMenu =
      arguments?["canUpdateFromUpstream"] as? Bool ?? false
    let activeOperation =
      (arguments?["activeRepositoryOperation"] as? String).flatMap(
        GitDesktopRepositoryOperation.init(rawValue:)
      )
    activeRepositoryOperationFromMenu = activeOperation
    canContinueOperationFromMenu = activeOperation != nil &&
      (arguments?["canContinueOperation"] as? Bool ?? false)
    canSkipOperationFromMenu = activeOperation != nil &&
      (arguments?["canSkipOperation"] as? Bool ?? false)
    canAbortOperationFromMenu = activeOperation != nil &&
      (arguments?["canAbortOperation"] as? Bool ?? false)
    canUseConflictStage2FromMenu =
      arguments?["canUseConflictStage2"] as? Bool ?? false
    canUseConflictStage3FromMenu =
      arguments?["canUseConflictStage3"] as? Bool ?? false
    canMarkConflictResolvedFromMenu =
      arguments?["canMarkConflictResolved"] as? Bool ?? false
    conflictStage2LabelFromMenu =
      arguments?["conflictStage2Label"] as? String ?? "当前基线版本"
    conflictStage3LabelFromMenu =
      arguments?["conflictStage3Label"] as? String ?? "待应用版本"
    canCommitFromMenu = arguments?["canCommit"] as? Bool ?? false
    canFetchFromMenu = arguments?["canFetch"] as? Bool ?? false
    canInteractiveRebaseFromMenu =
      arguments?["canInteractiveRebase"] as? Bool ?? false
    canMergeFromMenu = arguments?["canMerge"] as? Bool ?? false
    canPullFromMenu = arguments?["canPull"] as? Bool ?? false
    canPushFromMenu = arguments?["canPush"] as? Bool ?? false
    canRemoveSelectedFromMenu =
      arguments?["canRemoveSelected"] as? Bool ?? false
    canResetRepositoryFromMenu =
      arguments?["canResetRepository"] as? Bool ?? false
    canResetSelectedFromMenu =
      arguments?["canResetSelected"] as? Bool ?? false
    canResetToSelectedCommitFromMenu =
      arguments?["canResetToSelectedCommit"] as? Bool ?? false
    canCreateBranchFromMenu = arguments?["canCreateBranch"] as? Bool ?? false
    canStartGitFlowFromMenu = arguments?["canStartGitFlow"] as? Bool ?? false
    canStashFromMenu = arguments?["canStash"] as? Bool ?? false
    canTagFromMenu = arguments?["canTag"] as? Bool ?? false
    canViewSelectedFileHistoryFromMenu =
      arguments?["canViewSelectedFileHistory"] as? Bool ?? false
    canExternalDiffSelectedFromMenu =
      arguments?["canExternalDiffSelected"] as? Bool ?? false
    canIgnoreSelectedFromMenu =
      arguments?["canIgnoreSelected"] as? Bool ?? false
    canCopySelectedFromMenu =
      arguments?["canCopySelected"] as? Bool ?? false
    canMoveSelectedFromMenu =
      arguments?["canMoveSelected"] as? Bool ?? false
    canReviewSelectedFromMenu =
      arguments?["canReviewSelected"] as? Bool ?? false
    canStageSelectedFromMenu =
      arguments?["canStageSelected"] as? Bool ?? false
    canUnstageSelectedFromMenu =
      arguments?["canUnstageSelected"] as? Bool ?? false
    customActionMenuItems = (arguments?["customActions"] as? [[String: Any]] ?? [])
      .compactMap(GitDesktopCustomActionMenuItem.init(dictionary:))
    fileMenuTargets = GitDesktopWorkspaceFileMenuTargets(
      repositoryRootPath: arguments?["repositoryRootPath"] as? String,
      selectedFilePaths: arguments?["selectedFilePaths"] as? [String] ?? [],
      hasFileSelection: arguments?["hasFileSelection"] as? Bool ?? false
    )
  }

  private func prepareForShutdown(completion: @escaping () -> Void) {
    if isPreparedForShutdown || didShutDownEngine {
      completion()
      return
    }
    shutdownPreparationCompletions.append(completion)
    guard !isPreparingForShutdown else {
      return
    }
    isPreparingForShutdown = true

    windowChannel.invokeMethod(
      "prepareToClose",
      arguments: nil
    ) { [weak self] result in
      if let error = result as? FlutterError {
        NSLog("Workspace cleanup failed: %@", error.message ?? error.code)
      }
      self?.finishShutdownPreparation()
    }
    DispatchQueue.main.asyncAfter(
      deadline: .now() + gitDesktopEngineCleanupTimeout
    ) { [weak self] in
      self?.finishShutdownPreparation()
    }
  }

  private func finishShutdownPreparation() {
    guard !isPreparedForShutdown else {
      return
    }
    isPreparedForShutdown = true
    isPreparingForShutdown = false
    let completions = shutdownPreparationCompletions
    shutdownPreparationCompletions.removeAll()
    for completion in completions {
      completion()
    }
  }

  private func shutDownEngine() {
    guard !didShutDownEngine else {
      return
    }
    applyWorkspaceMenuState(nil)
    quickLookDataSource.urls = []
    historicalFileStore.removeAll()
    didShutDownEngine = true
    windowChannel.setMethodCallHandler(nil)
    window?.contentViewController = nil
    engine.shutDownEngine()
  }
}

/// A transient native panel that dismisses through Escape as well as its
/// standard close control.
///
/// 中文：可通过 Escape 或标准关闭按钮退出的短期原生面板。
private final class GitDesktopWorkspaceTabOverviewPanel: NSPanel {
  override func cancelOperation(_ sender: Any?) {
    performClose(sender)
  }
}

/// Owns the transient overview window without taking ownership of any
/// workspace window or Flutter Engine.
///
/// 中文：持有短期标签总览窗口，但不接管任何工作区窗口或
/// Flutter Engine 的生命周期。
final class GitDesktopWorkspaceTabOverviewWindowController:
  NSWindowController, NSWindowDelegate {
  private weak var hostWindow: MainFlutterWindow?
  var onClose: (() -> Void)?

  init(
    hostWindow: MainFlutterWindow,
    windows: [MainFlutterWindow],
    selectedWindow: MainFlutterWindow,
    selectionHandler: @escaping (MainFlutterWindow) -> Void
  ) {
    self.hostWindow = hostWindow
    let tabs = windows.map { window in
      GitDesktopWorkspaceTabDefinition(
        title: window.title,
        isSelected: window === selectedWindow,
        closeAction: {}
      ) { [weak window] in
        guard let window else { return }
        selectionHandler(window)
      }
    }
    let overviewView = GitDesktopWorkspaceTabOverviewView(tabs: tabs)
    let height = min(520, max(280, 118 + (windows.count * 48)))
    let panel = GitDesktopWorkspaceTabOverviewPanel(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: height),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    panel.title = "所有标签页"
    panel.isReleasedWhenClosed = false
    panel.contentView = overviewView
    super.init(window: panel)
    panel.delegate = self
  }

  required init?(coder: NSCoder) {
    nil
  }

  /// Shows the overview centered above its owning workspace.
  /// 中文：在所属工作区上方居中显示标签总览。
  func present() {
    guard let panel = window, let hostWindow else { return }
    let frame = panel.frame
    panel.setFrameOrigin(
      NSPoint(
        x: hostWindow.frame.midX - (frame.width / 2),
        y: hostWindow.frame.midY - (frame.height / 2)
      )
    )
    hostWindow.addChildWindow(panel, ordered: .above)
    panel.makeKeyAndOrderFront(nil)
    if let overview = panel.contentView as? GitDesktopWorkspaceTabOverviewView,
       let selectedButton = overview.tabButtons.first(where: \.isSelectedTab) {
      panel.makeFirstResponder(selectedButton)
    }
  }

  /// Closes the overview and removes its child-window relationship.
  /// 中文：关闭总览并移除它与工作区的子窗口关系。
  func dismiss() {
    if let panel = window {
      hostWindow?.removeChildWindow(panel)
      panel.close()
    }
  }

  /// Releases the host relationship after either programmatic or user-driven
  /// closure.
  ///
  /// 中文：程序或用户关闭总览后释放与宿主窗口的关系。
  func windowWillClose(_ notification: Notification) {
    if let panel = notification.object as? NSWindow {
      hostWindow?.removeChildWindow(panel)
    }
    onClose?()
    onClose = nil
  }
}
