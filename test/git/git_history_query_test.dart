import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/git/git.dart';

void main() {
  test('parses author path and date conditions with remaining text', () {
    final query = GitHistoryQuery.parse(
      'author:"Alice Example" path:lib/ after:2026-01-01 '
      'before:2026-10-01 release notes',
    );

    expect(query.author, 'Alice Example');
    expect(query.path, 'lib/');
    expect(query.after, '2026-01-01');
    expect(query.before, '2026-10-01');
    expect(query.text, 'release notes');
    expect(query.gitLogArguments, contains('--since=2026-01-01'));
    expect(query.gitLogArguments, contains('--until=2026-10-01'));
    expect(query.gitLogArguments, contains('--grep=release notes'));
  });

  test('rejects unsafe paths, dates, controls, and incomplete quotes', () {
    expect(
      () => GitHistoryQuery.parse('path:../secret'),
      throwsA(isA<GitParseException>()),
    );
    expect(
      () => GitHistoryQuery.parse('after:not-a-date'),
      throwsA(isA<GitParseException>()),
    );
    expect(
      () => GitHistoryQuery.parse('after:2026-10-01 before:2026-01-01'),
      throwsA(isA<GitParseException>()),
    );
    expect(
      () => GitHistoryQuery.parse('author:"unterminated'),
      throwsA(isA<GitParseException>()),
    );
    expect(
      () => GitHistoryQuery.parse('path:ok\u0000bad'),
      throwsA(isA<GitParseException>()),
    );
  });
}
