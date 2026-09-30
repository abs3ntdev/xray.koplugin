#!/usr/bin/env python3
"""Build a deterministic, installable ZIP from a committed plugin subtree only."""

import hashlib
from pathlib import PurePosixPath
import re
import subprocess
import sys
import zipfile


ROOT = "xray.koplugin"
# Runtime state is not distributed, even if accidentally committed later.
STATE_DIRS = {
    "__pycache__", "auth", "backup", "backups", "cache", "caches",
    "credentials", "data", "logs", "sessions", "settings", "tokens",
}
SOURCE_TYPES = {
    "assets": {".svg"},
    "certs": {".crt", ".md", ".txt"},
    "languages": {".po"},
    "prompts": {".lua"},
}


def distributable(name):
    path = PurePosixPath(name)
    parts = path.parts
    if len(parts) < 2 or parts[0] != ROOT:
        return False
    if any(part.startswith(".") or part.lower() in STATE_DIRS for part in parts[1:]):
        return False
    if len(parts) == 2:
        # xray_config.lua is the public blank-key template, not user settings.
        return path.name in {"main.lua", "_meta.lua", "localization_xray.lua", "THIRD_PARTY_NOTICES.md"} or (
            path.name.startswith("xray_") and path.suffix == ".lua"
        )
    return len(parts) == 3 and path.suffix in SOURCE_TYPES.get(parts[1], set())


def git(*args):
    return subprocess.check_output(["git", *args])


def main():
    if len(sys.argv) != 3 or not re.fullmatch(r"[0-9a-f]{40}", sys.argv[1]):
        raise SystemExit("Usage: package_release.py <full-commit-sha> <output.zip>")
    sha, output = sys.argv[1:]
    if git("rev-parse", f"{sha}^{{commit}}").decode().strip() != sha:
        raise SystemExit("Expected an exact commit SHA")
    files = {}
    # Inspect pathnames before reading blobs. Never read the working-tree files.
    for entry in git("ls-tree", "-rz", "--full-tree", sha, "--", ROOT).split(b"\0"):
        if not entry:
            continue
        metadata, raw_name = entry.split(b"\t", 1)
        mode, kind, oid = metadata.decode().split()
        name = raw_name.decode("utf-8")
        if not distributable(name):
            print(f"Excluded: {name}")
            continue
        if kind != "blob" or mode not in {"100644", "100755"}:
            raise SystemExit(f"Refusing non-regular plugin file: {name}")
        files[name] = git("cat-file", "blob", oid)
    required = {f"{ROOT}/{name}" for name in ("main.lua", "_meta.lua", "xray_config.lua")}
    if not required <= files.keys():
        raise SystemExit("Missing required Lua entrypoints or public config template")
    # Fixed metadata and no compression make reruns byte-identical across zlib versions.
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_STORED) as archive:
        for name, content in sorted(files.items()):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            archive.writestr(info, content)
    with zipfile.ZipFile(output) as archive:
        if archive.testzip() is not None or set(archive.namelist()) != files.keys():
            raise SystemExit("Archive integrity or path verification failed")
        for name, content in files.items():
            if archive.read(name) != content:
                raise SystemExit(f"Archive differs from committed source: {name}")
    with open(output, "rb") as archive:
        digest = hashlib.file_digest(archive, "sha256").hexdigest()
    print(f"Verified {len(files)} committed files at {sha}: {output} (sha256:{digest})")


if __name__ == "__main__":
    main()
