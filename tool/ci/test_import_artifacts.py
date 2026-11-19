"""Unit tests for import_artifacts.py manifest verification and placement."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import import_artifacts as import_module  # noqa: E402

COMMIT = "b" * 40


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_manifest(artifact: Path, platform: str, files: list[tuple[str, str | None, bytes]]) -> None:
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
    manifest = {
        "schemaVersion": 1,
        "platform": platform,
        "abis": sorted({abi for _, abi, _ in files if abi}),
        "commit": COMMIT,
        "generatedUtc": "2026-11-19T00:00:00+00:00",
        "upstream": {"libgit2": "1.9.7", "mbedtls": "3.6.4"},
        "licenses": ["licenses/PROJECT-LICENSE"],
        "checks": [],
        "files": records,
    }
    (artifact / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")


class ImportTests(unittest.TestCase):
    def test_android_import_succeeds(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work) / "repo"
            root.mkdir()
            artifact = Path(work) / "artifact"
            write_manifest(
                artifact,
                "android",
                [
                    ("arm64-v8a/libqfli_git.so", "arm64-v8a", b"\x7fELF arm64"),
                    ("armeabi-v7a/libqfli_git.so", "armeabi-v7a", b"\x7fELF v7a"),
                    ("x86_64/libqfli_git.so", "x86_64", b"\x7fELF x86_64"),
                ],
            )
            code = import_module.main(
                ["--artifact", str(artifact), "--repo-root", str(root)]
            )
            self.assertEqual(code, 0)
            copied = root / "android/src/main/jniLibs/arm64-v8a/libqfli_git.so"
            self.assertEqual(copied.read_bytes(), b"\x7fELF arm64")
            lock = json.loads((root / "native_libs.lock.json").read_text(encoding="utf-8"))
            self.assertEqual(lock["source"]["commits"]["android"], COMMIT)
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
            artifact = Path(work) / "artifact"
            write_manifest(
                artifact,
                "ohos",
                [
                    ("arm64-v8a/libqfli_git.so", "arm64-v8a", b"\x7fELF ohos arm64"),
                    ("x86_64/libqfli_git.so", "x86_64", b"\x7fELF ohos x86_64"),
                ],
            )
            self.assertEqual(
                import_module.main(["--artifact", str(artifact), "--repo-root", str(root)]),
                0,
            )
            self.assertTrue(
                (root / "ohos/libs/arm64-v8a/libqfli_git.so").is_file()
            )

    def test_ios_import_replaces_framework(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work) / "repo"
            stale = root / "ios/Frameworks/qfli_git.xcframework/ios-arm64/stale"
            stale.parent.mkdir(parents=True)
            stale.write_bytes(b"stale")
            artifact = Path(work) / "artifact"
            write_manifest(
                artifact,
                "ios",
                [
                    (
                        "qfli_git.xcframework/Info.plist",
                        None,
                        b"<plist/>",
                    ),
                    (
                        "qfli_git.xcframework/ios-arm64/qfli_git.framework/qfli_git",
                        None,
                        b"\xcf\xfa\xed\xfe device",
                    ),
                ],
            )
            self.assertEqual(
                import_module.main(["--artifact", str(artifact), "--repo-root", str(root)]),
                0,
            )
            framework = root / "ios/Frameworks/qfli_git.xcframework"
            self.assertFalse((framework / "ios-arm64/stale").exists())
            self.assertTrue((framework / "Info.plist").is_file())
            self.assertTrue((framework / "ios-arm64/qfli_git.framework/qfli_git").is_file())

    def test_checksum_mismatch_fails(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work) / "repo"
            root.mkdir()
            artifact = Path(work) / "artifact"
            write_manifest(
                artifact,
                "android",
                [("arm64-v8a/libqfli_git.so", "arm64-v8a", b"\x7fELF arm64")],
            )
            (artifact / "arm64-v8a/libqfli_git.so").write_bytes(b"\x7fELF tampered")
            self.assertEqual(
                import_module.main(["--artifact", str(artifact), "--repo-root", str(root)]),
                1,
            )
            self.assertFalse((root / "android/src/main/jniLibs/arm64-v8a").exists())
            self.assertFalse((root / "native_libs.lock.json").exists())

    def test_manifest_commit_filter(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work) / "repo"
            root.mkdir()
            artifact = Path(work) / "artifact"
            write_manifest(
                artifact,
                "android",
                [("arm64-v8a/libqfli_git.so", "arm64-v8a", b"\x7fELF arm64")],
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

    def test_missing_manifest_fails(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            with self.assertRaises(import_module.ArtifactError):
                import_module.load_manifest(Path(work))


if __name__ == "__main__":
    unittest.main()