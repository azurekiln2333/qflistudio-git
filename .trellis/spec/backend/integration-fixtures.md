# Native Git integration fixtures

## Scope

Apply this contract to `example/integration_test/flow_test.dart` and mobile
runtime gates. The fixture uses disposable local repositories and needs no
network service or remote credential.

## URL contract

`GitRepository.clone` validates its URL before starting the native operation.
A bare absolute directory is rejected. Convert a local fixture directory with
`Uri.directory(path).toString()` so the fixture exercises supported `file://`
transport. Use the same representation for the local bare push remote. Do not
relax production URL validation to accommodate a test.

## Runtime evidence

Keep all clone, branch, conflict, merge-commit and push assertions. Emit bounded
phase markers around initialization, repository seeding and the flow. Markers
contain no credentials or user repository paths. A successful simulator build
does not prove that initialization or any assertion executed.

When local execution is forbidden, use format/static checks locally and execute
the unchanged assertions in cloud CI. Record the exact plugin commit, native
source commit and Flutter SDK. Preserve failed candidate tags.
