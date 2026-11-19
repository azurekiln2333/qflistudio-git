# 执行计划：CI 技术验证

先读 `prd.md`、`design.md`。参考文件（只读）：

- `D:\MyNewProjects\qfli_go\.github\workflows\native-runtime.yml`：CI 结构、Actions 锁定的 SHA、NDK 安装。
- `D:\MyNewProjects\qfli_go\tool\ci\install_ohos_sdk.ps1`：鸿蒙 SDK 下载和校验。
- `D:\MyNewProjects\qfli_c\ohos\entry\src\main\cpp\CMakeLists.txt`：鸿蒙链接参数。
- `D:\ProgramFiles\flutter_ohos\packages\flutter_tools\templates\plugin_ffi\`：FFI 插件模板（含 `ohos.tmpl`）。

## 0. 全体规则（写进每份派工说明）

- 禁止 `git reset`、`git checkout --`、`git restore`、`git stash`、`git clean`、切换分支、改写历史。
- 只在自己的 worktree 和分支里工作。不改其他 Pi 负责的文件。
- 提交信息用 Conventional Commits，只写标题和正文。不加 `Co-Authored-By`，不加 Generated with。
- 不推送，不打标签，不提交预编译库（`*.so`、`*.xcframework`）。
- 不提交令牌、密钥、本机绝对路径。
- 完成后在 worktree 根目录写 `PI_REPORT.md`：改了什么、怎么验证、结果、遗留问题。然后提交。

## 1. 基线（大脑）

- [ ] 写根目录 `.gitignore`。
- [ ] 把默认分支设为 `main`，做初始提交（Trellis 脚手架 + 任务文件）。
- [ ] 添加远端 `origin` = `https://github.com/azurekiln2333/qflistudio-git.git`，推送 `main`。
- [ ] 建集成分支 `integration/git-ci`。
- [ ] 为 4 个 Pi 建 worktree：`D:\MyNewProjects\_wt\qfli_git\pi-{a,b,c,d}`，分支 `wt/pi-{a,b,c,d}`，基于 `main`。

## 2. 第一轮：并行实现

| Pi | 窗格 | 负责的文件 | 本地验证 |
|---|---|---|---|
| A 原生层 | w6F:p2 | `third_party/`、`native/`、`tool/fetch_sources.py`、`tool/build_native.sh`、`assets/cacert.pem` | `fetch_sources.py` 校验通过。本机用 Android NDK 编出 arm64-v8a，用鸿蒙 SDK 编出 arm64-v8a。`llvm-readelf -lW` 显示 LOAD 对齐 0x4000。`llvm-nm -D --defined-only` 只有 `qg_*`。主机冒烟测试在 WSL（`qfli-java-build`）或其他 Linux 环境通过。 |
| B CI | w6F:p3 | `.github/workflows/native.yml`、`tool/install_ohos_sdk.sh`、`tool/ci/`、`tool/import_artifacts.py` | `python -m unittest discover -s tool/ci`。workflow YAML 能被解析。`import_artifacts.py` 用伪造产物目录测试校验失败和成功两种情况。 |
| C Dart 插件 | w6F:p4 | `pubspec.yaml`、`lib/`、`android/`、`ios/`、`ohos/`、`test/`、`LICENSE`、`README.md` | `flutter analyze` 无问题。`flutter test` 通过（纯 Dart 部分，如 JSON 解析、错误映射）。 |
| D 鸿蒙打包验证 + 示例应用 | w6F:p5 | `example/`、`research/ohos-ffi-packaging.md`（写在任务目录） | 先做打包验证：在 `D:\MyNewProjects\_wt\qfli_git\spike\` 建最小 ffiPlugin 和应用，`.so` 只导出 `int qg_api_version(void)`。用 flutter_ohos 构建 HAP，确认 `.so` 在 HAP 里，`DynamicLibrary.open` 成功。没有鸿蒙设备时，用模拟器或解包 HAP 检查。结论写进研究文件。再按 `design.md` 第 6 节写 `example/` 和 `example/integration_test/`。 |

依赖处理：

- B 调用 `tool/build_native.sh`，按 `design.md` 第 3 节的参数写。A 必须实现同样的参数。
- C 的绑定按 `design.md` 第 2 节写。A 必须实现同样的签名。
- D 的示例应用按 `design.md` 第 6 节调用 Dart API。C 必须实现同样的 API。
- 发现接口需要改动时，Pi 不自行改接口。Pi 在 `PI_REPORT.md` 写明原因，大脑决定。

完成检测：大脑运行一个后台脚本。4 个 worktree 都出现已提交的 `PI_REPORT.md` 后退出。期间大脑不轮询。

## 3. 大脑审查与集成

- [ ] 逐个审查 4 个分支的差异和 `PI_REPORT.md`。
- [ ] 按 A → C → B → D 顺序合入 `integration/git-ci`。
- [ ] 本机跑：`flutter analyze`、`flutter test`、`python -m unittest discover -s tool/ci`。
- [ ] 推送 `integration/git-ci`，手动触发 CI。CI 失败时，把失败任务和日志摘要派给对应 Pi 修复。
- [ ] CI 全绿后，下载产物，用 `import_artifacts.py` 导入，提交预编译库和 `native_libs.lock.json`。

回退点：集成分支每合入一个 Pi 打一个本地记录（提交 SHA 写进本文件末尾）。合入出错时，在新分支上重新合入，不改写历史。

## 4. 第二轮：交叉检查

| 检查者 | 被检查者 | 重点 |
|---|---|---|
| A | C | 绑定签名与 `qfli_git.h` 一致，内存释放，取消标志 |
| C | A | C 实现与接口约定一致，错误填写，冲突处理 |
| D | B | CI 产物与插件目录对应，导入脚本 |
| B | D | 示例应用流程完整，令牌不落盘 |

检查者只写 `CROSS_CHECK.md` 并提交。修改由原负责人完成。

## 5. 第三轮：真机全流程

- [ ] Android 真机（已连接）：安装 example，跑全流程和 `integration_test`，截图。
- [ ] 鸿蒙真机（需用户接上设备并提供测试仓库和令牌）：安装 example，跑全流程和 `integration_test`，截图。push 后在 GitHub 网页确认合并提交。
- [ ] 记录包体数据（`prd.md` A6），写进 `research/size-report.md`。

## 6. 大脑复查与收尾

- [ ] 复查全部截图和报告，包括示例应用的 UI/UX。
- [ ] 把 `integration/git-ci` 合入 `main`，推送。
- [ ] 打标签 `native-v0.1.0`，确认 Release 产物。
- [ ] 更新 `.trellis/spec/`：记录原生构建和 FFI 插件的约定。
- [ ] 更新父任务的任务地图。

## 集成记录

（大脑填写各 Pi 合入的提交 SHA。）
