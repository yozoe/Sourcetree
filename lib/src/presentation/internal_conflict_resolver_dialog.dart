import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// One aligned row in the internal conflict comparison.
///
/// 中文：内部冲突对比中的一行；任一侧为空表示该行只存在于另一版本。
final class ConflictDiffLine {
  const ConflictDiffLine({
    required this.oursLineNumber,
    required this.oursText,
    required this.theirsLineNumber,
    required this.theirsText,
  });

  final int? oursLineNumber;
  final String? oursText;
  final int? theirsLineNumber;
  final String? theirsText;

  bool get isEqual => oursText != null && oursText == theirsText;
}

const int _maximumLcsCells = 250000;

/// Aligns two text versions around their longest common subsequence.
///
/// Replacement blocks are zipped so related changed lines remain side by
/// side. To keep rendering bounded, very large inputs use positional pairing
/// instead of allocating a quadratic LCS table.
///
/// 中文：以最长公共子序列为锚点对齐两个文本版本，并将相邻替换行并排展示；
/// 超大输入会退化为按位置配对，避免为二次复杂度表格耗尽内存。
List<ConflictDiffLine> alignConflictLines(String oursText, String theirsText) {
  final ours = oursText.split('\n');
  final theirs = theirsText.split('\n');
  if (ours.length * theirs.length > _maximumLcsCells) {
    return _zipConflictGap(ours, theirs, 0, 0);
  }

  final table = List<Uint32List>.generate(
    ours.length + 1,
    (_) => Uint32List(theirs.length + 1),
    growable: false,
  );
  for (var oursIndex = ours.length - 1; oursIndex >= 0; oursIndex--) {
    for (var theirsIndex = theirs.length - 1; theirsIndex >= 0; theirsIndex--) {
      table[oursIndex][theirsIndex] = ours[oursIndex] == theirs[theirsIndex]
          ? table[oursIndex + 1][theirsIndex + 1] + 1
          : math.max(
              table[oursIndex + 1][theirsIndex],
              table[oursIndex][theirsIndex + 1],
            );
    }
  }

  final anchors = <(int, int)>[];
  var oursIndex = 0;
  var theirsIndex = 0;
  while (oursIndex < ours.length && theirsIndex < theirs.length) {
    if (ours[oursIndex] == theirs[theirsIndex]) {
      anchors.add((oursIndex++, theirsIndex++));
    } else if (table[oursIndex + 1][theirsIndex] >=
        table[oursIndex][theirsIndex + 1]) {
      oursIndex++;
    } else {
      theirsIndex++;
    }
  }

  final result = <ConflictDiffLine>[];
  oursIndex = 0;
  theirsIndex = 0;
  for (final anchor in anchors) {
    result.addAll(
      _zipConflictGap(
        ours.sublist(oursIndex, anchor.$1),
        theirs.sublist(theirsIndex, anchor.$2),
        oursIndex,
        theirsIndex,
      ),
    );
    result.add(
      ConflictDiffLine(
        oursLineNumber: anchor.$1 + 1,
        oursText: ours[anchor.$1],
        theirsLineNumber: anchor.$2 + 1,
        theirsText: theirs[anchor.$2],
      ),
    );
    oursIndex = anchor.$1 + 1;
    theirsIndex = anchor.$2 + 1;
  }
  result.addAll(
    _zipConflictGap(
      ours.sublist(oursIndex),
      theirs.sublist(theirsIndex),
      oursIndex,
      theirsIndex,
    ),
  );
  return result;
}

List<ConflictDiffLine> _zipConflictGap(
  List<String> ours,
  List<String> theirs,
  int oursOffset,
  int theirsOffset,
) => [
  for (var index = 0; index < math.max(ours.length, theirs.length); index++)
    ConflictDiffLine(
      oursLineNumber: index < ours.length ? oursOffset + index + 1 : null,
      oursText: index < ours.length ? ours[index] : null,
      theirsLineNumber: index < theirs.length ? theirsOffset + index + 1 : null,
      theirsText: index < theirs.length ? theirs[index] : null,
    ),
];

/// 中文：用于文本冲突的内置三方合并对话框。
///
/// English: An internal, text-only three-way conflict resolver. The two index
/// sides stay vertically aligned in a shared list. The editable
/// result starts with the work-tree merge result and is returned only when the
/// user explicitly saves it.
class InternalConflictResolverDialog extends StatefulWidget {
  const InternalConflictResolverDialog({
    super.key,
    required this.path,
    required this.currentBranch,
    required this.oursText,
    required this.theirsText,
    required this.workingText,
    this.oursLabel,
    this.theirsLabel,
    this.isBinary = false,
    this.isTruncated = false,
  });

  final String path;
  final String currentBranch;
  final String oursText;
  final String theirsText;
  final String workingText;
  final String? oursLabel;
  final String? theirsLabel;
  final bool isBinary;
  final bool isTruncated;

  /// 中文：创建维护合并结果编辑状态的对话框状态。
  /// English: Creates the dialog state that owns the editable merge result.
  @override
  State<InternalConflictResolverDialog> createState() =>
      _InternalConflictResolverDialogState();
}

class _InternalConflictResolverDialogState
    extends State<InternalConflictResolverDialog> {
  late final TextEditingController _resultController;

  bool get _canSave => !widget.isBinary && !widget.isTruncated;

  /// 中文：以当前工作区合并内容初始化编辑器。
  /// English: Initializes the editor from the current work-tree merge result.
  @override
  void initState() {
    super.initState();
    _resultController = TextEditingController(text: widget.workingText);
  }

  /// 中文：释放合并结果编辑器。
  /// English: Releases the merge-result editor.
  @override
  void dispose() {
    _resultController.dispose();
    super.dispose();
  }

  /// 中文：将选定一侧的完整内容放入可编辑的合并结果。
  /// English: Replaces the editable merge result with one complete side.
  void _useVersion(String text) {
    _resultController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  /// 中文：构建内部冲突 Diff 与可编辑合并结果。
  /// English: Builds the internal conflict Diff and editable merge result.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final size = MediaQuery.sizeOf(context);
    final height = math.max(420.0, math.min(680.0, size.height - 96));

    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: math.min(1080, size.width - 48),
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DialogHeader(path: widget.path),
            if (!_canSave)
              Container(
                key: const ValueKey('conflict-resolver-warning'),
                color: colors.errorContainer,
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 9,
                ),
                child: Text(
                  widget.isBinary
                      ? '该文件包含二进制或非 UTF-8 内容，内部 Diff 仅供查看。'
                      : '文件超过内部 Diff 的大小上限，内容已截断，不能从此处保存。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onErrorContainer,
                  ),
                ),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: 3,
                      child: _SideBySideDiff(
                        oursLabel:
                            widget.oursLabel ??
                            '我的版本 · ${widget.currentBranch}',
                        theirsLabel: widget.theirsLabel ?? '他们的版本 · 合并来源',
                        oursText: widget.oursText,
                        theirsText: widget.theirsText,
                      ),
                    ),
                    const SizedBox(height: 10),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final oursActionLabel =
                            '使用${widget.oursLabel ?? "我的版本"}';
                        final theirsActionLabel =
                            '使用${widget.theirsLabel ?? "他们的版本"}';
                        final buttons = <Widget>[
                          OutlinedButton.icon(
                            key: const ValueKey('use-ours-version'),
                            onPressed: _canSave
                                ? () => _useVersion(widget.oursText)
                                : null,
                            icon: const Icon(Icons.arrow_downward, size: 16),
                            label: Tooltip(
                              message: oursActionLabel,
                              child: Text(
                                oursActionLabel,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          OutlinedButton.icon(
                            key: const ValueKey('use-theirs-version'),
                            onPressed: _canSave
                                ? () => _useVersion(widget.theirsText)
                                : null,
                            icon: const Icon(Icons.arrow_downward, size: 16),
                            label: Tooltip(
                              message: theirsActionLabel,
                              child: Text(
                                theirsActionLabel,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ];
                        final useVerticalLayout = constraints.maxWidth < 620;
                        if (useVerticalLayout) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              buttons.first,
                              const SizedBox(height: 8),
                              buttons.last,
                            ],
                          );
                        }
                        return Row(
                          children: [
                            Expanded(child: buttons.first),
                            const SizedBox(width: 8),
                            Expanded(child: buttons.last),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 10),
                    Text('合并结果', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 6),
                    Expanded(
                      flex: 2,
                      child: TextField(
                        key: const ValueKey('conflict-result-editor'),
                        controller: _resultController,
                        enabled: _canSave,
                        expands: true,
                        minLines: null,
                        maxLines: null,
                        textAlignVertical: TextAlignVertical.top,
                        style: _monospaceStyle(theme),
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.all(10),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Container(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: theme.dividerColor)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    key: const ValueKey('save-conflict-result'),
                    onPressed: _canSave
                        ? () =>
                              Navigator.of(context).pop(_resultController.text)
                        : null,
                    icon: const Icon(Icons.check, size: 17),
                    label: const Text('保存并标记为已解决'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DialogHeader extends StatelessWidget {
  const _DialogHeader({required this.path});

  final String path;

  /// 中文：构建包含文件路径和关闭操作的对话框标题栏。
  /// English: Builds the dialog header with its file path and close action.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
      child: Row(
        children: [
          Icon(Icons.compare_arrows, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('解决冲突', style: theme.textTheme.titleMedium),
                const SizedBox(height: 2),
                Text(
                  path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}

class _SideBySideDiff extends StatelessWidget {
  const _SideBySideDiff({
    required this.oursLabel,
    required this.theirsLabel,
    required this.oursText,
    required this.theirsText,
  });

  final String oursLabel;
  final String theirsLabel;
  final String oursText;
  final String theirsText;

  /// 中文：构建共用行对齐与差异高亮的左右版本列表。
  /// English: Builds the aligned side-by-side version list with difference
  /// highlighting.
  @override
  Widget build(BuildContext context) {
    final lines = alignConflictLines(oursText, theirsText);
    final theme = Theme.of(context);
    final rowHeight = _scaledHeight(context, 24);

    final longestLine = lines.fold<int>(0, (longest, line) {
      return math.max(
        longest,
        math.max(line.oursText?.length ?? 0, line.theirsText?.length ?? 0),
      );
    });
    final textScale = math.max(1.0, MediaQuery.textScalerOf(context).scale(1));
    return LayoutBuilder(
      builder: (context, constraints) {
        final contentWidth = math.max(
          constraints.maxWidth,
          math.min(32768.0, (70 + longestLine * 7.2 * textScale) * 2),
        );
        return SingleChildScrollView(
          key: const ValueKey('conflict-horizontal-scroll'),
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: contentWidth,
            height: constraints.maxHeight,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: theme.dividerColor),
                borderRadius: BorderRadius.circular(6),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: Column(
                  children: [
                    _DiffHeader(oursLabel: oursLabel, theirsLabel: theirsLabel),
                    Expanded(
                      child: ListView.builder(
                        key: const ValueKey('conflict-side-by-side-diff'),
                        itemExtent: rowHeight,
                        itemCount: lines.length,
                        itemBuilder: (context, index) {
                          final line = lines[index];
                          final differs = !line.isEqual;
                          return Container(
                            key: ValueKey(
                              differs
                                  ? 'conflict-difference-row-$index'
                                  : 'conflict-equal-row-$index',
                            ),
                            decoration: BoxDecoration(
                              color: differs
                                  ? theme.colorScheme.tertiaryContainer
                                        .withValues(alpha: .32)
                                  : null,
                              border: Border(
                                bottom: BorderSide(
                                  color: theme.dividerColor.withValues(
                                    alpha: .35,
                                  ),
                                ),
                              ),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: _VersionLine(
                                    lineNumber: line.oursLineNumber,
                                    text: line.oursText,
                                  ),
                                ),
                                VerticalDivider(
                                  width: 1,
                                  color: theme.dividerColor,
                                ),
                                Expanded(
                                  child: _VersionLine(
                                    lineNumber: line.theirsLineNumber,
                                    text: line.theirsText,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DiffHeader extends StatelessWidget {
  const _DiffHeader({required this.oursLabel, required this.theirsLabel});

  final String oursLabel;
  final String theirsLabel;

  /// 中文：构建左右版本的标题行。
  /// English: Builds the two version headings.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelMedium?.copyWith(
      fontWeight: FontWeight.w600,
    );
    return Container(
      height: _scaledHeight(context, 34),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                oursLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
          ),
          VerticalDivider(width: 1, color: theme.dividerColor),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                theirsLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _VersionLine extends StatelessWidget {
  const _VersionLine({required this.lineNumber, required this.text});

  final int? lineNumber;
  final String? text;

  /// 中文：构建含行号的单侧等宽文本行。
  /// English: Builds one numbered monospace line for a version pane.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(
          width: 42,
          child: Text(
            lineNumber?.toString() ?? '',
            textAlign: TextAlign.right,
            style: _monospaceStyle(theme).copyWith(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: .7),
              fontSize: 11,
            ),
          ),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            text ?? '',
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
            style: _monospaceStyle(theme),
          ),
        ),
        const SizedBox(width: 8),
      ],
    );
  }
}

/// 中文：返回内部 Diff 和结果编辑器共用的等宽文本样式。
/// English: Returns the monospace style shared by the Diff and result editor.
TextStyle _monospaceStyle(ThemeData theme) =>
    (theme.textTheme.bodySmall ?? const TextStyle()).copyWith(
      fontFamily: 'monospace',
      height: 1.35,
    );

double _scaledHeight(BuildContext context, double base) {
  final scale = math.max(1.0, MediaQuery.textScalerOf(context).scale(1));
  return base * scale;
}
