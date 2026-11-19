"""Unit tests for the artifact checks in collect_artifacts.py."""
from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import collect_artifacts as collect  # noqa: E402

READELF_ALIGNED = """\
Elf file type is DYN (Shared object file)
Entry point 0x0
There are 9 program headers, starting at offset 64

Program Headers:
  Type           Offset   VirtAddr           PhysAddr           FileSiz  MemSiz   Flg Align
  PHDR           0x000040 0x0000000000000040 0x0000000000000040 0x0001f8 0x0001f8 R   0x40
  LOAD           0x000000 0x0000000000000000 0x0000000000000000 0x04a1b0 0x04a1b0 R E 0x4000
  LOAD           0x04a1c0 0x000000000004b1c0 0x000000000004b1c0 0x0022b0 0x0022b0 RW  0x4000
  DYNAMIC        0x04a1f0 0x000000000004b1f0 0x000000000004b1f0 0x0001e0 0x0001e0 RW  0x8
"""

READELF_UNALIGNED = READELF_ALIGNED.replace("0x04a1b0 R E 0x4000", "0x04a1b0 R E 0x1000")

NM_EXPORTS = """\
0000000000012340 T qg_add_all
0000000000012400 T qg_clone
0000000000012500 T qg_commit
"""

NM_LEAK = NM_EXPORTS + "0000000000012600 T git_libgit2_init\n"


def elf_arguments(directory: Path, readelf: str, nm: str) -> list[str]:
    return [
        "--platform",
        "android",
        "--out",
        str(directory / "artifacts"),
        "--library",
        f"arm64-v8a={directory / 'arm64-v8a'}",
        "--library",
        f"armeabi-v7a={directory / 'armeabi-v7a'}",
        "--library",
        f"x86_64={directory / 'x86_64'}",
        "--readelf",
        readelf,
        "--nm",
        nm,
        "--versions",
        str(directory / "versions.json"),
        "--repo-root",
        str(directory),
        "--commit",
        "a" * 40,
    ]


class AlignmentTests(unittest.TestCase):
    def test_parse_load_alignments_reads_last_column(self) -> None:
        self.assertEqual(collect.parse_load_alignments(READELF_ALIGNED), [0x4000, 0x4000])

    def test_aligned_segments_pass(self) -> None:
        collect.check_alignment(collect.parse_load_alignments(READELF_ALIGNED))

    def test_unaligned_segment_fails(self) -> None:
        alignments = collect.parse_load_alignments(READELF_UNALIGNED)
        with self.assertRaises(collect.ArtifactError) as raised:
            collect.check_alignment(alignments)
        self.assertIn("0x1000", str(raised.exception))

    def test_missing_load_header_fails(self) -> None:
        with self.assertRaises(collect.ArtifactError):
            collect.check_alignment([])

    def test_non_multiple_alignment_fails(self) -> None:
        with self.assertRaises(collect.ArtifactError):
            collect.check_alignment([0x6000])


class ExportTests(unittest.TestCase):
    def test_qg_exports_pass(self) -> None:
        symbols = collect.parse_defined_symbols(NM_EXPORTS)
        self.assertEqual(symbols, ["qg_add_all", "qg_clone", "qg_commit"])
        collect.check_exports(symbols)

    def test_foreign_export_fails(self) -> None:
        with self.assertRaises(collect.ArtifactError) as raised:
            collect.check_exports(collect.parse_defined_symbols(NM_LEAK))
        self.assertIn("git_libgit2_init", str(raised.exception))

    def test_underscore_symbols_are_ignored(self) -> None:
        output = NM_EXPORTS + "0000000000012700 T __stack_chk_fail\n"
        self.assertEqual(
            collect.parse_defined_symbols(output), ["qg_add_all", "qg_clone", "qg_commit"]
        )

    def test_version_node_symbols_are_ignored(self) -> None:
        output = NM_EXPORTS + "0000000000000000 A QFLI_GIT_1.0\n"
        self.assertEqual(
            collect.parse_defined_symbols(output), ["qg_add_all", "qg_clone", "qg_commit"]
        )

    def test_no_export_fails(self) -> None:
        with self.assertRaises(collect.ArtifactError):
            collect.check_exports([])


class VersionTests(unittest.TestCase):
    def test_mapping_file(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            path = Path(work) / "versions.json"
            path.write_text(
                json.dumps(
                    {
                        "libgit2": {"version": "1.9.7", "url": "u", "sha256": "s"},
                        "mbedtls": {"version": "3.6.4"},
                    }
                ),
                encoding="utf-8",
            )
            self.assertEqual(
                collect.load_upstream_versions(path),
                {"libgit2": "1.9.7", "mbedtls": "3.6.4"},
            )

    def test_list_file(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            path = Path(work) / "versions.json"
            path.write_text(
                json.dumps([{"name": "libgit2", "version": "1.9.7"}]), encoding="utf-8"
            )
            self.assertEqual(collect.load_upstream_versions(path), {"libgit2": "1.9.7"})

    def test_repository_file(self) -> None:
        path = Path(__file__).resolve().parents[2] / "third_party" / "versions.json"
        versions = collect.load_upstream_versions(path)
        self.assertEqual(set(versions), {"libgit2", "mbedtls", "cacert"})
        self.assertNotIn("unknown", versions.values())

    def test_missing_file_fails(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            with self.assertRaises(collect.ArtifactError):
                collect.load_upstream_versions(Path(work) / "versions.json")


class CollectTests(unittest.TestCase):
    def prepare(self, directory: Path) -> None:
        (directory / "versions.json").write_text(
            json.dumps({"libgit2": {"version": "1.9.7"}, "mbedtls": {"version": "3.6.4"}}),
            encoding="utf-8",
        )
        (directory / "LICENSE").write_text("GPL-3.0-or-later\n", encoding="utf-8")
        licenses = directory / "third_party/licenses"
        licenses.mkdir(parents=True)
        for name in ("libgit2.txt", "mbedtls.txt", "cacert.txt"):
            (licenses / name).write_text(f"{name} terms\n", encoding="utf-8")
        for abi in collect.PLATFORM_ABIS["android"]:
            build = directory / abi
            build.mkdir(parents=True)
            (build / collect.LIBRARY_NAME).write_bytes(b"\x7fELF" + abi.encode() * 64)
            (build / collect.HEADER_NAME).write_text("#pragma once\n", encoding="utf-8")

    def fake_tool(self, command: list[str]) -> str:
        return READELF_ALIGNED if "-lW" in command else NM_EXPORTS

    def test_successful_collection(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            directory = Path(work)
            self.prepare(directory)
            with mock.patch.object(collect, "tool_output", side_effect=self.fake_tool):
                code = collect.main(elf_arguments(directory, "readelf", "nm"))
            self.assertEqual(code, 0)
            manifest = json.loads(
                (directory / "artifacts/manifest.json").read_text(encoding="utf-8")
            )
            self.assertEqual(manifest["platform"], "android")
            self.assertEqual(manifest["commit"], "a" * 40)
            self.assertEqual(manifest["upstream"]["libgit2"], "1.9.7")
            self.assertEqual(
                sorted(manifest["abis"]),
                sorted(collect.PLATFORM_ABIS["android"]),
            )
            paths = {record["path"] for record in manifest["files"]}
            self.assertIn("arm64-v8a/libqfli_git.so", paths)
            self.assertIn("licenses/PROJECT-LICENSE", paths)
            for record in manifest["files"]:
                self.assertGreater(record["bytes"], 0)
                self.assertGreater(record["zipBytes"], 0)
                self.assertEqual(len(record["sha256"]), 64)

    def test_upstream_licenses_are_collected(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            directory = Path(work)
            self.prepare(directory)
            with mock.patch.object(collect, "tool_output", side_effect=self.fake_tool):
                self.assertEqual(collect.main(elf_arguments(directory, "readelf", "nm")), 0)
            manifest = json.loads(
                (directory / "artifacts/manifest.json").read_text(encoding="utf-8")
            )
            self.assertEqual(
                sorted(manifest["licenses"]),
                [
                    "licenses/CACERT-LICENSE",
                    "licenses/LIBGIT2-LICENSE",
                    "licenses/MBEDTLS-LICENSE",
                    "licenses/PROJECT-LICENSE",
                ],
            )
            for relative in manifest["licenses"]:
                self.assertTrue((directory / "artifacts" / relative).is_file())

    def test_repository_licenses_exist(self) -> None:
        licenses = Path(__file__).resolve().parents[2] / "third_party" / "licenses"
        for name in ("libgit2.txt", "mbedtls.txt", "cacert.txt"):
            path = licenses / name
            self.assertTrue(path.is_file(), msg=str(path))
            self.assertGreater(path.stat().st_size, 0, msg=str(path))

    def test_unaligned_library_fails(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            directory = Path(work)
            self.prepare(directory)
            with mock.patch.object(collect, "tool_output", return_value=READELF_UNALIGNED):
                code = collect.main(elf_arguments(directory, "readelf", "nm"))
            self.assertEqual(code, 1)

    def test_leaked_symbol_fails(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            directory = Path(work)
            self.prepare(directory)

            def fake(command: list[str]) -> str:
                return READELF_ALIGNED if "-lW" in command else NM_LEAK

            with mock.patch.object(collect, "tool_output", side_effect=fake):
                code = collect.main(elf_arguments(directory, "readelf", "nm"))
            self.assertEqual(code, 1)

    def test_missing_abi_fails(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            directory = Path(work)
            self.prepare(directory)
            arguments = [
                argument
                for argument in elf_arguments(directory, "readelf", "nm")
                if not argument.startswith("x86_64=")
            ]
            position = arguments.index(f"arm64-v8a={directory / 'arm64-v8a'}")
            # The x86_64 value is gone, so drop its dangling --library flag too.
            arguments.pop(arguments.index("--readelf") - 1)
            with mock.patch.object(collect, "tool_output", side_effect=self.fake_tool):
                self.assertEqual(collect.main(arguments), 1)


if __name__ == "__main__":
    unittest.main()