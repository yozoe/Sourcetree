import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/git/git.dart';

void main() {
  const parser = GitStatusParser();

  test('parses an empty unborn repository', () {
    final snapshot = parser.parse(
      utf8.encode(
        '# branch.oid (initial)\u0000'
        '# branch.head main\u0000',
      ),
    );

    expect(snapshot.isClean, isTrue);
    expect(snapshot.branch.objectId, isNull);
    expect(snapshot.branch.head, 'main');
    expect(snapshot.branch.isUnborn, isTrue);
    expect(snapshot.branch.isDetached, isFalse);
  });

  test('parses branch metadata and ordinary statuses', () {
    final snapshot = parser.parse(
      utf8.encode(
        '# branch.oid 0123456789abcdef\u0000'
        '# branch.head feature/status\u0000'
        '# branch.upstream origin/feature/status\u0000'
        '# branch.ab +2 -3\u0000'
        '# stash 4\u0000'
        '1 M. N... 100644 100644 100644 '
        'aaaaaaaa bbbbbbbb staged.txt\u0000'
        '1 .M N... 100644 100644 100644 '
        'cccccccc cccccccc dir/working tree.txt\u0000'
        '? untracked file.txt\u0000'
        '! ignored.log\u0000',
      ),
    );

    expect(snapshot.branch.objectId, '0123456789abcdef');
    expect(snapshot.branch.head, 'feature/status');
    expect(snapshot.branch.upstream, 'origin/feature/status');
    expect(snapshot.branch.ahead, 2);
    expect(snapshot.branch.behind, 3);
    expect(snapshot.branch.stashCount, 4);
    expect(snapshot.entries, hasLength(4));

    final staged = snapshot.entries[0];
    expect(staged.path.display, 'staged.txt');
    expect(staged.indexStatus, GitChangeType.modified);
    expect(staged.workTreeStatus, GitChangeType.unmodified);
    expect(staged.hasStagedChange, isTrue);

    final working = snapshot.entries[1];
    expect(working.path.display, 'dir/working tree.txt');
    expect(working.indexStatus, GitChangeType.unmodified);
    expect(working.workTreeStatus, GitChangeType.modified);

    expect(snapshot.entries[2].kind, GitFileStatusKind.untracked);
    expect(snapshot.entries[3].kind, GitFileStatusKind.ignored);
  });

  test('preserves Unicode, spaces, and newlines in rename paths', () {
    final snapshot = parser.parse(
      utf8.encode(
        '2 R. N... 100644 100644 100644 '
        'aaaaaaaa bbbbbbbb R087 新目录/新 文件\n名.dart\u0000'
        '旧目录/旧 文件\n名.dart\u0000',
      ),
    );

    final entry = snapshot.entries.single;
    expect(entry.kind, GitFileStatusKind.renamed);
    expect(entry.renameOrCopyScore, 87);
    expect(entry.path.display, '新目录/新 文件\n名.dart');
    expect(entry.originalPath?.display, '旧目录/旧 文件\n名.dart');
    expect(entry.indexStatus, GitChangeType.renamed);
  });

  test('parses an unmerged record and all stage object IDs', () {
    final snapshot = parser.parse(
      utf8.encode(
        'u UU N... 100644 100644 100644 100644 '
        '11111111 22222222 33333333 conflict.txt\u0000',
      ),
    );

    final entry = snapshot.entries.single;
    expect(entry.kind, GitFileStatusKind.unmerged);
    expect(entry.isConflicted, isTrue);
    expect(entry.indexStatus, GitChangeType.unmerged);
    expect(entry.workTreeStatus, GitChangeType.unmerged);
    expect(entry.stage1ObjectId, '11111111');
    expect(entry.stage2ObjectId, '22222222');
    expect(entry.stage3ObjectId, '33333333');
  });

  test('retains non-UTF-8 path bytes for identity', () {
    final prefix = utf8.encode('? invalid-');
    final bytes = <int>[...prefix, 0xff, 0];
    final entry = parser.parse(bytes).entries.single;

    expect(entry.path.isValidUtf8, isFalse);
    expect(entry.path.rawBytes.last, 0xff);
    expect(entry.path.display, contains('\uFFFD'));
  });

  test('rejects a rename record without its original path', () {
    final bytes = utf8.encode(
      '2 R. N... 100644 100644 100644 '
      'aaaaaaaa bbbbbbbb R100 current.txt\u0000',
    );

    expect(() => parser.parse(bytes), throwsA(isA<GitParseException>()));
  });
}
