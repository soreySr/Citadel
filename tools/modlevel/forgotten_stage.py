#!/usr/bin/env python3
"""Stages The Forgotten Lands' level descriptions for the import (jakIOS/ModLevels/Forgotten).

Usage (from the repo root): python3 tools/modlevel/forgotten_stage.py <mod checkout> [output dir]
Writes <level>.jsonc and <level>.gd next to the packed glbs (forgotten-lands-plan.md):
  * the mod's tasks 116-149 are ours 151-184 (Glacier / Brume hold 116-150): numeric game_task / alt-task moved up
    by 35 (symbolic "(game-task name)" values resolve through all-types, which has the mod's names);
  * the developer commentary nodes and the replaced title screen (tfl-logo, camera-start, tfl-title-logo) are left
    out: the user's choice, 2026-10-28;
  * the mod keeps the zoomer in GAME.CGO; here its code and art go into the DGOs of the levels that use it, and the
    super eco crystals' / low-res Kui's art (GAME.CGO in the mod) into the DGOs that place them.
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "jakIOS/ModLevels/Forgotten"
LEVELS = ["crystal-cave", "crescent-top", "energy-bay", "open-mines", "valley"]
TASK_FIRST, TASK_LAST, TASK_SHIFT = 116, 149, 35
DROPPED_ETYPES = {"tfl-commentary-node", "tfl-logo", "camera-start"}
DROPPED_MODELS = {"tfl-title-logo"}
DROPPED_GD = {"tfl-title-obs.o", "tfl-title-logo-ag.go", "tfl-title-cam-ag.go", "logo-ag.go", "logo-black-ag.go",
              "logo-cam-ag.go", "logo-volumes-ag.go", "ndi-ag.go", "ndi-cam-ag.go", "ndi-volumes-ag.go"}
# GAME.CGO in the mod (dgos/game.gd), in its order
RACER_CODE = ["target-racer-h.o", "racer-part.o", "racer.o", "target-racer.o", "racer-states.o",
              "collide-reaction-racer.o"]
RACER_ART = ["racer-ag.go", "eichar-racer+0-ag.go", "tpage-1119.go"]
CRYSTAL_ART = ["tfl-crystal-green-ag.go", "tfl-crystal-red-ag.go", "tfl-crystal-blue-ag.go", "tfl-crystal-yellow-ag.go"]
KUI_ART = ["tfl-lowreskui-ag.go"]


def strip_comments(text: str) -> str:
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:j + 1])
            i = j + 1
        elif text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
        elif text.startswith("/*", i):
            i = text.index("*/", i) + 2
        else:
            out.append(c)
            i += 1
    return re.sub(r",(\s*[\]}])", r"\1", "".join(out))


def shift_task(value):
    if isinstance(value, int) and TASK_FIRST <= value <= TASK_LAST:
        return value + TASK_SHIFT
    return value


def stage_jsonc(src: Path, dst: Path) -> set:
    level = json.loads(strip_comments(src.read_text()))
    actors = [a for a in level.get("actors", []) if a.get("etype") not in DROPPED_ETYPES]
    for actor in actors:
        actor["game_task"] = shift_task(actor.get("game_task", 0))
        lump = actor.get("lump", {})
        if "alt-task" in lump and isinstance(lump["alt-task"], list):
            lump["alt-task"] = [lump["alt-task"][0]] + [shift_task(v) for v in lump["alt-task"][1:]]
    level["actors"] = actors
    level["custom_models"] = [m for m in level.get("custom_models", []) if m not in DROPPED_MODELS]
    dst.write_text(json.dumps(level, indent=1) + "\n")
    return {a.get("etype") for a in actors}


def stage_gd(src: Path, dst: Path, etypes: set) -> None:
    text = src.read_text()
    header = "".join(line + "\n" for line in text.splitlines() if line.startswith(";;"))
    body = strip_gd_comments(text)
    dgo = re.search(r'\(\s*"([^"]+)"', body).group(1)
    files = re.findall(r'"([^"]+)"', body)[1:]
    files = [f for f in files if f not in DROPPED_GD]
    code = [f for f in files if f.endswith(".o")]
    art = [f for f in files if not f.endswith(".o")]
    bsp = art.pop()  # the level's own bsp last
    if "racer" in etypes or "tfl-race-ring" in etypes or dst.stem == "valley":
        code = [f for f in RACER_CODE if f not in code] + code
        art += [f for f in RACER_ART if f not in art]
    if "super-eco-crystal" in etypes:
        art += [f for f in CRYSTAL_ART if f not in art]
    if "tfl-lowreskui" in etypes:
        art += [f for f in KUI_ART if f not in art]
    seen = set()
    ordered = [f for f in code + art + [bsp] if not (f in seen or seen.add(f))]
    lines = "\n".join(f'  "{f}"' for f in ordered)
    dst.write_text(f"{header};; staged for the iOS import by tools/modlevel/forgotten_stage.py\n"
                   f'("{dgo}"\n (\n{lines}\n  )\n )\n')


def strip_gd_comments(text: str) -> str:
    return "\n".join(line.split(";", 1)[0] for line in text.splitlines())


def main() -> int:
    mod = Path(sys.argv[1])
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else OUT
    out.mkdir(parents=True, exist_ok=True)
    for name in LEVELS:
        folder = mod / "custom_assets/jak1/levels" / name
        etypes = stage_jsonc(folder / f"{name}.jsonc", out / f"{name}.jsonc")
        gd = next(folder.glob("*.gd"))
        stage_gd(gd, out / f"{name}.gd", etypes)
        print(f"{name}: {gd.name} -> {name}.gd")
    return 0


if __name__ == "__main__":
    sys.exit(main())
