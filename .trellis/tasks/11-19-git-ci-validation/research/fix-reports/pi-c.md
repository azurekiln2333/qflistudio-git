# FIX_REPORT — Pi C（`lib/`、`test/`）

对应报告：`.trellis/tasks/11-19-git-ci-validation/research/cross-check/a-checks-dart.md`。
分支：`fx/pi-c`。改动只在 `lib/src/repository.dart`、`test/error_mapping_test.dart`、`test/json_parsing_test.dart`。

## 处理结果

每条修复一个提交，提交信息带问题编号。

### 中-2：`CancelToken.dispose()` 可能在操作运行时释放内存

提交 `ff9df11 fix(dart): keep CancelToken alive while operations run (A mid-2)`

- `CancelToken` 增加未完成操作计数 `_pending` 和释放请求标记 `_releaseRequested`。
- `clone`、`fetch`、`push` 在调用前 `acquireOperation()` 计数加 1。三个方法改为 `async`，在 `finally` 里 `releaseOperation()` 计数减 1。
- `dispose()` 只置释放请求。计数不为 0 时推迟释放。计数归零时 `_freeFlag()` 才 `malloc.free`。
- 计数大于 0 时 `cancel()` 仍然写标志，取消不会丢。`_freeFlag()` 先把标志清零再释放。
- `pendingOperations`、`acquireOperation()`、`releaseOperation()` 标 `@visibleForTesting`，供测试模拟运行中的操作。`cancel()`、`dispose()` 的对外约定不变。
- 新增 4 个单元测试：运行中 dispose 后标志仍可读写且在 release 后释放；无操作时 dispose 立即释放；重叠计数；释放后可再次开始新操作。

### 低-3：`status_bits` 被丢弃

提交 `4ca93c3 fix(dart): expose statusBits on GitStatusEntry (A low-3)`

- `GitStatusEntry` 增加 `final int statusBits`，缺省 0。
- `GitStatusEntry.fromJson` 从 `status_bits` 读取。缺失或不是整数时取 0。
- `status` 的注释写明它是 `statusBits` 最高位的文本形式。
- 新增 2 个解析测试：正常读取 256 和 512；缺失与字符串值时取 0。

### 低-4：分配顺序导致漏释放

提交 `e3c3d5f fix(dart): free native blocks when a later allocation throws (A low-4)`

- `_initNative`、`clone`、`init`、`_withRepo` 的 `calloc` 与 `toNativeUtf8` 全部移进 `try`。
- 指针改为可空局部变量，初值 `nullptr`。`finally` 判空后释放，顺序与分配相反。
- 释放顺序仍是先释放后分配的块，不会二次释放。

### 低-5：未调用 `ensureInitialized` 时 `qg_init` 被跳过

提交 `0421cbb fix(dart): call qg_init without a CA file too (A low-5)`

- `_initIfNeeded` 删除 `caFile == null` 的提前返回。
- 空 `caFile` 时 `_withUtf8` 传 `nullptr`，仍然调用 `bindings.init(nullptr, error)`。
- 注释改为说明空 CA 文件仍然初始化 libgit2，只是不带证书。

### 高-1：`GitHead.state` 注释与 C 实现不一致

提交 `8c72753 docs(dart): document clean and merge states on GitHead (A high-1)`

- 按大脑裁定，干净仓库为 `clean`，合并中为 `merge`。
- `GitHead.state` 注释改为：无操作进行时为 `clean`，合并打开时为 `merge`，其他状态用 libgit2 的状态名。
- Dart 侧没有把 `none` 写死的地方，`parseHead` 原样透传状态文本。

## 验证

`flutter analyze`：

```
Analyzing fx-c...
No issues found! (ran in 1.8s)
```

`flutter test`（33 个用例，原 27 个）：

```
00:00 +33: All tests passed!
```

新增用例落在 `test/error_mapping_test.dart` 的 `CancelToken` 组和 `test/json_parsing_test.dart` 的 `parseStatusEntries` 组。

## 未完成项

无。

## 接口问题

- `CancelToken` 新增三个 `@visibleForTesting` 成员。`design.md` 第 6 节只列了 `cancel()` 和 `dispose()`。三个成员只用于测试，不改变调用方用法。如需严格保持两个方法，可改为测试专用构造入口。
- 待确认 1（`qg_init` 与 isolate 生命周期）不在本轮范围。本轮让每次操作都调用 `qg_init`，libgit2 引用计数继续只增不减。
- 待确认 2（`cancel()` 跨 isolate 可见性）不在本轮范围。当前靠 native 侧的 `volatile` 读取。