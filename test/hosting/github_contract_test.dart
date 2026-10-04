import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/hosting/github_contract.dart';

void main() {
  group('parseGitHubRemote', () {
    test('accepts GitHub.com HTTPS remotes', () {
      final identity = parseGitHubRemote(
        'https://github.com/yozoe/Sourcetree.git',
      );

      expect(identity.owner, 'yozoe');
      expect(identity.name, 'Sourcetree');
      expect(identity.webUri.toString(), 'https://github.com/yozoe/Sourcetree');
      expect(identity.apiPath, '/repos/yozoe/Sourcetree');
    });

    test('accepts GitHub.com SSH remotes', () {
      expect(
        parseGitHubRemote('git@github.com:yozoe/Sourcetree.git').toString(),
        'yozoe/Sourcetree',
      );
      expect(
        parseGitHubRemote('ssh://git@github.com/yozoe/Sourcetree').toString(),
        'yozoe/Sourcetree',
      );
    });

    test('rejects enterprise, custom-host and credential-bearing remotes', () {
      for (final remote in <String>[
        'https://github.example.com/yozoe/Sourcetree.git',
        'https://github.com:8443/yozoe/Sourcetree.git',
        'https://user:secret@github.com/yozoe/Sourcetree.git',
        'https://github.com/yozoe/Sourcetree.git?token=secret',
        'git@github.example.com:yozoe/Sourcetree.git',
        'https://api.github.com/repos/yozoe/Sourcetree',
      ]) {
        expect(
          () => parseGitHubRemote(remote),
          throwsA(isA<FormatException>()),
        );
      }
    });

    test('rejects malformed paths and invisible characters', () {
      for (final remote in <String>[
        'https://github.com/yozoe',
        'https://github.com/yozoe/Sourcetree/issues',
        ' https://github.com/yozoe/Sourcetree.git',
        'https://github.com/yozoe/Sourcetree.git\n',
      ]) {
        expect(
          () => parseGitHubRemote(remote),
          throwsA(isA<FormatException>()),
        );
      }
    });
  });

  group('GitHubPullRequestDraft', () {
    final repository = GitHubRepositoryIdentity(
      owner: 'yozoe',
      name: 'Sourcetree',
    );

    test('keeps explicit branch and message fields', () {
      final draft = GitHubPullRequestDraft(
        repository: repository,
        head: 'codex/github-readonly-discovery',
        base: 'main',
        title: 'Add GitHub discovery',
        body: 'Review the explicitly selected branches.',
      );

      expect(draft.repository, repository);
      expect(draft.head, 'codex/github-readonly-discovery');
      expect(draft.base, 'main');
    });

    test('rejects unsafe or empty draft fields', () {
      expect(
        () => GitHubPullRequestDraft(
          repository: repository,
          head: '../main',
          base: 'main',
          title: 'title',
          body: '',
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => GitHubPullRequestDraft(
          repository: repository,
          head: 'feature',
          base: 'main',
          title: ' ',
          body: 'body',
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
