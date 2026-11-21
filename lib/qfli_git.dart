/// Local git operations for Flutter apps, backed by libgit2 and mbedTLS.
///
/// Call [QfliGit.ensureInitialized] once, then use [GitRepository]. Every
/// operation runs in a background isolate, so the UI thread keeps rendering.
library;

export 'src/bindings.dart'
    show
        NativeError,
        qgApiVersion,
        qgECanceled,
        qgEConflict,
        qgEInvalid,
        qgErrorMessageBytes,
        qgOidBufferBytes;
export 'src/repository.dart'
    show
        CancelToken,
        GitAuthor,
        GitBranch,
        GitCloneProgress,
        GitCloneStage,
        GitCommit,
        GitDiff,
        GitException,
        GitHead,
        GitRemote,
        GitRepository,
        GitStatusEntry,
        MergeOutcome,
        QfliGit,
        parseBranches,
        parseConflictPaths,
        parseDiff,
        parseHead,
        parseLog,
        parseRemotes,
        parseStatusEntries;
