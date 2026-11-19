import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:qfli_git/qfli_git.dart';

/// Exercises the local part of the plugin without any network access.
///
/// A seeded repository stands in for the upstream host. The plugin clones it,
/// commits, branches, merges with a conflict, commits the merge and pushes into
/// a bare repository.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const author = GitAuthor('Qfli Test', 'test@example.com');

  late Directory root;
  late String sourcePath;
  late String barePath;
  late String workPath;

  setUpAll(() async {
    await QfliGit.ensureInitialized();
    root = await _freshDirectory('qfli_git_flow_test');
    sourcePath = p.join(root.path, 'source');
    barePath = p.join(root.path, 'remote.git');
    workPath = p.join(root.path, 'work');

    // The source repository holds the first commit, so the clone has content
    // and a default branch.
    final source = await GitRepository.init(sourcePath);
    File(p.join(source.path, 'flow.txt')).writeAsStringSync('base\n');
    await source.addAll();
    await source.commit('base commit', author);

    await GitRepository.init(barePath, bare: true);
  });

  tearDownAll(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  testWidgets('clone, branch, conflict merge, merge commit, push', (
    WidgetTester tester,
  ) async {
    final repo = await GitRepository.clone(url: sourcePath, path: workPath);

    final baseHead = await repo.head();
    expect(baseHead.branch, isNotNull);
    final mainBranch = baseHead.branch!;
    expect(baseHead.state, 'clean');

    // Cut the feature branch from the clone, so the two histories diverge and
    // the merge below has to be a real three way merge.
    await repo.createBranch('feature');
    await repo.checkout('feature');

    File(p.join(repo.path, 'flow.txt')).writeAsStringSync('base\nfeature\n');
    File(p.join(repo.path, 'branch.txt')).writeAsStringSync('base\nfeature\n');
    await repo.addAll();
    final featureCommit = await repo.commit('feature change', author);
    expect(featureCommit, hasLength(40));

    await repo.checkout(mainBranch);

    File(p.join(repo.path, 'flow.txt')).writeAsStringSync('base\nmain\n');
    await repo.addAll();
    final mainCommit = await repo.commit('main change', author);
    expect(mainCommit, isNot(featureCommit));

    final outcome = await repo.merge('feature', author);
    expect(outcome, MergeOutcome.conflicts);

    final mergeHead = await repo.head();
    expect(mergeHead.state, 'merge');

    final conflicts = await repo.conflicts();
    expect(conflicts, contains('flow.txt'));
    expect(conflicts, isNot(contains('branch.txt')));

    final conflicted = File(p.join(repo.path, 'flow.txt')).readAsStringSync();
    expect(conflicted, contains('<<<<<<<'));
    expect(conflicted, contains('>>>>>>>'));

    _resolveByConcatenation(File(p.join(repo.path, 'flow.txt')));
    final resolved = File(p.join(repo.path, 'flow.txt')).readAsStringSync();
    expect(resolved, contains('main'));
    expect(resolved, contains('feature'));
    expect(resolved, isNot(contains('<<<<<<<')));
    await repo.addAll();
    expect(await repo.conflicts(), isEmpty);

    final mergeCommit = await repo.commitMerge('merge feature', author);
    expect(mergeCommit, hasLength(40));

    final mergedHead = await repo.head();
    expect(mergedHead.oid, mergeCommit);
    expect(mergedHead.state, 'clean');

    final status = await repo.status();
    expect(status, isEmpty);

    _addRemote(File(p.join(repo.path, '.git', 'config')), 'bare', barePath);
    await repo.push(
      remote: 'bare',
      refspec: 'refs/heads/$mainBranch:refs/heads/$mainBranch',
    );

    final remote = GitRepository.open(barePath);
    final remoteHead = await remote.head();
    expect(remoteHead.oid, mergeCommit);
  });
}

/// Replaces conflict markers with the concatenation of both sides.
void _resolveByConcatenation(File file) {
  final buffer = StringBuffer();
  for (final line in file.readAsStringSync().split('\n')) {
    if (line.startsWith('<<<<<<<') ||
        line.startsWith('=======') ||
        line.startsWith('>>>>>>>')) {
      continue;
    }
    buffer.writeln(line);
  }
  file.writeAsStringSync(buffer.toString());
}

/// Adds a fetchable remote pointing at [url] to an existing repository.
void _addRemote(File config, String name, String url) {
  final current = config.readAsStringSync();
  config.writeAsStringSync(
    '$current[remote "$name"]\n'
    '\turl = ${url.replaceAll(r'\', '/')}\n'
    '\tfetch = +refs/heads/*:refs/heads/*\n',
  );
}

/// Returns an empty directory under the app cache directory.
Future<Directory> _freshDirectory(String name) async {
  final cache = await getTemporaryDirectory();
  final directory = Directory(p.join(cache.path, name));
  if (directory.existsSync()) {
    directory.deleteSync(recursive: true);
  }
  directory.createSync(recursive: true);
  return directory;
}
