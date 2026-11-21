"""Unit tests for import_artifacts.py manifest verification and placement.

The importer refuses any artifact that does not carry the API v2 native
contract and, for local artifact directories, an explicit commit and run.
Every test therefore writes a schema 2 manifest with the required exports and
passes `--commit` plus `--run`.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import import_artifacts as import_module  # noqa: E402

COMMIT = "b" * 40
RUN_URL = "https://github.com/azurekiln2333/qflistudio-git/actions/runs/1234"
CONTRACT = {
    "apiVersion": 2,
    "requiredExports": [
        "qg_api_version",
        "qg_add_all",
        "qg_clone",
        "qg_commit",
    ],
}
UPSTREAM = {"libgit2": "1.9.7", "mbedtls": "3.6.8", "cacert": "2026-11-05"}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_contract(root: Path, contract: dict = CONTRACT) -> Path:
    path = root / "tool/ci/native_contract.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(contract) + "\n", encoding="utf-8")
    return path


def contract_digest(root: Path) -> str:
    return sha256((root / "tool/ci/native_contract.json").read_bytes())


def write_manifest(
    artifact: Path,
    platform: str,
    files: list[tuple[str, str | None, bytes]],
    *,
    repo_root: Path | None = None,
    contract_digest_sha: str | None = None,
    api_version: int = 2,
    required_exports: list[str] | None = None,
) -> None:
    artifact.mkdir(parents=True, exist_ok=True)
    records = []
    for relative, abi, data in files:
        target = artifact / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        records.append(
            {
                "path": relative,
                "abi": abi,
                "bytes": len(data),
                "zipBytes": max(1, len(data) // 2),
                "sha256": sha256(data),
            }
        )
    checks = [
        {
            "abi": abi,
            "kind": "elf",
            "pageAlignment": 0x4000,
            "loadAlignments": [0x4000],
            "exportedSymbols": required_exports or CONTRACT["requiredExports"],
        }
        for abi in sorted({abi for _, abi, _ in files if abi})
    ]
    if platform == "ios":
        exports = required_exports or CONTRACT["requiredExports"]
        checks = [
            {"abi": "ios-arm64", "kind": "macho", "exportedSymbols": exports},
        ]
    manifest = {
        "schemaVersion": 2 if api_version else 1,
        "apiVersion": api_version,
        "requiredExports": required_exports or CONTRACT["requiredExports"],
        "contractSha256": contract_digest_sha
        or (contract_digest(repo_root) if repo_root else None),
        "platform": platform,
        "abis": sorted({abi for _, abi, _ in files if abi}),
        "commit": COMMIT,
        "generatedUtc": "2026-11-19T00:00:00+00:00",
        "upstream": dict(UPSTREAM),
        "licenses": ["licenses/PROJECT-LICENSE"],
        "checks": checks,
        "files": records,
    }
    (artifact / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")


def import_arguments(artifact: Path, root: Path) -> list[str]:
    return [
        "--artifact",
        str(artifact),
        "--repo-root",
        str(root),
        "--commit",
        COMMIT,
        "--run",
        RUN_URL,
    ]


class ImportTests(unittest.TestCase):
    def test_android_import_succeeds(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work) / "repo"
            root.mkdir()
            write_contract(root)
            artifact = Path(work) / "artifact"
            write_manifest(
                artifact,
                "android",
                [
                    ("arm64-v8a/libqfli_git.so", "arm64-v8a", b"\x7fELF arm64"),
                    ("armeabi-v7a/libqfli_git.so", "armeabi-v7a", b"\x7fELF v7a"),
                    ("x86_64/libqfli_git.so", "x86_64", b"\x7fELF x86_64"),
                    ("licenses/PROJECT-LICENSE", None, b"GPL-3.0-or-later\n"),
                ],
                repo_root=root,
            )
            self.assertEqual(import_module.main(import_arguments(artifact, root)), 0)
            copied = root / "android/src/main/jniLibs/arm64-v8a/libqfli_git.so"
            self.assertEqual(copied.read_bytes(), b"\x7fELF arm64")
            self.assertFalse((root / "android/src/main/jniLibs/licenses").exists())
            lock = json.loads((root / "native_libs.lock.json").read_text(encoding="utf-8"))
            self.assertEqual(lock["schemaVersion"], 2)
            self.assertEqual(lock["apiVersion"], 2)
            self.assertEqual(lock["requiredExports"], CONTRACT["requiredExports"])
            self.assertEqual(lock["contractSha256"], contract_digest(root))
            self.assertEqual(lock["source"]["run"], RUN_URL)
            self.assertEqual(lock["source"]["commit"], COMMIT)
            self.assertEqual(lock["source"]["commits"]["android"], COMMIT)
            self.assertEqual(lock["source"]["upstream"]["android"], UPSTREAM)
            paths = {entry["path"] for entry in lock["files"]}
            self.assertEqual(
                paths,
                {
                    "android/src/main/jniLibs/arm64-v8a/libqfli_git.so",
                    "android/src/main/jniLibs/armeabi-v7a/libqfli_git.so",
                    "android/src/main/jniLibs/x86_64/libqfli_git.so",
                },
            )
            for entry in lock["files"]:
                self.assertEqual(entry["sha256"], sha256((root / entry["path"]).read_bytes()))

    def test_ohos_import_succeeds(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work) / "repo"
            root.mkdir()
            write_contract(root)
            artifact = Path(work) / "artifact"
            write_manifest(
                artifact,
                "ohos",
                [
                    ("arm64-v8a/libqfli_git.so", "arm64-v8a", b"\x7fELF ohos arm64"),
                    ("x86_64/libqfli_git.so", "x86_64", b"\x7fELF ohos x86_64"),
                ],
                repo_root=root,
            )
            self.assertEqual(import_module.main(import_arguments(artifact, root)), 0)
            self.assertTrue((root / "ohos/libs/arm64-v8a/libqfli_git.so").is_file())

    def test_ios_import_replaces_framework(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work) / "repo"
            stale = root / "ios/Frameworks/qfli_git.xcframework/ios-arm64/stale"
            stale.parent.mkdir(parents=True)
            stale.write_bytes(b"stale")
            write_contract(root)
            artifact = Path(work) / "artifact"
            write_manifest(
                artifact,
                "ios",
                [
                    ("qfli_git.xcframework/Info.plist", None, b"<plist/>"),
                    (
                        "qfli_git.xcframework/ios-arm64/qfli_git.framework/qfli_git",
                        None,
                        b"\xcf\xfa\xed\xfe device",
                    ),
                    ("licenses/PROJECT-LICENSE", None, b"GPL-3.0-or-later\n"),
                ],
                repo_root=root,
            )
            self.assertEqual(import_module.main(import_arguments(artifact, root)), 0)
            framework = root / "ios/Frameworks/qfli_git.xcframework"
            self.assertFalse((framework / "ios-arm64/stale").exists())
            self.assertTrue((framework / "Info.plist").is_file())
            self.assertTrue((framework / "ios-arm64/qfli_git.framework/qfli_git").is_file())

    def test_local_import_without_run_fails(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work) / "repo"
            root.mkdir()
            write_contract(root)
            artifact = Path(work) / "artifact"
            write_manifest(
                artifact,
                "android",
                [("arm64-v8a/libqfli_git.so", "arm64-v8a", b"\x7fELF arm64")],
                repo_root=root,
            )
            self.assertEqual(
                import_module.main(
                    [
                        "--artifact",
                        str(artifact),
                        "--repo-root",
                        str(root),
                        "--commit",
                        COMMIT,
                    ]
                ),
                1,
            )
            self.assertFalse((root / "native_libs.lock.json").exists())

    def test_local_import_without_commit_fails(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work) / "repo"
            root.mkdir()
            write_contract(root)
            artifact = Path(work) / "artifact"
            write_manifest(
                artifact,
                "android",
                [("arm64-v8a/libqfli_git.so", "arm64-v8a", b"\x7fELF arm64")],
                repo_root=root,
            )
            self.assertEqual(
                import_module.main(
                    ["--artifact", str(artifact), "--repo-root", str(root), "--run", RUN_URL]
                ),
                1,
            )
            self.assertFalse((root / "android/src/main/jniLibs").exists())

    def test_legacy_api1_artifact_fails(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work) / "repo"
            root.mkdir()
            write_contract(root)
            artifact = Path(work) / "artifact"
            write_manifest(
                artifact,
                "android",
                [("arm64-v8a/libqfli_git.so", "arm64-v8a", b"\x7fELF arm64")],
                repo_root=root,
                api_version=1,
            )
            self.assertEqual(import_module.main(import_arguments(artifact, root)), 1)
            self.assertFalse((root / "native_libs.lock.json").exists())

    def test_artifact_built_from_another_contract_fails(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work) / "repo"
            root.mkdir()
            write_contract(root)
            artifact = Path(work) / "artifact"
            write_manifest(
                artifact,
                "android",
                [("arm64-v8a/libqfli_git.so", "arm64-v8a", b"\x7fELF arm64")],
                contract_digest_sha="d" * 64,
            )
            self.assertEqual(import_module.main(import_arguments(artifact, root)), 1)
            self.assertFalse((root / "native_libs.lock.json").exists())

    def test_artifact_missing_a_required_export_fails(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work) / "repo"
            root.mkdir()
            write_contract(root)
            artifact = Path(work) / "artifact"
            write_manifest(
                artifact,
                "android",
                [("arm64-v8a/libqfli_git.so", "arm64-v8a", b"\x7fELF arm64")],
                repo_root=root,
                required_exports=["qg_api_version", "qg_add_all", "qg_clone"],
            )
            self.assertEqual(import_module.main(import_arguments(artifact, root)), 1)
            self.assertFalse((root / "native_libs.lock.json").exists())

    def test_missing_contract_file_fails(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work) / "repo"
            root.mkdir()
            artifact = Path(work) / "artifact"
            write_manifest(
                artifact,
                "android",
                [("arm64-v8a/libqfli_git.so", "arm64-v8a", b"\x7fELF arm64")],
            )
            self.assertEqual(import_module.main(import_arguments(artifact, root)), 1)

    def test_checksum_mismatch_fails(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work) / "repo"
            root.mkdir()
            write_contract(root)
            artifact = Path(work) / "artifact"
            write_manifest(
                artifact,
                "android",
                [("arm64-v8a/libqfli_git.so", "arm64-v8a", b"\x7fELF arm64")],
                repo_root=root,
            )
            (artifact / "arm64-v8a/libqfli_git.so").write_bytes(b"\x7fELF tampered")
            self.assertEqual(import_module.main(import_arguments(artifact, root)), 1)
            self.assertFalse((root / "android/src/main/jniLibs/arm64-v8a").exists())
            self.assertFalse((root / "native_libs.lock.json").exists())

    def test_manifest_commit_filter(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work) / "repo"
            root.mkdir()
            write_contract(root)
            artifact = Path(work) / "artifact"
            write_manifest(
                artifact,
                "android",
                [("arm64-v8a/libqfli_git.so", "arm64-v8a", b"\x7fELF arm64")],
                repo_root=root,
            )
            self.assertEqual(
                import_module.main(
                    [
                        "--artifact",
                        str(artifact),
                        "--repo-root",
                        str(root),
                        "--commit",
                        "c" * 40,
                        "--run",
                        RUN_URL,
                    ]
                ),
                1,
            )

    def test_path_traversal_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            artifact = Path(work) / "artifact"
            write_manifest(
                artifact,
                "android",
                [("arm64-v8a/libqfli_git.so", "arm64-v8a", b"\x7fELF arm64")],
            )
            manifest = json.loads(
                (artifact / "manifest.json").read_text(encoding="utf-8")
            )
            manifest["files"][0]["path"] = "../escape.so"
            (artifact / "manifest.json").write_text(
                json.dumps(manifest), encoding="utf-8"
            )
            with self.assertRaises(import_module.ArtifactError):
                import_module.verify_manifest(
                    artifact, import_module.load_manifest(artifact)
                )

    def test_release_zip_with_wrapper_directory(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work) / "repo"
            root.mkdir()
            write_contract(root)
            staging = Path(work) / "staging"
            inside = staging / "qfli-git-ohos-abc123"
            write_manifest(
                inside,
                "ohos",
                [("arm64-v8a/libqfli_git.so", "arm64-v8a", b"\x7fELF ohos arm64")],
                repo_root=root,
            )
            archive = Path(work) / "ohos.zip"
            with zipfile.ZipFile(archive, "w") as bundle:
                for source in sorted(inside.rglob("*")):
                    if source.is_file():
                        bundle.write(source, source.relative_to(staging).as_posix())
            extracted = Path(work) / "extracted"
            import_module.extract_zip(archive, extracted)
            found = import_module.artifact_root(extracted)
            self.assertEqual(found, extracted / "qfli-git-ohos-abc123")
            self.assertEqual(
                import_module.main(
                    [
                        "--artifact",
                        str(found),
                        "--repo-root",
                        str(root),
                        "--commit",
                        COMMIT,
                        "--run",
                        RUN_URL,
                    ]
                ),
                0,
            )
            self.assertTrue((root / "ohos/libs/arm64-v8a/libqfli_git.so").is_file())

    def test_artifact_root_rejects_two_wrapper_directories(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            extracted = Path(work)
            for name in ("first", "second"):
                write_manifest(
                    extracted / name,
                    "ohos",
                    [("arm64-v8a/libqfli_git.so", "arm64-v8a", b"\x7fELF ohos arm64")],
                )
            with self.assertRaises(import_module.ArtifactError):
                import_module.artifact_root(extracted)

    def test_abi_traversal_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work) / "repo"
            root.mkdir()
            write_contract(root)
            artifact = Path(work) / "artifact"
            write_manifest(
                artifact,
                "android",
                [("arm64-v8a/libqfli_git.so", "arm64-v8a", b"\x7fELF arm64")],
                repo_root=root,
            )
            manifest = json.loads(
                (artifact / "manifest.json").read_text(encoding="utf-8")
            )
            manifest["files"][0]["abi"] = "../../../escaped"
            (artifact / "manifest.json").write_text(
                json.dumps(manifest), encoding="utf-8"
            )
            self.assertEqual(import_module.main(import_arguments(artifact, root)), 1)
            self.assertFalse((root / "android/escaped").exists())
            self.assertFalse((root / "native_libs.lock.json").exists())

    def test_unknown_abi_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work) / "repo"
            root.mkdir()
            write_contract(root)
            artifact = Path(work) / "artifact"
            write_manifest(
                artifact,
                "ohos",
                [("arm64-v8a/libqfli_git.so", "arm64-v8a", b"\x7fELF ohos arm64")],
                repo_root=root,
            )
            manifest = json.loads(
                (artifact / "manifest.json").read_text(encoding="utf-8")
            )
            manifest["files"][0]["abi"] = "armeabi-v7a"
            (artifact / "manifest.json").write_text(
                json.dumps(manifest), encoding="utf-8"
            )
            self.assertEqual(import_module.main(import_arguments(artifact, root)), 1)
            self.assertFalse((root / "ohos/libs").exists())

    def test_other_shared_libraries_are_not_payload(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work) / "repo"
            root.mkdir()
            write_contract(root)
            artifact = Path(work) / "artifact"
            write_manifest(
                artifact,
                "android",
                [
                    ("arm64-v8a/libqfli_git.so", "arm64-v8a", b"\x7fELF arm64"),
                    ("arm64-v8a/libc++_shared.so", "arm64-v8a", b"\x7fELF shim"),
                ],
                repo_root=root,
            )
            self.assertEqual(import_module.main(import_arguments(artifact, root)), 0)
            jni = root / "android/src/main/jniLibs/arm64-v8a"
            self.assertEqual(sorted(child.name for child in jni.iterdir()), ["libqfli_git.so"])

    def test_repository_contract_matches_header(self) -> None:
        """The tracked contract must describe the tracked public API."""
        repo = Path(__file__).resolve().parents[2]
        contract = import_module.load_contract(repo / "tool/ci/native_contract.json")
        self.assertEqual(contract["apiVersion"], 3)
        self.assertIn("qg_clone", contract["requiredExports"])
        self.assertIn("qg_clone_with_progress", contract["requiredExports"])
        header = (repo / "native/include/qfli_git.h").read_text(encoding="utf-8")
        for name in contract["requiredExports"]:
            self.assertIn(name, header)

    def test_missing_manifest_fails(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            with self.assertRaises(import_module.ArtifactError):
                import_module.load_manifest(Path(work))


if __name__ == "__main__":
    unittest.main()
