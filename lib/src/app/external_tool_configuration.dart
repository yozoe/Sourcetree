import 'package:path/path.dart' as path_utils;

import 'repository_trust.dart';

/// The application-owned capability requested from an external tool.
///
/// 中文：应用准备交给外部工具的能力类型。
enum ExternalToolKind { readOnlyDiff, mergeWriteBack }

/// Stable validation issues for an application-owned external-tool template.
///
/// 中文：应用自有外部工具模板的稳定校验问题；界面可据此给出明确错误。
enum ExternalToolConfigurationIssue {
  emptyDisplayName,
  executableMustBeAbsolute,
  invalidExecutable,
  tooManyArguments,
  invalidArgument,
  unknownPlaceholder,
  missingBeforePlaceholder,
  missingAfterPlaceholder,
  missingBasePlaceholder,
  missingOursPlaceholder,
  missingTheirsPlaceholder,
  missingResultPlaceholder,
}

/// An immutable argv-only external-tool template that is never interpreted by
/// a shell. Repository configuration, aliases, and environment overrides are
/// deliberately outside this model.
///
/// 中文：只通过 argv 传参、绝不交给 Shell 解释的不可变外部工具模板；仓库配置、
/// Git alias 和环境变量覆盖刻意不属于此模型。
final class ExternalToolConfiguration {
  ExternalToolConfiguration({
    required this.displayName,
    required this.executablePath,
    required List<String> arguments,
    this.kind = ExternalToolKind.readOnlyDiff,
    this.enabled = false,
  }) : arguments = List<String>.unmodifiable(arguments);

  static const int snapshotByteLimit = 16 * 1024 * 1024;
  static const String beforePlaceholder = '{before}';
  static const String afterPlaceholder = '{after}';
  static const String basePlaceholder = '{base}';
  static const String oursPlaceholder = '{ours}';
  static const String theirsPlaceholder = '{theirs}';
  static const String resultPlaceholder = '{result}';
  static const String repositoryPlaceholder = '{repository}';
  static const String relativePathPlaceholder = '{path}';
  static const Set<String> _allowedPlaceholders = <String>{
    beforePlaceholder,
    afterPlaceholder,
    basePlaceholder,
    oursPlaceholder,
    theirsPlaceholder,
    resultPlaceholder,
    repositoryPlaceholder,
    relativePathPlaceholder,
  };
  static final RegExp _placeholderPattern = RegExp(r'\{[^{}]+\}');

  final String displayName;
  final String executablePath;
  final List<String> arguments;
  final ExternalToolKind kind;
  final bool enabled;

  /// Serializes a validated configuration without embedding repository trust.
  ///
  /// 中文：序列化已校验的工具配置；不会把仓库信任状态嵌入配置文件。
  Map<String, Object> toJson() => <String, Object>{
    'displayName': displayName,
    'executablePath': executablePath,
    'arguments': arguments,
    'kind': kind.name,
    'enabled': enabled,
  };

  /// Restores a safe configuration record, rejecting malformed or unsupported
  /// values before they can be offered to the process layer.
  ///
  /// 中文：恢复安全的工具配置记录；在交给进程层前拒绝损坏或不支持的值。
  static ExternalToolConfiguration? fromJson(Object? value) {
    if (value is! Map ||
        value['displayName'] is! String ||
        value['executablePath'] is! String ||
        value['arguments'] is! List ||
        value['kind'] is! String ||
        value['enabled'] is! bool) {
      return null;
    }
    final kindName = value['kind'] as String;
    ExternalToolKind? kind;
    for (final candidate in ExternalToolKind.values) {
      if (candidate.name == kindName) {
        kind = candidate;
        break;
      }
    }
    if (kind == null) return null;
    final rawArguments = value['arguments'] as List;
    if (rawArguments.any((argument) => argument is! String)) return null;
    final configuration = ExternalToolConfiguration(
      displayName: value['displayName'] as String,
      executablePath: value['executablePath'] as String,
      arguments: rawArguments.cast<String>(),
      kind: kind,
      enabled: value['enabled'] as bool,
    );
    return configuration.validate().isEmpty ? configuration : null;
  }

  /// Returns every safety or completeness issue without touching the file
  /// system or starting a process.
  ///
  /// 中文：在不访问文件系统、不启动进程的前提下返回全部安全性和完整性问题。
  List<ExternalToolConfigurationIssue> validate() {
    final issues = <ExternalToolConfigurationIssue>[];
    if (displayName.trim().isEmpty) {
      issues.add(ExternalToolConfigurationIssue.emptyDisplayName);
    }
    if (!_isSafeText(executablePath)) {
      issues.add(ExternalToolConfigurationIssue.invalidExecutable);
    } else if (!path_utils.isAbsolute(executablePath)) {
      issues.add(ExternalToolConfigurationIssue.executableMustBeAbsolute);
    }
    if (arguments.length > 64) {
      issues.add(ExternalToolConfigurationIssue.tooManyArguments);
    }
    var hasBefore = false;
    var hasAfter = false;
    var hasBase = false;
    var hasOurs = false;
    var hasTheirs = false;
    var hasResult = false;
    var hasUnknownPlaceholder = false;
    for (final argument in arguments) {
      if (!_isSafeText(argument) || argument.length > 4096) {
        issues.add(ExternalToolConfigurationIssue.invalidArgument);
        continue;
      }
      hasBefore = hasBefore || argument.contains(beforePlaceholder);
      hasAfter = hasAfter || argument.contains(afterPlaceholder);
      hasBase = hasBase || argument.contains(basePlaceholder);
      hasOurs = hasOurs || argument.contains(oursPlaceholder);
      hasTheirs = hasTheirs || argument.contains(theirsPlaceholder);
      hasResult = hasResult || argument.contains(resultPlaceholder);
      for (final match in _placeholderPattern.allMatches(argument)) {
        if (!_allowedPlaceholders.contains(match.group(0))) {
          hasUnknownPlaceholder = true;
        }
      }
    }
    if (hasUnknownPlaceholder) {
      issues.add(ExternalToolConfigurationIssue.unknownPlaceholder);
    }
    if (kind == ExternalToolKind.readOnlyDiff) {
      if (!hasBefore) {
        issues.add(ExternalToolConfigurationIssue.missingBeforePlaceholder);
      }
      if (!hasAfter) {
        issues.add(ExternalToolConfigurationIssue.missingAfterPlaceholder);
      }
    } else {
      if (!hasBase) {
        issues.add(ExternalToolConfigurationIssue.missingBasePlaceholder);
      }
      if (!hasOurs) {
        issues.add(ExternalToolConfigurationIssue.missingOursPlaceholder);
      }
      if (!hasTheirs) {
        issues.add(ExternalToolConfigurationIssue.missingTheirsPlaceholder);
      }
      if (!hasResult) {
        issues.add(ExternalToolConfigurationIssue.missingResultPlaceholder);
      }
    }
    return List<ExternalToolConfigurationIssue>.unmodifiable(issues);
  }

  /// Builds a literal argv invocation for two immutable snapshots after
  /// validating all configured and request-scoped paths.
  ///
  /// 中文：校验配置及本次请求的全部路径后，为两个不可变快照生成字面 argv 调用。
  ExternalToolInvocation buildReadOnlyDiffInvocation({
    required String beforeSnapshotPath,
    required String afterSnapshotPath,
    required String repositoryRoot,
    required String repositoryRelativePath,
  }) {
    final issues = validate();
    if (issues.isNotEmpty) {
      throw StateError('External tool configuration is invalid: $issues');
    }
    _requireAbsolutePath(beforeSnapshotPath, 'beforeSnapshotPath');
    _requireAbsolutePath(afterSnapshotPath, 'afterSnapshotPath');
    _requireAbsolutePath(repositoryRoot, 'repositoryRoot');
    _requireRepositoryRelativePath(repositoryRelativePath);
    final replacements = <String, String>{
      beforePlaceholder: beforeSnapshotPath,
      afterPlaceholder: afterSnapshotPath,
      repositoryPlaceholder: repositoryRoot,
      relativePathPlaceholder: repositoryRelativePath,
    };
    return ExternalToolInvocation(
      executablePath: executablePath,
      arguments: [
        for (final argument in arguments)
          replacements.entries.fold<String>(
            argument,
            (expanded, entry) => expanded.replaceAll(entry.key, entry.value),
          ),
      ],
    );
  }

  /// Builds a literal argv invocation for a three-way merge and a result file.
  /// 中文：为三方合并及结果文件构建不经 Shell 的字面 argv 调用。
  ExternalToolInvocation buildMergeInvocation({
    required String baseSnapshotPath,
    required String oursSnapshotPath,
    required String theirsSnapshotPath,
    required String resultSnapshotPath,
    required String repositoryRoot,
    required String repositoryRelativePath,
  }) {
    final issues = validate();
    if (issues.isNotEmpty) {
      throw StateError('External tool configuration is invalid: $issues');
    }
    for (final entry in <String, String>{
      'baseSnapshotPath': baseSnapshotPath,
      'oursSnapshotPath': oursSnapshotPath,
      'theirsSnapshotPath': theirsSnapshotPath,
      'resultSnapshotPath': resultSnapshotPath,
    }.entries) {
      _requireAbsolutePath(entry.value, entry.key);
    }
    _requireAbsolutePath(repositoryRoot, 'repositoryRoot');
    _requireRepositoryRelativePath(repositoryRelativePath);
    final replacements = <String, String>{
      basePlaceholder: baseSnapshotPath,
      oursPlaceholder: oursSnapshotPath,
      theirsPlaceholder: theirsSnapshotPath,
      resultPlaceholder: resultSnapshotPath,
      repositoryPlaceholder: repositoryRoot,
      relativePathPlaceholder: repositoryRelativePath,
    };
    return ExternalToolInvocation(
      executablePath: executablePath,
      arguments: [
        for (final argument in arguments)
          replacements.entries.fold<String>(
            argument,
            (expanded, entry) => expanded.replaceAll(entry.key, entry.value),
          ),
      ],
    );
  }

  static bool _isSafeText(String value) =>
      value.isNotEmpty && !value.contains('\u0000');

  static void _requireAbsolutePath(String value, String argumentName) {
    if (!_isSafeText(value) || !path_utils.isAbsolute(value)) {
      throw ArgumentError.value(
        value,
        argumentName,
        'Must be an absolute path.',
      );
    }
  }

  static void _requireRepositoryRelativePath(String value) {
    final normalized = path_utils.posix.normalize(value);
    if (!_isSafeText(value) ||
        path_utils.posix.isAbsolute(value) ||
        normalized == '.' ||
        normalized == '..' ||
        normalized.startsWith('../')) {
      throw ArgumentError.value(
        value,
        'repositoryRelativePath',
        'Must remain inside the repository.',
      );
    }
  }
}

/// A process-ready executable and literal argv list. It carries no shell
/// command string and no caller-controlled environment.
///
/// 中文：可交给进程层的可执行文件与字面 argv；不携带 Shell 命令字符串或调用方环境变量。
final class ExternalToolInvocation {
  ExternalToolInvocation({
    required this.executablePath,
    required List<String> arguments,
  }) : arguments = List<String>.unmodifiable(arguments);

  final String executablePath;
  final List<String> arguments;
}

/// Returns whether a validated configuration may be offered for one trusted
/// repository. This does not execute the tool or imply that its path exists.
///
/// 中文：判断已校验配置能否对一个受信任仓库开放；本函数不执行工具，也不保证路径存在。
bool canActivateExternalTool({
  required RepositoryTrustStatus trustStatus,
  required ExternalToolConfiguration configuration,
}) =>
    configuration.enabled &&
    canRunRepositoryExtension(trustStatus) &&
    configuration.validate().isEmpty;
