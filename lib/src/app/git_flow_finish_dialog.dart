import 'package:flutter/material.dart';

import 'git_flow_semantics.dart';

/// Collects the explicit target for one Git-flow v1 Finish plan.
/// 中文：收集 Git-flow v1 Finish 的明确目标分支，并在执行前展示无副作用预览。
class GitFlowFinishDialog extends StatefulWidget {
  const GitFlowFinishDialog({
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
  State<GitFlowFinishDialog> createState() => _GitFlowFinishDialogState();
}

class _GitFlowFinishDialogState extends State<GitFlowFinishDialog> {
  late String _targetBranch;

  @override
  void initState() {
    super.initState();
    final names = _availableTargets;
    _targetBranch = names.firstOrNull ?? '';
  }

  List<String> get _availableTargets {
    return orderGitFlowFinishTargets(
      sourceBranch: widget.currentBranch,
      localBranchNames: widget.localBranchNames,
    );
  }

  ({GitFlowFinishPlan? plan, String? error}) get _validation {
    return validateGitFlowFinish(
      sourceBranch: widget.currentBranch ?? '',
      targetBranch: _targetBranch,
      existingBranches: widget.localBranchNames,
      isAttachedHead: widget.isAttachedHead,
      isWorkingTreeClean: widget.isWorkingTreeClean,
      hasActiveOperation: widget.hasActiveOperation,
    );
  }

  @override
  Widget build(BuildContext context) {
    final validation = _validation;
    final plan = validation.plan;
    return AlertDialog(
      title: const Text('完成 Git Flow 分支'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('来源分支：${widget.currentBranch ?? '—'}'),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _availableTargets.contains(_targetBranch)
                  ? _targetBranch
                  : null,
              decoration: const InputDecoration(labelText: '目标本地分支'),
              items: [
                for (final branch in _availableTargets)
                  DropdownMenuItem(value: branch, child: Text(branch)),
              ],
              onChanged: (value) {
                if (value == null) return;
                setState(() => _targetBranch = value);
              },
            ),
            const SizedBox(height: 16),
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  plan == null
                      ? (validation.error ?? '请输入有效的 Git-flow 参数。')
                      : '执行：${plan.mergeStrategy}\n'
                            '${plan.sourceBranch} → ${plan.targetBranch}\n'
                            '不会推送、删除来源分支或修改 upstream。',
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
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: plan == null
              ? null
              : () => Navigator.of(context).pop(plan),
          child: const Text('合并完成'),
        ),
      ],
    );
  }
}
