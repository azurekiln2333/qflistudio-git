# CROSS_CHECK — Pi A（`lib/` Dart 插件）

检查对象：`lib/qfli_git.dart`、`lib/src/bindings.dart`、`lib/src/library.dart`、`lib/src/repository.dart`（提交 `c1d73d1`）。
对照：`native/include/qfli_git.h`、`native/src/qfli_git.c`、`.trellis/tasks/11-19-git-ci-validation/design.md` 第 2、6 节。

已跑的命令（只读）：
- `dart analyze lib` → `No issues found!`
- `flutter test test` → `All tests passed!`（27 个用例）

## 已确认的问题

### 1. 文档里 `state` 的示例值与 C 实现不一致（高）

- 位置：`lib/src/repository.dart:91`（`GitHead.state` 注释），`native/src/qfli_git.c:1291`，示例 `example/integration_test/flow_test.dart:55`、`:98`。
- 问题：Dart 注释只举了 `clean` 和 `merge` 两个例子，而 `qg_state_token` 对 `GIT_REPOSITORY_STATE_NONE` 返回 `"none"`。干净仓库实际拿到 `"none"`，不是 `"clean"`。
- 为什么是问题：示例集成测试断言 `expect(baseHead.state, 'clean')`，在真实库上会直接失败；调用方按注释判断会误判。
- 建议改法：二选一并统一。要么把 `qg_state_token` 的 `NONE` 改成 `"clean"`，要么把 Dart 注释和示例测试改成 `"none"`。只改其中一侧，不要两处都改。
- 归属：C 实现归 Pi C，Dart 注释归 Pi A；本条在这里登记，请大脑指派一侧修改。

### 2. `CancelToken.dispose()` 可能在操作仍在运行时释放内存（中）

- 位置：`lib/src/repository.dart:145-179`（`_flag` 在 151 行 `malloc`，177 行 `malloc.free`），调用点在 `clone`/`fetch`/`push`（`repository.dart:313`、`:583`、`:613` 取地址）。
- 问题：`cancel()` 只写标志位，`dispose()` 直接 `malloc.free(_flag)`。后台 isolate 里的 `qg_clone`/`qg_fetch`/`qg_push` 会在进度回调里读这个 `int32_t`。如果在操作返回前调用 `dispose()`，native 侧就写到已释放的内存，属于 use-after-free；同时 `cancel()` 的效果也会丢。
- 为什么是问题：Flutter 里常见的写法是 `State.dispose()` 里清理 token，而网络操作可能还没返回。文档只写了一句 “Call it after the operation finished”，没有任何机制保证，误用会崩溃。
- 建议改法：给 `CancelToken` 加一个未完成操作计数（`fetch`/`push`/`clone` 在调用前 `+1`、`finally` 里 `-1`），`dispose()` 在计数不为 0 时只置标志、把真正 `free` 推迟到计数归零；或者至少 `assert` 并在 `dispose` 时不再清零标志位。补一条“操作未结束时 dispose”的单元测试（可 mock 地址，不必真跑网络）。
- 严重程度：中。

### 3. JSON 里有 `status_bits`，Dart 层把它丢掉（低）

- 位置：`native/include/qfli_git.h:91`（`{"path":..,"status":..,"status_bits":256}`）、`native/src/qfli_git.c:1243`，`lib/src/repository.dart:64-78`。
- 问题：`GitStatusEntry` 只解析 `path` 和 `status`，`status_bits` 直接被丢弃。
- 为什么是问题：一个条目可能同时有多位状态（例如 `worktree_modified | worktree_deleted`），`status` 只是优先级最高的那一个字符串，Dart 调用方拿不到完整信息，做多选筛选做不到。
- 建议改法：给 `GitStatusEntry` 加 `final int statusBits`（缺省 0），从 JSON 读取 `status_bits`，并补一条解析测试。
- 严重程度：低。

### 4. 分配顺序：`calloc<QgError>` 之后的分配抛异常时会漏（低）

- 位置：`lib/src/repository.dart:358-359`（`init`）、`:681-682`（`_withRepo`）、`native` 无需改动；`clone`（`:316-317`）、`_initNative`（`:273-274`）同型。
- 问题：`calloc<QgError>()`、`calloc<Pointer<QgRepo>>()` 的 `try` 从第二个分配之后才开始（`_initNative` 里 `caFile.toNativeUtf8()` 也在 `try` 之前）。第二个分配或 `toNativeUtf8` 抛出 `ArgumentError` 时，第一个分配的指针就漏了。
- 为什么是问题：内存紧张时（正是 `ArgumentError` 会出现的场景）每次泄漏 520 字节，且正好发生在内存不足时。
- 建议改法：把两个分配都放进 `try`，用可空局部变量在 `finally` 里判空释放；或先 `try` 再逐个分配。
- 严重程度：低。

### 5. 未调用 `ensureInitialized` 时 `qg_init` 静默跳过（低）

- 位置：`lib/src/repository.dart:710-726`（`_initIfNeeded`，716 行 `caFile == null` 直接返回），`:685` 每次操作都调它。
- 问题：`qg_init` 是 `git_libgit2_init` 的唯一入口（`native/src/qfli_git.c:311`）。如果调用方忘了先 `ensureInitialized`，`QfliGit.caFile` 为 null，`qg_init` 一次也不会被调用，libgit2 处于未初始化状态。
- 为什么是问题：设计说 `ensureInitialized` 必须在第一个操作前调用，但漏调时不会得到清楚错误，只有 libgit2 的未初始化行为（报错内容依赖内部实现，可能崩溃）。
- 建议改法：`caFile == null` 时也调 `qg_init(nullptr, error)`（`qg_init` 接受 null），把 CA 设置留给后续的 `ensureInitialized`。
- 严重程度：低。

## 已检查、未发现问题的项目

- FFI 签名：`qg_api_version`、`qg_libgit2_version`、`qg_mbedtls_version`、`qg_init`、`qg_shutdown`、`qg_repo_init`、`qg_repo_open`、`qg_repo_free`、`qg_clone`、`qg_fetch`、`qg_push`、`qg_add_all`、`qg_commit`、`qg_branch_create`、`qg_checkout_branch`、`qg_merge`、`qg_merge_commit`、`qg_conflicts_json`、`qg_status_json`、`qg_head_json`、`qg_string_free` 逐个对照头文件，参数个数、顺序、指针层级、`Int32`/`Uint8` 宽度一致，共 21 个。
- `qg_error` 结构：`Int32 code`、`Int32 klass`、`Array<Uint8, 512>` 与头文件一致；`_messageOffset` 用 `sizeOf<_QgErrorHead>()` 得到 8，等于 C 的 `offsetof(qg_error, message)`；`message` 用字节视图读，可容纳非 ASCII。
- `malloc`/`calloc` 释放：`repository.dart` 共 11 处 `malloc`/`calloc` 分配，除 `_flag`（见问题 2）外全部在 `finally` 释放：`_initNative` 的 `error`+`caFilePointer`、`clone`/`init` 的 `out`+`error`、`merge` 的 `result`、`readJson` 的 `out`、`_withRepo` 的 4 个、`_withUtf8` 的每个字符串、`_withOid` 的缓冲区。`toNativeUtf8` 产生的指针走 `_withUtf8`，JSON 指针在 `readJson` 内的 `finally` 调 `qg_string_free`（`bindings.dart` 中 `stringFree` 的签名是 `void(char *)`）。
- 失败路径不空释放：`malloc`/`calloc` 分配失败会在 pub.dev `ffi` 2.1.4/2.2.0 抛 `ArgumentError` 而不是返回 `nullptr`；C 侧失败路径先 `*out_json = NULL`、`*out = NULL`，`qg_repo_wrap` 失败时也保持 `NULL`，所以 `stringFree(nullptr)`/`repoFree(nullptr)` 不会发生。
- `qg_repo` 指针不跨 isolate：`GitRepository` 只持有 `String path`，每个操作在 isolate 内 `qg_repo_open`，`finally` 里 `qg_repo_free`；`Isolate.run` 的闭包只捕获 `String` 和地址整数，没有捕获 `this` 或 `Pointer` 对象。
- 令牌：`token` 只出现在 `clone`/`fetch`/`push` 的形参和 `_withUtf8` 列表里，`lib/` 中没有任何 `print`/`debugPrint`/日志调用；`GitException` 的 `toString` 只输出 `code`、`klass`、`message`，`message` 来自 `qg_error.message`（libgit2 文本），Dart 侧不会把 token 写进去。
- `library.dart` 平台分支与 design 第 5 节一致：iOS 用 `qfli_git.framework/qfli_git`，Android/`ohos` 用 `libqfli_git.so`，`QFLI_GIT_LIBRARY` 覆盖。
- 公开 API 与 design 第 6 节：类、方法、参数、`MergeOutcome` 四个值、`GitException` 字段、`CancelToken` 两个方法都齐全；`dart analyze lib` 无告警，`flutter test` 27 个用例全过。

## 待确认

1. `qg_init` 与 isolate 生命周期（中）。
   - 位置：`lib/src/repository.dart:312-347`（`clone`）、`:680-686`（`_withRepo`）、`native/src/qfli_git.c:311-337`。
   - 情况：`git_libgit2_init` 是进程级引用计数。每个 isolate 的每个操作都调一次 `_initIfNeeded`，没有任何 `qg_shutdown` 配对，引用计数只增不减。
   - 不确定点：libgit2 1.9.7 在多个 isolate（多个线程）里重复进入 `git_libgit2_init` 是否安全；需不需要在 isolate 退出时配对 `qg_shutdown`。设计文档没有约定，我也没有在真机上跑过。
   - 建议：由大脑确认，或把“库只初始化一次”的约定写进 design 第 6 节。

2. `CancelToken.cancel()` 的可见性（低）。
   - 位置：`lib/src/repository.dart:163-168`。
   - 情况：`cancel()` 写入的 `Pointer<Int32>` 属于主 isolate，读者是另一个 isolate 的线程。C 侧用 `const volatile int32_t *` 读，Dart 侧没有内存屏障保证。
   - 不确定点：Dart VM 里对 native heap 的写入跨 isolate 是否一定及时可见。没有实测。
