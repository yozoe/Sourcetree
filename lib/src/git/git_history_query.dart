import 'git_errors.dart';

/// A validated query for Git commit history.
///
/// 中文：一个经过校验、可安全转换为 `git log` 参数的提交历史查询。
/// 字段查询支持作者、提交者、路径和 ISO 日期范围；未带字段的文本仍由
/// 展示层对已加载历史执行快速本地过滤。
final class GitHistoryQuery {
  GitHistoryQuery._({
    this.author,
    this.committer,
    this.path,
    this.after,
    this.before,
    this.text = '',
  });

  /// Parses the compact history-query syntax used by the history search box.
  ///
  /// Supported fields are `author:`, `committer:`, `path:`, `after:` and
  /// `before:`. Values may be quoted with single or double quotes. Remaining
  /// tokens form a case-insensitive commit subject/body search.
  ///
  /// 中文：解析历史搜索框使用的紧凑查询语法。支持 `author:`、`committer:`、
  /// `path:`、`after:` 和 `before:`；值可以使用单引号或双引号包裹，其余
  /// token 组成不区分大小写的提交标题/正文查询。
  factory GitHistoryQuery.parse(String input) {
    if (input.length > 2048) {
      throw const GitParseException('历史查询过长。');
    }
    final tokens = _tokenize(input);
    String? author;
    String? committer;
    String? path;
    String? after;
    String? before;
    final freeText = <String>[];
    for (final token in tokens) {
      final separator = token.indexOf(':');
      if (separator <= 0) {
        freeText.add(token);
        continue;
      }
      final key = token.substring(0, separator).toLowerCase();
      final value = token.substring(separator + 1);
      if (!const {
        'author',
        'committer',
        'path',
        'after',
        'before',
      }.contains(key)) {
        freeText.add(token);
        continue;
      }
      if (value.isEmpty || value.contains('\u0000') || _hasControl(value)) {
        throw GitParseException('历史查询字段 $key 的值无效。');
      }
      switch (key) {
        case 'author':
          if (author != null) throw const GitParseException('author 条件重复。');
          author = _bounded(value, key);
        case 'committer':
          if (committer != null) {
            throw const GitParseException('committer 条件重复。');
          }
          committer = _bounded(value, key);
        case 'path':
          if (path != null) throw const GitParseException('path 条件重复。');
          path = _validatePath(value);
        case 'after':
          if (after != null) throw const GitParseException('after 条件重复。');
          after = _validateDate(value, key);
        case 'before':
          if (before != null) {
            throw const GitParseException('before 条件重复。');
          }
          before = _validateDate(value, key);
      }
    }
    if (after != null && before != null) {
      final afterDate = DateTime.parse(after);
      final beforeDate = DateTime.parse(before);
      if (afterDate.isAfter(beforeDate)) {
        throw const GitParseException('after 条件不能晚于 before 条件。');
      }
    }
    final text = freeText.join(' ').trim();
    if (text.length > 1024) {
      throw const GitParseException('历史文本查询过长。');
    }
    return GitHistoryQuery._(
      author: author,
      committer: committer,
      path: path,
      after: after,
      before: before,
      text: text,
    );
  }

  /// Returns `null` for an empty query, but preserves parse failures.
  static GitHistoryQuery? tryParse(String input) {
    if (input.trim().isEmpty) return null;
    return GitHistoryQuery.parse(input);
  }

  final String? author;
  final String? committer;
  final String? path;
  final String? after;
  final String? before;
  final String text;

  /// Whether this query requires a Git-backed history read.
  bool get isStructured =>
      author != null ||
      committer != null ||
      path != null ||
      after != null ||
      before != null;

  bool get isEmpty => !isStructured && text.isEmpty;

  /// Converts validated fields to option arguments for `git log`.
  ///
  /// 中文：将已校验字段转换为 `git log` 选项；返回值只包含独立参数，不经过
  /// shell，路径仍由读取层在 `--` 后单独追加。
  List<String> get gitLogArguments {
    final arguments = <String>[];
    if (author != null) {
      arguments.add('--author=${_escapeGitRegex(author!)}');
    }
    if (committer != null) {
      arguments.add('--committer=${_escapeGitRegex(committer!)}');
    }
    if (after != null) arguments.add('--since=$after');
    if (before != null) arguments.add('--until=$before');
    if (text.isNotEmpty) {
      arguments.addAll([
        '--fixed-strings',
        '--regexp-ignore-case',
        '--all-match',
        '--grep=$text',
      ]);
    }
    return List<String>.unmodifiable(arguments);
  }
}

List<String> _tokenize(String input) {
  final tokens = <String>[];
  final buffer = StringBuffer();
  String? quote;
  var escaped = false;
  void flush() {
    if (buffer.isNotEmpty) {
      tokens.add(buffer.toString());
      buffer.clear();
    }
  }

  for (var index = 0; index < input.length; index++) {
    final character = input[index];
    if (escaped) {
      buffer.write(character);
      escaped = false;
    } else if (character == '\\' && quote != null) {
      escaped = true;
    } else if (quote != null) {
      if (character == quote) {
        quote = null;
      } else {
        buffer.write(character);
      }
    } else if (character == "'" || character == '"') {
      quote = character;
    } else if (character.trim().isEmpty) {
      flush();
    } else {
      buffer.write(character);
    }
  }
  if (escaped || quote != null) {
    throw const GitParseException('历史查询引号或转义不完整。');
  }
  flush();
  return tokens;
}

String _bounded(String value, String field) {
  if (value.length > 512) {
    throw GitParseException('历史查询字段 $field 过长。');
  }
  return value;
}

String _validateDate(String value, String field) {
  if (value.length > 64 || DateTime.tryParse(value) == null) {
    throw GitParseException('历史查询字段 $field 需要 ISO 日期。');
  }
  return value;
}

String _validatePath(String value) {
  if (value.length > 1024 ||
      value.startsWith('/') ||
      value.startsWith('\\') ||
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value)) {
    throw const GitParseException('历史查询路径必须是仓库相对路径。');
  }
  final segments = value.replaceAll('\\', '/').split('/');
  if (segments.any((segment) => segment == '..')) {
    throw const GitParseException('历史查询路径不能离开仓库目录。');
  }
  return value;
}

bool _hasControl(String value) {
  return value.codeUnits.any((codeUnit) => codeUnit < 0x20 || codeUnit == 0x7f);
}

String _escapeGitRegex(String value) {
  final buffer = StringBuffer();
  for (final character in value.split('')) {
    if ('\\.^\$|()?*+{}[]'.contains(character)) buffer.write('\\');
    buffer.write(character);
  }
  return buffer.toString();
}
