import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

/// One standard Git conflict-marker region in editable text.
///
/// 中文：可编辑结果中的一个标准 Git 冲突标记区段，保留当前区段在原文中的
/// 字符偏移范围以及两侧内容，供逐段选择而不影响其他冲突区段。
final class ConflictMarkerRegion {
  const ConflictMarkerRegion({
    required this.startOffset,
    required this.endOffset,
    required this.oursText,
    required this.theirsText,
  });

  final int startOffset;
  final int endOffset;
  final String oursText;
  final String theirsText;
}

/// Parses standard Git conflict markers without interpreting arbitrary source
/// text as a conflict region.
///
/// 中文：解析标准 Git 冲突标记，只有完整的 `<<<<<<<`、`=======`、
/// `>>>>>>>` 行才会形成区段；不完整或嵌套的标记会留给现有保存警告处理。
List<ConflictMarkerRegion> parseConflictMarkerRegions(String text) {
  final regions = <ConflictMarkerRegion>[];
  var searchOffset = 0;
  final startPattern = RegExp(r'^<<<<<<<[^\n]*(?:\n|$)', multiLine: true);
  final separatorPattern = RegExp(r'^=======[^\n]*(?:\n|$)', multiLine: true);
  final endPattern = RegExp(r'^>>>>>>>[^\n]*(?:\n|$)', multiLine: true);

  while (searchOffset < text.length) {
    final start = startPattern.firstMatch(text.substring(searchOffset));
    if (start == null) break;
    final startOffset = searchOffset + start.start;
    final contentStart = searchOffset + start.end;
    final separator = separatorPattern.firstMatch(text.substring(contentStart));
    if (separator == null) break;
    final separatorStart = contentStart + separator.start;
    final theirsStart = contentStart + separator.end;
    final end = endPattern.firstMatch(text.substring(theirsStart));
    if (end == null) break;
    final endStart = theirsStart + end.start;
    final endOffset = theirsStart + end.end;
    regions.add(
      ConflictMarkerRegion(
        startOffset: startOffset,
        endOffset: endOffset,
        oursText: text.substring(contentStart, separatorStart),
        theirsText: text.substring(theirsStart, endStart),
      ),
    );
    searchOffset = endOffset;
  }
  return regions;
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
    this.baseText,
    this.hasBaseVersion = false,
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
  final String? baseText;
  final bool hasBaseVersion;
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
  bool _showBase = false;
  int _selectedConflictRegion = 0;

  bool get _canSave => !widget.isBinary && !widget.isTruncated;

  /// 中文：以当前工作区合并内容初始化编辑器。
  /// English: Initializes the editor from the current work-tree merge result.
  @override
  void initState() {
    super.initState();
    _resultController = TextEditingController(text: widget.workingText);
    _resultController.addListener(_handleResultChanged);
  }

  /// 中文：释放合并结果编辑器。
  /// English: Releases the merge-result editor.
  @override
  void dispose() {
    _resultController.removeListener(_handleResultChanged);
    _resultController.dispose();
    super.dispose();
  }

  /// 中文：编辑结果变化后刷新逐段冲突操作，确保区段索引不会过期。
  /// English: Refreshes per-region conflict actions after edits so the index
  /// never points at stale marker offsets.
  void _handleResultChanged() {
    if (!mounted) return;
    final count = parseConflictMarkerRegions(_resultController.text).length;
    if (_selectedConflictRegion >= count && count > 0) {
      setState(() => _selectedConflictRegion = count - 1);
    } else if (count == 0 && _selectedConflictRegion != 0) {
      setState(() => _selectedConflictRegion = 0);
    } else {
      setState(() {});
    }
  }

  /// 中文：将选定一侧的完整内容放入可编辑的合并结果。
  /// English: Replaces the editable merge result with one complete side.
  void _useVersion(String text) {
    _resultController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  /// 中文：仅替换当前冲突标记区段的一侧内容，保留其他区段继续处理。
  /// English: Replaces only the selected conflict-marker region with one side
  /// while leaving every other region available for later resolution.
  void _useConflictRegionVersion({required bool ours}) {
    if (!_canSave) return;
    final text = _resultController.text;
    final regions = parseConflictMarkerRegions(text);
    if (_selectedConflictRegion >= regions.length) return;
    final region = regions[_selectedConflictRegion];
    final replacement = ours ? region.oursText : region.theirsText;
    final updated = text.replaceRange(
      region.startOffset,
      region.endOffset,
      replacement,
    );
    _resultController.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(
        offset: math.min(
          region.startOffset + replacement.length,
          updated.length,
        ),
      ),
    );
  }

  /// 中文：保存编辑结果前警告仍保留任意 Git 冲突标记的内容，并等待明确确认。
  /// English: Warns before saving content that still contains any Git conflict
  /// marker and waits for explicit confirmation.
  Future<void> _saveResult() async {
    if (!_canSave) return;
    final result = _resultController.text;
    if (_containsConflictMarkers(result)) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          key: const ValueKey('conflict-marker-warning-dialog'),
          title: const Text('仍包含冲突标记'),
          content: const Text(
            '当前合并结果仍包含 <<<<<<<、======= 或 >>>>>>> 标记。'
            '继续保存会让 Git 将这些标记当作普通文件内容并标记为已解决。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('返回编辑'),
            ),
            FilledButton(
              key: const ValueKey('confirm-conflict-marker-save'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('仍然保存'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(result);
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
                    if (widget.hasBaseVersion &&
                        widget.baseText != null &&
                        widget.baseText!.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          key: const ValueKey('toggle-conflict-base'),
                          onPressed: () {
                            setState(() => _showBase = !_showBase);
                          },
                          icon: Icon(
                            _showBase
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                            size: 16,
                          ),
                          label: Text(_showBase ? '隐藏共同基线' : '显示共同基线'),
                        ),
                      ),
                      if (_showBase)
                        ConstrainedBox(
                          key: const ValueKey('conflict-base-preview'),
                          constraints: const BoxConstraints(maxHeight: 110),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border.all(color: theme.dividerColor),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: SingleChildScrollView(
                                child: Padding(
                                  padding: const EdgeInsets.all(10),
                                  child: Text(
                                    widget.baseText!,
                                    style: _monospaceStyle(theme),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
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
                          if (widget.hasBaseVersion && widget.baseText != null)
                            OutlinedButton.icon(
                              key: const ValueKey('use-base-version'),
                              onPressed: _canSave
                                  ? () => _useVersion(widget.baseText!)
                                  : null,
                              icon: const Icon(Icons.history, size: 16),
                              label: const Tooltip(
                                message: '使用共同基线版本',
                                child: Text(
                                  '使用共同基线',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                        ];
                        return Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final button in buttons)
                              SizedBox(
                                width: math.max(
                                  180,
                                  (constraints.maxWidth -
                                          (buttons.length - 1) * 8) /
                                      buttons.length,
                                ),
                                child: button,
                              ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 10),
                    Text('合并结果', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 6),
                    Builder(
                      builder: (context) {
                        final regions = parseConflictMarkerRegions(
                          _resultController.text,
                        );
                        if (regions.isEmpty) return const SizedBox.shrink();
                        final selected = math.min(
                          _selectedConflictRegion,
                          regions.length - 1,
                        );
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text('逐段处理（共 ${regions.length} 段）'),
                              DropdownButton<int>(
                                key: const ValueKey('conflict-region-selector'),
                                value: selected,
                                isDense: true,
                                items: [
                                  for (
                                    var index = 0;
                                    index < regions.length;
                                    index++
                                  )
                                    DropdownMenuItem(
                                      value: index,
                                      child: Text('第 ${index + 1} 段'),
                                    ),
                                ],
                                onChanged: _canSave
                                    ? (value) {
                                        if (value == null) return;
                                        setState(
                                          () => _selectedConflictRegion = value,
                                        );
                                      }
                                    : null,
                              ),
                              OutlinedButton(
                                key: const ValueKey('use-ours-conflict-region'),
                                onPressed: _canSave
                                    ? () =>
                                          _useConflictRegionVersion(ours: true)
                                    : null,
                                child: const Text('当前段用我的版本'),
                              ),
                              OutlinedButton(
                                key: const ValueKey(
                                  'use-theirs-conflict-region',
                                ),
                                onPressed: _canSave
                                    ? () =>
                                          _useConflictRegionVersion(ours: false)
                                    : null,
                                child: const Text('当前段用他们的版本'),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
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
                    onPressed: _canSave ? _saveResult : null,
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

/// 中文：判断文本是否包含任意 Git 冲突标记行。
/// English: Returns whether text contains any Git conflict marker line.
bool _containsConflictMarkers(String text) {
  return text.split('\n').any((line) {
    final trimmed = line.trimLeft();
    return trimmed.startsWith('<<<<<<<') ||
        trimmed.startsWith('=======') ||
        trimmed.startsWith('>>>>>>>');
  });
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

class _SideBySideDiff extends StatefulWidget {
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

  @override
  State<_SideBySideDiff> createState() => _SideBySideDiffState();
}

class _SideBySideDiffState extends State<_SideBySideDiff> {
  late final ScrollController _scrollController;
  late final FocusNode _focusNode;
  bool _showOnlyDifferences = false;
  int? _activeDifferenceIndex;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _focusNode = FocusNode(debugLabel: 'Conflict difference navigator');
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// 中文：循环定位到上一处或下一处差异，并同步保留原始行号。
  /// English: Cycles to the previous or next difference while retaining the
  /// original aligned row index.
  void _jumpToDifference({
    required List<int> differenceIndices,
    required List<(int, ConflictDiffLine)> visibleLines,
    required double rowHeight,
    required bool forward,
  }) {
    if (differenceIndices.isEmpty) return;
    final currentPosition = _activeDifferenceIndex == null
        ? -1
        : differenceIndices.indexOf(_activeDifferenceIndex!);
    final nextPosition = forward
        ? (currentPosition + 1) % differenceIndices.length
        : (currentPosition <= 0
              ? differenceIndices.length - 1
              : currentPosition - 1);
    final targetIndex = differenceIndices[nextPosition];
    final visiblePosition = visibleLines.indexWhere(
      (entry) => entry.$1 == targetIndex,
    );
    if (visiblePosition < 0) return;
    setState(() => _activeDifferenceIndex = targetIndex);
    if (!_scrollController.hasClients) return;
    final targetOffset = (visiblePosition * rowHeight).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  /// 中文：构建共用行对齐与差异高亮的左右版本列表。
  /// English: Builds the aligned side-by-side version list with difference
  /// highlighting.
  @override
  Widget build(BuildContext context) {
    final allLines = alignConflictLines(widget.oursText, widget.theirsText);
    final differenceIndices = <int>[
      for (var index = 0; index < allLines.length; index++)
        if (!allLines[index].isEqual) index,
    ];
    final differenceCount = differenceIndices.length;
    final lines = <(int, ConflictDiffLine)>[
      for (var index = 0; index < allLines.length; index++)
        if (!_showOnlyDifferences || !allLines[index].isEqual)
          (index, allLines[index]),
    ];
    final theme = Theme.of(context);
    final rowHeight = _scaledHeight(context, 24);

    final longestLine = lines.fold<int>(0, (longest, entry) {
      final line = entry.$2;
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
        return Focus(
          focusNode: _focusNode,
          onKeyEvent: (node, event) {
            if (event is! KeyDownEvent) return KeyEventResult.ignored;
            if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
              _jumpToDifference(
                differenceIndices: differenceIndices,
                visibleLines: lines,
                rowHeight: rowHeight,
                forward: true,
              );
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
              _jumpToDifference(
                differenceIndices: differenceIndices,
                visibleLines: lines,
                rowHeight: rowHeight,
                forward: false,
              );
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _focusNode.requestFocus,
            child: Semantics(
              container: true,
              label: differenceCount == 0
                  ? '冲突差异对比，无差异'
                  : '冲突差异对比，共 $differenceCount 处差异；可用上下方向键定位',
              child: SingleChildScrollView(
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
                          _DiffHeader(
                            oursLabel: widget.oursLabel,
                            theirsLabel: widget.theirsLabel,
                            differenceCount: differenceCount,
                            activeDifferencePosition:
                                _activeDifferenceIndex == null
                                ? null
                                : differenceIndices.indexOf(
                                        _activeDifferenceIndex!,
                                      ) +
                                      1,
                            showOnlyDifferences: _showOnlyDifferences,
                            onToggleDifferences: differenceCount == 0
                                ? null
                                : () => setState(() {
                                    _showOnlyDifferences =
                                        !_showOnlyDifferences;
                                  }),
                            onPreviousDifference: differenceCount == 0
                                ? null
                                : () => _jumpToDifference(
                                    differenceIndices: differenceIndices,
                                    visibleLines: lines,
                                    rowHeight: rowHeight,
                                    forward: false,
                                  ),
                            onNextDifference: differenceCount == 0
                                ? null
                                : () => _jumpToDifference(
                                    differenceIndices: differenceIndices,
                                    visibleLines: lines,
                                    rowHeight: rowHeight,
                                    forward: true,
                                  ),
                          ),
                          Expanded(
                            child: ListView.builder(
                              key: const ValueKey('conflict-side-by-side-diff'),
                              controller: _scrollController,
                              itemExtent: rowHeight,
                              itemCount: lines.length,
                              itemBuilder: (context, index) {
                                final (originalIndex, line) = lines[index];
                                final differs = !line.isEqual;
                                return Container(
                                  key: ValueKey(
                                    differs
                                        ? 'conflict-difference-row-$originalIndex'
                                        : 'conflict-equal-row-$originalIndex',
                                  ),
                                  decoration: BoxDecoration(
                                    color:
                                        _activeDifferenceIndex == originalIndex
                                        ? theme.colorScheme.primaryContainer
                                        : differs
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
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DiffHeader extends StatelessWidget {
  const _DiffHeader({
    required this.oursLabel,
    required this.theirsLabel,
    required this.differenceCount,
    required this.activeDifferencePosition,
    required this.showOnlyDifferences,
    required this.onToggleDifferences,
    required this.onPreviousDifference,
    required this.onNextDifference,
  });

  final String oursLabel;
  final String theirsLabel;
  final int differenceCount;
  final int? activeDifferencePosition;
  final bool showOnlyDifferences;
  final VoidCallback? onToggleDifferences;
  final VoidCallback? onPreviousDifference;
  final VoidCallback? onNextDifference;

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
          SizedBox(
            width: _scaledHeight(context, 220),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  activeDifferencePosition == null
                      ? '$differenceCount'
                      : '$activeDifferencePosition/$differenceCount',
                  semanticsLabel: activeDifferencePosition == null
                      ? '$differenceCount 处差异'
                      : '第 $activeDifferencePosition 处，共 $differenceCount 处差异',
                  style: style,
                ),
                Tooltip(
                  message: '上一处差异',
                  child: IconButton(
                    key: const ValueKey('previous-conflict-difference'),
                    onPressed: onPreviousDifference,
                    padding: EdgeInsets.zero,
                    iconSize: _scaledHeight(context, 17),
                    tooltip: '上一处差异',
                    icon: const Icon(Icons.keyboard_arrow_up),
                  ),
                ),
                Tooltip(
                  message: '下一处差异',
                  child: IconButton(
                    key: const ValueKey('next-conflict-difference'),
                    onPressed: onNextDifference,
                    padding: EdgeInsets.zero,
                    iconSize: _scaledHeight(context, 17),
                    tooltip: '下一处差异',
                    icon: const Icon(Icons.keyboard_arrow_down),
                  ),
                ),
                Tooltip(
                  message: showOnlyDifferences
                      ? '显示全部（$differenceCount 处差异）'
                      : '仅显示差异（$differenceCount 处差异）',
                  child: IconButton(
                    key: const ValueKey('toggle-conflict-differences'),
                    onPressed: onToggleDifferences,
                    padding: EdgeInsets.zero,
                    iconSize: _scaledHeight(context, 17),
                    tooltip: showOnlyDifferences ? '显示全部' : '仅显示差异',
                    icon: Icon(
                      showOnlyDifferences
                          ? Icons.filter_alt_off_outlined
                          : Icons.filter_alt_outlined,
                    ),
                  ),
                ),
              ],
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
