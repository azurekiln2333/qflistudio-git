import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'bindings.dart';
import 'library.dart';

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

  /// Repository state text, for example `clean` or `merge`.
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
class CancelToken {
  CancelToken() {
    // malloc leaves the value undefined, so clear it before the first call.
    _flag.value = 0;
  }

  Pointer<Int32> _flag = malloc<Int32>();

  int get _address {
    final flag = _flag;
    if (flag == nullptr) {
      throw StateError('CancelToken has been disposed.');
    }
    return flag.address;
  }

  /// Asks the running operation to stop.
  void cancel() {
    final flag = _flag;
    if (flag == nullptr) {
      return;
    }
    flag.value = 1;
  }

  /// Releases the native flag. Call it after the operation finished.
  void dispose() {
    final flag = _flag;
    if (flag == nullptr) {
      return;
    }
    flag.value = 0;
    malloc.free(flag);
    _flag = nullptr;
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

/// Entry point of the plugin.
class QfliGit {
  QfliGit._();

  static const String _caAssetKey = 'packages/qfli_git/assets/cacert.pem';
  static const String _caFileName = 'cacert.pem';

  static String? _caFile;

  /// Absolute path of the CA bundle written by [ensureInitialized].
  ///
  /// Background isolates read this value and hand it to `qg_init`.
  static String? get caFile => _caFile;

  /// Copies the bundled CA certificates to the application support directory
  /// and initializes the native layer.
  ///
  /// Call it once before the first repository operation. Repeated calls do
  /// nothing.
  static Future<void> ensureInitialized() async {
    if (_caFile != null) {
      return;
    }
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
    final error = calloc<QgError>();
    final caFilePointer = caFile.toNativeUtf8();
    try {
      final code = bindings.init(caFilePointer, error);
      if (code != 0) {
        throw GitException.fromNative(NativeError.read(error, code));
      }
      final version = bindings.apiVersion();
      if (version != qgApiVersion) {
        throw StateError(
          'qfli_git reports API version $version, expected $qgApiVersion.',
        );
      }
    } finally {
      malloc.free(caFilePointer);
      calloc.free(error);
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
  }) {
    final target = _absolute(path);
    final caFile = QfliGit.caFile;
    final cancelAddress = cancel?._address;
    return Isolate.run(() {
      final bindings = QfliGitBindings(openQfliGitLibrary());
      final error = calloc<QgError>();
      final out = calloc<Pointer<QgRepo>>();
      final cancelFlag = _cancelPointer(cancelAddress);
      try {
        _initIfNeeded(bindings, caFile, error);
        return _withUtf8([url, target, username, token], (values) {
          final code = bindings.clone(
            values[0],
            values[1],
            values[2],
            values[3],
            cancelFlag,
            out,
            error,
          );
          if (code != 0) {
            throw GitException.fromNative(NativeError.read(error, code));
          }
          final repo = out.value;
          if (repo == nullptr) {
            throw const GitException(
              qgEInvalid,
              0,
              'qg_clone returned no handle',
            );
          }
          bindings.repoFree(repo);
          return GitRepository._(target);
        });
      } finally {
        calloc.free(out);
        calloc.free(error);
      }
    });
  }

  /// Creates a repository at [path].
  static Future<GitRepository> init(String path, {bool bare = false}) {
    final target = _absolute(path);
    final caFile = QfliGit.caFile;
    return Isolate.run(() {
      final bindings = QfliGitBindings(openQfliGitLibrary());
      final error = calloc<QgError>();
      final out = calloc<Pointer<QgRepo>>();
      try {
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
        calloc.free(out);
        calloc.free(error);
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
  }) {
    final repoPath = path;
    final caFile = QfliGit.caFile;
    final cancelAddress = cancel?._address;
    return Isolate.run(
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
  }

  /// Pushes [refspec] to [remote]. Pass [token] for a private repository and
  /// [cancel] to stop the transfer.
  Future<void> push({
    String remote = 'origin',
    required String refspec,
    String? username,
    String? token,
    CancelToken? cancel,
  }) {
    final repoPath = path;
    final caFile = QfliGit.caFile;
    final cancelAddress = cancel?._address;
    return Isolate.run(
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
  final error = calloc<QgError>();
  final out = calloc<Pointer<QgRepo>>();
  final pathPointer = repoPath.toNativeUtf8();
  try {
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
    malloc.free(pathPointer);
    calloc.free(out);
    calloc.free(error);
  }
}

/// Calls `qg_init` when the caller already ran [QfliGit.ensureInitialized].
void _initIfNeeded(
  QfliGitBindings bindings,
  String? caFile,
  Pointer<QgError> error,
) {
  if (caFile == null) {
    return;
  }
  _withUtf8([caFile], (values) {
    final code = bindings.init(values[0], error);
    if (code != 0) {
      throw GitException.fromNative(NativeError.read(error, code));
    }
  });
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
