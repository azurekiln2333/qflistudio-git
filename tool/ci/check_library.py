#!/usr/bin/env python3
"""Check one built host library against the native contract."""
from __future__ import annotations

import argparse
from pathlib import Path
import sys

from collect_artifacts import (
    ArtifactError,
    check_exports,
    inspect_elf,
    inspect_macho,
    load_contract,
)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", required=True, type=Path)
    parser.add_argument("--contract", required=True, type=Path)
    parser.add_argument("--nm", default="nm")
    parser.add_argument("--readelf", default="readelf")
    parser.add_argument(
        "--require-page-alignment",
        action="store_true",
        help="also require 16 KiB LOAD alignment (packaged mobile payloads)",
    )
    args = parser.parse_args(argv)
    try:
        contract = load_contract(args.contract)
        header = args.library.read_bytes()[:4]
        if header == b"\x7fELF":
            # A host build uses the plain host toolchain, which keeps the
            # default 4 KiB LOAD alignment. Only packaged mobile payloads are
            # gated on the 16 KiB page requirement.
            check = inspect_elf(
                args.library,
                "host",
                args.readelf,
                args.nm,
                contract["requiredExports"],
                require_page_alignment=args.require_page_alignment,
            )
        elif header in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe"):
            check = inspect_macho(
                args.library, "host", args.nm, contract["requiredExports"]
            )
        else:
            raise ArtifactError(f"Unsupported library format: {args.library}")
    except (ArtifactError, OSError) as error:
        print(f"check_library: {error}", file=sys.stderr)
        return 1
    alignment = (
        "page-aligned" if args.require_page_alignment else "alignment unchecked (host)"
    )
    print(
        f"PASS {args.library} API {contract['apiVersion']}, "
        f"{len(check['exportedSymbols'])} exports, {alignment}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())