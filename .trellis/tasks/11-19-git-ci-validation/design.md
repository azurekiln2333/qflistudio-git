# 设计：CI 技术验证

## 1. 仓库布局

```
qfli_git/
├── pubspec.yaml                 # Flutter FFI 插件，android/ios/ohos 均为 ffiPlugin: true
├── lib/
│   ├── qfli_git.dart            # 公开 API
│   └── src/
│       ├── bindings.dart        # 手写 dart:ffi 绑定，对应 qfli_git.h
│       ├── library.dart         # 按平台打开库
│       └── repository.dart      # GitRepository、GitException、CancelToken
├── assets/cacert.pem            # Mozilla CA 根证书包（R1.3）
├── native/
│   ├── CMakeLists.txt           # 构建 libqfli_git，静态链接 libgit2 + mbedTLS
│   ├── include/qfli_git.h       # 精简 C 接口（第 2 节）
│   ├── src/qfli_git.c
│   ├── exports.map              # 版本脚本：只导出 qg_*
│   └── test/smoke.c             # 主机冒烟测试
├── third_party/
│   ├── versions.json            # 上游名称、版本、URL、SHA-256
│   └── README.md                # 许可证清单、补丁说明
├── tool/
│   ├── fetch_sources.py         # 下载并校验上游包，解压到 native/build/src/
│   ├── build_native.sh          # 统一构建入口（第 3 节）
│   ├── install_ohos_sdk.sh      # 下载并校验鸿蒙 SDK（Linux 原生包）
│   ├── ci/collect_artifacts.py  # 生成 manifest.json，检查页对齐和导出符号
│   └── import_artifacts.py      # 大脑用：校验产物，复制到插件平台目录
├── android/                     # 插件 Android 模块，预编译库在 src/main/jniLibs/<abi>/
├── ios/                         # qfli_git.podspec，预编译库在 Frameworks/qfli_git.xcframework
├── ohos/                        # 插件 HAR 模块，预编译库在 libs/<abi>/
├── example/                     # 示例应用 + integration_test
├── .github/workflows/native.yml
├── LICENSE                      # GPL-3.0-or-later
└── README.md
```

`native/build/`、`build/`、`.dart_tool/`、`example/build/` 写入 `.gitignore`。

## 2. C 接口（`native/include/qfli_git.h`）

约定：

- 所有函数返回 `int`。`0` 表示成功，负数表示失败。
- 失败时填写调用方传入的 `qg_error`。接口不使用线程局部变量，Dart isolate 换线程不影响错误读取。
- 输出字符串由 `malloc` 分配，调用方用 `qg_string_free` 释放。
- `cancel_flag` 指向调用方分配的 `int32_t`。值变为非 0 后，进度回调返回非 0，操作以 `QG_ECANCELED` 结束。可以传 `NULL`。
- 字符串全部为 UTF-8。路径为绝对路径。

```c
#define QG_API_VERSION 1
#define QG_ECANCELED (-1000)
#define QG_ECONFLICT (-1001)   /* 合并提交时仍有冲突 */
#define QG_EINVALID  (-1002)   /* 参数无效 */

typedef struct qg_error {
  int code;          /* libgit2 错误码或 QG_E* */
  int klass;         /* libgit2 git_error_t，非 libgit2 错误为 0 */
  char message[512];
} qg_error;

typedef struct qg_repo qg_repo;

int qg_api_version(void);
const char *qg_libgit2_version(void);             /* 静态字符串，如 "1.9.7" */
const char *qg_mbedtls_version(void);

int qg_init(const char *ca_file, qg_error *err);  /* git_libgit2_init + 设置 CA 文件。可重复调用 */
int qg_shutdown(void);

int qg_repo_init(const char *path, int bare, qg_repo **out, qg_error *err);
int qg_repo_open(const char *path, qg_repo **out, qg_error *err);
void qg_repo_free(qg_repo *repo);

int qg_clone(const char *url, const char *path, const char *username, const char *token,
             const int32_t *cancel_flag, qg_repo **out, qg_error *err);
int qg_fetch(qg_repo *repo, const char *remote, const char *username, const char *token,
             const int32_t *cancel_flag, qg_error *err);
int qg_push(qg_repo *repo, const char *remote, const char *refspec, const char *username,
            const char *token, const int32_t *cancel_flag, qg_error *err);

int qg_add_all(qg_repo *repo, qg_error *err);     /* 等价 git add -A */
int qg_commit(qg_repo *repo, const char *message, const char *name, const char *email,
              char out_oid[41], qg_error *err);
int qg_branch_create(qg_repo *repo, const char *name, const char *start_point /* NULL 为 HEAD */,
                     qg_error *err);
int qg_checkout_branch(qg_repo *repo, const char *name, qg_error *err); /* 安全检出，有冲突改动时失败 */

/* out_result：0 已是最新，1 快进，2 已生成合并提交，3 有冲突（索引和工作区已写入冲突，MERGE_HEAD 已写入） */
int qg_merge(qg_repo *repo, const char *branch, const char *name, const char *email,
             int *out_result, char out_oid[41], qg_error *err);
int qg_merge_commit(qg_repo *repo, const char *message, const char *name, const char *email,
                    char out_oid[41], qg_error *err); /* 父提交为 HEAD + MERGE_HEAD，结束后清理合并状态 */

int qg_conflicts_json(qg_repo *repo, char **out_json, qg_error *err); /* ["path", ...] */
int qg_status_json(qg_repo *repo, char **out_json, qg_error *err);    /* [{"path":..,"status":..}, ...] */
int qg_head_json(qg_repo *repo, char **out_json, qg_error *err);      /* {"branch":..,"oid":..,"state":..} */
void qg_string_free(char *s);
```

实现要点：

- 凭据回调用 `git_credential_userpass_plaintext_new(username, token)`。`username` 为 `NULL` 时用 `"git"`。同一次操作第二次进入回调时返回 `GIT_EAUTH`，避免死循环。
- 证书校验使用 libgit2 默认逻辑。不覆盖 `certificate_check`。
- `qg_merge` 先调用 `git_merge_analysis`。普通合并调用 `git_merge`，然后检查索引冲突。无冲突时直接生成合并提交。
- `qg_add_all` 调用 `git_index_add_all` 和 `git_index_update_all`，然后写回索引。
- `qg_merge_commit` 在索引仍有冲突时返回 `QG_ECONFLICT`。

## 3. 构建入口（`tool/build_native.sh`）

```
tool/build_native.sh --platform <host|android|ohos|ios-device|ios-simulator> \
                     [--abi <abi>] --out <dir>
```

- 前置：`tool/fetch_sources.py` 已运行。环境变量 `ANDROID_NDK_HOME`、`OHOS_SDK_HOME` 按平台需要设置。
- 输出：`<dir>/libqfli_git.so`（host、android、ohos）或 `<dir>/qfli_git.framework`（iOS）。同时输出 `qfli_git.h`。
- libgit2 CMake 选项：`BUILD_SHARED_LIBS=OFF BUILD_TESTS=OFF BUILD_CLI=OFF USE_SSH=OFF USE_HTTPS=mbedTLS USE_SHA1=CollisionDetection USE_SHA256=Builtin USE_BUNDLED_ZLIB=ON REGEX_BACKEND=builtin USE_HTTP_PARSER=builtin USE_GSSAPI=OFF USE_NTLMCLIENT=OFF USE_ICONV=OFF`。实际选项名以 v1.9.7 的 `CMakeLists.txt` 为准。
- mbedTLS 用 CMake 静态编译，关闭程序和测试。
- 编译参数：`-fPIC -fvisibility=hidden -ffunction-sections -fdata-sections -O2`。
- 链接参数：`-Wl,--gc-sections -Wl,--version-script=native/exports.map -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384`（Android、鸿蒙）。链接后用 `llvm-strip --strip-unneeded`。
- Android：NDK 28.2.13676358，`ANDROID_PLATFORM=android-24`。
- 鸿蒙：SDK 自带 `native/build/cmake/ohos.toolchain.cmake`，`OHOS_ARCH` 取 `arm64-v8a` 或 `x86_64`。
- iOS：`CMAKE_SYSTEM_NAME=iOS`，最低版本 13.0，库目标设 `FRAMEWORK TRUE`。模拟器先分架构编译，再用 `lipo` 合并。CI 用 `xcodebuild -create-xcframework` 合成 xcframework。

## 4. CI（`.github/workflows/native.yml`）

触发：推送 `main`、推送 `native-v*` 标签、手动触发。Actions 用提交 SHA 锁版本，参照 `qfli_go/.github/workflows/native-runtime.yml`。

| 任务 | Runner | 内容 |
|---|---|---|
| `host-smoke` | ubuntu-24.04 | 编 host 库和 `smoke.c`，运行冒烟测试 |
| `android` | ubuntu-24.04 | 3 个 ABI，收集产物，检查页对齐和导出符号 |
| `ohos` | ubuntu-24.04 | 安装鸿蒙 SDK 5.0.0（校验 SHA-256），2 个 ABI，同样检查 |
| `ios` | macos-15 | 真机 + 模拟器，合成 xcframework |
| `example-android` | ubuntu-24.04 | 下载 android 产物，导入插件目录，`flutter build apk --debug` |
| `example-ios` | macos-15 | 下载 ios 产物，导入，`flutter build ios --simulator --no-codesign` |
| `release` | ubuntu-24.04 | 仅 `native-v*` 标签：把全部产物 zip 发布到 GitHub Release |

- 冒烟测试在本地建裸仓库作为远端，跑完 clone → commit → push → 分支 → 冲突合并 → 解决 → 合并提交 → push → 重新 clone 校验。
- 冒烟测试再用 HTTPS 匿名 clone 一个小型公开仓库，验证 mbedTLS 和 CA 证书。
- 鸿蒙 SDK 包与 qfli_go 相同：`ohos-sdk-windows_linux-public.tar.gz`，SHA-256 `f06a2a8a…0ecc`。CI 取其中的 Linux native 包。
- 产物名：`qfli-git-<platform>-<sha>`。保留 14 天。
- 鸿蒙 example 不在 CI 构建。鸿蒙 example 由 Pi 在本机用 flutter_ohos 构建。

## 5. 插件打包

| 平台 | 做法 | 风险与退路 |
|---|---|---|
| Android | `android/build.gradle` 不配置 CMake。预编译库放 `src/main/jniLibs/<abi>/`，Gradle 默认打包。 | 低。 |
| iOS | podspec 设 `vendored_frameworks = 'Frameworks/qfli_git.xcframework'`。动态 framework 由 CocoaPods 嵌入。 | 中。本机无 Mac，只在 CI 验证链接。 |
| 鸿蒙 | `ohos/` 是 HAR 模块，删除模板里的 `externalNativeOptions`。预编译库放 `ohos/libs/<abi>/`。 | 高。需要验证 flutter_ohos 是否把纯 ffiPlugin 的 HAR 加入应用，HAR 的 `libs/` 是否进入 HAP。退路：应用把 `.so` 复制到 `ohos/entry/libs/<abi>/`（qfli_go 现有做法），插件 README 写明步骤。 |

Dart 打开库：

- iOS：`DynamicLibrary.open('qfli_git.framework/qfli_git')`。
- Android、鸿蒙：`DynamicLibrary.open('libqfli_git.so')`。鸿蒙用 `Platform.operatingSystem == 'ohos'` 判断。
- 环境变量 `QFLI_GIT_LIBRARY` 可覆盖库路径，供主机测试使用。

## 6. Dart API

```dart
class QfliGit {
  static Future<void> ensureInitialized();  // 复制 assets/cacert.pem 到应用支持目录，调用 qg_init
  static String get libgit2Version;
}

class GitRepository {
  final String path;
  static Future<GitRepository> clone({required String url, required String path,
      String? username, String? token, CancelToken? cancel});
  static Future<GitRepository> init(String path, {bool bare = false});
  static GitRepository open(String path);
  Future<void> addAll();
  Future<String> commit(String message, GitAuthor author);
  Future<void> createBranch(String name, {String? from});
  Future<void> checkout(String name);
  Future<MergeOutcome> merge(String branch, GitAuthor author); // upToDate / fastForward / merged / conflicts
  Future<List<String>> conflicts();
  Future<String> commitMerge(String message, GitAuthor author);
  Future<List<GitStatusEntry>> status();
  Future<GitHead> head();
  Future<void> fetch({String remote = 'origin', String? username, String? token, CancelToken? cancel});
  Future<void> push({String remote = 'origin', required String refspec,
      String? username, String? token, CancelToken? cancel});
}

class GitException implements Exception { final int code; final int klass; final String message; }
class CancelToken { void cancel(); void dispose(); } // 内部 malloc 一个 Int32，把地址传给后台 isolate
```

- 每个操作用 `Isolate.run` 执行。后台 isolate 内打开库、`qg_repo_open`、执行操作、`qg_repo_free`。
- `qg_repo` 指针不跨 isolate 传递。
- 令牌只作为参数传入，不写文件，不打印。

## 7. 产物导入与版本

- CI 产物经大脑审查后，由 `tool/import_artifacts.py` 校验 `manifest.json` 中的 SHA-256，复制到插件平台目录，写入 `native_libs.lock.json`（来源提交、各文件 SHA-256）。
- 只有大脑提交预编译库。Pi 本地测试可以导入产物，但不提交库文件。
- 打 `native-v*` 标签后，Release 提供公开下载。`import_artifacts.py` 支持从 Release URL 或本地目录导入。

## 8. 证书

- 三端统一用插件自带的 `cacert.pem`。
- 鸿蒙和 Android 不依赖系统证书路径。
- 证书包更新方式：改 `third_party/versions.json` 的 URL 和 SHA-256，重新运行 `fetch_sources.py`，复制到 `assets/`。

## 9. 主要风险

| 风险 | 应对 |
|---|---|
| libgit2 v1.9.7 不兼容 mbedTLS 3.6 | Pi A 第一步验证。不兼容时报告大脑，改选 libgit2 支持的 mbedTLS 版本。 |
| 鸿蒙工具链编译 libgit2 报错 | 优先用 CMake 参数解决。必须改源码时用补丁文件。 |
| flutter_ohos 不打包插件 HAR 的 `.so` | 第 5 节退路。 |
| 鸿蒙 musl 的 `dlopen` 拒绝 TLS 重定位 | libgit2 使用 pthread TLS。用 `llvm-readelf` 检查无 `TLS` 初始执行模型重定位。 |
