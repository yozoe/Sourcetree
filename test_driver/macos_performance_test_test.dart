import 'package:integration_test/integration_test_driver.dart';

/// Bridges Flutter Drive's host process to the macOS performance integration test.
/// 中文：将 Flutter Drive 的宿主进程桥接到 macOS 性能集成测试；测试逻辑仍位于
/// `integration_test/macos_performance_test.dart`，这里不创建应用或读取凭据。
Future<void> main() async {
  await integrationDriver();
}
