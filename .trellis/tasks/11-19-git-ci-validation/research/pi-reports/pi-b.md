# PI B 报告：CI

分支 `wt/pi-b`。只改本 worktree。

## 改动文件

| 文件 | 内容 |
|---|---|
| `.github/workflows/native.yml` | 7 个任务：`host-smoke`、`android`、`ohos`、`ios`、`example-android`、`example-ios`、`release` |
| `tool/install_ohos_sdk.sh` | 鸿蒙 SDK 下载、校验、解包，取 Linux native 包 |
| `tool/ci/collect_artifacts.py` | 收集产物、写 `manifest.json`、检查页对齐和导出符号、复制许可证 |
| `tool/ci/test_collect_artifacts.py` | 页对齐、导出符号、版本文件解析、收集流程的单元测试 |
| `tool/import_artifacts.py` | 校验产物、复制到插件平台目录、写 `native_libs.lock.json`、支持 Release 标签 |
| `tool/ci/test_import_artifacts.py` | 导入成功、校验失败、路径穿越、提交过滤的单元测试 |

## 设计与实现要点

- 工作流按 `design.md` 第 4 节分任务。所有 Actions 用提交 SHA 锁定，注释写版本号。
  - `actions/checkout@3d3c42e5…`（v7.0.1）、`actions/setup-python@6d4fd22b…`（v7.1.0）、`actions/upload-artifact@cf430e03…`（v7.0.2）与 qfli_go 相同。
  - `actions/download-artifact@37930b1c…`（v7.0.0）、`subosito/flutter-action@1a449444…`（v2.23.0）。两个 SHA 由 GitHub API 查到。
- 顶层 `permissions: contents: read`。`release` 任务单独声明 `contents: write`。
- `concurrency` 按分支名分组并取消旧运行。
- 构建只调用 `tool/fetch_sources.py` 与 `tool/build_native.sh --platform … --abi … --out …`。
- 产物名 `qfli-git-<platform>-<sha>`，保留 14 天，`compression-level: 0`。
- `release` 只在 `native-v*` 标签运行。它下载全部产物、逐个 zip、生成 `SHA256SUMS`、用 `gh` 命令行创建或更新 Release。
- `collect_artifacts.py` 读 `third_party/versions.json`，把上游版本写进清单。清单字段：`platform`、`abis`、`commit`、`upstream`、`checks`、`files`（`path`、`abi`、`bytes`、`zipBytes`、`sha256`）、`licenses`。
- 页对齐检查取 `llvm-readelf -lW` 每行 `LOAD` 的最后一列，要求大于等于 `0x4000` 且是 `0x4000` 的整数倍。
- 导出符号检查取 `llvm-nm -D --defined-only` 的最后一列，跳过下划线开头的名字和 `A` 类型（版本节点）条目，要求其余名字都以 `qg_` 开头。没有导出符号也判失败。
- `import_artifacts.py` 先核对清单里每个文件的大小和 SHA-256，再复制库文件。许可证和头文件不进平台目录。
  - iOS 在复制前删除旧的 `ios/Frameworks/qfli_git.xcframework`，避免残留旧切片。
  - Release 来源用 GitHub API 列出资产，按 `qfli-git-<platform>-*.zip` 匹配，再下载。
  - 解压前拒绝绝对路径和 `..` 成员。
- 只用 Python 标准库。

## 本地验证

### 单元测试

```
python -m unittest discover -s tool/ci -p "test_*.py"
```

```
Ran 24 tests in 0.070s

OK
```

### 工作流解析

PyYAML 解析通过：

```
jobs: ['host-smoke', 'android', 'ohos', 'ios', 'example-android', 'example-ios', 'release']
on: ['push', 'workflow_dispatch']
release perms: {'contents': 'write'}
top perms: {'contents': 'read'}
```

actionlint 1.7.12 无输出、退出码 0：

```
exit=0
```

### Shell 脚本语法

```
bash -n tool/install_ohos_sdk.sh
```

输出 `bash -n OK`（Git Bash `D:\ProgramFiles\Git\bin\bash.exe`）。

### 鸿蒙 SDK 安装脚本的真实解包流程

用合成的 tar.gz 测试：包内为 `linux/native-linux-x64-9.9.9-Release.zip`，zip 内为 `native/llvm/bin/{clang,llvm-strip,llvm-readelf,llvm-nm}` 和 `native/sysroot`。为了绕过 HTTPS 限制，只在测试副本里把 URL 协议检查换成本地路径检查。结果：

```
OHOS SDK ready: native/build/ohos-sdk-test/out/native-package
--- exit ok ---
```

真实 SDK 包的 Linux 成员名用区间下载确认。读取 tar 头部（前 6 MB）得到 `linux/native-linux-x64-5.0.0.71-Release.zip`，与脚本正则、官方 5.0.0.71 版本一致。

### 产物收集到导入的整链路（iOS）

用伪造的 `qfli_git.xcframework`（`ios-arm64` 与 `ios-arm64_x86_64-simulator` 两个切片）跑 CLI：

```
collect exit=0
ios: 4 files from dddddddddddd
lock: …\repo\native_libs.lock.json
import exit=0
```

导入后的目录：

```
ios\Frameworks\qfli_git.xcframework\Info.plist
ios\Frameworks\qfli_git.xcframework\ios-arm64\qfli_git.framework\qfli_git
ios\Frameworks\qfli_git.xcframework\ios-arm64\qfli_git.framework\Headers\qfli_git.h
ios\Frameworks\qfli_git.xcframework\ios-arm64_x86_64-simulator\qfli_git.framework\qfli_git
```

这一步发现并修掉一个缺陷：清单里的许可证文件让 iOS 导入按切片路径规则报错。现在导入只取库文件。

## 未验证的步骤

- 没有运行 GitHub Actions。以下内容只在本地静态检查过：NDK 安装、`sdkmanager` 交互、macOS runner 的 Xcode 版本、`xcodebuild -create-xcframework`、`flutter build apk`、`flutter build ios --simulator`、`gh release create`。
- 没有下载真实的鸿蒙 SDK 包（2.6 GB）。脚本只在合成包上跑通。
- 没有对真实 `libqfli_git.so` 跑 `llvm-readelf`、`llvm-nm` 检查。本机没有编好的 Android 或鸿蒙库。检查逻辑由伪造输出的单元测试覆盖。
- 没有跑 shellcheck。actionlint 关闭了 shellcheck 和 pyflakes。
- `tool/fetch_sources.py`、`tool/build_native.sh`、`native/test/smoke.c`、`third_party/versions.json`、`LICENSE` 由其他 Pi 提供。本轮它们的文件还不存在，无法联调。

## 接口问题

1. `third_party/versions.json` 的字段结构没有写进 `design.md`。我按 `{"libgit2": {"version": "1.9.7"}, "mbedtls": {"version": "3.6.4"}}` 读取，也兼容 `[{"name": …, "version": …}]` 和字符串值。建议在 `design.md` 补一句，或由 Pi A 明确写法。
2. `tool/fetch_sources.py` 在 CI 里以无参数方式调用。如果它需要参数，需要改工作流。
3. `tool/build_native.sh --out` 必须把 `libqfli_git.so` 和 `qfli_git.h` 直接放在输出目录根下。`ios-simulator` 必须输出合并好的单份 `qfli_git.framework`，CI 把它直接传给 `xcodebuild -create-xcframework`，不再分架构合并。
4. 主机冒烟测试由 CI 自行编译 `native/test/smoke.c`：`cc … -Inative/include -Lnative/build/ci/host -lqfli_git -Wl,-rpath,'$ORIGIN' -lpthread -ldl -lm`。`build_native.sh` 不提供测试目标。如果 Pi A 另有测试构建方式，需要改工作流。
5. 许可证来源没有约定。`collect_artifacts.py` 默认取仓库根 `LICENSE`，再取 `third_party/licenses/*`，并允许 `--license PATH[=NAME]` 覆盖。建议 Pi A 把上游许可证放在 `third_party/licenses/`，否则产物会缺 libgit2、mbedTLS、CA 证书的许可证。这一条需要大脑决定。
6. `native/exports.map` 建议用匿名版本节点。具名节点会在动态符号表留下 `A` 类型条目，我在检查里跳过这类条目，因此两种写法都能通过。
7. `native_libs.lock.json` 写到仓库根目录。按 `design.md` 第 7 节，只有大脑提交它。
8. `example-android` 没有安装 NDK，因为 `design.md` 第 5 节要求 Android 模块不配置 CMake。如果 Pi C 的 Gradle 配置声明了 NDK 版本，这个任务会要求 NDK，需要在工作流里补装。
