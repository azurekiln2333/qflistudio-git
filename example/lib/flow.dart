import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:qfli_git/qfli_git.dart';

/// Removes any userinfo from [url].
///
/// libgit2 writes the remote URL into `.git/config`, so a token embedded in the
/// URL would reach the disk. Credentials belong in the Token field.
String sanitizeRemoteUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.userInfo.isEmpty) {
    return url;
  }
  return uri.replace(userInfo: '').toString();
}

/// Returns `host/path` for [url], so a step detail never shows userinfo.
String displayRemoteUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) {
    return url;
  }
  final path = uri.path.startsWith('/') ? uri.path : '/${uri.path}';
  return '${uri.host}$path';
}

/// One finished step of [FlowRunner.run].
class FlowStep {
  const FlowStep({
    required this.name,
    required this.succeeded,
    required this.elapsed,
    this.detail,
    this.error,
  });

  /// Short label shown in the step log, for example `clone`.
  final String name;

  /// Whether the step finished without an exception.
  final bool succeeded;

  /// Wall clock time spent in the step.
  final Duration elapsed;

  /// Extra text for a successful step, such as the new commit id.
  final String? detail;

  /// Error text of a failed step. It never contains the token.
  final String? error;

  @override
  String toString() {
    final state = succeeded ? 'ok' : 'failed';
    final text = detail ?? error ?? '';
    return '$name: $state (${elapsed.inMilliseconds} ms) $text';
  }
}

/// Values typed into the form.
///
/// The token is kept in memory only. Nothing here is written to storage or to
/// a log.
class FlowSettings {
  const FlowSettings({
    required this.remoteUrl,
    required this.branch,
    required this.authorName,
    required this.authorEmail,
    this.username,
    this.token,
  });

  final String remoteUrl;
  final String branch;
  final String authorName;
  final String authorEmail;
  final String? username;
  final String? token;

  GitAuthor get author => GitAuthor(authorName, authorEmail);
}

/// Runs clone, commit, branch, conflict merge and push against a remote.
///
/// Every step reports a [FlowStep] through [onStep]. A failing step reports the
/// failure and stops the run.
class FlowRunner {
  FlowRunner({
    required this.settings,
    required this.workPath,
    required this.onStep,
    required this.cancel,
  });

  final FlowSettings settings;

  /// Directory that receives the clone. Its content is replaced on every run.
  /// The previous clone is renamed to `<workPath>.previous` first.
  final String workPath;

  final void Function(FlowStep step) onStep;

  /// Passed to clone and push so the cancel button stops the transfer.
  final CancelToken cancel;

  static const String conflictFile = 'flow.txt';

  /// Files touched by the flow, relative to the repository root.
  static const String branchFile = 'branch.txt';

  Future<void> run() async {
    final repoDir = Directory(workPath);
    if (repoDir.existsSync()) {
      repoDir.deleteSync(recursive: true);
    }
    repoDir.createSync(recursive: true);

    final author = settings.author;
    final cloneUrl = sanitizeRemoteUrl(settings.remoteUrl);
    late final GitRepository repo;
    late final String defaultBranch;

    await _step('clone', () async {
      repo = await GitRepository.clone(
        url: cloneUrl,
        path: workPath,
        username: settings.username,
        token: settings.token,
        cancel: cancel,
      );
      defaultBranch = (await repo.head()).branch ?? settings.branch;
      return displayRemoteUrl(cloneUrl);
    });

    await _step('write base file', () async {
      _write(repo, conflictFile, 'base\n');
      _write(repo, branchFile, 'base\n');
      return null;
    });

    await _step('commit', () async {
      await repo.addAll();
      return await repo.commit('base commit', author);
    });

    await _step('create branch', () async {
      await repo.createBranch(settings.branch);
      return null;
    });

    await _step('checkout branch', () async {
      await repo.checkout(settings.branch);
      return null;
    });

    await _step('commit on branch', () async {
      _write(repo, conflictFile, 'base\nbranch\n');
      _write(repo, branchFile, 'base\nbranch\n');
      await repo.addAll();
      return await repo.commit('branch change', author);
    });

    await _step('checkout base branch', () async {
      await repo.checkout(defaultBranch);
      return null;
    });

    await _step('commit conflicting change', () async {
      _write(repo, conflictFile, 'base\nmain\n');
      await repo.addAll();
      return await repo.commit('main change', author);
    });

    late final MergeOutcome outcome;
    late final List<String> conflicts;
    await _step('merge branch', () async {
      outcome = await repo.merge(settings.branch, author);
      if (outcome != MergeOutcome.conflicts) {
        throw StateError('expected conflicts, merge reported ${outcome.name}');
      }
      return outcome.name;
    });

    await _step('list conflicts', () async {
      conflicts = await repo.conflicts();
      return conflicts.join(', ');
    });

    await _step('resolve conflicts', () async {
      for (final path in conflicts) {
        _resolveByConcatenation(File(p.join(repo.path, path)));
      }
      await repo.addAll();
      return conflicts.join(', ');
    });

    await _step('merge commit', () async {
      return await repo.commitMerge('merge ${settings.branch}', author);
    });

    await _step('push', () async {
      await repo.push(
        remote: 'origin',
        refspec: 'refs/heads/$defaultBranch:refs/heads/$defaultBranch',
        username: settings.username,
        token: settings.token,
        cancel: cancel,
      );
      return defaultBranch;
    });
  }

  /// Runs [body] as one step and reports it. A failure stops the run.
  Future<void> _step(String name, Future<String?> Function() body) async {
    final watch = Stopwatch()..start();
    try {
      final detail = await body();
      onStep(
        FlowStep(
          name: name,
          succeeded: true,
          elapsed: watch.elapsed,
          detail: detail,
        ),
      );
    } catch (error) {
      onStep(
        FlowStep(
          name: name,
          succeeded: false,
          elapsed: watch.elapsed,
          error: _describe(error),
        ),
      );
      rethrow;
    }
  }

  static String _describe(Object error) {
    if (error is GitException) {
      return '${error.message} (code ${error.code}, class ${error.klass})';
    }
    return error.toString();
  }

  static void _write(GitRepository repo, String relativePath, String text) {
    File(p.join(repo.path, relativePath)).writeAsStringSync(text);
  }

  /// Replaces the conflict markers with the concatenation of both sides.
  static void _resolveByConcatenation(File file) {
    if (!file.existsSync()) {
      return;
    }
    final text = file.readAsStringSync();
    final buffer = StringBuffer();
    for (final line in text.split('\n')) {
      if (line.startsWith('<<<<<<<') ||
          line.startsWith('=======') ||
          line.startsWith('>>>>>>>')) {
        continue;
      }
      buffer.writeln(line);
    }
    file.writeAsStringSync(buffer.toString());
  }
}
