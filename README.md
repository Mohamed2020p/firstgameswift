# SUPERCARS

A native iOS open-world supercar game by **c0derz**. 100 % Swift (5.9), SceneKit (Metal) for the 3D world, SwiftUI for every menu / HUD / touch control, AVAudioEngine for sound, CoreMotion tilt steering and GameController pad support. No third-party packages, no web view.

* Drive a Porsche 992 GT3 R through a ~3 km x 3 km city, race AI opponents, crash into destructible lamps / trees / signs.
* Walk around as c0derz, get in and out of the car, enter your house, sleep in the bed, open the garage and customise the car (engine V6 to V16, paint, livery, rims, calipers, tint, wing, tyres).
* iPhone (and iPad), iOS 16.0+, landscape only.

> **Status:** this repository was authored on Windows. The Swift code has **never been compiled** by a human-run Xcode yet; it is verified with a tree-sitter based static checker (`tools/check_swift.py`) and line-by-line review. The first Bitrise build may surface compile errors that need fixing.

## Folder map

```
bitrise.yaml                unsigned-IPA workflow (Bitrise)
project.yml                 XcodeGen spec  -> Supercars.xcodeproj
Supercars.xcodeproj/        committed fallback project (written by tools/gen_xcodeproj.py)
Supercars/
  App/                      AppDelegate.swift, GameViewController.swift   (app shell: window, SCNView + SwiftUI host)
  Core/                     shared math, settings, save data, GameState, CameraRig, GameContext (frame loop + game flow)
  Assets/                   GLB loader, AssetLibrary, procedural textures, mesh builders
  World/                    city, roads, sky, props, colliders
  Vehicle/                  physics, PlayerCar, cockpit, customiser, race manager, AI
  Character/                avatar, pose solver / IK, PlayerCharacter
  House/                    player's house + garage, c0derz art
  Audio/                    AudioManager
  Input/                    InputManager (tilt / touch / gamepad / keyboard), touch controls
  UI/                       SwiftUI: RootView, menus, HUD, settings, garage, pause ...
  Resources/                Info.plist, Assets.xcassets, Models/*.glb, Textures/, Data/*.json, Audio/*.m4a
assets_src/                 original GLB files supplied by the author (not shipped in the app)
tools/                      Python tooling (asset pipeline, audio synthesis, project generator, static checkers)
docs/ARCHITECTURE.md        conventions and the exact public API of every module
```

`Models`, `Textures`, `Data` and `Audio` are added to the app as **folder references**, so they appear in the bundle as real directories (`Models/`, `Textures/`, `Data/`, `Audio/`) and `AssetLibrary` loads files with `subdirectory:`.

## Build the IPA on Bitrise (no Mac needed)

1. Push this repository to GitHub / GitLab / Bitbucket.
2. On [bitrise.io](https://bitrise.io) choose **Add new app**, select the repository. When asked for the configuration, choose to use the `bitrise.yaml` that is already in the repository (skip the auto-detected setup).
3. Run the workflow **`build_ipa`** (stack `osx-xcode-26.5.x`, machine `g2.mac.large`).
   * Step 1 tries `brew install xcodegen` and regenerates `Supercars.xcodeproj` from `project.yml`; if XcodeGen is unavailable the committed project is used.
   * Step 2 runs `xcodebuild archive` for the `Supercars` scheme (Release, `generic/platform=iOS`) with code signing disabled and zips the `.app` into `Supercars.ipa`.
4. Download **`Supercars.ipa`** from the build's *Artifacts* tab.

The IPA is **unsigned**. Nothing else is needed on Bitrise (no certificates, no provisioning profiles). To run it on a device:

* install it with **AltStore** or **Sideloadly** (they sign it with your own Apple ID), or
* install it with **TrollStore** (no re-signing), or
* re-sign it yourself with any tool you like (`zsign`, `fastlane sigh` + `resign`, ...).

## Regenerating resources and project files

| What | Command |
| --- | --- |
| Optimised models + JSON data from `assets_src/*.glb` (numpy + Pillow + the Blender 2.79 MCP bridge in `C:lender-claude` for mesh decimation; the optimised results are already committed, so this is only needed to regenerate them) | `python tools/optimize_assets.py` |
| Synthesised sound effects, engine loops, music and ambience (`.m4a`, needs numpy + scipy + ffmpeg) | `python tools/make_audio_all.py` |
| App icon (Pillow + numpy) | `python tools/make_icon.py` |
| Xcode project (run after adding / removing any `.swift` file) | `python tools/gen_xcodeproj.py` |
| Validate the Xcode project structure | `python tools/check_xcodeproj.py` |
| Static Swift syntax + symbol check (tree-sitter) | `python tools/check_swift.py --symbols` |
| Cross-file call-site check (argument labels of project functions / initialisers) | `python tools/check_calls.py` |

XcodeGen (`project.yml`) picks up new files automatically; the fallback project needs `gen_xcodeproj.py` to be re-run and committed.

## Controls

* **Driving:** tilt the phone like a steering wheel (calibrate in Settings), or use the on-screen wheel / left-right buttons. Gas and brake pedals, handbrake, gear up / down, horn, headlights and a camera-view button (chase, close, hood, cockpit, bumper) are on screen. Steering mode, tilt sensitivity, dead zone and range are in Settings, left-handed layout is supported.
* **On foot:** left virtual joystick to move, drag on the right side to look, run button, interact button (doors, bed, garage console, car door ...).
* **Menus:** pause from the HUD; Settings contains graphics presets (Low / Medium / High / Ultra / Custom), controls, audio, gameplay and credits.
* **Gamepads:** MFi / DualShock / DualSense / Xbox controllers and hardware keyboards are read through the GameController framework.
* Progress (money, garage, position, best laps) and settings are saved automatically in the app's Documents folder.

## Known limitations

* Never compiled on the authoring machine (Windows): expect a first round of compile fixes after the first Bitrise run.
* The IPA is unsigned; it cannot be installed on a device without re-signing / TrollStore / AltStore / Sideloadly.
* Performance targets iPhone 12 and newer; use the Low / Medium presets on older devices.
* No iCloud / Game Center; single-player only.

## Credits and attributions

3D models used under **Creative Commons Attribution 4.0** ([CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/)); the models were optimised / decimated for mobile, otherwise unmodified in design:

* **Porsche 992 GT3 R** by Dave Love (Tyler_Dave)
* **bike rider 3d** by Atrikumar Das (ganash3691)
* **Buildings** by Elbolillo
* **Mango Tree** by stealth86

The same list is shown in the game under *Settings -> Credits*.

Game code, procedural textures, sounds and the app icon: (c) c0derz.
