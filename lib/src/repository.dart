import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'bindings.dart';
import 'library.dart';

/// Clone stages measured by libgit2.
enum GitCloneStage { receiving, resolving, checkout }

/// Numeric progress for one clone operation. No remote or file paths are sent.
class GitCloneProgress {
  const GitCloneProgress({
    required this.stage,
    this.completed = 0,
    this.total = 0,
    this.receivedBytes = 0,
  });

  final GitCloneStage stage;
  final int completed;
  final int total;
  final int receivedBytes;

  double? get fraction =>
      total <= 0 ? null : (completed / total).clamp(0.0, 1.0);
}

/// Author identity stored in new commits and merge commits.
class GitAuthor {
  const GitAuthor(this.name, this.email);

  final String name;
  final String email;

  @override
  String toString() => '$name <$email>';
}

/// Result of [GitRepository.merge].
enum MergeOutcome {
  /// The merged branch is already contained in HEAD.
  upToDate,

  /// HEAD moved forward without a merge commit.
  fastForward,

  /// A merge commit was created.
  merged,

  /// The merge stopped with conflicts in the index and the work tree.
  conflicts;

  /// Maps the `out_result` value of `qg_merge`.
  static MergeOutcome fromCode(int code) {
    switch (code) {
      case 0:
        return upToDate;
      case 1:
        return fastForward;
      case 2:
        return merged;
      case 3:
        return conflicts;
      default:
        throw GitException(qgEInvalid, 0, 'unknown merge result $code');
    }
  }
}

/// One entry of [GitRepository.status].
class GitStatusEntry {
  const GitStatusEntry({
    required this.path,
    required this.status,
    this.statusBits = 0,
  });

  final String path;

  /// Status text reported by the native layer, for example `modified`.
  ///
  /// It is the highest set bit of [statusBits] as text.
  final String status;

  /// Raw `git_status_t` bit mask of the entry, for example `256`.
  ///
  /// Use it to test several states at once, for example
  /// `entry.statusBits & 256 != 0` for a modified work tree.
  final int statusBits;

  factory GitStatusEntry.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('expected a status object');
    }
    final path = json['path'];
    if (path is! String) {
      throw const FormatException('status entry without a path');
    }
    final status = json['status'];
    final bits = json['status_bits'];
    return GitStatusEntry(
      path: path,
      status: status is String ? status : '',
      statusBits: bits is int ? bits : 0,
    );
  }

  @override
  String toString() => '$status $path';
}

/// Snapshot of HEAD, as reported by [GitRepository.head].
class GitHead {
  const GitHead({required this.branch, required this.oid, required this.state});

  /// Current branch, or null when HEAD is detached.
  final String? branch;

  /// Full hexadecimal commit id.
  final String oid;

  /// Repository state text: `clean` when no operation is in progress,
  /// `merge` while a merge is open, and other libgit2 state names otherwise.
  final String state;

  factory GitHead.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('expected a head object');
    }
    final oid = json['oid'];
    if (oid is! String) {
      throw const FormatException('head object without an oid');
    }
    final branch = json['branch'];
    final state = json['state'];
    return GitHead(
      branch: branch is String && branch.isNotEmpty ? branch : null,
      oid: oid,
      state: state is String ? state : '',
    );
  }

  @override
  String toString() => '${branch ?? '(detached)'} $oid $state';
}

/// A patch returned by [GitRepository.diff].
class GitDiff {
  const GitDiff({this.patch = '', this.binary = false, this.truncated = false});

  /// Unified diff text, empty for a binary or empty change.
  final String patch;

  /// The native layer treated the file as binary and omitted its content.
  final bool binary;

  /// The patch was cut at the requested byte bound.
  final bool truncated;

  /// Whether there is nothing to show.
  bool get isEmpty => patch.isEmpty;

  factory GitDiff.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('expected a diff object');
    }
    final patch = json['patch'];
    if (patch != null && patch is! String) {
      throw const FormatException('diff patch is not a string');
    }
    return GitDiff(
      patch: patch is String ? patch : '',
      binary: json['binary'] == true,
      truncated: json['truncated'] == true,
    );
  }

  @override
  String toString() =>
      'GitDiff(${patch.length} bytes, binary: $binary, truncated: $truncated)';
}

/// One commit returned by [GitRepository.log].
class GitCommit {
  const GitCommit({
    required this.oid,
    required this.message,
    required this.authorName,
    required this.authorEmail,
    required this.time,
  });

  /// Full hexadecimal commit id.
  final String oid;

  /// Commit message without the trailing newline libgit2 stores.
  final String message;

  final String authorName;
  final String authorEmail;

  /// Author time in UTC.
  final DateTime time;

  factory GitCommit.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('expected a commit object');
    }
    final oid = json['oid'];
    if (oid is! String || oid.isEmpty) {
      throw const FormatException('commit object without an oid');
    }
    final time = json['time'];
    if (time is! num) {
      throw const FormatException('commit object without a numeric time');
    }
    final message = json['message'];
    final authorName = json['authorName'];
    final authorEmail = json['authorEmail'];
    return GitCommit(
      oid: oid,
      message: message is String ? message : '',
      authorName: authorName is String ? authorName : '',
      authorEmail: authorEmail is String ? authorEmail : '',
      time: DateTime.fromMillisecondsSinceEpoch(
        (time * 1000).round(),
        isUtc: true,
      ),
    );
  }

  @override
  String toString() => '$oid ${message.split('\n').first}';
}

/// One local or remote branch returned by [GitRepository.branches].
class GitBranch {
  const GitBranch({
    required this.name,
    this.current = false,
    this.remote = false,
    this.upstream,
  });

  /// Branch name without a `refs/heads/` prefix.
  final String name;

  /// Whether this is the checked-out branch.
  final bool current;

  /// Whether this is a remote tracking branch.
  final bool remote;

  /// Configured upstream branch for a local branch, or null.
  final String? upstream;

  factory GitBranch.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('expected a branch object');
    }
    final name = json['name'];
    if (name is! String || name.isEmpty) {
      throw const FormatException('branch object without a name');
    }
    final upstream = json['upstream'];
    return GitBranch(
      name: name,
      current: json['current'] == true,
      remote: json['remote'] == true,
      upstream: upstream is String && upstream.isNotEmpty ? upstream : null,
    );
  }

  @override
  String toString() =>
      '${remote ? 'refs/remotes/' : ''}$name${current ? ' (current)' : ''}';
}

/// One configured remote returned by [GitRepository.remotes].
class GitRemote {
  const GitRemote({required this.name, required this.url});

  final String name;
  final String url;

  factory GitRemote.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('expected a remote object');
    }
    final name = json['name'];
    if (name is! String || name.isEmpty) {
      throw const FormatException('remote object without a name');
    }
    final url = json['url'];
    return GitRemote(name: name, url: url is String ? url : '');
  }

  @override
  String toString() => '$name $url';
}

/// Failure reported by the native layer.
class GitException implements Exception {
  const GitException(this.code, this.klass, this.message);

  /// libgit2 error code, or one of `qgECanceled`, `qgEConflict`, `qgEInvalid`.
  final int code;

  /// `git_error_t` class, or 0 when the failure came from `qfli_git.c`.
  final int klass;

  /// UTF-8 message text. It never contains credentials.
  final String message;

  factory GitException.fromNative(NativeError error) =>
      GitException(error.code, error.klass, error.message);

  /// Whether the operation stopped because its [CancelToken] was canceled.
  bool get isCanceled => code == qgECanceled;

  /// Whether a merge commit was refused because conflicts remain.
  bool get isConflict => code == qgEConflict;

  @override
  String toString() => 'GitException($code, klass $klass): $message';
}

/// Cancels a running network operation.
///
/// The token owns a native `int32_t`. Pass its address to a background isolate
/// so [cancel] affects the running operation from the UI isolate.
///
/// [dispose] does not free the flag while an operation still reads it. The
/// last [releaseOperation] frees it.
class CancelToken {
  CancelToken() {
    // malloc leaves the value undefined, so clear it before the first call.
    _flag.value = 0;
  }

  Pointer<Int32> _flag = malloc<Int32>();
  int _pending = 0;
  bool _releaseRequested = false;

  /// Number of operations that still hold the native flag.
  @visibleForTesting
  int get pendingOperations => _pending;

  /// Marks an operation as started and returns the flag address.
  ///
  /// [GitRepository] calls it before clone, fetch and push. Tests use it to
  /// simulate a running operation without native code.
  @visibleForTesting
  int acquireOperation() {
    final flag = _flag;
    if (flag == nullptr) {
      throw StateError('CancelToken has been disposed.');
    }
    _pending++;
    return flag.address;
  }

  /// Marks one operation as finished.
  ///
  /// When [dispose] was already called and this was the last operation, the
  /// flag is freed now. Tests use it to end a simulated operation.
  @visibleForTesting
  void releaseOperation() {
    assert(_pending > 0, 'releaseOperation without a running operation');
    if (_pending == 0) {
      return;
    }
    _pending--;
    if (_pending == 0 && _releaseRequested) {
      _freeFlag();
    }
  }

  /// Asks the running operation to stop.
  void cancel() {
    final flag = _flag;
    if (flag == nullptr) {
      return;
    }
    flag.value = 1;
  }

  /// Releases the native flag.
  ///
  /// A running operation still reads the flag, so the free is deferred until
  /// the last [releaseOperation]. [cancel] keeps working until then.
  void dispose() {
    if (_flag == nullptr) {
      return;
    }
    _releaseRequested = true;
    if (_pending == 0) {
      _freeFlag();
    }
  }

  void _freeFlag() {
    final flag = _flag;
    if (flag == nullptr) {
      return;
    }
    flag.value = 0;
    malloc.free(flag);
    _flag = nullptr;
    _releaseRequested = false;
  }
}

/// Parses `qg_conflicts_json` output, which is `["path", ...]`.
List<String> parseConflictPaths(String source) {
  final decoded = jsonDecode(source);
  if (decoded == null) {
    return const <String>[];
  }
  if (decoded is! List) {
    throw const FormatException('expected a JSON array of conflict paths');
  }
  final paths = <String>[];
  for (final entry in decoded) {
    if (entry is! String) {
      throw const FormatException('conflict entry is not a path string');
    }
    paths.add(entry);
  }
  return paths;
}

/// Parses `qg_status_json` output, which is `[{"path":..,"status":..}, ...]`.
List<GitStatusEntry> parseStatusEntries(String source) {
  final decoded = jsonDecode(source);
  if (decoded == null) {
    return const <GitStatusEntry>[];
  }
  if (decoded is! List) {
    throw const FormatException('expected a JSON array of status entries');
  }
  return [for (final entry in decoded) GitStatusEntry.fromJson(entry)];
}

/// Parses `qg_head_json` output, which is `{"branch":..,"oid":..,"state":..}`.
GitHead parseHead(String source) {
  final decoded = jsonDecode(source);
  if (decoded == null) {
    throw const FormatException('head JSON is empty');
  }
  return GitHead.fromJson(decoded);
}

/// Parses `qg_diff_json` output, which is
/// `{"patch":..,"binary":..,"truncated":..}`.
GitDiff parseDiff(String source) {
  final decoded = jsonDecode(source);
  if (decoded == null) {
    throw const FormatException('diff JSON is empty');
  }
  return GitDiff.fromJson(decoded);
}

/// Parses `qg_log_json` output, an array of commit objects.
List<GitCommit> parseLog(String source) {
  final decoded = jsonDecode(source);
  if (decoded == null) {
    return const <GitCommit>[];
  }
  if (decoded is! List) {
    throw const FormatException('expected a JSON array of commits');
  }
  return [for (final entry in decoded) GitCommit.fromJson(entry)];
}

/// Parses `qg_branches_json` output, an array of branch objects.
List<GitBranch> parseBranches(String source) {
  final decoded = jsonDecode(source);
  if (decoded == null) {
    return const <GitBranch>[];
  }
  if (decoded is! List) {
    throw const FormatException('expected a JSON array of branches');
  }
  return [for (final entry in decoded) GitBranch.fromJson(entry)];
}

/// Parses `qg_remotes_json` output, an array of remote objects.
List<GitRemote> parseRemotes(String source) {
  final decoded = jsonDecode(source);
  if (decoded == null) {
    return const <GitRemote>[];
  }
  if (decoded is! List) {
    throw const FormatException('expected a JSON array of remotes');
  }
  return [for (final entry in decoded) GitRemote.fromJson(entry)];
}

/// Entry point of the plugin.
class QfliGit {
  QfliGit._();

  static const String _caAssetKey = 'packages/qfli_git/assets/cacert.pem';
  static const String _caFileName = 'cacert.pem';

  static String? _caFile;
  static Future<void>? _initializing;

  /// Absolute path of the CA bundle written by [ensureInitialized].
  ///
  /// The foreground installs certificates once before repository workers run.
  static String? get caFile => _caFile;

  /// Copies the bundled CA certificates to the application support directory
  /// and initializes the native layer.
  ///
  /// Call it once before the first repository operation. Repeated calls do
  /// nothing.
  static Future<void> ensureInitialized() {
    if (_caFile != null) {
      return Future<void>.value();
    }
    return _initializing ??= _prepareCertificates().whenComplete(() {
      _initializing = null;
    });
  }

  static Future<void> _prepareCertificates() async {
    final data = await rootBundle.load(_caAssetKey);
    final directory = await getApplicationSupportDirectory();
    final file = File(p.join(directory.path, _caFileName));
    await file.parent.create(recursive: true);
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    await file.writeAsBytes(bytes, flush: true);
    final path = file.absolute.path;
    _initNative(path);
    _caFile = path;
  }

  /// libgit2 version reported by the native library, for example `1.9.7`.
  static String get libgit2Version =>
      QfliGitBindings(openQfliGitLibrary()).libgit2Version();

  /// mbedTLS version reported by the native library, for example `3.6.5`.
  static String get mbedtlsVersion =>
      QfliGitBindings(openQfliGitLibrary()).mbedtlsVersion();

  /// API version of the native library. The plugin expects [qgApiVersion].
  static int get apiVersion =>
      QfliGitBindings(openQfliGitLibrary()).apiVersion();

  static void _initNative(String caFile) {
    final bindings = QfliGitBindings(openQfliGitLibrary());
    Pointer<QgError> error = nullptr;
    Pointer<Utf8> caFilePointer = nullptr;
    try {
      error = calloc<QgError>();
      caFilePointer = caFile.toNativeUtf8();
      final code = bindings.init(caFilePointer, error);
      if (code != 0) {
        throw GitException.fromNative(NativeError.read(error, code));
      }
      bindings.checkApiVersion();
    } finally {
      if (caFilePointer != nullptr) {
        malloc.free(caFilePointer);
      }
      if (error != nullptr) {
        calloc.free(error);
      }
    }
  }
}

/// A repository reached through the native library.
///
/// Only [path] crosses isolate boundaries. The native handle is opened and
/// freed inside the isolate that runs each operation.
class GitRepository {
  GitRepository._(this.path);

  /// Absolute path of the repository, or of the clone target.
  final String path;

  /// Clones [url] into [path] and returns the opened repository.
  static Future<GitRepository> clone({
    required String url,
    required String path,
    String? username,
    String? token,
    CancelToken? cancel,
    void Function(GitCloneProgress progress)? onProgress,
  }) async {
    final cloneUrl = _validateRemoteUrl(url);
    final target = _absolute(path);
    final cancelAddress = cancel?.acquireOperation();
    final receivePort = onProgress == null ? null : ReceivePort();
    final drained = Completer<void>();
    receivePort?.listen((event) {
      if (event == null) {
        if (!drained.isCompleted) drained.complete();
        return;
      }
      if (event is! List<int> || event.length != 4) return;
      final stage = switch (event[0]) {
        1 => GitCloneStage.receiving,
        2 => GitCloneStage.resolving,
        3 => GitCloneStage.checkout,
        _ => null,
      };
      if (stage == null) return;
      try {
        onProgress?.call(
          GitCloneProgress(
            stage: stage,
            completed: event[1],
            total: event[2],
            receivedBytes: event[3],
          ),
        );
      } on Object {
        // Observers cannot change the operation result.
      }
    });
    try {
      final result = await _runCloneIsolate(
        cloneUrl,
        target,
        username,
        token,
        cancelAddress,
        receivePort?.sendPort,
      );
      if (receivePort != null) await drained.future;
      return result;
    } finally {
      receivePort?.close();
      cancel?.releaseOperation();
    }
  }

  /// Creates a repository at [path].
  static Future<GitRepository> init(String path, {bool bare = false}) {
    final target = _absolute(path);
    final caFile = QfliGit.caFile;
    return Isolate.run(() {
      final bindings = QfliGitBindings(openQfliGitLibrary());
      Pointer<QgError> error = nullptr;
      Pointer<Pointer<QgRepo>> out = nullptr;
      try {
        error = calloc<QgError>();
        out = calloc<Pointer<QgRepo>>();
        bindings.checkApiVersion();
        _initIfNeeded(bindings, caFile, error);
        return _withUtf8([target], (values) {
          final code = bindings.repoInit(values[0], bare ? 1 : 0, out, error);
          if (code != 0) {
            throw GitException.fromNative(NativeError.read(error, code));
          }
          final repo = out.value;
          if (repo == nullptr) {
            throw const GitException(
              qgEInvalid,
              0,
              'qg_repo_init returned no handle',
            );
          }
          bindings.repoFree(repo);
          return GitRepository._(target);
        });
      } finally {
        if (out != nullptr) {
          calloc.free(out);
        }
        if (error != nullptr) {
          calloc.free(error);
        }
      }
    });
  }

  /// Describes the repository at [path] without touching the native layer.
  static GitRepository open(String path) => GitRepository._(_absolute(path));

  /// Stages every change, including deletions. Equivalent to `git add -A`.
  Future<void> addAll() {
    final repoPath = path;
    final caFile = QfliGit.caFile;
    return Isolate.run(
      () => _withRepo(repoPath, caFile, (session) {
        session.check(session.bindings.addAll(session.repo, session.error));
      }),
    );
  }

  /// Stages exactly [paths].
  ///
  /// Paths are repository-relative and use forward slashes. The native layer
  /// validates each path before touching the index, so wildcards and traversal
  /// are rejected instead of being expanded.
  Future<void> stagePaths(List<String> paths) {
    final repoPath = path;
    final caFile = QfliGit.caFile;
    final entries = List<String>.of(paths);
    return Isolate.run(
      () => _withRepo(repoPath, caFile, (session) {
        _withUtf8Array(entries, (values, count) {
          session.check(
            session.bindings.stagePaths(
              session.repo,
              values,
              count,
              session.error,
            ),
          );
        });
      }),
    );
  }

  /// Removes exactly [paths] from the index, restoring the HEAD version.
  ///
  /// Paths without a HEAD entry are dropped from the index, which also covers
  /// newly added files on an unborn branch.
  Future<void> unstagePaths(List<String> paths) {
    final repoPath = path;
    final caFile = QfliGit.caFile;
    final entries = List<String>.of(paths);
    return Isolate.run(
      () => _withRepo(repoPath, caFile, (session) {
        _withUtf8Array(entries, (values, count) {
          session.check(
            session.bindings.unstagePaths(
              session.repo,
              values,
              count,
              session.error,
            ),
          );
        });
      }),
    );
  }

  /// Commits the index and returns the new commit id.
  Future<String> commit(String message, GitAuthor author) {
    final repoPath = path;
    final caFile = QfliGit.caFile;
    final name = author.name;
    final email = author.email;
    return Isolate.run(
      () => _withRepo(repoPath, caFile, (session) {
        return _withUtf8([message, name, email], (values) {
          return _withOid((oid) {
            session.check(
              session.bindings.commit(
                session.repo,
                values[0],
                values[1],
                values[2],
                oid,
                session.error,
              ),
            );
            return readUtf8(oid, qgOidBufferBytes);
          });
        });
      }),
    );
  }

  /// Creates [name], optionally starting at [from]. Defaults to HEAD.
  Future<void> createBranch(String name, {String? from}) {
    final repoPath = path;
    final caFile = QfliGit.caFile;
    return Isolate.run(
      () => _withRepo(repoPath, caFile, (session) {
        _withUtf8([name, from], (values) {
          session.check(
            session.bindings.branchCreate(
              session.repo,
              values[0],
              values[1],
              session.error,
            ),
          );
        });
      }),
    );
  }

  /// Checks out [name]. Fails instead of overwriting local changes.
  Future<void> checkout(String name) {
    final repoPath = path;
    final caFile = QfliGit.caFile;
    return Isolate.run(
      () => _withRepo(repoPath, caFile, (session) {
        _withUtf8([name], (values) {
          session.check(
            session.bindings.checkoutBranch(
              session.repo,
              values[0],
              session.error,
            ),
          );
        });
      }),
    );
  }

  /// Merges [branch] into HEAD.
  ///
  /// [MergeOutcome.conflicts] means the index and work tree hold the conflicts
  /// and `MERGE_HEAD` is written. Resolve them, then call [commitMerge].
  Future<MergeOutcome> merge(String branch, GitAuthor author) {
    final repoPath = path;
    final caFile = QfliGit.caFile;
    final name = author.name;
    final email = author.email;
    return Isolate.run(
      () => _withRepo(repoPath, caFile, (session) {
        final result = calloc<Int32>();
        try {
          return _withUtf8([branch, name, email], (values) {
            return _withOid((oid) {
              session.check(
                session.bindings.merge(
                  session.repo,
                  values[0],
                  values[1],
                  values[2],
                  result,
                  oid,
                  session.error,
                ),
              );
              return MergeOutcome.fromCode(result.value);
            });
          });
        } finally {
          calloc.free(result);
        }
      }),
    );
  }

  /// Lists the paths that still need conflict resolution.
  Future<List<String>> conflicts() {
    final repoPath = path;
    final caFile = QfliGit.caFile;
    return Isolate.run(
      () => _withRepo(repoPath, caFile, (session) {
        final json = session.readJson(
          (out) =>
              session.bindings.conflictsJson(session.repo, out, session.error),
        );
        return parseConflictPaths(json);
      }),
    );
  }

  /// Creates the merge commit for the conflicts resolved in the index and
  /// clears the merge state.
  Future<String> commitMerge(String message, GitAuthor author) {
    final repoPath = path;
    final caFile = QfliGit.caFile;
    final name = author.name;
    final email = author.email;
    return Isolate.run(
      () => _withRepo(repoPath, caFile, (session) {
        return _withUtf8([message, name, email], (values) {
          return _withOid((oid) {
            session.check(
              session.bindings.mergeCommit(
                session.repo,
                values[0],
                values[1],
                values[2],
                oid,
                session.error,
              ),
            );
            return readUtf8(oid, qgOidBufferBytes);
          });
        });
      }),
    );
  }

  /// Lists the changed paths of the work tree and the index.
  Future<List<GitStatusEntry>> status() {
    final repoPath = path;
    final caFile = QfliGit.caFile;
    return Isolate.run(
      () => _withRepo(repoPath, caFile, (session) {
        final json = session.readJson(
          (out) =>
              session.bindings.statusJson(session.repo, out, session.error),
        );
        return parseStatusEntries(json);
      }),
    );
  }

  /// Returns the patch for [path], or for the whole repository when null.
  ///
  /// [staged] selects the index against HEAD; otherwise the work tree is
  /// compared with the index. [maxBytes] bounds the patch size. The native
  /// layer clamps it to its supported maximum and reports truncation.
  Future<GitDiff> diff({
    String? path,
    bool staged = false,
    int maxBytes = 262144,
  }) {
    final repoPath = this.path;
    final caFile = QfliGit.caFile;
    final target = path;
    final stagedFlag = staged ? 1 : 0;
    final bound = maxBytes;
    return Isolate.run(
      () => _withRepo(repoPath, caFile, (session) {
        final json = _withUtf8([target], (values) {
          return session.readJson(
            (out) => session.bindings.diffJson(
              session.repo,
              values[0],
              stagedFlag,
              bound,
              out,
              session.error,
            ),
          );
        });
        return parseDiff(json);
      }),
    );
  }

  /// Lists up to [limit] commits reachable from HEAD, newest first.
  Future<List<GitCommit>> log({int limit = 20}) {
    final repoPath = path;
    final caFile = QfliGit.caFile;
    final maximum = limit;
    return Isolate.run(
      () => _withRepo(repoPath, caFile, (session) {
        final json = session.readJson(
          (out) => session.bindings.logJson(
            session.repo,
            maximum,
            out,
            session.error,
          ),
        );
        return parseLog(json);
      }),
    );
  }

  /// Lists local and remote tracking branches.
  Future<List<GitBranch>> branches() {
    final repoPath = path;
    final caFile = QfliGit.caFile;
    return Isolate.run(
      () => _withRepo(repoPath, caFile, (session) {
        final json = session.readJson(
          (out) =>
              session.bindings.branchesJson(session.repo, out, session.error),
        );
        return parseBranches(json);
      }),
    );
  }

  /// Lists the configured remotes.
  Future<List<GitRemote>> remotes() {
    final repoPath = path;
    final caFile = QfliGit.caFile;
    return Isolate.run(
      () => _withRepo(repoPath, caFile, (session) {
        final json = session.readJson(
          (out) =>
              session.bindings.remotesJson(session.repo, out, session.error),
        );
        return parseRemotes(json);
      }),
    );
  }

  /// Creates [name] or updates its URL to [url].
  Future<void> setRemote(String name, String url) {
    final repoPath = path;
    final caFile = QfliGit.caFile;
    final remoteUrl = _validateRemoteUrl(url);
    return Isolate.run(
      () => _withRepo(repoPath, caFile, (session) {
        _withUtf8([name, remoteUrl], (values) {
          session.check(
            session.bindings.remoteSetUrl(
              session.repo,
              values[0],
              values[1],
              session.error,
            ),
          );
        });
      }),
    );
  }

  /// Reads the current HEAD.
  Future<GitHead> head() {
    final repoPath = path;
    final caFile = QfliGit.caFile;
    return Isolate.run(
      () => _withRepo(repoPath, caFile, (session) {
        final json = session.readJson(
          (out) => session.bindings.headJson(session.repo, out, session.error),
        );
        return parseHead(json);
      }),
    );
  }

  /// Fetches [remote]. Pass [token] for a private repository and [cancel] to
  /// stop the transfer.
  Future<void> fetch({
    String remote = 'origin',
    String? username,
    String? token,
    CancelToken? cancel,
  }) async {
    final repoPath = path;
    final caFile = QfliGit.caFile;
    final cancelAddress = cancel?.acquireOperation();
    try {
      await Isolate.run(
        () => _withRepo(repoPath, caFile, (session) {
          _withUtf8([remote, username, token], (values) {
            session.check(
              session.bindings.fetch(
                session.repo,
                values[0],
                values[1],
                values[2],
                _cancelPointer(cancelAddress),
                session.error,
              ),
            );
          });
        }),
      );
    } finally {
      cancel?.releaseOperation();
    }
  }

  /// Pushes [refspec] to [remote]. Pass [token] for a private repository and
  /// [cancel] to stop the transfer.
  Future<void> push({
    String remote = 'origin',
    required String refspec,
    String? username,
    String? token,
    CancelToken? cancel,
  }) async {
    final repoPath = path;
    final caFile = QfliGit.caFile;
    final cancelAddress = cancel?.acquireOperation();
    try {
      await Isolate.run(
        () => _withRepo(repoPath, caFile, (session) {
          _withUtf8([remote, refspec, username, token], (values) {
            session.check(
              session.bindings.push(
                session.repo,
                values[0],
                values[1],
                values[2],
                values[3],
                _cancelPointer(cancelAddress),
                session.error,
              ),
            );
          });
        }),
      );
    } finally {
      cancel?.releaseOperation();
    }
  }

  @override
  String toString() => 'GitRepository($path)';
}

/// One opened repository inside a background isolate.
class _Session {
  _Session(this.bindings, this.repo, this.error);

  final QfliGitBindings bindings;
  final Pointer<QgRepo> repo;
  final Pointer<QgError> error;

  /// Throws [GitException] when [code] reports a failure.
  void check(int code) {
    if (code == 0) {
      return;
    }
    throw GitException.fromNative(NativeError.read(error, code));
  }

  /// Runs a `qg_*_json` call and copies the result before freeing it.
  String readJson(int Function(Pointer<Pointer<Utf8>> outJson) call) {
    final out = calloc<Pointer<Utf8>>();
    try {
      check(call(out));
      final text = out.value;
      if (text == nullptr) {
        throw StateError('native call returned no JSON');
      }
      try {
        return text.toDartString();
      } finally {
        bindings.stringFree(text);
      }
    } finally {
      calloc.free(out);
    }
  }
}

/// Opens the repository at [repoPath], runs [body] and frees every native
/// resource. The whole sequence runs inside one background isolate.
T _withRepo<T>(
  String repoPath,
  String? caFile,
  T Function(_Session session) body,
) {
  final bindings = QfliGitBindings(openQfliGitLibrary());
  Pointer<QgError> error = nullptr;
  Pointer<Pointer<QgRepo>> out = nullptr;
  Pointer<Utf8> pathPointer = nullptr;
  try {
    error = calloc<QgError>();
    out = calloc<Pointer<QgRepo>>();
    pathPointer = repoPath.toNativeUtf8();
    bindings.checkApiVersion();
    _initIfNeeded(bindings, caFile, error);
    final code = bindings.repoOpen(pathPointer, out, error);
    if (code != 0) {
      throw GitException.fromNative(NativeError.read(error, code));
    }
    final repo = out.value;
    if (repo == nullptr) {
      throw const GitException(
        qgEInvalid,
        0,
        'qg_repo_open returned no handle',
      );
    }
    try {
      return body(_Session(bindings, repo, error));
    } finally {
      bindings.repoFree(repo);
    }
  } finally {
    if (pathPointer != nullptr) {
      malloc.free(pathPointer);
    }
    if (out != nullptr) {
      calloc.free(out);
    }
    if (error != nullptr) {
      calloc.free(error);
    }
  }
}

// Keep the Isolate.run closure outside the caller's scope: UI observers and
// ReceivePorts must never be captured by the background computation.
Future<GitRepository> _runCloneIsolate(
  String url,
  String target,
  String? username,
  String? token,
  int? cancelAddress,
  SendPort? progressPort,
) => Isolate.run(
  () =>
      _cloneInWorker(url, target, username, token, cancelAddress, progressPort),
);

GitRepository _cloneInWorker(
  String url,
  String target,
  String? username,
  String? token,
  int? cancelAddress,
  SendPort? progressPort,
) {
  QfliGitBindings? bindings;
  Pointer<QgError> error = nullptr;
  Pointer<Pointer<QgRepo>> out = nullptr;
  NativeCallable<CloneProgressNative>? callback;
  final reporter = progressPort == null
      ? null
      : _CloneProgressReporter(progressPort);
  try {
    bindings = QfliGitBindings(openQfliGitLibrary());
    error = calloc<QgError>();
    out = calloc<Pointer<QgRepo>>();
    bindings.checkApiVersion();
    _initIfNeeded(bindings, null, error);
    if (reporter != null) {
      // libgit2 invokes transfer/checkout callbacks synchronously on this
      // isolate's calling thread. Keep the callable alive until clone returns.
      callback = NativeCallable<CloneProgressNative>.isolateLocal((
        int stage,
        int completed,
        int total,
        int bytes,
        Pointer<Void> _,
      ) {
        reporter.add(stage, completed, total, bytes);
      });
    }
    return _withUtf8([url, target, username, token], (values) {
      final code = bindings!.cloneWithProgress(
        values[0],
        values[1],
        values[2],
        values[3],
        _cancelPointer(cancelAddress),
        callback?.nativeFunction ?? nullptr,
        nullptr,
        out,
        error,
      );
      if (code != 0) {
        throw GitException.fromNative(NativeError.read(error, code));
      }
      if (out.value == nullptr) {
        throw const GitException(qgEInvalid, 0, 'qg_clone returned no handle');
      }
      return GitRepository._(target);
    });
  } finally {
    callback?.close();
    if (out != nullptr) {
      if (out.value != nullptr) bindings?.repoFree(out.value);
      calloc.free(out);
    }
    if (error != nullptr) calloc.free(error);
    reporter?.flush();
    // Same-port FIFO gives the foreground a barrier after the last progress.
    progressPort?.send(null);
  }
}

/// Throttles while synchronous FFI owns the isolate. A timer cannot run there.
class _CloneProgressReporter {
  _CloneProgressReporter(this.port);

  final SendPort port;
  final Stopwatch _sinceLast = Stopwatch()..start();
  List<int>? _last;
  List<int>? _pending;

  void add(int stage, int completed, int total, int bytes) {
    final event = <int>[stage, completed, total, bytes];
    if (_last != null && listEquals(_last, event)) return;
    _pending = event;
    if (_last == null ||
        _last![0] != stage ||
        (total > 0 && completed >= total) ||
        _sinceLast.elapsedMilliseconds >= 100) {
      flush();
    }
  }

  void flush() {
    final event = _pending;
    if (event == null) return;
    port.send(event);
    _last = event;
    _pending = null;
    _sinceLast.reset();
  }
}

/// Retains libgit2 initialization without replacing its process-wide TLS CA.
/// Replacing that CA while another repository uses it would race live TLS.
void _initIfNeeded(
  QfliGitBindings bindings,
  String? _,
  Pointer<QgError> error,
) {
  final code = bindings.init(nullptr, error);
  if (code != 0) {
    throw GitException.fromNative(NativeError.read(error, code));
  }
}

/// Builds the cancel pointer handed to the native layer.
Pointer<Int32> _cancelPointer(int? address) =>
    address == null ? nullptr : Pointer<Int32>.fromAddress(address);

/// Runs [body] with UTF-8 copies of [values] and frees them afterwards.
T _withUtf8<T>(
  List<String?> values,
  T Function(List<Pointer<Utf8>> pointers) body,
) {
  final pointers = <Pointer<Utf8>>[];
  try {
    for (final value in values) {
      pointers.add(value == null ? nullptr : value.toNativeUtf8());
    }
    return body(pointers);
  } finally {
    for (final pointer in pointers) {
      if (pointer != nullptr) {
        malloc.free(pointer);
      }
    }
  }
}

/// Runs [body] with a NUL terminated UTF-8 array of [values] and frees it
/// afterwards. An empty list passes a null array with a zero count.
T _withUtf8Array<T>(
  List<String> values,
  T Function(Pointer<Pointer<Utf8>> pointers, int count) body,
) {
  Pointer<Pointer<Utf8>> array = nullptr;
  final strings = <Pointer<Utf8>>[];
  try {
    if (values.isNotEmpty) {
      array = calloc<Pointer<Utf8>>(values.length);
      for (var index = 0; index < values.length; index++) {
        final pointer = values[index].toNativeUtf8();
        strings.add(pointer);
        array[index] = pointer;
      }
    }
    return body(array, values.length);
  } finally {
    for (final pointer in strings) {
      malloc.free(pointer);
    }
    if (array != nullptr) {
      calloc.free(array);
    }
  }
}

/// Runs [body] with a 41 byte object id buffer and frees it afterwards.
T _withOid<T>(T Function(Pointer<Uint8> oid) body) {
  final buffer = calloc<Uint8>(qgOidBufferBytes);
  try {
    return body(buffer);
  } finally {
    calloc.free(buffer);
  }
}

String _absolute(String path) => p.normalize(p.absolute(path));

///
/// Accepts the remote forms libgit2 can use without inventing credentials:
/// `https://`, `http://`, `ssh://`, `git://`, `file://` and scp-like
/// `user@host:path`. Embedded user info is rejected so a token can never reach
/// the URL, the Git config or a process argument list.
String _validateRemoteUrl(String url) {
  final value = url.trim();
  if (value.isEmpty) {
    throw const GitException(qgEInvalid, 0, 'remote URL is required');
  }
  if (value.length > 2048) {
    throw const GitException(qgEInvalid, 0, 'remote URL is too long');
  }
  if (value.contains('\u0000') ||
      RegExp(r'[\u0000-\u001f\u007f]').hasMatch(value)) {
    throw const GitException(
      qgEInvalid,
      0,
      'remote URL has control characters',
    );
  }

  final scheme = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.\-]*)://').firstMatch(value);
  if (scheme != null) {
    final name = scheme.group(1)!.toLowerCase();
    if (!const {'http', 'https', 'ssh', 'git', 'file'}.contains(name)) {
      throw const GitException(qgEInvalid, 0, 'unsupported remote URL scheme');
    }
    final Uri uri;
    try {
      uri = Uri.parse(value);
    } on FormatException {
      throw const GitException(qgEInvalid, 0, 'remote URL is malformed');
    }
    if (uri.userInfo.isNotEmpty) {
      throw const GitException(
        qgEInvalid,
        0,
        'remote URL must not embed credentials',
      );
    }
    if (name != 'file' && uri.host.isEmpty) {
      throw const GitException(qgEInvalid, 0, 'remote URL has no host');
    }
    if (name == 'file' && uri.path.isEmpty) {
      throw const GitException(qgEInvalid, 0, 'remote URL has no path');
    }
    return value;
  }

  // scp-like syntax: user@host:path. A bare local path is not a remote.
  final scp = RegExp(r'^([^@/\\:]+)@([^/\\:]+):(.+)$').firstMatch(value);
  if (scp != null) {
    if (scp.group(3)!.isEmpty) {
      throw const GitException(qgEInvalid, 0, 'remote URL has no path');
    }
    return value;
  }

  throw const GitException(
    qgEInvalid,
    0,
    'remote URL needs a scheme such as https://',
  );
}
