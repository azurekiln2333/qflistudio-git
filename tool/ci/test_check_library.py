"""Regression tests for check_library.py host builds.

A host build uses the plain host toolchain, so its LOAD segments keep the
default 4 KiB page alignment. The host check must accept that and still verify
the export list. Packaged mobile payloads keep the strict 16 KiB gate, which is
covered by test_collect_artifacts.py.
"""
from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import check_library  # noqa: E402
import collect_artifacts as collect  # noqa: E402

READELF_HOST = """\
Program Headers:
  Type           Offset   VirtAddr           PhysAddr           FileSiz  MemSiz   Flg Align
  LOAD           0x000000 0x0000000000000000 0x0000000000000000 0x04a1b0 0x04a1b0 R E 0x1000
  LOAD           0x04a1c0 0x000000000004b1c0 0x000000000004b1c0 0x0022b0 0x0022b0 RW  0x1000
"""

NM_EXPORTS = """\
0000000000012340 T qg_api_version
0000000000012400 T qg_add_all
"""

CONTRACT = {
    "apiVersion": 2,
    "requiredExports": ["qg_api_version", "qg_add_all"],
}


def write_contract(directory: Path) -> Path:
    path = directory / "native_contract.json"
    path.write_text(json.dumps(CONTRACT) + "\n", encoding="utf-8")
    return path


def write_library(directory: Path) -> Path:
    path = directory / "libqfli_git.so"
    path.write_bytes(b"\x7fELF" + b"\x00" * 60)
    return path


def fake_tool(readelf: str = READELF_HOST, nm: str = NM_EXPORTS):
    def run(command: list[str]) -> str:
        return readelf if "-lW" in command else nm

    return run


class CheckLibraryTests(unittest.TestCase):
    def test_host_build_with_4k_pages_passes(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            directory = Path(work)
            library = write_library(directory)
            contract = write_contract(directory)
            with mock.patch.object(collect, "tool_output", side_effect=fake_tool()):
                code = check_library.main(
                    ["--library", str(library), "--contract", str(contract)]
                )
            self.assertEqual(code, 0)

    def test_mobile_payload_with_4k_pages_fails_when_alignment_is_required(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            directory = Path(work)
            library = write_library(directory)
            contract = write_contract(directory)
            with mock.patch.object(collect, "tool_output", side_effect=fake_tool()):
                code = check_library.main(
                    [
                        "--library",
                        str(library),
                        "--contract",
                        str(contract),
                        "--require-page-alignment",
                    ]
                )
            self.assertEqual(code, 1)

    def test_missing_required_export_fails(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            directory = Path(work)
            library = write_library(directory)
            contract = write_contract(directory)
            incomplete = "0000000000012340 T qg_api_version\n"
            with mock.patch.object(
                collect, "tool_output", side_effect=fake_tool(nm=incomplete)
            ):
                code = check_library.main(
                    ["--library", str(library), "--contract", str(contract)]
                )
            self.assertEqual(code, 1)

    def test_non_library_file_fails(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            directory = Path(work)
            library = directory / "notes.txt"
            library.write_text("not a library\n", encoding="utf-8")
            contract = write_contract(directory)
            code = check_library.main(
                ["--library", str(library), "--contract", str(contract)]
            )
            self.assertEqual(code, 1)

    def test_missing_contract_fails(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            directory = Path(work)
            library = write_library(directory)
            code = check_library.main(
                [
                    "--library",
                    str(library),
                    "--contract",
                    str(directory / "absent.json"),
                ]
            )
            self.assertEqual(code, 1)


if __name__ == "__main__":
    unittest.main()
