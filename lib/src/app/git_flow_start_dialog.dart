import 'package:flutter/material.dart';

import 'git_flow_semantics.dart';

/// Collects the explicit inputs for one Git-flow v1 Start plan.
/// 中文：收集 Git-flow v1 Start 的显式输入，并在提交前展示无副作用预览。
class GitFlowStartDialog extends StatefulWidget {
  const GitFlowStartDialog({
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
  State<GitFlowStartDialog> createState() => _GitFlowStartDialogState();
}

class _GitFlowStartDialogState extends State<GitFlowStartDialog> {
  late final TextEditingController _nameController;
  late String _baseBranch;
  var _kind = GitFlowBranchKind.feature;

  @override
  void initState() {
    super.initState();
    final names = _availableBranches;
    _baseBranch = names.contains(widget.currentBranch)
        ? widget.currentBranch!
        : names.firstOrNull ?? '';
    _nameController = TextEditingController();
    _nameController.addListener(_onInputChanged);
  }

  List<String> get _availableBranches {
    final names = widget.localBranchNames.toSet().toList()..sort();
    return names;
  }

  GitFlowStartPlan? get _plan {
    final result = validateGitFlowStart(
      kind: _kind,
      name: _nameController.text,
      baseBranch: _baseBranch,
      existingBranches: _availableBranches,
      isAttachedHead: widget.isAttachedHead,
      isWorkingTreeClean: widget.isWorkingTreeClean,
      hasActiveOperation: widget.hasActiveOperation,
    );
    return result.plan;
  }

  String? get _validationError {
    final result = validateGitFlowStart(
      kind: _kind,
      name: _nameController.text,
      baseBranch: _baseBranch,
      existingBranches: _availableBranches,
      isAttachedHead: widget.isAttachedHead,
      isWorkingTreeClean: widget.isWorkingTreeClean,
      hasActiveOperation: widget.hasActiveOperation,
    );
    return result.error;
  }

  void _onInputChanged() => setState(() {});

  @override
  void dispose() {
    _nameController
      ..removeListener(_onInputChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    final error = _validationError;
    final availableBranches = _availableBranches;
    return AlertDialog(
      title: const Text('开始 Git Flow 分支'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<GitFlowBranchKind>(
                initialValue: _kind,
                decoration: const InputDecoration(labelText: '分支类型'),
                items: const [
                  DropdownMenuItem(
                    value: GitFlowBranchKind.feature,
                    child: Text('Feature（功能开发）'),
                  ),
                  DropdownMenuItem(
                    value: GitFlowBranchKind.release,
                    child: Text('Release（发布准备）'),
                  ),
                  DropdownMenuItem(
                    value: GitFlowBranchKind.hotfix,
                    child: Text('Hotfix（生产修复）'),
                  ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => _kind = value);
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: availableBranches.contains(_baseBranch)
                    ? _baseBranch
                    : null,
                decoration: const InputDecoration(labelText: '起点本地分支'),
                items: [
                  for (final branch in availableBranches)
                    DropdownMenuItem(value: branch, child: Text(branch)),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => _baseBranch = value);
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _nameController,
                decoration: InputDecoration(
                  labelText: _kind == GitFlowBranchKind.feature
                      ? 'Feature 名称'
                      : '版本号（SemVer）',
                  hintText: _kind == GitFlowBranchKind.feature
                      ? '例如 billing/invoice'
                      : '例如 1.2.3 或 1.2.3-rc.1',
                ),
                autofocus: true,
              ),
              const SizedBox(height: 16),
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '执行预览',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        plan == null
                            ? (error ?? '请输入有效的 Git-flow 参数。')
                            : '创建并切换到 ${plan.branchName}\n起点：${plan.baseBranch}',
                        style: TextStyle(
                          color: plan == null
                              ? Theme.of(context).colorScheme.error
                              : null,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text('只修改本地分支引用；不会推送、删除分支或修改 upstream。'),
                    ],
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
          child: const Text('创建并切换'),
        ),
      ],
    );
  }
}
