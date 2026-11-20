#!/usr/bin/env python3
"""Reject a Dart binding that does not match the committed native libraries.

The check reads ``native_libs.lock.json``, the tracked binaries, the Dart API
version and the C header version. It fails when the lock, the binaries or the
bindings come from different native API revisions, or when a committed library
is stale or modified.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path, PurePosixPath
import re
import sys

from collect_artifacts import ArtifactError, digest, load_contract

PLATFORM_ABIS = {
    "android": ("arm64-v8a", "armeabi-v7a", "x86_64"),
    "ohos": ("arm64-v8a", "x86_64"),
}
LIBRARY_NAME = "libqfli_git.so"
FRAMEWORK_NAME = "qfli_git.xcframework"
CA_ASSET = "assets/cacert.pem"
VERSIONS_FILE = "third_party/versions.json"


def safe_relative(name: str) -> PurePosixPath:
    relative = PurePosixPath(name)
    if not name or relative.is_absolute() or ".." in relative.parts or "\\" in name:
        raise ArtifactError(f"Unsafe lock path: {name!r}")
    return relative


def full_commit(value: object) -> str:
    if not isinstance(value, str) or len(value) != 40:
        raise ArtifactError(f"Source commit is not a full SHA-1: {value!r}")
    if any(character not in "0123456789abcdef" for character in value.lower()):
        raise ArtifactError(f"Source commit is not hexadecimal: {value!r}")
    return value.lower()


def read_api_versions(repo_root: Path) -> tuple[int, int]:
    bindings = (repo_root / "lib/src/bindings.dart").read_text(encoding="utf-8")
    dart = re.search(r"const int qgApiVersion\s*=\s*(\d+)\s*;", bindings)
    if not dart:
        raise ArtifactError("lib/src/bindings.dart has no qgApiVersion constant")
    header = (repo_root / "native/include/qfli_git.h").read_text(encoding="utf-8")
    c_api = re.search(r"#define\s+QG_API_VERSION\s+(\d+)", header)
    if not c_api:
        raise ArtifactError("native/include/qfli_git.h has no QG_API_VERSION")
    return int(dart.group(1)), int(c_api.group(1))


def required_symbols_present(checks: object, required: list[str]) -> None:
    if not isinstance(checks, list) or not checks:
        raise ArtifactError("Lock has no exported-symbol checks")
    symbols = set()
    for check in checks:
        if check.get("kind") in ("elf", "macho"):
            exported = check.get("exportedSymbols")
            if not isinstance(exported, list):
                raise ArtifactError("Lock check has no exportedSymbols list")
            symbols.update(exported)
    missing = sorted(set(required) - symbols)
    if missing:
        raise ArtifactError(
            "Locked native checks lack required exports: " + ", ".join(missing)
        )


def check_files(repo_root: Path, lock: dict) -> set[str]:
    records = lock.get("files")
    if not isinstance(records, list) or not records:
        raise ArtifactError("native_libs.lock.json records no files")
    seen = set()
    for record in records:
        relative = safe_relative(record.get("path", ""))
        text = str(relative)
        if text in seen:
            raise ArtifactError(f"Duplicate lock path: {text}")
        seen.add(text)
        target = repo_root / relative
        if not target.is_file():
            raise ArtifactError(f"Locked library is missing: {text}")
        expected_bytes = record.get("bytes")
        if target.stat().st_size != expected_bytes:
            raise ArtifactError(
                f"{text} is {target.stat().st_size} bytes, lock says {expected_bytes}"
            )
        expected_sha = str(record.get("sha256", "")).lower()
        actual_sha = digest(target)
        if actual_sha != expected_sha:
            raise ArtifactError(
                f"{text} SHA-256 is {actual_sha}, lock says {expected_sha}"
            )
    return seen


def check_payload_paths(paths: set[str], checks: dict) -> None:
    required = set()
    for platform, abis in PLATFORM_ABIS.items():
        folder = "android/src/main/jniLibs" if platform == "android" else "ohos/libs"
        for abi in abis:
            required.add(f"{folder}/{abi}/{LIBRARY_NAME}")
    required.add(
        f"ios/Frameworks/{FRAMEWORK_NAME}/ios-arm64/qfli_git.framework/qfli_git"
    )
    required.add(
        "ios/Frameworks/"
        f"{FRAMEWORK_NAME}/ios-arm64_x86_64-simulator/"
        "qfli_git.framework/qfli_git"
    )
    missing = sorted(required - paths)
    if missing:
        raise ArtifactError("Lock misses native payloads: " + ", ".join(missing))
    for platform in ("android", "ohos", "ios"):
        if platform not in checks:
            raise ArtifactError(f"Lock has no symbol checks for {platform}")


def check_cacert(repo_root: Path) -> str:
    ca = repo_root / CA_ASSET
    if not ca.is_file() or ca.stat().st_size == 0:
        raise ArtifactError(f"Missing packaged CA bundle: {CA_ASSET}")
    actual = digest(ca)
    versions_path = repo_root / VERSIONS_FILE
    if versions_path.is_file():
        data = json.loads(versions_path.read_text(encoding="utf-8"))
        for asset in data.get("assets", []):
            if asset.get("name") == "cacert":
                expected = str(asset.get("sha256", "")).lower()
                if expected and actual != expected:
                    raise ArtifactError(
                        f"{CA_ASSET} SHA-256 is {actual}, versions.json says {expected}"
                    )
    return actual


def check(repo_root: Path, contract_path: Path) -> dict:
    contract = load_contract(contract_path)
    lock_path = repo_root / "native_libs.lock.json"
    if not lock_path.is_file():
        raise ArtifactError("native_libs.lock.json is missing")
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
    if lock.get("schemaVersion") != 2:
        raise ArtifactError(
            "native_libs.lock.json is not schema 2; import new cloud-built artifacts"
        )
    if lock.get("apiVersion") != contract["apiVersion"]:
        raise ArtifactError(
            f"Lock API version {lock.get('apiVersion')!r} does not match the "
            f"native contract {contract['apiVersion']!r}"
        )
    if lock.get("requiredExports") != contract["requiredExports"]:
        raise ArtifactError("Lock required exports do not match the native contract")
    if lock.get("contractSha256") != digest(contract_path):
        raise ArtifactError("Lock was written against a different native contract")
    source = lock.get("source")
    if not isinstance(source, dict):
        raise ArtifactError("Lock has no source block")
    commit = full_commit(source.get("commit"))
    commits = source.get("commits")
    if not isinstance(commits, dict) or not commits:
        raise ArtifactError("Lock has no per-platform source commits")
    for platform, value in commits.items():
        if full_commit(value) != commit:
            raise ArtifactError(
                f"{platform} artifacts came from {value}, expected {commit}"
            )
    if not (source.get("release") or source.get("run")):
        raise ArtifactError("Lock records neither a release nor a workflow run URL")
    checks = lock.get("checks")
    if not isinstance(checks, dict):
        raise ArtifactError("Lock has no platform checks")
    for platform in commits:
        required_symbols_present(checks.get(platform), contract["requiredExports"])
    paths = check_files(repo_root, lock)
    check_payload_paths(paths, checks)
    dart_api, c_api = read_api_versions(repo_root)
    if dart_api != contract["apiVersion"] or c_api != contract["apiVersion"]:
        raise ArtifactError(
            "Dart/header API versions "
            f"{dart_api}/{c_api} do not match the locked native API "
            f"{contract['apiVersion']}"
        )
    cacert = check_cacert(repo_root)
    return {
        "apiVersion": contract["apiVersion"],
        "commit": commit,
        "files": len(paths),
        "cacert": cacert,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument(
        "--contract",
        type=Path,
        help="defaults to <repo-root>/tool/ci/native_contract.json",
    )
    args = parser.parse_args(argv)
    repo_root = args.repo_root.resolve()
    contract_path = args.contract or repo_root / "tool/ci/native_contract.json"
    if not contract_path.is_absolute():
        contract_path = repo_root / contract_path
    try:
        facts = check(repo_root, contract_path)
    except (ArtifactError, OSError, json.JSONDecodeError) as error:
        print(f"check_native_install: {error}", file=sys.stderr)
        return 1
    print(
        "PASS qfli_git native API "
        f"{facts['apiVersion']} from {facts['commit']}, "
        f"{facts['files']} files, CA {facts['cacert']}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())