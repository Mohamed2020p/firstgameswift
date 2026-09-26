import Foundation
import SceneKit
import UIKit
import simd

// MARK: - The player's house: villa + attached garage on the hillside street. Interactables (door, bed, TV, desk, garage console),
// automatic garage door, interior visibility / lights, sleeping sequence and the showroom camera of the garage.

struct GarageInfo {
    var carSpot: Spawn
    var liftNode: SCNNode?
    var showroomCameraPositions: [Vec3]
    var showroomFocus: Vec3
}

@MainActor
final class PlayerHouse: CameraController {
    let root = SCNNode()
    private(set) var interactables: [Interactable] = []
    private(set) var garage: GarageInfo

    private unowned let ctx: GameContext
    private var builder: HouseBuilder? = nil
    private var center = Vec2(0, 0)
    private var heading: Float = 0
    private var built = false

    private var zone: PlayerLocation = .outside
    private var doorOpen: Float = 0
    private var doorWanted: Bool = false
    private var tvOn = true
    private var scroll: Float = 0
    private var timer: Float = 0
    private var workCooldown: Float = 0
    private var showroom = false
    private var carLit = false

    // showroom camera
    private var orbitYaw: Float = 0.7
    private var orbitPitch: Float = 0.2
    private var orbitRadius: Float = 5.2
    private var idleTimer: Float = 0

    init(ctx: GameContext) {
        self.ctx = ctx
        garage = GarageInfo(carSpot: Spawn(position: Vec3(0, 0, 0), heading: 0), liftNode: nil,
                            showroomCameraPositions: [], showroomFocus: Vec3(0, 0.7, 0))
        root.name = "playerHouse"
    }

    // MARK: - Build

    func build(at spawn: Spawn) async {
        if built { return }
        built = true
        center = Vec2(spawn.position.x, spawn.position.z)
        heading = spawn.heading
        root.simdPosition = Vec3(center.x, 0, center.y)
        root.simdEulerAngles = Vec3(0, heading, 0)
        ctx.scene.rootNode.addChildNode(root)

        let b = HouseBuilder(ctx: ctx, center: center, heading: heading)
        b.build()
        await Task.yield()
        root.addChildNode(b.exteriorNode)
        root.addChildNode(b.interiorNode)
        root.addChildNode(b.garageNode)
        root.addChildNode(b.extrasNode)
        builder = b
        b.interiorNode.isHidden = true
        for s in b.showroomSpots { s.isHidden = true }

        let cs = HousePlan.carSpot
        let sp: Vec2 = b.worldPoint(cs.x, cs.y)
        let focus = Vec3(sp.x, 0.75, sp.y)
        var cams: [Vec3] = []
        for k in 0..<4 {
            let a: Float = Float(k) / 4 * Float.tau + 0.6
            cams.append(focus + Vec3(sinf(a) * 5.2, 1.5, cosf(a) * 5.2))
        }
        garage = GarageInfo(carSpot: Spawn(position: Vec3(sp.x, 0, sp.y), heading: heading), liftNode: b.liftRing,
                            showroomCameraPositions: cams, showroomFocus: focus)
        makeInteractables(b)
        updateWindowLook(force: true)
    }

    private func loc3(_ b: HouseBuilder, _ lx: Float, _ lz: Float) -> Vec3 {
        let p: Vec2 = b.worldPoint(lx, lz)
        return Vec3(p.x, 0, p.y)
    }

    private func makeInteractables(_ b: HouseBuilder) {
        var list: [Interactable] = []
        list.append(Interactable(id: "house-door", position: ctx.world.spawn.houseDoor.position, radius: 2.0, prompt: "Enter house",
                                 isEnabled: { [weak self] in self?.ctx.player.location == PlayerLocation.outside },
                                 action: { [weak self] in self?.ctx.enterHouse() }))
        list.append(Interactable(id: "house-exit", position: loc3(b, HousePlan.frontDoorX, 6.3), radius: 1.8, prompt: "Go outside",
                                 isEnabled: { [weak self] in self?.ctx.player.location == PlayerLocation.house },
                                 action: { [weak self] in self?.ctx.exitHouse() }))
        list.append(Interactable(id: "bed", position: loc3(b, -12.3, -6.0), radius: 1.9, prompt: "Sleep until morning",
                                 isEnabled: { [weak self] in self?.ctx.player.location == PlayerLocation.house },
                                 action: { [weak self] in self?.ctx.sleepInBed() }))
        list.append(Interactable(id: "tv", position: loc3(b, -9.5, 4.9), radius: 1.9, prompt: "Toggle TV",
                                 isEnabled: { [weak self] in self?.ctx.player.location == PlayerLocation.house },
                                 action: { [weak self] in self?.toggleTV() }))
        list.append(Interactable(id: "desk", position: loc3(b, 1.4, -9.3), radius: 1.8, prompt: "Freelance coding job (+$1,500)",
                                 isEnabled: { [weak self] in self?.ctx.player.location == PlayerLocation.house },
                                 action: { [weak self] in self?.doFreelance() }))
        list.append(Interactable(id: "garage-console", position: loc3(b, 8.7, 2.4), radius: 2.0, prompt: "Customize car",
                                 isEnabled: { [weak self] in self?.ctx.player.location == PlayerLocation.garageBuilding },
                                 action: { [weak self] in self?.ctx.openGarage() }))
        interactables = list
    }

    // MARK: - Actions

    private func toggleTV() {
        tvOn.toggle()
        builder?.tvNode?.isHidden = !tvOn
        ctx.audio.play(SFX.lightSwitch, volume: 0.7, rate: 1, position: nil)
        ctx.state.showToast(tvOn ? "TV on" : "TV off")
    }

    private func doFreelance() {
        if workCooldown > 0 {
            ctx.state.showToast("Take a break first — the next job arrives in \(Int(workCooldown))s")
            ctx.audio.play(SFX.uiError, volume: 0.6, rate: 1, position: nil)
            return
        }
        workCooldown = 60
        ctx.save.addMoney(1500)
        ctx.audio.play(SFX.cashRegister, volume: 0.9, rate: 1, position: nil)
        ctx.input.haptic(HapticKind.success)
        ctx.state.showToast("Client paid $1,500 — commit pushed ✔")
    }

    func enter() {
        guard let b = builder else { return }
        let p: Vec2 = b.worldPoint(HousePlan.frontDoorX, 5.6)
        ctx.player.place(position: Vec3(p.x, 0, p.y), heading: b.worldHeading(localAngle: Float.pi), location: PlayerLocation.house)
        applyZone(PlayerLocation.house)
        ctx.audio.play(SFX.doorOpen, volume: 0.9, rate: 1, position: Vec3(p.x, 1, p.y))
    }

    func exit() {
        let s: Spawn = ctx.world.spawn.houseDoor
        ctx.player.place(position: s.position, heading: heading, location: PlayerLocation.outside)
        applyZone(PlayerLocation.outside)
        ctx.audio.play(SFX.doorClose, volume: 0.9, rate: 1, position: s.position)
    }

    private func fade(to target: Float, seconds: Double) async {
        let steps = 24
        let start: Float = ctx.state.fade
        for i in 1...steps {
            ctx.state.fade = start + (target - start) * Float(i) / Float(steps)
            try? await Task.sleep(nanoseconds: UInt64(seconds / Double(steps) * 1_000_000_000))
        }
        ctx.state.fade = target
    }

    /// bed sequence: fade out, lie down, advance to 07:00, get up, fade in. (GameContext adds the day and saves afterwards)
    func sleep() async {
        guard let b = builder else { return }
        ctx.audio.play(SFX.bedRustle, volume: 0.8, rate: 1, position: nil)
        await fade(to: 1, seconds: 0.9)
        ctx.state.fadeText = "Sleeping…"
        let h: Vec2 = b.worldPoint(HousePlan.bedHips.x, HousePlan.bedHips.z)
        ctx.player.lieInBed(position: Vec3(h.x, HousePlan.bedHips.y, h.y), heading: b.worldHeading(localAngle: Float.pi * 0.5))
        try? await Task.sleep(nanoseconds: 700_000_000)
        ctx.audio.play(SFX.sleepChime, volume: 0.9, rate: 1, position: nil)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        ctx.world.timeOfDay = 7.0
        let g: Vec2 = b.worldPoint(HousePlan.bedGetUp.x, HousePlan.bedGetUp.y)
        ctx.player.getUpFromBed(position: Vec3(g.x, 0, g.y), heading: b.worldHeading(localAngle: Float.pi * 0.5))
        ctx.state.fadeText = nil
        await fade(to: 0, seconds: 1.0)
    }

    // MARK: - Garage / showroom

    func setGarageLift(up: Bool) {
        showroom = up
        builder?.liftRing?.isHidden = !up
        if let b = builder {
            for s in b.showroomSpots {
                s.isHidden = !up
                s.light?.intensity = up ? 1100 : 0
            }
        }
        if up {
            idleTimer = 0
            orbitYaw = wrapAngle(heading + 0.7)
            orbitPitch = 0.2
            orbitRadius = 5.2
            setCarLit(true)
        }
    }

    func orbit(dx: Float, dy: Float) {
        orbitYaw -= dx
        orbitPitch = clampf(orbitPitch + dy, 0.03, 0.85)
        idleTimer = 0
    }

    func zoom(by delta: Float) {
        orbitRadius = clampf(orbitRadius + delta, 3.6, 5.6)
        idleTimer = 0
    }

    func updateCamera(_ rig: CameraRig, dt: Float) {
        idleTimer += dt
        if idleTimer > 2.5 { orbitYaw += dt * 0.22 }
        let focus: Vec3 = garage.showroomFocus
        let cp: Float = cosf(orbitPitch)
        let off = Vec3(sinf(orbitYaw) * cp, sinf(orbitPitch), cosf(orbitYaw) * cp) * orbitRadius
        rig.fov = 42
        rig.follow(desired: focus + off, lookAt: focus, dt: dt, stiffness: 6, maxLag: 8)
    }

    private func setCarLit(_ on: Bool) {
        if carLit == on { return }
        carLit = on
        guard let car = ctx.car else { return }
        car.node.enumerateHierarchy { (n: SCNNode, _: UnsafeMutablePointer<ObjCBool>) in
            if on { n.categoryBitMask |= 8 } else { n.categoryBitMask &= ~8 }
        }
    }

    // MARK: - Zones + per frame

    private func zoneFor(_ p: Vec3) -> PlayerLocation {
        let d = Vec2(p.x - center.x, p.z - center.y)
        let lx: Float = simd_dot(d, headingLeft2(heading))
        let lz: Float = simd_dot(d, headingForward2(heading))
        if lx > HousePlan.vx0 && lx < HousePlan.gx0 - 0.1 && lz > HousePlan.vz0 && lz < HousePlan.vz1 - 0.1 { return PlayerLocation.house }
        if lx >= HousePlan.gx0 - 0.1 && lx < HousePlan.gx1 - 0.2 && lz > HousePlan.gz0 && lz < HousePlan.gz1 - 0.05 { return PlayerLocation.garageBuilding }
        return PlayerLocation.outside
    }

    private func applyZone(_ z: PlayerLocation) {
        zone = z
        builder?.interiorNode.isHidden = z != PlayerLocation.house
        ctx.world.setInteriorMode(z != PlayerLocation.outside)
        switch z {
        case .house: ctx.state.locationName = "Home"
        case .garageBuilding: ctx.state.locationName = "Garage"
        case .outside: ctx.state.locationName = ""
        }
        ctx.state.location = z
        let t: Float = ctx.world.timeOfDay
        switch z {
        case .house: ctx.audio.setAmbience(AmbienceTrack.houseInterior)
        case .garageBuilding: ctx.audio.setAmbience(AmbienceTrack.garageInterior)
        case .outside: ctx.audio.setAmbience((t > 6 && t < 19) ? AmbienceTrack.suburbDay : AmbienceTrack.suburbNight)
        }
    }

    private func updateWindowLook(force: Bool) {
        guard let b = builder else { return }
        let t: Float = ctx.world.timeOfDay
        let night: Float = clampf(1 - smoothstep(5.0, 7.0, t) + smoothstep(18.0, 20.0, t), 0, 1)
        let day = Vec3(0.55, 0.75, 0.95)
        let dark = Vec3(0.03, 0.05, 0.10)
        let c: Vec3 = day * (1 - night) + dark * night
        b.mats.windowView.diffuse.contents = UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
        b.mats.glassExterior.emission.intensity = CGFloat(night * 0.55)
        _ = force
    }

    func update(dt: Float) {
        guard let b = builder else { return }
        timer += dt
        if workCooldown > 0 { workCooldown = max(0, workCooldown - dt) }

        // where is the player?
        if ctx.state.mode == .onFoot, let p = ctx.player {
            let z: PlayerLocation = zoneFor(p.node.simdPosition)
            if z != zone {
                ctx.player.location = z
                applyZone(z)
            }
        }

        // garage door opens when the player or the car is close
        var wanted = false
        let door: Vec2 = b.worldPoint((HousePlan.doorX0 + HousePlan.doorX1) * 0.5, HousePlan.gz1 + 1.0)
        if let p = ctx.player, ctx.state.mode != .driving {
            let d: Float = simd_length(Vec2(p.node.simdPosition.x, p.node.simdPosition.z) - door)
            if d < 9 { wanted = true }
        }
        if let car = ctx.car {
            let d: Float = simd_length(Vec2(car.state.position.x, car.state.position.z) - door)
            if d < 14 { wanted = true }
        }
        if ctx.state.mode == .garage { wanted = true }
        if wanted != doorWanted {
            doorWanted = wanted
            ctx.audio.play(SFX.garageDoorMotor, volume: 0.8, rate: 1, position: Vec3(door.x, 1.5, door.y))
        }
        let target: Float = doorWanted ? 1 : 0
        if doorOpen != target {
            let step: Float = dt * 1.5
            doorOpen = doorOpen < target ? min(target, doorOpen + step) : max(target, doorOpen - step)
            if let n = b.garageDoorNode {
                let sy: Float = max(0.04, 1 - 0.96 * doorOpen)
                n.simdScale = Vec3(1, sy, 1)
                n.simdPosition = Vec3((HousePlan.doorX0 + HousePlan.doorX1) * 0.5, HousePlan.doorH - HousePlan.doorH * sy * 0.5, HousePlan.gz1 - 0.12)
            }
        }

        // things that only matter near the house
        let near: Bool
        if let p = ctx.player {
            near = simd_length(Vec2(p.node.simdPosition.x, p.node.simdPosition.z) - center) < 70
        } else {
            near = true
        }
        b.garageNode.isHidden = !near
        if timer > 0.5 {
            timer = 0
            updateWindowLook(force: false)
            if let car = ctx.car {
                let d = Vec2(car.state.position.x - center.x, car.state.position.z - center.y)
                let lx: Float = simd_dot(d, headingLeft2(heading))
                let lz: Float = simd_dot(d, headingForward2(heading))
                let inside: Bool = lx > HousePlan.gx0 && lx < HousePlan.gx1 && lz > HousePlan.gz0 && lz < HousePlan.gz1
                if !showroom { setCarLit(inside) }
            }
        }
        if zone == PlayerLocation.house {
            scroll += dt * 0.05
            let tr: SCNMatrix4 = SCNMatrix4Mult(SCNMatrix4MakeScale(1, 0.55, 1), SCNMatrix4MakeTranslation(0, scroll, 0))
            for m in b.animatedScreens { m.diffuse.contentsTransform = tr }
        }
    }
}
