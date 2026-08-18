import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/git/git.dart';

void main() {
  const parser = GitHistoryParser();

  test('empty output is empty history', () {
    expect(parser.parse(const []).commits, isEmpty);
  });

  test('parses fixed fields, Unicode, and arbitrary-length parent IDs', () {
    final sha256ParentA = 'a' * 64;
    final sha256ParentB = 'b' * 64;
    final bytes = _record([
      'c' * 64,
      '$sha256ParentA $sha256ParentB',
      '作者',
      'author@example.com',
      '2026-08-18T08:30:00+08:00',
      '提交者',
      'committer@example.com',
      '2026-08-18T09:00:00+08:00',
      '支持 Unicode',
      '正文第一行\n正文第二行\n',
    ]);

    final commit = parser.parse(bytes).commits.single;
    expect(commit.objectId, 'c' * 64);
    expect(commit.parentIds, [sha256ParentA, sha256ParentB]);
    expect(commit.author.name, '作者');
    expect(commit.author.when.toUtc(), DateTime.utc(2026, 8, 18, 0, 30));
    expect(commit.committer.name, '提交者');
    expect(commit.subject, '支持 Unicode');
    expect(commit.body, '正文第一行\n正文第二行\n');
  });

  test('parses a root commit followed by a child commit', () {
    final bytes = <int>[
      ..._record([
        'child',
        'root',
        'A',
        'a@example.com',
        '2026-08-18T01:00:00Z',
        'A',
        'a@example.com',
        '2026-08-18T01:00:00Z',
        'child subject',
        '',
      ]),
      ..._record([
        'root',
        '',
        'A',
        'a@example.com',
        '2026-08-17T01:00:00Z',
        'A',
        'a@example.com',
        '2026-08-17T01:00:00Z',
        'root subject',
        '',
      ]),
    ];

    final commits = parser.parse(bytes).commits;
    expect(commits, hasLength(2));
    expect(commits.first.parentIds, ['root']);
    expect(commits.last.parentIds, isEmpty);
  });

  test('rejects a partial history record', () {
    expect(
      () => parser.parse(utf8.encode('oid\u0000parent\u0000')),
      throwsA(isA<GitParseException>()),
    );
  });
}

List<int> _record(List<String> fields) {
  assert(fields.length == 10);
  return utf8.encode('${fields.join('\u0000')}\u0000\u0000');
}
