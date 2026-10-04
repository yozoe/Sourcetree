import 'package:flutter/services.dart';

/// Abstract storage for the explicit GitHub.com access token.
///
/// 中文：GitHub.com 显式访问令牌的安全存储接口；不从 Git 配置、remote 或 AskPass
/// 推断令牌。
abstract interface class GitHubAccessTokenStore {
  Future<String?> read();

  Future<void> write(String token);

  Future<void> delete();
}

/// macOS Keychain-backed GitHub token store.
///
/// 中文：由 macOS Keychain 支持的 GitHub 令牌存储；令牌不会写入普通偏好、Git 配置
/// 或日志。
final class MacOSGitHubAccessTokenStore implements GitHubAccessTokenStore {
  MacOSGitHubAccessTokenStore({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'com.yeknom.git_desktop/github_auth';
  final MethodChannel _channel;

  @override
  Future<String?> read() => _channel.invokeMethod<String>('readAccessToken');

  @override
  Future<void> write(String token) async {
    _validateToken(token);
    await _channel.invokeMethod<void>('writeAccessToken', <String, Object?>{
      'token': token,
    });
  }

  @override
  Future<void> delete() => _channel.invokeMethod<void>('deleteAccessToken');
}

void _validateToken(String token) {
  if (token.isEmpty ||
      token != token.trim() ||
      RegExp(r'[\x00-\x1F\x7F]').hasMatch(token)) {
    throw const FormatException('The GitHub access token is invalid.');
  }
}
