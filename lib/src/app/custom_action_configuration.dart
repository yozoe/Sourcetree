import 'dart:io';

import 'package:path/path.dart' as path_utils;

import 'repository_trust.dart';

/// The visible target scope declared by an application-owned custom action.
///
/// 中文：应用自有自定义操作声明的可见目标范围；当前只允许整个仓库或一个
/// 明确选中的 UTF-8 仓库相对路径，不支持隐式多选、任意目录或 Shell 上下文。
enum CustomActionScope { repository, selectedFile }

/// Stable validation issues for one custom-action configuration.
///
/// 中文：一个自定义操作配置的稳定校验问题，供配置界面准确说明拒绝原因。
enum CustomActionConfigurationIssue {
  invalidId,
  emptyDisplayName,
  executableMustBeAbsolute,
  invalidExecutable,
  tooManyArguments,
  invalidArgument,
  unknownPlaceholder,
  pathPlaceholderNotAllowed,
  missingPathPlaceholder,
  tooManyEnvironmentEntries,
  environmentVariableNotAllowed,
  invalidEnvironmentValue,
}

/// An immutable, disabled-by-default custom action described only by a literal
/// executable path, argv template, explicit target scope, and a minimal
/// environment allowlist.
///
/// The configuration never contains a shell command, arbitrary working
/// directory, inherited process environment, Git configuration, or repository
/// trust. Trust remains a separate per-repository decision.
///
/// 中文：默认关闭的不可变自定义操作，只包含字面可执行路径、argv 模板、明确
/// 目标范围和最小环境白名单。配置不包含 Shell 命令、任意工作目录、继承环境、
/// Git 配置或仓库信任；信任仍是独立的逐仓库决定。
final class CustomActionConfiguration {
  CustomActionConfiguration({
    required this.id,
    required this.displayName,
    required this.executablePath,
    required List<String> arguments,
    required this.scope,
    Map<String, String> environment = const <String, String>{},
    this.enabled = false,
  }) : arguments = List<String>.unmodifiable(arguments),
       environment = Map<String, String>.unmodifiable(environment);

  static const String repositoryPlaceholder = '{repository}';
  static const String relativePathPlaceholder = '{path}';
  static const Set<String> allowedEnvironmentVariables = <String>{
    'LANG',
    'LC_ALL',
  };
  static const Set<String> _allowedPlaceholders = <String>{
    repositoryPlaceholder,
    relativePathPlaceholder,
  };
  static final RegExp _placeholderPattern = RegExp(r'\{[^{}]+\}');

  final String displayName;
  final String id;
  final String executablePath;
  final List<String> arguments;
  final CustomActionScope scope;
  final Map<String, String> environment;
  final bool enabled;

  /// Returns whether this immutable definition is identical to [other].
  ///
  /// 中文：判断两个不可变配置定义是否完全一致；用于确认框关闭后复核配置，
  /// 防止用户确认的 argv、目标范围或环境白名单在执行前被另一窗口替换。
  bool hasSameDefinitionAs(CustomActionConfiguration other) {
    if (id != other.id ||
        displayName != other.displayName ||
        executablePath != other.executablePath ||
        scope != other.scope ||
        enabled != other.enabled ||
        arguments.length != other.arguments.length ||
        environment.length != other.environment.length) {
      return false;
    }
    for (var index = 0; index < arguments.length; index++) {
      if (arguments[index] != other.arguments[index]) return false;
    }
    for (final entry in environment.entries) {
      if (other.environment[entry.key] != entry.value) return false;
    }
    return true;
  }

  /// Serializes a validated configuration without repository trust or runtime
  /// target paths.
  ///
  /// 中文：序列化已校验配置，不包含仓库信任或本次运行的目标路径。
  Map<String, Object> toJson() => <String, Object>{
    'id': id,
    'displayName': displayName,
    'executablePath': executablePath,
    'arguments': arguments,
    'scope': scope.name,
    'environment': environment,
    'enabled': enabled,
  };

  /// Restores a safe configuration record and rejects malformed, unknown, or
  /// unsupported values before they reach any process layer.
  ///
  /// 中文：恢复安全配置记录；损坏、未知或不支持的值在到达进程层前直接拒绝。
  static CustomActionConfiguration? fromJson(Object? value) {
    if (value is! Map ||
        value['id'] is! String ||
        value['displayName'] is! String ||
        value['executablePath'] is! String ||
        value['arguments'] is! List ||
        value['scope'] is! String ||
        value['environment'] is! Map ||
        value['enabled'] is! bool) {
      return null;
    }
    final scopeName = value['scope'] as String;
    final scope = CustomActionScope.values
        .where((candidate) => candidate.name == scopeName)
        .firstOrNull;
    if (scope == null) return null;
    final rawArguments = value['arguments'] as List;
    final rawEnvironment = value['environment'] as Map;
    if (rawArguments.any((argument) => argument is! String) ||
        rawEnvironment.keys.any((key) => key is! String) ||
        rawEnvironment.values.any((entry) => entry is! String)) {
      return null;
    }
    final configuration = CustomActionConfiguration(
      id: value['id'] as String,
      displayName: value['displayName'] as String,
      executablePath: value['executablePath'] as String,
      arguments: rawArguments.cast<String>(),
      scope: scope,
      environment: rawEnvironment.cast<String, String>(),
      enabled: value['enabled'] as bool,
    );
    return configuration.validate().isEmpty ? configuration : null;
  }

  /// Returns all safety and completeness issues without touching the file
  /// system, reading Git configuration, or starting a process.
  ///
  /// 中文：在不访问文件系统、不读取 Git 配置且不启动进程的前提下，返回全部
  /// 安全性和完整性问题。
  List<CustomActionConfigurationIssue> validate() {
    final issues = <CustomActionConfigurationIssue>[];
    if (!RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$').hasMatch(id)) {
      issues.add(CustomActionConfigurationIssue.invalidId);
    }
    if (displayName.trim().isEmpty) {
      issues.add(CustomActionConfigurationIssue.emptyDisplayName);
    }
    if (!_isSafeText(executablePath)) {
      issues.add(CustomActionConfigurationIssue.invalidExecutable);
    } else if (!path_utils.isAbsolute(executablePath)) {
      issues.add(CustomActionConfigurationIssue.executableMustBeAbsolute);
    }
    if (arguments.length > 64) {
      issues.add(CustomActionConfigurationIssue.tooManyArguments);
    }
    var hasPathPlaceholder = false;
    var hasUnknownPlaceholder = false;
    for (final argument in arguments) {
      if (!_isSafeText(argument) || argument.length > 4096) {
        issues.add(CustomActionConfigurationIssue.invalidArgument);
        continue;
      }
      hasPathPlaceholder =
          hasPathPlaceholder || argument.contains(relativePathPlaceholder);
      for (final match in _placeholderPattern.allMatches(argument)) {
        if (!_allowedPlaceholders.contains(match.group(0))) {
          hasUnknownPlaceholder = true;
        }
      }
    }
    if (hasUnknownPlaceholder) {
      issues.add(CustomActionConfigurationIssue.unknownPlaceholder);
    }
    if (scope == CustomActionScope.repository && hasPathPlaceholder) {
      issues.add(CustomActionConfigurationIssue.pathPlaceholderNotAllowed);
    }
    if (scope == CustomActionScope.selectedFile && !hasPathPlaceholder) {
      issues.add(CustomActionConfigurationIssue.missingPathPlaceholder);
    }
    if (environment.length > allowedEnvironmentVariables.length) {
      issues.add(CustomActionConfigurationIssue.tooManyEnvironmentEntries);
    }
    for (final entry in environment.entries) {
      if (!allowedEnvironmentVariables.contains(entry.key)) {
        issues.add(
          CustomActionConfigurationIssue.environmentVariableNotAllowed,
        );
      }
      if (!_isSafeText(entry.value) || entry.value.length > 256) {
        issues.add(CustomActionConfigurationIssue.invalidEnvironmentValue);
      }
    }
    return List<CustomActionConfigurationIssue>.unmodifiable(issues);
  }

  /// Builds a literal process invocation for one already validated repository
  /// target. The working directory is always the repository root and the
  /// parent environment must not be inherited by the process runner.
  ///
  /// 中文：为一个已校验仓库目标生成字面进程调用。工作目录固定为仓库根目录，
  /// 进程层必须禁止继承父进程环境。
  CustomActionInvocation buildInvocation(CustomActionTarget target) {
    final issues = validate();
    if (issues.isNotEmpty) {
      throw StateError('Custom action configuration is invalid: $issues');
    }
    target.validateFor(scope);
    final replacements = <String, String>{
      repositoryPlaceholder: target.repositoryRoot,
      relativePathPlaceholder: target.repositoryRelativePath ?? '',
    };
    return CustomActionInvocation(
      executablePath: executablePath,
      arguments: [
        for (final argument in arguments)
          replacements.entries.fold<String>(
            argument,
            (expanded, entry) => expanded.replaceAll(entry.key, entry.value),
          ),
      ],
      workingDirectory: target.repositoryRoot,
      environment: environment,
      scope: scope,
      repositoryRelativePath: target.repositoryRelativePath,
    );
  }

  static bool _isSafeText(String value) =>
      value.isNotEmpty && !value.contains('\u0000');
}

/// The repository-owned target selected for one custom-action invocation.
///
/// 中文：一次自定义操作调用所选的仓库目标；路径在进入 argv 前保持仓库相对形式。
final class CustomActionTarget {
  const CustomActionTarget.repository({required this.repositoryRoot})
    : repositoryRelativePath = null;

  const CustomActionTarget.selectedFile({
    required this.repositoryRoot,
    required this.repositoryRelativePath,
  });

  final String repositoryRoot;
  final String? repositoryRelativePath;

  /// Verifies that the runtime target exactly matches the configured visible
  /// scope and remains inside the repository.
  ///
  /// 中文：确认运行目标与配置的可见范围完全一致，并且始终位于仓库内部。
  void validateFor(CustomActionScope scope) {
    if (repositoryRoot.isEmpty ||
        repositoryRoot.contains('\u0000') ||
        !path_utils.isAbsolute(repositoryRoot)) {
      throw ArgumentError.value(
        repositoryRoot,
        'repositoryRoot',
        'Must be an absolute path.',
      );
    }
    final relativePath = repositoryRelativePath;
    if (scope == CustomActionScope.repository) {
      if (relativePath != null) {
        throw ArgumentError.value(
          relativePath,
          'repositoryRelativePath',
          'Repository-scoped actions cannot receive a file target.',
        );
      }
      _validateFilesystemBoundary();
      return;
    }
    final normalized = relativePath == null
        ? null
        : path_utils.posix.normalize(relativePath);
    if (relativePath == null ||
        relativePath.isEmpty ||
        relativePath.contains('\u0000') ||
        path_utils.posix.isAbsolute(relativePath) ||
        normalized == '.' ||
        normalized == '..' ||
        normalized!.startsWith('../')) {
      throw ArgumentError.value(
        relativePath,
        'repositoryRelativePath',
        'Must identify one path inside the repository.',
      );
    }
    _validateFilesystemBoundary();
  }

  /// Rejects an existing target whose resolved path leaves the work tree.
  ///
  /// 中文：拒绝解析后越出工作树的现有目标；词法校验仍保留，以便不存在的
  /// 目标也能在进入文件系统前获得稳定错误。执行入口会在启动进程前再次调用。
  void _validateFilesystemBoundary() {
    final rootType = FileSystemEntity.typeSync(
      repositoryRoot,
      followLinks: false,
    );
    if (rootType == FileSystemEntityType.notFound) return;

    final canonicalRoot = Directory(repositoryRoot).resolveSymbolicLinksSync();
    final relativePath = repositoryRelativePath;
    if (relativePath == null) return;

    final target = path_utils.normalize(
      path_utils.join(repositoryRoot, relativePath),
    );
    final targetType = FileSystemEntity.typeSync(target, followLinks: false);
    final canonicalParent = _resolveNearestExistingAncestor(
      path_utils.dirname(target),
    );
    if (canonicalParent != canonicalRoot &&
        !path_utils.isWithin(canonicalRoot, canonicalParent)) {
      throw ArgumentError.value(
        relativePath,
        'repositoryRelativePath',
        'Must identify one path inside the repository.',
      );
    }
    if (targetType == FileSystemEntityType.notFound) return;

    final canonicalTarget = File(target).resolveSymbolicLinksSync();
    if (canonicalTarget != canonicalRoot &&
        !path_utils.isWithin(canonicalRoot, canonicalTarget)) {
      throw ArgumentError.value(
        relativePath,
        'repositoryRelativePath',
        'Must identify one path inside the repository.',
      );
    }
  }

  /// Resolves the closest existing ancestor so missing targets cannot bypass
  /// a symlinked directory boundary.
  ///
  /// 中文：解析目标最近的已存在祖先，避免不存在的目标绕过符号链接目录边界。
  static String _resolveNearestExistingAncestor(String candidate) {
    var current = candidate;
    while (true) {
      if (FileSystemEntity.typeSync(current, followLinks: false) !=
          FileSystemEntityType.notFound) {
        return Directory(current).resolveSymbolicLinksSync();
      }
      final parent = path_utils.dirname(current);
      if (parent == current) {
        return Directory(current).resolveSymbolicLinksSync();
      }
      current = parent;
    }
  }
}

/// A process-ready custom-action invocation with no shell string or inherited
/// environment. [scope] and [repositoryRelativePath] are retained so the
/// confirmation UI can display the exact execution range.
///
/// 中文：可交给进程层的自定义操作调用，不包含 Shell 字符串或继承环境；保留
/// [scope] 与 [repositoryRelativePath]，便于确认界面展示准确执行范围。
final class CustomActionInvocation {
  CustomActionInvocation({
    required this.executablePath,
    required List<String> arguments,
    required this.workingDirectory,
    required Map<String, String> environment,
    required this.scope,
    required this.repositoryRelativePath,
  }) : arguments = List<String>.unmodifiable(arguments),
       environment = Map<String, String>.unmodifiable(environment);

  final String executablePath;
  final List<String> arguments;
  final String workingDirectory;
  final Map<String, String> environment;
  final CustomActionScope scope;
  final String? repositoryRelativePath;

  /// Custom actions must never inherit credentials or caller-specific process
  /// variables from the desktop application.
  ///
  /// 中文：自定义操作绝不继承桌面应用中的凭据或调用方进程变量。
  bool get includeParentEnvironment => false;
}

/// Returns whether one validated custom action may be offered for a repository.
/// This gate does not execute the action or imply that the executable exists.
///
/// 中文：判断一个已校验自定义操作能否对当前仓库开放；本函数不执行操作，也不
/// 保证可执行文件存在。
bool canActivateCustomAction({
  required RepositoryTrustStatus trustStatus,
  required CustomActionConfiguration configuration,
}) =>
    configuration.enabled &&
    canRunRepositoryExtension(trustStatus) &&
    configuration.validate().isEmpty;
