import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qfli_git/qfli_git.dart';
import 'package:qfli_git/src/library.dart';

/// End-to-end checks against the real `libqfli_git` shared library.
///
/// The CI job builds the host library and exports [qfliGitLibraryVariable].
/// Without that variable there is no library to exercise, so every test here
/// fails instead of being skipped. A missing artifact never passes CI.
void main() {
  final libraryPath = Platform.environment[qfliGitLibraryVariable];
  final missingLibrary = libraryPath == null || libraryPath.isEmpty;
  final libraryFileMissing = !missingLibrary && !File(libraryPath).existsSync();

  late Directory root;

  setUpAll(() async {
    // Fail fast so a missing artifact is reported once, with a clear message.
    if (missingLibrary) {
      fail(
        '$qfliGitLibraryVariable is not set. Build the host library first, '
        'for example with tool/ci/build_native.sh --platform host.',
      );
    }
    if (libraryFileMissing) {
      fail('$qfliGitLibraryVariable points at a missing file: $libraryPath');
    }
    root = await Directory.systemTemp.createTemp('qfli_git_native_');
  });

  tearDownAll(() async {
    if (root.existsSync()) {
      await root.delete(recursive: true);
    }
  });

  const author = GitAuthor('Native Test', 'native@qfli.invalid');

  test('reports the API version the bindings expect', () {
    // QfliGit.ensureInitialized needs path_provider and rootBundle, which a
    // host test does not have. Repository calls pass a null CA file instead,
    // which is enough for local repositories.
    expect(QfliGit.apiVersion, qgApiVersion);
    expect(QfliGit.libgit2Version, isNotEmpty);
  });

  test('stages, unstages and commits through the native API', () async {
    final path = '${root.path}/basic';
    await GitRepository.init(path);
    final repo = GitRepository.open(path);

    await File('$path/a.txt').writeAsString('one\n');
    await File('$path/b.txt').writeAsString('bee\n');
    await repo.stagePaths(['a.txt', 'b.txt']);

    final staged = await repo.status();
    expect(
      staged.where((entry) => entry.status.startsWith('index_')),
      isNotEmpty,
    );

    final oid = await repo.commit('initial commit', author);
    expect(oid, matches(RegExp(r'^[0-9a-f]{40}$')));

    await File('$path/a.txt').writeAsString('two\n');
    await repo.stagePaths(['a.txt']);
    await repo.unstagePaths(['a.txt']);

    expect(await File('$path/a.txt').readAsString(), 'two\n');

    final head = await repo.head();
    expect(head.oid, oid);
    expect(head.state, 'clean');
  });

  test('an unborn repository reports an empty history', () async {
    final path = '${root.path}/unborn';
    await GitRepository.init(path);
    final repo = GitRepository.open(path);

    expect(await repo.log(), isEmpty);
    expect(await repo.branches(), isEmpty);

    final head = await repo.head();
    expect(head.oid, isEmpty);
    expect(head.state, 'clean');
  });

  test('a diff with no changes is an empty patch object', () async {
    final path = '${root.path}/empty-diff';
    await GitRepository.init(path);
    final repo = GitRepository.open(path);

    await File('$path/a.txt').writeAsString('one\n');
    await repo.addAll();
    await repo.commit('only commit', author);

    final staged = await repo.diff(staged: true);
    expect(staged.isEmpty, isTrue);
    expect(staged.patch, isEmpty);
    expect(staged.binary, isFalse);
    expect(staged.truncated, isFalse);

    final worktree = await repo.diff();
    expect(worktree.isEmpty, isTrue);
    expect(worktree.binary, isFalse);
    expect(worktree.truncated, isFalse);
  });

  test('a modified file shows removal, addition and context lines', () async {
    final path = '${root.path}/modify';
    await GitRepository.init(path);
    final repo = GitRepository.open(path);

    await File('$path/a.txt').writeAsString('old\n');
    await repo.addAll();
    await repo.commit('base', author);

    await File('$path/a.txt').writeAsString('new\n');

    final worktree = await repo.diff(path: 'a.txt');
    expect(worktree.binary, isFalse);
    expect(worktree.patch, contains('diff --git a/a.txt b/a.txt'));
    expect(worktree.patch, contains('--- a/a.txt'));
    expect(worktree.patch, contains('+++ b/a.txt'));
    expect(worktree.patch, contains('\n-old'));
    expect(worktree.patch, contains('\n+new'));

    await repo.stagePaths(['a.txt']);
    final staged = await repo.diff(path: 'a.txt', staged: true);
    expect(staged.patch, contains('\n-old'));
    expect(staged.patch, contains('\n+new'));
    expect(staged.patch, contains('@@'));

    // Context lines must keep their leading space, the origin byte libgit2
    // omits from git_diff_line.content.
    await File('$path/a.txt').writeAsString('top\nmiddle\nbottom\n');
    await repo.stagePaths(['a.txt']);
    await repo.commit('three lines', author);
    await File('$path/a.txt').writeAsString('top\nchanged\nbottom\n');

    final contextual = await repo.diff(path: 'a.txt');
    expect(contextual.patch, contains('\n top\n'));
    expect(contextual.patch, contains('\n-middle'));
    expect(contextual.patch, contains('\n+changed'));
    expect(contextual.patch, contains('\n bottom\n'));
  });

  test(
    'an untracked file contributes its content to the worktree diff',
    () async {
      final path = '${root.path}/untracked';
      await GitRepository.init(path);
      final repo = GitRepository.open(path);

      await File('$path/seed.txt').writeAsString('seed\n');
      await repo.addAll();
      await repo.commit('seed', author);

      await File('$path/fresh.txt').writeAsString('hello\n');

      final diff = await repo.diff(path: 'fresh.txt');
      expect(diff.binary, isFalse);
      expect(diff.patch, contains('fresh.txt'));
      expect(diff.patch, contains('\n+hello'));
    },
  );

  test('multiple files produce one patch body with every file', () async {
    final path = '${root.path}/multi';
    await GitRepository.init(path);
    final repo = GitRepository.open(path);

    await File('$path/a.txt').writeAsString('a1\n');
    await File('$path/b.txt').writeAsString('b1\n');
    await repo.addAll();
    await repo.commit('base', author);

    await File('$path/a.txt').writeAsString('a2\n');
    await File('$path/b.txt').writeAsString('b2\n');

    // Worktree changes are unstaged here, so this diff sees both files.
    final worktree = await repo.diff(maxBytes: 65536);
    expect(worktree.binary, isFalse);
    expect(worktree.truncated, isFalse);
    expect(worktree.patch, contains('-a1'));
    expect(worktree.patch, contains('+a2'));
    expect(worktree.patch, contains('-b1'));
    expect(worktree.patch, contains('+b2'));
    expect('diff --git'.allMatches(worktree.patch), hasLength(2));

    // Staging both files moves the same change to the index diff.
    await repo.stagePaths(['a.txt', 'b.txt']);
    expect((await repo.diff()).isEmpty, isTrue);

    final staged = await repo.diff(staged: true, maxBytes: 65536);
    expect(staged.truncated, isFalse);
    expect(staged.patch, contains('-a1'));
    expect(staged.patch, contains('+a2'));
    expect(staged.patch, contains('-b1'));
    expect(staged.patch, contains('+b2'));
    expect('diff --git'.allMatches(staged.patch), hasLength(2));
  });

  test('a binary file is labelled and omits its content', () async {
    final path = '${root.path}/binary';
    await GitRepository.init(path);
    final repo = GitRepository.open(path);

    await File('$path/bin.dat').writeAsBytes([0x61, 0x00, 0x62, 0x00, 0x0a]);
    await repo.stagePaths(['bin.dat']);

    final diff = await repo.diff(path: 'bin.dat', staged: true);
    expect(diff.binary, isTrue);
    expect(diff.patch, contains('bin.dat'));
  });

  test('a small byte bound truncates the patch and the flag says so', () async {
    final path = '${root.path}/bound';
    await GitRepository.init(path);
    final repo = GitRepository.open(path);

    final buffer = StringBuffer();
    for (var line = 0; line < 300; line++) {
      buffer.writeln('line $line abcdefghijklmnopqrstuvwxyz');
    }
    await File('$path/big.txt').writeAsString(buffer.toString());
    await repo.stagePaths(['big.txt']);

    final diff = await repo.diff(path: 'big.txt', staged: true, maxBytes: 256);
    expect(diff.truncated, isTrue);
    expect(diff.patch.length, lessThanOrEqualTo(256));
    expect(diff.patch, contains('diff --git'));

    final whole = await repo.diff(
      path: 'big.txt',
      staged: true,
      maxBytes: 1 << 20,
    );
    expect(whole.truncated, isFalse);
    expect(whole.patch.length, greaterThan(diff.patch.length));
    expect(whole.patch, contains('\n+line 299 abcdefghijklmnopqrstuvwxyz'));
  });

  test('rejects a remote URL that embeds credentials', () async {
    final path = '${root.path}/remote';
    await GitRepository.init(path);
    final repo = GitRepository.open(path);

    await expectLater(
      () =>
          repo.setRemote('origin', 'https://user:secret@example.com/repo.git'),
      throwsA(isA<GitException>().having((e) => e.code, 'code', qgEInvalid)),
    );
    await expectLater(
      () => repo.setRemote('origin', 'ftp://example.com/repo.git'),
      throwsA(isA<GitException>()),
    );

    await repo.setRemote('origin', 'https://example.com/repo.git');
    final remotes = await repo.remotes();
    expect(remotes, hasLength(1));
    expect(remotes.single.name, 'origin');
    expect(remotes.single.url, 'https://example.com/repo.git');
    expect(remotes.single.url, isNot(contains('@')));
  });

  test('branches and log carry the metadata the UI renders', () async {
    final path = '${root.path}/history';
    await GitRepository.init(path);
    final repo = GitRepository.open(path);

    await File('$path/a.txt').writeAsString('one\n');
    await repo.addAll();
    final first = await repo.commit('first commit', author);

    await File('$path/a.txt').writeAsString('two\n');
    await repo.addAll();
    final second = await repo.commit('second commit', author);

    final log = await repo.log(limit: 10);
    expect(log.map((commit) => commit.oid), [second, first]);
    expect(log.first.message, 'second commit');
    expect(log.first.authorName, 'Native Test');
    expect(log.first.authorEmail, 'native@qfli.invalid');
    expect(log.first.time.isUtc, isTrue);

    final branches = await repo.branches();
    expect(branches, hasLength(1));
    expect(branches.single.current, isTrue);
    expect(branches.single.remote, isFalse);
  });
}
