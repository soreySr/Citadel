# Citadel

**Jak and Daxter: The Precursor Legacy running natively on iPhone and iPad.**

Citadel is an iOS port of [OpenGOAL](https://github.com/open-goal/jak-project), the open source
reimplementation of the Jak and Daxter engine. It runs the original game on iOS with touch
controls, game controller support and up to 120 fps.

> **Jak 1 only.** Citadel supports only the first game, *Jak and Daxter: The Precursor Legacy*.
> Jak II and Jak 3 are **not** included or supported.

## Contains no game assets from the original game

This repository and the release IPA **contain no game assets from the original game**: no models,
textures, audio, text, video or level data. You supply your own copy of the game. On first launch
you import an ISO image of the **US (NTSC) PlayStation 2 release** of *Jak and Daxter: The
Precursor Legacy*, and the app extracts and builds everything it needs on the device.

Before every release, `tools/release_audit/audit.py` scans the source tree and the built app
byte by byte against the disc, to make sure no game data ends up in either.

## Installing

1. Download `Citadel.ipa` from the [Releases](../../releases) page.
2. Install it with [SideStore](https://sidestore.io), AltStore, Sideloadly or any other
   sideloading method you like. The IPA is unsigned and needs **no special entitlements**, so
   any free or paid Apple ID signing method works.
3. Open Citadel, tap **IMPORT ISO** and choose your US Jak and Daxter ISO from the Files app.
   The first import extracts the disc and builds the levels on the device, which takes a few
   minutes. After that the game starts straight from the title screen.

Requires iOS / iPadOS 18.6 or later.

## Features

- Full game playable from start to finish, 100% completion tested
- Touch controls: floating joysticks, swipe camera, pressure-sensitive buttons and tap/swipe menus
- Bluetooth game controller support (Xbox, PlayStation, MFi) and haptic feedback
- 60 and 120 fps modes, widescreen and any aspect ratio, HUD laid out for modern phones
- Mirror mode per save file (unlocked by beating the game)
- English subtitles and the OpenGOAL text translations

## Experimental features

Found under **Options > Experimental Options** on the title screen. These are new additions to the
game, not part of the original. **They are experimental: expect bugs, and they are subject to
change or removal in future updates.** Turn them off if something goes wrong.

| Option | What it does |
| --- | --- |
| Driveable Boat | Drive the fisherman's boat around the ocean yourself. Dock pads at Sandover and Rock Village summon it. |
| Dynamic Save Points | Saving and loading put you back exactly where you saved, instead of at the last checkpoint. |
| Expanded Flut Flut Spawning | Ride the Flut Flut outside its original areas, starting from a spawner near the Sage's hut. |
| Expanded Green Eco | Green eco charges up on foot, slowly regenerates health and grants brief invulnerability. Adds extra green eco vents. |
| Fish in Ocean | Adds swimming fish to the open ocean. |

**Coming in a future update:** custom levels.

## How the port works

Jak and Daxter was written in GOAL, Naughty Dog's own Lisp dialect. OpenGOAL decompiled the game's
code back into GOAL source (`OpenGOAL/goal_src`) and rebuilt the engine in C++ with a modern
compiler, renderer and audio system. On PC, OpenGOAL compiles and loads that code at runtime.

iOS does not let apps generate executable code at runtime, so Citadel works differently:

- **Ahead-of-time compiled GOAL.** OpenGOAL's ARM64 compiler and linker run on the Mac at build
  time. Every GOAL code segment is linked in advance and emitted into the app binary, so Xcode
  signs it like any other code. A separate writable image holds the initial symbol table, type
  graph and heaps, and is validated before the kernel starts.
- **Game state built on the device.** Data that would come from the disc is never shipped. The app
  rebuilds its startup state from a small binary patch applied to your disc's own files, and
  OpenGOAL's level extractor (built as a static iOS library) converts every level on the device
  during import.
- **Metal renderer.** OpenGOAL's OpenGL renderers (TFrag, TIE, Shrub, Merc, Generic, sprites,
  ocean, shadows, sky and more) are ported to Metal.
- **Audio.** OpenGOAL's 989snd sound engine and the Jak 1 overlord are ported, with streamed
  dialogue and music on AVAudioEngine.
- **iOS host layer.** SwiftUI and UIKit handle the launcher, ISO import, touch controls, game
  controllers, menus and HUD layout, which communicate with the GOAL runtime through native hooks.

The OpenGOAL source is included in `OpenGOAL/` with the changes needed for iOS. It is based on
upstream revision `efb21c3e` (see `OpenGOALUpstream.lock.json`).

## Building from source

Needs a Mac with Xcode, CMake and Ninja.

1. Build OpenGOAL's level extractor as static libraries:
   `sh tools/ios_extractor/build.sh`
2. Open `jakIOS.xcodeproj`, set your own development team under Signing & Capabilities, and build
   the `jakIOS` target for your device.

See [OPEN_GOAL_IOS_PORT.md](OPEN_GOAL_IOS_PORT.md) for details on the runtime, relinking level code
and the release audit.

## Credits

- **[OpenGOAL](https://github.com/open-goal/jak-project)**: the OpenGOAL Team and contributors, whose
  decompilation, compiler and engine this port is built on.
- **[Ottselesque](https://chriskirknielsen.com/fonts/ottselesque/)** font by Christopher Kirk-Nielsen.
- **Naughty Dog**, for creating Jak and Daxter.
- This port was developed with the help of the AI coding assistants **Claude** (Anthropic) and
  **Codex** (OpenAI).

## Licence

ISC, the same as OpenGOAL. See [LICENSE](LICENSE). The OpenGOAL code keeps its own copyright
notice in `OpenGOAL/LICENSE`.

*Jak and Daxter is a trademark of Sony Interactive Entertainment LLC. This project is not
affiliated with or endorsed by Sony Interactive Entertainment or Naughty Dog. Please support the
official releases.*
