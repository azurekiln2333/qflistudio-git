# qfli_git

供 Flutter 应用调用的本地 git 操作库。Dart 侧通过 `dart:ffi` 调用 C 接口，C 层静态链接 libgit2 与 mbedTLS。

## 能力

- 克隆、抓取、推送仓库。网络操作支持取消。令牌只在调用时传入。
- 暂存全部改动、提交、建分支、切分支。
- 三方合并。合并遇冲突时停下，列出冲突路径，解决后生成合并提交。
- 读取工作区状态和 HEAD。
- 自带 Mozilla CA 根证书包。三端都用同一份证书，不依赖系统证书路径。

## 平台

| 平台 | 库 | 打包位置 |
|---|---|---|
| Android | `libqfli_git.so` | `android/src/main/jniLibs/<abi>/` |
| iOS | `qfli_git.framework`（动态） | `ios/Frameworks/qfli_git.xcframework` |
| OpenHarmony | `libqfli_git.so` | `ohos/libs/<abi>/` |

Android 支持 `arm64-v8a`、`armeabi-v7a`、`x86_64`。鸿蒙支持 `arm64-v8a`、`x86_64`。iOS 最低版本 13.0，真机与模拟器都用同一份 xcframework。

## 预编译库来源

原生层由本仓库的 `native/`、`third_party/` 和 `.github/workflows/native.yml` 构建。

- libgit2 v1.9.7。
- mbedTLS 3.6 LTS。
- Mozilla CA 根证书包，来源 `curl.se/ca/cacert.pem`。
- 版本、下载地址和 SHA-256 记在 `third_party/versions.json`。

CI 推送 `main` 或手动触发时编出全部平台的库。每个产物附 `manifest.json`，记录上游版本、文件 SHA-256、大小和提交 SHA。

## 导入预编译库

1. 下载 CI 产物，或用 `native-v*` 标签的 Release。
2. 运行 `python tool/import_artifacts.py`，按脚本的用法参数指定产物来源。脚本校验 `manifest.json` 里的 SHA-256。
3. 脚本把库复制到上表的三个目录，并写入 `native_libs.lock.json`。
4. 提交库文件和锁文件。

本仓库不提交 `*.so` 和 `*.xcframework`。三个目录里只有 `.gitkeep`。缺库时 `flutter build` 会失败并提示找不到符号。

## 引入插件

`pubspec.yaml` 加路径依赖：

```yaml
dependencies:
  qfli_git:
    path: ../qfli_git
```

插件声明了 `android`、`ios`、`ohos` 三个 `ffiPlugin` 平台，无需额外的原生配置。鸿蒙端同时依赖 `path_provider_ohos`，插件已在 `dependencies` 里声明。

## Dart 用法

初始化一次，然后创建或打开仓库。所有操作在后台 isolate 执行，不阻塞 UI。

```dart
import 'package:qfli_git/qfli_git.dart';

const author = GitAuthor('QFLI', 'dev@example.com');

Future<void> run() async {
  await QfliGit.ensureInitialized();
  print('libgit2 ${QfliGit.libgit2Version}');

  final repo = await GitRepository.clone(
    url: 'https://github.com/example/demo.git',
    path: '/data/app/demo',
  );

  await repo.addAll();
  final oid = await repo.commit('feat: add notes', author);

  await repo.createBranch('topic', from: oid);
  await repo.checkout('topic');
  // 修改文件后提交，再回到默认分支合并。
  final outcome = await repo.merge('main', author);
  if (outcome == MergeOutcome.conflicts) {
    for (final path in await repo.conflicts()) {
      print('conflict: $path');
    }
    // 解决冲突并暂存后生成合并提交。
    await repo.addAll();
    await repo.commitMerge('merge: resolve conflicts', author);
  }

  final cancel = CancelToken();
  try {
    await repo.push(
      refspec: 'refs/heads/topic:refs/heads/topic',
      username: 'git',
      token: token,
      cancel: cancel,
    );
  } finally {
    cancel.dispose();
  }
}
```

推送目标与令牌由调用方提供。插件不写文件、不打印令牌，也不把令牌放进异常消息。

### 私有仓库

`clone`、`fetch`、`push` 接受 `username` 和 `token`。`username` 留空时 C 层用 `git`。HTTPS 凭据只交给 libgit2 的凭据回调，第二次请求凭据时直接失败，避免死循环。

### 取消

`CancelToken` 内部持有一个原生 `int32`。`cancel()` 把它置为非 0，正在进行的网络操作随即以 `GitException` 结束，`code` 为 `qgECanceled`，`GitException.isCanceled` 为 true。操作结束后调用 `dispose()` 释放内存。

### 错误

失败时抛出 `GitException`。

- `code`：libgit2 错误码，或 `qgECanceled`、`qgEConflict`、`qgEInvalid`。
- `klass`：libgit2 的 `git_error_t`。C 层的错误为 0。
- `message`：UTF-8 文本。

`MergeOutcome.conflicts` 表示索引和工作区已有冲突，`MERGE_HEAD` 已写入。`commitMerge` 在索引仍有冲突时抛出 `qgEConflict`。

## API

| 成员 | 说明 |
|---|---|
| `QfliGit.ensureInitialized()` | 把 `assets/cacert.pem` 复制到应用支持目录，然后调用 `qg_init`。 |
| `QfliGit.libgit2Version` / `mbedtlsVersion` / `apiVersion` | 读取原生库版本。 |
| `GitRepository.clone()` / `init()` / `open()` | 克隆、创建、按路径打开。 |
| `GitRepository.addAll()` | 等价 `git add -A`。 |
| `GitRepository.commit()` / `commitMerge()` | 生成提交，返回提交 id。 |
| `GitRepository.createBranch()` / `checkout()` | 建分支、安全检出。 |
| `GitRepository.merge()` | 返回 `MergeOutcome`。 |
| `GitRepository.conflicts()` | 返回冲突路径列表。 |
| `GitRepository.status()` / `head()` | 返回工作区状态、HEAD。 |
| `GitRepository.fetch()` / `push()` | 网络操作，可传 `CancelToken`。 |

## 主机测试

设置环境变量 `QFLI_GIT_LIBRARY` 指向本机编出的库，即可在桌面平台打开它：

```powershell
$env:QFLI_GIT_LIBRARY = "build/native/libqfli_git.so"
```

不设置该变量、又不在 Android、iOS、OpenHarmony 上运行时，插件抛出 `UnsupportedError`。

## 测试

`flutter test` 只跑纯 Dart 部分：JSON 解析、错误码映射、`MergeOutcome` 映射、`qg_error` 结构布局。这些测试不加载原生库。

## 许可证

GPL-3.0-or-later，见 `LICENSE`。libgit2 用 GPLv2 with linking exception，mbedTLS 用 Apache-2.0。清单见 `third_party/README.md`。
