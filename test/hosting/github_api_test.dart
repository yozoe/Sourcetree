import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/git/git_cancellation.dart';
import 'package:git_desktop/src/git/git_errors.dart';
import 'package:git_desktop/src/hosting/github_api.dart';
import 'package:git_desktop/src/hosting/github_contract.dart';

void main() {
  final repository = GitHubRepositoryIdentity(
    owner: 'yozoe',
    name: 'Sourcetree',
  );

  test('reads repository metadata from the fixed GitHub API origin', () async {
    final transport = _FakeTransport(
      response: _jsonResponse(<String, Object>{
        'private': true,
        'default_branch': 'main',
        'html_url': 'https://github.com/yozoe/Sourcetree',
      }),
    );
    final client = GitHubApiClient(
      transport: transport,
      accessTokenProvider: () async => 'ghp_test_token',
    );

    final result = await client.getRepository(repository);

    expect(result.isPrivate, isTrue);
    expect(result.defaultBranch, 'main');
    expect(
      transport.uri.toString(),
      'https://api.github.com/repos/yozoe/Sourcetree',
    );
    expect(transport.headers['Authorization'], 'Bearer ghp_test_token');
    expect(transport.headers['X-GitHub-Api-Version'], '2022-11-28');
  });

  test('lists an explicit branch page and parses commit SHAs', () async {
    final transport = _FakeTransport(
      response: _jsonResponse(<Object>[
        <String, Object>{
          'name': 'main',
          'commit': <String, String>{'sha': 'abc'},
        },
        <String, Object>{
          'name': 'feature',
          'commit': <String, String>{'sha': 'def'},
        },
      ]),
    );
    final branches = await GitHubApiClient(
      transport: transport,
    ).listBranches(repository, page: 2, perPage: 25);

    expect(branches.map((branch) => branch.name), ['main', 'feature']);
    expect(transport.uri.queryParameters, {'page': '2', 'per_page': '25'});
  });

  test('does not include a token in API errors', () async {
    final token = 'ghp_super_secret';
    final client = GitHubApiClient(
      transport: _FakeTransport(
        response: GitHubApiResponse(
          statusCode: 404,
          bodyBytes: utf8.encode('{}'),
        ),
      ),
      accessTokenProvider: () async => token,
    );

    final error = await captureException(
      () => client.getRepository(repository),
    );

    expect(error, isA<GitHubApiException>());
    expect(error.toString(), isNot(contains(token)));
    expect(error.toString(), isNot(contains('api.github.com')));
  });

  test(
    'cancels before transport when caller token is already cancelled',
    () async {
      final token = GitCancellationToken()..cancel();
      final transport = _FakeTransport(
        response: _jsonResponse(<String, Object>{}),
      );

      await expectLater(
        GitHubApiClient(
          transport: transport,
        ).getRepository(repository, cancellationToken: token),
        throwsA(isA<GitCancelledException>()),
      );
      expect(transport.wasCalled, isFalse);
    },
  );

  test('turns a slow transport into a timeout and cancels its token', () async {
    final transport = _FakeTransport(
      response: _jsonResponse(<String, Object>{}),
      holdResponse: true,
    );
    final client = GitHubApiClient(
      transport: transport,
      requestTimeout: const Duration(milliseconds: 10),
    );

    await expectLater(
      client.getRepository(repository),
      throwsA(isA<GitHubApiTimeoutException>()),
    );
    expect(transport.receivedCancellationToken?.isCancelled, isTrue);
  });
}

GitHubApiResponse _jsonResponse(Object value) => GitHubApiResponse(
  statusCode: 200,
  bodyBytes: utf8.encode(jsonEncode(value)),
);

Future<Object> captureException(Future<Object> Function() action) async {
  try {
    await action();
    fail('Expected action to throw.');
  } catch (error) {
    return error;
  }
}

final class _FakeTransport implements GitHubApiTransport {
  _FakeTransport({required this.response, this.holdResponse = false});

  final GitHubApiResponse response;
  final bool holdResponse;
  late Uri uri;
  late Map<String, String> headers;
  GitCancellationToken? receivedCancellationToken;
  bool wasCalled = false;

  @override
  Future<GitHubApiResponse> send({
    required Uri uri,
    required Map<String, String> headers,
    required GitCancellationToken cancellationToken,
  }) async {
    wasCalled = true;
    this.uri = uri;
    this.headers = headers;
    receivedCancellationToken = cancellationToken;
    if (holdResponse) {
      await Completer<void>().future;
    }
    return response;
  }
}
