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
    r'([?&](?:access_token|token|password|client_secret|api[_-]?key)=)[^&\s]+',
    caseSensitive: false,
  );
  final sensitiveHeader = RegExp(
    r'^([ \t]*(?:authorization|proxy-authorization|private-token|x-auth-token|x-access-token)[ \t]*:[ \t]*)[^\r\n]*$',
    caseSensitive: false,
    multiLine: true,
  );
  return text
      .replaceAllMapped(credentialUserInfo, (match) => '${match[1]}***@')
      .replaceAllMapped(tokenQueryParameter, (match) => '${match[1]}***')
      .replaceAllMapped(sensitiveHeader, (match) => '${match[1]}***');
}
