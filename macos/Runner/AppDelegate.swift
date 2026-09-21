import Cocoa
import FlutterMacOS
import QuickLookUI

private let gitDesktopEngineCleanupTimeout: TimeInterval = 3.5
private let gitDesktopWorkspaceRestorationTimeout: TimeInterval = 30

/// Returns whether the native Stop Tracking command may target its key window.
/// 中文：判断原生“停止追踪”菜单能否安全作用于当前前台工作区。
func gitDesktopCanPerformStopTrackingMenuAction(
  hasKeyWorkspace: Bool,
  hasValidatedTrackedSelection: Bool
) -> Bool {
  hasKeyWorkspace && hasValidatedTrackedSelection
}

/// Returns whether Apply Patch may target the key repository workspace.
/// 中文：判断原生“应用补丁”菜单能否安全作用于当前前台仓库工作区。
func gitDesktopCanPerformApplyPatchMenuAction(
  hasKeyWorkspace: Bool,
  hasRepositoryMutationCapability: Bool
) -> Bool {
  hasKeyWorkspace && hasRepositoryMutationCapability
}

/// Returns whether a native selected-file mutation may target the key window.
/// 中文：判断原生选中文件写操作能否安全作用于当前前台工作区。
func gitDesktopCanPerformSelectedChangeMenuAction(
  hasKeyWorkspace: Bool,
  hasValidatedSelection: Bool
) -> Bool {
  hasKeyWorkspace && hasValidatedSelection
}

/// A recoverable Git operation reported by one Flutter workspace Engine.
/// 中文：由单个 Flutter 工作区 Engine 上报、可继续或中止的 Git 操作。
enum GitDesktopRepositoryOperation: String {
  case merge
  case rebase
  case cherryPick
  case revert

  /// The localized operation name used by dynamic native menu labels.
  /// 中文：动态原生菜单标题使用的本地化操作名称。
  var menuName: String {
    switch self {
    case .merge: return "合并"
    case .rebase: return "变基"
    case .cherryPick: return "遴选"
    case .revert: return "回滚"
    }
  }
}

/// Read-only file targets reported by one Flutter workspace Engine.
/// 中文：单个 Flutter 工作区 Engine 上报的只读文件操作目标。
struct GitDesktopWorkspaceFileMenuTargets {
  let repositoryRootPath: String?
  let selectedFilePaths: [String]
  let hasFileSelection: Bool

  /// 中文：规范化平台路径并拒绝仓库根目录以外或重复的选择。
  /// English: Normalizes platform paths and rejects selections outside the
  /// repository root or duplicate targets.
  init(
    repositoryRootPath: String?,
    selectedFilePaths: [String],
    hasFileSelection: Bool
  ) {
    let root = repositoryRootPath.map {
      URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path
    }
    var seen: Set<String> = []
    let validated = selectedFilePaths.compactMap { candidate -> String? in
      guard let root else { return nil }
      let path = URL(fileURLWithPath: candidate).standardizedFileURL.path
      let separator = root == "/" ? root : root + "/"
      guard path != root,
            path.hasPrefix(separator),
            seen.insert(path).inserted else {
        return nil
      }
      return path
    }
    self.repositoryRootPath = root
    self.selectedFilePaths = validated.count == selectedFilePaths.count
      ? validated
      : []
    self.hasFileSelection = hasFileSelection
  }

  /// 中文：返回执行时仍存在的全部选中文件；部分失效时返回空集合。
  /// English: Returns every selected path if all still exist at execution
  /// time, otherwise an empty collection.
  func existingSelectedURLs(
    fileManager: FileManager = .default
  ) -> [URL] {
    guard hasFileSelection, !selectedFilePaths.isEmpty else { return [] }
    let urls = selectedFilePaths.map { URL(fileURLWithPath: $0) }
    return urls.allSatisfy { fileManager.fileExists(atPath: $0.path) }
      ? urls
      : []
  }

  /// Returns every selected path only when all are existing regular files.
  /// 中文：仅当全部选择仍是普通文件时返回其 URL；目录、链接和失效选择均拒绝。
  func existingRegularFileURLs(
    fileManager: FileManager = .default
  ) -> [URL] {
    let urls = existingSelectedURLs(fileManager: fileManager)
    guard !urls.isEmpty else { return [] }
    for url in urls {
      guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
            attributes[.type] as? FileAttributeType == .typeRegular else {
        return []
      }
    }
    return urls
  }

  /// 中文：返回仍存在的仓库根目录。
  /// English: Returns the repository root while it remains a directory.
  func existingRepositoryRootURL(
    fileManager: FileManager = .default
  ) -> URL? {
    guard let repositoryRootPath else { return nil }
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(
      atPath: repositoryRootPath,
      isDirectory: &isDirectory
    ), isDirectory.boolValue else {
      return nil
    }
    return URL(fileURLWithPath: repositoryRootPath, isDirectory: true)
  }

  /// 中文：解析终端应打开的仓库目录或唯一选中文件所在目录。
  /// English: Resolves the repository directory or the single selected file's
  /// containing directory for Terminal.
  func terminalDirectoryURL(
    fileManager: FileManager = .default
  ) -> URL? {
    guard hasFileSelection else {
      return existingRepositoryRootURL(fileManager: fileManager)
    }
    let urls = existingSelectedURLs(fileManager: fileManager)
    guard urls.count == 1 else { return nil }
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: urls[0].path, isDirectory: &isDirectory)
    else {
      return nil
    }
    return isDirectory.boolValue ? urls[0] : urls[0].deletingLastPathComponent()
  }
}

/// Owns the URLs shown by the shared macOS Quick Look panel.
/// 中文：持有 macOS 共享 Quick Look 面板当前预览的文件 URL。
final class GitDesktopQuickLookDataSource: NSObject, QLPreviewPanelDataSource {
  var urls: [URL] = []

  func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
    urls.count
  }

  func previewPanel(
    _ panel: QLPreviewPanel!,
    previewItemAt index: Int
  ) -> QLPreviewItem! {
    urls[index] as NSURL
  }
}

/// Owns private temporary files opened from immutable historical Git blobs.
/// 中文：持有从不可变历史 Git blob 导出的私有临时文件。
final class GitDesktopHistoricalFileStore {
  private let baseDirectory: URL
  private(set) var directories: [URL] = []

  init(baseDirectory: URL = FileManager.default.temporaryDirectory) {
    self.baseDirectory = baseDirectory
  }

  /// Creates one private file while preserving only the safe basename.
  /// 中文：仅保留安全 basename，并创建权限受限的临时文件。
  func createFile(suggestedName: String, data: Data) throws -> URL {
    let fileName = URL(fileURLWithPath: suggestedName).lastPathComponent
    guard !fileName.isEmpty, fileName != ".", fileName != ".." else {
      throw CocoaError(.fileWriteInvalidFileName)
    }
    let directory = baseDirectory.appendingPathComponent(
      "git-desktop-history-\(UUID().uuidString)",
      isDirectory: true
    )
    do {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      let file = directory.appendingPathComponent(fileName, isDirectory: false)
      try data.write(to: file, options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: file.path
      )
      directories.append(directory)
      return file
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  /// Removes every artifact owned by this workspace.
  /// 中文：删除当前工作区持有的全部历史文件临时产物。
  func removeAll() {
    for directory in directories {
      try? FileManager.default.removeItem(at: directory)
    }
    directories.removeAll()
  }

  /// Removes the directory containing one file created by this store.
  /// 中文：删除由该存储创建的指定文件及其私有目录。
  func removeFile(_ file: URL) {
    let directory = file.deletingLastPathComponent()
    guard let index = directories.firstIndex(of: directory) else { return }
    try? FileManager.default.removeItem(at: directory)
    directories.remove(at: index)
  }

  deinit {
    removeAll()
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

/// Removes one explicitly detached workspace from the pending restored group.
/// 中文：从待恢复的标签组意图中移除用户明确拆出的工作区，避免迟到验证撤销操作。
func gitDesktopMergedWorkspacePaths(
  _ paths: [String],
  afterDetaching detachedPath: String?
) -> [String] {
  guard let detachedPath else { return paths }
  return paths.filter { $0 != detachedPath }
}

func gitDesktopWorkspaceArguments(
  repositoryPath: String?,
  initialAction: String?,
  restoresPreviouslyOpenWorkspace: Bool = false
) -> [String] {
  var arguments = ["--git-desktop-workspace"]
  if let repositoryPath {
    arguments.append("--git-desktop-repository=\(repositoryPath)")
  }
  if let initialAction, !initialAction.isEmpty {
    arguments.append("--git-desktop-action=\(initialAction)")
  }
  if restoresPreviouslyOpenWorkspace {
    arguments.append("--git-desktop-restored-workspace")
  }
  return arguments
}

final class GitDesktopWorkspaceIndex<Host: AnyObject> {
  private var hostsByPath: [String: Host] = [:]

  var allHosts: [Host] {
    Array(hostsByPath.values)
  }

  func host(for repositoryPath: String) -> Host? {
    hostsByPath[repositoryPath]
  }

  @discardableResult
  func register(_ host: Host, for repositoryPath: String) -> Host? {
    hostsByPath.updateValue(host, forKey: repositoryPath)
  }

  func remove(_ host: Host) {
    let ownedPaths = hostsByPath.compactMap { repositoryPath, candidate in
      candidate === host ? repositoryPath : nil
    }
    for repositoryPath in ownedPaths {
      hostsByPath.removeValue(forKey: repositoryPath)
    }
  }

  func removeAll() {
    hostsByPath.removeAll()
  }
}

final class GitDesktopWorkspaceHistory<Host: AnyObject> {
  private var hosts: [Host] = []

  var mostRecent: Host? {
    hosts.last
  }

  func markRecent(_ host: Host) {
    hosts.removeAll { $0 === host }
    hosts.append(host)
  }

  func remove(_ host: Host) {
    hosts.removeAll { $0 === host }
  }

  func removeAll() {
    hosts.removeAll()
  }
}

/// Tracks the application window that was most recently placed in front.
///
/// This deliberately includes the repository library and workspaces: Dock
/// reactivation should restore the user's current context, not always the
/// startup window.
final class GitDesktopWindowFocusHistory<Host: AnyObject> {
  private weak var frontmostHost: Host?

  var frontmost: Host? {
    frontmostHost
  }

  func markFrontmost(_ host: Host) {
    frontmostHost = host
  }
}

/// Captures the restorable repository workspaces and merged-strip state.
struct GitDesktopWorkspaceRestoreSnapshot {
  let paths: [String]
  let mergedWorkspacePaths: [String]

  var restoresMergedWorkspaces: Bool {
    mergedWorkspacePaths.count > 1
  }
}

struct GitDesktopWorkspaceRestorationCompletion: Equatable {
  let resolvedPaths: [String]
  /// Paths that did not answer before the bounded wait; their windows remain open.
  let timedOutPathsToKeepOpen: [String]
  let mergedPathsToRestore: [String]

  var shouldMerge: Bool {
    mergedPathsToRestore.count > 1
  }
}

enum GitDesktopWorkspaceRestorationResolution: Equatable {
  case unrelated
  case waiting
  case finished(GitDesktopWorkspaceRestorationCompletion)
}

/// 中文：等待本次启动需要恢复的全部仓库给出成功或失败结果，再允许合并窗口。
///
/// English: Waits for every repository restored during this launch to resolve
/// successfully or unsuccessfully before allowing the windows to merge.
final class GitDesktopWorkspaceRestorationGate {
  private var orderedPaths: [String] = []
  private var pendingPaths: Set<String> = []
  private var resolvedPaths: Set<String> = []
  private var mergedPaths: Set<String> = []

  var isWaiting: Bool {
    !pendingPaths.isEmpty
  }

  /// 中文：开始跟踪一批待验证的恢复路径及其目标合并状态。
  ///
  /// English: Starts tracking a batch of restore paths and its intended merge
  /// state after verification.
  func begin(
    paths: [String],
    shouldMerge: Bool = false,
    mergedPaths: [String]? = nil
  ) {
    var seen: Set<String> = []
    orderedPaths = paths.filter { seen.insert($0).inserted }
    pendingPaths = Set(orderedPaths)
    resolvedPaths.removeAll()
    let requestedMergedPaths = mergedPaths ?? (shouldMerge ? orderedPaths : [])
    self.mergedPaths = Set(requestedMergedPaths).intersection(pendingPaths)
  }

  /// 中文：记录一个恢复路径已完成，并在最后一个路径完成时返回合并决策。
  ///
  /// English: Resolves one restored path and returns the merge decision only
  /// when the last pending path has completed.
  func resolve(_ path: String) -> GitDesktopWorkspaceRestorationResolution {
    guard pendingPaths.remove(path) != nil else {
      return .unrelated
    }
    resolvedPaths.insert(path)
    guard pendingPaths.isEmpty else {
      return .waiting
    }
    return .finished(finish())
  }

  /// 中文：结束仍在等待的恢复批次，并分别返回已完成与超时路径。
  ///
  /// English: Finishes a still-pending restore batch and returns its resolved
  /// and timed-out paths separately.
  func finishPending() -> GitDesktopWorkspaceRestorationCompletion? {
    guard !pendingPaths.isEmpty else {
      return nil
    }
    return finish()
  }

  private func finish() -> GitDesktopWorkspaceRestorationCompletion {
    let completion = GitDesktopWorkspaceRestorationCompletion(
      resolvedPaths: orderedPaths.filter { resolvedPaths.contains($0) },
      timedOutPathsToKeepOpen: orderedPaths.filter { pendingPaths.contains($0) },
      mergedPathsToRestore: orderedPaths.filter {
        resolvedPaths.contains($0) && mergedPaths.contains($0)
      }
    )
    orderedPaths.removeAll()
    pendingPaths.removeAll()
    resolvedPaths.removeAll()
    mergedPaths.removeAll()
    return completion
  }
}

/// Persists only repository workspace paths that were successfully opened.
///
/// The store deliberately lives on the native side because it describes
/// window ownership, rather than Git session state. Closing one workspace
/// removes it from the next-launch restore list; application termination keeps
/// the current list intact for the next process.
final class GitDesktopWorkspaceRestoreStore {
  private static let pathsKey = "gitDesktopOpenWorkspacePaths"
  private static let mergedWorkspacesKey = "gitDesktopRestoresMergedWorkspaces"
  private static let mergedWorkspacePathsKey =
    "gitDesktopMergedWorkspacePaths"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var snapshot: GitDesktopWorkspaceRestoreSnapshot {
    guard let rawPaths = defaults.array(forKey: Self.pathsKey) as? [String]
    else {
      return GitDesktopWorkspaceRestoreSnapshot(
        paths: [],
        mergedWorkspacePaths: []
      )
    }
    let paths = normalizedPaths(rawPaths)
    let storedMergedPaths = defaults.array(
      forKey: Self.mergedWorkspacePathsKey
    ) as? [String]
    let mergedCandidates = storedMergedPaths ?? (
      defaults.bool(forKey: Self.mergedWorkspacesKey) ? paths : []
    )
    let pathSet = Set(paths)
    let mergedPaths = normalizedPaths(mergedCandidates).filter {
      pathSet.contains($0)
    }
    return GitDesktopWorkspaceRestoreSnapshot(
      paths: paths,
      mergedWorkspacePaths: mergedPaths.count > 1 ? mergedPaths : []
    )
  }

  var paths: [String] {
    snapshot.paths
  }

  func save(
    paths: [String],
    restoresMergedWorkspaces: Bool = false,
    mergedWorkspacePaths: [String]? = nil
  ) {
    let normalized = normalizedPaths(paths)
    let normalizedSet = Set(normalized)
    let requestedMergedPaths = mergedWorkspacePaths ?? (
      restoresMergedWorkspaces ? normalized : []
    )
    let merged = normalizedPaths(requestedMergedPaths).filter {
      normalizedSet.contains($0)
    }
    let persistedMerged = merged.count > 1 ? merged : []
    defaults.set(normalized, forKey: Self.pathsKey)
    defaults.set(persistedMerged, forKey: Self.mergedWorkspacePathsKey)
    defaults.set(
      persistedMerged.count == normalized.count && normalized.count > 1,
      forKey: Self.mergedWorkspacesKey
    )
  }

  private func normalizedPaths(_ candidates: [String]) -> [String] {
    var result: [String] = []
    var seen: Set<String> = []
    for candidate in candidates {
      guard let path = gitDesktopCanonicalRepositoryPath(candidate),
            seen.insert(path).inserted else {
        continue
      }
      result.append(path)
    }
    return result
  }
}

/// Retains repository registrations until the home Engine confirms it has
/// added them to its own persistent library.
///
/// The native coordinator owns this cross-Engine handoff because the home
/// window may be closed while a workspace finishes opening a repository. A
/// successful Dart method reply removes the path; otherwise it is replayed
/// when a replacement home Engine becomes ready.
final class GitDesktopRepositoryLibraryPendingStore {
  private static let pathsKey = "gitDesktopPendingRepositoryLibraryPaths"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var paths: [String] {
    normalizedPaths(defaults.array(forKey: Self.pathsKey) as? [String] ?? [])
  }

  func add(_ path: String) {
    defaults.set(normalizedPaths(paths + [path]), forKey: Self.pathsKey)
  }

  func remove(_ path: String) {
    guard let canonicalPath = gitDesktopCanonicalRepositoryPath(path) else {
      return
    }
    defaults.set(paths.filter { $0 != canonicalPath }, forKey: Self.pathsKey)
  }

  private func normalizedPaths(_ candidates: [String]) -> [String] {
    var result: [String] = []
    var seen: Set<String> = []
    for candidate in candidates {
      guard let path = gitDesktopCanonicalRepositoryPath(candidate),
            seen.insert(path).inserted else {
        continue
      }
      result.append(path)
    }
    return result
  }
}

/// 中文：将窗口内容区尺寸限制在有效的最小值和当前屏幕可见范围内。
///
/// English: Constrains a window content size to valid minimum dimensions and
/// the current screen's visible bounds.
func gitDesktopConstrainedWindowContentSize(
  _ preferredSize: NSSize?,
  default defaultSize: NSSize,
  minimum minimumSize: NSSize,
  maximum maximumSize: NSSize? = nil
) -> NSSize {
  func validDimension(_ value: CGFloat) -> Bool {
    value.isFinite && value > 0
  }

  let preferred = preferredSize.flatMap { size in
    validDimension(size.width) && validDimension(size.height) ? size : nil
  } ?? defaultSize
  let maximumWidth = maximumSize.flatMap { size in
    validDimension(size.width) ? size.width : nil
  } ?? .greatestFiniteMagnitude
  let maximumHeight = maximumSize.flatMap { size in
    validDimension(size.height) ? size.height : nil
  } ?? .greatestFiniteMagnitude
  let minimumWidth = min(minimumSize.width, maximumWidth)
  let minimumHeight = min(minimumSize.height, maximumHeight)
  return NSSize(
    width: min(max(preferred.width, minimumWidth), maximumWidth),
    height: min(max(preferred.height, minimumHeight), maximumHeight)
  )
}

/// 中文：分别持久化仓库浏览器与工作区窗口的内容区尺寸。
///
/// English: Persists content sizes independently for the repository library
/// and workspace window roles.
final class GitDesktopWindowSizeStore {
  private static let repositoryLibraryKey =
    "gitDesktopRepositoryLibraryWindowContentSize"
  private static let workspaceKey = "gitDesktopWorkspaceWindowContentSize"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// 中文：保存指定窗口类型的有效内容区尺寸；无效值不会覆盖现有偏好。
  ///
  /// English: Saves a valid content size for one window role without letting
  /// invalid values replace an existing preference.
  func save(_ size: NSSize, for role: GitDesktopWindowRole) {
    guard size.width.isFinite,
          size.height.isFinite,
          size.width > 0,
          size.height > 0 else {
      return
    }
    defaults.set(
      ["width": Double(size.width), "height": Double(size.height)],
      forKey: key(for: role)
    )
  }

  /// 中文：读取并约束指定窗口类型的尺寸，缺失或损坏时返回默认值。
  ///
  /// English: Reads and constrains one window role's size, falling back to the
  /// default when the stored value is missing or corrupt.
  func restoredSize(
    for role: GitDesktopWindowRole,
    default defaultSize: NSSize,
    minimum minimumSize: NSSize,
    maximum maximumSize: NSSize? = nil
  ) -> NSSize {
    let dictionary = defaults.dictionary(forKey: key(for: role))
    let width = (dictionary?["width"] as? NSNumber)?.doubleValue
    let height = (dictionary?["height"] as? NSNumber)?.doubleValue
    let storedSize = width.flatMap { width in
      height.map { height in
        NSSize(width: width, height: height)
      }
    }
    return gitDesktopConstrainedWindowContentSize(
      storedSize,
      default: defaultSize,
      minimum: minimumSize,
      maximum: maximumSize
    )
  }

  private func key(for role: GitDesktopWindowRole) -> String {
    switch role {
    case .repositoryLibrary:
      Self.repositoryLibraryKey
    case .workspace:
      Self.workspaceKey
    }
  }
}

/// 中文：返回追加新工作区后的实时合并窗口顺序；当前不存在合并组时返回 nil。
///
/// English: Returns the live merged-window order after adding a newly opened
/// workspace, or nil when there is no existing merged group to extend.
func gitDesktopMergedWorkspaceOrderByAddingWindow(
  existingOrder: [ObjectIdentifier],
  liveWindowIdentifiers: Set<ObjectIdentifier>,
  newWindowIdentifier: ObjectIdentifier
) -> [ObjectIdentifier]? {
  let liveMergedOrder = existingOrder.filter(liveWindowIdentifiers.contains)
  guard liveMergedOrder.count > 1,
        !liveMergedOrder.contains(newWindowIdentifier) else {
    return nil
  }
  return liveMergedOrder + [newWindowIdentifier]
}

private enum GitDesktopWindowHostError: LocalizedError {
  case engineStartFailed
  case invalidRepositoryRegistration

  var errorDescription: String? {
    switch self {
    case .engineStartFailed:
      return "The Flutter engine for the repository workspace did not start."
    case .invalidRepositoryRegistration:
      return "The workspace repository could not be registered."
    }
  }
}

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
  fileprivate(set) var hasVerifiedRepository = false

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

  /// The active recoverable Git operation and its latest validated actions.
  /// 中文：当前可恢复 Git 操作及其最近一次校验的继续、中止能力。
  private(set) var activeRepositoryOperationFromMenu: GitDesktopRepositoryOperation?
  private(set) var canContinueOperationFromMenu = false
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
  func performWorkspaceAction(_ action: String) {
    windowChannel.invokeMethod("workspaceAction", arguments: ["action": action])
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
    canAddRemoteFromMenu = arguments?["canAddRemote"] as? Bool ?? false
    canStopTrackingFromMenu = arguments?["canStopTracking"] as? Bool ?? false
    canApplyPatchFromMenu = arguments?["canApplyPatch"] as? Bool ?? false
    canCheckoutFromMenu = arguments?["canCheckout"] as? Bool ?? false
    canCommitAllFromMenu = arguments?["canCommitAll"] as? Bool ?? false
    canCommitSelectedFromMenu =
      arguments?["canCommitSelected"] as? Bool ?? false
    let activeOperation =
      (arguments?["activeRepositoryOperation"] as? String).flatMap(
        GitDesktopRepositoryOperation.init(rawValue:)
      )
    activeRepositoryOperationFromMenu = activeOperation
    canContinueOperationFromMenu = activeOperation != nil &&
      (arguments?["canContinueOperation"] as? Bool ?? false)
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
    canStashFromMenu = arguments?["canStash"] as? Bool ?? false
    canTagFromMenu = arguments?["canTag"] as? Bool ?? false
    canViewSelectedFileHistoryFromMenu =
      arguments?["canViewSelectedFileHistory"] as? Bool ?? false
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
  private var unregisteredWorkspaces: [
    ObjectIdentifier: WorkspaceFlutterWindowController
  ] = [:]
  private var mergedWorkspaceOrder: [ObjectIdentifier] = []
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
  private var restoredMergedWorkspacePathOrder: [String] = []

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
  }

  deinit {
    removeRepositoryLibraryWindowObservers()
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
    controller.hasVerifiedRepository = true
    controller.window?.title = "\(URL(fileURLWithPath: repositoryPath).lastPathComponent) (Git)"
    if let window = controller.window as? MainFlutterWindow,
       mergedWorkspaceOrder.contains(ObjectIdentifier(window)) {
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
  private func mergeWorkspaceWindows(
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
    let wasAlreadyMerged = mergedWorkspaceWindows.count > 1
    let windowIdentifiers = Set(windows.map(ObjectIdentifier.init))
    for previousWindow in mergedWorkspaceWindows
    where !windowIdentifiers.contains(ObjectIdentifier(previousWindow)) {
      previousWindow.removeWorkspaceTabStrip()
      if !previousWindow.isVisible {
        previousWindow.orderFront(nil)
      }
    }
    mergedWorkspaceOrder = windows.map(ObjectIdentifier.init)
    selectedMergedWorkspaceWindow = primary
    if !wasAlreadyMerged {
      isMergedWorkspaceTabStripVisible = true
    }
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
    let mergedIdentifiers = Set(mergedWorkspaceOrder)
    return windows.contains { !mergedIdentifiers.contains(ObjectIdentifier($0)) }
  }

  func workspaceWillClose(_ controller: WorkspaceFlutterWindowController) {
    dismissWorkspaceTabOverview()
    let closingWindow = controller.window as? MainFlutterWindow
    closingWindow?.cancelPendingBringToFront()
    let closingFrame = closingWindow?.frame
    let closingIdentifier = closingWindow.map(ObjectIdentifier.init)
    let closingIndex = closingIdentifier.flatMap {
      mergedWorkspaceOrder.firstIndex(of: $0)
    }
    let wasSelected = closingWindow === selectedMergedWorkspaceWindow
    if let closingIdentifier {
      mergedWorkspaceOrder.removeAll { $0 == closingIdentifier }
    }
    workspaceIndex.remove(controller)
    unregisteredWorkspaces.removeValue(forKey: ObjectIdentifier(controller))
    workspaceHistory.remove(controller)
    guard !isTerminating else {
      return
    }
    let remainingMergedWindows = mergedWorkspaceWindows
    if remainingMergedWindows.count < 2 {
      remainingMergedWindows.forEach { $0.removeWorkspaceTabStrip() }
      mergedWorkspaceOrder.removeAll()
      selectedMergedWorkspaceWindow = nil
      isMergedWorkspaceTabStripVisible = true
      if wasSelected, let remainingWindow = remainingMergedWindows.first {
        if let closingFrame {
          remainingWindow.setFrame(closingFrame, display: false)
        }
        DispatchQueue.main.async {
          remainingWindow.bringToFrontImmediately()
        }
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
    let controllers = restoredMergedWorkspacePathOrder.compactMap {
      workspaceIndex.host(for: $0)
    }.filter(\.hasVerifiedRepository)
    if controllers.count > 1 {
      mergeWorkspaceWindows(controllers)
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
    if mergedWorkspaceOrder.contains(ObjectIdentifier(window)),
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
    mergedWorkspaceWindows.count > 1 &&
      mergedWorkspaceOrder.contains(ObjectIdentifier(window))
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
    restoredMergedWorkspacePathOrder = gitDesktopMergedWorkspacePaths(
      restoredMergedWorkspacePathOrder,
      afterDetaching: detachedRepositoryPath
    )
    let sharedFrame = detachedWindow.frame
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
      remainingWindows.forEach { $0.removeWorkspaceTabStrip() }
      mergedWorkspaceOrder.removeAll()
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
    guard mergedWorkspaceOrder.contains(ObjectIdentifier(window)) else {
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
    let windows = mergedWorkspaceWindows
    guard windows.count > 1,
          let selectedWindow = selectedMergedWorkspaceWindow,
          windows.contains(where: { $0 === selectedWindow }) else {
      windows.forEach { $0.removeWorkspaceTabStrip() }
      return
    }
    guard isMergedWorkspaceTabStripVisible else {
      windows.forEach { $0.removeWorkspaceTabStrip() }
      return
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
    mergedWorkspaceOrder.removeAll()
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
      let mergedWorkspacePaths = savedSnapshot.mergedWorkspacePaths.filter {
        restorablePathSet.contains($0)
      }
      self.restoredMergedWorkspacePathOrder = mergedWorkspacePaths
      self.workspaceRestoreStore.save(
        paths: restorablePaths,
        mergedWorkspacePaths: mergedWorkspacePaths
      )
      self.workspaceRestorationGate.begin(
        paths: restorablePaths,
        mergedPaths: mergedWorkspacePaths
      )
      self.scheduleWorkspaceRestorationTimeout()
      for repositoryPath in restorablePaths {
        self.openWorkspace(
          repositoryPath: repositoryPath,
          initialAction: nil,
          restoresPreviouslyOpenWorkspace: true,
          restoresMergedWorkspace: mergedWorkspacePaths.contains(repositoryPath)
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

    let restoredControllers = completion.mergedPathsToRestore.compactMap {
      workspaceIndex.host(for: $0)
    }
    if completion.shouldMerge, restoredControllers.count > 1 {
      mergeWorkspaceWindows(restoredControllers)
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
    let mergedControllers = mergedWorkspaceOrder.compactMap {
      controllerByWindowIdentifier[$0]
    }
    let mergedControllerIdentifiers = Set(
      mergedControllers.map(ObjectIdentifier.init)
    )
    let controllersInRestoreOrder = mergedControllers + controllers.filter {
      !mergedControllerIdentifiers.contains(ObjectIdentifier($0))
    }
    workspaceRestoreStore.save(
      paths: controllersInRestoreOrder.compactMap(\.repositoryPath),
      mergedWorkspacePaths: mergedControllers.compactMap(\.repositoryPath)
    )
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

@main
class AppDelegate: FlutterAppDelegate, NSMenuDelegate {
  let windowCoordinator = WindowCoordinator()
  private let quickLookDataSource = GitDesktopQuickLookDataSource()
  private var shortcutEventMonitor: Any?
  private var isTerminationPreparationRunning = false
  private var isTerminationPrepared = false

  override init() {
    super.init()
    NSApp.setActivationPolicy(.regular)
    shortcutEventMonitor = NSEvent.addLocalMonitorForEvents(
      matching: .keyDown
    ) { [weak self] event in
      guard let self else {
        return event
      }
      return self.handleShortcut(event) ? nil : event
    }
  }

  deinit {
    if let shortcutEventMonitor {
      NSEvent.removeMonitor(shortcutEventMonitor)
    }
  }

  func attachRepositoryLibrary(
    window: MainFlutterWindow,
    flutterViewController: FlutterViewController
  ) {
    windowCoordinator.attachRepositoryLibrary(
      window: window,
      flutterViewController: flutterViewController
    )
  }

  func windowDidBecomeKey(_ window: MainFlutterWindow) {
    windowCoordinator.windowDidBecomeKey(window)
  }

  func selectAdjacentMergedWorkspace(
    from window: MainFlutterWindow,
    offset: Int
  ) -> Bool {
    windowCoordinator.selectAdjacentMergedWorkspace(
      from: window,
      offset: offset
    )
  }

  func handleShortcut(_ event: NSEvent) -> Bool {
    let sourceWindow = NSApp.keyWindow as? MainFlutterWindow
    if gitDesktopIsRepositoryWindowToggle(event) {
      windowCoordinator.toggleRepositoryWindow(from: sourceWindow)
      return true
    }
    if sourceWindow?.role == .workspace,
       gitDesktopIsRepositoryLibraryShortcut(event) {
      windowCoordinator.showRepositoryLibrary()
      return true
    }
    return false
  }

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
    windowCoordinator.performWorkspaceAction("createPatch")
  }

  @IBAction func applyPatchFromMenu(_ sender: Any?) {
    guard windowCoordinator.canApplyPatchFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction("applyPatch")
  }

  @IBAction func repositoryDetailsFromMenu(_ sender: Any?) {
    windowCoordinator.performWorkspaceAction("repositoryDetails")
  }

  @IBAction func refreshRepositoryFromMenu(_ sender: Any?) {
    windowCoordinator.performWorkspaceAction("refresh")
  }

  @IBAction func fetchRepositoryFromMenu(_ sender: Any?) {
    guard windowCoordinator.canFetchFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction("fetch")
  }

  @IBAction func commitRepositoryFromMenu(_ sender: Any?) {
    guard windowCoordinator.canCommitFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction("commit")
  }

  /// Opens Commit All for the key workspace after Flutter validates its scope.
  /// 中文：Flutter 校验提交范围后，在当前 key workspace 打开“提交所有”。
  @IBAction func commitAllRepositoryFromMenu(_ sender: Any?) {
    guard windowCoordinator.canCommitAllFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction("commitAll")
  }

  /// Opens Commit Selected for the key workspace's visible file selection.
  /// 中文：为当前 key workspace 的可见文件选择打开“提交选中项”。
  @IBAction func commitSelectedRepositoryFromMenu(_ sender: Any?) {
    guard windowCoordinator.canCommitSelectedFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction("commitSelected")
  }

  /// Opens the same selected-path commit workflow from the Action menu.
  /// 中文：从“动作”菜单打开同一套按所选路径提交的流程。
  @IBAction func commitSelectedFromActionMenu(_ sender: Any?) {
    guard windowCoordinator.canCommitSelectedFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction("commitSelected")
  }

  /// Opens the repository-level reset target and mode flow.
  /// 中文：打开仓库级重置的目标与模式选择流程。
  @IBAction func resetRepositoryFromMenu(_ sender: Any?) {
    guard windowCoordinator.canResetRepositoryFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction("resetRepository")
  }

  /// Restores the current work-tree selection to HEAD after confirmation.
  /// 中文：确认后将当前工作区选择恢复到 HEAD。
  @IBAction func resetSelectedFromMenu(_ sender: Any?) {
    guard windowCoordinator.canResetSelectedFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction("resetSelected")
  }

  /// Resets the current branch to the visible selected history commit.
  /// 中文：将当前分支重置到可见的已选历史提交。
  @IBAction func resetToSelectedCommitFromMenu(_ sender: Any?) {
    guard windowCoordinator.canResetToSelectedCommitFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction("resetToSelectedCommit")
  }

  /// 中文：在当前 key workspace 打开已有 Git 能力支持的检出目标选择面板。
  /// English: Opens the checkout target picker in the key workspace, backed
  /// by the existing Git application-layer operations.
  @IBAction func checkoutRepositoryFromMenu(_ sender: Any?) {
    guard windowCoordinator.canCheckoutFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction("checkout")
  }

  /// 中文：在当前 key workspace 打开已有的本地分支合并流程。
  /// English: Opens the existing local-branch merge workflow in the key
  /// workspace.
  @IBAction func mergeRepositoryFromMenu(_ sender: Any?) {
    guard windowCoordinator.canMergeFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction("merge")
  }

  /// 中文：在当前 key workspace 以当前选中提交打开既有交互式变基流程。
  /// English: Opens the existing interactive-rebase workflow for the selected
  /// commit in the key workspace.
  @IBAction func interactiveRebaseRepositoryFromMenu(_ sender: Any?) {
    guard windowCoordinator.canInteractiveRebaseFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction("interactiveRebase")
  }

  /// Opens the add-remote form in the current key workspace.
  /// 中文：在当前 key workspace 打开添加远端表单。
  @IBAction func addRemoteRepositoryFromMenu(_ sender: Any?) {
    guard windowCoordinator.canAddRemoteFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction("addRemote")
  }

  /// 中文：在当前 key workspace 打开已有的标签管理流程。
  /// English: Opens the existing tag-management workflow in the key workspace.
  @IBAction func tagRepositoryFromMenu(_ sender: Any?) {
    guard windowCoordinator.canTagFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction("tag")
  }

  @IBAction func pullRepositoryFromMenu(_ sender: Any?) {
    guard windowCoordinator.canPullFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction("pull")
  }

  @IBAction func pushRepositoryFromMenu(_ sender: Any?) {
    guard windowCoordinator.canPushFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction("push")
  }

  @IBAction func createBranchRepositoryFromMenu(_ sender: Any?) {
    guard windowCoordinator.canCreateBranchFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction("createBranch")
  }

  @IBAction func stashRepositoryFromMenu(_ sender: Any?) {
    guard windowCoordinator.canStashFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction("stash")
  }

  @IBAction func repositoryFeaturePendingFromMenu(_ sender: Any?) {
    windowCoordinator.performWorkspaceAction("repositoryFeaturePending")
  }

  /// Continues the active Git operation in the key workspace.
  /// 中文：继续当前前台工作区正在进行的 Git 操作。
  @IBAction func continueRepositoryOperationFromMenu(_ sender: Any?) {
    guard windowCoordinator.canContinueOperationFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction("continueOperation")
  }

  /// Requests confirmation before aborting the active Git operation.
  /// 中文：在中止当前前台工作区的 Git 操作前请求影响确认。
  @IBAction func abortRepositoryOperationFromMenu(_ sender: Any?) {
    guard windowCoordinator.canAbortOperationFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction("abortOperation")
  }

  /// Uses index stage 2 for the key workspace's selected conflict file.
  /// 中文：为当前前台工作区选中的冲突文件使用索引第二阶段版本。
  @IBAction func useConflictStage2FromMenu(_ sender: Any?) {
    guard windowCoordinator.canUseConflictStage2FromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction("useConflictStage2")
  }

  /// Uses index stage 3 for the key workspace's selected conflict file.
  /// 中文：为当前前台工作区选中的冲突文件使用索引第三阶段版本。
  @IBAction func useConflictStage3FromMenu(_ sender: Any?) {
    guard windowCoordinator.canUseConflictStage3FromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction("useConflictStage3")
  }

  /// Stages the key workspace's selected conflict file as resolved.
  /// 中文：将当前前台工作区选中的冲突文件暂存并标记为已解决。
  @IBAction func markConflictResolvedFromMenu(_ sender: Any?) {
    guard windowCoordinator.canMarkConflictResolvedFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction("markConflictResolved")
  }

  /// Opens read-only history for the key workspace's selected file.
  /// 中文：为当前前台工作区选中的文件打开只读修改日志。
  @IBAction func viewSelectedFileHistoryFromMenu(_ sender: Any?) {
    guard windowCoordinator.canViewSelectedFileHistoryFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction("viewSelectedFileHistory")
  }

  /// Opens the ignore-rule preview for the key workspace's selection.
  /// 中文：为当前前台工作区选择打开忽略规则预览。
  @IBAction func ignoreSelectedFromMenu(_ sender: Any?) {
    guard windowCoordinator.canIgnoreSelectedFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction("ignoreSelected")
  }

  /// Opens the copy preview for the key workspace's selected local files.
  /// 中文：为当前前台工作区选中的本地文件打开复制预览。
  @IBAction func copySelectedFromMenu(_ sender: Any?) {
    guard windowCoordinator.canCopySelectedFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction("copySelected")
  }

  /// Opens the move preview for the key workspace's selected local files.
  /// 中文：为当前前台工作区选中的本地文件打开移动预览。
  @IBAction func moveSelectedFromMenu(_ sender: Any?) {
    guard windowCoordinator.canMoveSelectedFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction("moveSelected")
  }

  /// Opens the built-in read-only review for the key workspace selection.
  /// 中文：为当前前台工作区选择打开内置只读审查。
  @IBAction func reviewSelectedFromMenu(_ sender: Any?) {
    guard windowCoordinator.canReviewSelectedFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction("reviewSelected")
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
    windowCoordinator.performWorkspaceAction("stopTracking")
  }

  /// 中文：暂存当前前台工作区中由 Flutter 校验的未暂存文件选择。
  /// English: Stages the Flutter-validated unstaged file selection in the key
  /// workspace.
  @IBAction func stageSelectedFromMenu(_ sender: Any?) {
    guard windowCoordinator.canStageSelectedFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction("stageSelected")
  }

  /// 中文：取消暂存当前前台工作区中由 Flutter 校验的已暂存文件选择。
  /// English: Unstages the Flutter-validated staged file selection in the key
  /// workspace.
  @IBAction func unstageSelectedFromMenu(_ sender: Any?) {
    guard windowCoordinator.canUnstageSelectedFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction("unstageSelected")
  }

  /// 中文：将原生“移除”动作投递到当前 key workspace，并由 Flutter 显示删除确认。
  /// English: Delivers the native Remove action to the key workspace, where
  /// Flutter presents the destructive-file confirmation.
  @IBAction func removeSelectedFromMenu(_ sender: Any?) {
    guard windowCoordinator.canRemoveSelectedFromMenu else {
      NSSound.beep()
      return
    }
    windowCoordinator.performWorkspaceAction("removeSelected")
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
    if menuItem.action == #selector(stashRepositoryFromMenu(_:)) {
      return windowCoordinator.canStashFromMenu
    }
    return true
  }

  override func applicationWillTerminate(_ notification: Notification) {
    windowCoordinator.shutDownWorkspaces()
    super.applicationWillTerminate(notification)
  }

  override func applicationShouldTerminate(
    _ sender: NSApplication
  ) -> NSApplication.TerminateReply {
    if isTerminationPrepared {
      return .terminateNow
    }
    if !isTerminationPreparationRunning {
      isTerminationPreparationRunning = true
      windowCoordinator.beginApplicationTermination()
      windowCoordinator.prepareForApplicationTermination { [weak self] in
        guard let self else {
          sender.reply(toApplicationShouldTerminate: true)
          return
        }
        self.isTerminationPrepared = true
        self.isTerminationPreparationRunning = false
        sender.reply(toApplicationShouldTerminate: true)
      }
    }
    return .terminateLater
  }

  override func applicationShouldTerminateAfterLastWindowClosed(
    _ sender: NSApplication
  ) -> Bool {
    false
  }

  override func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    windowCoordinator.restoreMostRecentlyActiveWindow()
    return true
  }

  override func applicationSupportsSecureRestorableState(
    _ app: NSApplication
  ) -> Bool {
    true
  }
}
