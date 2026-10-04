import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path_utils;

const double _repositoryLibraryIconSize = 36;
const String _ungroupedWorkspaceValue = '__ungrouped__';

/// Shows a compact validated name prompt for a user workspace group.
/// 中文：显示并校验首页工作区分组名称输入框；取消或空名称返回 null。
Future<String?> _showWorkspaceGroupNameDialog(
  BuildContext context, {
  required String title,
  String initialValue = '',
}) async {
  final controller = TextEditingController(text: initialValue);
  final value = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 80,
        decoration: const InputDecoration(labelText: '分组名称'),
        onSubmitted: (value) => Navigator.of(dialogContext).pop(value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(dialogContext).pop(controller.text.trim()),
          child: const Text('保存'),
        ),
      ],
    ),
  );
  controller.dispose();
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

/// 中文：按显示尺寸和屏幕像素密度计算仓库图标的最大解码边长。
/// English: Returns the bounded decode dimension for a repository icon.
int repositoryLibraryIconCacheDimension(double devicePixelRatio) {
  if (!devicePixelRatio.isFinite || devicePixelRatio <= 0) {
    return _repositoryLibraryIconSize.toInt();
  }
  return (_repositoryLibraryIconSize * devicePixelRatio)
      .ceil()
      .clamp(36, 144)
      .toInt();
}

/// A repository displayed in the local repository library.
final class RepositoryLibraryItem {
  const RepositoryLibraryItem({
    required this.path,
    required this.label,
    this.branchName,
    this.changedFileCount = 0,
    this.isDetached = false,
    this.isUnborn = false,
    this.hasStatus = false,
    this.isFavorite = false,
    this.workspaceGroup,
  });

  /// Absolute path used to re-open this repository.
  final String path;

  /// Human-readable repository name.
  final String label;

  /// Branch name reported by the latest Git status read.
  final String? branchName;

  /// Number of files with staged, unstaged, or untracked changes.
  final int changedFileCount;

  /// Whether Git reported a detached HEAD instead of a local branch.
  final bool isDetached;

  /// Whether the current branch has not received its first commit.
  final bool isUnborn;

  /// Whether the branch and change summary was successfully read from Git.
  final bool hasStatus;

  /// Whether the user marked this repository as a favorite.
  /// 中文：首页用户是否将此仓库标记为收藏。
  final bool isFavorite;

  /// User-created home-window group containing this repository, if any.
  /// 中文：该仓库所属的首页用户分组；为空表示未分组。
  final String? workspaceGroup;

  /// 中文：返回仓库根目录中约定的自定义图标路径。
  /// English: Returns the conventional custom icon path at the repository root.
  String get iconPath => path_utils.join(path, 'icon.png');
}

/// A searchable overview of locally known repositories with user groups and a
/// directory-based fallback for ungrouped entries.
///
/// It intentionally deals only with already-known repository paths. Opening,
/// cloning and initialization remain application-layer actions supplied by the
/// host through callbacks.
class RepositoryLibraryPage extends StatefulWidget {
  const RepositoryLibraryPage({
    super.key,
    required this.repositories,
    required this.activePath,
    required this.onRepositorySelected,
    this.onOpenRepository,
    this.onCloneRepository,
    this.onInitializeRepository,
    this.onRepositoriesReordered,
    this.onFavoriteToggled,
    this.workspaceGroups = const [],
    this.repositoryGroups = const {},
    this.onWorkspaceGroupCreated,
    this.onWorkspaceGroupRenamed,
    this.onWorkspaceGroupDeleted,
    this.onRepositoryGroupChanged,
    this.isDirectoryDropActive = false,
    this.trailing,
  });

  final List<RepositoryLibraryItem> repositories;
  final String? activePath;
  final Future<void> Function(String path) onRepositorySelected;
  final VoidCallback? onOpenRepository;
  final VoidCallback? onCloneRepository;
  final VoidCallback? onInitializeRepository;
  final ValueChanged<List<String>>? onRepositoriesReordered;
  final ValueChanged<String>? onFavoriteToggled;
  final List<String> workspaceGroups;
  final Map<String, String> repositoryGroups;
  final ValueChanged<String>? onWorkspaceGroupCreated;
  final void Function(String oldName, String newName)? onWorkspaceGroupRenamed;
  final ValueChanged<String>? onWorkspaceGroupDeleted;
  final void Function(String path, String? group)? onRepositoryGroupChanged;
  final bool isDirectoryDropActive;
  final Widget? trailing;

  /// 中文：创建关联的状态对象。
  /// English: Creates the associated state object.
  @override
  State<RepositoryLibraryPage> createState() => _RepositoryLibraryPageState();
}

class _RepositoryLibraryPageState extends State<RepositoryLibraryPage> {
  String _query = '';

  /// 中文：更新本地仓库的筛选条件。
  /// English: Updates the local repository filter.
  void _updateQuery(String query) {
    setState(() => _query = query);
  }

  /// Opens the create-group prompt and reports a validated name to the host.
  /// 中文：打开创建工作区分组对话框，并把非空名称交给应用层持久化。
  Future<void> _createWorkspaceGroup() async {
    final name = await _showWorkspaceGroupNameDialog(context, title: '新建工作区分组');
    if (name != null) widget.onWorkspaceGroupCreated?.call(name);
  }

  /// Opens a rename prompt for one existing workspace group.
  /// 中文：打开已有工作区分组的重命名对话框。
  Future<void> _renameWorkspaceGroup(String currentName) async {
    final name = await _showWorkspaceGroupNameDialog(
      context,
      title: '重命名工作区分组',
      initialValue: currentName,
    );
    if (name != null) widget.onWorkspaceGroupRenamed?.call(currentName, name);
  }

  /// Confirms group removal while keeping its repositories in the library.
  /// 中文：确认删除分组；仓库不会删除，只会回到未分组状态。
  Future<void> _deleteWorkspaceGroup(String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除工作区分组？'),
        content: Text('“$name”中的仓库会保留在首页，但回到未分组状态。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除分组'),
          ),
        ],
      ),
    );
    if (confirmed == true) widget.onWorkspaceGroupDeleted?.call(name);
  }

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final List<RepositoryLibraryItem> visibleRepositories =
        _filteredRepositories(widget.repositories, _query);
    final Map<String, List<RepositoryLibraryItem>> groups = _groupRepositories(
      visibleRepositories,
      widget.workspaceGroups,
      widget.repositoryGroups,
    );

    return Stack(
      children: [
        Material(
          color: colors.surface,
          child: SafeArea(
            top: false,
            child: Column(
              children: [
                Container(
                  constraints: BoxConstraints(
                    minHeight:
                        52 *
                        math.max(1, MediaQuery.textScalerOf(context).scale(1)),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerLow,
                    border: Border(
                      bottom: BorderSide(color: colors.outlineVariant),
                    ),
                  ),
                  child: Row(
                    children: [
                      if (widget.repositories.isNotEmpty)
                        Expanded(
                          child: Semantics(
                            textField: true,
                            label: '筛选本地仓库',
                            child: TextField(
                              onChanged: _updateQuery,
                              textAlignVertical: TextAlignVertical.center,
                              decoration: InputDecoration(
                                isDense: true,
                                hintText: '筛选仓库',
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                prefixIconConstraints:
                                    const BoxConstraints.tightFor(
                                      width: 38,
                                      height: 36,
                                    ),
                                prefixIcon: const Center(
                                  child: Icon(Icons.search, size: 19),
                                ),
                                border: const OutlineInputBorder(),
                              ),
                            ),
                          ),
                        )
                      else
                        Expanded(
                          child: Text(
                            '本地仓库',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      const SizedBox(width: 10),
                      Tooltip(
                        message: '打开本地仓库',
                        child: IconButton(
                          onPressed: widget.onOpenRepository,
                          icon: const Icon(Icons.folder_open_outlined),
                        ),
                      ),
                      Tooltip(
                        message: '克隆远端仓库',
                        child: IconButton(
                          onPressed: widget.onCloneRepository,
                          icon: const Icon(Icons.download_outlined),
                        ),
                      ),
                      Tooltip(
                        message: '初始化新仓库',
                        child: IconButton(
                          onPressed: widget.onInitializeRepository,
                          icon: const Icon(Icons.create_new_folder_outlined),
                        ),
                      ),
                      if (widget.onWorkspaceGroupCreated != null)
                        Tooltip(
                          message: '新建工作区分组',
                          child: IconButton(
                            onPressed: _createWorkspaceGroup,
                            icon: const Icon(Icons.create_new_folder_outlined),
                          ),
                        ),
                      if (widget.trailing != null) ...[
                        const SizedBox(width: 4),
                        widget.trailing!,
                      ],
                    ],
                  ),
                ),
                Expanded(
                  child:
                      visibleRepositories.isEmpty &&
                          (_query.trim().isNotEmpty ||
                              widget.workspaceGroups.isEmpty)
                      ? _RepositoryLibraryEmptyState(
                          hasQuery: _query.trim().isNotEmpty,
                          onOpenRepository: widget.onOpenRepository,
                          onCloneRepository: widget.onCloneRepository,
                          onInitializeRepository: widget.onInitializeRepository,
                        )
                      : _RepositoryLibraryList(
                          groups: groups,
                          activePath: widget.activePath,
                          onRepositorySelected: widget.onRepositorySelected,
                          reorderEnabled:
                              _query.trim().isEmpty &&
                              widget.onRepositoriesReordered != null,
                          onRepositoriesReordered:
                              widget.onRepositoriesReordered,
                          onFavoriteToggled: widget.onFavoriteToggled,
                          workspaceGroups: widget.workspaceGroups,
                          currentGroups: widget.repositoryGroups,
                          onRepositoryGroupChanged:
                              widget.onRepositoryGroupChanged,
                          onWorkspaceGroupRenamed: _renameWorkspaceGroup,
                          onWorkspaceGroupDeleted: _deleteWorkspaceGroup,
                        ),
                ),
              ],
            ),
          ),
        ),
        if (widget.isDirectoryDropActive)
          const Positioned.fill(child: _RepositoryDirectoryDropOverlay()),
      ],
    );
  }
}

class _RepositoryLibraryList extends StatelessWidget {
  const _RepositoryLibraryList({
    required this.groups,
    required this.activePath,
    required this.onRepositorySelected,
    required this.reorderEnabled,
    this.onRepositoriesReordered,
    this.onFavoriteToggled,
    required this.workspaceGroups,
    required this.currentGroups,
    this.onRepositoryGroupChanged,
    this.onWorkspaceGroupRenamed,
    this.onWorkspaceGroupDeleted,
  });

  final Map<String, List<RepositoryLibraryItem>> groups;
  final String? activePath;
  final Future<void> Function(String path) onRepositorySelected;
  final bool reorderEnabled;
  final ValueChanged<List<String>>? onRepositoriesReordered;
  final ValueChanged<String>? onFavoriteToggled;
  final List<String> workspaceGroups;
  final Map<String, String> currentGroups;
  final void Function(String path, String? group)? onRepositoryGroupChanged;
  final Future<void> Function(String group)? onWorkspaceGroupRenamed;
  final ValueChanged<String>? onWorkspaceGroupDeleted;

  /// 中文：构建用户命名分组及未分组目录分组，并支持组内拖动排序。
  ///
  /// English: Builds user-grouped and fallback directory-grouped repositories
  /// with optional within-group drag reordering.
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(10, 14, 10, 28),
      children: [
        for (final MapEntry<String, List<RepositoryLibraryItem>> group
            in groups.entries) ...[
          _RepositoryLibraryGroupHeader(
            title: _repositoryGroupLabel(group.key, groups.keys),
            count: group.value.length,
            userGroup: _userGroupName(group.key),
            onRename: onWorkspaceGroupRenamed,
            onDelete: onWorkspaceGroupDeleted,
          ),
          _RepositoryLibraryGroup(
            repositories: group.value,
            activePath: activePath,
            onRepositorySelected: onRepositorySelected,
            onFavoriteToggled: onFavoriteToggled,
            workspaceGroups: workspaceGroups,
            currentGroups: currentGroups,
            onRepositoryGroupChanged: onRepositoryGroupChanged,
            onWorkspaceGroupRenamed: onWorkspaceGroupRenamed,
            onWorkspaceGroupDeleted: onWorkspaceGroupDeleted,
            reorderEnabled: reorderEnabled,
            onReordered: (reorderedGroup) {
              final paths = <String>[];
              for (final candidate in groups.entries) {
                paths.addAll(
                  (candidate.key == group.key
                          ? reorderedGroup
                          : candidate.value)
                      .map((item) => item.path),
                );
              }
              onRepositoriesReordered?.call(paths);
            },
          ),
        ],
      ],
    );
  }
}

class _RepositoryLibraryGroup extends StatelessWidget {
  const _RepositoryLibraryGroup({
    required this.repositories,
    required this.activePath,
    required this.onRepositorySelected,
    required this.reorderEnabled,
    required this.onReordered,
    this.onFavoriteToggled,
    required this.workspaceGroups,
    required this.currentGroups,
    this.onRepositoryGroupChanged,
    this.onWorkspaceGroupRenamed,
    this.onWorkspaceGroupDeleted,
  });

  final List<RepositoryLibraryItem> repositories;
  final String? activePath;
  final Future<void> Function(String path) onRepositorySelected;
  final bool reorderEnabled;
  final ValueChanged<List<RepositoryLibraryItem>> onReordered;
  final ValueChanged<String>? onFavoriteToggled;
  final List<String> workspaceGroups;
  final Map<String, String> currentGroups;
  final void Function(String path, String? group)? onRepositoryGroupChanged;
  final Future<void> Function(String group)? onWorkspaceGroupRenamed;
  final ValueChanged<String>? onWorkspaceGroupDeleted;

  /// 中文：构建单个首页分组，并只允许在组内调整仓库顺序。
  ///
  /// English: Builds one library group and limits dragging to its repository
  /// entries so group membership remains stable.
  @override
  Widget build(BuildContext context) {
    if (!reorderEnabled) {
      return Column(
        children: [
          for (final repository in repositories)
            _RepositoryLibraryTile(
              repository: repository,
              selected: repository.path == activePath,
              onPressed: () => onRepositorySelected(repository.path),
              onFavoriteToggled: onFavoriteToggled,
              workspaceGroups: workspaceGroups,
              currentGroup: currentGroups[repository.path],
              onRepositoryGroupChanged: onRepositoryGroupChanged,
            ),
        ],
      );
    }
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: repositories.length,
      onReorderItem: (oldIndex, newIndex) {
        final reordered = [...repositories];
        final item = reordered.removeAt(oldIndex);
        reordered.insert(newIndex, item);
        onReordered(reordered);
      },
      itemBuilder: (context, index) {
        final repository = repositories[index];
        return _RepositoryLibraryTile(
          key: ValueKey<String>(
            'repository-library-reorder:${repository.path}',
          ),
          repository: repository,
          selected: repository.path == activePath,
          onPressed: () => onRepositorySelected(repository.path),
          onFavoriteToggled: onFavoriteToggled,
          workspaceGroups: workspaceGroups,
          currentGroup: currentGroups[repository.path],
          onRepositoryGroupChanged: onRepositoryGroupChanged,
          dragHandle: ReorderableDragStartListener(
            index: index,
            child: const Tooltip(
              message: '拖动以排序',
              child: Padding(
                padding: EdgeInsets.all(8),
                child: Icon(Icons.drag_indicator_outlined, size: 18),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Returns repositories matching a case-insensitive name or path query.
List<RepositoryLibraryItem> _filteredRepositories(
  List<RepositoryLibraryItem> repositories,
  String query,
) {
  final String normalizedQuery = query.trim().toLowerCase();
  if (normalizedQuery.isEmpty) {
    return List<RepositoryLibraryItem>.unmodifiable(repositories);
  }
  return repositories
      .where(
        (RepositoryLibraryItem repository) =>
            repository.label.toLowerCase().contains(normalizedQuery) ||
            repository.path.toLowerCase().contains(normalizedQuery),
      )
      .toList(growable: false);
}

/// Groups repositories by user assignment, then by complete normalized parent
/// directory for entries without a user assignment.
///
/// 中文：以规范化的完整父目录分组，避免同名目录被合并。
Map<String, List<RepositoryLibraryItem>> _groupRepositories(
  List<RepositoryLibraryItem> repositories,
  List<String> workspaceGroups,
  Map<String, String> repositoryGroups,
) {
  final Map<String, List<RepositoryLibraryItem>> groups =
      <String, List<RepositoryLibraryItem>>{};
  for (final group in workspaceGroups) {
    groups['@workspace:$group'] = <RepositoryLibraryItem>[];
  }
  for (final RepositoryLibraryItem repository in repositories) {
    final assignedGroup = repositoryGroups[repository.path];
    if (assignedGroup != null && workspaceGroups.contains(assignedGroup)) {
      groups['@workspace:$assignedGroup']!.add(repository);
      continue;
    }
    final String parentPath = path_utils.dirname(repository.path);
    final String groupLabel = path_utils.normalize(parentPath);
    groups
        .putIfAbsent(groupLabel, () => <RepositoryLibraryItem>[])
        .add(repository);
  }
  return groups;
}

/// Returns a concise group label and includes the full path when basenames
/// collide.
///
/// 中文：返回紧凑的仓库分组标题；父目录同名时显示完整路径消歧。
String _repositoryGroupLabel(String parentPath, Iterable<String> allPaths) {
  final userGroup = _userGroupName(parentPath);
  if (userGroup != null) return userGroup;
  final basename = path_utils.basename(parentPath);
  final concise = basename.isEmpty ? parentPath : basename;
  final collisions = allPaths.where(
    (candidate) => path_utils.basename(candidate) == basename,
  );
  return collisions.length > 1 ? parentPath : concise;
}

String? _userGroupName(String key) =>
    key.startsWith('@workspace:') ? key.substring('@workspace:'.length) : null;

class _RepositoryLibraryGroupHeader extends StatelessWidget {
  const _RepositoryLibraryGroupHeader({
    required this.title,
    required this.count,
    this.userGroup,
    this.onRename,
    this.onDelete,
  });

  final String title;
  final int count;
  final String? userGroup;
  final Future<void> Function(String group)? onRename;
  final ValueChanged<String>? onDelete;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 8, right: 8, top: 4, bottom: 5),
      child: Row(
        children: [
          Icon(Icons.folder_outlined, size: 17, color: colors.primary),
          const SizedBox(width: 7),
          Text(
            title,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (userGroup != null && (onRename != null || onDelete != null))
            PopupMenuButton<String>(
              tooltip: '分组操作',
              onSelected: (value) {
                if (value == 'rename') {
                  onRename?.call(userGroup!);
                } else if (value == 'delete') {
                  onDelete?.call(userGroup!);
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'rename', child: Text('重命名分组')),
                PopupMenuItem(value: 'delete', child: Text('删除分组')),
              ],
            ),
          const SizedBox(width: 7),
          Text(
            '$count',
            style: theme.textTheme.labelSmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _RepositoryLibraryTile extends StatefulWidget {
  const _RepositoryLibraryTile({
    super.key,
    required this.repository,
    required this.selected,
    required this.onPressed,
    this.dragHandle,
    this.onFavoriteToggled,
    this.workspaceGroups = const [],
    this.currentGroup,
    this.onRepositoryGroupChanged,
  });

  final RepositoryLibraryItem repository;
  final bool selected;
  final VoidCallback onPressed;
  final Widget? dragHandle;
  final ValueChanged<String>? onFavoriteToggled;
  final List<String> workspaceGroups;
  final String? currentGroup;
  final void Function(String path, String? group)? onRepositoryGroupChanged;

  /// 中文：创建负责管理仓库条目键盘焦点的状态对象。
  /// English: Creates the state that owns keyboard focus for this repository.
  @override
  State<_RepositoryLibraryTile> createState() => _RepositoryLibraryTileState();
}

class _RepositoryLibraryTileState extends State<_RepositoryLibraryTile> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'Repository library tile');
  bool _focused = false;

  /// 中文：处理仓库条目的 Enter 和空格键激活，并忽略其他按键。
  /// English: Activates the repository for Enter or Space and ignores other keys.
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.space)) {
      widget.onPressed();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 中文：同步焦点可见状态，让键盘用户能辨认当前仓库条目。
  /// English: Tracks focus visibility so keyboard users can identify the tile.
  void _handleFocusChange(bool focused) {
    setState(() => _focused = focused);
  }

  /// 中文：释放当前条目拥有的键盘焦点节点。
  /// English: Disposes the keyboard focus node owned by this tile.
  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 1),
      child: Material(
        key: ValueKey<String>(
          'repository-library-tile:${widget.repository.path}',
        ),
        color: widget.selected ? colors.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
        child: Listener(
          onPointerDown: (_) => _focusNode.requestFocus(),
          child: Focus(
            focusNode: _focusNode,
            onKeyEvent: _handleKeyEvent,
            onFocusChange: _handleFocusChange,
            child: InkWell(
              canRequestFocus: false,
              onDoubleTap: widget.onPressed,
              borderRadius: BorderRadius.circular(7),
              child: Semantics(
                button: true,
                selected: widget.selected,
                label: '仓库 ${widget.repository.label}',
                hint: '双击打开仓库',
                onTap: widget.onPressed,
                child: Container(
                  constraints: const BoxConstraints(minHeight: 62),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  decoration: _focused
                      ? BoxDecoration(
                          border: Border.all(color: colors.primary, width: 2),
                          borderRadius: BorderRadius.circular(7),
                        )
                      : null,
                  child: Row(
                    children: [
                      _RepositoryLibraryIcon(
                        iconPath: widget.repository.iconPath,
                        repositoryPath: widget.repository.path,
                        selected: widget.selected,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.repository.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: widget.selected
                                    ? colors.onSecondaryContainer
                                    : colors.onSurface,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              widget.repository.path,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: widget.selected
                                    ? colors.onSecondaryContainer.withValues(
                                        alpha: .78,
                                      )
                                    : colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (widget.repository.hasStatus) ...[
                        const SizedBox(width: 12),
                        _RepositoryLibraryBranchStatus(
                          repository: widget.repository,
                        ),
                      ],
                      if (widget.selected) ...[
                        const SizedBox(width: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: colors.primary,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '当前',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: colors.onPrimary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                      if (widget.onFavoriteToggled != null) ...[
                        const SizedBox(width: 2),
                        Tooltip(
                          message: widget.repository.isFavorite
                              ? '取消收藏'
                              : '收藏仓库',
                          child: IconButton(
                            key: ValueKey<String>(
                              'repository-library-favorite:${widget.repository.path}',
                            ),
                            visualDensity: VisualDensity.compact,
                            onPressed: () => widget.onFavoriteToggled!(
                              widget.repository.path,
                            ),
                            icon: Icon(
                              widget.repository.isFavorite
                                  ? Icons.star
                                  : Icons.star_border,
                            ),
                          ),
                        ),
                      ],
                      if (widget.onRepositoryGroupChanged != null) ...[
                        const SizedBox(width: 2),
                        PopupMenuButton<String>(
                          key: ValueKey<String>(
                            'repository-library-group:${widget.repository.path}',
                          ),
                          tooltip: '设置工作区分组',
                          icon: Icon(
                            widget.currentGroup == null
                                ? Icons.folder_outlined
                                : Icons.folder_special,
                          ),
                          onSelected: (value) {
                            widget.onRepositoryGroupChanged!(
                              widget.repository.path,
                              value == _ungroupedWorkspaceValue ? null : value,
                            );
                          },
                          itemBuilder: (context) => [
                            const PopupMenuItem<String>(
                              value: _ungroupedWorkspaceValue,
                              child: Text('未分组'),
                            ),
                            for (final group in widget.workspaceGroups)
                              PopupMenuItem<String>(
                                value: group,
                                child: Text(group),
                              ),
                          ],
                        ),
                      ],
                      ...(widget.dragHandle == null
                          ? const <Widget>[]
                          : <Widget>[widget.dragHandle!]),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows the current branch and changed-file count for one library entry.
class _RepositoryLibraryBranchStatus extends StatelessWidget {
  const _RepositoryLibraryBranchStatus({required this.repository});

  final RepositoryLibraryItem repository;

  /// 中文：根据 Git 分支状态生成首页可读的分支标签。
  /// English: Creates a readable branch label for the library from Git status.
  String get _branchLabel {
    final branchName = repository.branchName;
    if (branchName != null && branchName.isNotEmpty) return branchName;
    if (repository.isDetached) return 'HEAD';
    if (repository.isUnborn) return '未提交';
    return '未知分支';
  }

  /// 中文：构建仓库当前分支和未提交改动数的紧凑状态徽标。
  /// English: Builds compact badges for the repository branch and dirty-file
  /// count.
  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color badgeColor = colors.surfaceContainerHighest;
    final Color foregroundColor = colors.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (repository.changedFileCount > 0) ...[
          Tooltip(
            message: '${repository.changedFileCount} 项未提交改动',
            child: Semantics(
              label: '${repository.changedFileCount} 项未提交改动',
              child: Container(
                key: ValueKey<String>(
                  'repository-library-change-count:${repository.path}',
                ),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: badgeColor,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  '${repository.changedFileCount}',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: foregroundColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
        ],
        Tooltip(
          message: '当前分支 $_branchLabel',
          child: Container(
            key: ValueKey<String>(
              'repository-library-branch:${repository.path}',
            ),
            constraints: const BoxConstraints(maxWidth: 180),
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
            decoration: BoxDecoration(
              color: badgeColor,
              borderRadius: BorderRadius.circular(3),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  repository.isDetached
                      ? Icons.account_tree_outlined
                      : Icons.call_split_outlined,
                  size: 14,
                  color: foregroundColor,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    _branchLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: foregroundColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Displays a repository-provided root icon when it can be read safely.
class _RepositoryLibraryIcon extends StatefulWidget {
  const _RepositoryLibraryIcon({
    required this.iconPath,
    required this.repositoryPath,
    required this.selected,
  });

  final String iconPath;
  final String repositoryPath;
  final bool selected;

  /// 中文：创建仓库图标的状态对象。
  /// English: Creates the state object for the repository icon.
  @override
  State<_RepositoryLibraryIcon> createState() => _RepositoryLibraryIconState();
}

class _RepositoryLibraryIconState extends State<_RepositoryLibraryIcon> {
  late Future<bool> _hasCustomIcon;

  /// 中文：初始化仓库根目录图标的异步可用性检查。
  /// English: Starts the asynchronous availability check for the repository
  /// root icon.
  @override
  void initState() {
    super.initState();
    _hasCustomIcon = _findCustomIcon();
  }

  /// 中文：仓库路径变化时重新检查新的根目录，避免复用旧条目的图片结果。
  /// English: Rechecks the new root path when the repository changes so a
  /// reused tile cannot retain the previous item's image result.
  @override
  void didUpdateWidget(covariant _RepositoryLibraryIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.iconPath != widget.iconPath) {
      _hasCustomIcon = _findCustomIcon();
    }
  }

  /// 中文：异步确认仓库根目录的 `icon.png` 可读取；文件系统异常按无图标处理。
  /// English: Asynchronously checks whether the root `icon.png` is readable;
  /// file-system failures are treated as no custom icon.
  Future<bool> _findCustomIcon() async {
    try {
      return await File(widget.iconPath).exists();
    } on FileSystemException {
      return false;
    }
  }

  /// 中文：构建图片图标或默认 Git 图标，并在图片失效时安全回退。
  /// English: Builds the image or default Git icon and safely falls back when
  /// the image becomes unavailable.
  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final int cacheDimension = repositoryLibraryIconCacheDimension(
      MediaQuery.devicePixelRatioOf(context),
    );
    final Color backgroundColor = widget.selected
        ? colors.primary
        : colors.primaryContainer;
    final Color foregroundColor = widget.selected
        ? colors.onPrimary
        : colors.onPrimaryContainer;

    Widget fallbackIcon() =>
        Icon(Icons.account_tree_outlined, size: 20, color: foregroundColor);

    return FutureBuilder<bool>(
      future: _hasCustomIcon,
      builder: (context, snapshot) {
        final bool hasCustomIcon = snapshot.data == true;
        return Container(
          key: ValueKey<String>(
            'repository-library-icon:${widget.repositoryPath}',
          ),
          width: _repositoryLibraryIconSize,
          height: _repositoryLibraryIconSize,
          decoration: BoxDecoration(
            color: backgroundColor,
            shape: BoxShape.circle,
          ),
          clipBehavior: Clip.antiAlias,
          child: hasCustomIcon
              ? Image.file(
                  File(widget.iconPath),
                  fit: BoxFit.cover,
                  cacheWidth: cacheDimension,
                  cacheHeight: cacheDimension,
                  excludeFromSemantics: true,
                  errorBuilder: (context, error, stackTrace) => fallbackIcon(),
                )
              : fallbackIcon(),
        );
      },
    );
  }
}

class _RepositoryDirectoryDropOverlay extends StatelessWidget {
  const _RepositoryDirectoryDropOverlay();

  /// 中文：构建目录拖入时覆盖首页内容的接收提示。
  ///
  /// English: Builds the drop target hint over the repository library while
  /// macOS is dragging directories above it.
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: ColoredBox(
        color: colors.scrim.withValues(alpha: .24),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 22),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colors.primary, width: 2),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.folder_open_outlined,
                  color: colors.primary,
                  size: 32,
                ),
                const SizedBox(height: 10),
                Text(
                  '松开以添加 Git 仓库',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  '将自动识别仓库根目录。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RepositoryLibraryEmptyState extends StatelessWidget {
  const _RepositoryLibraryEmptyState({
    required this.hasQuery,
    this.onOpenRepository,
    this.onCloneRepository,
    this.onInitializeRepository,
  });

  final bool hasQuery;
  final VoidCallback? onOpenRepository;
  final VoidCallback? onCloneRepository;
  final VoidCallback? onInitializeRepository;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                hasQuery
                    ? Icons.search_off_outlined
                    : Icons.account_tree_outlined,
                size: 42,
                color: colors.onSurfaceVariant,
              ),
              const SizedBox(height: 14),
              Text(
                hasQuery ? '没有匹配的仓库' : '打开一个 Git 仓库',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                hasQuery ? '请尝试使用仓库名或路径的一部分进行筛选。' : '已打开的仓库会按所在目录显示在这里。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
              if (!hasQuery) ...[
                const SizedBox(height: 20),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: onOpenRepository,
                      icon: const Icon(Icons.folder_open_outlined),
                      label: const Text('打开仓库'),
                    ),
                    OutlinedButton.icon(
                      onPressed: onCloneRepository,
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('克隆仓库'),
                    ),
                    OutlinedButton.icon(
                      onPressed: onInitializeRepository,
                      icon: const Icon(Icons.create_new_folder_outlined),
                      label: const Text('初始化仓库'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
