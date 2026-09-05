import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/app/git_sensitive_text_redactor.dart';

void main() {
  test('redacts credential-shaped URLs, query values and auth headers', () {
    const source = '''
fatal: https://octavia:top-secret@example.test/private
remote: https://token-only@example.test/private
request: https://example.test/api?access_token=query-secret&api_key=api-secret
Authorization: Bearer header-secret
Private-Token: private-secret
X-Access-Token: access-secret
''';

    final redacted = redactGitSensitiveText(source);

    expect(redacted, contains('https://***@example.test/private'));
    expect(redacted, contains('access_token=***'));
    expect(redacted, contains('api_key=***'));
    expect(redacted, contains('Authorization: ***'));
    expect(redacted, contains('Private-Token: ***'));
    expect(redacted, contains('X-Access-Token: ***'));
    expect(redacted, isNot(contains('top-secret')));
    expect(redacted, isNot(contains('token-only')));
    expect(redacted, isNot(contains('query-secret')));
    expect(redacted, isNot(contains('api-secret')));
    expect(redacted, isNot(contains('header-secret')));
    expect(redacted, isNot(contains('private-secret')));
    expect(redacted, isNot(contains('access-secret')));
  });

  test('redacts SCP credentials, OAuth, AWS signatures and fragments', () {
    const source = '''
fatal: user:scp-secret@example.test:owner/repository.git
request: https://example.test/api?refresh_token=refresh-secret&oauth_token=oauth-secret
signed: https://example.test/object?X-Amz-Credential=credential-secret&X-Amz-Signature=signature-secret&X-Amz-Security-Token=security-secret
fragment: ssh://git@example.test/repository.git#fragment-secret
X-Api-Key: header-api-secret
Cookie: session=cookie-secret
''';

    final redacted = redactGitSensitiveText(source);

    expect(redacted, contains('user:***@example.test:owner/repository.git'));
    expect(redacted, contains('refresh_token=***'));
    expect(redacted, contains('oauth_token=***'));
    expect(redacted, contains('X-Amz-Credential=***'));
    expect(redacted, contains('X-Amz-Signature=***'));
    expect(redacted, contains('X-Amz-Security-Token=***'));
    expect(redacted, contains('repository.git#***'));
    expect(redacted, contains('X-Api-Key: ***'));
    expect(redacted, contains('Cookie: ***'));
    for (final secret in const [
      'scp-secret',
      'refresh-secret',
      'oauth-secret',
      'credential-secret',
      'signature-secret',
      'security-secret',
      'fragment-secret',
      'header-api-secret',
      'cookie-secret',
    ]) {
      expect(redacted, isNot(contains(secret)));
    }
  });
}
