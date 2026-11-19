/**
 * The native library travels inside this HAR under libs/<abi>/libqfli_git.so.
 * Dart loads it with dart:ffi, so the module exports no ArkTS API.
 */
export const QFLI_GIT_HAR_VERSION: string = '0.1.0';
