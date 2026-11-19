# Pi D 报告

## 结论

鸿蒙侧打包可行。flutter_ohos 会把插件 HAR 模块 `ohos/libs/<abi>/` 的预编译 `.so` 打进应用 HAP，不需要退路。

示例应用已按 `design.md` 第 6 节写完。`flutter analyze` 无问题。`flutter test` 3 个用例通过。`integration_test` 没跑，本分支还缺原生库和 Pi C 的 `pubspec.yaml`。

## 改了哪些文件

- `example/`（整个目录，新文件）
  - `pubspec.yaml`：依赖 `qfli_git: path: ../`、`path`、`path_provider`，dev 依赖 `integration_test`、`flutter_test`、`flutter_lints`。
  - `lib/main.dart`：表单、全流程按钮、取消按钮、步骤列表、顶部 `QfliGit.libgit2Version`。
  - `lib/flow.dart`：`FlowSettings`、`FlowStep`、`FlowRunner`，按 R6.2 的十步执行。
  - `test/widget_test.dart`：表单字段、令牌遮挡开关、取消按钮初始禁用。
  - `integration_test/flow_test.dart`：本地裸仓库、clone、commit、分支、冲突合并、冲突列表、合并提交、push。
  - `README.md`：运行方法、界面说明、测试命令。
  - `android/`、`ios/`、`ohos/`：`flutter create` 生成。
- `.trellis/tasks/11-19-git-ci-validation/research/ohos-ffi-packaging.md`（新文件）

## 第一部分：鸿蒙打包验证

验证工程在 `D:\MyNewProjects\_wt\qfli_git\spike\`，不在 git 里。完整记录见 `research/ohos-ffi-packaging.md`。

### 构建命令

```
cd D:\MyNewProjects\_wt\qfli_git\spike\spike_plugin\example
set JAVA_HOME=D:\ProgramFiles\Huawei\DevEco Studio\jbr
set PATH=%JAVA_HOME%\bin;%PATH%
flutter build hap --debug
```

`java` 必须在 PATH 最前面用 DevEco 的 jbr。PATH 里原来的 Oracle javapath 会让 `app_packing_tool.jar` 崩在 `0xC0000005`。

### 解包结果

产物：`spike_plugin\example\ohos\entry\build\default\outputs\default\entry-default-unsigned.hap`

```
libs/arm64-v8a/libflutter.so   38715088
libs/arm64-v8a/libqfli_git.so      4136
libs/x86_64/libqfli_git.so         3960
```

应用的 `ohos/entry/libs/` 是空的，所以这两个库只来自插件 HAR 的 `ohos/libs/`。

`.so` 在 HAP 里被剥掉符号（源文件 11720 字节，HAP 里 4136 字节）。`qg_api_version` 仍在动态符号表。`llvm-readelf -lW` 显示四个 `LOAD` 段 `Align` 都是 `0x4000`。

### 没做的部分

`hdc list targets` 为空，没有鸿蒙设备。构建停在签名步骤：

```
请通过DevEco Studio打开ohos工程后配置调试签名(File -> Project Structure -> Signing Configs 勾选Automatically generate signature)
```

得到的 `entry-default-unsigned.hap` 足够做第 7 步的解包校验。装机运行留到接上设备时做。

`C:\Users\<user>\.ohos\config\default_ohos_*.p7b` 绑定 `bundle-name` 和 UDID 白名单，不能跨应用或跨设备复用。必须连上鸿蒙设备后由 DevEco Studio 重新生成。

### Android 对照

```
flutter build apk --debug --target-platform android-arm64
```

APK 内：

```
lib/arm64-v8a/libqfli_git.so    4320
lib/x86_64/libqfli_git.so       4144
```

装到 `FA6CP0302212`（Pixel，android-arm64，API 29）：

```
adb install -r build/app/outputs/flutter-apk/app-debug.apk
Success
adb logcat -s flutter:I
I flutter : SPIKE_PROBE ok qg_api_version=1
```

真机上 `DynamicLibrary.open('libqfli_git.so')` 和 `qg_api_version` 都成功。

没截到应用界面。真机设了锁屏密码，屏幕锁着，`dumpsys window` 显示 `isStatusBarKeyguard=true`、`mAwake=false`。解锁界面截图在 `D:\MyNewProjects\_wt\qfli_git\spike\screenshots\android-device-state.png`。应用跑起来的证据是 logcat 的 `SPIKE_PROBE ok qg_api_version=1` 和 `ResumedActivity: com.example.spike_plugin_example/.MainActivity`。解锁设备后可以直接补截图。

## 第二部分：示例应用

### 全流程步骤

clone、写基础文件、commit、建分支、切分支、分支上提交、切回主干、主干上制造冲突提交、merge、列冲突、解决冲突、合并提交、push。

冲突解决方式：读工作区里的冲突文件，删掉 `<<<<<<<`、`=======`、`>>>>>>>` 行，两边内容自然拼在一起，然后 `addAll` 和 `commitMerge`。

令牌只存在 `_tokenController` 里，只作为 `username`/`token` 参数传给 clone 和 push。不写 SharedPreferences，不写文件，不进日志，不进 `FlowStep.error`。

### 调用的 API 和参数

全部按 `design.md` 第 6 节，参数名逐一核对：

| 调用 | 参数 |
|---|---|
| `QfliGit.ensureInitialized()` | 无 |
| `QfliGit.libgit2Version` | 无（静态 getter） |
| `GitRepository.clone` | `url:`, `path:`, `username:`, `token:`, `cancel:` |
| `GitRepository.init` | 位置参数 `path`，命名参数 `bare:` |
| `GitRepository.open` | 位置参数 `path` |
| `GitRepository.path` | 字段 |
| `repo.addAll()` | 无 |
| `repo.commit` | 位置参数 `message`, `GitAuthor` |
| `repo.createBranch` | 位置参数 `name` |
| `repo.checkout` | 位置参数 `name` |
| `repo.merge` | 位置参数 `branch`, `GitAuthor`，返回 `MergeOutcome` |
| `repo.conflicts()` | 无，返回 `List<String>` |
| `repo.commitMerge` | 位置参数 `message`, `GitAuthor` |
| `repo.status()` | 无，返回 `List<GitStatusEntry>` |
| `repo.head()` | 无，返回 `GitHead`，用到 `branch`、`oid`、`state` |
| `repo.push` | `remote: 'origin'`, `refspec:`, `username:`, `token:`, `cancel:` |
| `GitAuthor` | 位置参数 `name`, `email` |
| `CancelToken()` / `.cancel()` / `.dispose()` | 无 |
| `GitException` | 读 `code`、`klass`、`message` |

`fetch()` 没有用到，R6.2 的全流程里没有 fetch 步骤。

## 本地验证

### `flutter analyze`

本分支还没有根目录 `pubspec.yaml`，`example/` 无法直接 `flutter pub get`。我在 `spike\verify-example` 复制了一份 `example/lib`、`example/test`、`example/integration_test` 和 `pubspec.yaml`，把依赖指向 Pi C 的工作树 `D:\MyNewProjects\_wt\qfli_git\pi-c`。

```
cd D:\MyNewProjects\_wt\qfli_git\spike\verify-example
flutter pub get --offline
flutter analyze
Analyzing verify-example...
No issues found! (ran in 1.7s)
```

`spike\verify-example` 不在 git 里。

### `flutter test`

```
00:00 +0: form shows every input and both buttons
00:00 +1: token field is obscured until toggled
00:00 +2: cancel button is disabled until a run starts
00:00 +3: All tests passed!
```

### `integration_test`

没跑。原因有两条：

1. 本分支没有 `qfli_git` 的原生库，Windows 主机也没有 host 版 `.so`。
2. Android 真机锁屏，鸿蒙无设备。

写测试时按「不依赖网络的空仓库 clone 可能失败」做了规避：先用 `init` 建一个带首个提交的普通仓库，从它 clone，再用 `init(bare: true)` 建裸仓库作为 push 目标。裸仓库的远程靠测试里往 `.git/config` 追加 `[remote "bare"]` 段落来建立。这样不依赖 libgit2 对空裸仓库 clone 的行为。

## 未完成项

- 鸿蒙 HAP 没有签名，没有装机运行和截图。需要接上鸿蒙设备，并在 DevEco Studio 里自动生成签名。
- `example/` 没有真机跑过全流程。等 Pi A 和 Pi C 合入后，本机 Android 真机解锁即可跑 `flutter run` 和 `flutter test integration_test`。
- 没有 `example/` 的安装包体积数据。`prd.md` A6 要求插件前后对比，需要预编译库导入后才能测。

## 接口问题

没有阻塞性问题。两点观察，按原约定继续实现：

1. `design.md` 第 6 节没有「添加远程」的 API。集成测试要给仓库加第二个远程，只能直接改 `.git/config`。如果以后需要给本地仓库指定推送目标，建议增加 `addRemote(name, url)`。本任务不阻塞。
2. `GitRepository.open` 是同步方法，不校验仓库是否存在。集成测试里 push 之后用它读裸仓库 HEAD，能工作。若要让调用方更早发现路径错误，可以改成异步并调用 `qg_repo_open`。本任务不阻塞。