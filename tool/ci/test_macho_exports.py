"""Regression tests for the Mach-O export parsing in collect_artifacts.py.

A fat xcframework slice is read with `nm -gU`, which prints one
`(for architecture <arch>):` header per archive before its symbol lines. Taking
the last whitespace field of such a header yields `arm64):`, which the export
check rejects as a foreign symbol. These tests pin the strict line parser and
the per-architecture `nm -arch` query.
"""
from __future__ import annotations

from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import collect_artifacts as collect  # noqa: E402

# `nm -gU` on a fat binary: two archives, each with a header line.
FAT_NM_OUTPUT = """
fat.bin (for architecture arm64):
0000000000012340 T _qg_api_version
0000000000012400 T _qg_add_all
0000000000012500 T _qg_clone
0000000000012600 T _qg_commit
fat.bin (for architecture x86_64):
0000000000012340 T _qg_api_version
0000000000012400 T _qg_add_all
0000000000012500 T _qg_clone
0000000000012600 T _qg_commit
"""

# `nm -arch all -gU` on the same binary, one section per architecture.
ARCH_ALL_OUTPUT = """
fat.bin (for architecture arm64):
0000000000012340 T _qg_api_version
fat.bin (for architecture x86_64):
0000000000012340 T _qg_api_version
"""

# A thin binary: no architecture header at all.
THIN_NM_OUTPUT = """
0000000000012340 T _qg_api_version
0000000000012400 T _qg_add_all
0000000000012500 T _qg_clone
0000000000012600 T _qg_commit
"""

ARCH_EXPORTS = {
    "arm64": """
0000000000012340 T _qg_api_version
0000000000012400 T _qg_add_all
0000000000012500 T _qg_clone
0000000000012600 T _qg_commit
""",
    "x86_64": """
0000000000012340 T _qg_api_version
0000000000012400 T _qg_add_all
0000000000012500 T _qg_clone
0000000000012600 T _qg_commit
""",
}

REQUIRED = ["qg_api_version", "qg_add_all", "qg_clone", "qg_commit"]


class MachoParseTests(unittest.TestCase):
    def test_fat_headers_are_not_symbols(self) -> None:
        symbols = collect.parse_macho_symbols(FAT_NM_OUTPUT)
        self.assertNotIn("arm64):", symbols)
        self.assertNotIn("x86_64):", symbols)
        self.assertEqual(
            sorted(set(symbols)),
            ["qg_add_all", "qg_api_version", "qg_clone", "qg_commit"],
        )

    def test_fat_parse_passes_the_export_check(self) -> None:
        symbols = collect.parse_macho_symbols(FAT_NM_OUTPUT)
        collect.check_exports(list(dict.fromkeys(symbols)), required=REQUIRED)

    def test_thin_binary_still_parses(self) -> None:
        symbols = collect.parse_macho_symbols(THIN_NM_OUTPUT)
        self.assertEqual(
            sorted(symbols),
            ["qg_add_all", "qg_api_version", "qg_clone", "qg_commit"],
        )

    def test_arch_all_output_yields_one_symbol_per_slice(self) -> None:
        self.assertEqual(
            collect.parse_macho_symbols(ARCH_ALL_OUTPUT),
            ["qg_api_version", "qg_api_version"],
        )

    def test_diagnostics_and_blank_lines_are_skipped(self) -> None:
        output = (
            "warning: /tmp/x.a(qg.o) object file is not an object file\n"
            "\n"
            "0000000000012340 T _qg_api_version\n"
        )
        self.assertEqual(collect.parse_macho_symbols(output), ["qg_api_version"])

    def test_undefined_entries_are_not_exports(self) -> None:
        output = "0000000000012340 T _qg_api_version\n                 U _strlen\n"
        self.assertEqual(collect.parse_macho_symbols(output), ["qg_api_version"])

    def test_double_underscore_internals_are_skipped(self) -> None:
        output = "0000000000012340 T __ZSt9terminatev\n0000000000012400 T _qg_clone\n"
        self.assertEqual(collect.parse_macho_symbols(output), ["qg_clone"])

    def test_foreign_export_fails(self) -> None:
        output = FAT_NM_OUTPUT + "0000000000012700 T _git_libgit2_init\n"
        symbols = list(dict.fromkeys(collect.parse_macho_symbols(output)))
        with self.assertRaises(collect.ArtifactError) as raised:
            collect.check_exports(symbols, required=REQUIRED)
        self.assertIn("git_libgit2_init", str(raised.exception))

    def test_missing_required_export_fails(self) -> None:
        output = "0000000000012340 T _qg_api_version\n"
        symbols = collect.parse_macho_symbols(output)
        with self.assertRaises(collect.ArtifactError) as raised:
            collect.check_exports(symbols, required=REQUIRED)
        self.assertIn("qg_clone", str(raised.exception))


class MachoArchTests(unittest.TestCase):
    def fake_nm(self, command: list[str]) -> str:
        if command[1] == "-arch" and command[2] == "all":
            return ARCH_ALL_OUTPUT
        if command[1] == "-arch":
            return ARCH_EXPORTS[command[2]]
        return FAT_NM_OUTPUT

    def test_architectures_are_read_from_headers(self) -> None:
        with mock.patch.object(collect, "tool_output", side_effect=self.fake_nm):
            found = collect.macho_architectures("nm", Path("fat.bin"))
        self.assertEqual(found, ["arm64", "x86_64"])

    def test_each_architecture_is_queried_separately(self) -> None:
        calls = []

        def record(command: list[str]) -> str:
            calls.append(command)
            return self.fake_nm(command)

        with mock.patch.object(collect, "tool_output", side_effect=record):
            symbols = collect.macho_exports("nm", Path("fat.bin"))
        self.assertEqual(
            sorted(symbols),
            ["qg_add_all", "qg_api_version", "qg_clone", "qg_commit"],
        )
        thin_queries = [call for call in calls if call[1] == "-arch" and call[2] != "all"]
        self.assertEqual(
            [call[2] for call in thin_queries],
            ["arm64", "x86_64"],
        )

    def test_thin_binary_falls_back_to_one_query(self) -> None:
        calls = []

        def record(command: list[str]) -> str:
            calls.append(command)
            if command[1] == "-arch":
                return ""
            return THIN_NM_OUTPUT

        with mock.patch.object(collect, "tool_output", side_effect=record):
            symbols = collect.macho_exports("nm", Path("thin.bin"))
        self.assertEqual(len(symbols), 4)
        self.assertEqual(sum(1 for call in calls if call[1] == "-gU"), 1)

    def test_inspect_macho_records_architectures(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            binary = Path(work) / "qfli_git"
            binary.write_bytes(b"\xcf\xfa\xed\xfe" + b"\x00" * 28)
            with mock.patch.object(collect, "tool_output", side_effect=self.fake_nm):
                facts = collect.inspect_macho(binary, "arm64", "nm", REQUIRED)
        self.assertEqual(facts["architectures"], ["arm64", "x86_64"])
        self.assertEqual(
            facts["exportedSymbols"],
            ["qg_add_all", "qg_api_version", "qg_clone", "qg_commit"],
        )


if __name__ == "__main__":
    unittest.main()
