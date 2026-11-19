import 'dart:ffi';
import 'dart:io';

/// Environment variable that overrides the library location.
///
/// Host tests and desktop development use it to point at a locally built
/// library. Mobile builds never set it.
const String qfliGitLibraryVariable = 'QFLI_GIT_LIBRARY';

/// iOS framework name inside the app bundle.
const String _iosLibraryPath = 'qfli_git.framework/qfli_git';

/// Shared library name on Android and OpenHarmony.
const String _sharedLibraryName = 'libqfli_git.so';

DynamicLibrary? _cached;

/// Opens `libqfli_git` for the current platform.
///
/// The result is cached per isolate. Each isolate opens the library on its own
/// because [DynamicLibrary] cannot cross isolate boundaries.
DynamicLibrary openQfliGitLibrary() {
  final cached = _cached;
  if (cached != null) {
    return cached;
  }
  final library = _openLibrary();
  _cached = library;
  return library;
}

DynamicLibrary _openLibrary() {
  final override = Platform.environment[qfliGitLibraryVariable];
  if (override != null && override.isNotEmpty) {
    return DynamicLibrary.open(override);
  }
  if (Platform.isIOS) {
    return DynamicLibrary.open(_iosLibraryPath);
  }
  if (Platform.isAndroid || Platform.operatingSystem == 'ohos') {
    return DynamicLibrary.open(_sharedLibraryName);
  }
  throw UnsupportedError(
    'qfli_git has no library for ${Platform.operatingSystem}. '
    'Set $qfliGitLibraryVariable to the built library path.',
  );
}
