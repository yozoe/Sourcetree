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
        canStopTracking: false,
        canApplyPatch: true,
      );

      expect(receivedCall?.method, 'setWorkspaceMenuState');
      expect(receivedCall?.arguments, <String, bool>{
        'canStopTracking': false,
        'canApplyPatch': true,
      });
    },
  );
}
