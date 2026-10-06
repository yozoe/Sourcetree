import 'package:flutter/material.dart';

import 'git_flow_semantics.dart';

/// Collects an explicit multi-source Git-flow Finish, cleanup, and release tag.
/// 中文：收集多来源 Git-flow Finish、来源安全删除和本地版本标签的明确选项。
final class GitFlowBatchFinishDialog extends StatefulWidget {
  const GitFlowBatchFinishDialog({
    super.key,
    required this.localBranchNames,
    required this.currentBranch,
    required this.isAttachedHead,
    required this.isWorkingTreeClean,
    required this.hasActiveOperation,
  });

  final List<String> localBranchNames;
  final String? currentBranch;
  final bool isAttachedHead;
  final bool isWorkingTreeClean;
  final bool hasActiveOperation;

  @override
  State<GitFlowBatchFinishDialog> createState() =>
      _GitFlowBatchFinishDialogState();
}

final class _GitFlowBatchFinishDialogState
    extends State<GitFlowBatchFinishDialog> {
  late final List<String> _sources;
  late final List<String> _targets;
  late final List<String> _selectedSources;
  late String _target;
  var _deleteSources = false;
  final _tagController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _sources = widget.localBranchNames
        .where((name) => gitFlowBranchKindForName(name) != null)
        .toList(growable: false);
    _selectedSources = List<String>.of(_sources);
    _targets = orderGitFlowFinishTargets(
      sourceBranch: _sources.firstOrNull ?? widget.currentBranch,
      localBranchNames: widget.localBranchNames,
    );
    _target = _targets.firstOrNull ?? '';
  }

  @override
  void dispose() {
    _tagController.dispose();
    super.dispose();
  }

  ({GitFlowBatchFinishPlan? plan, String? error}) get _validation =>
      validateGitFlowBatchFinish(
        sourceBranches: _selectedSources,
        targetBranch: _target,
        existingBranches: widget.localBranchNames,
        isAttachedHead: widget.isAttachedHead,
        isWorkingTreeClean: widget.isWorkingTreeClean,
        hasActiveOperation: widget.hasActiveOperation,
        deleteSourceBranches: _deleteSources,
        releaseTag: _tagController.text.trim().isEmpty
            ? null
            : _tagController.text.trim(),
      );

  @override
  Widget build(BuildContext context) {
    final validation = _validation;
    final plan = validation.plan;
    final orderedSources = [
      ..._selectedSources,
      for (final source in _sources)
        if (!_selectedSources.contains(source)) source,
    ];
    return AlertDialog(
      title: const Text('批量完成 Git Flow 分支'),
      content: SizedBox(
        width: 580,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('来源分支（按列表顺序合并）'),
              const SizedBox(height: 6),
              if (_sources.isEmpty)
                const Text('当前没有可完成的 feature、release 或 hotfix 分支。')
              else ...[
                for (final source in orderedSources)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: _selectedSources.contains(source),
                    title: Text(source),
                    secondary: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: '上移',
                          onPressed:
                              !_selectedSources.contains(source) ||
                                  _selectedSources.indexOf(source) == 0
                              ? null
                              : () {
                                  setState(() {
                                    final index = _selectedSources.indexOf(
                                      source,
                                    );
                                    final previous =
                                        _selectedSources[index - 1];
                                    _selectedSources[index - 1] = source;
                                    _selectedSources[index] = previous;
                                  });
                                },
                          icon: const Icon(Icons.arrow_upward, size: 18),
                        ),
                        IconButton(
                          tooltip: '下移',
                          onPressed:
                              !_selectedSources.contains(source) ||
                                  _selectedSources.indexOf(source) ==
                                      _selectedSources.length - 1
                              ? null
                              : () {
                                  setState(() {
                                    final index = _selectedSources.indexOf(
                                      source,
                                    );
                                    final next = _selectedSources[index + 1];
                                    _selectedSources[index + 1] = source;
                                    _selectedSources[index] = next;
                                  });
                                },
                          icon: const Icon(Icons.arrow_downward, size: 18),
                        ),
                      ],
                    ),
                    onChanged: (value) {
                      setState(() {
                        if (value == true) {
                          _selectedSources.add(source);
                        } else {
                          _selectedSources.remove(source);
                        }
                      });
                    },
                  ),
              ],
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: _targets.contains(_target) ? _target : null,
                decoration: const InputDecoration(labelText: '目标本地分支'),
                items: [
                  for (final target in _targets)
                    DropdownMenuItem(value: target, child: Text(target)),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => _target = value);
                },
              ),
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: _deleteSources,
                title: const Text('合并成功后安全删除来源分支'),
                subtitle: const Text('只调用 Git 的安全删除模式；未合并分支不会被强制删除。'),
                onChanged: (value) =>
                    setState(() => _deleteSources = value ?? false),
                controlAffinity: ListTileControlAffinity.leading,
              ),
              TextField(
                controller: _tagController,
                decoration: const InputDecoration(
                  labelText: '版本标签（可选）',
                  hintText: 'v1.2.3',
                  helperText: '只创建本地附注标签；不会自动推送。仅 release/hotfix 来源可创建标签。',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 10),
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    plan == null
                        ? (validation.error ?? '请选择有效的 Git-flow 参数。')
                        : '将 ${plan.sourceBranches.length} 个来源合并到 ${plan.targetBranch}。\n'
                              '${plan.releaseTag == null ? '不创建版本标签。' : '完成后创建 ${plan.releaseTag}。'}\n'
                              '${plan.deleteSourceBranches ? '完成后尝试安全删除来源分支。' : '保留来源分支。'}',
                    style: TextStyle(
                      color: plan == null
                          ? Theme.of(context).colorScheme.error
                          : null,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: plan == null
              ? null
              : () => Navigator.of(context).pop(plan),
          child: const Text('开始批量完成'),
        ),
      ],
    );
  }
}
