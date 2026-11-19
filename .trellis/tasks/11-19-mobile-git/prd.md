# 移动端 git（父任务）

来源：`research/HANDOFF-git-mobile.md`（qflistudio 会话交接，2026-11-19）。

## 目标

- 桌面端（Windows、macOS、Linux）继续调用用户安装的官方 git。
- Android、iOS、鸿蒙在应用进程内运行 libgit2 + mbedTLS，通过 Dart FFI 调用。
- Agent 会话分支必须可用：每个会话一个分支，检查通过后三方合并。

## 已定决策

| 项 | 决策 |
|---|---|
| git 引擎 | libgit2 + mbedTLS。不用 go-git，不打包 git 可执行文件。 |
| 编译位置 | GitHub Actions。手机只加载预编译库。 |
| 远端 | `https://github.com/azurekiln2333/qflistudio-git.git`，公开。默认分支 `main`。 |
| 第一阶段传输 | HTTPS + 令牌。SSH 放到后续阶段。 |
| 业务逻辑位置 | `qfli_studio_core`。本仓库只提供引擎、C 接口和 Dart 绑定。 |
| 预编译库存放 | 提交进本仓库的插件平台目录。只有大脑从 CI 产物导入。理由：pub 的 git 依赖无需构建期下载，三端构建系统都能直接使用。 |
| 本仓库许可证 | GPL-3.0-or-later，与主应用一致。第三方许可证随产物分发。 |
| 版本锁定 | 内核 `pubspec.yaml` 用 git 地址 + 标签依赖本仓库。应用 CI 用内核 `main`，内核 `main` 锁定本仓库标签。 |

## 任务地图

| 子任务 | 仓库 | 状态 | 依赖 |
|---|---|---|---|
| `11-19-git-ci-validation`：CI 技术验证 | qfli_git | 规划中 | 无 |
| GitBackend 与移动端 git 页面 | qfli_studio_core | 未建 | 子任务 1 验收通过 |
| 会话分支（替换 Agents 工作台 §11.10 叠加层方案） | qfli_studio_core + qflistudio | 未建 | 子任务 2 |

子任务 2、3 在子任务 1 验收后再建。届时决定它们建在哪个仓库的 Trellis。

## 跨子任务验收

- [ ] 三个移动平台都能在 `qfli_studio_core` 的 git 页面完成 clone、commit、分支、合并、push。
- [ ] 桌面行为不变。
- [ ] Agent 会话在独立分支上工作，检查通过后合并回来。冲突时给出冲突文件列表。

## 后续阶段（不在本父任务首轮范围）

- SSH（libssh2）。
- 桌面端未安装 git 时用 libgit2 兜底。
- hooks、git-lfs、credential helper 不支持。
