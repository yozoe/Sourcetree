import 'dart:convert';

import 'git_errors.dart';
import 'git_models.dart';

/// The fixed format consumed by [GitHistoryParser].
///
/// `git log -z` adds one NUL record separator after the final `%x00`.
const gitHistoryFormat =
    '%H%x00%P%x00%an%x00%ae%x00%aI%x00'
    '%cn%x00%ce%x00%cI%x00%s%x00%b%x00';

/// Parses fixed-field, NUL-delimited history records without assuming an
/// object ID length.
final class GitHistoryParser {
  const GitHistoryParser();

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

  String readText(int recordIndex) =>
      utf8.decode(readBytes(recordIndex), allowMalformed: true);
}
