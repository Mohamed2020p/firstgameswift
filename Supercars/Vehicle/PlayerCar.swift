import Foundation
import SceneKit
import simd
import UIKit

// MARK: - Public state

struct VehicleState {
    var position: Vec3 = Vec3(0, 0, 0)      // model origin (between the axles, on the ground)
    var heading: Float = 0
    var speed: Float = 0                    // m/s along the heading (negative = reversing)
    var velocity: Vec3 = Vec3(0, 0, 0)      // world velocity
    var yawRate: Float = 0
    var rpm: Float = 1000
    var gear: Int = 1                       // -1 reverse
    var steer: Float = 0                    // smoothed steering input actually applied, + = left
    var wheelSpin: Float = 0                // 0...1 excess drive force at the rear wheels (burnout / wheelspin)
    var slipRear: Float = 0                 // rear slip angle (rad)
    var onGround: Bool = true
    var lateralG: Float = 0                 // + = accelerating to the left
    var longitudinalG: Float = 0            // + = accelerating forward
}

enum VehicleSurface {
    static func grip(_ s: SurfaceType) -> (mu: Float, drag: Float) {
        switch s {
        case .asphalt: return (1.0, 0.0)
        case .concrete: return (0.95, 0.0)
        case .sidewalk: return (0.6, 0.8)
        case .grass: return (0.45, 3.0)
        default: return (0.55, 2.0)
        }
    }

    static func isHard(_ s: SurfaceType) -> Bool {
        switch s {
        case .asphalt, .concrete: return true
        default: return false
        }
    }
}

// MARK: - The player's car

@MainActor
final class PlayerCar: CameraController {
    private unowned let ctx: GameContext

    let node: SCNNode = SCNNode()
    private(set) var state: VehicleState = VehicleState()
    private(set) var config: CarConfig
    private(set) var isOccupied: Bool = false
    let cockpit: CockpitRig = CockpitRig()

    var view: CameraView = .chase {
        didSet { viewChanged() }
    }

    /// set by RaceManager: forced controls (countdown / after the finish) and a hard hold (no movement)
    var controlOverride: VehicleControls? = nil
    var holdBrake: Bool = false

    var engineSpec: EngineSpec { return EngineSpec.spec(config.engine) }

    // physics
    private let physics: VehiclePhysics = VehiclePhysics()
    private let solver: VehicleCollisionSolver = VehicleCollisionSolver()
    private let fixedStep: Float = 1.0 / 240.0
    private var acc: Float = 0
    private var prevX: Float = 0
    private var prevZ: Float = 0
    private var prevH: Float = 0
    private var lastGoodX: Float = 0
    private var lastGoodZ: Float = 0
    private var lastGoodH: Float = 0
    private var poseDirty: Bool = true
    private var idleTimer: Float = 0

    // model
    private var rig: CarVisualRig? = nil
    private var customizer: CarCustomizer? = nil
    private var effects: VehicleEffects? = nil
    private var built: Bool = false
    private var usingPlaceholder: Bool = false
    private var lightNodes: [SCNNode] = []
    private var hoodAnchor: SCNNode? = nil
    private var bumperAnchor: SCNNode? = nil
    private var lightsOn: Bool = false

    // meta
    private var wheelRadiusFront: Float = 0.34
    private var wheelRadiusRear: Float = 0.352
    private var frontAxleZ: Float = 1.258
    private var rearAxleZ: Float = -1.258
    private var trackFront: Float = 1.68
    private var trackRear: Float = 1.64
    private var cgZ: Float = -0.126
    private var doorLocal: Vec3 = Vec3(1.05, 0.6, 0.1)

    // pose smoothing
    private var baseY: Float = 0
    private var groundY: Float = 0
    private var groundPitch: Float = 0
    private var groundRoll: Float = 0
    private var wheelWorld: [Vec3] = [Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(0, 0, 0)]
    private var surfaceKind: SurfaceType = .asphalt
    private var surfaceHard: Bool = true

    // visual dynamics
    private let suspension: VehicleSuspension = VehicleSuspension()
    private var wheelGround: [Float] = [0, 0, 0, 0]
    private var bodyPitch: Float = 0
    private var bodyRoll: Float = 0
    private var rpmDisplay: Float = 1000
    private var lastBraking: Bool = false
    private var lastThrottleInput: Float = 0
    private var popCooldown: Float = 0
    private var impactCooldown: Float = 0
    private var scrapeCooldown: Float = 0
    private var lastParticles: Bool = true

    // camera
    private var cameraSnap: Bool = true
    private var camYaw: Float = 0
    private var camFov: Float = 62
    private var camPull: Float = 0          // camera distance change from acceleration / braking (smoothed)

    init(ctx: GameContext) {
        self.ctx = ctx
        self.config = ctx.save.data.car
        node.name = "playerCar"
        configurePhysics()
    }

    // MARK: - Build

    func build() async throws {
        ctx.scene.rootNode.addChildNode(node)
        var model: SCNNode
        do {
            model = try ctx.assets.model("car_player")
        } catch {
            model = VehicleModelFactory.placeholderCar(color: UIColor(hexString: config.paint))
            usingPlaceholder = true
        }
        model.name = model.name ?? "car"
        node.addChildNode(model)
        await Task.yield()

        let meta: VehicleMeta? = try? ctx.assets.json("car_meta", as: VehicleMeta.self)
        readMeta(meta)

        let r: CarVisualRig = CarVisualRig(root: model, wingNames: meta?.wingNodes ?? [])
        rig = r
        customizer = CarCustomizer(root: model)
        NormalMaps.refineCockpit(root: model)

        // anchors that move with the body
        let eyeP: Vec3 = VehicleMeta.vec(meta?.driverEye, Vec3(0.36, 0.98, 0.05))
        let hipP: Vec3 = VehicleMeta.vec(meta?.driverHip, Vec3(0.36, 0.55, -0.25))
        let hubP: Vec3 = VehicleMeta.vec(meta?.steeringHub, Vec3(0.36, 0.83, 0.62))
        let axisP: Vec3 = VehicleMeta.vec(meta?.steeringAxis, Vec3(0, 0.35, -0.94)).normalizedSafe
        let thrP: Vec3 = VehicleMeta.vec(meta?.pedalThrottle, Vec3(0.36, 0.3, 0.55))
        let brkP: Vec3 = VehicleMeta.vec(meta?.pedalBrake, Vec3(0.27, 0.3, 0.55))
        let length: Float = meta?.length ?? 4.77
        let eyeA: SCNNode = r.makeAnchor(eyeP, space: node, name: "eyeAnchor")
        let hipA: SCNNode = r.makeAnchor(hipP, space: node, name: "hipAnchor")
        let hubA: SCNNode = r.makeAnchor(hubP, space: node, name: "hubAnchor")
        let thrA: SCNNode = r.makeAnchor(thrP, space: node, name: "throttleAnchor")
        let brkA: SCNNode = r.makeAnchor(brkP, space: node, name: "brakeAnchor")
        hoodAnchor = r.makeAnchor(Vec3(0, eyeP.y + 0.02, 1.05), space: node, name: "hoodAnchor")
        bumperAnchor = r.makeAnchor(Vec3(0, 0.5, length * 0.5 - 0.1), space: node, name: "bumperAnchor")

        var sign: Float = 1
        if let w = r.steeringWheel {
            let axisCar: Vec3 = node.simdConvertVector(Vec3(0, 0, 1), from: w)
            if simd_dot(axisCar, axisP) < 0 { sign = -1 }
        }
        let radius: Float = meta?.steeringRadius ?? 0.17
        var gl: Vec3 = VehicleMeta.vec(meta?.gripLeft, Vec3(0, 0, 0))
        var gr: Vec3 = VehicleMeta.vec(meta?.gripRight, Vec3(0, 0, 0))
        if gl.length < 1e-4 && gr.length < 1e-4 {
            gl = Vec3(radius, 0, 0)
            gr = Vec3(-radius, 0, 0)
        }
        cockpit.configure(eye: eyeA, hip: hipA, hub: hubA, throttle: thrA, brake: brkA, wheel: r.steeringWheel,
                          gripLeft: gl, gripRight: gr, wheelSign: sign)

        // effects
        let rearL: Vec3 = Vec3(trackRear * 0.5, wheelRadiusRear, rearAxleZ)
        let rearR: Vec3 = Vec3(-trackRear * 0.5, wheelRadiusRear, rearAxleZ)
        let exhausts: [Vec3] = VehicleMeta.vecList(meta?.exhausts, [Vec3(0.45, 0.4, -2.3)])
        let flameSize: Float = 0.08 + Float(engineSpec.cylinders) * 0.008
        effects = VehicleEffects(ctx: ctx, car: node, rearWheels: [rearL, rearR], exhausts: exhausts,
                                 hood: Vec3(0, 0.75, frontAxleZ + 0.3), exhaustSize: flameSize)

        // headlight spots
        let heads: [Vec3] = VehicleMeta.vecList(meta?.headlights, [Vec3(0.7, 0.65, 2.2)])
        var lightPositions: [Vec3] = []
        if let h0 = heads.first {
            lightPositions.append(Vec3(abs(h0.x) > 0.05 ? abs(h0.x) : 0.6, h0.y, h0.z))
            lightPositions.append(Vec3(abs(h0.x) > 0.05 ? -abs(h0.x) : -0.6, h0.y, h0.z))
        }
        for lp in lightPositions {
            let ln: SCNNode = SCNNode()
            let light: SCNLight = SCNLight()
            light.type = .spot
            light.color = UIColor(red: 1.0, green: 0.95, blue: 0.82, alpha: 1)
            light.intensity = 700
            light.spotInnerAngle = 18
            light.spotOuterAngle = 62
            light.attenuationStartDistance = 4
            light.attenuationEndDistance = 34
            light.castsShadow = false
            ln.light = light
            ln.simdPosition = lp
            ln.simdEulerAngles = Vec3(0.05, Float.pi, 0)
            ln.isHidden = true
            node.addChildNode(ln)
            lightNodes.append(ln)
        }

        built = true
        configurePhysics()
        apply(config: config)
        viewChanged()
        poseDirty = true
        updatePose(alpha: 0, dt: 0, snap: true)
    }

    private func readMeta(_ m: VehicleMeta?) {
        guard let meta = m else { return }
        if let v = meta.wheelRadiusFront { wheelRadiusFront = v }
        if let v = meta.wheelRadiusRear { wheelRadiusRear = v }
        if let v = meta.frontAxleZ { frontAxleZ = v }
        if let v = meta.rearAxleZ { rearAxleZ = v }
        if let v = meta.trackFront { trackFront = v }
        if let v = meta.trackRear { trackRear = v }
        if let v = meta.cgZ { cgZ = v }
        doorLocal = VehicleMeta.vec(meta.doorDriver, doorLocal)
        let length: Float = meta.length ?? 4.77
        let width: Float = meta.width ?? 2.05
        solver.halfLength = max(1.5, length * 0.5)
        solver.halfWidth = max(0.8, width * 0.5 - 0.03)
        solver.centreOffset = 0 - cgZ
    }

    private func configurePhysics() {
        let a: Float = frontAxleZ - cgZ
        let b: Float = cgZ - rearAxleZ
        physics.configure(spec: EngineSpec.spec(config.engine), tyre: config.tyres, wing: config.wing,
                          wheelRadius: wheelRadiusRear, distFront: max(0.8, a), distRear: max(0.8, b))
    }

    // MARK: - Configuration

    func apply(config cfg: CarConfig) {
        config = cfg
        configurePhysics()
        let spec: EngineSpec = EngineSpec.spec(cfg.engine)
        if ctx.state.engineName != spec.name { ctx.state.engineName = spec.name }
        if ctx.state.redline != spec.redline { ctx.state.redline = spec.redline }
        customizer?.apply(cfg)
        rig?.setWing(cfg.wing)
    }

    func setLights(_ on: Bool) {
        lightsOn = on
        customizer?.setHeadlights(on)
        let allowed: Bool = ctx.settings.settings.graphics.preset != .low
        for n in lightNodes { n.isHidden = !(on && allowed) }
    }

    func repair() {
        ctx.state.damage = 0
        physics.damage = 0
        effects?.setDamageSmoke(0)
    }

    private func viewChanged() {
        cameraSnap = true
        if ctx.state.view != view { ctx.state.view = view }
        let inside: Bool = view == .cockpit
        rig?.setCockpitMode(inside)
        customizer?.setInsideView(inside)
        if let p = ctx.player { p.cockpitFirstPerson = inside }
    }

    func cycleView() {
        let all: [CameraView] = CameraView.allCases
        if let i = all.firstIndex(of: view) {
            view = all[(i + 1) % all.count]
        } else {
            view = .chase
        }
    }

    // MARK: - Placement

    func place(position: Vec3, heading: Float) {
        let f: Vec2 = headingForward2(heading)
        physics.reset(x: position.x + f.x * cgZ, z: position.z + f.y * cgZ, heading: heading)
        prevX = physics.x
        prevZ = physics.z
        prevH = physics.heading
        lastGoodX = prevX
        lastGoodZ = prevZ
        lastGoodH = prevH
        acc = 0
        baseY = position.y
        groundY = position.y
        groundPitch = 0
        groundRoll = 0
        bodyPitch = 0
        bodyRoll = 0
        suspension.reset()
        rpmDisplay = physics.idleRPM
        cameraSnap = true
        poseDirty = true
        solver.forgetStruck()
        cockpit.resetWheel()
        effects?.skid.clear()
        effects?.setTyreSmoke(0)
        updatePose(alpha: 0, dt: 0, snap: true)
    }

    func enter() {
        isOccupied = true
        cameraSnap = true
        poseDirty = true
        lastThrottleInput = 0
        setLights(ctx.state.headlights)
        rpmDisplay = max(rpmDisplay, physics.idleRPM)
    }

    /// Returns a free spot beside the driver door (checks both sides against colliders).
    func exit() -> Spawn {
        isOccupied = false
        poseDirty = true
        cameraSnap = true
        let h: Float = state.heading
        let fwd: Vec2 = headingForward2(h)
        let left: Vec2 = headingLeft2(h)
        let origin: Vec2 = Vec2(state.position.x, state.position.z)
        let off: Float = solver.halfWidth + 0.95
        let doorZ: Float = doorLocal.z
        var cands: [(Vec2, Float)] = []
        cands.append((origin + left * off + fwd * doorZ, h + Float.pi / 2))
        cands.append((origin - left * off + fwd * doorZ, h - Float.pi / 2))
        cands.append((origin + left * (off + 1.2) + fwd * doorZ, h + Float.pi / 2))
        cands.append((origin - left * (off + 1.2) + fwd * doorZ, h - Float.pi / 2))
        cands.append((origin + left * off - fwd * 1.6, h + Float.pi / 2))
        var chosen: (Vec2, Float) = cands[0]
        var colliders: [Collider] = []
        if let w = ctx.world { colliders = w.colliders.query(center: origin, radius: 7) }
        for c in cands {
            if !VehicleCollisionSolver.isBlocked(c.0, radius: 0.45, colliders: colliders) {
                chosen = c
                break
            }
        }
        var y: Float = state.position.y
        if let w = ctx.world { y = w.groundHeight(at: chosen.0) }
        pushHUD(active: false)
        effects?.setTyreSmoke(0)
        return Spawn(position: Vec3(chosen.0.x, y, chosen.0.y), heading: chosen.1)
    }

    var driverDoorWorld: Vec3 {
        let h: Float = state.heading
        let f: Vec3 = headingForward(h)
        let l: Vec3 = headingLeft(h)
        return state.position + l * doorLocal.x + f * doorLocal.z + Vec3(0, doorLocal.y, 0)
    }

    /// External push (AI contact): shifts the car and changes its velocity (world XZ).
    func nudge(shift: Vec2, velocityDelta: Vec2) {
        physics.x += shift.x
        physics.z += shift.y
        prevX += shift.x
        prevZ += shift.y
        let v: Vec2 = physics.worldVelocity() + velocityDelta
        physics.setWorldVelocity(v)
        poseDirty = true
    }

    // MARK: - Per-frame update

    func update(dt: Float) {
        if !built { return }
        let d: Float = clampf(dt, 0.0005, 0.05)
        let gs: GameSettings = ctx.settings.settings
        let occupied: Bool = isOccupied && ctx.state.mode == .driving

        // ---- controls
        var controls: VehicleControls = VehicleControls()
        var inputThrottle: Float = 0
        var inputBrake: Float = 0
        if occupied {
            if let o = controlOverride {
                controls = o
            } else {
                let s: InputState = ctx.input.state
                controls.steer = clampf(s.steer, -1, 1)
                controls.throttle = clampf(s.throttle, 0, 1)
                controls.brake = clampf(s.brake, 0, 1)
                controls.handbrake = s.handbrake
                if gs.controls.autoThrottle && controls.brake < 0.05 { controls.throttle = 1 }
                if s.shiftUp { physics.requestShift(1) }
                if s.shiftDown { physics.requestShift(-1) }
            }
            inputThrottle = controls.throttle
            inputBrake = controls.brake
        }

        // ---- physics settings
        physics.assists.tractionControl = gs.gameplay.tractionControl
        physics.assists.absEnabled = gs.gameplay.abs
        physics.assists.stability = gs.gameplay.stability
        physics.damage = gs.gameplay.damage ? ctx.state.damage : 0
        physics.allowReverse = controlOverride == nil
        let held: Bool = !occupied || holdBrake
        let needsPhysics: Bool = !(held && physics.isAtRest)

        if needsPhysics {
            sampleSurface()
            var colliders: [Collider] = []
            if let w = ctx.world {
                let qr: Float = 4.0 + abs(physics.u) * d * 1.5
                colliders = w.colliders.query(center: Vec2(physics.x, physics.z), radius: qr)
            }
            solver.beginFrame()
            acc += d
            var n: Int = 0
            while acc >= fixedStep && n < 12 {
                prevX = physics.x
                prevZ = physics.z
                prevH = physics.heading
                if held {
                    physics.stepHold(fixedStep, decel: holdBrake ? 7.0 : 9.0)
                } else {
                    physics.step(fixedStep, controls: controls)
                }
                if !colliders.isEmpty { collide(colliders) }
                if !physics.isValid {
                    recover()
                    break
                }
                lastGoodX = physics.x
                lastGoodZ = physics.z
                lastGoodH = physics.heading
                acc -= fixedStep
                n += 1
            }
            if n >= 12 { acc = 0 }
            handleImpacts(d)
        } else {
            prevX = physics.x
            prevZ = physics.z
            prevH = physics.heading
            acc = 0
        }

        // ---- pose + visuals
        idleTimer += d
        if needsPhysics || poseDirty || idleTimer > 0.5 {
            idleTimer = 0
            let alpha: Float = needsPhysics ? clampf(acc / fixedStep, 0, 1) : 0
            updatePose(alpha: alpha, dt: d, snap: poseDirty)
            poseDirty = false
        }
        popCooldown = max(0, popCooldown - d)
        impactCooldown = max(0, impactCooldown - d)
        scrapeCooldown = max(0, scrapeCooldown - d)

        rpmDisplay = damp(rpmDisplay, physics.rpm, 14, d)
        if let rg = rig {
            // four independent suspension corners + per-wheel steering / rotation (see Suspension.swift)
            var si: SuspensionInput = SuspensionInput()
            si.ax = physics.ax
            si.ay = physics.ay
            si.u = physics.u
            si.v = physics.v
            si.yawRate = physics.r
            si.steerDelta = physics.delta
            si.rearSpin = physics.rearSpin
            si.frontLocked = physics.frontLocked
            si.absActive = physics.absActive
            si.handbrake = controls.handbrake
            si.ground = wheelGround
            si.mass = physics.mass
            si.downforceCoefficient = physics.clA
            si.cgHeight = physics.cgHeight
            si.wheelbase = physics.wheelbase
            si.distFront = physics.distFront
            si.trackFront = trackFront
            si.trackRear = trackRear
            si.radiusFront = wheelRadiusFront
            si.radiusRear = wheelRadiusRear
            suspension.step(d, si)
            rg.setWheelStates(suspension.wheels)
            rg.setBody(pitchX: suspension.pitch, rollZ: suspension.roll, heave: suspension.heave)
        }
        cockpit.update(steerInput: occupied ? controls.steer : 0, speed: physics.u, throttle: inputThrottle, brake: inputBrake, dt: d)

        // brake / head lights
        let braking: Bool = inputBrake > 0.05 && !physics.reverse
        var night: Bool = false
        if let w = ctx.world { night = w.timeOfDay < 6.5 || w.timeOfDay > 18.5 }
        customizer?.setBrakeLights(braking, night: night || lightsOn)

        // effects, audio, HUD
        if let fx = effects {
            if gs.graphics.particles != lastParticles {
                lastParticles = gs.graphics.particles
                fx.setParticlesEnabled(lastParticles)
            }
            fx.update(dt: d)
            if occupied {
                updateEffects(fx, controls: controls, inputThrottle: inputThrottle, dt: d)
            } else {
                fx.setTyreSmoke(0)
                fx.skid.endWheel(0)
                fx.skid.endWheel(1)
                fx.skid.endWheel(2)
                fx.skid.endWheel(3)
            }
            fx.setDamageSmoke(gs.gameplay.damage ? ctx.state.damage : 0)
        }
        if occupied {
            let spd: Float = abs(physics.u)
            ctx.audio.updateEngine(rpm: rpmDisplay, throttle: inputThrottle, load: clampf(inputThrottle * 0.8 + 0.2 * clampf(physics.ax / 8, 0, 1), 0, 1), speed: spd)
            pushHUD(active: true, throttle: inputThrottle, brake: inputBrake)
        }
        lastThrottleInput = inputThrottle
    }

    private func recover() {
        physics.x = lastGoodX
        physics.z = lastGoodZ
        physics.heading = lastGoodH
        physics.u = 0
        physics.v = 0
        physics.r = 0
        physics.rpm = physics.idleRPM
        physics.ax = 0
        physics.ay = 0
        physics.steerIn = 0
        if !physics.isValid { physics.reset(x: 0, z: 0, heading: 0) }
        prevX = physics.x
        prevZ = physics.z
        prevH = physics.heading
        acc = 0
    }

    // MARK: - Collisions

    private func collide(_ colliders: [Collider]) {
        guard let w = ctx.world else { return }
        let world: World = w
        solver.resolve(physics, colliders: colliders, strike: { (c: Collider, speed: Float, dir: Vec2) -> Float in
            return world.colliders.strike(id: c.id, speed: speed, direction: dir)
        })
    }

    private func handleImpacts(_ d: Float) {
        let imp: VehicleImpact = solver.frameImpact
        let gs: GameSettings = ctx.settings.settings
        let ground: Float = state.position.y
        if imp.speed > 1.2 && impactCooldown <= 0 {
            impactCooldown = 0.12
            let heavy: Bool = imp.speed > 9
            let vol: Float = clampf(imp.speed / 18, 0.3, 1)
            let p3: Vec3 = Vec3(imp.point.x, ground + 0.5, imp.point.y)
            ctx.audio.play(heavy ? SFX.crashMetalHeavy : SFX.crashMetalLight, volume: vol, rate: 1, position: p3)
            if imp.speed > 4 {
                ctx.cameraRig.shake(clampf(imp.speed / 14, 0.15, 1.3))
                ctx.input.haptic(imp.speed > 10 ? HapticKind.heavy : HapticKind.medium)
            }
            if imp.speed > 3 { effects?.burstSparks(at: p3) }
            if imp.speed > 5 {
                ctx.wanted?.reportCrash(speed: imp.speed, destructible: imp.destructible)
                ctx.npcs?.notifyCrash(at: imp.point, magnitude: clampf(imp.speed / 20, 0.1, 1))
            }
            if gs.gameplay.damage {
                var add: Float = 0
                if imp.destructible {
                    add = min(0.08, imp.speed * 0.004)
                } else {
                    let x: Float = max(0, imp.speed - 2.5) / 28
                    add = powf(x, 1.3) * 0.5
                }
                ctx.state.damage = min(1, ctx.state.damage + add)
            }
        } else if solver.frameScrape > 3 && imp.speed > 0.2 && scrapeCooldown <= 0 {
            scrapeCooldown = 0.45
            let p3: Vec3 = Vec3(imp.point.x, ground + 0.5, imp.point.y)
            ctx.audio.play(SFX.scrape, volume: clampf(solver.frameScrape / 15, 0.25, 0.8), rate: 1, position: p3)
            effects?.burstSparks(at: p3)
        }
    }

    // MARK: - Surface

    private func wheelPointsXZ(cg: Vec2, heading h: Float) -> [Vec2] {
        let f: Vec2 = headingForward2(h)
        let l: Vec2 = headingLeft2(h)
        let origin: Vec2 = cg - f * cgZ
        let fa: Vec2 = origin + f * frontAxleZ
        let ra: Vec2 = origin + f * rearAxleZ
        let hf: Float = trackFront * 0.5
        let hr: Float = trackRear * 0.5
        return [fa + l * hf, fa - l * hf, ra + l * hr, ra - l * hr]
    }

    private func sampleSurface() {
        guard let w = ctx.world else {
            physics.muScale = 1
            physics.extraDrag = 0
            surfaceKind = .asphalt
            surfaceHard = true
            return
        }
        let cg: Vec2 = Vec2(physics.x, physics.z)
        let pts: [Vec2] = wheelPointsXZ(cg: cg, heading: physics.heading)
        var mu: Float = 0
        var drag: Float = 0
        var hard: Bool = true
        for (i, p) in pts.enumerated() {
            let s: SurfaceType = w.surface(at: p)
            let g: (mu: Float, drag: Float) = VehicleSurface.grip(s)
            mu += g.mu
            drag += g.drag
            if !VehicleSurface.isHard(s) { hard = false }
            // height of the surface under this wheel: the kerb / sidewalk is 15 cm up, soft ground is uneven
            var level: Float = 0
            if s == SurfaceType.sidewalk {
                level = WC.curbH
            } else if s == SurfaceType.grass || s == SurfaceType.dirt {
                let x: Float = p.x
                let z: Float = p.y
                let n: Float = (sinf(x * 2.1) + sinf(z * 1.7 + 1.3) + sinf((x + z) * 3.3)) / 3
                level = 0.022 * n * clampf(abs(physics.u) / 5, 0, 1)
            }
            if i < wheelGround.count { wheelGround[i] = level }
        }
        physics.muScale = mu * 0.25
        physics.extraDrag = drag * 0.25
        surfaceHard = hard
        surfaceKind = w.surface(at: cg)
    }

    // MARK: - Pose (interpolated between physics steps)

    private func updatePose(alpha: Float, dt: Float, snap: Bool) {
        let cx: Float = lerpf(prevX, physics.x, alpha)
        let cz: Float = lerpf(prevZ, physics.z, alpha)
        let h: Float = wrapAngle(prevH + angleDiff(prevH, physics.heading) * alpha)
        let f: Vec2 = headingForward2(h)
        let origin: Vec2 = Vec2(cx, cz) - f * cgZ
        let pts: [Vec2] = wheelPointsXZ(cg: Vec2(cx, cz), heading: h)

        var targetY: Float = baseY
        var targetPitch: Float = 0
        var targetRoll: Float = 0
        let follow: Bool = ctx.state.mode != .garage
        var heights: [Float] = [baseY, baseY, baseY, baseY]
        if follow, let w = ctx.world {
            for i in 0..<4 { heights[i] = w.groundHeight(at: pts[i]) }
            targetY = (heights[0] + heights[1] + heights[2] + heights[3]) * 0.25
            let frontAvg: Float = (heights[0] + heights[1]) * 0.5
            let rearAvg: Float = (heights[2] + heights[3]) * 0.5
            let leftAvg: Float = (heights[0] + heights[2]) * 0.5
            let rightAvg: Float = (heights[1] + heights[3]) * 0.5
            targetPitch = atan2f(frontAvg - rearAvg, max(0.5, frontAxleZ - rearAxleZ))
            targetRoll = atan2f(leftAvg - rightAvg, max(0.5, trackFront))
            targetPitch = clampf(targetPitch, -0.6, 0.6)
            targetRoll = clampf(targetRoll, -0.6, 0.6)
        }
        if snap || dt <= 0 {
            groundY = targetY
            groundPitch = targetPitch
            groundRoll = targetRoll
        } else {
            groundY = damp(groundY, targetY, 22, dt)
            groundPitch = damp(groundPitch, targetPitch, 18, dt)
            groundRoll = damp(groundRoll, targetRoll, 18, dt)
        }
        let pos: Vec3 = Vec3(origin.x, groundY, origin.y)
        let qYaw: simd_quatf = simd_quatf(angle: h, axis: Vec3(0, 1, 0))
        let qPitch: simd_quatf = simd_quatf(angle: -groundPitch, axis: Vec3(1, 0, 0))
        let qRoll: simd_quatf = simd_quatf(angle: groundRoll, axis: Vec3(0, 0, 1))
        node.simdPosition = pos
        node.simdOrientation = qYaw * qPitch * qRoll
        for i in 0..<4 { wheelWorld[i] = Vec3(pts[i].x, heights[i], pts[i].y) }

        let vel: Vec2 = physics.worldVelocity()
        var st: VehicleState = VehicleState()
        st.position = pos
        st.heading = h
        st.speed = physics.u
        st.velocity = Vec3(vel.x, 0, vel.y)
        st.yawRate = physics.r
        st.rpm = rpmDisplay
        st.gear = physics.reverse ? -1 : physics.gear
        st.steer = physics.steerIn
        st.wheelSpin = physics.rearSpin
        st.slipRear = physics.slipR
        st.onGround = true
        st.lateralG = clampf(physics.ay / VehiclePhysics.gravity, -6, 6)
        st.longitudinalG = clampf(physics.ax / VehiclePhysics.gravity, -6, 6)
        state = st
    }

    // MARK: - Effects / audio

    private func updateEffects(_ fx: VehicleEffects, controls: VehicleControls, inputThrottle: Float, dt: Float) {
        let speed: Float = abs(physics.u)
        var frontSkid: Float = 0
        var rearSkid: Float = 0
        if speed > 5 {
            frontSkid = clampf((abs(physics.slipF) - 0.11) / 0.10, 0, 1)
            if physics.frontLocked { frontSkid = max(frontSkid, 0.9) }
            rearSkid = clampf((abs(physics.slipR) - 0.10) / 0.10, 0, 1)
            if controls.handbrake { rearSkid = max(rearSkid, 0.8) }
        }
        let spinFactor: Float = physics.assists.tractionControl ? 0.35 : 1.0
        rearSkid = max(rearSkid, physics.rearSpin * 1.3 * spinFactor)
        if speed < 1 && physics.rearSpin < 0.05 { rearSkid = 0 }
        let intensities: [Float] = [frontSkid, frontSkid, rearSkid, rearSkid]
        for i in 0..<4 {
            if surfaceHard && intensities[i] > 0.35 {
                let p: Vec3 = Vec3(wheelWorld[i].x, wheelWorld[i].y + 0.04, wheelWorld[i].z)
                fx.skid.addPoint(wheel: i, position: p, width: 0.27)
            } else {
                fx.skid.endWheel(i)
            }
        }
        let smokeAmount: Float = max(rearSkid, frontSkid * 0.6)
        fx.setTyreSmoke(smokeAmount)

        let skidAudio: Float = max(frontSkid, rearSkid)
        var rumble: Float = 0
        if !surfaceHard { rumble = clampf(speed / 40, 0, 1) }
        let wind: Float = clampf(speed / 100, 0, 1)
        ctx.audio.updateTyres(skid: skidAudio, surface: surfaceKind, rumble: rumble, wind: wind)

        // exhaust pops and turbo whoosh when lifting off
        let spec: EngineSpec = engineSpec
        if lastThrottleInput > 0.6 && inputThrottle < 0.1 && popCooldown <= 0 && physics.rpm > spec.redline * 0.55 && speed > 10 {
            popCooldown = 0.6
            if spec.cylinders >= 8 {
                fx.exhaustBurst()
                ctx.audio.play(SFX.exhaustPop, volume: 0.5 + 0.03 * Float(spec.cylinders), rate: 1, position: state.position)
            }
            if spec.type == .v6 || spec.type == .v16 {
                ctx.audio.play(SFX.turboWhoosh, volume: 0.6, rate: 1, position: state.position)
            }
        }
    }

    private func pushHUD(active: Bool, throttle: Float = 0, brake: Float = 0) {
        let st: GameState = ctx.state
        let spd: Float = active ? abs(physics.u) : 0
        if abs(st.speed - spd) > 0.02 { st.speed = spd }
        let r: Float = active ? rpmDisplay : physics.idleRPM
        if abs(st.rpm - r) > 5 { st.rpm = r }
        let g: Int = physics.reverse ? -1 : physics.gear
        if st.gear != g { st.gear = g }
        if abs(st.throttle - throttle) > 0.01 { st.throttle = throttle }
        if abs(st.brake - brake) > 0.01 { st.brake = brake }
        let s: Float = active ? physics.steerIn : 0
        if abs(st.steer - s) > 0.005 { st.steer = s }
        let a: Bool = active && physics.absActive
        if st.abs != a { st.abs = a }
        let tcA: Bool = active && physics.tcActive
        if st.tractionControlActive != tcA { st.tractionControlActive = tcA }
    }

    // MARK: - Cameras

    private func groundAt(_ p: Vec2) -> Float {
        if let w = ctx.world { return w.groundHeight(at: p) }
        return baseY
    }

    func updateCamera(_ rig: CameraRig, dt: Float) {
        let d: Float = clampf(dt, 0.001, 0.1)
        let gs: GameplaySettings = ctx.settings.settings.gameplay
        let fovScale: Float = gs.fovScale
        let speed: Float = abs(state.speed)
        let sf: Float = clampf(speed / 70, 0, 1)
        let pos: Vec3 = state.position

        switch view {
        case .chase, .close:
            let close: Bool = view == .close
            // acceleration pulls the camera back, braking brings it in (smooth, small)
            camPull = damp(camPull, clampf(state.longitudinalG * 0.8, -0.6, 0.8), 2.4, d)
            let dist: Float = (close ? 4.6 + 1.4 * sf : 6.4 + 2.4 * sf) + camPull
            let height: Float = close ? 1.35 + 0.25 * sf : 2.0 + 0.5 * sf
            var target: Float = state.heading
            if state.speed > 6 {
                let vh: Float = headingOf(Vec2(state.velocity.x, state.velocity.z))
                target = state.heading + clampf(angleDiff(state.heading, vh), -0.6, 0.6) * 0.5
            }
            if cameraSnap {
                camYaw = state.heading
            } else {
                let k: Float = 1 - expf(-5.5 * d)
                camYaw = wrapAngle(camYaw + angleDiff(camYaw, target) * k)
            }
            let fwd: Vec3 = headingForward(camYaw)
            var desired: Vec3 = pos - fwd * dist + Vec3(0, height, 0)
            let minY: Float = groundAt(Vec2(desired.x, desired.z)) + 0.6
            if desired.y < minY { desired.y = minY }
            let look: Vec3 = pos + fwd * (3 + 0.06 * speed) + Vec3(0, 1.0, 0)
            let targetFov: Float = (close ? 64 : 62) + 16 * sf + clampf(state.longitudinalG * 2.5, -2, 3)
            if cameraSnap {
                camFov = targetFov
            } else {
                camFov = damp(camFov, targetFov, 4, d)
            }
            rig.fov = camFov * fovScale
            let farAway: Bool = simd_distance(rig.position, desired) > 20
            if cameraSnap || farAway {
                rig.set(position: desired, lookAt: look)
                cameraSnap = false
            } else {
                rig.follow(desired: desired, lookAt: look, dt: d, stiffness: 12 + 0.3 * speed, maxLag: 2.5)
            }
        case .hood:
            lookFrom(rig, anchor: hoodAnchor, yawExtra: -state.steer * 0.05, fov: 66 * fovScale)
        case .bumper:
            lookFrom(rig, anchor: bumperAnchor, yawExtra: 0, fov: 74 * fovScale)
        case .cockpit:
            let lat: Float = clampf(-state.lateralG * 0.03, -0.05, 0.05)
            let lon: Float = clampf(-state.longitudinalG * 0.02, -0.04, 0.04)
            let fw: Vec3 = cockpit.forwardWorld
            let up: Vec3 = cockpit.upWorld
            let rightW: Vec3 = simd_cross(up, fw).normalizedSafe
            var eye: Vec3 = cockpit.eyeWorld
            eye = eye + rightW * (-lat) + fw * lon
            let yaw: Float = state.steer * 0.12 * (1 - sf * 0.6)
            let upB: Vec3 = (Vec3(0, 1, 0) * 0.4 + up * 0.6).normalizedSafe
            var dir: Vec3 = fw
            if abs(yaw) > 1e-4 { dir = simd_quatf(angle: yaw, axis: upB).act(fw) }
            rig.fov = 72 * fovScale
            rig.set(position: eye, lookAt: eye + dir * 20, up: upB)
            cameraSnap = false
        }
        if view != .chase && view != .close { cameraSnap = false }
    }

    private func lookFrom(_ rig: CameraRig, anchor: SCNNode?, yawExtra: Float, fov: Float) {
        guard let a = anchor else { return }
        let p: Vec3 = a.simdWorldPosition
        let f: Vec3 = a.simdConvertVector(Vec3(0, 0, 1), to: nil).normalizedSafe
        let up: Vec3 = a.simdConvertVector(Vec3(0, 1, 0), to: nil).normalizedSafe
        let upB: Vec3 = (Vec3(0, 1, 0) * 0.4 + up * 0.6).normalizedSafe
        var dir: Vec3 = f
        if abs(yawExtra) > 1e-4 { dir = simd_quatf(angle: yawExtra, axis: upB).act(f) }
        rig.fov = fov
        rig.set(position: p, lookAt: p + dir * 20, up: upB)
    }
}
