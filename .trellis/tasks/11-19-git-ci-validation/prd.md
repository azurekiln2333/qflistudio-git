# CI 技术验证：libgit2 + mbedTLS 三端编译与鸿蒙真机全流程

父任务：`11-19-mobile-git`。本任务只改本仓库（qfli_git）。

## 目标

证明三件事：

1. GitHub Actions 能编出 Android、iOS、鸿蒙的 libgit2 + mbedTLS 库。
2. 本仓库作为 Flutter FFI 插件，能在 Android、鸿蒙（flutter_ohos）应用里带上 `.so`，在 iOS 应用里带上 framework。
3. 鸿蒙真机能通过插件跑通 clone → commit → 三方合并（含冲突）→ push。

## 需求

### R1 上游源码

- R1.1 锁定 libgit2 v1.9.7。
- R1.2 锁定 mbedTLS 3.6 LTS 的最新补丁版。实施时先确认 libgit2 v1.9.7 能用它编过。
- R1.3 锁定 Mozilla CA 根证书包（curl.se 的 `cacert.pem`）。
- R1.4 每个上游包都记录下载地址和 SHA-256。构建前必须校验。
- R1.5 不修改上游源码。确需修改时，用补丁文件，并在 `third_party/README.md` 说明原因。

### R2 编译目标

| 平台 | ABI | 产物 |
|---|---|---|
| Android | arm64-v8a、armeabi-v7a、x86_64 | `libqfli_git.so` |
| 鸿蒙 | arm64-v8a、x86_64 | `libqfli_git.so` |
| iOS 真机 | arm64 | `qfli_git.framework`（动态） |
| iOS 模拟器 | arm64、x86_64 | `qfli_git.framework`（动态，通用） |

- R2.1 iOS 两个 framework 合成一个 `qfli_git.xcframework`。
- R2.2 Android 和鸿蒙的 `.so` 必须 16 KB 页对齐。
- R2.3 每个库只导出 `qg_` 前缀的符号。
- R2.4 关闭 SSH、GSSAPI、NTLM、iconv。zlib、正则、HTTP 解析器用 libgit2 自带版本。

### R3 C 接口

- R3.1 提供精简 C 接口 `qfli_git.h`。接口定义见 `design.md`。
- R3.2 网络操作支持取消。
- R3.3 错误信息包含 libgit2 错误码和消息文本。

### R4 Dart 插件

- R4.1 插件包名 `qfli_git`，声明 android、ios、ohos 三个 `ffiPlugin` 平台。
- R4.2 Dart API 在后台 isolate 执行 git 操作，不阻塞 UI。
- R4.3 插件自带 CA 根证书包。初始化时把证书路径传给 C 层。
- R4.4 令牌只在调用时传入。插件不保存令牌。

### R5 CI

- R5.1 推送到 `main` 或手动触发时，GitHub Actions 编出 R2 的全部产物。
- R5.2 每个产物附带 `manifest.json`：上游版本、SHA-256、文件大小、压缩后大小、提交 SHA。
- R5.3 CI 检查 16 KB 页对齐和导出符号。检查失败时任务失败。
- R5.4 CI 在 Linux 主机上编译并运行 C 冒烟测试。
- R5.5 CI 编译 example 应用的 Android APK 和 iOS 模拟器包，证明插件能链接。

### R6 示例应用与验证

- R6.1 `example/` 是一个 Flutter 应用，平台为 android、ios、ohos。
- R6.2 应用提供一个全流程按钮：clone → 改文件 → commit → 建分支并提交 → 在主分支制造冲突提交 → 合并 → 列出冲突 → 解决冲突 → 合并提交 → push。每一步显示结果和耗时。
- R6.3 推送目标仓库和令牌在界面输入。令牌不写入磁盘，不进入日志。
- R6.4 `example/integration_test/` 覆盖不需要网络的部分：本地仓库 commit、分支、三方合并、冲突列表、合并提交。

## 验收标准

- [ ] A1 GitHub Actions 全部任务通过。产物包含 R2 的全部库和 `manifest.json`。
- [ ] A2 C 冒烟测试在 CI 通过。
- [ ] A3 Android 真机运行 example 全流程通过，有截图。
- [ ] A4 鸿蒙真机（arm64-v8a）运行 example 全流程通过，有截图。push 后在 GitHub 网页能看到合并提交。
- [ ] A5 鸿蒙和 Android 真机上 `integration_test` 通过。
- [ ] A6 记录每个 ABI 的 `.so` 大小（未压缩、zip 压缩后）。记录 example 安装包加插件前后的大小差。
- [ ] A7 iOS：CI 编出 xcframework，example 的模拟器包链接通过。本机无 Mac，iOS 设备运行不在本任务验收范围。
- [ ] A8 `README.md` 说明构建、导入产物、使用插件的方法。许可证文件齐全。

## 不在范围内

- `qfli_studio_core` 的任何改动。
- SSH、hooks、git-lfs、credential helper。
- 桌面平台的库。

## 外部依赖

- 鸿蒙真机：验收 A4、A5 前，用户需要接上鸿蒙设备。当前 `hdc list targets` 为空。
- 推送测试仓库和令牌：验收 A4 前，用户提供一个可写的测试仓库和细粒度令牌。令牌只在设备界面输入。
