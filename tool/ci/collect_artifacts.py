#!/usr/bin/env python3
"""Collect native build outputs into a release artifact with manifest and checks."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import zipfile

LIBRARY_NAME = "libqfli_git.so"
HEADER_NAME = "qfli_git.h"
FRAMEWORK_NAME = "qfli_git.xcframework"
PAGE_ALIGNMENT = 0x4000
EXPORT_PREFIX = "qg_"
PLATFORM_ABIS = {
    "android": ("arm64-v8a", "armeabi-v7a", "x86_64"),
    "ohos": ("arm64-v8a", "x86_64"),
}
ELF_PLATFORMS = ("android", "ohos")
LICENSE_CANDIDATES = (
    ("PROJECT-LICENSE", ("LICENSE", "LICENSE.md")),
    ("LIBGIT2-LICENSE", ("third_party/licenses/libgit2.txt", "third_party/licenses/LIBGIT2-LICENSE")),
    ("MBEDTLS-LICENSE", ("third_party/licenses/mbedtls.txt", "third_party/licenses/MBEDTLS-LICENSE")),
    ("CACERT-LICENSE", ("third_party/licenses/cacert.txt", "third_party/licenses/CACERT-LICENSE")),
)


class ArtifactError(RuntimeError):
    """Raised when a build output is missing or fails a release check."""


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def tool_output(command: list[str]) -> str:
    try:
        return subprocess.run(
            command, check=True, capture_output=True, text=True
        ).stdout
    except FileNotFoundError as error:
        raise ArtifactError(f"Missing tool: {command[0]}") from error
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or error.stdout or "").strip()
        raise ArtifactError(f"{' '.join(command)} failed: {detail}") from error


def parse_load_alignments(readelf_output: str) -> list[int]:
    """Return the p_align value of every PT_LOAD program header."""
    alignments = []
    for line in readelf_output.splitlines():
        fields = line.split()
        if fields and fields[0] == "LOAD":
            try:
                alignments.append(int(fields[-1], 16))
            except ValueError as error:
                raise ArtifactError(f"Cannot parse LOAD alignment: {line.strip()}") from error
    return alignments


def check_alignment(alignments: list[int], expected: int = PAGE_ALIGNMENT) -> None:
    if not alignments:
        raise ArtifactError("No LOAD program header found")
    bad = [hex(value) for value in alignments if value < expected or value % expected]
    if bad:
        raise ArtifactError(f"LOAD segments not aligned to {hex(expected)}: {bad}")


def parse_defined_symbols(nm_output: str) -> list[str]:
    """Return defined dynamic symbol names, skipping linker internal names."""
    symbols = []
    for line in nm_output.splitlines():
        fields = line.split()
        if not fields:
            continue
        name = fields[-1]
        if name.startswith("_"):
            continue
        # Absolute entries hold the version node names of a named version script.
        if len(fields) >= 3 and len(fields[-2]) == 1 and fields[-2] == "A":
            continue
        symbols.append(name)
    return symbols


def check_exports(symbols: list[str], prefix: str = EXPORT_PREFIX) -> None:
    if not symbols:
        raise ArtifactError("No exported symbol found")
    unexpected = sorted({name for name in symbols if not name.startswith(prefix)})
    if unexpected:
        raise ArtifactError(f"Symbols without the {prefix} prefix: {unexpected[:20]}")


def inspect_elf(library: Path, abi: str, readelf: str, nm: str) -> dict:
    alignments = parse_load_alignments(tool_output([readelf, "-lW", str(library)]))
    check_alignment(alignments)
    symbols = parse_defined_symbols(
        tool_output([nm, "-D", "--defined-only", str(library)])
    )
    check_exports(symbols)
    return {
        "abi": abi,
        "kind": "elf",
        "pageAlignment": PAGE_ALIGNMENT,
        "loadAlignments": alignments,
        "exportedSymbols": sorted(symbols),
    }


def parse_library(spec: str) -> tuple[str, Path]:
    abi, separator, directory = spec.partition("=")
    if not separator or not abi or not directory:
        raise ArtifactError(f"Expected abi=directory, got {spec!r}")
    return abi, Path(directory)


def load_upstream_versions(path: Path) -> dict:
    """Read third_party/versions.json and flatten it to name -> version."""
    if not path.is_file():
        raise ArtifactError(f"Missing upstream version file: {path}")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise ArtifactError(f"Cannot parse {path}: {error}") from error
    versions = {}
    if isinstance(data, dict) and (
        isinstance(data.get("sources"), list) or isinstance(data.get("assets"), list)
    ):
        # Schema written for tool/fetch_sources.py: {"sources": [...], "assets": [...]}.
        data = list(data.get("sources") or []) + list(data.get("assets") or [])
    entries = data.items() if isinstance(data, dict) else (
        (entry.get("name"), entry) for entry in data
    )
    for name, value in entries:
        if not name:
            continue
        if isinstance(value, str):
            versions[str(name)] = value
        elif isinstance(value, dict):
            versions[str(value.get("name") or name)] = str(
                value.get("version") or value.get("tag") or "unknown"
            )
    if not versions:
        raise ArtifactError(f"No upstream version recorded in {path}")
    return versions


def copy_file(source: Path, out: Path, relative: str, abi: str | None) -> dict:
    target = out / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    return {
        "path": relative,
        "abi": abi,
        "bytes": target.stat().st_size,
        "sha256": digest(target),
    }


def zip_size(data: bytes, name: str) -> int:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as bundle:
        bundle.writestr(name, data)
    with zipfile.ZipFile(buffer) as bundle:
        return bundle.getinfo(name).compress_size


def add_zip_sizes(out: Path, records: list[dict]) -> None:
    for record in records:
        record["zipBytes"] = zip_size(
            (out / record["path"]).read_bytes(), Path(record["path"]).name
        )


def collect_licenses(
    repo_root: Path, out: Path, overrides: list[str], records: list[dict]
) -> list[str]:
    copied = []
    selected: dict[str, Path] = {}
    for spec in overrides:
        path_text, _, name = spec.partition("=")
        source = Path(path_text)
        target_name = name or source.name
        if not source.is_file():
            raise ArtifactError(f"Missing license file: {source}")
        selected[target_name] = source
    for name, candidates in LICENSE_CANDIDATES:
        if name in selected:
            continue
        for candidate in candidates:
            source = repo_root / candidate
            if source.is_file():
                selected[name] = source
                break
    licenses_dir = repo_root / "third_party/licenses"
    if licenses_dir.is_dir():
        for source in sorted(licenses_dir.iterdir()):
            if source.is_file() and source.name not in selected:
                selected[f"UPSTREAM-{source.name}"] = source
    for name, source in sorted(selected.items()):
        relative = f"licenses/{name}"
        records.append(copy_file(source, out, relative, None))
        copied.append(relative)
    return copied


def collect(args: argparse.Namespace) -> dict:
    out: Path = args.out
    if out.exists() and any(out.iterdir()):
        raise ArtifactError(f"Artifact directory must be empty: {out}")
    if args.platform in ELF_PLATFORMS:
        if not args.library:
            raise ArtifactError(f"{args.platform} needs at least one --library abi=directory")
        if not args.readelf or not args.nm:
            raise ArtifactError(f"{args.platform} needs --readelf and --nm")
        expected = PLATFORM_ABIS[args.platform]
        abis = [parse_library(spec)[0] for spec in args.library]
        if sorted(abis) != sorted(expected):
            raise ArtifactError(
                f"{args.platform} needs exactly these ABIs: {', '.join(expected)}"
            )
    elif args.platform == "ios":
        if not args.xcframework:
            raise ArtifactError("ios needs --xcframework")
        if not (args.xcframework / "Info.plist").is_file():
            raise ArtifactError(f"Not an xcframework: {args.xcframework}")
    else:
        raise ArtifactError(f"Unsupported platform: {args.platform}")

    out.mkdir(parents=True, exist_ok=True)
    records: list[dict] = []
    checks: list[dict] = []
    abis: list[str] = []
    if args.platform in ELF_PLATFORMS:
        for spec in args.library:
            abi, directory = parse_library(spec)
            library = directory / LIBRARY_NAME
            if not library.is_file():
                raise ArtifactError(f"Missing build output: {library}")
            checks.append(inspect_elf(library, abi, args.readelf, args.nm))
            records.append(copy_file(library, out, f"{abi}/{LIBRARY_NAME}", abi))
            header = directory / HEADER_NAME
            if header.is_file():
                records.append(copy_file(header, out, f"{abi}/{HEADER_NAME}", abi))
            abis.append(abi)
    else:
        for source in sorted(args.xcframework.rglob("*")):
            if not source.is_file():
                continue
            relative = f"{FRAMEWORK_NAME}/" + source.relative_to(args.xcframework).as_posix()
            records.append(copy_file(source, out, relative, None))
        checks.append(
            {
                "abi": "ios",
                "kind": "xcframework",
                "slices": sorted(
                    child.name for child in args.xcframework.iterdir() if child.is_dir()
                ),
            }
        )
        abis = list(args.abi or [])
    licenses = collect_licenses(args.repo_root, out, args.license, records)
    add_zip_sizes(out, records)
    manifest = {
        "schemaVersion": 1,
        "platform": args.platform,
        "abis": abis,
        "commit": args.commit,
        "generatedUtc": datetime.now(timezone.utc).isoformat(),
        "upstream": load_upstream_versions(args.versions),
        "licenses": licenses,
        "checks": checks,
        "files": records,
    }
    (out / "manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    return manifest


def summary(manifest: dict) -> str:
    lines = [f"### qfli_git {manifest['platform']}", ""]
    for check in manifest["checks"]:
        if check["kind"] == "elf":
            align = ", ".join(hex(value) for value in check["loadAlignments"])
            lines.append(
                f"- `{check['abi']}`: LOAD {align}, "
                f"{len(check['exportedSymbols'])} exported symbols"
            )
        else:
            lines.append(f"- slices: {', '.join(check['slices'])}")
    lines.extend(["", "| File | Bytes | Zipped | SHA-256 |", "| --- | ---: | ---: | --- |"])
    for record in manifest["files"]:
        lines.append(
            f"| `{record['path']}` | {record['bytes']} | {record['zipBytes']} "
            f"| `{record['sha256']}` |"
        )
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", required=True, choices=("android", "ohos", "ios"))
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--library", action="append", default=[], metavar="ABI=DIR")
    parser.add_argument("--xcframework", type=Path)
    parser.add_argument("--abi", action="append", help="declare ios slice architectures")
    parser.add_argument("--readelf", help="path to llvm-readelf")
    parser.add_argument("--nm", help="path to llvm-nm")
    parser.add_argument("--versions", type=Path, help="third_party/versions.json")
    parser.add_argument("--license", action="append", default=[], metavar="PATH[=NAME]")
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument("--commit", default="")
    args = parser.parse_args(argv)
    args.repo_root = args.repo_root.resolve()
    if args.versions is None:
        args.versions = args.repo_root / "third_party/versions.json"
    if not args.commit:
        try:
            args.commit = subprocess.run(
                ["git", "rev-parse", "HEAD"],
                cwd=args.repo_root,
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
        except (OSError, subprocess.CalledProcessError) as error:
            print(f"collect_artifacts: cannot resolve commit: {error}", file=sys.stderr)
            return 1
    try:
        manifest = collect(args)
    except (ArtifactError, OSError) as error:
        print(f"collect_artifacts: {error}", file=sys.stderr)
        if os.environ.get("GITHUB_ACTIONS"):
            # Annotations are public; job logs need admin rights.
            message = str(error).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
            print(f"::error title=collect_artifacts::{message[:1500]}")
        return 1
    report = summary(manifest)
    print(report, end="")
    summary_file = Path(summary_file_path()) if summary_file_path() else None
    if summary_file:
        with summary_file.open("a", encoding="utf-8") as stream:
            stream.write(report)
    return 0


def summary_file_path() -> str | None:
    import os

    return os.environ.get("GITHUB_STEP_SUMMARY")


if __name__ == "__main__":
    sys.exit(main())