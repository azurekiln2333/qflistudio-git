# 交叉检查（第二轮）：native/ C 实现

检查者 Pi C，worktree `xc-c`，分支 `xc/pi-c`。检查对象 `native/src/qfli_git.c`、`native/include/qfli_git.h`、`native/test/smoke.c`、`native/exports.map`。对照 `design.md` 第 2 节。没有修改检查对象。

行号以本 worktree 的 `native/src/qfli_git.c` 为准。libgit2 行为对照了 `pi-a/native/build/src/libgit2` 的 1.9.7 源码（只读）。

## 高

### 1. `qg_merge` 自动生成合并提交后残留合并状态，后续 `qg_merge_commit` 会基于旧 MERGE_HEAD 生成重复合并

- 位置：`native/src/qfli_git.c:887-929`（`git_merge` 成功、无冲突分支，`*out_result = 2` 在 926 行返回）。
- 问题：`git_merge` 成功时已经写了 `MERGE_HEAD`、`MERGE_MODE`、`MERGE_MSG`（libgit2 `git_merge` 调 `git_merge__setup`，见 pi-a worktree 的 `native/build/src/libgit2/src/libgit2/merge.c:2843-2863`）。这条路径直接建提交返回，没有调用 `git_repository_state_cleanup`。只有 `qg_merge_commit`（1034 行）清理。
- 为什么是问题：
  1. `git_repository_state()` 仍然报 `merge`，`qg_head_json` 的 `state` 返回 `"merge"`，调用方看到仓库卡在合并中。
  2. `qg_merge_commit` 只用 `git_repository_mergehead_foreach` 判断「有没有合并在进行」（975-980 行），残留的 `MERGE_HEAD` 让它通过。如果调用方在这次 `qg_merge`（结果 2）之后又调 `qg_merge_commit`，会生成 `HEAD + 旧 MERGE_HEAD` 的第二个合并提交，两父提交顺序错误（旧 MERGE_HEAD 变成第一父）。
  3. 冒烟测试没覆盖这条路径：`smoke.c` 的 fast-forward 用例走结果 1，冲突用例走结果 3，`interesting` 的普通合并（结果 2）没有断言 `state` 为干净。
- 建议：在 928 行前（`*out_result = 2` 之后、`return 0` 之前）调用 `git_repository_state_cleanup(repo->repo)`，失败就走 `qg_error_libgit2`。同时让 `qg_merge_commit` 除了 `MERGE_HEAD` 还检查 `git_repository_state()` 是否为 `GIT_REPOSITORY_STATE_MERGE`。
- 严重程度：高。

## 中

### 2. `qg_status_json` 用循环下标判断逗号，跳过条目后可能生成非法 JSON

- 位置：`native/src/qfli_git.c:1232`（`if (index > 0 && qg_buffer_append(&buffer, ",") < 0)`）。
- 问题：`index` 是 `git_status_list` 的下标，不是已输出条目数。1223-1230 行在 `entry == NULL` 或 `path == NULL` 时 `continue`，这两种情况下 `index` 继续加一，于是下一条正常条目会在 `[` 后面直接追加 `,`，产出 `[,{...}]`。同样，若中间某条目被跳过，两条正常条目之间也不会补逗号，产出 `{...}{...}`。
- 为什么是问题：Dart 侧 `parseStatusEntries` 直接 `jsonDecode`，非法 JSON 抛 `FormatException`，`status()` 变成不可诊断的 Dart 异常而不是 `GitException`。`design.md` 第 2 节要求输出合法 JSON 数组。
- 建议：改用 `first` 标记（脚本已在 `qg_conflicts_json` 里用同样写法），或把逗号并入 1239 行的追加链。
- 严重程度：中。

### 3. `qg_conflicts_json` 的 `realloc` 直接覆盖原指针，失败时泄漏原缓冲

- 位置：`native/src/qfli_git.c:1123-1128`（`seen = realloc(seen, ...)`，紧接着 `if (seen == NULL) goto done;`）。
- 问题：`realloc` 失败返回 NULL，原来的 `seen` 指针丢失，`done:` 处的 `free(seen)` 释放的是 NULL，已分配的那块泄漏。`seen[seen_count++] = path` 会因为先 `goto done` 而跳过，所以不会崩溃，但泄漏是确定的。
- 为什么是问题：这是本文件唯一一处没有走 `qg_buffer` 的手写分配，与其他部分的「失败即释放」风格不一致；冲突很多时才会触发，属于低频但真实的泄漏路径。
- 建议：引入临时变量 `grown = realloc(...)`，判空后再赋给 `seen`。
- 严重程度：中（低频路径上的确定性泄漏）。

### 4. 凭据回调用 `username_from_url` 覆盖用户名，与 `design.md` 第 2 节的「username 为 NULL 时用 git」不一致

- 位置：`native/src/qfli_git.c:245-249`。
- 问题：调用方传 `username = NULL` 且 URL 里带用户名（`https://user@host/repo.git`）时，实际用的是 URL 里的用户名；`design.md` 第 2 节要求 `username` 为 NULL 时用 `"git"`。
- 为什么是问题：GitHub、Gitee 的令牌认证接受任意用户名，实际影响小。但约定是接口契约，且 Dart 侧 `username` 与 `token` 是成对参数，行为不一致会让「同一 token 换 username 得到不同结果」的排查变难。
- 建议：删掉 `username_from_url` 分支，`username` 为空一律用 `"git"`；或者承认新行为并更新 `design.md` 第 2 节。
- 严重程度：中（契约偏差，实际影响低）。

### 5. `qg_head_json` 的 `state` 词表是 `none`，example 集成测试期望 `clean`

- 位置：`native/src/qfli_git.c:1265-1293`（`qg_state_token` 默认返回 `"none"`）、`native/include/qfli_git.h:93` 的注释、对照 `example/integration_test/flow_test.dart:55` 与 `:98`（`expect(baseHead.state, 'clean')`）。
- 问题：集成测试第一次 `head()` 就会失败。若第 1 条问题没修，第 98 行的 `'clean'` 也会失败（此时实际是 `"merge"`）。
- 为什么是问题：跨层词表没有在 `design.md` 里约定，Pi A 选 `none`，Pi B 按 `clean` 断言。这是集成后的真实失败，不是风格问题。
- 建议：二选一，由大脑裁定后写进 `qfli_git.h` 注释：C 侧把默认值改成 `"clean"`，或 example 改成 `'none'`。前者不需要改 Dart 绑定。
- 严重程度：中。

## 低

### 6. `qg_advance_branch` 里 `snprintf` 静默截断分支引用名

- 位置：`native/src/qfli_git.c:782`（`snprintf(refname, sizeof(refname), "%s", symbolic)`，`refname[1024]`）。
- 问题：符号引用名超过 1023 字节时被截断，随后 `git_reference_create` 会拿截断后的名字建引用，报的错误指向「无效引用名」，看不出是截断造成的。
- 建议：检查 `snprintf` 返回值，`>= sizeof(refname)` 时用 `qg_error_string(err, -1, "reference name is too long")` 提前失败。
- 严重程度：低。

### 7. 自造合并提交信息被固定 512 字节缓冲截断

- 位置：`native/src/qfli_git.c:908`、`916`（`snprintf(message, sizeof(message), "Merge branch '%s'", branch)`）。
- 问题：分支名超过约 495 字节时提交信息被截断。`qg_commit` / `qg_merge_commit` 的调用方信息不受影响。
- 建议：改用 `qg_buffer` 拼串，或按分支名长度校验后返回 `QG_EINVALID`。
- 严重程度：低。

### 8. `qg_merge_commit` 的 8 父上限只存在于代码里，接口没写

- 位置：`native/src/qfli_git.c:961-962`（`git_commit *parents[9]`、`commit_parents[9]`）、`936`（`git_oid items[8]`）、`945-948`（满 8 个置 `overflow`）。
- 问题：上限是 1 个 `HEAD` 加 8 个 `MERGE_HEAD`，`qfli_git.h` 与 `design.md` 都没写。超出时返回 `QG_EINVALID`（「too many merge heads」），调用方只能从错误文本看出原因。本接口只做单分支合并，实际不会触发。
- 建议：在 `qfli_git.h` 的 `qg_merge_commit` 注释里补一句「最多支持 8 个 MERGE_HEAD」，或把上限提到 32 并加 `GIT_ASSERT`。
- 严重程度：低（文档缺失）。

## 已确认无问题

- **接口一致性**：`qfli_git.h` 的 21 个函数名、参数顺序、`char out_oid[41]`、`const int32_t *cancel_flag` 与 `design.md` 第 2 节逐项一致。`QG_ECANCELED`/`QG_ECONFLICT`/`QG_EINVALID` 的值、`qg_error` 的 `int/int/char[512]` 布局一致。`exports.map` 只导出 `qg_*`。
- **失败路径填写 `qg_error`**：`qg_repo_init`、`qg_repo_open`、`qg_clone`、`qg_fetch`、`qg_push`、`qg_add_all`、`qg_commit`、`qg_branch_create`、`qg_checkout_branch`、`qg_merge`、`qg_merge_commit`、`qg_conflicts_json`、`qg_status_json`、`qg_head_json` 的每条 `return` 都经过 `qg_error_libgit2` / `qg_error_string` / `qg_invalid` / `qg_result`。唯一的例外是 `qg_shutdown`，接口里它没有 `qg_error` 参数，返回 `QG_EINVALID` 符合设计。指针参数为 NULL 的入口都有 `qg_invalid` 检查。
- **取消语义**：`qg_result`（67-76 行）在失败且 `cancel_flag` 非 0 时统一映射成 `QG_ECANCELED`，覆盖 `git_remote_fetch`、`git_remote_push`、`git_clone` 的取消。`transfer_progress` 与 `push_transfer_progress` 回调都检查 `cancel_flag`，凭据回调也检查。`qg_canceled` 用 `volatile` 读，跨线程可见性够用。`NULL` 取消标志不会解引用。
- **凭据回调第二次进入**：`cb->attempts++ > 0` 返回 `GIT_EAUTH`（238-239 行），与设计一致。`token` 为 NULL 或空时也返回 `GIT_EAUTH`，不会死循环。令牌只作为参数传给 `git_credential_userpass_plaintext_new`，不进 `qg_error.message`，不发日志。
- **`qg_merge` 四种结果**：
  - 情况 0（`GIT_MERGE_ANALYSIS_UP_TO_DATE`）：`*out_result = 0`，不回写 oid 之外的状态，不动工作区。
  - 情况 1（`FASTFORWARD`，含 `UNBORN`）：`qg_advance_branch` 先 `GIT_CHECKOUT_SAFE` 检出，再把符号引用前移；detached HEAD 走 `git_repository_set_head_detached`。
  - 情况 2（普通合并、无冲突）：生成合并提交并在 `HEAD` 上创建，见第 1 条问题（缺状态清理）。
  - 情况 3（有冲突）：`git_merge` 已写索引与工作区冲突，`qg_index_has_conflict` 判定后再写一次 `MERGE_HEAD`（冗余但幂等），`*out_result = 3` 并返回 0，符合设计。
  - 分支名不存在时先 `git_branch_lookup` 失败，再 `git_revparse_single` 兜底，两次都走 `qg_error_libgit2`。
- **`qg_merge_commit` 冲突返回 `QG_ECONFLICT`**：985-990 行先 `git_index_has_conflict`，有冲突时 `qg_error_string(err, QG_ECONFLICT, ...)` 并返回该码。冒烟测试 `smoke.c` 的「merge commit refuses open conflicts」断言通过。
- **对象释放**：逐个函数核对了 libgit2 对象。`qg_repo_wrap` 在 `calloc` 失败时 `git_repository_free`；`qg_fetch`/`qg_push` 每条路径都 `git_remote_free`；`qg_index_tree` 只返回已查到的 tree；`qg_write_commit` 的成功与失败路径都释放 `index`、`tree`、`head`、`parent`、`signature`；`qg_branch_create` 释放 `object`、`target`、`reference`、`head`；`qg_checkout_branch` 释放 `reference`、`target`；`qg_merge` 每条 `return` 都 `git_annotated_commit_free(theirs)`，`commit` 与 `target` 也都配对释放；`qg_merge_commit` 的 `done:` 统一释放 `signature`、`parents[0..parent_count)`、`tree`；`qg_conflicts_json` 的 `done:` 释放迭代器、索引、缓冲；`qg_status_json` 释放 `list` 与缓冲；`qg_head_json` 释放 `head`/`symbolic` 与缓冲。没有发现确定性泄漏，唯一的泄漏在第 3 条。
- **字符串所有权**：`qg_*_json` 的输出都来自 `qg_buffer_release` 的 `malloc`，空数组也会先追加 `[` 和 `]`，所以 `*out_json` 总是可释放的非空指针，`qg_string_free` 用 `free`，与设计一致。失败时 `*out_json` 保持 NULL。
- **冒烟测试覆盖面**：`smoke.c` 的本地流程覆盖 clone → commit → push → 分支 → 冲突合并 → 冲突列表 → 拒绝提前提交 → 解决 → 合并提交 → push → 重新 clone 校验，另加 `head_json` 的 `branch`/`oid`/`state` 断言与匿名 HTTPS clone，符合 `design.md` 第 4 节。缺口是普通合并（结果 2）与取消路径没有断言，见第 1 条。
- **`qg_init`/`qg_shutdown`**：`qg_init` 可重复调用（`git_libgit2_init` 引用计数），设置 CA 文件失败时回退一次 `shutdown` 再返回错误，行为合理。

## 待确认

1. **`qg_merge_commit` 在没有合并在进行时的错误码**：`git_repository_mergehead_foreach` 读不到 `MERGE_HEAD` 时返回 `GIT_ENOTFOUND`，函数在 975-977 行直接把它交给 `qg_error_libgit2`，所以 979-980 行的 `heads.count == 0` → `QG_EINVALID` 分支实际不可达。`design.md` 没规定这种情况的错误码。如果希望 Dart 侧能明确区分「没有合并」和「文件读失败」，需要把 `GIT_ENOTFOUND` 映射成 `QG_EINVALID`，并同步 `qfli_git.h` 注释。
2. **`qg_merge` 结果 3 的 `out_oid` 语义**：现在填的是对方提交的 oid（`target_id`）。`design.md` 只写了 `char out_oid[41]`，没说结果 3 时它是什么。Dart 侧（`lib/src/repository.dart` 的 `merge`）在结果 3 时忽略这个值，所以当前无影响。建议在 `qfli_git.h` 注释里写清楚「结果 0/1/3 为对方提交，结果 2 为新建的合并提交」。
3. **`qg_merge` 快进前的安全检查**：`qg_advance_branch` 用 `GIT_CHECKOUT_SAFE`，工作区有冲突改动时 `git_checkout_tree` 会失败，语义正确。但「分支引用前移」发生在检出成功之后，若检出成功而 `git_reference_create` 失败，工作区已到目标提交而分支引用没动，仓库处于半更新状态。libgit2 没有事务接口，这一条只能靠注释说明，不当作缺陷。
4. **`git_index_has_conflicts` 返回负数的可能**：`qg_index_has_conflict` 把负返回值也当错误处理（`qg_error_libgit2`），实现正确。但 1.9.7 的该函数实际只返回 0/1，负分支不可达，属于防御性代码，不算问题。
5. **`qg_write_merge_head` 用 `fopen(path, "w")`**：`repo->gitdir` 在 Windows 上是 UTF-8 路径，`fopen` 在 Windows 需要 ANSI 路径。本接口只在 Android、鸿蒙、iOS、Linux 主机上跑，Windows 主机测试只有 MSVC 场景才受影响，冒烟测试在 CI 的 ubuntu/macos 上跑，暂不作为问题。若以后要在 Windows 上跑 `smoke.c`，需要改成 `_wfopen` 或 `git_futils_writebuffer`。
