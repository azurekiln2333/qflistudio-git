#
# Builds libqfli_git: a shared library that links libgit2 and mbedTLS
# statically. Sources come from tool/fetch_sources.py.
#
# Configure through tool/build_native.sh. In short:
#   cmake -S native -B <build> -G Ninja \
#         -DQFLI_GIT_SRC_DIR=native/build/src \
#         -DQFLI_GIT_MBEDTLS_ROOT=<mbedtls install prefix> \
#         -DQFLI_GIT_OUTPUT_DIR=<out> [toolchain arguments]
#
cmake_minimum_required(VERSION 3.20)

project(qfli_git VERSION 0.1.0 LANGUAGES C)

set(QFLI_GIT_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/build/src"
    CACHE PATH "Directory with the unpacked libgit2 and mbedtls sources")
set(QFLI_GIT_MBEDTLS_ROOT ""
    CACHE PATH "mbedTLS install prefix with include/ and library/")
set(QFLI_GIT_OUTPUT_DIR "${CMAKE_CURRENT_BINARY_DIR}/out"
    CACHE PATH "Directory that receives libqfli_git.so or qfli_git.framework")

if(ANDROID)
	set(QFLI_GIT_PLATFORM "android")
elseif(CMAKE_SYSTEM_NAME STREQUAL "OHOS")
	set(QFLI_GIT_PLATFORM "ohos")
elseif(CMAKE_SYSTEM_NAME STREQUAL "iOS")
	set(QFLI_GIT_PLATFORM "ios")
else()
	set(QFLI_GIT_PLATFORM "host")
endif()

if(QFLI_GIT_PLATFORM MATCHES "^ios")
	set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0" CACHE STRING "" FORCE)
endif()

set(CMAKE_POSITION_INDEPENDENT_CODE ON)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
	set(CMAKE_BUILD_TYPE "Release" CACHE STRING "" FORCE)
endif()

add_compile_options(-fPIC -fvisibility=hidden -ffunction-sections -fdata-sections -O2)

if(QFLI_GIT_PLATFORM MATCHES "^ios" OR APPLE)
	add_link_options(-Wl,-dead_strip)
endif()

# ---------------------------------------------------------------------------
# mbedTLS: libgit2 locates it through MBEDTLS_ROOT_DIR.
# ---------------------------------------------------------------------------

if(NOT QFLI_GIT_MBEDTLS_ROOT)
	if(DEFINED ENV{MBEDTLS_ROOT_DIR})
		set(QFLI_GIT_MBEDTLS_ROOT "$ENV{MBEDTLS_ROOT_DIR}")
	else()
		message(FATAL_ERROR "QFLI_GIT_MBEDTLS_ROOT is not set; run tool/build_native.sh")
	endif()
endif()

set(MBEDTLS_ROOT_DIR "${QFLI_GIT_MBEDTLS_ROOT}" CACHE PATH "mbedTLS install prefix" FORCE)

#
# Hand libgit2's FindmbedTLS the resolved paths. Cross toolchains such as the
# NDK set CMAKE_FIND_ROOT_PATH_MODE_INCLUDE to ONLY, which makes find_path()
# ignore an absolute hint.
#
set(QFLI_GIT_MBEDTLS_INCLUDE "${QFLI_GIT_MBEDTLS_ROOT}/include" CACHE PATH "" FORCE)
set(QFLI_GIT_MBEDTLS_LIBDIR "${QFLI_GIT_MBEDTLS_ROOT}/library" CACHE PATH "" FORCE)

foreach(_qfli_mbedtls_lib mbedtls mbedx509 mbedcrypto)
	set(_qfli_mbedtls_file
		"${QFLI_GIT_MBEDTLS_LIBDIR}/${CMAKE_STATIC_LIBRARY_PREFIX}${_qfli_mbedtls_lib}${CMAKE_STATIC_LIBRARY_SUFFIX}")
	if(NOT EXISTS "${_qfli_mbedtls_file}")
		message(FATAL_ERROR
			"mbedTLS is not built in ${QFLI_GIT_MBEDTLS_ROOT}; run tool/build_native.sh")
	endif()
endforeach()

set(MBEDTLS_INCLUDE_DIR "${QFLI_GIT_MBEDTLS_INCLUDE}" CACHE PATH "" FORCE)
set(MBEDTLS_LIBRARY
	"${QFLI_GIT_MBEDTLS_LIBDIR}/${CMAKE_STATIC_LIBRARY_PREFIX}mbedtls${CMAKE_STATIC_LIBRARY_SUFFIX}"
	CACHE FILEPATH "" FORCE)
set(MBEDX509_LIBRARY
	"${QFLI_GIT_MBEDTLS_LIBDIR}/${CMAKE_STATIC_LIBRARY_PREFIX}mbedx509${CMAKE_STATIC_LIBRARY_SUFFIX}"
	CACHE FILEPATH "" FORCE)
set(MBEDCRYPTO_LIBRARY
	"${QFLI_GIT_MBEDTLS_LIBDIR}/${CMAKE_STATIC_LIBRARY_PREFIX}mbedcrypto${CMAKE_STATIC_LIBRARY_SUFFIX}"
	CACHE FILEPATH "" FORCE)
set(MBEDTLS_FOUND TRUE CACHE BOOL "" FORCE)

if(NOT EXISTS "${QFLI_GIT_SRC_DIR}/libgit2/include/git2.h")
	message(FATAL_ERROR "libgit2 sources are missing; run python tool/fetch_sources.py")
endif()

# ---------------------------------------------------------------------------
# libgit2, built as a subproject.
# ---------------------------------------------------------------------------

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(BUILD_CLI OFF CACHE BOOL "" FORCE)
set(BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(BUILD_FUZZERS OFF CACHE BOOL "" FORCE)
set(USE_SSH OFF CACHE STRING "" FORCE)
set(USE_HTTPS mbedTLS CACHE STRING "" FORCE)
set(USE_SHA1 CollisionDetection CACHE STRING "" FORCE)
set(USE_SHA256 Builtin CACHE STRING "" FORCE)
set(USE_BUNDLED_ZLIB ON CACHE STRING "" FORCE)
set(REGEX_BACKEND builtin CACHE STRING "" FORCE)
set(USE_HTTP_PARSER builtin CACHE STRING "" FORCE)
set(USE_GSSAPI OFF CACHE BOOL "" FORCE)
set(USE_NTLMCLIENT OFF CACHE BOOL "" FORCE)
set(USE_ICONV OFF CACHE BOOL "" FORCE)

add_subdirectory("${QFLI_GIT_SRC_DIR}/libgit2" "${CMAKE_BINARY_DIR}/libgit2")

# ---------------------------------------------------------------------------
# libqfli_git
# ---------------------------------------------------------------------------

add_library(qfli_git SHARED src/qfli_git.c)

target_include_directories(qfli_git PRIVATE
	"${CMAKE_CURRENT_SOURCE_DIR}/include"
	"${CMAKE_BINARY_DIR}/libgit2/include"
	"${QFLI_GIT_SRC_DIR}/libgit2/include"
	"${QFLI_GIT_MBEDTLS_ROOT}/include")

target_link_libraries(qfli_git PRIVATE libgit2package)
add_dependencies(qfli_git libgit2package)

set_target_properties(qfli_git PROPERTIES
	C_STANDARD 99
	C_STANDARD_REQUIRED ON
	OUTPUT_NAME "qfli_git"
	LIBRARY_OUTPUT_DIRECTORY "${QFLI_GIT_OUTPUT_DIR}"
	RUNTIME_OUTPUT_DIRECTORY "${QFLI_GIT_OUTPUT_DIR}"
	PUBLIC_HEADER "${CMAKE_CURRENT_SOURCE_DIR}/include/qfli_git.h")

if(QFLI_GIT_PLATFORM MATCHES "^ios")
	# iOS refuses to install an app whose embedded framework has no
	# CFBundleIdentifier, and App Store validation also wants MinimumOSVersion.
	set_target_properties(qfli_git PROPERTIES
		PREFIX ""
		FRAMEWORK TRUE
		FRAMEWORK_VERSION "A"
		VERSION "${PROJECT_VERSION}"
		SOVERSION "1"
		INSTALL_NAME_DIR "@rpath"
		MACOSX_RPATH TRUE
		MACOSX_FRAMEWORK_IDENTIFIER "com.azurekiln.qfli-git"
		MACOSX_FRAMEWORK_BUNDLE_VERSION "${PROJECT_VERSION}"
		MACOSX_FRAMEWORK_SHORT_VERSION_STRING "${PROJECT_VERSION}"
		MACOSX_FRAMEWORK_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/ios/Info.plist.in")
endif()

if(APPLE)
	# ld64 has no version script; restrict the exports with a symbol list.
	file(WRITE "${CMAKE_BINARY_DIR}/exports.apple.txt" "_qg_*\n")
	target_link_options(qfli_git PRIVATE
		"-Wl,-exported_symbols_list,${CMAKE_BINARY_DIR}/exports.apple.txt")
else()
	target_link_options(qfli_git PRIVATE
		-Wl,--gc-sections
		"-Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/exports.map")
endif()

# Android and OpenHarmony devices run 16 KB page kernels on arm64.
if(QFLI_GIT_PLATFORM STREQUAL "android" OR QFLI_GIT_PLATFORM STREQUAL "ohos")
	target_link_options(qfli_git PRIVATE
		"-Wl,-z,max-page-size=16384"
		"-Wl,-z,common-page-size=16384")
endif()

if(QFLI_GIT_PLATFORM STREQUAL "ohos")
	target_link_options(qfli_git PRIVATE "-Wl,-z,noexecstack")
endif()

# ---------------------------------------------------------------------------
# Host smoke test
# ---------------------------------------------------------------------------

if(QFLI_GIT_PLATFORM STREQUAL "host")
	option(QFLI_GIT_BUILD_SMOKE "Build the host smoke test" ON)
else()
	option(QFLI_GIT_BUILD_SMOKE "Build the host smoke test" OFF)
endif()

if(QFLI_GIT_BUILD_SMOKE)
	add_executable(qfli_git_smoke test/smoke.c)
	target_include_directories(qfli_git_smoke PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/include")
	target_link_libraries(qfli_git_smoke PRIVATE qfli_git)
	set_target_properties(qfli_git_smoke PROPERTIES
		RUNTIME_OUTPUT_DIRECTORY "${QFLI_GIT_OUTPUT_DIR}"
		BUILD_WITH_INSTALL_RPATH TRUE
		INSTALL_RPATH "$ORIGIN")
endif()
