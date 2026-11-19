# 第二轮修复报告：Pi A

范围：`native/src/qfli_git.c`、`native/include/qfli_git.h`、`native/test/smoke.c`。
对照报告：`.trellis/tasks/11-19-git-ci-validation/research/cross-check/c-checks-native.md`。

## 修复结果

### 高-1：自动合并后残留合并状态

- `qg_merge` 结果 2 的路径在返回前调用 `git_repository_state_cleanup`，失败走 `qg_error_libgit2`。
- `qg_merge_commit` 先检查 `git_repository_state()` 是否为 `GIT_REPOSITORY_STATE_MERGE`，不是就返回 `QG_EINVALID`。
- `git_repository_mergehead_foreach` 的 `GIT_ENOTFOUND` 映射成 `QG_EINVALID`，`heads.count == 0` 同样返回 `QG_EINVALID`。
- 提交 `07af0a4`。

### 中-2：`qg_status_json` 的逗号

- 用 `first` 标记代替 `index > 0`，跳过条目后不再生成非法 JSON。提交 `1deeb4a`。

### 中-3：`qg_conflicts_json` 的 `realloc`

- 先写临时变量 `grown`，判空后再赋给 `seen`，失败不丢原指针。提交 `d6571cf`。

### 中-4：凭据用户名

- 删除 `username_from_url` 分支，`username` 为 `NULL` 或空字符串时一律用 `"git"`，参数标注为未使用。提交 `755bdc1`。

### 中-5：`state` 词表

- `qg_state_token` 对 `GIT_REPOSITORY_STATE_NONE` 返回 `"clean"`，其他状态保持原词。
- `qfli_git.h` 的 `qg_head_json` 注释改为 `"state": "clean"` 并说明取值。提交 `4c8a0ca`。

### 低-6、低-7：`snprintf` 截断

- `qg_advance_branch` 检查符号引用名长度，超长返回 `QG_EINVALID`（`reference name is too long`）。提交 `2980d84`。
- `qg_merge` 的默认合并提交信息先拼串再判长度，超长返回 `QG_EINVALID`（`branch name is too long`）。提交 `6f81522`。

### 低-8、待确认 2：接口注释

- `qg_merge` 注释写明 `out_oid` 在各结果下的含义：0/1/3 为分支指向的提交，2 为新建的合并提交。
- `qg_merge_commit` 注释写明必须处于合并状态、否则返回 `QG_EINVALID`，最多支持 8 个 `MERGE_HEAD`。提交 `75a9777`。

### 冒烟测试

- 新增普通合并（结果 2）用例：建 `side` 分支提交，回主分支提交，合并后断言结果为 2、`state` 为 `clean`、`qg_merge_commit` 返回 `QG_EINVALID`。
- 首次提交后断言干净仓库的 `state` 为 `clean`。
- 冲突合并完成后的断言由 `none` 改为 `clean`。
- 顺带修正测试自身的两个缺陷：`file` 缓冲被新用例复用导致快进用例写错文件；`test_local` 把合并结果当返回值，失败时仍打印 PASS。提交 `66bef01`。

## 验证

本机编 Android arm64-v8a，用 `native/build/run_android_smoke.sh` 在真机 `FA6CP0302212` 上跑冒烟测试。该脚本与 `native/build/` 均在 `.gitignore` 内，不提交。

构建（节选）：

```
[220/222] Linking C static library libgit2\libgit2.a
[221/222] Linking C shared library ..\smoke-out\libqfli_git.so
[222/222] Linking C executable ..\smoke-out\qfli_git_smoke
```

设备输出（节选，全部通过）：

```
qfli_git smoke test
     qg_api_version     1
     libgit2            1.9.7
     mbedtls            3.6.8
     ca file            /data/local/tmp/cacert.pem
ok   qg_init(ca_file, &err)
     branch is master
ok   head reports a clean repository
ok   head reports an open merge
ok   merge commit refuses open conflicts
ok   head reports no merge after the merge commit
ok   head points at the merge commit
ok   merge creates a merge commit
ok   head reports clean after an automatic merge
ok   merge commit refuses a finished merge
ok   merge fast-forwards
ok   merging the current branch is a no-op
ok   cloned content matches
ok   cloned head matches the pushed fast-forward commit
ok   https clone
ok   https head is 49322bb17d3acc9146f98c97d078513228bbf3c0
PASS
exit=0
```

`git status --short` 无输出。9 个修复提交加本报告。

## 未完成项

- 无。

## 接口问题

- 无。行为与 `design.md` 第 2 节一致，`state` 词表只补了 `"clean"`。