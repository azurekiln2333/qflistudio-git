# 交叉检查：Pi D 检查 Pi B（CI 与产物导入）

检查对象：`.github/workflows/native.yml`、`tool/ci/collect_artifacts.py`、`tool/ci/test_collect_artifacts.py`、`tool/install_ohos_sdk.sh`、`tool/import_artifacts.py`、`tool/ci/test_import_artifacts.py`。
对照依据：`design.md` 第 4、5、7 节，`prd.md` R5、A8，插件目录 `android/`、`ios/`、`ohos/`。

只读检查，未修改任何检查对象。

## 已确认的问题

### 1. `import_artifacts.py --release` 一定失败：Release 的 zip 多包了一层目录

- 文件与行号：`.github/workflows/native.yml:259-266`，`tool/import_artifacts.py:189-200`（`import_release`）。
- 问题：Release 任务把 `dist/` 下每个 Actions 产物目录整体打包，命令是 `zip -r -9 -q "$name.zip" "$directory"`，成员名形如 `qfli-git-android-<sha>/manifest.json`、`qfli-git-android-<sha>/arm64-v8a/libqfli_git.so`。`import_release` 把 zip 解压到 `workdir/<platform>` 后直接调用 `import_artifact(extracted, ...)`，而 `load_manifest` 只在 `<extracted>/manifest.json` 找清单。
- 为什么是问题：下载的 Release 包里清单在 `qfli-git-android-<sha>/` 子目录下，所以 `--release` 这条路径必然报 `Missing manifest.json`。`design.md` 第 7 节要求 `import_artifacts.py` 支持从 Release URL 导入，这条功能实际不可用。CI 里的 example 任务走 `--artifact` 直连 Actions 产物目录，所以 CI 不会暴露这个缺陷。另外 `tool/ci/test_import_artifacts.py` 没有覆盖 `import_release`，测试绿也说明不了这条路径。
- 复现（本机，模拟 Release 打包）：把一份合法产物目录按 `zip -r qfli-git-android-abc123.zip qfli-git-android-abc123` 打包，再走 `import_release` 的解压逻辑调用 `import_artifact`，得到
  `import: FAILED -> Missing manifest.json in ...\work\android`。
- 建议改法：二选一。改打包，让 zip 成员不带顶层目录：
  ```sh
  cd dist
  for directory in */; do
    name="${directory%/}"
    ( cd "$directory" && zip -r -9 -q "../$name.zip" . )
  done
  ```
  或改导入，解压后若 `extracted/manifest.json` 不存在但恰有一个子目录含 `manifest.json`，就用那个子目录。前者更干净，但注意 `cd` 后返回码要检查。两种改法都要在 `test_import_artifacts.py` 里补一条带顶层目录的 zip 用例。
- 严重程度：高。

### 2. manifest 里的 `abi` 没有做路径校验，可以写到插件目录外

- 文件与行号：`tool/import_artifacts.py:90-104`（`destination_for`），调用点 `import_artifacts.py:135-137`。
- 问题：`destination_for` 直接 `repo_root / "android/src/main/jniLibs" / abi / relative.name` 和 `repo_root / "ohos/libs" / abi / relative.name`，`abi` 取自 `record.get("abi")`，只检查非空，没有做 `safe_relative` 同款校验。`verify_manifest` 只校验 `path` 和字节数，不看 `abi`。
- 为什么是问题：`abi` 为 `../../../escaped` 时，复制目标落在插件目录之外，甚至仓库之外。`path` 有防护、`abi` 没有，等于把同一个入口开了两个洞。当前产物由本仓库 CI 生成，风险不高，但导入脚本也接收 Release 下载的、以及手写的 manifest，`design.md` 第 7 节明确要求「校验产物」。
- 复现（本机）：把一份合法 manifest 的 `abi` 改成 `../../../escaped`，其余字段与文件都不动，运行 `python tool/import_artifacts.py --artifact <dir> --repo-root <repo>`：
  ```
  android: 1 files from cccccccccccc
  exit code: 0
  written: ...\repo\android\escaped\libqfli_git.so
  ```
- 建议改法：在 `destination_for` 里对 `abi` 复用 `safe_relative` 并加白名单，例如
  ```python
  expected = PLATFORM_ABIS[platform]  # 与 collect_artifacts 共用同一份常量
  if abi not in expected:
      raise ArtifactError(f"{platform} manifest has an unknown abi: {abi!r}")
  ```
  并在 `test_import_artifacts.py` 增加 `abi` 越权用例。
- 严重程度：高。

### 3. 产物里只带项目许可证，libgit2、mbedTLS、CA 包的许可证实际不会被收集

- 文件与行号：`tool/ci/collect_artifacts.py:27-32`（`LICENSE_CANDIDATES`）、`:203-207`（扫描 `third_party/licenses`）。
- 问题：脚本从 `third_party/licenses/libgit2.txt`（或 `LIBGIT2-LICENSE`）等路径找上游许可证，仓库里 `third_party/licenses/` 目录不存在（`Test-Path third_party/licenses` 为 `False`），根目录只有 `LICENSE`。所以每个产物的 `manifest.json` 里 `licenses` 只有 `licenses/PROJECT-LICENSE` 一份。
- 为什么是问题：`prd.md` A8 要求「许可证文件齐全」，`design.md` 第 7 节和 `third_party/README.md` 也都把许可证清单当作产物的一部分。实际发布出去的库（libgit2 静态链接、mbedTLS 静态链接、cacert.pem）不带任何上游许可证文本，A8 无法通过。当前 `test_collect_artifacts.py` 只断言 `PROJECT-LICENSE` 存在，所以测试是绿的。
- 建议改法：在 `third_party/licenses/` 目录放 `libgit2.txt`、`mbedtls.txt`、`cacert.txt`（MPL-2.0 声明），或者让 `fetch_sources.py` 在解压后把上游 `COPYING`/`LICENSE` 复制到该目录。再在 `test_collect_artifacts.py` 里断言这三份都在 manifest 的 `licenses` 里，缺一份就失败。
- 严重程度：中。

### 4. `host-smoke` 重复编译冒烟测试

- 文件与行号：`.github/workflows/native.yml:47-58`，`native/CMakeLists.txt:200-213`。
- 问题：`build_native.sh --platform host` 已经在 CMake 里把 `qfli_git_smoke` 编到同一个输出目录，workflow 又用 `cc` 手动编了一遍 `native/test/smoke.c`，还多带 `-lpthread -ldl -lm`。
- 为什么是问题：两条编译路径的宏和链接参数不一致，手动那条一旦和 CMake 里的配置漂移（例如新增了需要链接的库），CI 会用另一套参数掩盖问题。也不必要地多花一次编译时间。
- 建议改法：直接运行 CMake 产出的 `native/build/ci/host/qfli_git_smoke`，删掉手写 `cc` 步骤。若坚持保留手动编译，把参数集中到一个脚本里，让本地和 CI 共用。
- 严重程度：低。

## 已验证通过的部分

- 产物路径与导入目录一致：CI 产物根下是 `<abi>/libqfli_git.so`、`<abi>/qfli_git.h`、`manifest.json`、`licenses/`（`collect_artifacts.py:225-240`）；`import_artifacts.py` 只取 `lib*.so` 作为 payload（`:80-88`），Android 落到 `android/src/main/jniLibs/<abi>/`（与 `android/build.gradle` 默认 sourceSet 一致，无 CMake），鸿蒙落到 `ohos/libs/<abi>/`（与 `ohos` HAR 目录一致），iOS 落到 `ios/Frameworks/qfli_git.xcframework/`（与 `ios/qfli_git.podspec:19` 的 `vendored_frameworks` 一致）。
- iOS 导入前整目录删除 `ios/Frameworks/qfli_git.xcframework`（`import_artifacts.py:124-128`），旧 slice 不会残留。
- Release 只在 `native-v*` 标签运行：`native.yml:252` `if: !cancelled() && startsWith(github.ref, 'refs/tags/native-v')`；触发条件里 `tags: 'native-v*'`（`:8-10`）。release 任务的 zip 名 `qfli-git-<platform>-<sha>.zip` 与 `release_assets` 的匹配规则 `qfli-git-{platform}-*.zip`（`import_artifacts.py:159-162`）一致。
- Release 任务单独声明 `permissions: contents: write`（`:253-255`），顶层 `contents: read` 不会挡住 `gh release`。
- 鸿蒙 SDK 安装：`install_ohos_sdk.sh` 只筛选 Linux native 包，校验 SHA-256，设置 `OHOS_SDK_HOME` 到含 `native/llvm/bin` 的目录；SBOM 里的 `$OHOS_SDK_HOME/native/llvm/bin/llvm-readelf`、`llvm-nm`（`native.yml:131-141`）确实存在，与 `tool/build_native.sh` 的 `find_llvm_tool "$OHOS/native"` 一致。`native/llvm/bin/clang` 允许符号链接的修复有效。
- 页对齐与导出符号检查：`collect_artifacts.py` 从 `readelf -lW` 最后一个字段取 `p_align` 并要求 `>= 0x4000` 且为 0x4000 的倍数；`nm -D --defined-only` 过滤 `_` 前缀和版本节点 `A` 符号后要求全部 `qg_` 前缀。与 `design.md` 第 3 节的链接参数、`native/exports.map` 对应。
- `python -m unittest discover -s tool/ci -p 'test_*.py'` 在本 worktree 通过：`Ran 25 tests ... OK`。
- `native.yml` 能被 YAML 解析，任务集合为 `host-smoke, android, ohos, ios, example-android, example-ios, release`，与 `design.md` 第 4 节表格一致。Actions 均按提交 SHA 锁定。

## 待确认（未定性，供大脑判断）

1. `is_payload`（`import_artifacts.py:80-88`）用 `name.startswith("lib") and suffix == ".so"` 认 payload，会把任何 `lib*.so` 当作要导入的库。目前产物里只有 `libqfli_git.so`，所以没影响。如果以后产物里带上 `libc++_shared.so`，它会被复制进 `jniLibs`。是否收紧成只认 `LIBRARY_NAME`，请大脑定。
2. iOS 的 `abis` 由 CI 手写（`native.yml:183-184` `--abi arm64 --abi x86_64`），而 `collect_artifacts.py:269` 直接 `abis = list(args.abi or [])`，没有从 xcframework 的实际 slice 推导。两处不一致（模拟器 slice 是 `arm64+x86_64`，真机 slice 是 `arm64`）时清单会失真，且漏传 `--abi` 时 `abis` 为空但检查仍然通过。是否需要改为从 `Info.plist`/slice 目录推导，请大脑定。
3. `native_libs.lock.json` 由 `import_artifacts.py` 写入，只记录导入的 payload 文件，不记录 `manifest.json` 摘要、也不记录 `licenses`。`design.md` 第 7 节只要求记录来源提交和各文件 SHA-256，符合约定，但无法从锁文件反查当时的清单。是否需要补，请大脑定。
