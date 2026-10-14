#!/usr/bin/env python3
"""Release audit: fail if game data from the disc ended up in the app or in the files to be published.

Indexes the player's own extracted disc (and optionally converted level files) as 32-byte windows, then scans
every target file at every byte offset. Copied data shows up as long chains of matching windows; coincidences
as isolated windows, so only spans of at least --min-span bytes count. Matches are attributed by the disc object
they come from:
  code    v3 objects (compiled GOAL code). Their static tables are what OpenGOAL publishes as decompiled source
          in goal_src, so matches here are reported but allowed (the AOT code blobs consist of them).
  data    v2/v4 objects (art groups, textures, level data) and other disc files (audio, text, video).
  level   converted level files (--levels: the PC renderer's .fr3/.fr3z, built from the disc).
Containers are decoded first: .fr3z (LZFSE), .fr3 (zstd), packed and patched runtime states, .gz, .ipa.

Usage (macOS, needs numpy and the zstd CLI):
  python3 tools/release_audit/audit.py --disc OpenGOAL/iso_data/jak1 --levels OpenGOAL/out/jak1/fr3 \\
      --app path/to/jakIOS.app            # a built app or .ipa
  python3 tools/release_audit/audit.py --disc ... --source .   # the files git would publish
Exit status 1 if any file not in allowlist.json has more than --max-bytes of data/level spans.
"""

from __future__ import annotations

import argparse
import ctypes
import fnmatch
import gzip
import json
import os
import struct
import subprocess
import sys
import tempfile
import zipfile
import zlib
from pathlib import Path

import numpy as np

WINDOW = 32
SOURCE_STRIDE_U64 = 8  # index every 64 bytes of the sources; a copy of >= ~96 bytes is always found
P = np.array([0x9E3779B97F4A7C15, 0xC2B2AE3D27D4EB4F, 0x165667B19E3779F9, 0xD6E8FEB86659FD93], dtype=np.uint64)
CODE, DATA, LEVEL = 0, 1, 2
HERE = Path(__file__).resolve().parent


# ---------------------------------------------------------------- hashing

def window_hashes(buf: bytes, stride_u64: int, offset: int = 0, chunk: int = 1 << 20):
    """Hashes of 32-byte windows starting at offset + 8*k*stride_u64, with filler and counters removed."""
    b = buf[offset:]
    n = len(b) // 8
    if n < 4:
        return np.zeros(0, np.uint64), np.zeros(0, np.int64)
    a = np.frombuffer(b[: n * 8], dtype=np.uint64)
    all_idx = np.arange(0, n - 3, stride_u64)
    hashes, positions = [], []
    for start in range(0, len(all_idx), chunk):
        idx = all_idx[start : start + chunk]
        w = [a[idx + k] for k in range(4)]
        keep = ~((w[0] == w[1]) & (w[1] == w[2]) & (w[2] == w[3]))
        # counting sequences (index lists 0,1,2,... or a counter in some field, any constant step) occur in any
        # mesh data and are not content
        for width, shifts in ((0xFFFFFFFF, (0, 32)), (0xFFFF, (0, 16, 32, 48))):
            lanes = np.stack([x >> np.uint64(s) & np.uint64(width) for x in w for s in shifts], 1).astype(np.int64)
            steps = np.diff(lanes, axis=1)
            keep &= ~(np.all(steps == steps[:, :1], axis=1) & (steps[:, 0] != 0))
        # low entropy (mostly zeros / one repeated value): fewer than 6 distinct byte values
        by = np.stack([x >> np.uint64(s) & np.uint64(0xFF) for x in w for s in range(0, 64, 8)], 1).astype(np.uint8)
        by.sort(axis=1)
        keep &= 1 + np.count_nonzero(np.diff(by, axis=1), axis=1) >= 6
        with np.errstate(over="ignore"):
            h = w[0] * P[0] + w[1] * P[1] + w[2] * P[2] + w[3] * P[3]
        hashes.append(h[keep])
        positions.append(offset + idx[keep] * 8)
    return np.concatenate(hashes), np.concatenate(positions)


class Index:
    def __init__(self):
        self.parts: list[tuple[np.ndarray, int]] = []

    def add(self, buf: bytes, category: int):
        h, _ = window_hashes(buf, SOURCE_STRIDE_U64)
        self.parts.append((h, category))

    def finish(self):
        h = np.concatenate([p[0] for p in self.parts]) if self.parts else np.zeros(0, np.uint64)
        c = np.concatenate([np.full(len(p[0]), p[1], np.int8) for p in self.parts]) if self.parts else np.zeros(0, np.int8)
        order = np.argsort(h, kind="stable")
        h, c = h[order], c[order]
        uniq, start, counts = np.unique(h, return_index=True, return_counts=True)
        # a window that also occurs in a data object counts as data
        cat = np.maximum.reduceat(c, start) if len(start) else np.zeros(0, np.int8)
        common = counts > 20  # padding and generic tables
        self.hashes, self.categories = uniq[~common], cat[~common]
        self.parts = []

    def lookup(self, h: np.ndarray):
        if len(self.hashes) == 0:
            return np.zeros(len(h), bool), np.zeros(len(h), np.int8)
        i = np.minimum(np.searchsorted(self.hashes, h), len(self.hashes) - 1)
        found = self.hashes[i] == h
        return found, self.categories[i]


def dgo_objects(data: bytes):
    count = struct.unpack_from("<I", data, 0)[0]
    offset = 64
    for _ in range(count):
        if offset + 64 > len(data):
            return
        size = struct.unpack_from("<I", data, offset)[0]
        name = data[offset + 4 : offset + 64].split(b"\0")[0].decode(errors="replace")
        yield name, data[offset + 64 : offset + 64 + size]
        offset += 64 + size


def build_index(disc: Path, levels: Path | None) -> Index:
    index = Index()
    files = [p for p in disc.rglob("*") if p.is_file()]
    for path in files:
        data = path.read_bytes()
        if path.suffix.upper() in (".DGO", ".CGO"):
            for _, obj in dgo_objects(data):
                version = struct.unpack_from("<H", obj, 8)[0] if len(obj) >= 10 else 0
                index.add(obj, CODE if version == 3 else DATA)
        else:
            index.add(data, DATA)
    if levels is not None:
        for path in sorted(levels.iterdir()):
            if path.suffix in (".fr3", ".fr3z"):
                raw = decode(path, path.read_bytes())
                if raw is not None:
                    index.add(raw, LEVEL)
    index.finish()
    return index


# ---------------------------------------------------------------- containers

_lib = None


def lzfse_decode(data: bytes, size: int) -> bytes | None:
    global _lib
    if _lib is None:
        _lib = ctypes.CDLL("/usr/lib/libcompression.dylib")
    out = ctypes.create_string_buffer(size)
    got = _lib.compression_decode_buffer(out, ctypes.c_size_t(size), data, ctypes.c_size_t(len(data)), None, 0x801)
    return out.raw[:got] if got else None


def decode(path: Path, data: bytes) -> bytes | None:
    """Decoded payload for known containers, else None."""
    try:
        if data[:4] == b"FR3Z" and len(data) > 12:
            return lzfse_decode(data[12:], struct.unpack_from("<Q", data, 4)[0])
        if path.suffix == ".fr3" and len(data) > 8:
            return subprocess.run(["zstd", "-d", "-q", "-c"], input=data[8:], capture_output=True, check=True).stdout
        if data[:8] == b"JAK1STA\0":
            return zlib.decompress(data[28 : 28 + struct.unpack_from("<I", data, 16)[0]], -15)
        if data[:8] == b"JAK1SXD\0":  # runtime state patch: scan the xdelta literals
            count = struct.unpack_from("<I", data, 28)[0]
            encoded = struct.unpack_from("<I", data, 24)[0]
            start = 32 + 40 * count
            return zlib.decompress(data[start : start + encoded], -15)
        if path.suffix == ".gz":
            return gzip.decompress(data)
    except Exception:
        return None
    return None


# ---------------------------------------------------------------- scanning

def scan(buf: bytes, index: Index, min_span: int):
    """Bytes in matching spans >= min_span, per category, and the longest span."""
    positions, cats = [], []
    for shift in range(8):
        h, pos = window_hashes(buf, 1, shift)
        found, cat = index.lookup(h)
        positions.append(pos[found])
        cats.append(cat[found])
    if not positions:
        return {}, 0
    pos = np.concatenate(positions)
    cat = np.concatenate(cats)
    result, longest = {}, 0
    for category in (CODE, DATA, LEVEL):
        p = np.sort(pos[cat == category])
        if len(p) == 0:
            continue
        breaks = np.nonzero(np.diff(p) > 2 * WINDOW)[0]
        starts = np.r_[p[0], p[breaks + 1]]
        ends = np.r_[p[breaks], p[-1]] + WINDOW
        lengths = ends - starts
        result[category] = int(lengths[lengths >= min_span].sum())
        longest = max(longest, int(lengths.max()))
    return result, longest


# ---------------------------------------------------------------- targets

def publishable_files(root: Path, nested_full: bool) -> list[Path]:
    """Files git would publish under root (tracked + untracked, honoring .gitignore). Nested repositories
    (OpenGOAL) contribute only their changes against their own HEAD unless nested_full."""
    def git(cwd: Path, *args: str, git_dir: str | None = None) -> list[str]:
        command = ["git"] + (["--git-dir", git_dir, "--work-tree", str(cwd)] if git_dir else []) + list(args)
        out = subprocess.run(command, cwd=cwd, capture_output=True, text=True, check=True).stdout
        return [line for line in out.split("\0") if line]

    def walk(directory: Path, is_nested: bool) -> list[Path]:
        if (directory / ".git").exists():
            if is_nested and not nested_full:
                names = git(directory, "diff", "--name-only", "-z", "HEAD")
                names += git(directory, "ls-files", "-o", "--exclude-standard", "-z")
            else:
                names = git(directory, "ls-files", "-co", "--exclude-standard", "-z")
            git_dir = None
        else:
            # not a repository yet: ask git what it would add, using a throwaway repository
            git_dir = tempfile.mkdtemp(prefix="audit-git-")
            subprocess.run(["git", "init", "-q", "--bare", git_dir], check=True)
            names = git(directory, "ls-files", "-o", "--exclude-standard", "-z", git_dir=git_dir)
        files = []
        for name in names:
            path = directory / name
            if name.endswith("/") and (path / ".git").exists():
                files += walk(path, True)
            elif path.is_file():
                files.append(path)
            elif path.is_dir() and (path / ".git").exists():
                files += walk(path, True)
        return files

    return walk(root, False)


def expand(targets: list[Path], workdir: Path) -> list[Path]:
    files = []
    for target in targets:
        if target.suffix == ".ipa":
            out = workdir / target.stem
            with zipfile.ZipFile(target) as archive:
                archive.extractall(out)
            files += [p for p in out.rglob("*") if p.is_file()]
        elif target.is_dir():
            files += [p for p in target.rglob("*") if p.is_file()]
        elif target.is_file():
            files.append(target)
    return files


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--disc", type=Path, required=True, help="extracted NTSC v1 disc (CGO/, DGO/, ...)")
    parser.add_argument("--levels", type=Path, help="converted levels (.fr3 / .fr3z) to detect converted data")
    parser.add_argument("--app", type=Path, action="append", default=[], help="built .app, .ipa or folder")
    parser.add_argument("--source", type=Path, help="repository root: scan the files git would publish")
    parser.add_argument("--nested-full", action="store_true", help="also scan unchanged files of nested repos")
    parser.add_argument("--min-span", type=int, default=1024, help="shortest matching span that counts (bytes)")
    parser.add_argument("--max-bytes", type=int, default=16384,
                        help="data/level bytes in spans allowed per file (generic tables and names stay below; "
                             "copied assets measured 260 KB and up)")
    args = parser.parse_args()

    allow = json.loads((HERE / "allowlist.json").read_text())
    print(f"indexing {args.disc}" + (f" and {args.levels}" if args.levels else ""), file=sys.stderr)
    index = build_index(args.disc, args.levels)
    print(f"  {len(index.hashes)} windows", file=sys.stderr)

    with tempfile.TemporaryDirectory() as tmp:
        files = expand(args.app, Path(tmp))
        roots = [(t, t) for t in args.app]
        if args.source:
            source_files = publishable_files(args.source.resolve(), args.nested_full)
            files += source_files
            roots.append((args.source.resolve(), args.source.resolve()))
        print(f"scanning {len(files)} files", file=sys.stderr)
        failures, notes = [], []
        for path in files:
            if path.stat().st_size < WINDOW * 4:
                continue
            data = path.read_bytes()
            buf = decode(path, data) or data
            spans, longest = scan(buf, index, args.min_span)
            bad = spans.get(DATA, 0) + spans.get(LEVEL, 0)
            rel = str(path)
            for root, _ in roots:
                try:
                    rel = str(path.resolve().relative_to(Path(root).resolve()))
                    break
                except ValueError:
                    pass
            allowed = next((a for a in allow if fnmatch.fnmatch(rel, a["path"]) or fnmatch.fnmatch(path.name, a["path"])), None)
            line = (f"{rel}: data {spans.get(DATA, 0) / 1024:.1f} KB, converted levels {spans.get(LEVEL, 0) / 1024:.1f} KB, "
                    f"code tables {spans.get(CODE, 0) / 1024:.1f} KB (longest span {longest} B)")
            if bad > args.max_bytes and allowed is None:
                failures.append(line)
            elif bad > args.max_bytes or allowed is not None or spans.get(CODE, 0) > 0:
                notes.append(line + (f"  [allowed: {allowed['reason']}]" if allowed else ""))

    for line in notes:
        print("note  " + line)
    for line in failures:
        print("FAIL  " + line)
    for item in allow:
        print(f"known {item['path']}: {item['reason']}")
    print(f"{len(files)} files scanned, {len(failures)} with game data" + ("" if failures else " - OK"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
