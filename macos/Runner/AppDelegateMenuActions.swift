import Cocoa
import FlutterMacOS
import QuickLookUI

private let gitDesktopCustomActionMenuIdentifier = NSUserInterfaceItemIdentifier(
  "GitDesktop.CustomActions"
)

extension AppDelegate {
  /// 中文：将全部仓库工作区收拢为单行矩形标签组。
  ///
  /// English: Collects all live repository workspaces into one rectangular
  /// strip without sharing their Flutter Engine lifecycles.
  @IBAction func mergeAllRepositoryWindows(_ sender: Any?) {
    windowCoordinator.mergeAllWorkspaceWindows()
  }

  /// 中文：循环切换到合并工作区组中的上一个标签。
  /// English: Selects the previous tab in the merged workspace group.
  @IBAction func selectPreviousRepositoryTabFromMenu(_ sender: Any?) {
    if !windowCoordinator.selectAdjacentMergedWorkspaceFromMenu(offset: -1) {
      NSSound.beep()
    }
  }

  /// 中文：循环切换到合并工作区组中的下一个标签。
  /// English: Selects the next tab in the merged workspace group.
  @IBAction func selectNextRepositoryTabFromMenu(_ sender: Any?) {
    if !windowCoordinator.selectAdjacentMergedWorkspaceFromMenu(offset: 1) {
      NSSound.beep()
    }
  }

  /// 中文：将当前工作区标签移出合并组并保留其独立 Engine。
  /// English: Detaches the current workspace tab while preserving its Engine.
  @IBAction func detachRepositoryTabFromMenu(_ sender: Any?) {
    if !windowCoordinator.detachCurrentWorkspaceFromMergedGroup() {
      NSSound.beep()
    }
  }

  /// 中文：显示或隐藏当前合并工作区的自绘标签栏。
  /// English: Shows or hides the current merged workspace's custom tab strip.
  @IBAction func toggleRepositoryTabBarFromMenu(_ sender: Any?) {
    if !windowCoordinator.toggleCurrentMergedWorkspaceTabStrip() {
      NSSound.beep()
    }
  }

  /// 中文：显示当前合并工作区组的可访问标签总览。
  /// English: Shows the accessible tab overview for the current merged
  /// workspace group.
  @IBAction func showAllRepositoryTabsFromMenu(_ sender: Any?) {
    if !windowCoordinator.showCurrentMergedWorkspaceOverview() {
      NSSound.beep()
    }
  }

  /// 中文：在“移动到显示器”子菜单展开时按当前在线屏幕重建菜单项。
  ///
  /// English: Rebuilds the Move to Display submenu from the currently online
  /// screens whenever it opens.
  func menuNeedsUpdate(_ menu: NSMenu) {
    if menu.identifier == gitDesktopCustomActionMenuIdentifier ||
      menu.title == "自定义操作" || menu.title == "自定义操作（待实现）" {
      updateCustomActionMenu(menu)
      return
    }
    menu.removeAllItems()
    let screens = NSScreen.screens
    guard screens.count > 1 else {
      let item = NSMenuItem(
        title: "没有其他可用显示器",
        action: nil,
        keyEquivalent: ""
      )
      item.isEnabled = false
      menu.addItem(item)
      return
    }
    let currentScreenNumber = (NSApp.keyWindow?.screen?.deviceDescription[
      NSDeviceDescriptionKey("NSScreenNumber")
    ] as? NSNumber)?.uint32Value
    let canMove = gitDesktopCanPerformWindowPlacement(NSApp.keyWindow)
    for (index, screen) in screens.enumerated() {
      guard let screenNumber = screen.deviceDescription[
        NSDeviceDescriptionKey("NSScreenNumber")
      ] as? NSNumber else {
        continue
      }
      let suffix = screen === NSScreen.main ? "（主显示器）" : ""
      let item = NSMenuItem(
        title: "\(screen.localizedName)\(suffix)",
        action: #selector(moveWindowToDisplayFromMenu(_:)),
        keyEquivalent: ""
      )
      item.target = self
      item.representedObject = screenNumber
      item.tag = index
      item.state = screenNumber.uint32Value == currentScreenNumber ? .on : .off
      item.isEnabled = canMove && item.state != .on
      menu.addItem(item)
    }
  }

  /// Rebuilds the native custom-action submenu from the key workspace's
  /// Flutter-validated IDs and display names.
  /// 中文：根据当前前台工作区 Flutter 校验的稳定 ID 和显示名称重建自定义操作子菜单。
  private func updateCustomActionMenu(_ menu: NSMenu) {
    menu.identifier = gitDesktopCustomActionMenuIdentifier
    let actions = windowCoordinator.customActionMenuItemsFromMenu
    let title = actions.isEmpty ? "自定义操作（待实现）" : "自定义操作"
    menu.title = title
    if let parentItem = menu.supermenu?.items.first(where: { $0.submenu === menu }) {
      parentItem.title = title
    }
    menu.removeAllItems()
    guard !actions.isEmpty else {
      let item = NSMenuItem(title: "暂无可用操作（待实现）", action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
      return
    }
    for action in actions {
      let item = NSMenuItem(
        title: action.isEnabled
          ? action.displayName
          : "\(action.displayName)（当前不可用）",
        action: action.isEnabled ? #selector(customActionFromMenu(_:)) : nil,
        keyEquivalent: ""
      )
      item.target = self
      item.representedObject = action.id
      item.isEnabled = action.isEnabled
      menu.addItem(item)
    }
  }

  /// Dispatches one dynamic custom-action ID after the native capability gate.
  /// 中文：通过原生 capability 门槛后，将动态自定义操作 ID 投递给 Flutter。
  @IBAction func customActionFromMenu(_ sender: Any?) {
    guard let item = sender as? NSMenuItem,
          let id = item.representedObject as? String,
          windowCoordinator.canPerformCustomActionFromMenu(id) else {
      NSSound.beep()
      return
    }
    windowCoordinator.performCustomActionFromMenu(id)
  }

  /// 中文：将当前应用窗口移动到菜单项代表的在线显示器并保持完整可见。
  ///
  /// English: Moves the current app window to the represented online display
  /// while keeping its full frame visible.
  @IBAction func moveWindowToDisplayFromMenu(_ sender: Any?) {
    guard let item = sender as? NSMenuItem,
          let targetNumber = item.representedObject as? NSNumber,
          let window = NSApp.keyWindow as? MainFlutterWindow,
          gitDesktopCanPerformWindowPlacement(window),
          let sourceScreen = window.screen ?? NSScreen.main,
          let targetScreen = NSScreen.screens.first(where: { screen in
            (screen.deviceDescription[
              NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber)?.uint32Value == targetNumber.uint32Value
          }),
          targetScreen !== sourceScreen else {
      NSSound.beep()
      return
    }
    let targetFrame = gitDesktopWindowFrame(
      moving: window.frame,
      from: sourceScreen.visibleFrame,
      to: targetScreen.visibleFrame
    )
    window.setFrame(targetFrame, display: true, animate: true)
    windowCoordinator.saveContentSize(of: window, for: window.role)
  }

  @IBAction func createPatchFromMenu(_ sender: Any?) {
    windowCoordinator.performWorkspaceAction(.createPatch)
  }

  @IBAction func applyPatchFromMenu(_ sender: Any?) {
    guard windowCoordinator.canApplyPatchFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.applyPatch)
  }

  @IBAction func repositoryDetailsFromMenu(_ sender: Any?) {
    windowCoordinator.performWorkspaceAction(.repositoryDetails)
  }

  @IBAction func refreshRepositoryFromMenu(_ sender: Any?) {
    windowCoordinator.performWorkspaceAction(.refresh)
  }

  @IBAction func fetchRepositoryFromMenu(_ sender: Any?) {
    guard windowCoordinator.canFetchFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.fetch)
  }

  @IBAction func commitRepositoryFromMenu(_ sender: Any?) {
    guard windowCoordinator.canCommitFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.commit)
  }

  /// Opens Commit All for the key workspace after Flutter validates its scope.
  /// 中文：Flutter 校验提交范围后，在当前 key workspace 打开“提交所有”。
  @IBAction func commitAllRepositoryFromMenu(_ sender: Any?) {
    guard windowCoordinator.canCommitAllFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.commitAll)
  }

  /// Opens Commit Selected for the key workspace's visible file selection.
  /// 中文：为当前 key workspace 的可见文件选择打开“提交选中项”。
  @IBAction func commitSelectedRepositoryFromMenu(_ sender: Any?) {
    guard windowCoordinator.canCommitSelectedFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.commitSelected)
  }

  /// Opens the same selected-path commit workflow from the Action menu.
  /// 中文：从“动作”菜单打开同一套按所选路径提交的流程。
  @IBAction func commitSelectedFromActionMenu(_ sender: Any?) {
    guard windowCoordinator.canCommitSelectedFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.commitSelected)
  }

  /// Opens the repository-level reset target and mode flow.
  /// 中文：打开仓库级重置的目标与模式选择流程。
  @IBAction func resetRepositoryFromMenu(_ sender: Any?) {
    guard windowCoordinator.canResetRepositoryFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.resetRepository)
  }

  /// Restores the current work-tree selection to HEAD after confirmation.
  /// 中文：确认后将当前工作区选择恢复到 HEAD。
  @IBAction func resetSelectedFromMenu(_ sender: Any?) {
    guard windowCoordinator.canResetSelectedFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.resetSelected)
  }

  /// Resets the current branch to the visible selected history commit.
  /// 中文：将当前分支重置到可见的已选历史提交。
  @IBAction func resetToSelectedCommitFromMenu(_ sender: Any?) {
    guard windowCoordinator.canResetToSelectedCommitFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.resetToSelectedCommit)
  }

  /// 中文：在当前 key workspace 打开已有 Git 能力支持的检出目标选择面板。
  /// English: Opens the checkout target picker in the key workspace, backed
  /// by the existing Git application-layer operations.
  @IBAction func checkoutRepositoryFromMenu(_ sender: Any?) {
    guard windowCoordinator.canCheckoutFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.checkout)
  }

  /// 中文：在当前 key workspace 打开已有的本地分支合并流程。
  /// English: Opens the existing local-branch merge workflow in the key
  /// workspace.
  @IBAction func mergeRepositoryFromMenu(_ sender: Any?) {
    guard windowCoordinator.canMergeFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.merge)
  }

  /// 中文：在当前 key workspace 以当前选中提交打开既有交互式变基流程。
  /// English: Opens the existing interactive-rebase workflow for the selected
  /// commit in the key workspace.
  @IBAction func interactiveRebaseRepositoryFromMenu(_ sender: Any?) {
    guard windowCoordinator.canInteractiveRebaseFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.interactiveRebase)
  }

  /// Opens the add-remote form in the current key workspace.
  /// 中文：在当前 key workspace 打开添加远端表单。
  @IBAction func addRemoteRepositoryFromMenu(_ sender: Any?) {
    guard windowCoordinator.canAddRemoteFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.addRemote)
  }

  /// 中文：在当前 key workspace 打开已有的标签管理流程。
  /// English: Opens the existing tag-management workflow in the key workspace.
  @IBAction func tagRepositoryFromMenu(_ sender: Any?) {
    guard windowCoordinator.canTagFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.tag)
  }

  @IBAction func pullRepositoryFromMenu(_ sender: Any?) {
    guard windowCoordinator.canPullFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.pull)
  }

  @IBAction func pushRepositoryFromMenu(_ sender: Any?) {
    guard windowCoordinator.canPushFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.push)
  }

  @IBAction func createBranchRepositoryFromMenu(_ sender: Any?) {
    guard windowCoordinator.canCreateBranchFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.createBranch)
  }

  /// Opens the local-only Git-flow v1 Start flow in the current key workspace.
  /// 中文：在当前 key workspace 打开仅修改本地引用的 Git-flow v1 Start 流程。
  @IBAction func startGitFlowRepositoryFromMenu(_ sender: Any?) {
    guard windowCoordinator.canStartGitFlowFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.startGitFlow)
  }

  @IBAction func stashRepositoryFromMenu(_ sender: Any?) {
    guard windowCoordinator.canStashFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.stash)
  }

  @IBAction func repositoryFeaturePendingFromMenu(_ sender: Any?) {
    windowCoordinator.performWorkspaceAction(.repositoryFeaturePending)
  }

  /// Hides the validated working-tree selection for the current window session.
  /// 中文：在当前窗口会话中隐藏 Flutter 已校验的工作区改动选择。
  @IBAction func hideChangesFromMenu(_ sender: Any?) {
    guard windowCoordinator.canHideChangesFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.hideChanges)
  }

  /// Refreshes all configured remotes through the current workspace session.
  /// 中文：通过当前工作区会话刷新全部已配置远端。
  @IBAction func refreshRemoteStatusFromMenu(_ sender: Any?) {
    guard windowCoordinator.canRefreshRemoteStatusFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.refreshRemoteStatus)
  }

  /// Updates the current branch from its configured upstream using fast-forward only.
  /// 中文：通过当前工作区以仅快进方式从已配置 upstream 更新当前分支。
  @IBAction func updateFromUpstreamFromMenu(_ sender: Any?) {
    guard windowCoordinator.canUpdateFromUpstreamFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.updateFromUpstream)
  }

  /// Continues the active Git operation in the key workspace.
  /// 中文：继续当前前台工作区正在进行的 Git 操作。
  @IBAction func continueRepositoryOperationFromMenu(_ sender: Any?) {
    guard windowCoordinator.canContinueOperationFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.continueOperation)
  }

  /// Skips the current commit in the active sequencer or rebase operation.
  /// 中文：跳过当前前台工作区变基、遴选或回滚操作中的当前提交。
  @IBAction func skipRepositoryOperationFromMenu(_ sender: Any?) {
    guard windowCoordinator.canSkipOperationFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.skipOperation)
  }

  /// Requests confirmation before aborting the active Git operation.
  /// 中文：在中止当前前台工作区的 Git 操作前请求影响确认。
  @IBAction func abortRepositoryOperationFromMenu(_ sender: Any?) {
    guard windowCoordinator.canAbortOperationFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.abortOperation)
  }

  /// Uses index stage 2 for the key workspace's selected conflict file.
  /// 中文：为当前前台工作区选中的冲突文件使用索引第二阶段版本。
  @IBAction func useConflictStage2FromMenu(_ sender: Any?) {
    guard windowCoordinator.canUseConflictStage2FromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.useConflictStage2)
  }

  /// Uses index stage 3 for the key workspace's selected conflict file.
  /// 中文：为当前前台工作区选中的冲突文件使用索引第三阶段版本。
  @IBAction func useConflictStage3FromMenu(_ sender: Any?) {
    guard windowCoordinator.canUseConflictStage3FromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.useConflictStage3)
  }

  /// Stages the key workspace's selected conflict file as resolved.
  /// 中文：将当前前台工作区选中的冲突文件暂存并标记为已解决。
  @IBAction func markConflictResolvedFromMenu(_ sender: Any?) {
    guard windowCoordinator.canMarkConflictResolvedFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.markConflictResolved)
  }

  /// Opens read-only history for the key workspace's selected file.
  /// 中文：为当前前台工作区选中的文件打开只读修改日志。
  @IBAction func viewSelectedFileHistoryFromMenu(_ sender: Any?) {
    guard windowCoordinator.canViewSelectedFileHistoryFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.viewSelectedFileHistory)
  }

  /// Opens the selected file in the configured read-only Diff or FileMerge.
  /// 中文：为当前所选文件打开配置的只读 Diff 工具或 Apple FileMerge。
  @IBAction func externalDiffSelectedFromMenu(_ sender: Any?) {
    guard windowCoordinator.canExternalDiffSelectedFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.externalDiffSelected)
  }

  /// Opens the ignore-rule preview for the key workspace's selection.
  /// 中文：为当前前台工作区选择打开忽略规则预览。
  @IBAction func ignoreSelectedFromMenu(_ sender: Any?) {
    guard windowCoordinator.canIgnoreSelectedFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.ignoreSelected)
  }

  /// Opens the copy preview for the key workspace's selected local files.
  /// 中文：为当前前台工作区选中的本地文件打开复制预览。
  @IBAction func copySelectedFromMenu(_ sender: Any?) {
    guard windowCoordinator.canCopySelectedFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.copySelected)
  }

  /// Opens the move preview for the key workspace's selected local files.
  /// 中文：为当前前台工作区选中的本地文件打开移动预览。
  @IBAction func moveSelectedFromMenu(_ sender: Any?) {
    guard windowCoordinator.canMoveSelectedFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.moveSelected)
  }

  /// Opens the built-in read-only review for the key workspace selection.
  /// 中文：为当前前台工作区选择打开内置只读审查。
  @IBAction func reviewSelectedFromMenu(_ sender: Any?) {
    guard windowCoordinator.canReviewSelectedFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.reviewSelected)
  }

  /// 中文：用系统默认应用打开当前工作区唯一选中的现存文件。
  /// English: Opens the single existing workspace selection in its default app.
  @IBAction func openSelectedFileFromMenu(_ sender: Any?) {
    guard windowCoordinator.canOpenSelectedFileFromMenu,
          let url = windowCoordinator.currentWorkspaceFileMenuTargets?
            .existingSelectedURLs().first else {
      NSSound.beep()
      return
    }
    if !NSWorkspace.shared.open(url) {
      showNativeFileActionError("无法使用系统默认应用打开所选文件。")
    }
  }

  /// 中文：在 Finder 中定位当前文件选择；无选择时定位仓库根目录。
  /// English: Reveals selected files in Finder, or the repository root when no
  /// file is selected.
  @IBAction func revealSelectedFileFromMenu(_ sender: Any?) {
    guard windowCoordinator.canRevealFileFromMenu,
          let targets = windowCoordinator.currentWorkspaceFileMenuTargets else {
      NSSound.beep()
      return
    }
    let urls = targets.hasFileSelection
      ? targets.existingSelectedURLs()
      : [targets.existingRepositoryRootURL()].compactMap { $0 }
    guard !urls.isEmpty else {
      NSSound.beep()
      return
    }
    NSWorkspace.shared.activateFileViewerSelecting(urls)
  }

  /// 中文：在系统 Terminal 中打开仓库或唯一选中文件所在目录。
  /// English: Opens the repository or single selected file's directory in
  /// macOS Terminal without constructing a shell command.
  @IBAction func openSelectedDirectoryInTerminalFromMenu(_ sender: Any?) {
    guard let directory = windowCoordinator.currentWorkspaceFileMenuTargets?
      .terminalDirectoryURL(),
      let terminal = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: "com.apple.Terminal"
      ) else {
      NSSound.beep()
      return
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.open(
      [directory],
      withApplicationAt: terminal,
      configuration: configuration
    ) { [weak self] _, error in
      guard error != nil else { return }
      DispatchQueue.main.async {
        self?.showNativeFileActionError("无法在 Terminal 中打开所选目录。")
      }
    }
  }

  /// 中文：在 macOS Quick Look 面板中预览当前选中的现存文件。
  /// English: Previews the current existing file selection in the macOS Quick
  /// Look panel.
  @IBAction func quickLookSelectedFilesFromMenu(_ sender: Any?) {
    let urls = windowCoordinator.currentWorkspaceFileMenuTargets?
      .existingSelectedURLs() ?? []
    guard windowCoordinator.canQuickLookSelectedFilesFromMenu,
          !urls.isEmpty,
          let panel = QLPreviewPanel.shared() else {
      NSSound.beep()
      return
    }
    quickLookDataSource.urls = urls
    panel.dataSource = quickLookDataSource
    panel.reloadData()
    panel.makeKeyAndOrderFront(nil)
  }

  /// 中文：在当前工作区窗口中显示原生只读文件操作失败。
  /// English: Presents a native read-only file-action failure in the current
  /// workspace window.
  private func showNativeFileActionError(_ message: String) {
    guard let window = NSApp.keyWindow as? MainFlutterWindow else { return }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "无法完成操作"
    alert.informativeText = message
    alert.addButton(withTitle: "好")
    alert.beginSheetModal(for: window)
  }

  /// 中文：将原生“停止追踪”动作投递到当前 key workspace 的 Flutter Engine。
  /// English: Delivers the native Stop Tracking action to the current key
  /// workspace's Flutter Engine.
  @IBAction func stopTrackingFromMenu(_ sender: Any?) {
    guard windowCoordinator.canStopTrackingFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.stopTracking)
  }

  /// 中文：暂存当前前台工作区中由 Flutter 校验的未暂存文件选择。
  /// English: Stages the Flutter-validated unstaged file selection in the key
  /// workspace.
  @IBAction func stageSelectedFromMenu(_ sender: Any?) {
    guard windowCoordinator.canStageSelectedFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.stageSelected)
  }

  /// 中文：取消暂存当前前台工作区中由 Flutter 校验的已暂存文件选择。
  /// English: Unstages the Flutter-validated staged file selection in the key
  /// workspace.
  @IBAction func unstageSelectedFromMenu(_ sender: Any?) {
    guard windowCoordinator.canUnstageSelectedFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.unstageSelected)
  }

  /// 中文：将原生“移除”动作投递到当前 key workspace，并由 Flutter 显示删除确认。
  /// English: Delivers the native Remove action to the key workspace, where
  /// Flutter presents the destructive-file confirmation.
  @IBAction func removeSelectedFromMenu(_ sender: Any?) {
    guard windowCoordinator.canRemoveSelectedFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction(.removeSelected)
  }

  /// 中文：在当前应用窗口中显示尚未交付的窗口菜单提示，不依赖仓库工作区。
  ///
  /// English: Shows a pending window-menu notice in the current app window
  /// without requiring a repository workspace.
  @IBAction func windowFeaturePendingFromMenu(_ sender: Any?) {
    guard let keyWindow = NSApp.keyWindow,
          gitDesktopCanPerformWindowMenuAction(keyWindow) else {
      NSSound.beep()
      return
    }
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "待实现"
    alert.informativeText = "该窗口菜单功能待实现。"
    alert.addButton(withTitle: "好")
    alert.beginSheetModal(for: keyWindow)
  }

  /// 中文：将当前应用窗口填充到所在显示器的可见工作区。
  /// English: Fills the current app window into its display's visible frame.
  @IBAction func fillWindowFromMenu(_ sender: Any?) {
    performWindowPlacement(.fill)
  }

  /// 中文：在所在显示器的可见工作区内居中当前应用窗口。
  /// English: Centers the current app window within its display's visible frame.
  @IBAction func centerWindowFromMenu(_ sender: Any?) {
    performWindowPlacement(.center)
  }

  /// 中文：将当前应用窗口靠齐所在显示器可见工作区左侧。
  /// English: Aligns the current app window to the leading half of its display.
  @IBAction func alignWindowLeadingFromMenu(_ sender: Any?) {
    performWindowPlacement(.leading)
  }

  /// 中文：将当前应用窗口靠齐所在显示器可见工作区右侧。
  /// English: Aligns the current app window to the trailing half of its display.
  @IBAction func alignWindowTrailingFromMenu(_ sender: Any?) {
    performWindowPlacement(.trailing)
  }

  /// 中文：校验当前窗口后应用布局，并保存其角色对应的内容尺寸偏好。
  ///
  /// English: Validates and applies a placement to the current window, then
  /// persists the content-size preference for that window role.
  private func performWindowPlacement(_ placement: GitDesktopWindowPlacement) {
    guard let keyWindow = NSApp.keyWindow as? MainFlutterWindow,
          gitDesktopCanPerformWindowPlacement(keyWindow),
          let screen = keyWindow.screen ?? NSScreen.main else {
      NSSound.beep()
      return
    }
    let targetFrame = gitDesktopWindowFrame(
      currentFrame: keyWindow.frame,
      visibleFrame: screen.visibleFrame,
      minimumSize: NSSize(width: 900, height: 600),
      placement: placement
    )
    keyWindow.setFrame(targetFrame, display: true, animate: true)
    windowCoordinator.saveContentSize(of: keyWindow, for: keyWindow.role)
  }

  @IBAction func showRepositoryLibraryFromMenu(_ sender: Any?) {
    windowCoordinator.showRepositoryLibrary()
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(mergeAllRepositoryWindows(_:)) {
      return windowCoordinator.canMergeAllWorkspaceWindows
    }
    if menuItem.action == #selector(selectPreviousRepositoryTabFromMenu(_:)) ||
       menuItem.action == #selector(selectNextRepositoryTabFromMenu(_:)) ||
       menuItem.action == #selector(detachRepositoryTabFromMenu(_:)) {
      return windowCoordinator.canManageCurrentMergedWorkspace
    }
    if menuItem.action == #selector(toggleRepositoryTabBarFromMenu(_:)) {
      menuItem.title = windowCoordinator.showsCurrentMergedWorkspaceTabStrip
        ? "隐藏标签页栏"
        : "显示标签页栏"
      return windowCoordinator.canManageCurrentMergedWorkspace
    }
    if menuItem.action == #selector(showAllRepositoryTabsFromMenu(_:)) {
      return windowCoordinator.canManageCurrentMergedWorkspace
    }
    if menuItem.action == #selector(moveWindowToDisplayFromMenu(_:)) {
      guard let targetNumber = menuItem.representedObject as? NSNumber,
            let sourceScreen = NSApp.keyWindow?.screen else {
        return false
      }
      let sourceNumber = sourceScreen.deviceDescription[
        NSDeviceDescriptionKey("NSScreenNumber")
      ] as? NSNumber
      return gitDesktopCanPerformWindowPlacement(NSApp.keyWindow) &&
        NSScreen.screens.contains { screen in
          (screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
          ] as? NSNumber)?.uint32Value == targetNumber.uint32Value
        } && sourceNumber?.uint32Value != targetNumber.uint32Value
    }
    if menuItem.action == #selector(windowFeaturePendingFromMenu(_:)) {
      return gitDesktopCanPerformWindowMenuAction(NSApp.keyWindow)
    }
    if menuItem.action == #selector(fillWindowFromMenu(_:)) ||
       menuItem.action == #selector(centerWindowFromMenu(_:)) ||
       menuItem.action == #selector(alignWindowLeadingFromMenu(_:)) ||
       menuItem.action == #selector(alignWindowTrailingFromMenu(_:)) {
      return gitDesktopCanPerformWindowPlacement(NSApp.keyWindow)
    }
    if menuItem.action == #selector(applyPatchFromMenu(_:)) {
      return windowCoordinator.canApplyPatchFromMenu
    }
    if menuItem.action == #selector(openSelectedFileFromMenu(_:)) {
      return windowCoordinator.canOpenSelectedFileFromMenu
    }
    if menuItem.action == #selector(revealSelectedFileFromMenu(_:)) {
      return windowCoordinator.canRevealFileFromMenu
    }
    if menuItem.action == #selector(openSelectedDirectoryInTerminalFromMenu(_:)) {
      return windowCoordinator.canOpenTerminalFromMenu
    }
    if menuItem.action == #selector(quickLookSelectedFilesFromMenu(_:)) {
      return windowCoordinator.canQuickLookSelectedFilesFromMenu
    }
    if menuItem.action == #selector(createPatchFromMenu(_:)) ||
       menuItem.action == #selector(repositoryDetailsFromMenu(_:)) ||
       menuItem.action == #selector(refreshRepositoryFromMenu(_:)) ||
       menuItem.action == #selector(repositoryFeaturePendingFromMenu(_:)) {
      return windowCoordinator.canPerformWorkspaceAction
    }
    if menuItem.action == #selector(hideChangesFromMenu(_:)) {
      return windowCoordinator.canHideChangesFromMenu
    }
    if menuItem.action == #selector(refreshRemoteStatusFromMenu(_:)) {
      return windowCoordinator.canRefreshRemoteStatusFromMenu
    }
    if menuItem.action == #selector(updateFromUpstreamFromMenu(_:)) {
      return windowCoordinator.canUpdateFromUpstreamFromMenu
    }
    if menuItem.action == #selector(stopTrackingFromMenu(_:)) {
      return windowCoordinator.canStopTrackingFromMenu
    }
    if menuItem.action == #selector(stageSelectedFromMenu(_:)) {
      return windowCoordinator.canStageSelectedFromMenu
    }
    if menuItem.action == #selector(unstageSelectedFromMenu(_:)) {
      return windowCoordinator.canUnstageSelectedFromMenu
    }
    if menuItem.action == #selector(removeSelectedFromMenu(_:)) {
      return windowCoordinator.canRemoveSelectedFromMenu
    }
    if menuItem.action == #selector(resetRepositoryFromMenu(_:)) {
      return windowCoordinator.canResetRepositoryFromMenu
    }
    if menuItem.action == #selector(resetSelectedFromMenu(_:)) {
      return windowCoordinator.canResetSelectedFromMenu
    }
    if menuItem.action == #selector(resetToSelectedCommitFromMenu(_:)) {
      return windowCoordinator.canResetToSelectedCommitFromMenu
    }
    if menuItem.action == #selector(continueRepositoryOperationFromMenu(_:)) {
      menuItem.title = windowCoordinator.activeRepositoryOperationFromMenu.map {
        "继续\($0.menuName)"
      } ?? "继续"
      return windowCoordinator.canContinueOperationFromMenu
    }
    if menuItem.action == #selector(abortRepositoryOperationFromMenu(_:)) {
      menuItem.title = windowCoordinator.activeRepositoryOperationFromMenu.map {
        "中止\($0.menuName)"
      } ?? "中止"
      return windowCoordinator.canAbortOperationFromMenu
    }
    if menuItem.action == #selector(skipRepositoryOperationFromMenu(_:)) {
      menuItem.title = windowCoordinator.activeRepositoryOperationFromMenu.map {
        "跳过当前\($0.menuName)提交"
      } ?? "跳过当前提交"
      return windowCoordinator.canSkipOperationFromMenu
    }
    if menuItem.action == #selector(useConflictStage2FromMenu(_:)) {
      menuItem.title =
        "使用\(windowCoordinator.conflictStage2LabelFromMenu)（Git stage 2）"
      return windowCoordinator.canUseConflictStage2FromMenu
    }
    if menuItem.action == #selector(useConflictStage3FromMenu(_:)) {
      menuItem.title =
        "使用\(windowCoordinator.conflictStage3LabelFromMenu)（Git stage 3）"
      return windowCoordinator.canUseConflictStage3FromMenu
    }
    if menuItem.action == #selector(markConflictResolvedFromMenu(_:)) {
      return windowCoordinator.canMarkConflictResolvedFromMenu
    }
    if menuItem.action == #selector(viewSelectedFileHistoryFromMenu(_:)) {
      return windowCoordinator.canViewSelectedFileHistoryFromMenu
    }
    if menuItem.action == #selector(externalDiffSelectedFromMenu(_:)) {
      return windowCoordinator.canExternalDiffSelectedFromMenu
    }
    if menuItem.action == #selector(ignoreSelectedFromMenu(_:)) {
      return windowCoordinator.canIgnoreSelectedFromMenu
    }
    if menuItem.action == #selector(copySelectedFromMenu(_:)) {
      return windowCoordinator.canCopySelectedFromMenu
    }
    if menuItem.action == #selector(moveSelectedFromMenu(_:)) {
      return windowCoordinator.canMoveSelectedFromMenu
    }
    if menuItem.action == #selector(reviewSelectedFromMenu(_:)) {
      return windowCoordinator.canReviewSelectedFromMenu
    }
    if menuItem.action == #selector(fetchRepositoryFromMenu(_:)) {
      return windowCoordinator.canFetchFromMenu
    }
    if menuItem.action == #selector(commitRepositoryFromMenu(_:)) {
      return windowCoordinator.canCommitFromMenu
    }
    if menuItem.action == #selector(commitAllRepositoryFromMenu(_:)) {
      return windowCoordinator.canCommitAllFromMenu
    }
    if menuItem.action == #selector(commitSelectedRepositoryFromMenu(_:)) {
      return windowCoordinator.canCommitSelectedFromMenu
    }
    if menuItem.action == #selector(commitSelectedFromActionMenu(_:)) {
      return windowCoordinator.canCommitSelectedFromMenu
    }
    if menuItem.action == #selector(checkoutRepositoryFromMenu(_:)) {
      return windowCoordinator.canCheckoutFromMenu
    }
    if menuItem.action == #selector(interactiveRebaseRepositoryFromMenu(_:)) {
      return windowCoordinator.canInteractiveRebaseFromMenu
    }
    if menuItem.action == #selector(addRemoteRepositoryFromMenu(_:)) {
      return windowCoordinator.canAddRemoteFromMenu
    }
    if menuItem.action == #selector(mergeRepositoryFromMenu(_:)) {
      return windowCoordinator.canMergeFromMenu
    }
    if menuItem.action == #selector(tagRepositoryFromMenu(_:)) {
      return windowCoordinator.canTagFromMenu
    }
    if menuItem.action == #selector(pullRepositoryFromMenu(_:)) {
      return windowCoordinator.canPullFromMenu
    }
    if menuItem.action == #selector(pushRepositoryFromMenu(_:)) {
      return windowCoordinator.canPushFromMenu
    }
    if menuItem.action == #selector(createBranchRepositoryFromMenu(_:)) {
      return windowCoordinator.canCreateBranchFromMenu
    }
    if menuItem.action == #selector(startGitFlowRepositoryFromMenu(_:)) {
      return windowCoordinator.canStartGitFlowFromMenu
    }
    if menuItem.action == #selector(stashRepositoryFromMenu(_:)) {
      return windowCoordinator.canStashFromMenu
    }
    return true
  }


}
