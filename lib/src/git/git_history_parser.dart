import 'dart:convert';

import 'git_errors.dart';
import 'git_models.dart';

/// The fixed format consumed by [GitHistoryParser].
///
/// `git log -z` adds one NUL record separator after the final `%x00`.
const gitHistoryFormat =
    '%H%x00%P%x00%an%x00%ae%x00%aI%x00'
    '%cn%x00%ce%x00%cI%x00%s%x00%b%x00';

/// The fixed history format plus one record-start byte for file history.
///
/// Name-status data follows the ten NUL-delimited Git fields. The byte is
/// deliberately outside normal text output so the parser can retain each
/// path as Git reported it for `git log --follow`.
const gitFileHistoryFormat = '%x1e$gitHistoryFormat';

/// Parses fixed-field, NUL-delimited history records without assuming an
/// object ID length.
final class GitHistoryParser {
  const GitHistoryParser();

  /// 中文：解析输入数据。
  /// English: Parses the input data.
  GitHistoryParseResult parse(List<int> bytes) {
    if (bytes.isEmpty) {
      return const GitHistoryParseResult([]);
    }
    final cursor = _NulFieldCursor(bytes);
    final commits = <GitCommit>[];
    var recordIndex = 0;
    while (!cursor.isDone) {
      final objectId = cursor.readText(recordIndex);
      final parents = cursor.readText(recordIndex);
      final authorName = cursor.readText(recordIndex);
      final authorEmail = cursor.readText(recordIndex);
      final authorDate = _parseDate(cursor.readText(recordIndex), recordIndex);
      final committerName = cursor.readText(recordIndex);
      final committerEmail = cursor.readText(recordIndex);
      final committerDate = _parseDate(
        cursor.readText(recordIndex),
        recordIndex,
      );
      final subject = cursor.readText(recordIndex);
      final body = cursor.readText(recordIndex);
      final separator = cursor.readBytes(recordIndex);

      if (objectId.isEmpty) {
        throw GitParseException(
          'History record has an empty object ID.',
          recordIndex: recordIndex,
        );
      }
      if (separator.isNotEmpty) {
        throw GitParseException(
          'History record separator was not empty.',
          recordIndex: recordIndex,
        );
      }

      commits.add(
        GitCommit(
          objectId: objectId,
          parentIds: parents.isEmpty ? const [] : parents.split(' '),
          author: GitSignature(
            name: authorName,
            email: authorEmail,
            when: authorDate,
          ),
          committer: GitSignature(
            name: committerName,
            email: committerEmail,
            when: committerDate,
          ),
          subject: subject,
          body: body,
        ),
      );
      recordIndex++;
    }
    return GitHistoryParseResult(commits);
  }

  /// Parses `git log --follow --name-status -z` output.
  ///
  /// Each record contains the same ten fields as [parse], followed by one
  /// path-filtered name-status entry. Rename and copy records contain an old
  /// and a new path; the new path is valid for rendering that commit's diff.
  ///
  /// 中文：解析 `git log --follow --name-status -z` 输出。每条记录先包含与
  /// [parse] 相同的十个字段，再包含一个按路径过滤的 name-status 条目；重命名
  /// 和复制条目有旧/新两个路径，显示该提交 Diff 时使用新路径。
  GitFileHistoryParseResult parseFileHistory(List<int> bytes) {
    if (bytes.isEmpty) return const GitFileHistoryParseResult([]);
    final entries = <GitFileHistoryEntry>[];
    final cursor = _NulFieldCursor(bytes);
    while (!cursor.isDone) {
      cursor.skipRecordPadding();
      if (cursor.isDone) break;
      if (cursor.currentByte != 0x1e) {
        throw GitParseException('File-history record did not start correctly.');
      }
      cursor.advance();
      final recordIndex = entries.length;
      final commit = _readCommit(cursor, recordIndex);
      cursor.skipRecordPadding();
      final path = _parseFileHistoryPath(cursor, recordIndex);
      entries.add(GitFileHistoryEntry(commit: commit, path: path));
    }
    return GitFileHistoryParseResult(entries);
  }

  /// Reads the ten fixed commit fields at the cursor without consuming the
  /// following name-status entry.
  ///
  /// 中文：从当前游标读取十个固定提交字段，不消费后续的 name-status 条目。
  GitCommit _readCommit(_NulFieldCursor cursor, int recordIndex) {
    final objectId = cursor.readText(recordIndex);
    final parents = cursor.readText(recordIndex);
    final authorName = cursor.readText(recordIndex);
    final authorEmail = cursor.readText(recordIndex);
    final authorDate = _parseDate(cursor.readText(recordIndex), recordIndex);
    final committerName = cursor.readText(recordIndex);
    final committerEmail = cursor.readText(recordIndex);
    final committerDate = _parseDate(cursor.readText(recordIndex), recordIndex);
    final subject = cursor.readText(recordIndex);
    final body = cursor.readText(recordIndex);
    if (objectId.isEmpty) {
      throw GitParseException(
        'History record has an empty object ID.',
        recordIndex: recordIndex,
      );
    }
    return GitCommit(
      objectId: objectId,
      parentIds: parents.isEmpty ? const [] : parents.split(' '),
      author: GitSignature(
        name: authorName,
        email: authorEmail,
        when: authorDate,
      ),
      committer: GitSignature(
        name: committerName,
        email: committerEmail,
        when: committerDate,
      ),
      subject: subject,
      body: body,
    );
  }

  /// Reads the path valid for this history record from one name-status entry.
  ///
  /// 中文：从一个 name-status 条目读取该历史记录中有效的路径；重命名和复制
  /// 使用目标路径，普通改动使用唯一的路径字段。
  GitPath _parseFileHistoryPath(_NulFieldCursor cursor, int recordIndex) {
    if (cursor.isDone) {
      throw GitParseException(
        'File-history record did not include a changed path.',
        recordIndex: recordIndex,
      );
    }
    final status = cursor.readText(recordIndex);
    if (status.isEmpty) {
      throw GitParseException(
        'File-history record has an empty change status.',
        recordIndex: recordIndex,
      );
    }
    if (status.startsWith('R') || status.startsWith('C')) {
      cursor.readBytes(recordIndex);
      return GitPath(cursor.readBytes(recordIndex));
    }
    return GitPath(cursor.readBytes(recordIndex));
  }

  /// 中文：解析输入数据。
  /// English: Parses the input data.
  DateTime _parseDate(String value, int recordIndex) {
    final parsed = DateTime.tryParse(value);
    if (parsed == null) {
      throw GitParseException(
        'Invalid ISO 8601 date in history record: $value',
        recordIndex: recordIndex,
      );
    }
    return parsed;
  }
}

final class GitHistoryParseResult {
  const GitHistoryParseResult(this.commits);

  final List<GitCommit> commits;
}

final class _NulFieldCursor {
  _NulFieldCursor(this.bytes);

  final List<int> bytes;
  int _offset = 0;

  bool get isDone => _offset >= bytes.length;

  /// Returns the byte under the cursor, or `null` after all input is consumed.
  ///
  /// 中文：返回当前游标指向的字节；输入已读取完毕时返回 `null`。
  int? get currentByte => isDone ? null : bytes[_offset];

  /// Moves the cursor forward by one byte without passing the input boundary.
  ///
  /// 中文：将游标向前移动一个字节，并确保不会越过输入边界。
  void advance() {
    if (!isDone) _offset++;
  }

  /// Skips separators emitted between pretty-format and name-status records.
  ///
  /// 中文：跳过 pretty-format 与 name-status 记录之间由 Git 输出的空字节和换行。
  void skipRecordPadding() {
    while (!isDone &&
        (bytes[_offset] == 0 || bytes[_offset] == 10 || bytes[_offset] == 13)) {
      _offset++;
    }
  }

  /// 中文：读取所需的数据。
  /// English: Reads the required data.
  List<int> readBytes(int recordIndex) {
    if (isDone) {
      throw GitParseException(
        'History record ended before all fields were read.',
        recordIndex: recordIndex,
      );
    }
    final terminator = bytes.indexOf(0, _offset);
    if (terminator < 0) {
      throw GitParseException(
        'History output did not end with NUL.',
        recordIndex: recordIndex,
      );
    }
    final value = bytes.sublist(_offset, terminator);
    _offset = terminator + 1;
    return value;
  }

  /// 中文：读取所需的数据。
  /// English: Reads the required data.
  String readText(int recordIndex) =>
      utf8.decode(readBytes(recordIndex), allowMalformed: true);
}

final class GitFileHistoryParseResult {
  const GitFileHistoryParseResult(this.entries);

  final List<GitFileHistoryEntry> entries;
}
