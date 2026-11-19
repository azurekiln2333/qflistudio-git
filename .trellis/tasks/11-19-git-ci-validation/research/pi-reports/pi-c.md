# Pi C 报告：Dart 插件

分支 `wt/pi-c`，worktree `D:\MyNewProjects\_wt\qfli_git\pi-c`。

## 一、改动文件

新增：

- `pubspec.yaml`：包名 `qfli_git`，`publish_to: none`，Dart SDK `^3.11.0`。`plugin.platforms` 下 android、ios、ohos 都是 `ffiPlugin: true`。依赖只有 `ffi`、`path`、`path_provider`、`path_provider_ohos`。声明资源 `assets/cacert.pem`。
- `analysis_options.yaml`：启用 `package:flutter_lints/flutter.yaml`。
- `lib/qfli_git.dart`：公开入口，转出 `src/repository.dart` 的 API 和错误码常量。
- `lib/src/bindings.dart`：手写 `dart:ffi` 绑定。`QgError` 为 `Struct`，`message` 是 512 字节 `Array<Uint8>`。`QgRepo` 为 `Opaque`。附 `NativeError` 快照类和 UTF-8 读取工具。
- `lib/src/library.dart`：按设计第 5 节打开库。iOS 开 `qfli_git.framework/qfli_git`，Android 与鸿蒙开 `libqfli_git.so`。`QFLI_GIT_LIBRARY` 覆盖路径。每个 isolate 各自打开并缓存。
- `lib/src/repository.dart`：`QfliGit`、`GitRepository`、`GitException`、`CancelToken`、`GitAuthor`、`GitStatusEntry`、`GitHead`、`MergeOutcome`，以及 JSON 解析函数。
- `android/build.gradle`：AGP 8.11.1、`compileSdk = 36`、`minSdk = 24`、namespace `com.azurekiln.qfli_git`。没有 CMake 配置，也没有 `externalNativeBuild`。
- `android/settings.gradle`、`android/.gitignore`、`android/src/main/AndroidManifest.xml`。
- `android/src/main/jniLibs/{arm64-v8a,armeabi-v7a,x86_64}/.gitkeep`。
- `ios/qfli_git.podspec`：`vendored_frameworks = 'Frameworks/qfli_git.xcframework'`，`s.platform = :ios, '13.0'`。
- `ios/Frameworks/.gitkeep`。
- `ohos/build-profile.json5`：照 `ohos.tmpl` 写，删掉 `externalNativeOptions`。
- `ohos/hvigorfile.ts`、`ohos/oh-package.json5`、`ohos/index.ets`、`ohos/src/main/module.json5`（`type: har`）、`ohos/.gitignore`。`ohos/BuildProfile.ets` 由 hvigor 生成，`ohos.tmpl` 的 `.gitignore` 本来就忽略它，所以不提交。
- `ohos/libs/{arm64-v8a,x86_64}/.gitkeep`。
- `test/json_parsing_test.dart`：conflicts、status、head 的 JSON 解析。
- `test/error_mapping_test.dart`：`qg_error` 布局、`NativeError` 读取、错误码到 `GitException` 的映射、`CancelToken` 生命周期。
- `LICENSE`：从 `D:\MyNewProjects\qflistudio\LICENSE` 复制的 GPL-3.0 全文，35149 字节，与源文件一致。
- `README.md`：用途、平台、预编译库来源、导入步骤、Dart 用法、取消、错误、API 表、主机测试。
- `CHANGELOG.md`：`0.1.0`。

没有建 `example/`。没有写 `assets/cacert.pem`。

## 二、怎么验证

1. `D:\ProgramFiles\flutter_ohos\bin\flutter pub get`
2. `D:\ProgramFiles\flutter_ohos\bin\flutter analyze`
3. `D:\ProgramFiles\flutter_ohos\bin\flutter test`
4. `D:\ProgramFiles\flutter_ohos\bin\dart format --output=none --set-exit-if-changed lib test`
5. 三个 `.json5` 文件用 `ConvertFrom-Json` 校验语法。

## 三、验证结果

`flutter pub get`：

```
+ path_provider_ohos 2.2.1
+ ffi 2.1.4 (2.2.0 available)
Changed 37 dependencies!
```

`flutter analyze`：

```
Analyzing pi-c...
No issues found! (ran in 2.9s)
```

`flutter test`：

```
00:00 +26: test/json_parsing_test.dart: MergeOutcome.fromCode rejects an unknown result
00:00 +27: All tests passed!
```

`dart format`：

```
Formatted 6 files (0 changed) in 0.02 seconds.
```

`.json5` 语法：`ohos/build-profile.json5`、`ohos/oh-package.json5`、`ohos/src/main/module.json5` 全部 OK。

### FFI 签名对照表

`design.md` 第 2 节逐一对应 `lib/src/bindings.dart` 的 typedef：

| C 函数 | Dart typedef |
|---|---|
| `int qg_api_version(void)` | `Int32 Function()` |
| `const char *qg_libgit2_version(void)` | `Pointer<Utf8> Function()` |
| `const char *qg_mbedtls_version(void)` | `Pointer<Utf8> Function()` |
| `int qg_init(const char *ca_file, qg_error *err)` | `Int32 Function(Pointer<Utf8>, Pointer<QgError>)` |
| `int qg_shutdown(void)` | `Int32 Function()` |
| `int qg_repo_init(const char *path, int bare, qg_repo **out, qg_error *err)` | `Int32 Function(Pointer<Utf8>, Int32, Pointer<Pointer<QgRepo>>, Pointer<QgError>)` |
| `int qg_repo_open(const char *path, qg_repo **out, qg_error *err)` | `Int32 Function(Pointer<Utf8>, Pointer<Pointer<QgRepo>>, Pointer<QgError>)` |
| `void qg_repo_free(qg_repo *repo)` | `Void Function(Pointer<QgRepo>)` |
| `int qg_clone(url, path, username, token, cancel_flag, out, err)` | `Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Int32>, Pointer<Pointer<QgRepo>>, Pointer<QgError>)` |
| `int qg_fetch(repo, remote, username, token, cancel_flag, err)` | `Int32 Function(Pointer<QgRepo>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Int32>, Pointer<QgError>)` |
| `int qg_push(repo, remote, refspec, username, token, cancel_flag, err)` | `Int32 Function(Pointer<QgRepo>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Int32>, Pointer<QgError>)` |
| `int qg_add_all(repo, err)` | `Int32 Function(Pointer<QgRepo>, Pointer<QgError>)` |
| `int qg_commit(repo, message, name, email, out_oid, err)` | `Int32 Function(Pointer<QgRepo>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Uint8>, Pointer<QgError>)` |
| `int qg_branch_create(repo, name, start_point, err)` | `Int32 Function(Pointer<QgRepo>, Pointer<Utf8>, Pointer<Utf8>, Pointer<QgError>)` |
| `int qg_checkout_branch(repo, name, err)` | `Int32 Function(Pointer<QgRepo>, Pointer<Utf8>, Pointer<QgError>)` |
| `int qg_merge(repo, branch, name, email, out_result, out_oid, err)` | `Int32 Function(Pointer<QgRepo>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Int32>, Pointer<Uint8>, Pointer<QgError>)` |
| `int qg_merge_commit(repo, message, name, email, out_oid, err)` | `Int32 Function(Pointer<QgRepo>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Uint8>, Pointer<QgError>)` |
| `int qg_conflicts_json(repo, char **out_json, err)` | `Int32 Function(Pointer<QgRepo>, Pointer<Pointer<Utf8>>, Pointer<QgError>)` |
| `int qg_status_json(repo, char **out_json, err)` | 同上 |
| `int qg_head_json(repo, char **out_json, err)` | 同上 |
| `void qg_string_free(char *s)` | `Void Function(Pointer<Utf8>)` |

`qg_error`：`code` 与 `klass` 是 `Int32`，`message` 是 `Array<Uint8>` 512 字节。`sizeOf<QgError>()` 为 520，测试断言等于 `2 * sizeOf<Int32>() + 512`。

`char out_oid[41]` 在 Dart 侧是 `Pointer<Uint8>` 指向 41 字节缓冲区，调用后按 NUL 截断读取。

资源释放：所有 `malloc` 出的字符串、`calloc` 出的结构、`qg_*_json` 返回的字符串都在 `finally` 里释放。`qg_string_free` 只用于 C 层分配的字符串，Dart 分配的用 `malloc.free` / `calloc.free`。

取消与 isolate：`CancelToken` 用 `malloc<Int32>` 分配，构造函数清零。进入后台 isolate 前只取地址（`int`），`qg_repo` 指针不跨 isolate。每次操作在 isolate 内 `qg_repo_open`，结束时 `qg_repo_free`。

令牌：只作为 `String?` 参数传给 C 层。不写文件，不打印，不放进 `message`。README 与代码注释都不出现真实令牌。

## 四、未完成项

1. 没有在真机上验证。本机没有 Android 设备接入，也没有鸿蒙设备，`hdc list targets` 为空。插件与原生库的联调要等 Pi A 的库导入后才能做。
2. `assets/cacert.pem` 没有提交，属于 Pi A。为了本地跑通 `flutter analyze`（缺资源会报 `asset_does_not_exist`），worktree 里放了一个未跟踪的占位文件，内容只有三行注释。提交里不含它，Pi A 的真实证书包会直接覆盖同名文件。
3. `pubspec.lock` 未提交。插件包按惯例不提交锁文件。
4. Android 的 `build.gradle` 没有在本机执行 Gradle 构建。原生库还没导入，`flutter build apk` 会因缺少 `.so` 失败。CI 的 `example-android` 任务在有产物后才验证链接。
5. iOS 的 podspec 需要 `ios/Frameworks/qfli_git.xcframework` 才能 `pod install`。产物导入前，iOS 构建会停在 CocoaPods 这一步。本机无 Mac，按设计只在 CI 验证。
6. 鸿蒙 HAR 是否把 `libs/<abi>/*.so` 带进 HAP，本机未验证，属于 Pi D 的打包验证范围。按设计第 5 节的退路，插件 README 已写明应用可直接把 `.so` 放到 `ohos/entry/libs/<abi>/`。当前 README 只写了三个预编译库目录，退路细节可以等 Pi D 结论后补。

## 五、接口问题

不改约定，按 `design.md` 实现。以下几点需要在集成时确认。

1. `qg_status_json` 的 `status` 取值和 `qg_head_json` 的 `state` 取值在 `design.md` 里只写了 `"status":..`、`"state":..`，没有给词表。Dart 侧按不透明字符串处理，解析不会因新词失败，但 example 的界面会直接显示这个字符串。建议 Pi A 在 `qfli_git.h` 注释里固定取值，例如 status 用 `modified`/`new`/`deleted`/`renamed`/`typechange`/`conflicted`，state 用 `clean`/`merge`/`rebase`/`cherrypick`/`revert`/`bisect`。Dart 侧改词表不需要改绑定。
2. `GitAuthor` 的构造形式设计里没写。我实现为 `const GitAuthor(String name, String email)` 位置参数。Pi D 的 example 按此调用即可。如果希望改成命名参数，需要改 `lib/src/repository.dart` 与 README 两处。
3. `GitHead.branch` 在 detached HEAD 时返回 `null`，`state` 缺失时返回空串。`design.md` 只写了字段名。
4. 在 `design.md` 的 Dart API 之外新增了几个只读成员，不破坏约定：`QfliGit.mbedtlsVersion`、`QfliGit.apiVersion`、`QfliGit.caFile`、`GitException.isCanceled`、`GitException.isConflict`、`MergeOutcome.fromCode`，以及顶层解析函数 `parseConflictPaths`、`parseStatusEntries`、`parseHead`。这些是取消与冲突判定的必需项，也让纯 Dart 测试可以覆盖解析逻辑。
5. `qg_error.code` 为 0 但返回值为负时，Dart 侧用返回值当 `code`，`message` 为空则填入 `native call failed with code <n>`。请 Pi A 保证失败路径一定写满 `err`。
6. `qg_shutdown` 绑定已就绪但 Dart 未暴露。进程退出前不需要显式调用，`git_libgit2_init` 的引用计数由 C 层维护。
