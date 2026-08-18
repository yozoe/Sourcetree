import 'dart:io';

/// A disposable, real Git repository for integration and service tests.
///
/// Every instance gets its own work tree, HOME directory, and global Git
/// configuration. Commands are executed as an executable plus an argument
/// list, so test data is never interpreted by a shell.
final class GitTestRepository {
  GitTestRepository._({
    required this.rootDirectory,
    required this.workingDirectory,
    required this.homeDirectory,
    required this.initialBranch,
    required Map<String, String> environment,
  }) : _environment = environment;

  static const String authorName = 'Git Desktop Test';
  static const String authorEmail = 'git-desktop-test@example.invalid';

  /// The directory that owns all files for this fixture.
  final Directory rootDirectory;

  /// The non-bare repository work tree.
  final Directory workingDirectory;

  /// The isolated HOME used by every Git command for this fixture.
  final Directory homeDirectory;

  /// The branch created for a new repository.
  final String initialBranch;

  final Map<String, String> _environment;
  bool _isDisposed = false;

  /// Creates and initializes an empty repository.
  static Future<GitTestRepository> create({
    String initialBranch = 'main',
  }) async {
    _validateBranchName(initialBranch);

    final root = await Directory.systemTemp.createTemp(
      'git-desktop-test-repository-',
    );

    try {
      final repository = await _createFixture(
        root: root,
        initialBranch: initialBranch,
      );
      await repository.runGit([
        'init',
        '--initial-branch=$initialBranch',
        repository.workingDirectory.path,
      ], workingDirectory: root);
      await repository._configureIdentity();
      return repository;
    } on Object {
      await _deleteIfPresent(root);
      rethrow;
    }
  }

  /// Clones a local repository into a new, independently disposable fixture.
  static Future<GitTestRepository> cloneFrom(
    Directory source, {
    String initialBranch = 'main',
  }) async {
    _validateBranchName(initialBranch);

    final root = await Directory.systemTemp.createTemp(
      'git-desktop-test-clone-',
    );

    try {
      final repository = await _createFixture(
        root: root,
        initialBranch: initialBranch,
        createWorkingDirectory: false,
      );
      await repository.runGit([
        'clone',
        '--',
        source.absolute.path,
        repository.workingDirectory.path,
      ], workingDirectory: root);
      await repository._configureIdentity();
      return repository;
    } on Object {
      await _deleteIfPresent(root);
      rethrow;
    }
  }

  static Future<GitTestRepository> _createFixture({
    required Directory root,
    required String initialBranch,
    bool createWorkingDirectory = true,
  }) async {
    final home = Directory(_join(root.path, 'home'));
    final workTree = Directory(_join(root.path, 'repository'));
    await home.create(recursive: true);
    await Directory(_join(home.path, '.config')).create(recursive: true);
    await File(_join(home.path, '.gitconfig')).writeAsString('');
    if (createWorkingDirectory) {
      await workTree.create(recursive: true);
    }

    return GitTestRepository._(
      rootDirectory: root,
      workingDirectory: workTree,
      homeDirectory: home,
      initialBranch: initialBranch,
      environment: _isolatedEnvironment(home),
    );
  }

  /// Runs Git with [arguments] without invoking a shell.
  ///
  /// By default, a non-zero result throws [GitTestCommandException]. Set
  /// [throwOnError] to false when a failure is the behavior under test.
  Future<ProcessResult> runGit(
    List<String> arguments, {
    Directory? workingDirectory,
    bool throwOnError = true,
  }) async {
    _ensureActive();

    final result = await Process.run(
      'git',
      List<String>.unmodifiable(arguments),
      workingDirectory: (workingDirectory ?? this.workingDirectory).path,
      environment: _environment,
      includeParentEnvironment: false,
      runInShell: false,
    );

    if (throwOnError && result.exitCode != 0) {
      throw GitTestCommandException(
        arguments: List<String>.unmodifiable(arguments),
        exitCode: result.exitCode,
        standardOutput: result.stdout.toString(),
        standardError: result.stderr.toString(),
      );
    }
    return result;
  }

  /// Writes [contents] to a path relative to [workingDirectory].
  Future<File> writeFile(
    String relativePath,
    String contents, {
    bool append = false,
  }) async {
    _ensureActive();
    final segments = _validatedRelativePath(relativePath);
    final file = File(_joinAll([workingDirectory.path, ...segments]));
    await file.parent.create(recursive: true);
    await file.writeAsString(
      contents,
      mode: append ? FileMode.append : FileMode.write,
      flush: true,
    );
    return file;
  }

  /// Stages [paths], creates a commit, and returns its object id.
  Future<String> commit(
    String message, {
    List<String> paths = const ['.'],
  }) async {
    if (message.isEmpty) {
      throw ArgumentError.value(message, 'message', 'Must not be empty.');
    }
    if (paths.isEmpty) {
      throw ArgumentError.value(paths, 'paths', 'Must not be empty.');
    }

    await runGit(['add', '--', ...paths]);
    await runGit(['commit', '--message', message]);
    final result = await runGit(['rev-parse', 'HEAD']);
    return result.stdout.toString().trim();
  }

  /// Creates a local bare repository and adds it as [remoteName].
  ///
  /// The bare repository is owned by this fixture and is removed by [dispose].
  Future<Directory> createBareOrigin({String remoteName = 'origin'}) async {
    _validatePathComponent(remoteName, parameterName: 'remoteName');

    final remotesDirectory = Directory(_join(rootDirectory.path, 'remotes'));
    await remotesDirectory.create(recursive: true);
    final bareRepository = Directory(
      _join(remotesDirectory.path, '$remoteName.git'),
    );
    if (await bareRepository.exists()) {
      throw StateError('Remote "$remoteName" already exists.');
    }

    await runGit([
      'init',
      '--bare',
      '--initial-branch=$initialBranch',
      bareRepository.path,
    ], workingDirectory: rootDirectory);
    await runGit(['remote', 'add', remoteName, bareRepository.path]);
    return bareRepository;
  }

  /// Recursively removes this fixture and all bare repositories it owns.
  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    await _deleteIfPresent(rootDirectory);
  }

  Future<void> _configureIdentity() async {
    await runGit(['config', '--local', 'user.name', authorName]);
    await runGit(['config', '--local', 'user.email', authorEmail]);
    await runGit(['config', '--local', 'commit.gpgSign', 'false']);
  }

  void _ensureActive() {
    if (_isDisposed) {
      throw StateError('GitTestRepository has already been disposed.');
    }
  }

  static Map<String, String> _isolatedEnvironment(Directory home) {
    final environment = <String, String>{
      for (final entry in Platform.environment.entries)
        if (!entry.key.startsWith('GIT_')) entry.key: entry.value,
      'HOME': home.path,
      'USERPROFILE': home.path,
      'XDG_CONFIG_HOME': _join(home.path, '.config'),
      'GIT_CONFIG_GLOBAL': _join(home.path, '.gitconfig'),
      'GIT_CONFIG_NOSYSTEM': '1',
      'GIT_TERMINAL_PROMPT': '0',
      'GIT_AUTHOR_NAME': authorName,
      'GIT_AUTHOR_EMAIL': authorEmail,
      'GIT_COMMITTER_NAME': authorName,
      'GIT_COMMITTER_EMAIL': authorEmail,
      'LC_ALL': 'C',
    };
    return Map<String, String>.unmodifiable(environment);
  }

  static List<String> _validatedRelativePath(String path) {
    if (path.isEmpty || path.startsWith('/') || path.startsWith(r'\')) {
      throw ArgumentError.value(path, 'relativePath', 'Must be relative.');
    }
    if (RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path)) {
      throw ArgumentError.value(path, 'relativePath', 'Must be relative.');
    }

    final segments = path.replaceAll(r'\', '/').split('/');
    if (segments.any((segment) => segment == '..')) {
      throw ArgumentError.value(
        path,
        'relativePath',
        'Must remain inside the repository.',
      );
    }
    return segments.where((segment) => segment.isNotEmpty).toList();
  }

  static void _validateBranchName(String branchName) {
    if (branchName.isEmpty ||
        branchName.startsWith('-') ||
        branchName.contains(RegExp(r'[\s~^:?*\[\\]')) ||
        branchName.contains('..') ||
        branchName.contains('@{')) {
      throw ArgumentError.value(
        branchName,
        'initialBranch',
        'Must be a safe Git branch name.',
      );
    }
  }

  static void _validatePathComponent(
    String value, {
    required String parameterName,
  }) {
    if (value.isEmpty || !RegExp(r'^[a-zA-Z0-9._-]+$').hasMatch(value)) {
      throw ArgumentError.value(
        value,
        parameterName,
        'Must be one safe path component.',
      );
    }
  }

  static String _join(String parent, String child) =>
      '$parent${Platform.pathSeparator}$child';

  static String _joinAll(Iterable<String> components) =>
      components.join(Platform.pathSeparator);

  static Future<void> _deleteIfPresent(Directory directory) async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}

/// A failed Git invocation made by [GitTestRepository].
final class GitTestCommandException implements Exception {
  const GitTestCommandException({
    required this.arguments,
    required this.exitCode,
    required this.standardOutput,
    required this.standardError,
  });

  final List<String> arguments;
  final int exitCode;
  final String standardOutput;
  final String standardError;

  @override
  String toString() {
    final command = ['git', ...arguments].join(' ');
    return 'Git command failed with exit code $exitCode: $command\n'
        '$standardError';
  }
}
