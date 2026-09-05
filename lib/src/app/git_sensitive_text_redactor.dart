/// Redacts credential-shaped text before it reaches user-visible errors,
/// operation records or technical diagnostics.
///
/// This is a defensive last line of protection. AskPass answers are never
/// passed to this function because application code must not log or retain
/// them in the first place.
/// 中文：脱敏敏感内容。
/// English: Redacts sensitive content.
String redactGitSensitiveText(String text) {
  final credentialUserInfo = RegExp(
    r'([a-z][a-z0-9+.-]*://)([^/\s@]+)@',
    caseSensitive: false,
  );
  final tokenQueryParameter = RegExp(
    r'([?&](?:access_token|refresh_token|oauth_token|token|password|auth|secret|client_secret|api[_-]?key|x-amz-(?:credential|signature|security-token))=)[^&#\s]+',
    caseSensitive: false,
  );
  final urlFragment = RegExp(
    r'([a-z][a-z0-9+.-]*://[^\s#]*)(#[^\s]*)',
    caseSensitive: false,
  );
  final scpCredential = RegExp(r'\b([^/@\s:]+:)[^/@\s]+(@[^/:\s]+:)');
  final sensitiveHeader = RegExp(
    r'^([ \t]*(?:authorization|proxy-authorization|private-token|x-auth-token|x-access-token|x-api-key|cookie|set-cookie)[ \t]*:[ \t]*)[^\r\n]*$',
    caseSensitive: false,
    multiLine: true,
  );
  return text
      .replaceAllMapped(credentialUserInfo, (match) => '${match[1]}***@')
      .replaceAllMapped(scpCredential, (match) => '${match[1]}***${match[2]}')
      .replaceAllMapped(tokenQueryParameter, (match) => '${match[1]}***')
      .replaceAllMapped(urlFragment, (match) => '${match[1]}#***')
      .replaceAllMapped(sensitiveHeader, (match) => '${match[1]}***');
}
