# 交叉检查（第二轮）：Pi B — `example/`

检查对象：`example/`（`lib/main.dart`、`lib/flow.dart`、`integration_test/flow_test.dart`、`test/widget_test.dart`、`pubspec.yaml`、`README.md`、`android/`、`ios/`、`ohos/` 平台壳）。
检查依据：`prd.md` R6.1–R6.4、`design.md` 第 6 节、`lib/src/repository.dart` 的实际映射、`native/src/qfli_git.c` 的取消与合并路径。
方式：只读，未修改被检查文件。

## 1. 已核对通过的内容

### R6.2 全流程步骤覆盖

`example/lib/flow.dart` 的 `FlowRunner.run()` 覆盖 R6.2 的全部步骤，顺序正确：

| PRD 步骤 | 代码位置 |
|---|---|
| clone | `flow.dart:101` |
| 改文件 | `flow.dart:113`、`flow.dart:134` |
| commit | `flow.dart:119`、`flow.dart:134` |
| 建分支 | `flow.dart:124` |
| 在分支上提交 | `flow.dart:134` |
| 在主分支制造冲突提交 | `flow.dart:146` |
| 合并 | `flow.dart:154` |
| 列出冲突 | `flow.dart:162` |
| 解决冲突 | `flow.dart:167` |
| 合并提交 | `flow.dart:175` |
| push | `flow.dart:179` |

`flow.dart:192-215` 的 `_step()` 用 `Stopwatch` 记录耗时，成功写 `detail`，失败写 `error`，并在 `main.dart:258-276` 按步骤渲染成卡片，耗时显示在 `main.dart:273`。R6.2 的「每一步显示结果和耗时」满足。

`flow.dart:119-150` 的提交顺序是「先建分支并在分支上提交，再回到主分支提交」，两条历史确实分叉，`flow.dart:154` 的合并会走 `git_merge_analysis` 的 NORMAL 分支并产生真冲突。应用流程本身的三方合并是正确的。

`flow.dart:156-158` 还断言合并结果必须是 `MergeOutcome.conflicts`。合并没有产生冲突时该步骤直接失败，流程不会假装成功。

### R6.3 令牌只在内存

- 令牌只来自 `main.dart:36` 的 `TextEditingController`，输入框默认隐藏（`main.dart:160`）。
- `FlowSettings.token` 只传给 `GitRepository.clone`（`flow.dart:106`）和 `push`（`flow.dart:184`）。全目录没有 `print`、`log` 或 `File.write` 使用它。
- 失败文本来自 `GitException.message` 和 `error.toString()`（`flow.dart:217-222`）。`native/src/qfli_git.c` 的 `qg_credentials_cb` 只用 username/token 构造 `git_credential`，错误信息不含令牌；`GitException.toString()`（`repository.dart:138`）只输出 code、klass、message。
- 进程结束令牌随之消失，没有任何持久化。

结论：在正常输入路径下，令牌不进磁盘、不进日志、不进异常文本。

### 取消按钮真的取消网络操作

- `main.dart:100` 建 token，`main.dart:113` 交给 `FlowRunner`，`flow.dart:107` 和 `flow.dart:185` 传给 clone 和 push。
- `main.dart:136-138` 调用 `CancelToken.cancel()`，直接写 native 的 `Int32`（`repository.dart:162-168`）；后台 isolate 用同一地址构造 `Pointer<Int32>`（`repository.dart:728-729`）。跨 isolate 共享的是原始地址，取消实时生效。
- 原生侧 `qg_clone`/`qg_fetch`/`qg_push` 都把 `cancel_flag` 挂到 `transfer_progress`、`push_transfer_progress` 和凭据回调（`qfli_git.c:282-290`），回调返回 `GIT_EUSER`，`qg_result` 统一转成 `QG_ECANCELED`（`qfli_git.c:67-76`）。取消确实中断传输，不只是丢弃 UI 结果。
- 运行中运行按钮禁用（`main.dart:178`）、取消按钮可用（`main.dart:187`），不会并发跑两次。
- 每次运行新建 token（`main.dart:100`），上一次的取消位不会污染下一次。

### R6.4 集成测试不依赖网络

`integration_test/flow_test.dart` 的全部仓库都在 `getTemporaryDirectory()` 下（`flow_test.dart:135-141`）：`source` 是本地 init 的仓库，`remote.git` 是本地裸仓库，克隆源是本地路径（`flow_test.dart:49`），push 目标是本地裸仓库（`flow_test.dart:103-107`）。没有任何 `https://` 地址，也没有 DNS 依赖。

### 其他检查过、未发现问题的点

- `example/.metadata:19-32` 登记了 android、ios、ohos 三个平台，R6.1 满足。
- `example/ohos/entry/src/main/module.json5:40` 声明了 `ohos.permission.INTERNET`，鸿蒙真机（A4）需要它，已具备。
- `example/pubspec.yaml` 依赖只有 `path_provider`、`path`、`qfli_git`，其中 `path_provider_ohos` 由插件自身的依赖带入，鸿蒙上 `getApplicationSupportDirectory()` 有实现。
- `test/widget_test.dart` 只检查表单与按钮状态，不触碰 FFI，`flutter test` 无设备可跑；`_loadVersion()` 的异常被 `main.dart:67-79` 捕获，库缺失时不会让测试崩。
- `example/README.md` 说明了导入产物、令牌不入盘、取消按钮的范围，以及集成测试不联网。

## 2. 发现的问题

### B-1 集成测试的历史不分叉，合并必然快进，断言会失败

- 位置：`example/integration_test/flow_test.dart:57-75`
- 问题：先在主分支提交 `main change`（`flow_test.dart:57-60`），之后才 `createBranch('feature')`（`flow_test.dart:63`）。因此 feature 的提交是 main 提交的**直接子提交**。`checkout(mainBranch)` 后调用 `merge('feature')`，`git_merge_analysis` 给出 `GIT_MERGE_ANALYSIS_FASTFORWARD`，`qg_merge` 走 `qfli_git.c:860-878` 的快进分支并把 `out_result` 置 1，Dart 侧映射为 `MergeOutcome.fastForward`（`repository.dart:44-45`）。`flow_test.dart:75` 的 `expect(outcome, MergeOutcome.conflicts)` 必然失败，`flow_test.dart:77-83` 的冲突列表与冲突标记断言也随之失败。
- 为什么是问题：这条测试是 A5 的验收手段，现在它一定红；即使有人把断言改成 `fastForward`，R6.4 要求的「三方合并」也就没有覆盖了。
- 建议：把制造主分支冲突的提交移到切出 feature 之后，与 `flow.dart:119-150` 的顺序一致：base 提交 → 建 feature 并切换 → 分支提交 → 切回主分支 → 主分支冲突提交 → 合并。改完后顺手让这条测试直接用 `FlowRunner`（本地路径可同时作为 clone 源和 origin），顺带覆盖示例自己的流程代码。
- 严重程度：高

### B-2 远端 URL 里带凭据时会写进磁盘并显示在步骤日志

- 位置：`example/lib/main.dart:82-98`、`example/lib/flow.dart:110`
- 问题：`Remote HTTPS URL` 只校验非空，`clone` 成功后把 `settings.remoteUrl` 原样作为步骤 detail 返回（`flow.dart:110`），随后显示在界面上（`main.dart:270-272`）。用户如果把令牌写进 URL（`https://user:token@host/repo.git`），libgit2 会把该 URL 写进 `.git/config`，令牌落盘；同一串还会出现在步骤卡片里。
- 为什么是问题：R6.3 要求令牌不写入磁盘、不进日志。正常用独立的 Token 输入框时安全，但这条路径绕过了它，验收人一旦图省事把带令牌的 URL 粘进来就破功。
- 建议：在 `_runFlow` 里解析 URL，含 userinfo 时去掉它（或直接提示 `Put the token in the Token field`），并把清洗后的 URL 交给 `FlowSettings`；步骤 detail 只显示 `host/path`。
- 严重程度：中

### B-3 取消被记为「失败」，界面提示 `Flow stopped`

- 位置：`example/lib/flow.dart:204-213`、`example/lib/main.dart:121-124`
- 问题：`_step()` 对所有异常一律写 `succeeded: false`，`main.dart:123` 再弹 `Flow stopped: ...`。用户按取消后看到的是红色失败步骤加一条错误提示，看不出是自己取消的。
- 为什么是问题：取消是正常路径，不是缺陷。`GitException.isCanceled`（`repository.dart:132`）已经能区分，示例没有用。
- 建议：`_step()` 判断 `error is GitException && error.isCanceled`，把该步记为 `cancelled`（`FlowStep` 加一个字段，或 detail 写 `canceled`）；`main.dart` 收到取消时提示 `Flow canceled`。
- 严重程度：低

### B-4 解决冲突后没有复查索引，剩余冲突要到最后一步才暴露

- 位置：`example/lib/flow.dart:167-173`
- 问题：`_resolveByConcatenation` 只处理 `conflicts` 列表里的路径，然后 `addAll()`，直接进入合并提交。索引里若仍有未合并路径（例如解析留下空文件、或列表漏项），`commitMerge` 会返回 `QG_ECONFLICT`（`design.md` 第 2 节），错误出现在「merge commit」步骤，用户不知道哪个文件没解决。
- 为什么是问题：R6.2 把「解决冲突」和「合并提交」列为两步，第二步失败时应能指出第一步漏了什么。真机验收（A3/A4）出问题时排查成本高。
- 建议：`addAll()` 之后调用 `repo.conflicts()`，非空就抛 `StateError('unresolved: ${left.join(', ')}')`，让错误落在「解决冲突」这一步。
- 严重程度：低

### B-5 主清单没有 INTERNET 权限，release 包无法 clone/push

- 位置：`example/android/app/src/main/AndroidManifest.xml:1-30`
- 问题：`INTERNET` 只写在 `src/debug/AndroidManifest.xml:5` 和 profile 清单里，主清单没有声明。debug 构建（A3 的 `flutter run`）正常，release 构建装到真机上克隆远端会直接失败。
- 为什么是问题：示例应用的核心功能就是 HTTPS clone/push，权限属于功能必需项，不应只存在于调试清单。
- 建议：在 `src/main/AndroidManifest.xml` 加 `<uses-permission android:name="android.permission.INTERNET"/>`。
- 严重程度：低

### B-6 每次运行前无条件删除工作目录，失败现场不保留

- 位置：`example/lib/flow.dart:90-95`
- 问题：`workPath`（`main.dart:112`，即 `<应用支持目录>/flow_repo`）在流程开始时被 `deleteSync(recursive: true)` 整棵树删掉。
- 为什么是问题：不丢用户数据（目录由示例自己创建），但上一次运行的仓库、冲突文件和 `.git` 日志一起消失，真机验收失败时无法事后查看。
- 建议：删除前先改名为 `flow_repo.previous`，或只清理工作树里的内容。也可以在「clone」步骤的 detail 里显示 `workPath`。
- 严重程度：低

## 3. 待确认

- `integration_test/flow_test.dart:130-137` 的 `_addRemote` 直接向 `.git/config` 追加文本，路径经 `replaceAll(r'\', '/')` 处理。Windows 本机的普通路径可以工作，UNC 路径（`\\host\share`）转成 `//host/share` 后是否被 libgit2 接受，未验证。
- 鸿蒙上插件 HAR 的 `.so` 能否进入 HAP（`design.md` 第 5 节列为高风险）。`example/ohos/entry/oh-package.json5` 的 `dependencies` 为空，依赖靠 flutter_ohos 生成，属于本机构建阶段才能判定的事，这里不结论。
- `example/pubspec.yaml` 未固定 `flutter.minSdkVersion`，而插件 `android/build.gradle:27` 要求 minSdk 24。当前 Flutter 版本的默认值若低于 24，Gradle 合并会报错。未在本机跑 `flutter build apk` 验证，故列入待确认。
- `main.dart:230` 的副标题固定写 `Token stays in memory only.`，与库加载错误互斥显示，这是文案选择，不是缺陷。

## 4. 结论

`example/` 满足 R6.1、R6.2（应用流程本身）、R6.3（正常输入路径）、R6.4 的覆盖面要求。取消链路从 UI 到 libgit2 回调是完整且真实生效的，令牌没有日志或磁盘泄漏路径。

阻断项 1 个：B-1 的集成测试历史不分叉，A5 会失败，且 R6.4 的三方合并实际没有覆盖。另有 1 个中危（B-2 带凭据 URL 落盘）和 4 个低危。
