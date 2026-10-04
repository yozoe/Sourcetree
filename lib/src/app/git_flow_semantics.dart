/// Product-level validation for the delivered Git-flow v1 Start/Finish slice.
/// 中文：已交付 Git-flow v1 Start/Finish 切片的产品级校验；只生成安全计划，不执行 Git 写操作。
library;

/// The three local branch families supported by the frozen Git-flow v1
/// contract.
/// 中文：已冻结的 Git-flow v1 契约支持的三类本地分支。
enum GitFlowBranchKind { feature, release, hotfix }

/// A validated, side-effect-free Git-flow start plan.
/// 中文：经过校验且不产生副作用的 Git-flow Start 计划。
final class GitFlowStartPlan {
  const GitFlowStartPlan({
    required this.kind,
    required this.name,
    required this.branchName,
    required this.baseBranch,
    required this.version,
  });

  /// The requested Git-flow branch family.
  /// 中文：请求创建的 Git-flow 分支类型。
  final GitFlowBranchKind kind;

  /// The normalized user input used after the fixed branch prefix.
  /// 中文：固定分支前缀之后使用的规范化用户输入。
  final String name;

  /// The complete local branch name to create.
  /// 中文：待创建的完整本地分支名。
  final String branchName;

  /// The explicit local branch selected as the start point.
  /// 中文：用户明确选择的起点本地分支。
  final String baseBranch;

  /// The validated release/hotfix version, or null for a feature branch.
  /// 中文：已校验的 release/hotfix 版本；feature 分支为 null。
  final String? version;
}

/// Result of executing a validated Git-flow Start plan.
/// 中文：执行已校验 Git-flow Start 计划后的分阶段结果。
final class GitFlowStartExecutionResult {
  const GitFlowStartExecutionResult({
    required this.branchCreated,
    required this.checkedOut,
    required this.message,
  });

  /// Whether the local branch ref was created successfully.
  /// 中文：本地分支引用是否已经成功创建。
  final bool branchCreated;

  /// Whether the work tree switched to the newly created branch.
  /// 中文：工作区是否已切换到新创建的分支。
  final bool checkedOut;

  /// User-facing result including partial-success information.
  /// 中文：包含部分成功信息的用户可见结果。
  final String message;

  bool get succeeded => branchCreated && checkedOut;
}

/// A validated, side-effect-free single-target Git-flow Finish plan.
/// 中文：经过校验且不产生副作用的单目标 Git-flow Finish 计划。
final class GitFlowFinishPlan {
  const GitFlowFinishPlan({
    required this.sourceBranch,
    required this.targetBranch,
    required this.kind,
  });

  /// The current Git-flow branch that will be merged.
  /// 中文：将被合并的当前 Git-flow 来源分支。
  final String sourceBranch;

  /// The explicit local branch that receives the merge.
  /// 中文：用户明确选择的本地目标分支。
  final String targetBranch;

  /// The Git-flow branch family inferred from [sourceBranch].
  /// 中文：从 [sourceBranch] 推断出的 Git-flow 分支类型。
  final GitFlowBranchKind kind;

  /// Finish uses one explicit non-fast-forward merge and never pushes or
  /// deletes references automatically.
  /// 中文：Finish 只执行一次明确的非快进合并，不自动推送或删除引用。
  String get mergeStrategy => 'merge --no-edit --no-ff';
}

/// Result of executing a validated Git-flow Finish plan.
/// 中文：执行已校验 Git-flow Finish 计划后的结果。
final class GitFlowFinishExecutionResult {
  const GitFlowFinishExecutionResult({
    required this.merged,
    required this.message,
  });

  /// Whether Git completed the requested merge and refresh was trustworthy.
  /// 中文：Git 是否完成合并且刷新结果可信。
  final bool merged;

  /// User-facing result including conflict or uncertain-state information.
  /// 中文：包含冲突或结果不确定信息的用户可见结果。
  final String message;
}

/// Infers the supported Git-flow family from a local branch name.
/// 中文：从本地分支名推断受支持的 Git-flow 类型；不符合规范时返回 null。
GitFlowBranchKind? gitFlowBranchKindForName(String branchName) {
  final normalized = branchName.trim();
  for (final kind in GitFlowBranchKind.values) {
    final prefix = switch (kind) {
      GitFlowBranchKind.feature => 'feature/',
      GitFlowBranchKind.release => 'release/',
      GitFlowBranchKind.hotfix => 'hotfix/',
    };
    if (!normalized.startsWith(prefix)) continue;
    final suffix = normalized.substring(prefix.length);
    if (kind == GitFlowBranchKind.feature && _isBranchSuffix(suffix)) {
      return kind;
    }
    if (kind != GitFlowBranchKind.feature && _isSemanticVersion(suffix)) {
      return kind;
    }
  }
  return null;
}

/// Orders local branches for the Git-flow Finish target picker.
/// 中文：为 Git-flow Finish 目标选择器排序本地分支；优先展示惯用的集成分支，
/// 但仍保留所有已加载的本地分支供用户明确选择。
///
/// Feature branches conventionally finish into `develop`, while release and
/// hotfix branches conventionally finish into `main`/`master`. This is only a
/// picker preference and does not narrow the validated target set.
List<String> orderGitFlowFinishTargets({
  required String? sourceBranch,
  required Iterable<String> localBranchNames,
}) {
  final source = sourceBranch?.trim();
  final sourceKind = source == null ? null : gitFlowBranchKindForName(source);
  final preferred = switch (sourceKind) {
    GitFlowBranchKind.feature => const ['develop', 'main', 'master'],
    GitFlowBranchKind.release ||
    GitFlowBranchKind.hotfix => const ['main', 'master', 'develop'],
    null => const ['develop', 'main', 'master'],
  };
  final names = localBranchNames
      .map((name) => name.trim())
      .where((name) => name.isNotEmpty && name != source)
      .toSet()
      .toList();
  names.sort((left, right) {
    final leftIndex = preferred.indexOf(left);
    final rightIndex = preferred.indexOf(right);
    final leftRank = leftIndex < 0 ? preferred.length : leftIndex;
    final rightRank = rightIndex < 0 ? preferred.length : rightIndex;
    final rankComparison = leftRank.compareTo(rightRank);
    return rankComparison != 0 ? rankComparison : left.compareTo(right);
  });
  return names;
}

/// Validates a single-target local Git-flow Finish request.
/// 中文：校验单目标本地 Git-flow Finish 请求，不执行 Git 写操作。
({GitFlowFinishPlan? plan, String? error}) validateGitFlowFinish({
  required String sourceBranch,
  required String targetBranch,
  required Iterable<String> existingBranches,
  required bool isAttachedHead,
  required bool isWorkingTreeClean,
  required bool hasActiveOperation,
}) {
  if (!isAttachedHead) {
    return (plan: null, error: 'Git-flow Finish 需要附着在本地分支上。');
  }
  if (!isWorkingTreeClean) {
    return (plan: null, error: 'Git-flow Finish 需要干净的工作区。');
  }
  if (hasActiveOperation) {
    return (plan: null, error: '当前存在未完成的 Git 操作，暂时不能完成 Git-flow 分支。');
  }
  final source = sourceBranch.trim();
  final target = targetBranch.trim();
  final kind = gitFlowBranchKindForName(source);
  if (kind == null) {
    return (
      plan: null,
      error: '当前分支不是受支持的 Git-flow feature、release 或 hotfix 分支。',
    );
  }
  if (!_isLocalBranchName(target)) {
    return (plan: null, error: '请选择有效的本地目标分支。');
  }
  if (source == target) {
    return (plan: null, error: 'Git-flow Finish 的来源和目标分支不能相同。');
  }
  final existing = existingBranches.map((branch) => branch.trim()).toSet();
  if (!existing.contains(source)) {
    return (plan: null, error: '当前 Git-flow 分支不存在或未加载。');
  }
  if (!existing.contains(target)) {
    return (plan: null, error: '目标分支 $target 不存在或未加载。');
  }
  return (
    plan: GitFlowFinishPlan(
      sourceBranch: source,
      targetBranch: target,
      kind: kind,
    ),
    error: null,
  );
}

/// Returns a validated local Git-flow Start plan, or a user-facing error.
/// 中文：校验 Git-flow Start 请求并返回计划或可直接展示的错误信息；不会执行 Git。
({GitFlowStartPlan? plan, String? error}) validateGitFlowStart({
  required GitFlowBranchKind kind,
  required String name,
  required String baseBranch,
  required Iterable<String> existingBranches,
  required bool isAttachedHead,
  required bool isWorkingTreeClean,
  required bool hasActiveOperation,
}) {
  if (!isAttachedHead) {
    return (plan: null, error: 'Git-flow Start 需要附着在本地分支上。');
  }
  if (!isWorkingTreeClean) {
    return (plan: null, error: 'Git-flow Start 需要干净的工作区。');
  }
  if (hasActiveOperation) {
    return (plan: null, error: '当前存在未完成的 Git 操作，暂时不能开始 Git-flow 分支。');
  }

  final normalizedBase = baseBranch.trim();
  if (!_isLocalBranchName(normalizedBase)) {
    return (plan: null, error: '请选择有效的本地起点分支。');
  }
  final existing = existingBranches.map((branch) => branch.trim()).toSet();
  if (!existing.contains(normalizedBase)) {
    return (plan: null, error: '起点分支 $normalizedBase 不存在或未加载。');
  }

  final normalizedName = name.trim();
  String? version;
  String suffix;
  switch (kind) {
    case GitFlowBranchKind.feature:
      if (!_isBranchSuffix(normalizedName)) {
        return (plan: null, error: 'Feature 名称不能为空，且不能包含不安全的 Git 引用字符。');
      }
      suffix = normalizedName;
    case GitFlowBranchKind.release:
    case GitFlowBranchKind.hotfix:
      if (!_isSemanticVersion(normalizedName)) {
        return (
          plan: null,
          error: 'Release 和 hotfix 必须使用完整的 SemVer 版本号，例如 1.2.3。',
        );
      }
      version = normalizedName;
      suffix = normalizedName;
  }

  final prefix = switch (kind) {
    GitFlowBranchKind.feature => 'feature',
    GitFlowBranchKind.release => 'release',
    GitFlowBranchKind.hotfix => 'hotfix',
  };
  final branchName = '$prefix/$suffix';
  if (existing.contains(branchName)) {
    return (plan: null, error: '分支 $branchName 已存在。');
  }

  return (
    plan: GitFlowStartPlan(
      kind: kind,
      name: normalizedName,
      branchName: branchName,
      baseBranch: normalizedBase,
      version: version,
    ),
    error: null,
  );
}

bool _isLocalBranchName(String value) =>
    value.isNotEmpty && _isSafeRefPart(value) && !value.startsWith('refs/');

bool _isBranchSuffix(String value) =>
    value.isNotEmpty &&
    _isSafeRefPart(value) &&
    !value.startsWith('/') &&
    !value.endsWith('/');

bool _isSafeRefPart(String value) {
  if (value.contains(RegExp(r'[\u0000-\u001f\u007f ~^:?*\\\[]'))) {
    return false;
  }
  if (value.contains('..') || value.contains('@{')) {
    return false;
  }
  if (value.contains('//') || value.contains('/./') || value.contains('/../')) {
    return false;
  }
  if (value.split('/').any((part) => part.endsWith('.lock'))) {
    return false;
  }
  if (value.startsWith('.') || value.endsWith('.') || value.endsWith('/')) {
    return false;
  }
  return true;
}

final _semanticVersionPattern = RegExp(
  r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)'
  r'(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?'
  r'(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
);

bool _isSemanticVersion(String value) =>
    _semanticVersionPattern.hasMatch(value);
