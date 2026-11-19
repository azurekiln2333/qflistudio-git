#!/usr/bin/env python3
"""Verify built native artifacts and copy them into the plugin platform folders."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile

REPOSITORY = "azurekiln2333/qflistudio-git"
RELEASE_API = f"https://api.github.com/repos/{REPOSITORY}/releases/tags"
LIBRARY_NAME = "libqfli_git.so"
FRAMEWORK_NAME = "qfli_git.xcframework"
PLATFORM_ORDER = ("android", "ohos", "ios")


class ArtifactError(RuntimeError):
    """Raised when an artifact fails verification or cannot be placed."""


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def safe_relative(name: str) -> PurePosixPath:
    relative = PurePosixPath(name)
    if not name or relative.is_absolute() or ".." in relative.parts or "\\" in name:
        raise ArtifactError(f"Unsafe manifest path: {name!r}")
    return relative


def load_manifest(artifact: Path) -> dict:
    path = artifact / "manifest.json"
    if not path.is_file():
        raise ArtifactError(f"Missing manifest.json in {artifact}")
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise ArtifactError(f"Cannot parse {path}: {error}") from error
    platform = manifest.get("platform")
    if platform not in PLATFORM_ORDER:
        raise ArtifactError(f"Unsupported platform in {path}: {platform!r}")
    if not isinstance(manifest.get("files"), list) or not manifest["files"]:
        raise ArtifactError(f"No files recorded in {path}")
    if not isinstance(manifest.get("commit"), str) or not manifest["commit"]:
        raise ArtifactError(f"Missing source commit in {path}")
    return manifest


def verify_manifest(artifact: Path, manifest: dict) -> list[dict]:
    """Check every recorded file against its size and SHA-256, return the records."""
    verified = []
    for record in manifest["files"]:
        try:
            relative = safe_relative(record["path"])
            expected_bytes = int(record["bytes"])
            expected_sha = str(record["sha256"]).lower()
        except (KeyError, TypeError, ValueError) as error:
            raise ArtifactError(f"Malformed file record in manifest: {record!r}") from error
        source = artifact / relative
        if not source.is_file():
            raise ArtifactError(f"Missing artifact file: {source}")
        actual_bytes = source.stat().st_size
        if actual_bytes != expected_bytes:
            raise ArtifactError(f"Size mismatch for {relative}: {actual_bytes} != {expected_bytes}")
        actual_sha = digest(source)
        if actual_sha != expected_sha:
            raise ArtifactError(f"SHA-256 mismatch for {relative}: {actual_sha} != {expected_sha}")
        verified.append({**record, "path": str(relative), "sha256": actual_sha})
    return verified


def is_payload(platform: str, record: dict) -> bool:
    """Return True for the file records that belong in a plugin platform folder."""
    relative = safe_relative(record["path"])
    if platform in ("android", "ohos"):
        return relative.name.startswith("lib") and relative.suffix == ".so"
    if platform == "ios":
        return relative.parts[0] == FRAMEWORK_NAME
    return False


def destination_for(platform: str, repo_root: Path, record: dict) -> Path:
    """Map one manifest record to its final path inside the plugin."""
    relative = safe_relative(record["path"])
    if platform == "android":
        abi = record.get("abi")
        if not abi:
            raise ArtifactError(f"Android artifact needs an abi: {relative}")
        return repo_root / "android/src/main/jniLibs" / abi / relative.name
    if platform == "ohos":
        abi = record.get("abi")
        if not abi:
            raise ArtifactError(f"OHOS artifact needs an abi: {relative}")
        return repo_root / "ohos/libs" / abi / relative.name
    if platform == "ios":
        return repo_root / "ios/Frameworks" / relative
    raise ArtifactError(f"Unsupported platform: {platform}")


def import_artifact(artifact: Path, repo_root: Path, commit_filter: str | None = None) -> dict:
    """Verify one artifact directory and copy its libraries into the plugin."""
    manifest = load_manifest(artifact)
    platform = manifest["platform"]
    if commit_filter and manifest["commit"] != commit_filter:
        raise ArtifactError(
            f"Artifact commit {manifest['commit']} does not match expected {commit_filter}"
        )
    verified = verify_manifest(artifact, manifest)
    payload = [record for record in verified if is_payload(platform, record)]
    if not payload:
        raise ArtifactError(f"No library payload in {artifact} for {platform}")
    targets = [
        (artifact, record, destination_for(platform, repo_root, record))
        for record in payload
    ]
    if platform == "ios":
        # Replace the previous xcframework as a unit so stale slices never linger.
        framework = repo_root / "ios/Frameworks" / FRAMEWORK_NAME
        if framework.exists():
            shutil.rmtree(framework)
    copied = []
    for source_dir, record, target in targets:
        source = source_dir / record["path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        copied.append(
            {
                "path": target.relative_to(repo_root).as_posix(),
                "platform": platform,
                "abi": record.get("abi"),
                "bytes": target.stat().st_size,
                "sha256": digest(target),
            }
        )
    return {
        "platform": platform,
        "commit": manifest["commit"],
        "upstream": manifest.get("upstream", {}),
        "abis": manifest.get("abis", []),
        "files": copied,
    }


def release_assets(tag: str, platforms: list[str], token: str | None) -> dict[str, str]:
    """Return download URLs for the platform zips of one release tag."""
    request = urllib.request.Request(
        f"{RELEASE_API}/{tag}",
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "qfli-git-import-artifacts",
            **({"Authorization": f"Bearer {token}"} if token else {}),
        },
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        release = json.load(response)
    urls = {}
    for asset in release.get("assets", []):
        name = asset.get("name", "")
        for platform in platforms:
            if name.startswith(f"qfli-git-{platform}-") and name.endswith(".zip"):
                urls[platform] = asset["browser_download_url"]
    missing = [platform for platform in platforms if platform not in urls]
    if missing:
        raise ArtifactError(f"Release {tag} has no artifact zip for: {', '.join(missing)}")
    return urls


def download(url: str, target: Path) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": "qfli-git-import-artifacts"})
    with urllib.request.urlopen(request, timeout=600) as response, target.open("wb") as stream:
        shutil.copyfileobj(response, stream)


def extract_zip(archive: Path, destination: Path) -> None:
    with zipfile.ZipFile(archive) as bundle:
        for member in bundle.infolist():
            safe_relative(member.filename.rstrip("/"))
        bundle.extractall(destination)


def import_release(tag: str, repo_root: Path, platforms: list[str], token: str | None) -> list[dict]:
    results = []
    with tempfile.TemporaryDirectory(prefix="qfli-git-release-") as work:
        workdir = Path(work)
        for platform, url in release_assets(tag, platforms, token).items():
            archive = workdir / f"{platform}.zip"
            download(url, archive)
            extracted = workdir / platform
            extracted.mkdir()
            extract_zip(archive, extracted)
            results.append(import_artifact(extracted, repo_root))
    return results


def write_lock(repo_root: Path, results: list[dict], tag: str | None) -> Path:
    lock = {
        "schemaVersion": 1,
        "source": {
            "repository": f"https://github.com/{REPOSITORY}",
            "release": tag,
            "commits": {result["platform"]: result["commit"] for result in results},
            "upstream": {result["platform"]: result["upstream"] for result in results},
        },
        "files": sorted(
            (entry for result in results for entry in result["files"]),
            key=lambda entry: entry["path"],
        ),
    }
    path = repo_root / "native_libs.lock.json"
    path.write_text(json.dumps(lock, indent=2) + "\n", encoding="utf-8")
    return path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--artifact", type=Path, action="append", help="local artifact directory")
    source.add_argument("--release", help="GitHub release tag to download artifacts from")
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument(
        "--platform",
        action="append",
        choices=PLATFORM_ORDER,
        help="limit a release import to these platforms",
    )
    parser.add_argument("--commit", help="require this source commit in every manifest")
    args = parser.parse_args(argv)
    repo_root = args.repo_root.resolve()
    try:
        if args.release:
            platforms = args.platform or list(PLATFORM_ORDER)
            results = import_release(
                args.release, repo_root, platforms, common_token()
            )
        else:
            results = [
                import_artifact(artifact.resolve(), repo_root, args.commit)
                for artifact in args.artifact
            ]
        lock = write_lock(repo_root, results, args.release)
    except (ArtifactError, OSError, urllib.error.URLError, zipfile.BadZipFile) as error:
        print(f"import_artifacts: {error}", file=sys.stderr)
        return 1
    for result in results:
        print(f"{result['platform']}: {len(result['files'])} files from {result['commit'][:12]}")
    print(f"lock: {lock}")
    return 0


def common_token() -> str | None:
    import os

    return os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")


if __name__ == "__main__":
    sys.exit(main())
