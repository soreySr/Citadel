#!/usr/bin/env python3
"""Writes OpenGOAL/goal_src/jak1/pc/ios/ios-forgotten-engine.gc: The Forgotten Lands' engine changes as boot-time
overrides (forgotten-lands-plan.md).

The mod's edits were three-way merged into our engine sources (base: upstream e656ef94, the mod's last upstream
merge). Those engine objects are captured in the signed image, so the changed top-level forms listed below are
collected from our merged sources into one startup object instead. Fields the mod added to captured types (target,
control-info, camera-bank) live in *ios-tfl-super* (ios-forgotten.gc) instead: the captured code's layouts stay.

Usage (from the repo root): python3 tools/modlevel/forgotten_engine.py
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "OpenGOAL/goal_src/jak1"
OUT = SRC / "pc/ios/ios-forgotten-engine.gc"
# forms that need the mod's shared code's types
# (tfl-hint) or the zoomer's level code types: a second startup object, linked after tfl-lowreskui
LATE = {"pc/subtitle.gc", "pc/hud-classes-pc.gc"}
OUT_LATE = SRC / "pc/ios/ios-forgotten-late.gc"

# (file, form keys); a key is "<def-form> <name>" as forms() reports it ("defstate <state> <type>" for states).
FORMS = [
    ("engine/gfx/sprite/sparticle/sparticle-launcher.gc",
     ["defglobalconstant MAX_LAUNCH_GROUP_SIZE", "defun part-group-pointer?", "define *last-particle-error-log-time*",
      "defun sp-queue-launch", "defun sparticle-track-quat"]),
    ("engine/math/math.gc", ["defun rand-vu-int-range-exclude"]),
    ("engine/game/projectiles-h.gc", ["deftype tfl-yellow-shot", "defglobalconstant SUPER_YELLOW_MAX_CHARGE_TIME", "define-extern tfl-yellow-shot-init-by-other"]),
    ("engine/game/projectiles.gc", None),  # all changed forms (the super yellow shot)
    ("engine/common-obs/collectables-part.gc", None),  # the super eco particles
    ("engine/gfx/mood/weather-part.gc", ["defun update-snow-valley"]),
    ("engine/game/task/hint-control.gc", ["(declare-type tfl-hint process-drawable)", "defun can-hint-be-played?"]),
    ("engine/target/target-util.gc", ["defbehavior can-hands?"]),
    ("engine/target/target.gc", None),
    ("engine/target/target2.gc", None),
    ("engine/target/target-handler.gc", ["defbehavior target-attacked"]),
    ("engine/game/powerups.gc", ["defbehavior target-powerup-process", "defbehavior target-powerup-effect"]),
    ("engine/game/game-info.gc", ["defmethod adjust (this", "defmethod pickup-collectable! (this"]),
    ("engine/common-obs/collectables.gc",
     ["defbehavior add-blue-motion", "defstate pickup eco-collectable", "defstate pickup money",
      "defstate pickup fuel-cell", "defstate pickup buzzer", "defstate vent-wait-for-touch vent"]),
    ("engine/common-obs/crates.gc", None),
    ("engine/common-obs/generic-obs.gc", ["defstate launcher-idle launcher", "defstate launcher-active launcher"]),
    ("engine/common-obs/nav-enemy.gc",
     ["define-extern freeze", "defbehavior nav-enemy-default-event-handler", "defstate freeze nav-enemy"]),
    ("engine/common-obs/orb-cache.gc", ["defstate orb-cache-top-idle orb-cache-top"]),
    ("engine/common-obs/plat-eco.gc", ["defstate plat-idle plat-eco", "defstate notice-blue plat-eco"]),
    ("engine/common-obs/sharkey.gc", ["defmethod attack-handler (this"]),
    ("engine/ui/hud-classes.gc",
     ["defun part-hud-eco-timer-01-func", "defun part-hud-eco-timer-02-func", "defun part-hud-eco-timer-03-func"]),
    ("engine/nav/navigate.gc", ["defun recursive-inside-poly"]),
    ("engine/gfx/foreground/bones.gc", ["defun draw-bones"]),  # 'texscroll-dist (four Crescent Top actors)
    ("engine/camera/cam-states.gc", ["defbehavior cam-string-code"]),
    ("engine/camera/cam-master.gc", ["defstate cam-master-active camera-master"]),
    ("engine/level/load-boundary.gc", ["defun on-foot?", "defun on-flut?", "defun on-racer?"]),
    ("pc/subtitle.gc", ["defstate subtitle-process subtitle"]),  # the hints' subtitles (commentary cut, below)
    ("pc/hud-classes-pc.gc",
     ["deftype hud-bike-red-boost", "defmacro hud-new-particle", "defmethod init-particles! (this",
      "defmethod set-pos-and-scale (this", "defmethod draw-hud (this", "defmethod hud-update (this",
      "defun activate-hud-pc"]),
]


def drop_forms(text: str, starts: list) -> str:
    """Removes every balanced form that begins with one of `starts` (the mod's developer commentary branches)."""
    for start in starts:
        while start in text:
            a = text.index(start)
            depth, i = 0, a
            while True:
                if text[i] == "(":
                    depth += 1
                elif text[i] == ")":
                    depth -= 1
                    if depth == 0:
                        break
                i += 1
            text = text[:a] + text[i + 1:]
    return text


COMMENTARY = ["(*tfl-commentary-semaphore*", "(((pc-subtitle-channel tfl-commentary))",
              "(= (-> self cur-channel) (pc-subtitle-channel tfl-commentary))"]

# Fields the mod added to captured types -> *ios-tfl-super* (ios-forgotten.gc).
REWRITES = [
    (r"\(-> ([^()]+?|\([^()]*\)) control (super-yellow-[a-z-]+)\)", r"(-> *ios-tfl-super* \2)"),
    (r"\(set! \(-> (?!\*ios-tfl-super\*)([^()]+?) super-yellow-charge-loop\)", r"(set! (-> *ios-tfl-super* charge-loop-sound)"),
    (r"\(set! \(-> (?!\*ios-tfl-super\*)([^()]+?) super-yellow-charge-part\)", r"(set! (-> *ios-tfl-super* charge-part)"),
    (r"\(-> (?!\*ios-tfl-super\*)([^()]+?) super-yellow-charge-loop\)", r"(ios-tfl-charge-loop-sound)"),
    (r"\(-> (?!\*ios-tfl-super\*)([^()]+?) super-yellow-charge-part\)", r"(ios-tfl-charge-part)"),
    (r"\(-> \*CAMERA-bank\* default-track-speed\)", r"(-> *ios-tfl-super* track-speed)"),
    (r"\(-> \*hud-parts-pc\* bike-red-boost\)", r"*ios-tfl-red-boost-hud*"),
    # draw-bones: processes without an entity (Jak, the HUD, ...) have no lumps
    (r"\(res-lump-float \(-> arg0 process entity\) 'texscroll-dist :default 0\.0\)",
     r"(if (and (-> arg0 process) (-> arg0 process entity)) (res-lump-float (-> arg0 process entity) 'texscroll-dist :default 0.0) 0.0)"),
    (r"\(-> \*CAMERA-bank\* default-track-accel\)", r"(-> *ios-tfl-super* track-accel)"),
]


def rewrite(text: str) -> str:
    for pattern, repl in REWRITES:
        text = re.sub(pattern, repl, text)
    return text


def main() -> int:
    sys.path.insert(0, "/tmp/tfl-dev")
    from changed_forms import changed  # noqa: E402  (dev helper: forms that differ from the pre-merge sources)

    out = [";;-*-Lisp-*-", "(in-package goal)", "",
           ";; name: ios-forgotten-engine.gc", ";; name in dgo: ios-forgotten-engine", ";; dgos: none (iOS startup object)",
           "", ";; GENERATED by tools/modlevel/forgotten_engine.py from the merged engine sources: do not edit here.",
           ";; The Forgotten Lands' changes to captured engine objects (super eco, the super yellow shot, the custom camera",
           ";; events, load boundary flags...), as overrides. Linked after ios-forgotten (its *ios-tfl-super* side table).", ""]
    late = [";;-*-Lisp-*-", "(in-package goal)", "",
            ";; name: ios-forgotten-late.gc", ";; name in dgo: ios-forgotten-late", ";; dgos: none (iOS startup object)",
            "", ";; GENERATED by tools/modlevel/forgotten_engine.py from the merged engine sources: do not edit here.",
            ";; The Forgotten Lands' changes that need its shared code (tfl-hint.gc): the subtitle process, so its voice-acted",
            ";; hints show their lines (subtitle files rebuilt with the mod's hint entries, Runtime/PCText/*SUBTIT.TXT), and",
            ";; the zoomer's super red eco boost HUD (in *ios-tfl-red-boost-hud*: *hud-parts-pc* has room for one part).",
            ";; Linked after tfl-lowreskui (LAST).", ""]
    for rel, keys in FORMS:
        target = late if rel in LATE else out
        found = {k: f for k, t, f in changed(rel)}
        # the file's new forward declarations always come along
        decls = [k for k in found if k.startswith(("define-extern", "defun-extern", "(declare-type"))]
        missing = [k for k in (keys or []) if k not in found]
        if missing:
            raise SystemExit(f"{rel}: no changed forms {missing} (have: {list(found)})")
        wanted = list(found) if keys is None else [k for k in found if k in decls or k in keys]  # the file's order
        target.append(f";; ---- {rel} " + "-" * max(0, 100 - len(rel)))
        for k in wanted:
            if k not in found:
                raise SystemExit(f"{rel}: no changed form {k!r} (have: {list(found)})")
            form = found[k]
            if k == "defmethod pickup-collectable! (this":
                # the bottom of the pickup chain (ios-green-eco.gc / ios-open-ocean.gc wrap it): a function
                form = form.replace("(defmethod pickup-collectable! ((this fact-info-target)",
                                    "(defun ios-tfl-pickup-collectable ((this fact-info-target)", 1)
            if "tfl-commentary" in form:
                form = drop_forms(form, COMMENTARY)
            target.append(rewrite(form))
            target.append("")
    out.append(";; the TFL pickup under ios-green-eco's and ios-open-ocean's wrappers")
    out.append("(set! *ios-green-eco-stock-pickup* ios-tfl-pickup-collectable)")
    OUT.write_text("\n".join(out) + "\n")
    OUT_LATE.write_text("\n".join(late) + "\n")
    print(f"wrote {OUT} ({len(out)} lines)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
