# Pi A 报告：原生层

## 改了哪些文件

新增：

- `third_party/versions.json`：锁定 libgit2 1.9.7、Mbed TLS 3.6.8、cacert-2026-11-05，含 URL、文件名、SHA-256、许可证。
- `third_party/README.md`：上游版本、许可证、无补丁说明、升级步骤。
- `tool/fetch_sources.py`：纯标准库下载、校验、解压、`--update-assets`。
- `tool/build_native.sh`：`--platform/--abi/--out` 统一构建入口。
- `native/CMakeLists.txt`：编译静态链接 libgit2 + mbedTLS 的 `libqfli_git`，含导出控制、16 KB 对齐、iOS framework、host 冒烟测试目标。
- `native/include/qfli_git.h`：`design.md` 第 2 节接口，函数加 `QG_API` 可见性修饰。
- `native/src/qfli_git.c`：全部接口实现。
- `native/exports.map`：只导出 `qg_*`。
- `native/test/smoke.c`：主机冒烟测试。
- `assets/cacert.pem`：由 `fetch_sources.py --update-assets` 生成，200116 字节。

## 版本与校验和

SHA-256 都由本次实际下载后计算：

| 上游 | URL | SHA-256 |
|---|---|---|
| libgit2 1.9.7 | `https://github.com/libgit2/libgit2/archive/refs/tags/v1.9.7.tar.gz` | `1a4fbe7589e814777ae76b64734ad80f4ecad22cd33a22682a2aaea4ae5375e7` |
| Mbed TLS 3.6.8 | `https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-3.6.8/mbedtls-3.6.8.tar.bz2` | `bc54b818e87f49c0b3281dd85d24adaede0e63b4e822e3fbd49c005a38b9595b` |
| cacert 2026-11-05 | `https://curl.se/ca/cacert-2026-11-05.pem` | `427c064216761a1e72a8b30f0d954d08cb6e4435a82091fb865afd20c8497285` |

mbedTLS 3.6.8 是 3.6 LTS 最新补丁版，release 页第 1 到 3 页只到 3.6.8。包内 `mbedtls-3.6.8-sha256sum.txt` 与本地计算值一致。`cacert.pem` 与 `cacert-2026-11-05.pem` 内容相同，`2026-11-04`、`2026-11-06` 等日期返回 404，确认这是当前版本。

## 怎么验证

```
python tool/fetch_sources.py --update-assets
tool/build_native.sh --platform android --abi arm64-v8a     --out dist/android/arm64-v8a
tool/build_native.sh --platform android --abi armeabi-v7a   --out dist/android/armeabi-v7a
tool/build_native.sh --platform ohos    --abi arm64-v8a     --out dist/ohos/arm64-v8a
tool/build_native.sh --platform ohos    --abi x86_64        --out dist/ohos/x86_64
llvm-readelf -lW <so>      # LOAD 对齐
llvm-nm -D --defined-only  # 导出符号
```

Android 用 NDK 28.2.13676358，鸿蒙用 `D:\ProgramFiles\Huawei\OpenHarmony\Sdk\23`，CMake/Ninja 用 Android SDK 的 3.22.1。

## 验证结果

`fetch_sources.py`：

```
verified libgit2-1.9.7.tar.gz sha256=1a4fbe7589e814777ae76b64734ad80f4ecad22cd33a22682a2aaea4ae5375e7
unpack   libgit2-1.9.7.tar.gz -> native\build\src\libgit2
skipped 1 archive members the filesystem rejected
verified mbedtls-3.6.8.tar.bz2 sha256=bc54b818e87f49c0b3281dd85d24adaede0e63b4e822e3fbd49c005a38b9595b
wrote    assets/cacert.pem sha256=427c064216761a1e72a8b30f0d954d08cb6e4435a82091fb865afd20c8497285
```

跳过的那 1 个成员是 libgit2 测试夹具里 Windows 不接受的文件名，不参与编译。

libgit2 配置摘要（每次构建都会打印）：

```
 * HTTPS, using mbedTLS
 * SHA1, using CollisionDetection
 * SHA256, using builtin
 * http-parser, using bundled parser
 * regex, using bundled PCRE
 * zlib, using bundled zlib
 * GSSAPI / SSH / ntlmclient / iconv 均 Disabled
```

产物与检查：

| 产物 | 大小 (字节) | zip 后 (字节) | LOAD Align | 导出符号 |
|---|---|---|---|---|
| `dist/android/arm64-v8a/libqfli_git.so` | 1791784 | 853694 | 0x4000 | 21 个，全部 `qg_*` |
| `dist/android/armeabi-v7a/libqfli_git.so` | 1314272 | 768457 | 0x4000 | 21 个，全部 `qg_*` |
| `dist/ohos/arm64-v8a/libqfli_git.so` | 1776952 | 842661 | 0x4000 | 21 个，全部 `qg_*` |
| `dist/ohos/x86_64/libqfli_git.so` | 1914280 | 883462 | 0x4000 | 21 个，全部 `qg_*` |

`llvm-readelf -lW` 片段（Android arm64）：

```
  LOAD           0x000000 0x0000000000000000 0x0000000000000000 0x1a8880 0x1a8880 R E 0x4000
  LOAD           0x1a8880 0x00000000001ac880 0x00000000001ac880 0x009010 0x00b780 RW  0x4000
  LOAD           0x1b1890 0x00000000001b9890 0x00000000001b9890 0x0035a8 0x006f78 RW  0x4000
```

`llvm-nm -D --defined-only` 输出 21 行，全部是 `qg_`：`add_all api_version branch_create checkout_branch clone commit conflicts_json fetch head_json init libgit2_version mbedtls_version merge merge_commit push repo_free repo_init repo_open shutdown status_json string_free`。

鸿蒙 `libqfli_git.so` 的动态依赖只有 `libc.so`。`llvm-readelf -rW` 里没有 TLS 重定位，`.tdata`/`.tbss` 不存在，`design.md` 第 9 节的 musl TLS 风险不成立。

主机冒烟测试（`native/build/run_android_smoke.sh`，同一份 `smoke.c` 编成 Android arm64 可执行文件，在设备 `FA6CP0302212` 上跑）：

```
qfli_git smoke test
     qg_api_version     1
     libgit2            1.9.7
     mbedtls            3.6.8
     ca file            /data/local/tmp/cacert.pem
-- conflicting merge
ok   merge reports conflicts
ok   head reports an open merge
ok   conflicts json lists file.txt
ok   merge commit refuses open conflicts
-- resolve and finish the merge
ok   head reports no merge after the merge commit
ok   head points at the merge commit
ok   merge fast-forwards
ok   merging the current branch is a no-op
ok   cloned content matches
ok   cloned head matches the pushed fast-forward commit
-- anonymous https clone
ok   https clone
ok   https head is 49322bb17d3acc9146f98c97d078513228bbf3c0
PASS
exit=0
```

这条流程覆盖 clone → commit → push → 建分支 → 冲突合并 → 冲突列表 → 解决 → 合并提交 → push → 重新 clone 校验，外加 HTTPS 匿名 clone，说明 libgit2 1.9.7 与 mbedTLS 3.6.8 编译、运行都正常，CA 包可用。

## 未完成项

- 主机冒烟测试没有在本机跑：`wsl -d qfli-java-build` 报 `Wsl/Service/CreateInstance/CreateVm/HCS/E_HYPERV_NOT_INSTALLED`，本机也没有 MSVC、gcc、clang 和 docker，无法产出 Windows 主机库。`tool/build_native.sh --platform host` 与 `native/test/smoke.c` 由 CI 在 ubuntu-24.04、macos-15 上跑。本机改用 Android 设备执行同一份 `smoke.c`，结果见上。
- iOS 产物没编：本机无 macOS。`ios-device`、`ios-simulator` 分支（`FRAMEWORK TRUE`、`-exported_symbols_list`、`lipo` 合并）只做了代码实现，实际构建交给 CI 的 `ios` 任务。
- 取消路径没有在冒烟测试里触发。`qg_clone/fetch/push` 的取消靠进度回调返回非 0，再由 `qg_result()` 映射成 `QG_ECANCELED`，只能靠 Dart 侧集成测试覆盖。
- Android `x86_64` 没在本机编（只要求 arm64-v8a），CI 会编。

## 接口问题

1. `qfli_git.h` 的每个函数前面加了 `QG_API` 宏。原因：构建参数里有 `-fvisibility=hidden`，不加可见性修饰，`qg_*` 进不了动态符号表，version script 也没法把已隐藏的符号变成全局；iOS 的 `-exported_symbols_list` 同样无法导出隐藏符号。函数名、参数、返回值与 `design.md` 第 2 节完全一致，Dart 绑定不受影响。
2. `qg_status_json` 每项输出 `{"path": ..., "status": "worktree_modified", "status_bits": 256}`。`design.md` 只写了 `"status"`。多出的 `status_bits` 是 libgit2 `git_status_t` 原始位，方便 Dart 侧判断组合状态；`status` 仍是单个字符串。如果要严格两字段，删掉 `status_bits` 即可。
3. 构建依赖：libgit2 在 `USE_HTTPS=mbedTLS` 时用 `openssl version -d` 找默认证书目录，PATH 里没有 `openssl` 会直接 `FATAL_ERROR`。CI 的 ubuntu、macos 镜像自带 openssl，不受影响。如果以后要在没有 openssl 的机器上构建，需要给 libgit2 传 `-DCERT_LOCATION=...`，或者在 `native/CMakeLists.txt` 里补一个默认值。
4. libgit2 1.9.7 没有 `git_repository_fast_forward`。快进由 `qg_merge` 自己实现：`GIT_CHECKOUT_SAFE` 检出目标提交，再把当前分支引用指过去。对外语义与 `design.md` 的 `out_result = 1` 一致。
5. `qg_add_all` 依次调用 `git_index_add_all`、`git_index_update_all`、`git_index_write`，与第 2 节一致。冲突解决依赖 libgit2 在 `git_index_add_bypath` 里把冲突条目搬到 REUC，实测有效（冒烟测试的「解决冲突」一步通过）。

## 其它说明

- `native/build/`、`dist/` 都在 `.gitignore` 里，本次没有提交任何 `.so`。仓库只提交源码、脚本和 `assets/cacert.pem`。
- `native/build/run_android_smoke.sh` 是本地临时脚本，位于被忽略的 `native/build/` 下，没有提交。
- `tool/build_native.sh` 在 Git Bash 下验证通过（路径用 `cygpath -m` 转成 Windows 形式再交给 cmake），没有使用 Windows 专有命令；`--platform host` 只依赖 `cmake`、`ninja`、系统 `cc`。