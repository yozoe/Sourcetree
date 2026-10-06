import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('external Diff action is delivered instead of pending placeholder', () {
    final xib = File('macos/Runner/Base.lproj/MainMenu.xib').readAsStringSync();
    expect(xib, contains('title="外部差异比对" id="GDA-action-external-diff"'));
    expect(xib, contains('<action selector="externalDiffSelectedFromMenu:"'));
    expect(xib, isNot(contains('title="外部差异比对（待实现）"')));
  });

  test('Git-flow Start and Finish action share a real native route', () {
    final xib = File('macos/Runner/Base.lproj/MainMenu.xib').readAsStringSync();
    expect(xib, contains('title="Git Flow…" id="GDA-repository-flow"'));
    expect(xib, contains('<action selector="startGitFlowRepositoryFromMenu:"'));
    expect(xib, isNot(contains('title="Git Flow（待实现）"')));
  });

  test('Pull Request is excluded instead of exposed as pending', () {
    final xib = File('macos/Runner/Base.lproj/MainMenu.xib').readAsStringSync();
    expect(xib, isNot(contains('GDA-repository-create-pr')));
    expect(xib, isNot(contains('创建拉取请求')));
  });

  test('keeps frozen but unimplemented repository actions visibly pending', () {
    final xib = File('macos/Runner/Base.lproj/MainMenu.xib').readAsStringSync();

    const pendingItems = <String, String>{'GDA-repository-lfs': 'Git LFS（待实现）'};

    for (final entry in pendingItems.entries) {
      final itemPattern = RegExp(
        '<menuItem title="${RegExp.escape(entry.value)}" '
        'id="${RegExp.escape(entry.key)}"[\\s\\S]*?'
        '<action selector="repositoryFeaturePendingFromMenu:"',
      );
      expect(
        itemPattern.hasMatch(xib),
        isTrue,
        reason:
            '${entry.key} must remain visibly pending and use the no-op '
            'repositoryFeaturePendingFromMenu: route until its frozen contract is implemented.',
      );
    }
  });

  test('routes hide changes through its delivered native action', () {
    final xib = File('macos/Runner/Base.lproj/MainMenu.xib').readAsStringSync();
    expect(xib, contains('title="隐藏变更…" id="GDA-repository-hide-changes"'));
    expect(xib, contains('<action selector="hideChangesFromMenu:"'));
    expect(xib, isNot(contains('title="隐藏变更…（待实现）"')));
  });

  test('routes remote status refresh through its delivered native action', () {
    final xib = File('macos/Runner/Base.lproj/MainMenu.xib').readAsStringSync();
    expect(
      xib,
      contains('title="刷新远程仓库状态…" id="GDA-repository-refresh-remote"'),
    );
    expect(xib, contains('<action selector="refreshRemoteStatusFromMenu:"'));
    expect(xib, isNot(contains('title="刷新远程仓库状态（待实现）"')));
  });

  test('routes upstream update through its delivered native action', () {
    final xib = File('macos/Runner/Base.lproj/MainMenu.xib').readAsStringSync();
    expect(xib, contains('title="更新…" id="GDA-repository-update"'));
    expect(xib, contains('<action selector="updateFromUpstreamFromMenu:"'));
    expect(xib, isNot(contains('title="更新（待实现）"')));
  });
}
