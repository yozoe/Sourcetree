import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/app/git_flow_semantics.dart';

void main() {
  test(
    'validates one-target Git-flow Finish for supported branch families',
    () {
      final feature = validateGitFlowFinish(
        sourceBranch: 'feature/invoice',
        targetBranch: 'develop',
        existingBranches: const ['feature/invoice', 'develop'],
        isAttachedHead: true,
        isWorkingTreeClean: true,
        hasActiveOperation: false,
      );
      expect(feature.error, isNull);
      expect(feature.plan?.kind, GitFlowBranchKind.feature);
      expect(feature.plan?.mergeStrategy, 'merge --no-edit --no-ff');

      for (final name in const ['release/1.2.3', 'hotfix/2.0.0-rc.1']) {
        final result = validateGitFlowFinish(
          sourceBranch: name,
          targetBranch: 'main',
          existingBranches: [name, 'main'],
          isAttachedHead: true,
          isWorkingTreeClean: true,
          hasActiveOperation: false,
        );
        expect(result.plan, isNotNull);
      }
    },
  );

  test('rejects unsafe or unsupported Git-flow Finish requests', () {
    final cases = <({String source, String target, String message})>[
      (source: 'bugfix/one', target: 'main', message: '受支持的 Git-flow'),
      (source: 'feature/one', target: 'feature/one', message: '不能相同'),
      (source: 'release/1.2', target: 'main', message: '受支持的 Git-flow'),
    ];
    for (final item in cases) {
      final result = validateGitFlowFinish(
        sourceBranch: item.source,
        targetBranch: item.target,
        existingBranches: [item.source, item.target],
        isAttachedHead: true,
        isWorkingTreeClean: true,
        hasActiveOperation: false,
      );
      expect(result.plan, isNull);
      expect(result.error, contains(item.message));
    }
  });

  test('builds a feature start plan without performing a Git write', () {
    final result = validateGitFlowStart(
      kind: GitFlowBranchKind.feature,
      name: 'billing/invoice',
      baseBranch: 'develop',
      existingBranches: const ['main', 'develop'],
      isAttachedHead: true,
      isWorkingTreeClean: true,
      hasActiveOperation: false,
    );

    expect(result.error, isNull);
    expect(result.plan?.branchName, 'feature/billing/invoice');
    expect(result.plan?.baseBranch, 'develop');
    expect(result.plan?.version, isNull);
  });

  test('requires SemVer for release and hotfix starts', () {
    final release = validateGitFlowStart(
      kind: GitFlowBranchKind.release,
      name: '1.2.3-rc.1',
      baseBranch: 'develop',
      existingBranches: const ['develop'],
      isAttachedHead: true,
      isWorkingTreeClean: true,
      hasActiveOperation: false,
    );
    final hotfix = validateGitFlowStart(
      kind: GitFlowBranchKind.hotfix,
      name: '1.2',
      baseBranch: 'main',
      existingBranches: const ['main'],
      isAttachedHead: true,
      isWorkingTreeClean: true,
      hasActiveOperation: false,
    );

    expect(release.error, isNull);
    expect(release.plan?.branchName, 'release/1.2.3-rc.1');
    expect(hotfix.plan, isNull);
    expect(hotfix.error, contains('SemVer'));
  });

  test('rejects unsafe or duplicate branch names', () {
    final unsafe = validateGitFlowStart(
      kind: GitFlowBranchKind.feature,
      name: '../secrets',
      baseBranch: 'develop',
      existingBranches: const ['develop'],
      isAttachedHead: true,
      isWorkingTreeClean: true,
      hasActiveOperation: false,
    );
    final duplicate = validateGitFlowStart(
      kind: GitFlowBranchKind.feature,
      name: 'billing',
      baseBranch: 'develop',
      existingBranches: const ['develop', 'feature/billing'],
      isAttachedHead: true,
      isWorkingTreeClean: true,
      hasActiveOperation: false,
    );

    expect(unsafe.plan, isNull);
    expect(unsafe.error, contains('不安全'));
    expect(duplicate.plan, isNull);
    expect(duplicate.error, contains('已存在'));
  });

  test('orders Finish targets by conventional integration branch', () {
    expect(
      orderGitFlowFinishTargets(
        sourceBranch: 'feature/invoice',
        localBranchNames: const [
          'feature/other',
          'main',
          'develop',
          'release/1.2.3',
          'master',
        ],
      ),
      const ['develop', 'main', 'master', 'feature/other', 'release/1.2.3'],
    );
    expect(
      orderGitFlowFinishTargets(
        sourceBranch: 'hotfix/1.2.3',
        localBranchNames: const ['develop', 'feature/other', 'main'],
      ),
      const ['main', 'develop', 'feature/other'],
    );
  });

  test('enforces attached, clean, and idle preconditions', () {
    for (final flags in <({bool attached, bool clean, bool active})>[
      (attached: false, clean: true, active: false),
      (attached: true, clean: false, active: false),
      (attached: true, clean: true, active: true),
    ]) {
      final result = validateGitFlowStart(
        kind: GitFlowBranchKind.feature,
        name: 'demo',
        baseBranch: 'develop',
        existingBranches: const ['develop'],
        isAttachedHead: flags.attached,
        isWorkingTreeClean: flags.clean,
        hasActiveOperation: flags.active,
      );
      expect(result.plan, isNull);
      expect(result.error, isNotNull);
    }
  });

  test('validates ordered batch Finish with safe cleanup and release tag', () {
    final result = validateGitFlowBatchFinish(
      sourceBranches: const ['feature/one', 'release/1.2.3'],
      targetBranch: 'main',
      existingBranches: const ['main', 'feature/one', 'release/1.2.3'],
      isAttachedHead: true,
      isWorkingTreeClean: true,
      hasActiveOperation: false,
      deleteSourceBranches: true,
      releaseTag: 'v1.2.3',
    );

    expect(result.error, isNull);
    expect(result.plan?.sourceBranches, const ['feature/one', 'release/1.2.3']);
    expect(result.plan?.targetBranch, 'main');
    expect(result.plan?.deleteSourceBranches, isTrue);
    expect(result.plan?.releaseTag, 'v1.2.3');
  });

  test('rejects batch release tags without a release or hotfix source', () {
    final result = validateGitFlowBatchFinish(
      sourceBranches: const ['feature/one'],
      targetBranch: 'main',
      existingBranches: const ['main', 'feature/one'],
      isAttachedHead: true,
      isWorkingTreeClean: true,
      hasActiveOperation: false,
      releaseTag: 'v1.2.3',
    );

    expect(result.plan, isNull);
    expect(result.error, contains('release 或 hotfix'));
  });

  test(
    'does not report batch Finish success when the requested tag failed',
    () {
      const result = GitFlowBatchFinishExecutionResult(
        items: [
          GitFlowBatchFinishItemResult(
            sourceBranch: 'release/1.2.3',
            merged: true,
            deleted: false,
          ),
        ],
        targetCheckedOut: true,
        tagCreated: false,
        cancelled: false,
        message: '标签创建失败',
      );

      expect(result.succeeded, isFalse);
    },
  );
}
