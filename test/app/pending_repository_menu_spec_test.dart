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

  test('keeps unresolved repository menu semantics visibly pending', () {
    final xib = File('macos/Runner/Base.lproj/MainMenu.xib').readAsStringSync();

    const pendingItems = <String, String>{
      'GDA-repository-hide-changes': '隐藏变更…（待实现）',
      'GDA-repository-refresh-remote': '刷新远程仓库状态（待实现）',
      'GDA-repository-update': '更新（待实现）',
      'GDA-repository-lfs': 'Git LFS（待实现）',
    };

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
            'repositoryFeaturePendingFromMenu: route until its semantics are frozen.',
      );
    }
  });
}
