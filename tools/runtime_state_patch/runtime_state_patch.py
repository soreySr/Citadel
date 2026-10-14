#!/usr/bin/env python3
"""Ship the captured Jak 1 GOAL arena as an xdelta3 patch against the player's own disc files.

The captured 128 MiB arena (Jak1AOTRuntimeState.bin) holds verbatim copies of disc data (Jak, Daxter, the
title logo, texture pages). The app bundles only Jak1AOTRuntimeState.xd3; OpenGOALRuntimeHost.mm
(LoadValidRuntimeState) rebuilds the arena at boot from the imported disc's SOURCES.

  encode <state.bin> <disc-dir> <out.xd3>   desktop: make the patch from the captured state
  decode <in.xd3> <disc-dir> <out.bin>      desktop: rebuild the packed state (e.g. for level-code relinks)

<disc-dir> is an extracted NTSC v1 disc (CGO/ and DGO/ folders), e.g. OpenGOAL/iso_data/jak1.
Build xd3_tool first (see xd3_tool.c).

Patch file (little endian):
  char magic[8] "JAK1SXD\\0", u32 version 1, u32 decodedSize, u32 decodedCRC32, u32 patchSize,
  u32 encodedSize, u32 sourceCount, then per source {char name[32], u32 size, u32 crc32},
  then raw DEFLATE (RFC 1951) of the xdelta3 patch (patchSize bytes once inflated).
"""

from __future__ import annotations

import argparse
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

MAGIC = b"JAK1SXD\0"
VERSION = 1
HEADER = struct.Struct("<8sIIIIII")
SOURCE = struct.Struct("<32sII")
# The patch source is these disc files concatenated in this order (the objects linked into the captured arena).
SOURCES = ("CGO/KERNEL.CGO", "CGO/ENGINE.CGO", "CGO/GAME.CGO", "DGO/TIT.DGO")
STATE_MAGIC = b"JAK1STA\0"
STATE_HEADER = struct.Struct("<8sIIIII")
STATE_SIZE = 128 * 1024 * 1024
TOOL = Path(__file__).with_name("xd3_tool")


def read_state(path: Path) -> bytes:
    data = path.read_bytes()
    if data[:8] == STATE_MAGIC:
        _, version, decoded, encoded, crc, flags = STATE_HEADER.unpack_from(data)
        state = zlib.decompress(data[STATE_HEADER.size:STATE_HEADER.size + encoded], -15)
        if version != 1 or len(state) != decoded or zlib.crc32(state) != crc:
            raise SystemExit(f"{path}: corrupt packed state")
        return state
    if len(data) != STATE_SIZE:
        raise SystemExit(f"{path}: expected a packed state or a raw {STATE_SIZE}-byte arena")
    return data


def pack_state(state: bytes) -> bytes:
    compressor = zlib.compressobj(level=9, wbits=-15)
    encoded = compressor.compress(state) + compressor.flush()
    return STATE_HEADER.pack(STATE_MAGIC, 1, len(state), len(encoded), zlib.crc32(state), 0) + encoded


def read_sources(disc: Path) -> tuple[bytes, list[tuple[str, int, int]]]:
    blobs, records = [], []
    for name in SOURCES:
        path = disc / name
        if not path.is_file():
            raise SystemExit(f"missing disc file {path}")
        data = path.read_bytes()
        blobs.append(data)
        records.append((name, len(data), zlib.crc32(data)))
    return b"".join(blobs), records


def run_tool(*args: str) -> None:
    if not TOOL.exists():
        raise SystemExit(f"{TOOL} not built (see the build line in xd3_tool.c)")
    subprocess.run([str(TOOL), *args], check=True, stdout=subprocess.DEVNULL)


def encode(state_path: Path, disc: Path, out: Path) -> None:
    state = read_state(state_path)
    source, records = read_sources(disc)
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        (tmp / "source").write_bytes(source)
        (tmp / "target").write_bytes(state)
        run_tool("encode", str(tmp / "source"), str(tmp / "target"), str(tmp / "patch"))
        patch = (tmp / "patch").read_bytes()
        run_tool("decode", str(tmp / "source"), str(tmp / "patch"), str(tmp / "check"), str(len(state)))
        if (tmp / "check").read_bytes() != state:
            raise SystemExit("patch does not reproduce the state")
    compressor = zlib.compressobj(level=9, wbits=-15)
    encoded = compressor.compress(patch) + compressor.flush()
    header = HEADER.pack(MAGIC, VERSION, len(state), zlib.crc32(state), len(patch), len(encoded), len(records))
    sources = b"".join(SOURCE.pack(name.encode(), size, crc) for name, size, crc in records)
    out.write_bytes(header + sources + encoded)
    print(f"Wrote {out}: {len(state)} -> {len(patch)} patch bytes -> {len(encoded)} deflated "
          f"(sources: {', '.join(name for name, _, _ in records)})")


def decode(patch_path: Path, disc: Path, out: Path) -> None:
    data = patch_path.read_bytes()
    magic, version, decoded, crc, patch_size, encoded, count = HEADER.unpack_from(data)
    if magic != MAGIC or version != VERSION:
        raise SystemExit(f"{patch_path}: not a runtime state patch")
    offset = HEADER.size
    source, records = read_sources(disc)
    for index in range(count):
        name, size, source_crc = SOURCE.unpack_from(data, offset)
        offset += SOURCE.size
        name = name.rstrip(b"\0").decode()
        if (name, size, source_crc) != records[index]:
            raise SystemExit(f"{disc / name} does not match the NTSC v1 disc this patch was made from")
    patch = zlib.decompress(data[offset:offset + encoded], -15)
    if len(patch) != patch_size:
        raise SystemExit(f"{patch_path}: corrupt patch")
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        (tmp / "source").write_bytes(source)
        (tmp / "patch").write_bytes(patch)
        run_tool("decode", str(tmp / "source"), str(tmp / "patch"), str(tmp / "state"), str(decoded))
        state = (tmp / "state").read_bytes()
    if len(state) != decoded or zlib.crc32(state) != crc:
        raise SystemExit("decoded state failed its CRC check")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(pack_state(state))
    print(f"Wrote {out} ({len(state)} bytes, CRC32 0x{crc:08x})")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("mode", choices=("encode", "decode"))
    parser.add_argument("input", type=Path)
    parser.add_argument("disc", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    (encode if args.mode == "encode" else decode)(args.input, args.disc, args.output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
