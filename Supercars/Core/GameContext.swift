import Foundation
import SceneKit
import SwiftUI
import Combine
import UIKit

// MARK: - GameContext: owns the scene, all modules and the frame loop; implements the high level game flow.
// Modules attach their own root nodes to `scene.rootNode` inside their build methods.

@MainActor
private final class DisplayLinkProxy: NSObject {
    var onTick: ((CADisplayLink) -> Void)?
    @objc func tick(_ link: CADisplayLink) { onTick?(link) }   // CADisplayLink on .main run loop => always the main thread
}

/// Slow cinematic orbit around the player's house / car for the main menu backdrop.
@MainActor
private final class MenuCameraController: CameraController {
    weak var ctx: GameContext?
    var angle: Float = 0.6
    init(ctx: GameContext) { self.ctx = ctx }
    func updateCamera(_ rig: CameraRig, dt: Float) {
        guard let ctx = ctx, let car = ctx.car else { return }
        angle += dt * 0.12
        let focus = car.state.position + Vec3(0, 0.9, 0)
        let r: Float = 8.0
        let p = focus + Vec3(sinf(angle) * r, 1.6 + 0.5 * sinf(angle * 0.7), cosf(angle) * r)
        rig.fov = 46
        rig.follow(desired: p, lookAt: focus, dt: dt, stiffness: 2.0, maxLag: 30)
    }
}

@MainActor
final class GameContext {
    let scnView: SCNView
    let scene: SCNScene
    let cameraRig = CameraRig()
    let state = GameState()
    let settings = SettingsStore()
    let save = SaveStore()
    let assets = AssetLibrary()
    private(set) var input: InputManager!
    private(set) var audio: AudioManager!
    var world: World!
    var car: PlayerCar!
    var player: PlayerCharacter!
    var house: PlayerHouse!
    var race: RaceManager!
    // living city (all optional: the game still runs if any of them fails to build)
    var wanted: WantedSystem?
    var npcs: NPCManager?
    var traffic: TrafficManager?
    var taxi: TaxiSystem?
    var police: PoliceSystem?
    var nav: NavigationManager?
    var dev: DeveloperMode?

    var sun: SCNNode { return world.sun }

    private let linkProxy = DisplayLinkProxy()
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var fpsAccumulator: Float = 0
    private var fpsFrames: Int = 0
    private var autosaveTimer: Float = 0
    private var menuCamera: MenuCameraController!
    private var cancellables = Set<AnyCancellable>()
    private var booted = false
    private var currentInteractable: Interactable?

    init(view: SCNView) {
        scnView = view
        scene = SCNScene()
        view.scene = scene
        scene.rootNode.addChildNode(cameraRig.node)
        view.pointOfView = cameraRig.node
        view.isPlaying = true
        view.rendersContinuously = true
        view.backgroundColor = UIColor.black
        input = InputManager(ctx: self)
        audio = AudioManager(ctx: self)
        menuCamera = MenuCameraController(ctx: self)
        settings.changed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyGraphics() }
            .store(in: &cancellables)
    }

    // MARK: Boot

    func boot() async {
        if booted { return }
        booted = true
        state.mode = .loading
        state.screen = .none
        applyGraphics()

        state.loadingText = "Building the city…"
        world = World(ctx: self)
        await world.build { [weak self] p, text in
            guard let self = self else { return }
            self.state.loadingProgress = 0.05 + 0.55 * p
            self.state.loadingText = text
        }
        await Task.yield()

        state.loadingText = "Building your house and garage…"
        house = PlayerHouse(ctx: self)
        await house.build(at: world.spawn.house)
        state.loadingProgress = 0.72
        await Task.yield()

        state.loadingText = "Loading the Porsche…"
        car = PlayerCar(ctx: self)
        do { try await car.build() } catch { state.showToast("Car failed to load: \(error.localizedDescription)", seconds: 6) }
        car.apply(config: save.data.car)
        state.loadingProgress = 0.86
        await Task.yield()

        state.loadingText = "Meeting c0derz…"
        player = PlayerCharacter(ctx: self)
        do { try await player.build() } catch { state.showToast("Character failed to load: \(error.localizedDescription)", seconds: 6) }
        state.loadingProgress = 0.94
        await Task.yield()

        state.loadingText = "Warming up the grid…"
        race = RaceManager(ctx: self)
        await race.build()
        state.loadingProgress = 0.96
        await Task.yield()

        state.loadingText = "Bringing the city to life…"
        wanted = WantedSystem(ctx: self)
        let navigation = NavigationManager(ctx: self)
        nav = navigation
        world.registerWaypoints(into: navigation.registry, spawn: world.spawn)
        state.pois = navigation.registry.pointsOfInterest
        let people = NPCManager(ctx: self, layout: world.cityLayout)
        npcs = people
        people.navigator.taxiStops = world.taxiStops
        await people.build()
        state.loadingProgress = 0.98
        await Task.yield()
        let cars = TrafficManager(ctx: self)
        traffic = cars
        await cars.build()
        people.trafficBodies = { [weak cars] in cars?.movingBodies() ?? [] }
        taxi = TaxiSystem(ctx: self, traffic: cars, npcs: people)
        police = PoliceSystem(ctx: self, traffic: cars)
        dev = DeveloperMode(ctx: self)

        world.timeOfDay = save.data.timeOfDay
        state.minimap = world.minimap()
        placeForNewSession()
        state.loadingProgress = 1
        input.startMotion()
        startLoop()
        showMenu()
    }

    private func placeForNewSession() {
        let sp = world.spawn
        car.place(position: sp.car.position, heading: sp.car.heading)
        player.place(position: sp.player.position, heading: sp.player.heading, location: .outside)
        state.location = .outside
        state.money = save.data.money
        state.day = save.data.day
        state.engineName = EngineSpec.spec(save.data.car.engine).name
    }

    private func showMenu() {
        state.mode = .menu
        state.screen = .main
        input.context = .menu
        cameraRig.controller = menuCamera
        audio.setMusic(.menu)
        audio.setAmbience(.suburbDay)
        player.setVisible(true)
    }

    // MARK: Frame loop

    private func startLoop() {
        linkProxy.onTick = { [weak self] link in
            self?.tick(link)
        }
        let link = CADisplayLink(target: linkProxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        let cap = settings.settings.graphics.fpsCap
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: Float(cap), preferred: Float(cap))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTimestamp = link.timestamp
    }

    private func tick(_ link: CADisplayLink) {
        var dt = Float(link.timestamp - lastTimestamp)
        lastTimestamp = link.timestamp
        if dt <= 0 || dt > 0.5 { dt = 1.0 / 60.0 }
        dt = min(dt, 1.0 / 20.0)
        fpsAccumulator += dt
        fpsFrames += 1
        if fpsAccumulator >= 0.5 {
            state.fps = Int((Float(fpsFrames) / fpsAccumulator).rounded())
            fpsAccumulator = 0
            fpsFrames = 0
        }
        update(dt: dt)
    }

    func update(dt: Float) {
        guard state.mode != .loading else { return }
        input.update(dt: dt)
        let s = input.state
        if s.pause { if state.isPaused { resume() } else if state.mode == .onFoot || state.mode == .driving { pause() } }
        if s.map {
            if state.screen == .map { closeMap() } else if state.mode == .onFoot || state.mode == .driving { openMap() }
        }
        if state.isPaused { return }

        switch state.mode {
        case .onFoot:
            player.update(dt: dt)
            scanInteractables(interactPressed: s.interact)
        case .driving:
            if s.cameraToggle { car.cycleView() }
            if s.lights { car.setLights(!state.headlights); state.headlights = !state.headlights }
            drivingInteractions(interactPressed: s.interact)
        case .garage, .menu, .sleeping, .loading:
            break
        }
        car.update(dt: dt)
        if state.mode == .driving, let p = player { p.updateDriving(dt: dt, car: car) }
        if state.mode != .onFoot { setPrompt(state.mode == .driving ? state.prompt : nil) }

        let focus: Vec3 = (state.mode == .onFoot || state.mode == .garage) ? player.node.simdPosition : car.state.position
        world.update(dt: dt, focus: focus)
        house.update(dt: dt)
        race.update(dt: dt)
        let camForward: Vec3 = cameraRig.node.simdWorldFront
        npcs?.update(dt: dt, focus: focus, cameraForward: camForward)
        traffic?.update(dt: dt, focus: focus)
        taxi?.update(dt: dt)
        police?.update(dt: dt)
        wanted?.update(dt: dt, police: police)
        nav?.update(dt: dt)
        cameraRig.update(dt: dt)
        audio.updateListener(position: cameraRig.node.simdPosition, forward: cameraRig.node.simdWorldFront)

        state.timeOfDay = world.timeOfDay
        state.money = save.data.money
        state.day = save.data.day
        state.playerMapPosition = (state.mode == .driving || state.mode == .menu) ? car.state.position.xz : player.node.simdPosition.xz
        state.playerMapHeading = (state.mode == .driving || state.mode == .menu) ? car.state.heading : player.node.simdEulerAngles.y

        save.data.timeOfDay = world.timeOfDay
        save.data.playSeconds += Double(dt)
        autosaveTimer += dt
        if autosaveTimer > 20 { autosaveTimer = 0; savePosition(); save.saveNow() }
    }

    // MARK: Interaction

    private func collectInteractables() -> [Interactable] {
        var list: [Interactable] = house.interactables
        if state.mode == .onFoot, player.location != .house {
            list.append(Interactable(id: "car-door", position: car.driverDoorWorld, radius: 2.4, prompt: "Get in the car", action: { [weak self] in self?.enterCar() }))
        }
        return list
    }

    private func scanInteractables(interactPressed: Bool) {
        let p = player.node.simdPosition
        var best: Interactable?
        var bestD: Float = Float.greatestFiniteMagnitude
        for it in collectInteractables() where it.isEnabled() {
            let d = simd_distance(Vec3(p.x, 0, p.z), Vec3(it.position.x, 0, it.position.z))
            if d <= it.radius && d < bestD { best = it; bestD = d }
        }
        currentInteractable = best
        setPrompt(best?.prompt)
        if interactPressed, let b = best {
            audio.play(.uiTap, volume: 0.6)
            input.haptic(.light)
            b.action()
        }
    }

    private func drivingInteractions(interactPressed: Bool) {
        let gate = world.spawn.raceGate.position
        let carPos = car.state.position
        let nearGate = simd_distance(Vec3(carPos.x, 0, carPos.z), Vec3(gate.x, 0, gate.z)) < 14 && !race.isActive
        if nearGate {
            state.prompt = "Start race (3 laps)"
            if interactPressed { startRace(laps: 3) }
        } else if abs(car.state.speed) < 2.5 && !race.isActive {
            state.prompt = "Get out"
            if interactPressed { exitCar() }
        } else {
            state.prompt = nil
        }
    }

    func setPrompt(_ text: String?) {
        if state.prompt != text { state.prompt = text }
    }

    func toast(_ text: String) { state.showToast(text) }

    // MARK: Mode / flow

    func setMode(_ m: GameMode) {
        state.mode = m
        switch m {
        case .onFoot: input.context = .onFoot; cameraRig.controller = player
        case .driving: input.context = .driving; cameraRig.controller = car
        case .garage: input.context = .menu; cameraRig.controller = house
        case .menu, .sleeping, .loading: input.context = .menu
        }
    }

    func startGame(continueSave: Bool) {
        audio.start()
        if !continueSave { save.eraseAll() }
        placeForNewSession()
        world.timeOfDay = save.data.timeOfDay
        car.apply(config: save.data.car)
        state.screen = .none
        state.isPaused = false
        state.race = nil
        setMode(.onFoot)
        audio.setMusic(.drive)
        audio.setAmbience(.suburbDay)
        state.showToast("Welcome home, \(save.data.playerName)")
        // a new game starts with the race already marked: the map, the minimap and the HUD arrow lead the way
        if !continueSave { nav?.setDestination(id: "raceStart") }
    }

    func returnToMenu() {
        if race.isActive { race.stop() }
        wanted?.clear()
        nav?.clear()
        if state.mode == .driving { exitCar() }
        if player.location != .outside { exitHouse() }
        state.isPaused = false
        savePosition()
        save.saveNow()
        showMenu()
    }

    func pause() {
        guard state.mode == .onFoot || state.mode == .driving else { return }
        state.isPaused = true
        state.screen = .pause
    }

    /// full-screen interactive map (pauses the world while it is open)
    func openMap() {
        guard state.mode == .onFoot || state.mode == .driving, state.screen == .none else { return }
        state.isPaused = true
        state.screen = .map
        audio.play(SFX.uiTap, volume: 0.7, rate: 1, position: nil)
    }

    func closeMap() {
        guard state.screen == .map else { return }
        state.isPaused = false
        state.screen = .none
        lastTimestamp = displayLink?.timestamp ?? lastTimestamp
        audio.play(SFX.uiBack, volume: 0.6, rate: 1, position: nil)
    }

    func resume() {
        state.isPaused = false
        state.screen = .none
        lastTimestamp = displayLink?.timestamp ?? lastTimestamp
    }

    func enterCar() {
        guard state.mode == .onFoot else { return }
        car.enter()
        player.beginDriving(car: car)
        setMode(.driving)
        car.view = settings.settings.gameplay.defaultView
        state.view = car.view
        audio.engineStart(type: car.config.engine)
        audio.play(.carDoorClose)
        audio.setMusic(.drive)
        setPrompt(nil)
        state.location = .outside
    }

    func exitCar() {
        guard state.mode == .driving else { return }
        let spawn = car.exit()
        player.endDriving(exit: spawn)
        setMode(.onFoot)
        audio.engineStop()
        audio.play(.carDoorOpen)
        state.prompt = nil
    }

    func enterHouse() {
        house.enter()
        state.location = player.location
        audio.setAmbience(.houseInterior)
    }

    func exitHouse() {
        house.exit()
        state.location = player.location
        audio.setAmbience(world.timeOfDay > 6 && world.timeOfDay < 19 ? .suburbDay : .suburbNight)
    }

    func sleepInBed() {
        guard state.mode == .onFoot else { return }
        setMode(.sleeping)
        Task { @MainActor in
            await house.sleep()
            save.data.day += 1
            save.saveNow()
            setMode(.onFoot)
            state.showToast("Good morning, \(save.data.playerName) — day \(save.data.day)")
        }
    }

    func openGarage() {
        guard state.mode == .onFoot else { return }
        let spot = house.garage.carSpot
        car.place(position: spot.position, heading: spot.heading)
        house.setGarageLift(up: true)
        player.setVisible(false)
        setMode(.garage)
        state.screen = .garage
        audio.setMusic(.garage)
        audio.setAmbience(.garageInterior)
    }

    func closeGarage() {
        guard state.mode == .garage else { return }
        house.setGarageLift(up: false)
        player.setVisible(true)
        state.screen = .none
        setMode(.onFoot)
        audio.setMusic(.drive)
    }

    func startRace(laps: Int) {
        guard state.mode == .driving, !race.isActive else { return }
        race.start(routeIndex: 0, laps: laps)
        audio.setMusic(.race)
    }

    func stopRace() {
        race.stop()
        audio.setMusic(.drive)
    }

    // MARK: Persistence / graphics

    private func savePosition() {
        guard let car = car, let player = player else { return }
        if state.mode == .driving {
            save.data.lastPosition = SavedPosition(x: car.state.position.x, z: car.state.position.z, heading: car.state.heading, driving: true)
        } else {
            let p = player.node.simdPosition
            save.data.lastPosition = SavedPosition(x: p.x, z: p.z, heading: player.node.simdEulerAngles.y, driving: false)
        }
    }

    func applyGraphics() {
        let g = settings.settings.graphics
        switch g.antialiasing {
        case .none: scnView.antialiasingMode = .none
        case .x2: scnView.antialiasingMode = .multisampling2X
        case .x4: scnView.antialiasingMode = .multisampling4X
        }
        scnView.preferredFramesPerSecond = g.fpsCap
        let native = scnView.window?.screen.scale ?? UIScreen.main.scale
        scnView.contentScaleFactor = native * CGFloat(g.renderScale)
        cameraRig.applyGraphics(g, fovScale: settings.settings.gameplay.fovScale)
        npcs?.applyGraphics(g)
        if let link = displayLink {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: Float(g.fpsCap), preferred: Float(g.fpsCap))
        }
        audio.applySettings()
    }
}
