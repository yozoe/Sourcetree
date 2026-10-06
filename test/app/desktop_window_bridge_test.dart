import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/app/desktop_window_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.yeknom.git_desktop/window');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('keeps routable and reserved workspace action IDs disjoint', () {
    expect(
      DesktopWorkspaceActionId.routable.intersection(
        DesktopWorkspaceActionId.reserved,
      ),
      isEmpty,
    );
    expect(DesktopWorkspaceActionId.reserved, isEmpty);
    expect(
      DesktopWorkspaceActionId.routable,
      containsAll(<String>[
        DesktopWorkspaceActionId.fetch,
        DesktopWorkspaceActionId.pull,
        DesktopWorkspaceActionId.stash,
      ]),
    );
  });

  test(
    'sends mutation capability snapshots to the native workspace menu',
    () async {
      MethodCall? receivedCall;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            receivedCall = call;
            return null;
          });

      await DesktopWindowBridge.setWorkspaceMenuState(
        generation: 42,
        canAddRemote: true,
        canStopTracking: false,
        canApplyPatch: true,
        canCheckout: true,
        canAbortOperation: true,
        canMarkConflictResolved: true,
        canCommitAll: true,
        canCommitSelected: true,
        canHideChanges: false,
        canRefreshRemoteStatus: false,
        canCommit: true,
        canContinueOperation: false,
        canExternalDiffSelected: true,
        canSkipOperation: false,
        canCopySelected: true,
        canMoveSelected: true,
        canUseConflictStage2: true,
        canUseConflictStage3: false,
        canFetch: true,
        canInteractiveRebase: true,
        canIgnoreSelected: true,
        canMerge: true,
        canPull: true,
        canPush: true,
        canReviewSelected: true,
        canRemoveSelected: true,
        canResetRepository: true,
        canResetSelected: true,
        canResetToSelectedCommit: false,
        canStageSelected: true,
        canCreateBranch: true,
        canStartGitFlow: true,
        canStash: true,
        canTag: true,
        canUnstageSelected: false,
        canViewSelectedFileHistory: true,
        activeRepositoryOperation: 'merge',
        conflictStage2Label: '当前分支版本 · main',
        conflictStage3Label: '合并来源版本',
        repositoryRootPath: '/tmp/example-repository',
        selectedFilePaths: const ['/tmp/example-repository/lib/example.dart'],
        hasFileSelection: true,
        customActions: const [
          <String, Object?>{
            'id': 'format',
            'displayName': '格式化',
            'requiresFilePath': true,
            'isEnabled': true,
          },
        ],
      );

      expect(receivedCall?.method, 'setWorkspaceMenuState');
      expect(receivedCall?.arguments, <String, Object?>{
        'generation': 42,
        'canAddRemote': true,
        'canStopTracking': false,
        'canApplyPatch': true,
        'canCheckout': true,
        'canAbortOperation': true,
        'canMarkConflictResolved': true,
        'canCommitAll': true,
        'canCommitSelected': true,
        'canHideChanges': false,
        'canRefreshRemoteStatus': false,
        'canUpdateFromUpstream': false,
        'canCommit': true,
        'canContinueOperation': false,
        'canExternalDiffSelected': true,
        'canSkipOperation': false,
        'canCopySelected': true,
        'canMoveSelected': true,
        'canUseConflictStage2': true,
        'canUseConflictStage3': false,
        'canFetch': true,
        'canInteractiveRebase': true,
        'canIgnoreSelected': true,
        'canMerge': true,
        'canPull': true,
        'canPush': true,
        'canReviewSelected': true,
        'canRemoveSelected': true,
        'canResetRepository': true,
        'canResetSelected': true,
        'canResetToSelectedCommit': false,
        'canStageSelected': true,
        'canCreateBranch': true,
        'canStartGitFlow': true,
        'canStash': true,
        'canTag': true,
        'canUnstageSelected': false,
        'canViewSelectedFileHistory': true,
        'activeRepositoryOperation': 'merge',
        'conflictStage2Label': '当前分支版本 · main',
        'conflictStage3Label': '合并来源版本',
        'repositoryRootPath': '/tmp/example-repository',
        'selectedFilePaths': <String>[
          '/tmp/example-repository/lib/example.dart',
        ],
        'hasFileSelection': true,
        'customActions': const [
          <String, Object?>{
            'id': 'format',
            'displayName': '格式化',
            'requiresFilePath': true,
            'isEnabled': true,
          },
        ],
      });
    },
  );

  test('sends refreshes without re-registering a workspace window', () async {
    MethodCall? receivedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          receivedCall = call;
          return null;
        });

    await DesktopWindowBridge.repositoryStatusUpdated(
      '/tmp/example-repository',
    );

    expect(receivedCall?.method, 'repositoryStatusUpdated');
    expect(receivedCall?.arguments, <String, Object>{
      'repositoryPath': '/tmp/example-repository',
    });
  });

  test('requests a native read-only action for explicit files', () async {
    MethodCall? receivedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          receivedCall = call;
          return null;
        });

    await DesktopWindowBridge.performFileAction(
      action: 'quickLook',
      repositoryRootPath: '/tmp/example-repository',
      filePaths: const [
        '/tmp/example-repository/lib/example.dart',
        '/tmp/example-repository/README.md',
      ],
    );

    expect(receivedCall?.method, 'performFileAction');
    expect(receivedCall?.arguments, <String, Object>{
      'action': 'quickLook',
      'repositoryRootPath': '/tmp/example-repository',
      'filePaths': <String>[
        '/tmp/example-repository/lib/example.dart',
        '/tmp/example-repository/README.md',
      ],
    });
  });

  test('sends binary historical content to its owning workspace', () async {
    MethodCall? receivedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          receivedCall = call;
          return null;
        });

    await DesktopWindowBridge.openHistoricalFile(
      repositoryRootPath: '/tmp/example-repository',
      suggestedFileName: 'snapshot.bin',
      bytes: Uint8List.fromList([0, 255, 10]),
    );

    expect(receivedCall?.method, 'openHistoricalFile');
    expect(receivedCall?.arguments, <String, Object>{
      'repositoryRootPath': '/tmp/example-repository',
      'suggestedFileName': 'snapshot.bin',
      'bytes': Uint8List.fromList([0, 255, 10]),
    });
  });

  test('sends historical comparison bytes to its owning workspace', () async {
    MethodCall? receivedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          receivedCall = call;
          return null;
        });

    await DesktopWindowBridge.openHistoricalDiff(
      repositoryRootPath: '/tmp/example-repository',
      suggestedFileName: 'snapshot.bin',
      beforeBytes: Uint8List.fromList([0, 1]),
      afterBytes: Uint8List.fromList([0, 2]),
    );

    expect(receivedCall?.method, 'openHistoricalDiff');
    expect(receivedCall?.arguments, <String, Object>{
      'repositoryRootPath': '/tmp/example-repository',
      'suggestedFileName': 'snapshot.bin',
      'beforeBytes': Uint8List.fromList([0, 1]),
      'afterBytes': Uint8List.fromList([0, 2]),
    });
  });
}
