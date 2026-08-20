import 'dart:convert';

import 'git_errors.dart';
import 'git_models.dart';

/// Parses the byte-oriented output of
/// `git status --porcelain=v2 -z --branch --show-stash`.
final class GitStatusParser {
  const GitStatusParser();

  /// 中文：解析输入数据。
  /// English: Parses the input data.
  GitStatusSnapshot parse(List<int> bytes) {
    final cursor = _NulRecordCursor(bytes);
    final branch = _BranchStatusBuilder();
    final entries = <GitStatusEntry>[];
    var recordIndex = 0;

    while (!cursor.isDone) {
      final record = cursor.readRecord(recordIndex: recordIndex);
      if (record.isEmpty) {
        recordIndex++;
        continue;
      }
      final marker = record.first;
      switch (marker) {
        case 0x23: // #
          _parseHeader(record, branch, recordIndex);
        case 0x31: // 1
          entries.add(_parseOrdinary(record, recordIndex));
        case 0x32: // 2
          final originalPath = cursor.readRecord(recordIndex: recordIndex + 1);
          entries.add(_parseRenameOrCopy(record, originalPath, recordIndex));
          recordIndex++;
        case 0x75: // u
          entries.add(_parseUnmerged(record, recordIndex));
        case 0x3f: // ?
          entries.add(_parseUntracked(record, recordIndex));
        case 0x21: // !
          entries.add(_parseIgnored(record, recordIndex));
        default:
          throw GitParseException(
            'Unknown porcelain v2 record type 0x${marker.toRadixString(16)}.',
            recordIndex: recordIndex,
          );
      }
      recordIndex++;
    }

    return GitStatusSnapshot(
      branch: branch.build(),
      entries: entries,
      additionalHeaders: branch.additionalHeaders,
    );
  }

  /// 中文：解析输入数据。
  /// English: Parses the input data.
  void _parseHeader(
    List<int> record,
    _BranchStatusBuilder branch,
    int recordIndex,
  ) {
    if (record.length < 4 || record[1] != 0x20) {
      throw GitParseException(
        'Malformed porcelain v2 header.',
        recordIndex: recordIndex,
      );
    }
    final payload = utf8.decode(record.sublist(2), allowMalformed: true);
    final separator = payload.indexOf(' ');
    final key = separator < 0 ? payload : payload.substring(0, separator);
    final value = separator < 0 ? '' : payload.substring(separator + 1);

    switch (key) {
      case 'branch.oid':
        if (value == '(initial)') {
          branch.objectId = null;
          branch.isUnborn = true;
        } else {
          branch.objectId = value;
        }
      case 'branch.head':
        if (value == '(detached)') {
          branch.head = null;
          branch.isDetached = true;
        } else {
          branch.head = value;
        }
      case 'branch.upstream':
        branch.upstream = value;
      case 'branch.ab':
        final match = RegExp(r'^\+(\d+) -(\d+)$').firstMatch(value);
        if (match == null) {
          throw GitParseException(
            'Malformed branch.ab header: $value',
            recordIndex: recordIndex,
          );
        }
        branch.ahead = int.parse(match.group(1)!);
        branch.behind = int.parse(match.group(2)!);
      case 'stash':
        final count = int.tryParse(value);
        if (count == null || count < 0) {
          throw GitParseException(
            'Malformed stash header: $value',
            recordIndex: recordIndex,
          );
        }
        branch.stashCount = count;
      default:
        branch.additionalHeaders[key] = value;
    }
  }

  /// 中文：解析输入数据。
  /// English: Parses the input data.
  GitStatusEntry _parseOrdinary(List<int> record, int recordIndex) {
    final fields = _splitPrefix(
      record,
      spaceCount: 8,
      recordIndex: recordIndex,
    );
    final xy = _parseXy(fields[1], recordIndex);
    return GitStatusEntry(
      kind: GitFileStatusKind.ordinary,
      path: GitPath(fields[8]),
      indexStatus: xy.$1,
      workTreeStatus: xy.$2,
      submodule: GitSubmoduleStatus.parse(_text(fields[2])),
      headMode: _text(fields[3]),
      indexMode: _text(fields[4]),
      workTreeMode: _text(fields[5]),
      headObjectId: _zeroObjectIdToNull(_text(fields[6])),
      indexObjectId: _zeroObjectIdToNull(_text(fields[7])),
    );
  }

  /// 中文：解析输入数据。
  /// English: Parses the input data.
  GitStatusEntry _parseRenameOrCopy(
    List<int> record,
    List<int> originalPath,
    int recordIndex,
  ) {
    final fields = _splitPrefix(
      record,
      spaceCount: 9,
      recordIndex: recordIndex,
    );
    final xy = _parseXy(fields[1], recordIndex);
    final scoreField = _text(fields[8]);
    if (scoreField.length < 2) {
      throw GitParseException(
        'Malformed rename/copy score.',
        recordIndex: recordIndex,
      );
    }
    final score = int.tryParse(scoreField.substring(1));
    if (score == null) {
      throw GitParseException(
        'Malformed rename/copy score: $scoreField',
        recordIndex: recordIndex,
      );
    }
    final kind = switch (scoreField[0]) {
      'R' => GitFileStatusKind.renamed,
      'C' => GitFileStatusKind.copied,
      _ => throw GitParseException(
        'Unexpected rename/copy kind: $scoreField',
        recordIndex: recordIndex,
      ),
    };
    return GitStatusEntry(
      kind: kind,
      path: GitPath(fields[9]),
      originalPath: GitPath(originalPath),
      indexStatus: xy.$1,
      workTreeStatus: xy.$2,
      submodule: GitSubmoduleStatus.parse(_text(fields[2])),
      renameOrCopyScore: score,
      headMode: _text(fields[3]),
      indexMode: _text(fields[4]),
      workTreeMode: _text(fields[5]),
      headObjectId: _zeroObjectIdToNull(_text(fields[6])),
      indexObjectId: _zeroObjectIdToNull(_text(fields[7])),
    );
  }

  /// 中文：解析输入数据。
  /// English: Parses the input data.
  GitStatusEntry _parseUnmerged(List<int> record, int recordIndex) {
    final fields = _splitPrefix(
      record,
      spaceCount: 10,
      recordIndex: recordIndex,
    );
    final xy = _parseXy(fields[1], recordIndex);
    return GitStatusEntry(
      kind: GitFileStatusKind.unmerged,
      path: GitPath(fields[10]),
      indexStatus: xy.$1,
      workTreeStatus: xy.$2,
      submodule: GitSubmoduleStatus.parse(_text(fields[2])),
      stage1Mode: _text(fields[3]),
      stage2Mode: _text(fields[4]),
      stage3Mode: _text(fields[5]),
      workTreeMode: _text(fields[6]),
      stage1ObjectId: _zeroObjectIdToNull(_text(fields[7])),
      stage2ObjectId: _zeroObjectIdToNull(_text(fields[8])),
      stage3ObjectId: _zeroObjectIdToNull(_text(fields[9])),
    );
  }

  /// 中文：解析输入数据。
  /// English: Parses the input data.
  GitStatusEntry _parseUntracked(List<int> record, int recordIndex) {
    final path = _simplePath(record, recordIndex);
    return GitStatusEntry(
      kind: GitFileStatusKind.untracked,
      path: GitPath(path),
      indexStatus: GitChangeType.unmodified,
      workTreeStatus: GitChangeType.untracked,
    );
  }

  /// 中文：解析输入数据。
  /// English: Parses the input data.
  GitStatusEntry _parseIgnored(List<int> record, int recordIndex) {
    final path = _simplePath(record, recordIndex);
    return GitStatusEntry(
      kind: GitFileStatusKind.ignored,
      path: GitPath(path),
      indexStatus: GitChangeType.unmodified,
      workTreeStatus: GitChangeType.ignored,
    );
  }

  /// 中文：从未跟踪或忽略记录中提取路径字节，并验证其固定前缀。
  ///
  /// English: Extracts path bytes from an untracked or ignored record after
  /// validating its fixed prefix.
  List<int> _simplePath(List<int> record, int recordIndex) {
    if (record.length < 3 || record[1] != 0x20) {
      throw GitParseException(
        'Malformed simple pathname record.',
        recordIndex: recordIndex,
      );
    }
    return record.sublist(2);
  }

  (GitChangeType, GitChangeType) _parseXy(List<int> bytes, int recordIndex) {
    if (bytes.length != 2) {
      throw GitParseException(
        'Malformed XY status field.',
        recordIndex: recordIndex,
      );
    }
    return (
      GitChangeTypeParsing.fromCode(String.fromCharCode(bytes[0])),
      GitChangeTypeParsing.fromCode(String.fromCharCode(bytes[1])),
    );
  }

  /// 中文：按指定数量的空格拆分 porcelain v2 的固定字段，并保留最后一个字段的原始字节。
  ///
  /// English: Splits the fixed porcelain-v2 fields at the requested number of
  /// spaces while preserving the raw bytes of the final field.
  List<List<int>> _splitPrefix(
    List<int> record, {
    required int spaceCount,
    required int recordIndex,
  }) {
    final fields = <List<int>>[];
    var start = 0;
    for (var index = 0; index < spaceCount; index++) {
      final separator = record.indexOf(0x20, start);
      if (separator < 0) {
        throw GitParseException(
          'Porcelain v2 record has too few fields.',
          recordIndex: recordIndex,
        );
      }
      fields.add(record.sublist(start, separator));
      start = separator + 1;
    }
    fields.add(record.sublist(start));
    return fields;
  }

  /// 中文：将 Git 的字节字段解码为可显示文本；无效 UTF-8 会被替换而不会中断解析。
  ///
  /// English: Decodes a Git byte field for display, replacing malformed UTF-8
  /// rather than aborting parsing.
  String _text(List<int> bytes) => utf8.decode(bytes, allowMalformed: true);

  /// 中文：将全为零的对象 ID 规范化为 `null`，其余值保持不变。
  ///
  /// English: Normalizes an all-zero object ID to `null` and leaves other
  /// values unchanged.
  String? _zeroObjectIdToNull(String objectId) {
    if (objectId.isNotEmpty &&
        objectId.codeUnits.every((character) => character == 0x30)) {
      return null;
    }
    return objectId;
  }
}

final class _BranchStatusBuilder {
  String? objectId;
  String? head;
  String? upstream;
  int ahead = 0;
  int behind = 0;
  int stashCount = 0;
  bool isDetached = false;
  bool isUnborn = false;
  final Map<String, String> additionalHeaders = {};

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  GitBranchStatus build() {
    return GitBranchStatus(
      objectId: objectId,
      head: head,
      upstream: upstream,
      ahead: ahead,
      behind: behind,
      stashCount: stashCount,
      isDetached: isDetached,
      isUnborn: isUnborn,
    );
  }
}

final class _NulRecordCursor {
  _NulRecordCursor(this.bytes);

  final List<int> bytes;
  int _offset = 0;

  bool get isDone => _offset >= bytes.length;

  /// 中文：读取所需的数据。
  /// English: Reads the required data.
  List<int> readRecord({required int recordIndex}) {
    if (isDone) {
      throw GitParseException(
        'Missing NUL-delimited record.',
        recordIndex: recordIndex,
      );
    }
    final terminator = bytes.indexOf(0, _offset);
    if (terminator < 0) {
      throw GitParseException(
        'Porcelain v2 output did not end with NUL.',
        recordIndex: recordIndex,
      );
    }
    final record = bytes.sublist(_offset, terminator);
    _offset = terminator + 1;
    return record;
  }
}
