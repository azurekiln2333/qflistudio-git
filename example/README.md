# qfli_git example

Demonstrates the `qfli_git` plugin on Android, iOS and HarmonyOS.

## Run

The plugin's native libraries are not built by this project. Import the CI
artifacts with `tool/import_artifacts.py` first, then:

```sh
flutter pub get
flutter run -d <device>
```

The plugin needs a writable application support directory for the bundled CA
bundle, which `QfliGit.ensureInitialized` creates on first use.

## Screen

- `Remote HTTPS URL`: repository to clone and push to. Userinfo in the URL
  (`https://user:token@host/repo.git`) is removed before the clone, because
  libgit2 writes the URL into `.git/config`. Put the token in the Token field.
- `Username` and `Token`: optional credentials. The token stays in memory and
  is never written to disk or to a log. It is only passed to the native layer
  while a call is running.
- `Merge branch name`: the branch created for the conflicting change.
- `Author name` and `Author email`: identity used for every commit.
- `全流程`: runs clone, base commit, branch, conflicting commit, merge, conflict
  listing, resolution, merge commit and push. Each step shows its result,
  duration and error text. A step stopped by `取消` shows as `已取消`.
- `取消`: cancels the running clone or push. The flow stops with `Flow canceled.`

Every run replaces the work tree in `<app support>/flow_repo`. The previous
run is kept as `<app support>/flow_repo.previous` so a failure can be inspected
afterwards. The clone step shows `host/path` of the remote, never credentials.

The header shows `QfliGit.libgit2Version`, which also proves the native library
was found.

## Tests

```sh
flutter test                        # widget tests, no device needed
flutter test integration_test       # needs a device with the native library
```

`integration_test/flow_test.dart` never touches the network. It seeds a local
repository, clones it, cuts the feature branch before the main branch commit,
merges with a conflict, resolves it, creates the merge commit and pushes into a
local bare repository.