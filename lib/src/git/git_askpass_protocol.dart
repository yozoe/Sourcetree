import 'dart:convert';

/// The non-secret portion of a one-time AskPass IPC request.
///
/// Secrets deliberately never appear in this value type. They are accepted by
/// a future UI session only after the helper has authenticated with its nonce.
///
/// 中文：一次性 AskPass IPC 请求中的非机密部分。该类型绝不保存密码等机密，
/// 只有 helper 通过 nonce 认证后，后续 UI 会话才会接收答案。
final class GitAskPassRequest {
  const GitAskPassRequest({
    required this.nonce,
    required this.prompt,
    required this.kind,
  });

  static const int maxPromptLength = 8 * 1024;

  final String nonce;
  final String prompt;
  final GitAskPassPromptKind kind;

  /// Decodes and validates a helper request before it can reach the UI.
  /// 中文：解码输入内容。
  /// English: Decodes the input content.
  static GitAskPassRequest decode(String payload) {
    if (payload.length > maxPromptLength * 2) {
      throw const FormatException('AskPass request is too large.');
    }
    final decoded = jsonDecode(payload);
    if (decoded is! Map<Object?, Object?>) {
      throw const FormatException('AskPass request must be an object.');
    }
    if (decoded.length != 2 ||
        !decoded.containsKey('nonce') ||
        !decoded.containsKey('prompt')) {
      throw const FormatException('AskPass request has unexpected fields.');
    }
    final nonce = decoded['nonce'];
    final prompt = decoded['prompt'];
    if (nonce is! String ||
        !RegExp(r'^[a-f0-9]{64}$', caseSensitive: false).hasMatch(nonce)) {
      throw const FormatException('AskPass nonce is invalid.');
    }
    if (prompt is! String ||
        prompt.isEmpty ||
        prompt.length > maxPromptLength) {
      throw const FormatException('AskPass prompt is invalid.');
    }
    return GitAskPassRequest(
      nonce: nonce,
      prompt: prompt,
      kind: _classifyPrompt(prompt),
    );
  }

  /// 中文：对输入结果进行分类。
  /// English: Classifies the input result.
  static GitAskPassPromptKind _classifyPrompt(String prompt) {
    final normalized = prompt.toLowerCase();
    if (normalized.contains('username')) return GitAskPassPromptKind.username;
    if (normalized.contains('passphrase')) {
      return GitAskPassPromptKind.passphrase;
    }
    if (normalized.contains('password')) return GitAskPassPromptKind.password;
    return GitAskPassPromptKind.unknown;
  }
}

enum GitAskPassPromptKind { username, password, passphrase, unknown }
