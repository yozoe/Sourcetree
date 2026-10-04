/// GitHub.com integration contracts used before any network or credential
/// operation is allowed.
///
/// 中文：GitHub.com 集成的前置数据契约；在网络请求或凭据读取之前，先固定
/// 支持的域名、仓库标识和 Pull Request 草稿边界。
library;

/// The only hosted Git service supported by the first integration slice.
///
/// 中文：首期托管平台集成唯一支持的 Git 服务。
const String githubComHost = 'github.com';

/// The fixed GitHub REST API origin. Enterprise or user-supplied API origins
/// are intentionally not representable by this contract.
///
/// 中文：固定的 GitHub REST API 源地址；该契约不接受企业或用户自定义 API 地址。
const String githubApiOrigin = 'https://api.github.com';

/// A validated GitHub.com repository identity.
///
/// 中文：经过校验的 GitHub.com 仓库身份；不携带凭据、查询参数或自定义域名。
final class GitHubRepositoryIdentity {
  GitHubRepositoryIdentity({required this.owner, required this.name}) {
    _validateSegment(owner, field: 'owner');
    _validateSegment(name, field: 'name');
  }

  final String owner;
  final String name;

  /// Returns the canonical web URL without credentials or query data.
  ///
  /// 中文：返回不含凭据和查询参数的规范网页地址。
  Uri get webUri => Uri.https(githubComHost, '/$owner/$name');

  /// Returns the repository API path used by GitHub.com.
  ///
  /// 中文：返回 GitHub.com API 使用的仓库路径。
  String get apiPath => '/repos/$owner/$name';

  @override
  bool operator ==(Object other) =>
      other is GitHubRepositoryIdentity &&
      other.owner == owner &&
      other.name == name;

  @override
  int get hashCode => Object.hash(owner, name);

  @override
  String toString() => '$owner/$name';
}

/// Parses a Git remote only when it unambiguously identifies GitHub.com.
///
/// 中文：仅在 Git remote 明确指向 GitHub.com 时解析仓库身份；企业域名、凭据、
/// 查询参数、片段、自定义端口和未知协议都会被拒绝。
GitHubRepositoryIdentity parseGitHubRemote(String remote) {
  if (remote.isEmpty ||
      remote != remote.trim() ||
      _hasControlCharacter(remote)) {
    throw const FormatException('The GitHub remote is invalid.');
  }

  final uri = Uri.tryParse(remote);
  if (uri != null && uri.hasScheme) {
    return _parseUriRemote(uri);
  }

  final scpMatch = RegExp(
    r'^git@github\.com:([^/\s]+)/([^/\s]+)$',
  ).firstMatch(remote);
  if (scpMatch == null) {
    throw const FormatException('Only GitHub.com remotes are supported.');
  }
  return GitHubRepositoryIdentity(
    owner: scpMatch.group(1)!,
    name: _stripGitSuffix(scpMatch.group(2)!),
  );
}

/// Validates a user-selected branch name for a Pull Request draft.
///
/// 中文：校验用户明确选择的 Pull Request 分支名；不允许空值、控制字符或
/// 会改变 API 路径语义的分隔符。
String validateGitHubBranchName(String branch) {
  if (branch.isEmpty ||
      branch != branch.trim() ||
      _hasControlCharacter(branch)) {
    throw const FormatException('The branch name is invalid.');
  }
  if (branch.contains('/') && branch.startsWith('/')) {
    throw const FormatException('The branch name is invalid.');
  }
  if (branch.contains('..') || branch.contains('?') || branch.contains('#')) {
    throw const FormatException('The branch name is invalid.');
  }
  return branch;
}

/// An explicit Pull Request draft; creating it never implies pushing a branch.
///
/// 中文：用户明确选择的 Pull Request 草稿；创建草稿本身不代表推送分支。
final class GitHubPullRequestDraft {
  GitHubPullRequestDraft({
    required this.repository,
    required String head,
    required String base,
    required String title,
    required String body,
  }) : head = validateGitHubBranchName(head),
       base = validateGitHubBranchName(base),
       title = _validateText(title, field: 'title', maxLength: 256),
       body = _validateText(body, field: 'body', maxLength: 65536);

  final GitHubRepositoryIdentity repository;
  final String head;
  final String base;
  final String title;
  final String body;
}

GitHubRepositoryIdentity _parseUriRemote(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  final validHttps =
      scheme == 'https' &&
      uri.userInfo.isEmpty &&
      (uri.port == 443 || uri.port == 0);
  final validSsh =
      scheme == 'ssh' &&
      (uri.userInfo.isEmpty || uri.userInfo == 'git') &&
      (uri.port == 22 || uri.port == 0);
  if ((!validHttps && !validSsh) ||
      uri.host.toLowerCase() != githubComHost ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const FormatException(
      'Only credential-free GitHub.com HTTPS or SSH remotes are supported.',
    );
  }
  final segments = uri.pathSegments;
  if (segments.length != 2 || segments.any((segment) => segment.isEmpty)) {
    throw const FormatException('The GitHub repository path is invalid.');
  }
  return GitHubRepositoryIdentity(
    owner: segments[0],
    name: _stripGitSuffix(segments[1]),
  );
}

String _stripGitSuffix(String value) {
  if (value.endsWith('.git')) return value.substring(0, value.length - 4);
  return value;
}

String _validateText(
  String value, {
  required String field,
  required int maxLength,
}) {
  if (value.trim().isEmpty ||
      _hasControlCharacter(value) ||
      value.length > maxLength) {
    throw FormatException('The $field is invalid.');
  }
  return value;
}

void _validateSegment(String value, {required String field}) {
  if (value.isEmpty || value != value.trim() || _hasControlCharacter(value)) {
    throw FormatException('The GitHub $field is invalid.');
  }
  if (value == '.' ||
      value == '..' ||
      value.contains('/') ||
      value.contains('\\')) {
    throw FormatException('The GitHub $field is invalid.');
  }
}

bool _hasControlCharacter(String value) =>
    RegExp(r'[\x00-\x1F\x7F]').hasMatch(value);
