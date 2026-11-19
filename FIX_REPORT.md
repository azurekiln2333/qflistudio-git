# Pi B Fix Report (round 2)

范围：`.github/workflows/native.yml`、`tool/ci/`、`tool/import_artifacts.py`、`third_party/licenses/`。
依据：`research/cross-check/d-checks-ci.md` 与 `briefs/fix-round2.md` 的 Pi B 小节。

## 1. 高-1 Release 的 zip 多包一层目录

- `.github/workflows/native.yml`：`Zip every platform artifact` 改为进入每个产物目录再打包，成员落在 zip 根部：

  ```sh
  cd dist
  for directory in */; do
    name="${directory%/}"
    ( cd "$directory" && zip -r -9 -q "../$name.zip" . ) || exit 1
  done
  sha256sum ./*.zip > SHA256SUMS
  ```

- `tool/import_artifacts.py`：新增 `artifact_root()`，解压后若 `<extracted>/manifest.json` 不存在但恰好一个子目录含 `manifest.json`，就用那个子目录；多于一个时报 `ArtifactError`。`import_release()` 改为把结果交给 `import_artifact()`。
- `tool/ci/test_import_artifacts.py`：新增 `test_release_zip_with_wrapper_directory`（带一层顶层目录的 zip 能导入）与 `test_artifact_root_rejects_two_wrapper_directories`。

验证（本机模拟新打包方式的成员名，含 `zip -r .` 写出的 `./` 前缀）：

```
flat: root='flat' exit=0 copied=True
wrapped: root='qfli-git-android-abc' exit=0 copied=True
```

## 2. 高-2 `abi` 没做路径校验

- `tool/import_artifacts.py`：新增 `PLATFORM_ABIS`（android: arm64-v8a、armeabi-v7a、x86_64；ohos: arm64-v8a、x86_64）与 `safe_abi()`。`destination_for()` 的 android / ohos 分支改为走白名单，清单里的 abi 不在白名单时抛 `ArtifactError`。
- `tool/ci/test_import_artifacts.py`：新增 `test_abi_traversal_is_rejected`（`../../../escaped` 返回 1，且不写 `android/escaped`、不写锁文件）与 `test_unknown_abi_is_rejected`（ohos 清单出现 `armeabi-v7a` 返回 1）。

## 3. 中-3 上游许可证没进产物

- 新增 `third_party/licenses/libgit2.txt`（libgit2 1.9.7 的 `COPYING`）、`third_party/licenses/mbedtls.txt`（Mbed TLS 3.6.8 的 `LICENSE`），文本取自本机已解压的上游源码包。
- 新增 `third_party/licenses/cacert.txt`：MPL-2.0 声明、来源（`https://curl.se/ca/` 的日期文件）、完整文本地址。
- `tool/ci/collect_artifacts.py`：`collect_licenses()` 的目录补扫改为按来源路径去重，避免 `libgit2.txt` 既生成 `LICENSES/LIBGIT2-LICENSE` 又生成 `UPSTREAM-libgit2.txt`。
- `tool/ci/test_collect_artifacts.py`：`prepare()` 造出三份上游许可证；新增 `test_upstream_licenses_are_collected`（清单恰好是 CACERT / LIBGIT2 / MBEDTLS / PROJECT 四份，且文件都落在产物里）与 `test_repository_licenses_exist`（仓库里三份文件存在且非空）。

验证（对真实仓库根目录调用 `collect_licenses`）：

```
licenses: ['licenses/CACERT-LICENSE', 'licenses/LIBGIT2-LICENSE', 'licenses/MBEDTLS-LICENSE', 'licenses/PROJECT-LICENSE']
licenses/CACERT-LICENSE 776
licenses/LIBGIT2-LICENSE 72970
licenses/MBEDTLS-LICENSE 29852
licenses/PROJECT-LICENSE 35823
```

## 4. 低-4 `host-smoke` 重复编译冒烟测试

- `.github/workflows/native.yml`：删除手写 `cc` 步骤，`Run smoke test` 直接运行 `./native/build/ci/host/qfli_git_smoke`。`tool/build_native.sh --platform host` 已通过 CMake 目标 `qfli_git_smoke` 把二进制写进 `--out` 目录（`native/CMakeLists.txt:182-189`）。

## 5. 待确认 1 `is_payload` 认所有 `lib*.so`

- `tool/import_artifacts.py`：android / ohos 只把 `LIBRARY_NAME`（`libqfli_git.so`）当 payload。
- `tool/ci/test_import_artifacts.py`：新增 `test_other_shared_libraries_are_not_payload`，同一 ABI 下的 `libc++_shared.so` 不进 `jniLibs`。

## 验证输出

```
$ python -m unittest discover -s tool/ci -p "test_*.py"
Ran 32 tests in 0.128s
OK
```

YAML 解析（PyYAML）：

```
jobs: host-smoke,android,ohos,ios,example-android,example-ios,release
host-smoke steps: [None, None, 'Check CI scripts', 'Fetch pinned upstream sources', 'Build host library', 'Run smoke test']
Zip every platform artifact -> cd dist | for directory in */; do |   name="${directory%/}" |   ( cd "$directory" && zip -r -9 -q "../$name.zip" . ) || exit 1 | done | sha256sum ./*.zip > SHA2...
```

本机没有可用的 bash / zip / WSL（WSL 报 `HCS_E_HYPERV_NOT_INSTALLED`），所以 Release 打包脚本只做了 YAML 解析与等价的 Python 模拟，没有在真机 shell 里跑过；CI 上 `release` 任务首次触发时会覆盖这条路径。

## 未完成项

- 未在真实 GitHub Actions 上运行 `release` 任务（需要 `native-v*` 标签，属大脑操作）。

## 接口问题

无。`import_artifacts.py` 的 abi 白名单直接复用了 `collect_artifacts.py` 里的同一组值，两处仍各写一份常量，后续若要改成单一来源，需要把常量移到共享模块。

## 提醒（不在本人文件范围，未改）

`third_party/README.md` 仍写着「libgit2 完整条款在 `native/build/src/libgit2-1.9.7/COPYING`」，现在文本已提交在 `third_party/licenses/libgit2.txt`，建议由负责该文档的 Pi 顺手改一句。