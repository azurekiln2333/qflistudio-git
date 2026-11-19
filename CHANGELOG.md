## 0.1.0

* 首次发布：libgit2 与 mbedTLS 的 Dart FFI 绑定，覆盖克隆、提交、分支、三方合并、冲突处理与推送。
* Android、iOS、OpenHarmony 三个 `ffiPlugin` 平台，使用预编译库。
* 后台 isolate 执行全部 git 操作，网络操作支持 `CancelToken` 取消。
* 自带 Mozilla CA 根证书包，由 `QfliGit.ensureInitialized` 复制到应用支持目录。
