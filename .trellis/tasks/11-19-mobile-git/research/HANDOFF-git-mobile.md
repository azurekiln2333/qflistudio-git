# 交接：移动端 git（libgit2）

来源：qflistudio 工作区的 Claude 会话，2026-11-19。
接收方：qfli_git 工作区的 Claude（大脑）。
本文件只做交接。建好 Trellis 任务后，把它移到任务的 `research/` 目录，并删除仓库根目录的这份。

## 1. 目标

QFLIStudio+ 的 git 能力要覆盖全部平台：

- 桌面（Windows / macOS / Linux）：调用用户安装的官方 git。现有实现保留。
- Android、iOS、鸿蒙：内置 git 引擎，体验尽量接近 PC 上的 git。
- Agent 会话分支是必需功能。每个会话一个分支，检查通过后合并。

## 2. 用户已做的决定

以下是用户在本会话里的原话或明确选择：

1. 移动端三个平台都要能用：「除了桌面端能直接调用安装官方的 其他移动端 android ios ohos都要可以用」。
2. 场景选 B，即 Agent 会话分支：「agent会话分支我觉得是必然需要的」。
3. 原生库在 GitHub Actions 上编译。手机只加载编好的库，不在设备上编译：「肯定得在github上编译完啊」。
4. 新开独立仓库 `qfli_git`，低耦合。用户已在本地创建 `D:\MyNewProjects\qfli_git`。GitHub 远端尚未创建，由用户自己建。
5. git 的业务逻辑放在共享内核 `qfli_studio_core`，不放在任何语言子项目（如 qfli_go）。

## 3. 技术结论

### 3.1 选 libgit2 + mbedTLS

- 执行必须在应用进程内的 native 层，通过 Dart FFI 调用。
- 不能打包 git 可执行文件：iOS 和鸿蒙都不允许应用启动子进程。qfli_c 在鸿蒙上把用户程序编成 WASI 字节码再解释执行，原因相同。Android 10 起也禁止执行应用可写目录里的程序。
- 不选 go-git：其 [COMPATIBILITY.md](https://github.com/go-git/go-git/blob/main/COMPATIBILITY.md) 写明 merge 只支持快进，rebase、stash、revert 不支持。会话分支需要三方合并。
- libgit2 提供：三方合并与冲突索引、rebase、stash、cherry-pick、worktree、diff、blame。
- mbedTLS 提供 HTTPS。Android 和鸿蒙没有 libgit2 可直接使用的系统 TLS。三端统一用 mbedTLS。
- SSH 放到后续阶段，需要 libssh2。第一阶段只做 HTTPS + 令牌。
- 许可证：libgit2 是 GPLv2 加链接例外，mbedTLS 是 Apache-2.0。两者都能链入 GPL v3 的主应用。
- 做不到的部分：hooks（要启动 shell）、git-lfs、credential helper、依赖外部程序的命令（difftool、send-email）。
- 鸿蒙不是 libgit2 的官方目标。鸿蒙 SDK 自带 `native/build/cmake/ohos.toolchain.cmake`，预计改少量编译参数可编过。尚未验证。
- 鸿蒙的 CA 根证书路径可能与 Linux 不同，可能需要自带根证书。尚未验证。

### 3.2 仓库分工

- `qfli_git`：上游 C 源码依赖（锁版本和校验和，不改上游）、CI 交叉编译、预编译库或 Release 产物、精简 C 接口、Dart FFI 绑定。形态是 Flutter FFI 插件，平台为 android、ios、ohos。
- `qfli_studio_core`：`GitBackend` 接口、桌面端官方 git 实现、移动端调用 `qfli_git` 的实现、会话分支逻辑、git 页面、终端里的 `git` 命令。
- 依赖方式（建议，待用户确认）：内核 `pubspec.yaml` 用 git 地址加标签依赖 `qfli_git`。本地联调用 `pubspec_overrides.yaml` 指向 `../qfli_git`。

## 4. 现有代码位置（只读参考）

| 内容 | 路径 |
|---|---|
| 桌面 git 封装，移动端返回「当前平台不支持本地 git」 | `D:\MyNewProjects\qfli_studio_core\lib\services\git_service.dart` |
| git 页面，桌面走 GitService，云端走 CloudSyncService | `D:\MyNewProjects\qfli_studio_core\lib\pages\git_page.dart` |
| 云端 git 接口，服务端固定返回 503 | `qfli_studio_core\lib\services\cloud_sync_service.dart` 的 `git()` |
| 终端命令委托，可接 `git` 子命令 | `qfli_studio_core\lib\terminal\shell\sandbox_shell_backend.dart` 的 `TerminalCommandDelegate` |
| 内核插件声明，目前只有 Android（`QfliPickerPlugin`，系统文件选择器） | `qfli_studio_core\pubspec.yaml` |
| 会话分支调研：现有 git 能力、缺口、worktree 流程、`AgentBranchState` | `D:\MyNewProjects\qflistudio\.trellis\tasks\11-12-agents-workbench\research\G-agent-isolation.md` |
| 会话分支延后项 §11.10（手机原定用写时复制叠加层） | `D:\MyNewProjects\qflistudio\.trellis\tasks\11-12-agents-workbench\design.md` |
| 可照抄的移动端原生 CI：Android 3 个 ABI（NDK 28.2.13676358，16 KB 页对齐）+ 鸿蒙 arm64 / x86_64（官方 SDK 5.0.0），Windows runner | `D:\MyNewProjects\qfli_go\native\go_runtime\CI.md`、`README.md`、`qfli_go\tool\build_go_runtime.ps1` |
| 鸿蒙 CMake + NAPI 链接参考（16 KB 页对齐参数） | `D:\MyNewProjects\qfli_c\ohos\entry\src\main\cpp\CMakeLists.txt` |
| 鸿蒙上 `.so` 的放置方式（应用级 `ohos/entry/libs/<abi>`） | `D:\MyNewProjects\qfli_go\ohos\entry\libs\` |

## 5. 建议的任务拆分

父任务：移动端 git。

1. **CI 技术验证（qfli_git）**：GitHub Actions 编出 libgit2 + mbedTLS。
   - 目标：Android arm64-v8a / armeabi-v7a / x86_64，iOS 真机 arm64 + 模拟器，鸿蒙 arm64-v8a / x86_64。
   - 验收：在鸿蒙真机上跑通 clone → commit → 三方合并（含冲突）→ push，并记录每个 ABI 的包体增量。
   - 同时验证：Flutter FFI 插件能否在 flutter_ohos 下带上 `.so`。
2. **`GitBackend` 与移动端 git 页面（qfli_studio_core）**：桌面行为不变，移动端接 libgit2。
3. **会话分支（qfli_studio_core + qflistudio）**：接 Agents 工作台 §11.10。手机改用 libgit2 真分支，原叠加层方案作废，需改那份 design.md。

## 6. 待确认问题

- GitHub 远端仓库名、公开或私有。私有仓库会影响应用 CI 拉取 git 依赖。
- `qfli_git` 自身的许可证。
- 预编译库的存放方式：提交进仓库，还是放 Release 由插件构建时下载。
- 桌面端没装 git 时，是否用 libgit2 兜底。
- 应用 CI 每次都用内核 `main` 构建，不锁内核版本。`qfli_git` 的版本锁定方式要和这一点一起设计。

## 7. 用户的工作约定（qflistudio 记忆，本仓库的记忆目录看不到）

- 提交信息只写 Conventional Commits 的标题和正文。不加 `Co-Authored-By` 或 Generated with 行，派给 Pi 的提交也一样。
- 禁止破坏性 git 操作：`reset`、`checkout --`、`restore`、`stash`、`clean`、切分支、改写历史。第一份派工说明里就要写明。2026-11-01 一个 Pi 执行 `reset --hard` 清掉了用户约 20 个文件的未提交改动。
- 不开 Claude 子代理（Agent 工具），研究也不开。派给本工作区的 herdr Pi（w6F:p2–p5）。
- 每个 Pi 一个 git worktree 和分支。顺序：Pi 实现 → 大脑审查 → 合入集成分支 → Pi 交叉检查 → Pi 真机全流程检查并截图 → 大脑复查含 UI/UX → 应用到主目录。
- Git Bash 里调用 herdr 要加 `MSYS_NO_PATHCONV=1`，否则 `/new` 会被改写成路径。
- 给 Pi 发 `/new` 后，它会回落到无效的默认模型。先发 `/model newapi/deepseek-v4.1-flash`，再发派工说明。
- 派工后不要轮询，用一个后台脚本在所有 Pi 完成时退出。用户原话：「派下之后你就不要消耗tokens了」。
- Pi 不推送、不打标签。推送、打标签和看 CI 由大脑做。
- 中文技术文本按受控中文写：一句一动作、主动语态、一词一义、不用分号连接动作、不写套话和营销词，不改情态词。
- Trellis：建任务要先征得用户同意。同意建任务不等于同意实现，规划产物评审通过后才 `task.py start`。
