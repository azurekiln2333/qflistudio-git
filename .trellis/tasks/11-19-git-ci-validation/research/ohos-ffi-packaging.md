# 鸿蒙 FFI 插件打包验证

日期：2026-11-19。执行者：Pi D。

## 结论

插件 HAR 模块的 `ohos/libs/<abi>/` 下的预编译 `.so` 会被 flutter_ohos 打进应用 HAP。

- HAP 内路径：`libs/arm64-v8a/libqfli_git.so`、`libs/x86_64/libqfli_git.so`。
- 不需要退路，不需要把 `.so` 放到应用的 `ohos/entry/libs/<abi>/`。
- `design.md` 第 5 节把这条风险列为「高」，实测可行，风险降为低。

链路：应用 `hvigorconfig.ts` 调用 `injectNativeModules`，把插件 `ohos/` 目录作为 HAR 节点加入构建。hvigor 把 HAR 的 `libs/<abi>/*.so` 合并进应用 `entry/build/default/intermediates/stripped_native_libs/<target>/<abi>/`，`app_packing_tool.jar` 再写进 HAP 的 `libs/<abi>/`。

## 验证环境

| 项 | 值 |
|---|---|
| Flutter | 3.27.5-ohos-1.0.1，`D:\ProgramFiles\flutter_ohos` |
| 鸿蒙 SDK | `D:\ProgramFiles\Huawei\DevEco Studio\sdk`（HarmonyOS 26.0.0，API 26，`default`） |
| 鸿蒙 clang | SDK `native/llvm/bin/clang.exe`，LLVM 15.0.4 |
| JDK | `D:\ProgramFiles\Huawei\DevEco Studio\jbr`（OpenJDK 25.0.2） |
| Android NDK | 28.2.13676358 |
| Android 真机 | Pixel，`FA6CP0302212`，android-arm64，API 29 |
| 鸿蒙真机 | 无，`hdc list targets` 为空 |

验证工程放在 `D:\MyNewProjects\_wt\qfli_git\spike\`（不在 git 里）。

## 步骤

### 1. 建插件

```
flutter create --template=plugin_ffi --platforms=android,ohos spike_plugin
```

本机 pub.dev 不通，`flutter pub get` 失败。从 `pubspec.yaml` 删掉 `ffigen` 后 `flutter pub get --offline` 成功。插件只用到 `plugin_platform_interface`、`ffi`、`flutter_test`、`flutter_lints`，缓存里都有。

### 2. 去掉 HAR 的 CMake 构建

`spike_plugin/ohos/build-profile.json5` 删掉整个 `externalNativeOptions`，只留 `apiType` 和 `targets`。

Android 侧同样删掉 `android/build.gradle` 的 `externalNativeBuild { cmake { ... } }`，与 `design.md` 第 5 节「预编译库放 `src/main/jniLibs/<abi>/`」一致。

### 3. 编最小库

`spike/native/qfli_git_spike.c`：

```c
__attribute__((visibility("default"))) int qg_api_version(void) { return 1; }
```

脚本 `spike/native/build_spike_lib.ps1`：

```
clang.exe --target=aarch64-linux-ohos --sysroot=<sdk>/native/sysroot \
  -shared -fPIC -O2 -fvisibility=hidden -fuse-ld=lld \
  -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384 \
  -Wl,-soname,libqfli_git.so -o out/arm64-v8a/libqfli_git.so qfli_git_spike.c
```

`x86_64-linux-ohos` 同参数。

注意：SDK 的 `aarch64-unknown-linux-ohos-clang`、`x86_64-unknown-linux-ohos-clang` 是没有扩展名的 shell 脚本，Windows 上不能直接执行。用 `clang.exe --target=<triple>` 代替。

产物：

| ABI | 大小 |
|---|---|
| arm64-v8a | 11720 字节 |
| x86_64 | 9848 字节 |

`llvm-readelf -lW` 显示四个 `LOAD` 段 `Align` 均为 `0x4000`（16 KB）。`llvm-nm -D --defined-only` 只有 `qg_api_version`、`_init`、`_fini`。

### 4. 放进插件

- `spike_plugin/ohos/libs/arm64-v8a/libqfli_git.so`
- `spike_plugin/ohos/libs/x86_64/libqfli_git.so`
- `spike_plugin/android/src/main/jniLibs/arm64-v8a/libqfli_git.so`
- `spike_plugin/android/src/main/jniLibs/x86_64/libqfli_git.so`

### 5. 应用调用

插件自带的 `example/` 应用改 `lib/main.dart`：`DynamicLibrary.open('libqfli_git.so')`，`lookupFunction` 取 `qg_api_version`，界面显示结果，同时 `debugPrint`。

### 6. 构建 HAP

```
cd spike_plugin\example
set JAVA_HOME=D:\ProgramFiles\Huawei\DevEco Studio\jbr
set PATH=%JAVA_HOME%\bin;%PATH%
flutter build hap --debug
```

### 7. 解包 HAP

HAP 是 zip。产物：`spike_plugin\example\ohos\entry\build\default\outputs\default\entry-default-unsigned.hap`。

```
libs/arm64-v8a/libflutter.so   38715088
libs/arm64-v8a/libqfli_git.so      4136
libs/x86_64/libqfli_git.so         3960
```

`.so` 被 hvigor 的 `debugSymbol.strip` 剥掉符号（11720 → 4136），`qg_api_version` 仍在动态符号表，`LOAD` 对齐仍是 `0x4000`。

应用自己的 `entry/libs/` 目录为空，所以这三个库只能来自插件 HAR。退路（应用放 `.so`）不需要验证。

### 8. 装机

`hdc list targets` 为空，没有鸿蒙设备。构建卡在签名：hvigor 报

```
请通过DevEco Studio打开ohos工程后配置调试签名(File -> Project Structure -> Signing Configs 勾选Automatically generate signature)
```

结果是 `entry-default-unsigned.hap`，解包校验已经完成，安装运行留到有设备时做。

签名要点：`C:\Users\<user>\.ohos\config\default_ohos_*.p7b` 是调试证书描述文件，绑定 `bundle-name` 和 `device-ids`（UDID 白名单）。换 bundleName 或换设备都会失败。必须连上鸿蒙设备后由 DevEco Studio 重新生成。

### 9. Android 对照

```
flutter build apk --debug --target-platform android-arm64
```

APK 内：

```
lib/arm64-v8a/libqfli_git.so    4320
lib/x86_64/libqfli_git.so       4144
```

装到 `FA6CP0302212`：

```
adb install -r build/app/outputs/flutter-apk/app-debug.apk   -> Success
adb shell am start -n com.example.spike_plugin_example/.MainActivity
adb logcat -s flutter:I
I flutter : SPIKE_PROBE ok qg_api_version=1
```

真机上 `DynamicLibrary.open('libqfli_git.so')` 和 `qg_api_version` 都成功。

## 截图

- `D:\MyNewProjects\_wt\qfli_git\spike\screenshots\android-device-state.png`：解锁界面。真机设了锁屏密码，未解锁，无法截应用界面。
- 应用是否真的跑起来，用 logcat 的 `SPIKE_PROBE ok qg_api_version=1` 和 `ResumedActivity: com.example.spike_plugin_example/.MainActivity` 证明。

## 失败的尝试

| 现象 | 原因 | 处理 |
|---|---|---|
| `flutter create` 结束时报 `Got socket error trying to find package flutter_lints` | pub.dev 不通 | 删 `ffigen`，`flutter pub get --offline` |
| `:entry:default@PackageHap` 报 `Command failed with exit code 3221225477`（`0xC0000005`），崩在 `app_packing_tool.jar` | PATH 里的 `java` 是 `C:\Program Files\Common Files\Oracle\Java\javapath\java.exe`，执行无输出 | 把 DevEco 的 `jbr\bin` 放到 PATH 最前 |
| `flutter build hap` 报 `The term '...aarch64-unknown-linux-ohos-clang' is not recognized` | 那个文件是 shell 脚本 | 用 `clang.exe --target=aarch64-linux-ohos` |
| `flutter build hap` 报「请通过DevEco Studio打开ohos工程后配置调试签名」 | 模板 `signingConfigs` 为空 | 未解决，需要鸿蒙设备 + DevEco 自动签名 |

## 打包行为要点

1. HAR 的 `libs/<abi>/` 会进 HAP。`injectNativeModules` 把插件 `ohos/` 注册成 HAR 节点，hvigor 合并 native 库到应用 entry。
2. HAR 的 native 库不受 `--target-platform` 约束。用 `--target-platform ohos-arm64` 构建，HAP 里仍有 `x86_64/libqfli_git.so`。要精简包体，在应用的 `entry/build-profile.json5` 加：

   ```json5
   "buildOption": {
     "nativeLib": {
       "filter": { "excludes": ["**/x86_64/**", "**/armeabi-v7a/**"] }
     }
   }
   ```

   这也是 `qfli_c` 现有做法。
3. `debugSymbol.strip` 默认开启，会剥掉 HAR 里的 `.so` 符号。只保留动态符号和 16 KB 页对齐，符合 `prd.md` R2.2、R2.3。
4. 插件 HAR 不需要 `externalNativeOptions`。删掉后 hvigor 不调用 CMake，构建更快，也不会因为 NDK 缺失失败。

## 对 qfli_git 的落地建议

- `ohos/` 只放 `build-profile.json5`（无 `externalNativeOptions`）、`hvigorfile.ts`、`oh-package.json5`、`src/main/module.json5`，加 `libs/arm64-v8a/libqfli_git.so` 和 `libs/x86_64/libqfli_git.so`。
- `pubspec.yaml` 的 `ohos: ffiPlugin: true` 就够了，Dart 侧 `DynamicLibrary.open('libqfli_git.so')`。
- example 应用不需要往 `ohos/entry/libs/` 复制任何东西。
- 发布前在 `example/ohos/entry/build-profile.json5` 按上表排除 `x86_64`，否则发布包多带一份库。
