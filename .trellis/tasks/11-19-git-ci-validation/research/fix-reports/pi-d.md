# 修复报告（第二轮）：Pi D — `example/`

依据：`briefs/fix-round2.md` 中 Pi D 章节与大脑裁定，交叉检查报告
`research/cross-check/b-checks-example.md`。

## 逐条处理

### 高 B-1 集成测试历史不分叉（已修复，`2fe474b`）

- `example/integration_test/flow_test.dart`：把 feature 分支切出点移到主分支提交之前。
  顺序改为「clone → 建 feature 并切换 → 分支提交（改 `flow.txt`，新增 `branch.txt`）→
  切回主分支 → 主分支冲突提交（改 `flow.txt`）→ 合并」。
- 断言：`expect(outcome, MergeOutcome.conflicts)` 保留，`conflicts` 含 `flow.txt`、
  不含 `branch.txt`，冲突标记存在。合并后新增 `expect(mergeHead.state, 'merge')`。
- 干净状态断言用 `'clean'`：`baseHead.state`、`mergedHead.state` 均断言 `'clean'`（按裁定）。

### 中 B-2 URL 里的 userinfo（已修复，`7c58a2f`）

- `example/lib/flow.dart` 新增两个顶层函数：
  - `sanitizeRemoteUrl(url)`：`Uri.userInfo` 非空时用 `uri.replace(userInfo: '')` 去掉。
  - `displayRemoteUrl(url)`：只返回 `host/path`。
- `FlowRunner.run()` 在 clone 前再清洗一次 URL（`cloneUrl`），不依赖调用方；
  clone 步骤 detail 改为 `displayRemoteUrl(cloneUrl)`。
- `example/lib/main.dart` 的 `_runFlow` 清洗表单输入，发现被清洗时提示
  `Put the token in the Token field. The URL was cleaned.`
- `example/test/flow_helpers_test.dart` 增加 5 个用例（去 userinfo、无 userinfo 原样、
  本地路径原样、host/path、detail 不含令牌）。

### 低 B-3 取消显示为失败（已修复，`6b658e3`）

- `FlowStep` 增加 `cancelled`（缺省 `false`），`toString` 的 state 为
  `cancelled` / `ok` / `failed`。
- `_step()` 判断 `error is GitException && error.isCanceled`，该步记 `cancelled: true`
  且不写 `error`。
- `main.dart`：取消时提示 `Flow canceled.`；步骤卡片取消用橙色 `Icons.cancel_outlined`
  并显示「已取消」，失败仍是红色。`已取消` 通过 `FlowStep.cancelled` 渲染。
- 新增单元测试 `FlowStep a cancelled step is not a failure`。

### 低 B-4 解决冲突后不复查索引（已修复，`3fec4c1`）

- `resolve conflicts` 步骤在 `addAll()` 之后调用 `repo.conflicts()`，
  非空时抛 `StateError('unresolved: <paths>')`，错误落在本步骤而不是合并提交步骤。

### 低 B-5 主清单缺 INTERNET（已修复，`39b4c3f`）

- `example/android/app/src/main/AndroidManifest.xml` 顶部加
  `<uses-permission android:name="android.permission.INTERNET"/>`。

### 低 B-6 工作目录被无条件删除（已修复，`c3715be`）

- `FlowRunner.run()` 删除前先改名为 `$workPath.previous`；已存在同名目录时先删它。
- `workPath` 字段注释同步说明 `flow_repo.previous`。

### 文档（`82ac887`）

- `example/README.md`：写明 URL 会去掉 userinfo、步骤 detail 只显示 `host/path`、
  取消显示为 `已取消` 且提示 `Flow canceled.`、失败现场保留在 `flow_repo.previous`。
- 集成测试说明改为「先切出 feature 分支再做主分支提交」。

## 验证

`flutter analyze`（工作目录 `example/`）：

```
Analyzing example...
No issues found! (ran in 1.6s)
```

`flutter test`（工作目录 `example/`，widget 与单元测试，不需要设备）：

```
00:00 +5: .../flow_helpers_test.dart: FlowStep a cancelled step is not a failure
00:00 +6: .../widget_test.dart: form shows every input and both buttons
00:00 +7: .../widget_test.dart: token field is obscured until toggled
00:00 +8: .../widget_test.dart: cancel button is disabled until a run starts
00:01 +9: All tests passed!
```

`dart format` 对改动的 4 个 Dart 文件无剩余差异。

## 未完成项 / 说明

- `integration_test/flow_test.dart` 需要真机和已导入的原生产物，本轮未运行
  （不在 Pi D 的验证要求内）。该文件已通过 `flutter analyze`。
  `expect(baseHead.state, 'clean')` 依赖 Pi A 的中-5 修复（`NONE` → `"clean"`）；
  合并 Pi A 之前，本机原生产物仍返回 `"none"`，集成测试会停在这一条。
- 大脑裁定中 `username` 为 `NULL`/空串时用 `"git"`、URL userinfo 不参与用户名，
  涉及 `native/`，不在 Pi D 的文件范围内；示例侧只做 URL 清洗，不读 userinfo。
- 交叉检查报告的建议「集成测试直接用 `FlowRunner`」未采纳：现有测试要断言冲突标记
  和索引细节，直接调用 `GitRepository` 覆盖更细；步骤顺序已与 `FlowRunner` 一致。
- `example/pubspec.yaml` 未固定 `minSdkVersion`（原报告的待确认项），未在本轮处理。