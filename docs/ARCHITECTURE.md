# SUPERCARS — native iOS game (Swift 5.9, SceneKit + SwiftUI + AVAudioEngine + CoreMotion)

Open-world supercar game for iPhone. **100 % native Swift** (no web view). Target iOS 16.0+, iPhone, landscape only.
Rendering: SceneKit (Metal, PBR materials, cascaded sun shadows, HDR + bloom). UI: SwiftUI overlays hosted over the SCNView.
Audio: AVAudioEngine. Input: touch + CoreMotion tilt steering + GameController (MFi/PS/Xbox pads).
Assets: the user's GLB files, optimised by a Python/Blender pipeline (`tools/`), loaded at runtime by our own `GLBLoader` (no third-party packages).

IMPORTANT: this repository is authored on Windows – **nothing here has been compiled**. Every file must therefore be written
to compile the first time: explicit types, simple expressions (split long expressions), no third-party dependencies, only
public Apple APIs available in iOS 16, `import` everything you use, mark UI-touching classes `@MainActor`.
Reviewers will read every file line by line against the Apple SDK API surface.

```
thebestgame/
  bitrise.yaml                       unsigned IPA workflow (user supplied template, renamed)
  project.yml                        XcodeGen spec  -> Supercars.xcodeproj  (generated on Bitrise; committed fallback project too)
  Supercars.xcodeproj/               committed fallback (tools/gen_xcodeproj.py)
  Supercars/
    App/        AppDelegate.swift, GameViewController.swift
    Core/       Math, CarTypes, Sounds, Settings, SaveData, GameState, CameraRig, Interaction, GameContext   (written by the lead — DO NOT edit; ask)
    Assets/     GLBLoader.swift, AssetLibrary.swift, ProceduralTextures.swift, MeshBuilder.swift
    World/      World.swift, City*.swift, Sky.swift, Props.swift, Colliders.swift …
    Vehicle/    VehiclePhysics.swift, PlayerCar.swift, Cockpit.swift, CarCustomizer.swift, RaceManager.swift, AIDriver.swift …
    Character/  Avatar.swift, PoseSolver.swift, PlayerCharacter.swift …
    House/      PlayerHouse.swift, HouseBuilder.swift, Garage*.swift, C0derzArt.swift …
    Audio/      AudioManager.swift
    Input/      InputManager.swift, TouchControls (SwiftUI)
    UI/         Theme.swift, RootView.swift, MainMenuView.swift, SettingsView.swift, HUDView.swift, GarageView.swift, PauseView.swift …
    Resources/  Models/*.glb  Textures/*  Data/*.json  Audio/*.m4a  Assets.xcassets  Info.plist
  assets_src/                        user supplied original GLBs (not shipped)
  tools/                             Python + Blender-MCP asset pipeline, audio synthesis, project generator, static checker
  docs/
```

## Conventions
* **Units** metres/seconds/radians, **Y up**, ground plane XZ, street level y = 0. Use `Vec2/Vec3` (SIMD) from `Core/Math.swift`; convert to SceneKit only through `node.simdPosition / simdEulerAngles / simdOrientation / simdScale`.
* **Heading** `h`: forward = `(sin h, 0, cos h)`, left = `(cos h, 0, -sin h)`; `node.simdEulerAngles.y = h` makes a model authored facing **+Z** face along the heading. Positive steering / yaw rate = turning LEFT.
* **Model space**: cars and the avatar face +Z, +X is their LEFT, feet/tyres on y = 0. The driver sits on the left (+X). SceneKit cameras look down their local −Z.
* Threading: everything game-related runs on the main thread (`@MainActor`); frame loop is a `CADisplayLink` in `GameContext`. Long builds use `async` and `await Task.yield()` between chunks so the loading bar animates.
* No global mutable singletons except `GameContext` (passed as `unowned let ctx`). No `print` spam in per-frame code.
* Don't redefine operators or the helpers from Core/Math.swift (duplicate definitions fail to compile). Prefix private helper types with your module name to avoid name clashes (e.g. `WorldHelper`, `HouseBuilder`).
* Performance budget (iPhone 12 and up, "High"): ≤ 2 M triangles, ≤ 600 draw calls, 60 fps. Flatten static geometry per chunk with `flattenedClone()`, share geometry/materials, use `SCNLevelOfDetail` for trees/props, hide far chunks, cap shadow casters.
* Player name is **c0derz**; the c0derz identity = neon green `#39FF88` + magenta `#FF2BD6` on near-black with `</>` and circuit motifs (`Palette` in Math.swift).
* Attribution (CC-BY-4.0) must appear in Settings → Credits: Porsche 992 GT3 R by Dave Love (Tyler_Dave), bike rider 3d by Atrikumar Das (ganash3691), Buildings by Elbolillo, Mango Tree by stealth86.

## Public APIs (exact signatures — every module implements these; add more if you like but keep these)

### Core (already written): `GameContext`
```swift
@MainActor final class GameContext {
    let scnView: SCNView;  let scene: SCNScene;  let cameraRig: CameraRig
    let state: GameState;  let settings: SettingsStore;  let save: SaveStore
    let assets: AssetLibrary;  let input: InputManager;  let audio: AudioManager
    var world: World!;  var car: PlayerCar!;  var player: PlayerCharacter!;  var house: PlayerHouse!;  var race: RaceManager!
    func toast(_ text: String)                 // HUD toast
    func setPrompt(_ text: String?)            // interaction prompt at the bottom of the screen
    func setMode(_ m: GameMode)
    // high level actions (implemented in GameContext, call them from interactables / UI)
    func startGame(continueSave: Bool);  func returnToMenu();  func pause();  func resume()
    func enterCar();  func exitCar();  func enterHouse();  func exitHouse();  func sleepInBed()
    func openGarage();  func closeGarage();  func startRace(laps: Int);  func stopRace()
    var sun: SCNNode { get }    // the directional light node owned by World (for shadow focus)
}
struct Interactable { let id: String; var position: Vec3; var radius: Float; var prompt: String; var isEnabled: () -> Bool; var action: () -> Void }
```

### `AssetLibrary` (Assets/)
```swift
@MainActor final class AssetLibrary {
    init()
    func model(_ name: String) throws -> SCNNode                 // Resources/Models/<name>.glb ; NEW clone each call; geometry/materials shared; skins re-bound
    func preload(_ names: [String]) async                        // parse + cache without instantiating
    func image(_ name: String) -> UIImage?                       // Resources/Textures/<name>.png|jpg
    func json<T: Decodable>(_ name: String, as type: T.Type) throws -> T   // Resources/Data/<name>.json
    func audioURL(_ name: String) -> URL?                        // Resources/Audio/<name>.m4a
}
enum ProceduralTextures { static func image(size: CGSize, opaque: Bool, draw: (CGContext) -> Void) -> UIImage; … helpers (noise, bricks, windows …) }
final class GLBLoader { static func load(url: URL, options: GLBLoadOptions) throws -> SCNNode }   // glTF 2.0 subset incl. skins, PBR materials, embedded images
```
Model names produced by the pipeline (Resources/Models): `car_player`, `car_ai`, `tree_lod0`, `tree_lod1`, `tree_lod2`, `building_01 … building_10`, `rider`.
JSON in Resources/Data: `car_meta`, `buildings_meta`, `rider_meta`, `tree_meta`.

**car_player.glb node names** (pipeline guarantees; all pivots at their own centre so `simdEulerAngles.x` spins a wheel):
`car` (root) → `body`, `interior` (seats, dash, cage, gauges), `steering_wheel` (pivot at the hub, rotate about its local **Z**), `glass`, `steer_FL`/`steer_FR` (front steering pivots at wheel centres, rotate about Y)
containing `wheel_FL`/`wheel_FR` (tyre+rim+disc; spin about local X) and `brake_FL`/`brake_FR`; rear `wheel_RL`/`wheel_RR`. Materials are named:
`carpaint` (livery texture), `glass`, `rim`, `caliper`, `tyre`, `taillight`, `headlight`, `interior_*`.  `car_meta.json` gives wheelbase, track, wheel radii/pivots,
`driverEye`, `driverHip`, `steeringHub`, `steeringRadius`, `gripLeft/gripRight` (local hand points at 9 and 3 o'clock, wheel angle 0), `doorDriver`, `wing` node names, bounding box, exhaust points.

### `World` (World/)
```swift
enum SurfaceType { case asphalt, sidewalk, grass, dirt, concrete }
struct Spawn { var position: Vec3; var heading: Float }
struct SpawnPoints { var houseDoor: Spawn; var car: Spawn; var player: Spawn; var garageDoor: Spawn; var raceGate: Spawn; var house: Spawn }
struct RaceRoute { var name: String; var points: [Vec2]; var width: Float; var closed: Bool; var length: Float }
enum ColliderKind { case building, wall, lamp, tree, sign, prop, houseWall, barrier }
struct Collider { var id: Int; var kind: ColliderKind; var center: Vec2; var halfExtents: Vec2; var radius: Float; var heading: Float; var destructible: Bool; var height: Float; var mass: Float }
    // radius > 0 => circle collider ; otherwise oriented box (halfExtents in local x (left) / z (forward), rotated by heading)
@MainActor final class ColliderWorld {
    func query(center: Vec2, radius: Float) -> [Collider]              // static + still-standing destructibles only
    func add(_ c: Collider)                                            // used by the house for interior walls
    func remove(id: Int)
    /// A vehicle hit destructible `id` at `speed` m/s moving along `direction` (world XZ). Animates lamp bend / tree topple / sign fall,
    /// plays the sound, spawns debris/dust, removes the collider. Returns the fraction of the car's momentum absorbed (0.15 ... 0.9).
    func strike(id: Int, speed: Float, direction: Vec2) -> Float
}
@MainActor final class World {
    let root: SCNNode;  let colliders: ColliderWorld;  let sun: SCNNode
    private(set) var spawn: SpawnPoints;  private(set) var raceRoutes: [RaceRoute]
    var timeOfDay: Float { get set }                                    // 0 ... 24, updates sun, sky, ambient, lamps, window lights
    init(ctx: GameContext)
    func build(progress: @escaping (Float, String) -> Void) async       // whole city (deterministic seed)
    func update(dt: Float, focus: Vec3)                                 // day cycle, chunk visibility, lamp/window lights, shadow follow
    func surface(at p: Vec2) -> SurfaceType;  func groundHeight(at p: Vec2) -> Float
    func minimap() -> MinimapData
    func setInteriorMode(_ on: Bool)                                    // hides the outdoor city/sky detail while the player is inside the house
    func nearestRoadPoint(to p: Vec2) -> (point: Vec2, heading: Float)? // for traffic/AI
}
```
City content: ~3 km × 3 km, road grid + boulevards + a ring road, downtown high-rises (procedural facades with windows, emissive lit windows at night), mid-rise districts using the user's `building_01…10.glb`, suburb, parks with the user's mango trees (LODs), destructible street lamps, signs, traffic lights, benches, fences, crosswalks and lane markings, sidewalks + curbs, the player's house + garage on a quiet hillside street at the edge, a race gate/plaza, day/night sky with sun, moon, stars, clouds.

### `PlayerCar` (Vehicle/)
```swift
struct VehicleState { var position: Vec3; var heading: Float; var speed: Float /*m/s along heading*/; var velocity: Vec3; var yawRate: Float; var rpm: Float; var gear: Int; var steer: Float; var wheelSpin: Float; var slipRear: Float; var onGround: Bool; var lateralG: Float; var longitudinalG: Float }
@MainActor final class PlayerCar: CameraController {
    let node: SCNNode                       // model root (origin between axles, on the ground, faces +Z)
    private(set) var state: VehicleState
    private(set) var config: CarConfig
    var isOccupied: Bool { get }
    var view: CameraView { get set }        // chase/close/hood/cockpit/bumper
    let cockpit: CockpitRig
    init(ctx: GameContext)
    func build() async throws               // loads car_player, sets up wheels/materials/physics/sounds
    func apply(config: CarConfig)           // engine (mass, power, sound), paint/finish/livery, rims, calipers, tint, wing, tyres
    func place(position: Vec3, heading: Float)     // teleport + zero velocity
    func enter();  func exit() -> Spawn            // exit returns a free spot beside the driver door
    var driverDoorWorld: Vec3 { get }
    func update(dt: Float)                          // physics + visuals + HUD state while mode == .driving (idle physics otherwise)
    func cycleView()
    func setLights(_ on: Bool)
    func updateCamera(_ rig: CameraRig, dt: Float)  // CameraController
    func repair()
}
@MainActor final class CockpitRig {                 // interior view helpers (steering wheel rotates with input; hands follow)
    var wheelAngle: Float { get }                   // radians, + = left turn
    func gripPointsWorld() -> (left: Vec3, right: Vec3)   // where the driver's hands should be on the rim right now
    var seatHipWorld: Vec3 { get };  var eyeWorld: Vec3 { get }
    func pedalPointsWorld() -> (throttle: Vec3, brake: Vec3)
}
@MainActor final class RaceManager {
    init(ctx: GameContext)
    func build() async                       // AI cars (car_ai) ready but hidden
    func start(routeIndex: Int, laps: Int)   // grid placement, countdown, AI, HUD (ctx.state.race)
    func stop();  var isActive: Bool { get }
    func update(dt: Float)
}
```
Physics = Swift port of `C:\blender-claude\game\sim.py` (`Vehicle`, `resolve_walls`, `Bot`, `RailCar`, speed profile) adapted to the conventions above,
with engine specs from `EngineSpec`, tyre compound grip, wing downforce, TC/ABS/stability settings, obstacle collisions through `ColliderWorld`
(hitting a destructible lamp/tree/sign absorbs momentum, shakes camera, plays sounds, `ColliderWorld.strike`), ground surface friction from `World.surface`.

### `PlayerCharacter` (Character/)
```swift
@MainActor final class PlayerCharacter: CameraController {
    let node: SCNNode                                   // avatar root, feet at y = 0, faces +Z
    var location: PlayerLocation { get set }
    init(ctx: GameContext)
    func build() async throws                           // loads rider.glb, finds bones, prepares pose solver
    func place(position: Vec3, heading: Float, location: PlayerLocation)
    func update(dt: Float)                              // on-foot movement (input.state.moveX/moveY/run/lookDX/lookDY), collisions, walk/run/idle animation, interaction search
    func beginDriving(car: PlayerCar)                   // seat pose; arms IK to car.cockpit.gripPointsWorld() every frame (call updateDriving from update)
    func updateDriving(dt: Float, car: PlayerCar)       // called by GameContext every frame while driving (hands + head follow)
    func endDriving(exit: Spawn)                        // stand up beside the door
    func lieInBed(position: Vec3, heading: Float)       // sleeping pose;  func getUpFromBed(position: Vec3, heading: Float)
    func setVisible(_ v: Bool)                          // hidden in cockpit view (only hands/arms shown, see cockpitFirstPerson)
    var cockpitFirstPerson: Bool { get set }            // true: hide head/torso meshes, keep arms+hands
    func updateCamera(_ rig: CameraRig, dt: Float)      // third-person orbit camera (drag to look), or interior-friendly camera in the house
}
```
Animations are procedural (bone-direction pose solver + 2-bone IK): idle (breathing), walk, run, turn-in-place, sit/drive with hands on the wheel, sleep, press/interact, get in/out of the car.
The rider model has 68 Mixamo-named bones, no animation clips and is in T-pose; solve poses by rotating bones so each bone points along a target direction (independent of the bone's local axes).

### `PlayerHouse` (House/)
```swift
struct GarageInfo { var carSpot: Spawn; var liftNode: SCNNode?; var showroomCameraPositions: [Vec3]; var showroomFocus: Vec3 }
@MainActor final class PlayerHouse: CameraController {
    let root: SCNNode
    private(set) var interactables: [Interactable]         // door, bed, garage console, garage door, TV, desk…  (positions in world space, updated when the door state changes)
    private(set) var garage: GarageInfo
    init(ctx: GameContext)
    func build(at spawn: Spawn) async                       // exterior villa + attached garage building + full interior; registers colliders (exterior + interior walls)
    func enter();  func exit()                              // moves the on-foot player through the door; toggles interior lighting / outdoor visibility
    func sleep() async                                      // bed sequence: fade, time -> 07:00 next day, save, fade in
    func update(dt: Float)                                  // door animations, screens, neon flicker, interior lights vs time of day
    func setGarageLift(up: Bool)
    func updateCamera(_ rig: CameraRig, dt: Float)          // garage showroom orbit camera (mode == .garage)
}
```
Design: modern two-storey villa + attached garage (lift, tool wall, tyre rack, neon, epoxy floor), **c0derz design** on feature walls (neon `</>` c0derz graffiti, circuit-board patterns, LED strips), bedroom (bed), living room (sofa, TV), kitchen, bathroom, home office (desk + monitors with scrolling code). Textures are procedural (CoreGraphics).

### `AudioManager` (Audio/)
```swift
@MainActor final class AudioManager {
    init(ctx: GameContext)
    func start()                                                        // configure AVAudioSession + engine (call once after first user tap)
    func play(_ sfx: SFX, volume: Float = 1, rate: Float = 1, position: Vec3? = nil)
    func engineStart(type: EngineType);  func engineStop()
    func updateEngine(rpm: Float, throttle: Float, load: Float, speed: Float)
    func updateTyres(skid: Float, surface: SurfaceType, rumble: Float, wind: Float)
    func setMusic(_ track: MusicTrack?);  func setAmbience(_ track: AmbienceTrack?)
    func updateListener(position: Vec3, forward: Vec3)
    func applySettings()                                                // volumes from ctx.settings
}
```

### `InputManager` + touch UI (Input/)
```swift
struct InputState { var steer: Float; var throttle: Float; var brake: Float; var handbrake: Bool; var shiftUp: Bool; var shiftDown: Bool
                    var moveX: Float; var moveY: Float; var run: Bool; var jump: Bool; var lookDX: Float; var lookDY: Float
                    var interact: Bool; var cameraToggle: Bool; var pause: Bool; var horn: Bool; var lights: Bool }   // edge flags are true for exactly one frame
enum InputContext { case menu, onFoot, driving }
@MainActor final class InputManager: ObservableObject {
    init(ctx: GameContext)
    var state: InputState { get }
    var context: InputContext { get set }
    let touch: TouchInput            // written by SwiftUI touch views (buttons, joystick, wheel, look pad)
    func update(dt: Float)           // merges tilt / touch / gamepad / keyboard into `state`
    func calibrateTilt();  func startMotion();  func stopMotion()
    func haptic(_ kind: HapticKind)
}
```
Tilt steering: CMMotionManager device motion @60 Hz, phone held in landscape like a wheel; roll about the screen normal (handles landscapeLeft/Right), calibrated neutral, `ControlSettings` sensitivity/deadzone/range/smoothing.

### UI (UI/, SwiftUI)
`RootView(ctx)` overlays everything: loading screen, main menu (c0derz-branded, animated), HUD (speedo, rpm ring, gear, minimap, race panel, prompts, toasts, clock, money), touch controls (context-aware), pause menu, full Settings (graphics preset + individual options, controls incl. tilt sliders and calibrate, audio, gameplay, credits), Garage UI (engine V6/V8/V10/V12/V16 with stats and prices, paint colours + finish, livery, rims, calipers, tint, wing, tyres; live preview through `ctx.car.apply(config:)`), race setup/results, sleep fade overlay.
All state comes from `ctx.state`, `ctx.settings`, `ctx.save`; all actions are `ctx.*` methods.

## Assets / pipeline (tools/)
* `tools/optimize_assets.py` (+ Blender 2.79 through `C:\blender-claude\scripts\mcp_cli.py` for decimation) writes `Supercars/Resources/Models/*.glb` (+ Data JSON): car with interior (decimated), 3 tree LODs from `mango_tree.glb`, the 10 buildings split out, rider (textures ≤ 1024).
* `tools/make_audio.py` synthesises all sounds (numpy) and encodes AAC `.m4a` with ffmpeg into `Supercars/Resources/Audio`.
* `tools/gen_xcodeproj.py` writes `Supercars.xcodeproj/project.pbxproj`; `project.yml` is the XcodeGen equivalent used first on Bitrise.
* `tools/check_swift.py` static checker (tree-sitter syntax + cross-file symbol/API sanity) run before every hand-off.

## Additional contract details (lead decisions)
* **Node ownership:** every module attaches its own root node(s) to `ctx.scene.rootNode` inside its `build…` method (World.root, PlayerHouse.root, PlayerCar.node, PlayerCharacter.node, RaceManager's AI cars).
* **Interaction search** is done by `GameContext.scanInteractables` (see Core/GameContext.swift). `PlayerCharacter` only moves/animates; it does not search for interactables.
* `HapticKind` (declared by the Input module): `enum HapticKind { case light, medium, heavy, rigid, soft, success, warning, error }`.
* `RootView` (UI module): `struct RootView: View { init(ctx: GameContext) … }`; the app's `GameViewController` hosts it in a transparent `UIHostingController` above the `SCNView`.
* `TouchInput` (Input module): `final class TouchInput: ObservableObject` with plain fields that SwiftUI touch views write each frame: `steerWheel, leftDown, rightDown, gas, brake, handbrake, moveX, moveY, lookDX, lookDY (accumulated, consumed by InputManager), runHeld, interactTap, cameraTap, shiftUpTap, shiftDownTap, lightsTap, hornHeld, pauseTap`.
* Loading order in `GameContext.boot()`: World → House → Car → Character → Race. A module must not depend on a module built later during its own `build`.
* All modules read settings via `ctx.settings.settings` (struct) and may subscribe to `ctx.settings.changed` (Combine) — apply graphics-dependent things (shadow quality, tree LOD, particles) live.
* Every `SCNNode` that should not cast/receive shadows or be hit-tested should set `castsShadow = false`; use `categoryBitMask` bit 1 = "world static", bit 2 = "car", bit 4 = "character", bit 8 = "interior" so the sun shadow / interior lights can be scoped.

### Data schemas (Resources/Data/*.json — produced by the asset pipeline, consumed by Swift; all lengths in metres, car/avatar local space as in Conventions)
`car_meta.json`
```json
{ "length": 4.77, "width": 2.05, "height": 1.25, "wheelbase": 2.516, "trackFront": 1.68, "trackRear": 1.64,
  "wheelRadiusFront": 0.34, "wheelRadiusRear": 0.352, "frontAxleZ": 1.258, "rearAxleZ": -1.258, "cgZ": -0.126,
  "driverEye": [0.36,0.98,0.05], "driverHip": [0.36,0.55,-0.25], "steeringHub": [0.36,0.83,0.62], "steeringAxis": [0,0.35,-0.94],
  "steeringRadius": 0.17, "gripLeft": [0,0,0], "gripRight": [0,0,0], "doorDriver": [1.05,0.6,0.1],
  "pedalThrottle": [0.36,0.3,0.55], "pedalBrake": [0.27,0.3,0.55], "exhausts": [[0.45,0.4,-2.3]],
  "headlights": [[0.7,0.65,2.2]], "taillights": [[0.6,0.7,-2.3]], "wingNodes": ["wing_gt3","wing_big"] }
```
(`gripLeft/gripRight` are hand points on the rim in **steering_wheel local space** at angle 0 (9 and 3 o'clock); `steeringAxis` = unit vector along the column pointing toward the driver; values above are placeholders — the pipeline writes real ones.)
`buildings_meta.json`  `{ "buildings": [ { "name": "building_01", "size": [w, h, d], "triangles": 240, "hasShops": true, "roofY": h } ] }` — every building GLB has its pivot at the **bottom centre of its footprint**, the street-facing façade toward **+Z**, size = footprint width (x), height (y), depth (z).
`tree_meta.json`   `{ "height": 6.8, "crownRadius": 3.3, "trunkRadius": 0.32, "lods": [ {"name":"tree_lod0","triangles":6000,"maxDistance":45}, {"name":"tree_lod1","triangles":1400,"maxDistance":140}, {"name":"tree_lod2","triangles":60,"maxDistance":1000} ] }` (pivot at the trunk base).
`rider_meta.json`  `{ "height": 1.85, "hipHeight": 0.98, "notes": "T-pose, faces +Z, 68 Mixamo-named bones with numeric suffixes e.g. Hips_66" }`.
