# arcdemo

Arcaea iOS 6.13.10 sideload dylib for practice.

Repository: <https://github.com/XingChenRS/ArcDemo>

The active branch is intentionally narrow: keep the features that work, keep
the judgement UI as a design surface, and remove failed main-binary surgery from
the build path.

## Scope

Implemented:
- chart speed retime through `Gameplay.update`
- visual speed warp through `gettimeofday`
- basic seek through the in-game music player
- floating UI, plist config, and file logging
- judgement-window UI parameters, saved for the next design pass

Not implemented:
- runtime `__TEXT` patching
- main-binary payload insertion
- alternate privileged-install build variants
- audio speed control
- audio/chart drift correction
- replaying already-judged notes after seek
- scorekeeper or note-state reset experiments

## Code Stack

| Area | File | Notes |
| --- | --- | --- |
| Main tweak | `Tweak.x` | Bootstrap, hooks, UI, config, logging |
| Offsets | `include/ArcOffsets.h` | 6.13.10 runtime offsets and judgement research anchors |
| Fishhook | `fishhook.c`, `include/fishhook.h` | Used for `gettimeofday` visual warp |
| Shared declarations | `AccCommon.h` | Cross-file declarations for tweak/UI helpers |
| Packaging helper | `inject.py` | Copies dylibs and inserts load commands only |
| Build | `Makefile` | Single sideload dylib target |

## Runtime Semantics

Speed has two cooperating parts:
- `gettimeofday` fishhook changes the visual/Cocos time domain.
- `Gameplay.update` vtable swap advances the chart clock at the selected rate.

Seek is intentionally limited:
- `MTP::seekTo(ms, 0)` jumps the music player.
- The chart clock is shifted to the requested display time.
- Already-judged notes do not replay. The game rebuilds those states only when
  entering a fresh gameplay scene, so this branch treats seek as navigation, not
  full gameplay reset.

Judgement parameters are UI/config only today. They are saved as
`judgeMaxMs`, `judgePureMs`, `judgeFarMs`, and `judgeLostMs`, but no active code
applies them to the classifier.

## Config

Settings are stored in `Documents/xrc-arcdemo.plist`.

| Key | Meaning | Default |
| --- | --- | --- |
| `speedKeys` / `speed-N` | Speed preset list | `1.0, 0.8, 0.6, 1.25, 1.5` |
| `rateIndex` | Selected speed preset index | `0` |
| `toast` | Show speed-change toast | `YES` |
| `buttonEnabled` | Floating button visibility | `YES` |
| `judgeMaxMs` | Judgement design parameter, not applied yet | `25` |
| `judgePureMs` | Judgement design parameter, not applied yet | `50` |
| `judgeFarMs` | Judgement design parameter, not applied yet | `100` |
| `judgeLostMs` | Judgement design parameter, not applied yet | `120` |

## Build

```sh
make
```

The build produces `AccDemoArcaea.dylib`. For sideload use, package it with
`libellekit.dylib` and load both from `Arc-mobile.app/Frameworks`.

GitHub Actions builds the same single target on each pushed commit and uploads:
- `libAccDemoArcaea.dylib`
- `libellekit.dylib`

## Injection Helper

`inject.py` expects `ios/Payload/Arc-mobile.app/Arc-mobile` and copies
`libAccDemoArcaea.dylib` plus `libellekit.dylib` into `Frameworks`, then inserts:

- `LC_LOAD_DYLIB @rpath/libAccDemoArcaea.dylib`
- `LC_RPATH @executable_path/Frameworks`

It does not patch gameplay or judgement code in the main binary.

## Next Research

The judgement problem should be approached read-only first:
- verify whether classifier callers are direct `BL` sites or pass through any
  writable dispatch/vtable layer
- look for data-side inputs that influence `dt` before the hardcoded CMP sites
- avoid any design that requires runtime `__TEXT` writes or fragile payload
  insertion into the app binary

## License

GPL-2.0
