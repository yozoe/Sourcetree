import 'package:flutter/material.dart';
import 'package:path/path.dart' as path_utils;

/// A repository displayed in the local repository library.
final class RepositoryLibraryItem {
  const RepositoryLibraryItem({required this.path, required this.label});

  /// Absolute path used to re-open this repository.
  final String path;

  /// Human-readable repository name.
  final String label;
}

/// A searchable, directory-grouped overview of locally known repositories.
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
                  height: 52,
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
                      if (widget.trailing != null) ...[
                        const SizedBox(width: 4),
                        widget.trailing!,
                      ],
                    ],
                  ),
                ),
                Expanded(
                  child: visibleRepositories.isEmpty
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
  });

  final Map<String, List<RepositoryLibraryItem>> groups;
  final String? activePath;
  final Future<void> Function(String path) onRepositorySelected;
  final bool reorderEnabled;
  final ValueChanged<List<String>>? onRepositoriesReordered;

  /// 中文：构建可按目录分组且可在组内拖动排序的仓库列表。
  ///
  /// English: Builds the directory-grouped repository list with optional
  /// within-group drag reordering.
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(10, 14, 10, 28),
      children: [
        for (final MapEntry<String, List<RepositoryLibraryItem>> group
            in groups.entries) ...[
          _RepositoryLibraryGroupHeader(
            title: group.key,
            count: group.value.length,
          ),
          _RepositoryLibraryGroup(
            repositories: group.value,
            activePath: activePath,
            onRepositorySelected: onRepositorySelected,
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
  });

  final List<RepositoryLibraryItem> repositories;
  final String? activePath;
  final Future<void> Function(String path) onRepositorySelected;
  final bool reorderEnabled;
  final ValueChanged<List<RepositoryLibraryItem>> onReordered;

  /// 中文：构建单个目录组，并只允许在组内调整仓库顺序。
  ///
  /// English: Builds one directory group and limits dragging to its repository
  /// entries so directory grouping remains stable.
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

/// Groups repositories by the final component of their parent directory.
Map<String, List<RepositoryLibraryItem>> _groupRepositories(
  List<RepositoryLibraryItem> repositories,
) {
  final Map<String, List<RepositoryLibraryItem>> groups =
      <String, List<RepositoryLibraryItem>>{};
  for (final RepositoryLibraryItem repository in repositories) {
    final String parentPath = path_utils.dirname(repository.path);
    final String groupLabel = path_utils.basename(parentPath).isEmpty
        ? parentPath
        : path_utils.basename(parentPath);
    groups
        .putIfAbsent(groupLabel, () => <RepositoryLibraryItem>[])
        .add(repository);
  }
  return groups;
}

class _RepositoryLibraryGroupHeader extends StatelessWidget {
  const _RepositoryLibraryGroupHeader({
    required this.title,
    required this.count,
  });

  final String title;
  final int count;

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

class _RepositoryLibraryTile extends StatelessWidget {
  const _RepositoryLibraryTile({
    super.key,
    required this.repository,
    required this.selected,
    required this.onPressed,
    this.dragHandle,
  });

  final RepositoryLibraryItem repository;
  final bool selected;
  final VoidCallback onPressed;
  final Widget? dragHandle;

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 1),
      child: Material(
        key: ValueKey<String>('repository-library-tile:${repository.path}'),
        color: selected ? colors.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(7),
          child: Semantics(
            button: true,
            selected: selected,
            label: '仓库 ${repository.label}',
            child: Container(
              constraints: const BoxConstraints(minHeight: 62),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: selected
                          ? colors.primary
                          : colors.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.account_tree_outlined,
                      size: 20,
                      color: selected
                          ? colors.onPrimary
                          : colors.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          repository.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: selected
                                ? colors.onSecondaryContainer
                                : colors.onSurface,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          repository.path,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: selected
                                ? colors.onSecondaryContainer.withValues(
                                    alpha: .78,
                                  )
                                : colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (selected) ...[
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
                  ...(dragHandle == null
                      ? const <Widget>[]
                      : <Widget>[dragHandle!]),
                ],
              ),
            ),
          ),
        ),
      ),
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
