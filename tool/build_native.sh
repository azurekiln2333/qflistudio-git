#!/usr/bin/env bash
#
# Build libqfli_git for one platform.
#
#   tool/build_native.sh --platform <host|android|ohos|ios-device|ios-simulator> \
#                        [--abi <abi>] --out <dir>
#
# The upstream sources must already be unpacked; run
# `python tool/fetch_sources.py` first.
#
# Environment:
#   ANDROID_NDK_HOME  Android NDK (android)
#   OHOS_SDK_HOME     OpenHarmony SDK (ohos)
#   CMake / Ninja are looked up on PATH.
#
set -euo pipefail
if [ -n "${GITHUB_ACTIONS:-}" ]; then
	# Annotations are public; job logs need admin rights.
	trap 'echo "::error title=build_native::line $LINENO failed: $BASH_COMMAND"' ERR
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$ROOT_DIR/native/build/src"
BUILD_ROOT="$ROOT_DIR/native/build"
STAGE_ROOT="$BUILD_ROOT/stage"

PLATFORM=""
ABI=""
OUT_DIR=""
JOBS=""

usage() {
	cat <<'EOF'
usage: tool/build_native.sh --platform <host|android|ohos|ios-device|ios-simulator>
                            [--abi <abi>] --out <dir> [--jobs <n>]

  --platform  host           Linux or macOS host library, for the smoke test
              android        needs ANDROID_NDK_HOME, abi arm64-v8a|armeabi-v7a|x86_64
              ohos           needs OHOS_SDK_HOME, abi arm64-v8a|x86_64
              ios-device     arm64 device framework
              ios-simulator  universal arm64 + x86_64 simulator framework
  --abi       target ABI, required for android and ohos
  --out       directory that receives libqfli_git.so / qfli_git.framework and qfli_git.h
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--platform)
		PLATFORM="${2:-}"
		shift 2
		;;
	--abi)
		ABI="${2:-}"
		shift 2
		;;
	--out)
		OUT_DIR="${2:-}"
		shift 2
		;;
	--jobs)
		JOBS="${2:-}"
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "error: unknown argument: $1" >&2
		usage >&2
		exit 1
		;;
	esac
done

die() {
	echo "error: $*" >&2
	# Annotations are public; job logs need admin rights.
	if [ -n "${GITHUB_ACTIONS:-}" ]; then
		echo "::error title=build_native::$*"
	fi
	exit 1
}

[ -n "$PLATFORM" ] || die "--platform is required"
[ -n "$OUT_DIR" ] || die "--out is required"

case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN*) HOST_SHELL="windows" ;;
Darwin) HOST_SHELL="darwin" ;;
*) HOST_SHELL="unix" ;;
esac

# cmake is a native program on Windows, so hand it native paths.
native_path() {
	if [ "$HOST_SHELL" = "windows" ] && command -v cygpath >/dev/null 2>&1; then
		cygpath -m "$1"
	else
		printf '%s' "$1"
	fi
}

if [ -z "$JOBS" ]; then
	if command -v nproc >/dev/null 2>&1; then
		JOBS="$(nproc)"
	elif command -v sysctl >/dev/null 2>&1; then
		JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
	else
		JOBS=4
	fi
fi

CMAKE="${CMAKE:-cmake}"
command -v "$CMAKE" >/dev/null 2>&1 || die "cmake not found"

GENERATOR_ARGS=()
if command -v ninja >/dev/null 2>&1; then
	GENERATOR_ARGS=(-G Ninja)
fi

# Locate llvm-strip inside an NDK or OpenHarmony SDK tree.
find_llvm_tool() {
	local root="$1"
	local tool="$2"
	local candidate

	for candidate in \
		"$root"/toolchains/llvm/prebuilt/*/bin/"$tool" \
		"$root"/toolchains/llvm/prebuilt/*/bin/"$tool".exe \
		"$root"/native/llvm/bin/"$tool" \
		"$root"/native/llvm/bin/"$tool".exe; do
		if [ -x "$candidate" ]; then
			printf '%s' "$candidate"
			return 0
		fi
	done

	candidate="$(find "$root" -type f \( -name "$tool" -o -name "$tool.exe" \) 2>/dev/null | head -n 1 || true)"
	printf '%s' "$candidate"
}

[ -d "$SRC_DIR/libgit2" ] || die "libgit2 sources are missing; run python tool/fetch_sources.py"
[ -d "$SRC_DIR/mbedtls" ] || die "mbedtls sources are missing; run python tool/fetch_sources.py"

# ---------------------------------------------------------------------------
# Per platform settings
# ---------------------------------------------------------------------------

TOOLCHAIN_ARGS=()
STRIP=""
CONFIG_NAME=""
TARGET_ARCHES=""
TARGETS="qfli_git"

case "$PLATFORM" in
host)
	CONFIG_NAME="host-$(uname -m)"
	TARGETS="qfli_git qfli_git_smoke"
	;;
android)
	[ -n "$ABI" ] || die "--abi is required for android"
	NDK="${ANDROID_NDK_HOME:-}"
	[ -n "$NDK" ] || die "ANDROID_NDK_HOME is not set"
	[ -f "$NDK/build/cmake/android.toolchain.cmake" ] || die "no android.toolchain.cmake in $NDK"
	TOOLCHAIN_ARGS=(
		"-DCMAKE_TOOLCHAIN_FILE=$(native_path "$NDK/build/cmake/android.toolchain.cmake")"
		"-DANDROID_NDK=$(native_path "$NDK")"
		"-DANDROID_ABI=$ABI"
		"-DANDROID_PLATFORM=android-24"
	)
	CONFIG_NAME="android-$ABI"
	STRIP="$(find_llvm_tool "$NDK" llvm-strip)"
	;;
ohos)
	[ -n "$ABI" ] || die "--abi is required for ohos"
	OHOS="${OHOS_SDK_HOME:-}"
	[ -n "$OHOS" ] || die "OHOS_SDK_HOME is not set"
	TOOLCHAIN="$OHOS/native/build/cmake/ohos.toolchain.cmake"
	[ -f "$TOOLCHAIN" ] || die "no ohos.toolchain.cmake in $OHOS/native"
	TOOLCHAIN_ARGS=(
		"-DCMAKE_TOOLCHAIN_FILE=$(native_path "$TOOLCHAIN")"
		"-DOHOS_ARCH=$ABI"
	)
	CONFIG_NAME="ohos-$ABI"
	STRIP="$(find_llvm_tool "$OHOS/native" llvm-strip)"
	;;
ios-device)
	TOOLCHAIN_ARGS=(
		"-DCMAKE_SYSTEM_NAME=iOS"
		"-DCMAKE_OSX_SYSROOT=iphoneos"
		"-DCMAKE_OSX_ARCHITECTURES=arm64"
		"-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0"
	)
	CONFIG_NAME="ios-device-arm64"
	TARGET_ARCHES="arm64"
	;;
ios-simulator)
	CONFIG_NAME="ios-simulator"
	TARGET_ARCHES="arm64 x86_64"
	;;
*)
	die "unknown platform: $PLATFORM"
	;;
esac

[ -n "$PLATFORM" ] || die "--platform is required"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

build_mbedtls() {
	local name="$1"
	shift
	local prefix="$STAGE_ROOT/$name/mbedtls"
	local build="$BUILD_ROOT/$name/mbedtls-build"

	echo "== mbedtls ($name)"
	"$CMAKE" -S "$(native_path "$SRC_DIR/mbedtls")" -B "$(native_path "$build")" \
		"${GENERATOR_ARGS[@]}" \
		"-DCMAKE_BUILD_TYPE=Release" \
		"-DCMAKE_INSTALL_PREFIX=$(native_path "$prefix")" \
		"-DCMAKE_INSTALL_LIBDIR=library" \
		"-DCMAKE_POSITION_INDEPENDENT_CODE=ON" \
		"-DCMAKE_C_FLAGS=-fPIC -ffunction-sections -fdata-sections -O2" \
		"-DENABLE_PROGRAMS=OFF" \
		"-DENABLE_TESTING=OFF" \
		"-DGEN_FILES=OFF" \
		"-DMBEDTLS_FATAL_WARNINGS=OFF" \
		"-DUSE_STATIC_MBEDTLS_LIBRARY=ON" \
		"-DUSE_SHARED_MBEDTLS_LIBRARY=OFF" \
		"$@"
	"$CMAKE" --build "$(native_path "$build")" --target install -- -j "$JOBS"
}

build_library() {
	local name="$1"
	shift
	local mbedtls_prefix="$STAGE_ROOT/$name/mbedtls"
	local build="$BUILD_ROOT/$name/native"
	local out="$OUT_DIR"

	echo "== qfli_git ($name)"
	"$CMAKE" -S "$(native_path "$ROOT_DIR/native")" -B "$(native_path "$build")" \
		"${GENERATOR_ARGS[@]}" \
		"-DCMAKE_BUILD_TYPE=Release" \
		"-DQFLI_GIT_SRC_DIR=$(native_path "$SRC_DIR")" \
		"-DQFLI_GIT_MBEDTLS_ROOT=$(native_path "$mbedtls_prefix")" \
		"-DQFLI_GIT_OUTPUT_DIR=$(native_path "$out")" \
		"$@"
	"$CMAKE" --build "$(native_path "$build")" --target $TARGETS -- -j "$JOBS"
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

OUT_DIR="$(mkdir -p "$OUT_DIR" && cd "$OUT_DIR" && pwd)"
mkdir -p "$BUILD_ROOT" "$STAGE_ROOT"

case "$PLATFORM" in
host | android | ohos)
	build_mbedtls "$CONFIG_NAME" "${TOOLCHAIN_ARGS[@]}"
	build_library "$CONFIG_NAME" "${TOOLCHAIN_ARGS[@]}"
	cp "$ROOT_DIR/native/include/qfli_git.h" "$OUT_DIR/qfli_git.h"
	;;
ios-device)
	build_mbedtls "$CONFIG_NAME" "${TOOLCHAIN_ARGS[@]}"
	build_library "$CONFIG_NAME" "${TOOLCHAIN_ARGS[@]}"
	cp "$ROOT_DIR/native/include/qfli_git.h" "$OUT_DIR/qfli_git.h"
	;;
ios-simulator)
	framework_binaries=""
	for arch in $TARGET_ARCHES; do
		name="ios-simulator-$arch"
		build_mbedtls "$name" \
			"-DCMAKE_SYSTEM_NAME=iOS" \
			"-DCMAKE_OSX_SYSROOT=iphonesimulator" \
			"-DCMAKE_OSX_ARCHITECTURES=$arch" \
			"-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0"
		out_arch="$BUILD_ROOT/$name/out"
		build_library "$name" \
			"-DCMAKE_SYSTEM_NAME=iOS" \
			"-DCMAKE_OSX_SYSROOT=iphonesimulator" \
			"-DCMAKE_OSX_ARCHITECTURES=$arch" \
			"-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0" \
			"-DQFLI_GIT_OUTPUT_DIR=$(native_path "$out_arch")"
		framework_binaries="$framework_binaries $out_arch/qfli_git.framework/qfli_git"
	done

	# Merge the per-architecture binaries into one universal framework.
	rm -rf "$OUT_DIR/qfli_git.framework"
	cp -R "$BUILD_ROOT/ios-simulator-arm64/out/qfli_git.framework" "$OUT_DIR/qfli_git.framework"
	lipo -create $framework_binaries -output "$OUT_DIR/qfli_git.framework/qfli_git"
	cp "$ROOT_DIR/native/include/qfli_git.h" "$OUT_DIR/qfli_git.h"
	;;
esac

# ---------------------------------------------------------------------------
# Strip
# ---------------------------------------------------------------------------

case "$PLATFORM" in
host | android | ohos)
	if [ -n "$STRIP" ] && [ -x "$STRIP" ]; then
		"$STRIP" --strip-unneeded "$OUT_DIR/libqfli_git.so" 2>/dev/null || true
	elif command -v llvm-strip >/dev/null 2>&1; then
		llvm-strip --strip-unneeded "$OUT_DIR/libqfli_git.so" 2>/dev/null || true
	elif command -v strip >/dev/null 2>&1; then
		strip --strip-unneeded "$OUT_DIR/libqfli_git.so" 2>/dev/null || true
	fi
	;;
ios-device | ios-simulator)
	if command -v xcrun >/dev/null 2>&1; then
		xcrun strip -x "$OUT_DIR/qfli_git.framework/qfli_git" 2>/dev/null || true
	fi
	;;
esac

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

echo "== output"
if [ -d "$OUT_DIR/qfli_git.framework" ]; then
	framework_binary="$OUT_DIR/qfli_git.framework/qfli_git"
	echo "framework: $framework_binary"
	ls -l "$framework_binary" | awk '{print "size: " $5 " bytes"}'
else
	echo "library: $OUT_DIR/libqfli_git.so"
	ls -l "$OUT_DIR/libqfli_git.so" | awk '{print "size: " $5 " bytes"}'
fi
echo "header: $OUT_DIR/qfli_git.h"
if [ -f "$OUT_DIR/qfli_git_smoke" ]; then
	echo "smoke: $OUT_DIR/qfli_git_smoke"
fi
