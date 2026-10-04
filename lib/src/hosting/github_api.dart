import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../git/git_cancellation.dart';
import '../git/git_errors.dart';
import 'github_contract.dart';

/// A bounded response returned by a GitHub.com transport.
///
/// 中文：GitHub.com 传输层返回的有大小上限响应；不保存请求令牌。
final class GitHubApiResponse {
  GitHubApiResponse({
    required this.statusCode,
    required List<int> bodyBytes,
    Map<String, String> headers = const <String, String>{},
  }) : headers = Map<String, String>.unmodifiable(headers),
       bodyBytes = Uint8List.fromList(bodyBytes);

  final int statusCode;
  final Uint8List bodyBytes;
  final Map<String, String> headers;

  String get bodyText => utf8.decode(bodyBytes, allowMalformed: true);
}

/// Network transport boundary for GitHub.com API calls.
///
/// 中文：GitHub.com API 网络传输边界；测试可注入内存实现，避免访问公网。
abstract interface class GitHubApiTransport {
  Future<GitHubApiResponse> send({
    required Uri uri,
    required Map<String, String> headers,
    required GitCancellationToken cancellationToken,
  });
}

/// `dart:io` implementation of [GitHubApiTransport].
///
/// 中文：基于 `dart:io` 的 GitHub.com API 传输实现；取消会中止当前请求。
final class HttpClientGitHubApiTransport implements GitHubApiTransport {
  HttpClientGitHubApiTransport({
    HttpClient? client,
    this.maxResponseBytes = 4 * 1024 * 1024,
  }) : _client = client ?? HttpClient();

  final HttpClient _client;
  final int maxResponseBytes;

  /// Closes the underlying HTTP client after all requests finish.
  ///
  /// 中文：在所有请求结束后关闭底层 HTTP 客户端。
  void close({bool force = false}) => _client.close(force: force);

  @override
  Future<GitHubApiResponse> send({
    required Uri uri,
    required Map<String, String> headers,
    required GitCancellationToken cancellationToken,
  }) async {
    if (cancellationToken.isCancelled) {
      throw const GitCancelledException();
    }
    final request = await _client.getUrl(uri);
    headers.forEach(request.headers.set);
    final registration = cancellationToken.register(request.abort);
    try {
      final response = await request.close();
      final builder = BytesBuilder(copy: false);
      var length = 0;
      await for (final chunk in response) {
        length += chunk.length;
        if (length > maxResponseBytes) {
          throw const GitHubApiException(
            operation: 'read GitHub response',
            message: 'The GitHub response exceeded the safety limit.',
          );
        }
        builder.add(chunk);
      }
      if (cancellationToken.isCancelled) {
        throw const GitCancelledException();
      }
      final responseHeaders = <String, String>{};
      response.headers.forEach((name, values) {
        responseHeaders[name] = values.join(',');
      });
      return GitHubApiResponse(
        statusCode: response.statusCode,
        bodyBytes: builder.takeBytes(),
        headers: responseHeaders,
      );
    } finally {
      registration.dispose();
    }
  }
}

/// A safe, non-secret GitHub API failure.
///
/// 中文：不包含令牌、完整请求地址或响应正文的安全 GitHub API 错误。
class GitHubApiException implements Exception {
  const GitHubApiException({
    required this.operation,
    required this.message,
    this.statusCode,
  });

  final String operation;
  final String message;
  final int? statusCode;

  @override
  String toString() => statusCode == null
      ? 'GitHubApiException($operation): $message'
      : 'GitHubApiException($operation, status $statusCode): $message';
}

/// Indicates that a GitHub API request exceeded its caller-provided timeout.
///
/// 中文：GitHub API 请求超过调用方超时限制。
final class GitHubApiTimeoutException extends GitHubApiException {
  const GitHubApiTimeoutException({required super.operation})
    : super(message: 'The GitHub request timed out.');
}

/// Repository metadata returned by GitHub.com.
///
/// 中文：GitHub.com 返回的仓库元数据。
final class GitHubRepositoryMetadata {
  const GitHubRepositoryMetadata({
    required this.identity,
    required this.isPrivate,
    required this.defaultBranch,
    required this.webUri,
  });

  final GitHubRepositoryIdentity identity;
  final bool isPrivate;
  final String defaultBranch;
  final Uri webUri;
}

/// A branch returned by GitHub.com.
///
/// 中文：GitHub.com 返回的分支信息。
final class GitHubBranch {
  const GitHubBranch({required this.name, required this.commitSha});

  final String name;
  final String commitSha;
}

/// Fixed-origin, read-only GitHub.com API client.
///
/// 中文：固定 API 源地址的只读 GitHub.com 客户端；不会 Push、创建分支或创建 PR。
final class GitHubApiClient {
  GitHubApiClient({
    GitHubApiTransport? transport,
    this.accessTokenProvider,
    this.requestTimeout = const Duration(seconds: 20),
  }) : _transport = transport ?? HttpClientGitHubApiTransport();

  final GitHubApiTransport _transport;
  final Future<String?> Function()? accessTokenProvider;
  final Duration requestTimeout;

  /// Closes the owned HTTP transport when this client is no longer needed.
  ///
  /// 中文：客户端不再使用时关闭其 HTTP 传输，供窗口关闭和 Engine 销毁路径调用。
  void close({bool force = false}) {
    final transport = _transport;
    if (transport is HttpClientGitHubApiTransport) {
      transport.close(force: force);
    }
  }

  /// Reads repository metadata from the fixed GitHub.com API.
  ///
  /// 中文：从固定 GitHub.com API 读取仓库元数据；失败不会猜测仓库或目标分支。
  Future<GitHubRepositoryMetadata> getRepository(
    GitHubRepositoryIdentity identity, {
    GitCancellationToken? cancellationToken,
  }) async {
    final json = await _getJson(
      path: identity.apiPath,
      cancellationToken: cancellationToken,
      operation: 'read GitHub repository',
    );
    return _parseRepository(identity, json);
  }

  /// Reads one explicit page of branches from the fixed GitHub.com API.
  ///
  /// 中文：从固定 GitHub.com API 读取一页分支；分页失败不会降级为猜测分支。
  Future<List<GitHubBranch>> listBranches(
    GitHubRepositoryIdentity identity, {
    int page = 1,
    int perPage = 100,
    GitCancellationToken? cancellationToken,
  }) async {
    if (page < 1 || page > 1000 || perPage < 1 || perPage > 100) {
      throw const GitHubApiException(
        operation: 'list GitHub branches',
        message: 'The branch page is invalid.',
      );
    }
    final json = await _getJson(
      path: '${identity.apiPath}/branches',
      queryParameters: <String, String>{
        'page': '$page',
        'per_page': '$perPage',
      },
      cancellationToken: cancellationToken,
      operation: 'list GitHub branches',
    );
    if (json is! List) {
      throw const GitHubApiException(
        operation: 'list GitHub branches',
        message: 'GitHub returned an invalid branch response.',
      );
    }
    return json.map<GitHubBranch>(_parseBranch).toList(growable: false);
  }

  Future<Object?> _getJson({
    required String path,
    Map<String, String> queryParameters = const <String, String>{},
    required GitCancellationToken? cancellationToken,
    required String operation,
  }) async {
    final callerToken = cancellationToken;
    if (callerToken?.isCancelled ?? false) {
      throw const GitCancelledException();
    }
    final requestToken = GitCancellationToken();
    final registration = callerToken?.register(requestToken.cancel);
    try {
      final uri = Uri.https(
        Uri.parse(githubApiOrigin).host,
        path,
        queryParameters.isEmpty ? null : queryParameters,
      );
      final token = await accessTokenProvider?.call();
      if (requestToken.isCancelled) {
        throw const GitCancelledException();
      }
      final headers = <String, String>{
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'git-desktop',
      };
      if (token != null) {
        headers['Authorization'] = 'Bearer ${_validateToken(token)}';
      }
      final response = await _transport
          .send(uri: uri, headers: headers, cancellationToken: requestToken)
          .timeout(
            requestTimeout,
            onTimeout: () {
              requestToken.cancel();
              throw GitHubApiTimeoutException(operation: operation);
            },
          );
      if (requestToken.isCancelled) throw const GitCancelledException();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw GitHubApiException(
          operation: operation,
          statusCode: response.statusCode,
          message: 'GitHub returned an unsuccessful response.',
        );
      }
      try {
        return jsonDecode(response.bodyText);
      } on FormatException {
        throw GitHubApiException(
          operation: operation,
          statusCode: response.statusCode,
          message: 'GitHub returned invalid JSON.',
        );
      }
    } finally {
      registration?.dispose();
    }
  }
}

GitHubRepositoryMetadata _parseRepository(
  GitHubRepositoryIdentity identity,
  Object? value,
) {
  if (value is! Map) {
    throw const GitHubApiException(
      operation: 'read GitHub repository',
      message: 'GitHub returned an invalid repository response.',
    );
  }
  final isPrivate = value['private'];
  final defaultBranch = value['default_branch'];
  final htmlUrl = value['html_url'];
  if (isPrivate is! bool ||
      defaultBranch is! String ||
      defaultBranch.isEmpty ||
      htmlUrl is! String) {
    throw const GitHubApiException(
      operation: 'read GitHub repository',
      message: 'GitHub returned incomplete repository metadata.',
    );
  }
  final uri = Uri.tryParse(htmlUrl);
  if (uri == null || uri.scheme != 'https' || uri.host != githubComHost) {
    throw const GitHubApiException(
      operation: 'read GitHub repository',
      message: 'GitHub returned an unsupported repository URL.',
    );
  }
  return GitHubRepositoryMetadata(
    identity: identity,
    isPrivate: isPrivate,
    defaultBranch: defaultBranch,
    webUri: uri,
  );
}

GitHubBranch _parseBranch(Object? value) {
  if (value is! Map || value['name'] is! String || value['commit'] is! Map) {
    throw const GitHubApiException(
      operation: 'list GitHub branches',
      message: 'GitHub returned an invalid branch entry.',
    );
  }
  final name = value['name'] as String;
  final commit = value['commit'] as Map;
  final sha = commit['sha'];
  if (name.isEmpty || sha is! String || sha.isEmpty) {
    throw const GitHubApiException(
      operation: 'list GitHub branches',
      message: 'GitHub returned an incomplete branch entry.',
    );
  }
  return GitHubBranch(name: name, commitSha: sha);
}

String _validateToken(String token) {
  if (token.isEmpty ||
      token != token.trim() ||
      RegExp(r'[\x00-\x1F\x7F]').hasMatch(token)) {
    throw const GitHubApiException(
      operation: 'prepare GitHub request',
      message: 'The GitHub access token is invalid.',
    );
  }
  return token;
}
