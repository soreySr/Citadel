#!/usr/bin/env python3
"""Pack the OpenGOAL decompiler config that level extraction reads into one bundle resource.

The app's synchronized Xcode group flattens resource folders, so the extractor's project-relative files
(decompiler/config/jak1/..., goal_src/jak1/build/all_objs.json) ship as jakIOS/Generated/Jak1ExtractorConfig.pack
and are unpacked into a scratch project folder at import (Jak1LevelBuilder.mm). These are OpenGOAL repo
files (no disc data).

Format (little endian): char magic[8] "JAK1CFG\\0", u32 count, then per file
{u16 path length, path (UTF-8, '/'-separated, relative to the OpenGOAL root), u32 size, data}.

Usage (from the repo root): python3 tools/ios_extractor/pack_config.py [output]
"""

from __future__ import annotations

import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OPENGOAL = ROOT / "OpenGOAL"
OUTPUT = ROOT / "jakIOS" / "Generated" / "Jak1ExtractorConfig.pack"
FILES = [
    "decompiler/config/jak1/jak1_config.jsonc",
    "decompiler/config/jak1/all-types.gc",
    "goal_src/jak1/build/all_objs.json",
] + sorted(
    str(path.relative_to(OPENGOAL))
    for path in (OPENGOAL / "decompiler/config/jak1/ntsc_v1").iterdir()
    if path.is_file()
)


def main() -> None:
    output = Path(sys.argv[1]) if len(sys.argv) > 1 else OUTPUT
    out = bytearray(b"JAK1CFG\0" + struct.pack("<I", len(FILES)))
    for name in FILES:
        data = (OPENGOAL / name).read_bytes()
        encoded = name.encode()
        out += struct.pack("<H", len(encoded)) + encoded + struct.pack("<I", len(data)) + data
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(out)
    print(f"Wrote {output} ({len(FILES)} files, {len(out)} bytes)")


if __name__ == "__main__":
    main()
