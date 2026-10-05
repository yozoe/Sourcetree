import Cocoa
import FlutterMacOS
import QuickLookUI

let gitDesktopEngineCleanupTimeout: TimeInterval = 3.5
let gitDesktopWorkspaceRestorationTimeout: TimeInterval = 30

enum GitDesktopWindowHostError: LocalizedError {
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

/// Returns whether the native Skip command may target the key workspace.
/// 中文：判断原生“跳过当前提交”是否可以安全作用于当前前台工作区。
func gitDesktopCanPerformSkipOperationMenuAction(
  hasKeyWorkspace: Bool,
  operation: GitDesktopRepositoryOperation?,
  hasValidatedSkipCapability: Bool
) -> Bool {
  hasKeyWorkspace &&
    operation != nil &&
    operation != .merge &&
    hasValidatedSkipCapability
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
  /// All persisted merged workspace groups, in tab order.
  /// 中文：按标签顺序保存的全部合并工作区组。
  let mergedWorkspaceGroups: [[String]]

  /// Legacy-compatible view of the first merged group.
  /// 中文：兼容旧调用方的第一个合并组视图。
  var mergedWorkspacePaths: [String] {
    mergedWorkspaceGroups.first ?? []
  }

  var restoresMergedWorkspaces: Bool {
    mergedWorkspaceGroups.contains { $0.count > 1 }
  }
}

struct GitDesktopWorkspaceRestorationCompletion: Equatable {
  let resolvedPaths: [String]
  /// Paths that did not answer before the bounded wait; their windows remain open.
  let timedOutPathsToKeepOpen: [String]
  let mergedGroupsToRestore: [[String]]

  init(
    resolvedPaths: [String],
    timedOutPathsToKeepOpen: [String],
    mergedPathsToRestore: [String] = [],
    mergedGroupsToRestore: [[String]]? = nil
  ) {
    self.resolvedPaths = resolvedPaths
    self.timedOutPathsToKeepOpen = timedOutPathsToKeepOpen
    self.mergedGroupsToRestore = mergedGroupsToRestore ?? (
      mergedPathsToRestore.count > 1 ? [mergedPathsToRestore] : []
    )
  }

  /// Legacy-compatible view of the first group.
  /// 中文：兼容旧测试与迁移代码的第一个合并组视图。
  var mergedPathsToRestore: [String] {
    mergedGroupsToRestore.first ?? []
  }

  var shouldMerge: Bool {
    !mergedGroupsToRestore.isEmpty
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
  private var mergedGroups: [[String]] = []

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
    mergedPaths: [String]? = nil,
    mergedGroups: [[String]]? = nil
  ) {
    var seen: Set<String> = []
    orderedPaths = paths.filter { seen.insert($0).inserted }
    pendingPaths = Set(orderedPaths)
    resolvedPaths.removeAll()
    let requestedGroups = mergedGroups ?? [
      mergedPaths ?? (shouldMerge ? orderedPaths : [])
    ]
    self.mergedGroups = requestedGroups.map { group in
      group.filter { pendingPaths.contains($0) }
    }.filter { $0.count > 1 }
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
      mergedGroupsToRestore: mergedGroups.map { group in
        orderedPaths.filter { group.contains($0) && resolvedPaths.contains($0) }
      }.filter { $0.count > 1 }
    )
    orderedPaths.removeAll()
    pendingPaths.removeAll()
    resolvedPaths.removeAll()
    mergedGroups.removeAll()
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
  private static let mergedWorkspaceGroupsKey =
    "gitDesktopMergedWorkspaceGroups"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var snapshot: GitDesktopWorkspaceRestoreSnapshot {
    guard let rawPaths = defaults.array(forKey: Self.pathsKey) as? [String]
    else {
      return GitDesktopWorkspaceRestoreSnapshot(
        paths: [],
        mergedWorkspaceGroups: []
      )
    }
    let paths = normalizedPaths(rawPaths)
    let pathSet = Set(paths)
    let storedGroups = defaults.array(
      forKey: Self.mergedWorkspaceGroupsKey
    ) as? [[String]]
    let legacyPaths = defaults.array(
      forKey: Self.mergedWorkspacePathsKey
    ) as? [String]
    let candidates = storedGroups ?? [
      legacyPaths ?? (
        defaults.bool(forKey: Self.mergedWorkspacesKey) ? paths : []
      )
    ]
    let mergedGroups = normalizedGroups(candidates, pathSet: pathSet)
    return GitDesktopWorkspaceRestoreSnapshot(
      paths: paths,
      mergedWorkspaceGroups: mergedGroups
    )
  }

  var paths: [String] {
    snapshot.paths
  }

  func save(
    paths: [String],
    restoresMergedWorkspaces: Bool = false,
    mergedWorkspacePaths: [String]? = nil,
    mergedWorkspaceGroups: [[String]]? = nil
  ) {
    let normalized = normalizedPaths(paths)
    let normalizedSet = Set(normalized)
    let requestedGroups = mergedWorkspaceGroups ?? [
      mergedWorkspacePaths ?? (
        restoresMergedWorkspaces ? normalized : []
      )
    ]
    let persistedGroups = normalizedGroups(
      requestedGroups,
      pathSet: normalizedSet
    )
    defaults.set(normalized, forKey: Self.pathsKey)
    defaults.set(persistedGroups, forKey: Self.mergedWorkspaceGroupsKey)
    // Keep the legacy keys in sync for older builds that may be launched
    // after this version. The first group is the only representation they
    // understand.
    defaults.set(
      persistedGroups.first ?? [],
      forKey: Self.mergedWorkspacePathsKey
    )
    defaults.set(
      persistedGroups.count == 1 &&
        persistedGroups.first?.count == normalized.count &&
        normalized.count > 1,
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

  /// Canonicalizes and filters every persisted group without allowing a path
  /// to appear twice in one group or a one-window group to masquerade as a
  /// merged group.
  /// 中文：规范化并过滤全部持久化组，避免组内重复路径或单窗口伪合并。
  private func normalizedGroups(
    _ candidates: [[String]],
    pathSet: Set<String>
  ) -> [[String]] {
    var result: [[String]] = []
    var claimed: Set<String> = []
    for candidate in candidates {
      let group = normalizedPaths(candidate).filter {
        pathSet.contains($0) && !claimed.contains($0)
      }
      guard group.count > 1 else { continue }
      claimed.formUnion(group)
      result.append(group)
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
