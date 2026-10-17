// Stops the build with a clear message when a generated file is missing from jakIOS/Generated/.
// Those files (AOT-compiled GOAL code, link tables, the runtime-state patch, the extractor config) are built from
// OpenGOAL's goal_src and the player's own disc and are never committed (see OPEN_GOAL_IOS_PORT.md).
// Keep this list in sync with what the target loads from the bundle, what Jak1AOTSignedImage.s embeds and
// what tools/release/build.sh writes.
// Note: absent files are not build dependencies, so an incremental build only notices a deletion after a clean.

#if !__has_include("../Generated/Jak1AOTImagePayload.bin")
#error "Missing jakIOS/Generated/Jak1AOTImagePayload.bin: build the files in jakIOS/Generated/ (see OPEN_GOAL_IOS_PORT.md)"
#endif
#if !__has_include("../Generated/Jak1AOTBootstrap.bin")
#error "Missing jakIOS/Generated/Jak1AOTBootstrap.bin: build the files in jakIOS/Generated/ (see OPEN_GOAL_IOS_PORT.md)"
#endif
#if !__has_include("../Generated/Jak1AOTBootstrapManifest.json")
#error "Missing jakIOS/Generated/Jak1AOTBootstrapManifest.json: build the files in jakIOS/Generated/ (see OPEN_GOAL_IOS_PORT.md)"
#endif
#if !__has_include("../Generated/Jak1AOTCodeRanges.bin")
#error "Missing jakIOS/Generated/Jak1AOTCodeRanges.bin: build the files in jakIOS/Generated/ (see OPEN_GOAL_IOS_PORT.md)"
#endif
#if !__has_include("../Generated/Jak1AOTKernelEntry.json")
#error "Missing jakIOS/Generated/Jak1AOTKernelEntry.json: build the files in jakIOS/Generated/ (see OPEN_GOAL_IOS_PORT.md)"
#endif
#if !__has_include("../Generated/Jak1AOTRuntimeState.xd3")
#error "Missing jakIOS/Generated/Jak1AOTRuntimeState.xd3: build the files in jakIOS/Generated/ (see OPEN_GOAL_IOS_PORT.md)"
#endif
#if !__has_include("../Generated/Jak1AOTRuntimeSymbols.json")
#error "Missing jakIOS/Generated/Jak1AOTRuntimeSymbols.json: build the files in jakIOS/Generated/ (see OPEN_GOAL_IOS_PORT.md)"
#endif
#if !__has_include("../Generated/LevelCode/Jak1LevelCode.bin")
#error "Missing jakIOS/Generated/LevelCode/Jak1LevelCode.bin: build the files in jakIOS/Generated/ (see OPEN_GOAL_IOS_PORT.md)"
#endif
#if !__has_include("../Generated/LevelCode/Jak1LevelCodeManifest.json")
#error "Missing jakIOS/Generated/LevelCode/Jak1LevelCodeManifest.json: build the files in jakIOS/Generated/ (see OPEN_GOAL_IOS_PORT.md)"
#endif
#if !__has_include("../Generated/Jak1ExtractorConfig.pack")
#error "Missing jakIOS/Generated/Jak1ExtractorConfig.pack: build the files in jakIOS/Generated/ (see OPEN_GOAL_IOS_PORT.md)"
#endif
