import 'dart:convert';
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

/// Value returned by `qg_api_version`.
const int qgApiVersion = 1;

/// The operation observed a non-zero cancel flag and stopped.
const int qgECanceled = -1000;

/// The merge commit still has unresolved conflicts.
const int qgEConflict = -1001;

/// A parameter was rejected before reaching libgit2.
const int qgEInvalid = -1002;

/// Size of the `message` field of `qg_error`.
const int qgErrorMessageBytes = 512;

/// Size of the buffer `qg_commit`, `qg_merge` and `qg_merge_commit` fill with a
/// hexadecimal object id and a terminating NUL.
const int qgOidBufferBytes = 41;

/// Mirrors `qg_error` in `qfli_git.h`.
///
/// The header declares `char message[512]`. The characters are read as bytes
/// because dart:ffi offers no element access for inline arrays.
final class QgError extends ffi.Struct {
  @ffi.Int32()
  external int code;

  @ffi.Int32()
  external int klass;

  @ffi.Array(qgErrorMessageBytes)
  external ffi.Array<ffi.Uint8> message;
}

/// Opaque `qg_repo` handle.
final class QgRepo extends ffi.Opaque {}

/// Snapshot of a filled [QgError].
class NativeError {
  const NativeError({
    required this.code,
    required this.klass,
    required this.message,
  });

  /// Error code reported by libgit2 or one of the `QG_E*` values.
  final int code;

  /// `git_error_t` class, or 0 when the failure came from `qfli_git.c`.
  final int klass;

  /// UTF-8 message text.
  final String message;

  /// Reads the error block after a native call returned [returnCode].
  ///
  /// A zero code in the block falls back to [returnCode] so a native failure
  /// never turns into a silent success.
  factory NativeError.read(ffi.Pointer<QgError> error, int returnCode) {
    final code = error.ref.code != 0 ? error.ref.code : returnCode;
    final message = _readMessage(error);
    return NativeError(
      code: code,
      klass: error.ref.klass,
      message: message.isEmpty
          ? 'native call failed with code $returnCode'
          : message,
    );
  }

  @override
  String toString() => 'NativeError($code, klass $klass): $message';
}

/// Byte offset of the `message` field, computed from the leading fields.
final int _messageOffset = ffi.sizeOf<_QgErrorHead>();
final int _errorSize = ffi.sizeOf<QgError>();

final class _QgErrorHead extends ffi.Struct {
  @ffi.Int32()
  external int code;

  @ffi.Int32()
  external int klass;
}

String _readMessage(ffi.Pointer<QgError> error) {
  final bytes = error.cast<ffi.Uint8>().asTypedList(_errorSize);
  var end = _messageOffset;
  while (end < bytes.length && bytes[end] != 0) {
    end++;
  }
  return utf8.decode(bytes.sublist(_messageOffset, end), allowMalformed: true);
}

/// Reads a NUL terminated UTF-8 string that the caller already copied.
String readUtf8(ffi.Pointer<ffi.Uint8> bytes, int capacity) {
  final view = bytes.asTypedList(capacity);
  var end = 0;
  while (end < capacity && view[end] != 0) {
    end++;
  }
  return utf8.decode(view.sublist(0, end), allowMalformed: true);
}

typedef _ApiVersionNative = ffi.Int32 Function();
typedef _ApiVersionDart = int Function();
typedef _VersionNative = ffi.Pointer<Utf8> Function();
typedef _VersionDart = ffi.Pointer<Utf8> Function();
typedef _InitNative =
    ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Pointer<QgError>);
typedef _InitDart = int Function(ffi.Pointer<Utf8>, ffi.Pointer<QgError>);
typedef _ShutdownNative = ffi.Int32 Function();
typedef _ShutdownDart = int Function();
typedef _RepoInitNative =
    ffi.Int32 Function(
      ffi.Pointer<Utf8>,
      ffi.Int32,
      ffi.Pointer<ffi.Pointer<QgRepo>>,
      ffi.Pointer<QgError>,
    );
typedef _RepoInitDart =
    int Function(
      ffi.Pointer<Utf8>,
      int,
      ffi.Pointer<ffi.Pointer<QgRepo>>,
      ffi.Pointer<QgError>,
    );
typedef _RepoOpenNative =
    ffi.Int32 Function(
      ffi.Pointer<Utf8>,
      ffi.Pointer<ffi.Pointer<QgRepo>>,
      ffi.Pointer<QgError>,
    );
typedef _RepoOpenDart =
    int Function(
      ffi.Pointer<Utf8>,
      ffi.Pointer<ffi.Pointer<QgRepo>>,
      ffi.Pointer<QgError>,
    );
typedef _RepoFreeNative = ffi.Void Function(ffi.Pointer<QgRepo>);
typedef _RepoFreeDart = void Function(ffi.Pointer<QgRepo>);
typedef _CloneNative =
    ffi.Int32 Function(
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<ffi.Int32>,
      ffi.Pointer<ffi.Pointer<QgRepo>>,
      ffi.Pointer<QgError>,
    );
typedef _CloneDart =
    int Function(
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<ffi.Int32>,
      ffi.Pointer<ffi.Pointer<QgRepo>>,
      ffi.Pointer<QgError>,
    );
typedef _FetchNative =
    ffi.Int32 Function(
      ffi.Pointer<QgRepo>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<ffi.Int32>,
      ffi.Pointer<QgError>,
    );
typedef _FetchDart =
    int Function(
      ffi.Pointer<QgRepo>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<ffi.Int32>,
      ffi.Pointer<QgError>,
    );
typedef _PushNative =
    ffi.Int32 Function(
      ffi.Pointer<QgRepo>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<ffi.Int32>,
      ffi.Pointer<QgError>,
    );
typedef _PushDart =
    int Function(
      ffi.Pointer<QgRepo>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<ffi.Int32>,
      ffi.Pointer<QgError>,
    );
typedef _AddAllNative =
    ffi.Int32 Function(ffi.Pointer<QgRepo>, ffi.Pointer<QgError>);
typedef _AddAllDart = int Function(ffi.Pointer<QgRepo>, ffi.Pointer<QgError>);
typedef _CommitNative =
    ffi.Int32 Function(
      ffi.Pointer<QgRepo>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Pointer<QgError>,
    );
typedef _CommitDart =
    int Function(
      ffi.Pointer<QgRepo>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Pointer<QgError>,
    );
typedef _BranchCreateNative =
    ffi.Int32 Function(
      ffi.Pointer<QgRepo>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<QgError>,
    );
typedef _BranchCreateDart =
    int Function(
      ffi.Pointer<QgRepo>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<QgError>,
    );
typedef _CheckoutBranchNative =
    ffi.Int32 Function(
      ffi.Pointer<QgRepo>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<QgError>,
    );
typedef _CheckoutBranchDart =
    int Function(ffi.Pointer<QgRepo>, ffi.Pointer<Utf8>, ffi.Pointer<QgError>);
typedef _MergeNative =
    ffi.Int32 Function(
      ffi.Pointer<QgRepo>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<ffi.Int32>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Pointer<QgError>,
    );
typedef _MergeDart =
    int Function(
      ffi.Pointer<QgRepo>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<ffi.Int32>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Pointer<QgError>,
    );
typedef _MergeCommitNative =
    ffi.Int32 Function(
      ffi.Pointer<QgRepo>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Pointer<QgError>,
    );
typedef _MergeCommitDart =
    int Function(
      ffi.Pointer<QgRepo>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Pointer<QgError>,
    );
typedef _JsonNative =
    ffi.Int32 Function(
      ffi.Pointer<QgRepo>,
      ffi.Pointer<ffi.Pointer<Utf8>>,
      ffi.Pointer<QgError>,
    );
typedef _JsonDart =
    int Function(
      ffi.Pointer<QgRepo>,
      ffi.Pointer<ffi.Pointer<Utf8>>,
      ffi.Pointer<QgError>,
    );
typedef _StringFreeNative = ffi.Void Function(ffi.Pointer<Utf8>);
typedef _StringFreeDart = void Function(ffi.Pointer<Utf8>);

/// Hand written bindings for `qfli_git.h`.
///
/// Every method mirrors one C function. Callers own the `qg_error` block and
/// pass the same pointer to each call.
class QfliGitBindings {
  QfliGitBindings(this._library);

  final ffi.DynamicLibrary _library;

  late final _apiVersion = _library
      .lookupFunction<_ApiVersionNative, _ApiVersionDart>('qg_api_version');
  late final _libgit2Version = _library
      .lookupFunction<_VersionNative, _VersionDart>('qg_libgit2_version');
  late final _mbedtlsVersion = _library
      .lookupFunction<_VersionNative, _VersionDart>('qg_mbedtls_version');
  late final _init = _library.lookupFunction<_InitNative, _InitDart>('qg_init');
  late final _shutdown = _library
      .lookupFunction<_ShutdownNative, _ShutdownDart>('qg_shutdown');
  late final _repoInit = _library
      .lookupFunction<_RepoInitNative, _RepoInitDart>('qg_repo_init');
  late final _repoOpen = _library
      .lookupFunction<_RepoOpenNative, _RepoOpenDart>('qg_repo_open');
  late final _repoFree = _library
      .lookupFunction<_RepoFreeNative, _RepoFreeDart>('qg_repo_free');
  late final _clone = _library.lookupFunction<_CloneNative, _CloneDart>(
    'qg_clone',
  );
  late final _fetch = _library.lookupFunction<_FetchNative, _FetchDart>(
    'qg_fetch',
  );
  late final _push = _library.lookupFunction<_PushNative, _PushDart>('qg_push');
  late final _addAll = _library.lookupFunction<_AddAllNative, _AddAllDart>(
    'qg_add_all',
  );
  late final _commit = _library.lookupFunction<_CommitNative, _CommitDart>(
    'qg_commit',
  );
  late final _branchCreate = _library
      .lookupFunction<_BranchCreateNative, _BranchCreateDart>(
        'qg_branch_create',
      );
  late final _checkoutBranch = _library
      .lookupFunction<_CheckoutBranchNative, _CheckoutBranchDart>(
        'qg_checkout_branch',
      );
  late final _merge = _library.lookupFunction<_MergeNative, _MergeDart>(
    'qg_merge',
  );
  late final _mergeCommit = _library
      .lookupFunction<_MergeCommitNative, _MergeCommitDart>('qg_merge_commit');
  late final _conflictsJson = _library.lookupFunction<_JsonNative, _JsonDart>(
    'qg_conflicts_json',
  );
  late final _statusJson = _library.lookupFunction<_JsonNative, _JsonDart>(
    'qg_status_json',
  );
  late final _headJson = _library.lookupFunction<_JsonNative, _JsonDart>(
    'qg_head_json',
  );
  late final _stringFree = _library
      .lookupFunction<_StringFreeNative, _StringFreeDart>('qg_string_free');

  /// `int qg_api_version(void)`
  int apiVersion() => _apiVersion();

  /// `const char *qg_libgit2_version(void)`
  String libgit2Version() => _libgit2Version().toDartString();

  /// `const char *qg_mbedtls_version(void)`
  String mbedtlsVersion() => _mbedtlsVersion().toDartString();

  /// `int qg_init(const char *ca_file, qg_error *err)`
  int init(ffi.Pointer<Utf8> caFile, ffi.Pointer<QgError> err) =>
      _init(caFile, err);

  /// `int qg_shutdown(void)`
  int shutdown() => _shutdown();

  /// `int qg_repo_init(const char *path, int bare, qg_repo **out, qg_error *err)`
  int repoInit(
    ffi.Pointer<Utf8> path,
    int bare,
    ffi.Pointer<ffi.Pointer<QgRepo>> out,
    ffi.Pointer<QgError> err,
  ) => _repoInit(path, bare, out, err);

  /// `int qg_repo_open(const char *path, qg_repo **out, qg_error *err)`
  int repoOpen(
    ffi.Pointer<Utf8> path,
    ffi.Pointer<ffi.Pointer<QgRepo>> out,
    ffi.Pointer<QgError> err,
  ) => _repoOpen(path, out, err);

  /// `void qg_repo_free(qg_repo *repo)`
  void repoFree(ffi.Pointer<QgRepo> repo) => _repoFree(repo);

  /// `int qg_clone(const char *url, const char *path, const char *username,
  /// const char *token, const int32_t *cancel_flag, qg_repo **out, qg_error *err)`
  int clone(
    ffi.Pointer<Utf8> url,
    ffi.Pointer<Utf8> path,
    ffi.Pointer<Utf8> username,
    ffi.Pointer<Utf8> token,
    ffi.Pointer<ffi.Int32> cancelFlag,
    ffi.Pointer<ffi.Pointer<QgRepo>> out,
    ffi.Pointer<QgError> err,
  ) => _clone(url, path, username, token, cancelFlag, out, err);

  /// `int qg_fetch(qg_repo *repo, const char *remote, const char *username,
  /// const char *token, const int32_t *cancel_flag, qg_error *err)`
  int fetch(
    ffi.Pointer<QgRepo> repo,
    ffi.Pointer<Utf8> remote,
    ffi.Pointer<Utf8> username,
    ffi.Pointer<Utf8> token,
    ffi.Pointer<ffi.Int32> cancelFlag,
    ffi.Pointer<QgError> err,
  ) => _fetch(repo, remote, username, token, cancelFlag, err);

  /// `int qg_push(qg_repo *repo, const char *remote, const char *refspec,
  /// const char *username, const char *token, const int32_t *cancel_flag,
  /// qg_error *err)`
  int push(
    ffi.Pointer<QgRepo> repo,
    ffi.Pointer<Utf8> remote,
    ffi.Pointer<Utf8> refspec,
    ffi.Pointer<Utf8> username,
    ffi.Pointer<Utf8> token,
    ffi.Pointer<ffi.Int32> cancelFlag,
    ffi.Pointer<QgError> err,
  ) => _push(repo, remote, refspec, username, token, cancelFlag, err);

  /// `int qg_add_all(qg_repo *repo, qg_error *err)`
  int addAll(ffi.Pointer<QgRepo> repo, ffi.Pointer<QgError> err) =>
      _addAll(repo, err);

  /// `int qg_commit(qg_repo *repo, const char *message, const char *name,
  /// const char *email, char out_oid[41], qg_error *err)`
  int commit(
    ffi.Pointer<QgRepo> repo,
    ffi.Pointer<Utf8> message,
    ffi.Pointer<Utf8> name,
    ffi.Pointer<Utf8> email,
    ffi.Pointer<ffi.Uint8> outOid,
    ffi.Pointer<QgError> err,
  ) => _commit(repo, message, name, email, outOid, err);

  /// `int qg_branch_create(qg_repo *repo, const char *name,
  /// const char *start_point, qg_error *err)`
  int branchCreate(
    ffi.Pointer<QgRepo> repo,
    ffi.Pointer<Utf8> name,
    ffi.Pointer<Utf8> startPoint,
    ffi.Pointer<QgError> err,
  ) => _branchCreate(repo, name, startPoint, err);

  /// `int qg_checkout_branch(qg_repo *repo, const char *name, qg_error *err)`
  int checkoutBranch(
    ffi.Pointer<QgRepo> repo,
    ffi.Pointer<Utf8> name,
    ffi.Pointer<QgError> err,
  ) => _checkoutBranch(repo, name, err);

  /// `int qg_merge(qg_repo *repo, const char *branch, const char *name,
  /// const char *email, int *out_result, char out_oid[41], qg_error *err)`
  int merge(
    ffi.Pointer<QgRepo> repo,
    ffi.Pointer<Utf8> branch,
    ffi.Pointer<Utf8> name,
    ffi.Pointer<Utf8> email,
    ffi.Pointer<ffi.Int32> outResult,
    ffi.Pointer<ffi.Uint8> outOid,
    ffi.Pointer<QgError> err,
  ) => _merge(repo, branch, name, email, outResult, outOid, err);

  /// `int qg_merge_commit(qg_repo *repo, const char *message, const char *name,
  /// const char *email, char out_oid[41], qg_error *err)`
  int mergeCommit(
    ffi.Pointer<QgRepo> repo,
    ffi.Pointer<Utf8> message,
    ffi.Pointer<Utf8> name,
    ffi.Pointer<Utf8> email,
    ffi.Pointer<ffi.Uint8> outOid,
    ffi.Pointer<QgError> err,
  ) => _mergeCommit(repo, message, name, email, outOid, err);

  /// `int qg_conflicts_json(qg_repo *repo, char **out_json, qg_error *err)`
  int conflictsJson(
    ffi.Pointer<QgRepo> repo,
    ffi.Pointer<ffi.Pointer<Utf8>> outJson,
    ffi.Pointer<QgError> err,
  ) => _conflictsJson(repo, outJson, err);

  /// `int qg_status_json(qg_repo *repo, char **out_json, qg_error *err)`
  int statusJson(
    ffi.Pointer<QgRepo> repo,
    ffi.Pointer<ffi.Pointer<Utf8>> outJson,
    ffi.Pointer<QgError> err,
  ) => _statusJson(repo, outJson, err);

  /// `int qg_head_json(qg_repo *repo, char **out_json, qg_error *err)`
  int headJson(
    ffi.Pointer<QgRepo> repo,
    ffi.Pointer<ffi.Pointer<Utf8>> outJson,
    ffi.Pointer<QgError> err,
  ) => _headJson(repo, outJson, err);

  /// `void qg_string_free(char *s)`
  void stringFree(ffi.Pointer<Utf8> text) => _stringFree(text);
}
