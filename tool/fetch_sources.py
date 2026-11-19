#!/usr/bin/env python3
"""Download, verify and unpack the pinned upstream sources.

Reads third_party/versions.json, writes archives to native/build/downloads/,
and unpacks each package into native/build/src/<name>/.

Pass --update-assets to also refresh assets/cacert.pem from the pinned bundle.

Standard library only. No git, no shell.
"""

import argparse
import hashlib
import json
import os
import shutil
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request
from pathlib import Path, PurePosixPath

REPO_ROOT = Path(__file__).resolve().parent.parent
VERSIONS_FILE = REPO_ROOT / "third_party" / "versions.json"
DOWNLOAD_DIR = REPO_ROOT / "native" / "build" / "downloads"
SRC_DIR = REPO_ROOT / "native" / "build" / "src"
MARKER_NAME = ".qfli-source.json"
USER_AGENT = "qfli_git-fetch-sources/1"
CHUNK_SIZE = 1 << 20


class FetchError(Exception):
    pass


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(CHUNK_SIZE), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(url, target):
    """Download url into target, replacing it atomically."""
    print("download %s" % url)
    target.parent.mkdir(parents=True, exist_ok=True)
    handle, temp_name = tempfile.mkstemp(dir=str(target.parent), prefix=".download-")
    try:
        request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        with os.fdopen(handle, "wb") as out:
            with urllib.request.urlopen(request, timeout=120) as response:
                shutil.copyfileobj(response, out, CHUNK_SIZE)
            out.flush()
            os.fsync(out.fileno())
        os.replace(temp_name, target)
    except BaseException:
        if os.path.exists(temp_name):
            os.unlink(temp_name)
        raise


def fetch_archive(entry, force):
    """Return the local archive path for entry, downloading it when needed."""
    archive = DOWNLOAD_DIR / entry["archive"]
    expected = entry["sha256"].lower()

    if archive.exists() and not force:
        actual = sha256_file(archive)
        if actual == expected:
            print("cached   %s" % archive.name)
            return archive
        print("checksum mismatch on cached %s, downloading again" % archive.name)
        archive.unlink()

    try:
        download(entry["url"], archive)
    except urllib.error.URLError as error:
        raise FetchError("cannot download %s: %s" % (entry["url"], error))

    actual = sha256_file(archive)
    if actual != expected:
        archive.unlink()
        raise FetchError(
            "SHA-256 mismatch for %s\n  expected %s\n  actual   %s"
            % (entry["url"], expected, actual)
        )

    print("verified %s sha256=%s" % (archive.name, actual))
    return archive


def _member_target(root, member_name):
    """Map an archive member name to a path inside root, or None to skip."""
    parts = PurePosixPath(member_name.replace("\\", "/")).parts
    if not parts:
        return None
    target = root.joinpath(*parts)
    resolved = os.path.normpath(str(target))
    if not resolved.startswith(str(root) + os.sep) and resolved != str(root):
        raise FetchError("archive member escapes the source directory: %s" % member_name)
    return target


def extract(archive, destination, archive_root):
    """Unpack archive into destination, dropping the single top directory."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(dir=str(destination.parent), prefix=".extract-"))
    skipped = []

    try:
        with tarfile.open(str(archive)) as tar:
            for member in tar:
                relative = member.name
                if archive_root:
                    if relative == archive_root:
                        continue
                    prefix = archive_root + "/"
                    if not relative.startswith(prefix):
                        raise FetchError(
                            "unexpected archive layout: %s has no %s/ prefix"
                            % (archive.name, archive_root)
                        )
                    relative = relative[len(prefix):]
                if not relative:
                    continue

                target = _member_target(staging, relative)
                if target is None:
                    continue

                try:
                    if member.isdir():
                        target.mkdir(parents=True, exist_ok=True)
                    elif member.issym():
                        if os.name == "nt":
                            skipped.append(relative)
                            continue
                        target.parent.mkdir(parents=True, exist_ok=True)
                        if target.is_symlink() or target.exists():
                            target.unlink()
                        target.symlink_to(member.linkname)
                    elif member.islnk():
                        source = _member_target(staging, member.linkname)
                        target.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(str(source), str(target))
                    elif member.isfile():
                        target.parent.mkdir(parents=True, exist_ok=True)
                        source = tar.extractfile(member)
                        with open(target, "wb") as out:
                            shutil.copyfileobj(source, out, CHUNK_SIZE)
                        mode = member.mode & 0o777
                        if mode and os.name != "nt":
                            os.chmod(target, mode or 0o644)
                    else:
                        skipped.append(relative)
                except OSError as error:
                    # Windows rejects a few upstream test fixture names.
                    skipped.append("%s (%s)" % (relative, error.strerror))

        if destination.exists():
            shutil.rmtree(destination)
        os.replace(str(staging), str(destination))
    except BaseException:
        shutil.rmtree(str(staging), ignore_errors=True)
        raise

    if skipped:
        print("skipped %d archive members the filesystem rejected" % len(skipped))


def write_marker(destination, entry):
    marker = destination / MARKER_NAME
    payload = {
        "name": entry["name"],
        "version": entry["version"],
        "sha256": entry["sha256"],
        "url": entry["url"],
    }
    marker.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def source_is_current(destination, entry):
    marker = destination / MARKER_NAME
    if not marker.exists():
        return False
    try:
        payload = json.loads(marker.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    return (
        payload.get("version") == entry["version"]
        and payload.get("sha256") == entry["sha256"]
    )


def update_asset(entry, force):
    archive = fetch_archive(entry, force)
    target = REPO_ROOT / entry["target"]
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(str(archive), str(target))
    copied = sha256_file(target)
    if copied != entry["sha256"].lower():
        raise FetchError("copied %s does not match the pinned SHA-256" % target)
    print("wrote    %s sha256=%s" % (entry["target"], copied))


def load_versions():
    try:
        data = json.loads(VERSIONS_FILE.read_text(encoding="utf-8"))
    except OSError as error:
        raise FetchError("cannot read %s: %s" % (VERSIONS_FILE, error))
    except ValueError as error:
        raise FetchError("%s is not valid JSON: %s" % (VERSIONS_FILE, error))
    return data


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--force", action="store_true", help="download and unpack again")
    parser.add_argument(
        "--update-assets",
        action="store_true",
        help="copy the pinned cacert bundle to assets/cacert.pem",
    )
    parser.add_argument(
        "--name",
        action="append",
        default=[],
        help="limit the work to one package name (repeatable)",
    )
    args = parser.parse_args(argv)

    try:
        data = load_versions()
        DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)
        SRC_DIR.mkdir(parents=True, exist_ok=True)

        sources = data.get("sources", [])
        assets = data.get("assets", [])
        selected = args.name

        for entry in sources:
            if selected and entry["name"] not in selected:
                continue
            destination = SRC_DIR / entry["name"]
            if not args.force and source_is_current(destination, entry):
                print("present  %s %s" % (entry["name"], entry["version"]))
                continue
            archive = fetch_archive(entry, args.force)
            print("unpack   %s -> %s" % (archive.name, destination.relative_to(REPO_ROOT)))
            extract(archive, destination, entry.get("archive_root", ""))
            write_marker(destination, entry)

        if args.update_assets:
            for entry in assets:
                if selected and entry["name"] not in selected:
                    continue
                update_asset(entry, args.force)
    except FetchError as error:
        print("error: %s" % error, file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
