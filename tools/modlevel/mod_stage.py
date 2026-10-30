#!/usr/bin/env python3
"""Stages Glacier's and Brume Village's level descriptions for the import (glacier-plan.md, brume-plan.md).

Usage (from the repo root): python3 tools/modlevel/mod_stage.py glacier|brume <mod checkout> <output dir>
Copies the mod's <level>.jsonc / <level>.gd and applies our changes:
  * glacier.jsonc: "ios_offset", where the app places the level (east of the coast, halfway from Sandover to Rock
    Village; level-info.gc, entity.gc, fishermans-boat.gc and ios-open-ocean.gc follow it);
  * brume.jsonc: the mod's numeric alt-task 121 is 128 here (Glacier holds 116-121, tasks moved up by 7);
  * brume.gd: test-actor-ag.go and brumesteamcap-ag.go are left out (no level places them).
The Forgotten Lands has its own script (forgotten_stage.py).
"""

import shutil
import sys
from pathlib import Path

GLACIER_OFFSET = '''  // iOS (Jak1ModLevelBuilder.cpp): where the app places the level, as an offset (meters) from where the mod has it
  // (north of Misty, centre 0 / 1750). User 2026-10-27: east of the coast, halfway from Sandover to Rock Village
  // (centre 1050 / -800). The GOAL side follows it: level-info.gc glacier continues + bsphere, entity.gc nav meshes,
  // fishermans-boat.gc IOS_SEA_GLACIER_*, ios-open-ocean.gc zone 8 / ios-ocean-in-glacier?.
  "ios_offset": [1050.0, 0.0, -2550.0],
'''
BRUME_LEVELS = ["brume", "abandon", "mount", "preundg"]


def replace_once(text: str, old: str, new: str, what: str) -> str:
    if text.count(old) != 1:
        sys.exit(f"error: {what}: expected one {old!r} in the mod's file (did the mod change?)")
    return text.replace(old, new)


def stage_glacier(mod: Path, out: Path) -> None:
    src = mod / "custom_assets/jak1/levels/glacier"
    text = (src / "glacier.jsonc").read_text()
    anchor = '  "nickname": "gla", // 3 char name, all lowercase\n'
    (out / "glacier.jsonc").write_text(replace_once(text, anchor, anchor + GLACIER_OFFSET, "glacier.jsonc"))
    shutil.copyfile(src / "glacier.gd", out / "glacier.gd")


def stage_brume(mod: Path, out: Path) -> None:
    for level in BRUME_LEVELS:
        src = mod / "custom_assets/jak1/levels" / level
        jsonc = (src / f"{level}.jsonc").read_text()
        gd = (src / f"{level}.gd").read_text()
        if level == "brume":
            jsonc = replace_once(jsonc, '"alt-task": ["int32", 121]', '"alt-task": ["int32", 128]', "brume.jsonc")
            for art in ("test-actor-ag.go", "brumesteamcap-ag.go"):
                gd = replace_once(gd, f'  "{art}"\n', "", "brume.gd")
        (out / f"{level}.jsonc").write_text(jsonc)
        (out / f"{level}.gd").write_text(gd)


def main() -> int:
    if len(sys.argv) != 4 or sys.argv[1] not in ("glacier", "brume"):
        print(__doc__)
        return 2
    mod, out = Path(sys.argv[2]), Path(sys.argv[3])
    out.mkdir(parents=True, exist_ok=True)
    (stage_glacier if sys.argv[1] == "glacier" else stage_brume)(mod, out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
