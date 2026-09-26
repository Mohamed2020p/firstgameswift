import Foundation
import SceneKit
import simd

// MARK: - The player (c0derz): full avatar with procedural animation (idle, walk, run, sit + drive with hands on the wheel, sleep),
// on-foot movement with collisions, third-person orbit camera with wall avoidance.

@MainActor
final class PlayerCharacter: CameraController {
    private unowned let ctx: GameContext

    /// avatar root: feet at y = 0, faces +Z
    let node = SCNNode()
    var location: PlayerLocation = .outside
    var cockpitFirstPerson: Bool = false {
        didSet { updateHeadVisibility() }
    }

    private enum Mode { case walking, driving, lying }
    private var mode: Mode = .walking
    private var model: SCNNode? = nil
    private var solver: WPoseSolver? = nil
    private var headNodes: [SCNNode] = []

    // locomotion
    private var pos: Vec3 = Vec3(0, 0, 0)
    private var heading: Float = 0
    private var speed: Float = 0
    private var vel: Vec3 = Vec3(0, 0, 0)
    private var gaitPhase: Float = 0
    private var time: Float = 0
    private var stepIndex: Int = 0
    private let radius: Float = 0.32

    // camera
    private var camYaw: Float = 0
    private var camPitch: Float = 0.28
    private var camDist: Float = 3.5
    private var camSnap: Bool = true

    // driving
    private var seatBlend: Float = 1
    private var seatStart: Vec3 = Vec3(0, 0, 0)
    private var seatLean: Float = -0.32
    private var exitBlend: Float = 1
    private var footBlend: Float = 0

    // lying
    private var lyingPos: Vec3 = Vec3(0, 0, 0)

    init(ctx: GameContext) {
        self.ctx = ctx
        node.name = "player"
    }

    // MARK: - Build

    func build() async throws {
        ctx.scene.rootNode.addChildNode(node)
        let m: SCNNode = try ctx.assets.model("rider")
        m.name = "rider"
        node.addChildNode(m)
        model = m
        solver = WPoseSolver(model: m)
        if solver == nil { assetLog("rider skeleton not found; the character stays in its rest pose") }
        m.enumerateHierarchy { (n: SCNNode, _: UnsafeMutablePointer<ObjCBool>) in
            if n.geometry != nil {
                n.castsShadow = true
                n.categoryBitMask = 4 | 1 | 8
                if n.boundingBox.min.y > 1.45 { self.headNodes.append(n) }
            }
        }
        applyIdlePose(dt: 0)
    }

    private func updateHeadVisibility() {
        let hide: Bool = cockpitFirstPerson && mode == .driving
        for n in headNodes { n.isHidden = hide }
    }

    func setVisible(_ v: Bool) {
        node.isHidden = !v
    }

    // MARK: - Placement

    func place(position: Vec3, heading h: Float, location loc: PlayerLocation) {
        mode = .walking
        pos = position
        heading = h
        speed = 0
        vel = Vec3(0, 0, 0)
        location = loc
        camYaw = h
        camPitch = 0.28
        camSnap = true
        exitBlend = 1
        node.simdPosition = position
        node.simdEulerAngles = Vec3(0, h, 0)
        node.isHidden = false
        updateHeadVisibility()
        applyIdlePose(dt: 0)
    }

    // MARK: - On-foot update

    func update(dt: Float) {
        if mode != .walking { return }
        let s: InputState = ctx.input.state
        time += dt

        // camera look
        camYaw = wrapAngle(camYaw - s.lookDX)
        camPitch = clampf(camPitch + s.lookDY, -0.35, location == PlayerLocation.outside ? 1.25 : 0.62)

        // movement relative to the camera
        let camF: Vec3 = headingForward(camYaw)
        var wish: Vec3 = camF * s.moveY + Vec3(-cosf(camYaw), 0, sinf(camYaw)) * s.moveX
        let mag: Float = min(1, simd_length(wish))
        if mag > 0.001 { wish = wish / simd_length(wish) }
        var targetSpeed: Float = 0
        if mag > 0.08 {
            if s.run { targetSpeed = 6.2 } else if mag > 0.6 { targetSpeed = 3.7 } else { targetSpeed = 1.6 * (mag / 0.6) }
        }
        let accel: Float = targetSpeed > speed ? 13 : 18
        speed = speed + clampf(targetSpeed - speed, -accel * dt, accel * dt)
        if mag > 0.08 {
            let targetHeading: Float = headingOf(Vec2(wish.x, wish.z))
            let diff: Float = angleDiff(heading, targetHeading)
            let maxTurn: Float = (speed > 3 ? 9 : 12) * dt
            heading = wrapAngle(heading + clampf(diff, -maxTurn, maxTurn))
        }
        let step: Vec3 = headingForward(heading) * (speed * dt)
        var np: Vec3 = pos + step
        resolveCollisions(&np)
        // measured speed after collisions (so we stop animating when pushed against a wall)
        let moved: Float = simd_length(Vec3(np.x - pos.x, 0, np.z - pos.z)) / max(dt, 0.0001)
        if speed > 0.5 && moved < speed * 0.35 { speed = max(moved, 0) }
        pos = np
        if let w = ctx.world { pos.y = w.groundHeight(at: Vec2(pos.x, pos.z)) }
        node.simdPosition = pos
        node.simdEulerAngles = Vec3(0, heading, 0)

        applyLocomotionPose(dt: dt)
    }

    private func resolveCollisions(_ p: inout Vec3) {
        guard let w = ctx.world else { return }
        for _ in 0..<2 {
            let list: [Collider] = w.colliders.query(center: Vec2(p.x, p.z), radius: 2.5)
            for c in list {
                if c.radius > 0 {
                    let d: Vec2 = Vec2(p.x, p.z) - c.center
                    let l: Float = simd_length(d)
                    let minD: Float = c.radius + radius
                    if l < minD {
                        let n: Vec2 = l > 1e-4 ? d / l : Vec2(1, 0)
                        p.x = c.center.x + n.x * minD
                        p.z = c.center.y + n.y * minD
                    }
                } else {
                    let rel: Vec2 = Vec2(p.x, p.z) - c.center
                    let lft: Vec2 = headingLeft2(c.heading)
                    let fwd: Vec2 = headingForward2(c.heading)
                    var lx: Float = simd_dot(rel, lft)
                    var lz: Float = simd_dot(rel, fwd)
                    let cx: Float = clampf(lx, -c.halfExtents.x, c.halfExtents.x)
                    let cz: Float = clampf(lz, -c.halfExtents.y, c.halfExtents.y)
                    let dx: Float = lx - cx
                    let dz: Float = lz - cz
                    let dd: Float = sqrtf(dx * dx + dz * dz)
                    if dd < radius {
                        if dd > 1e-4 {
                            let k: Float = (radius - dd) / dd
                            lx += dx * k
                            lz += dz * k
                        } else {
                            // centre inside the box: leave through the nearest face
                            let px: Float = c.halfExtents.x - abs(lx)
                            let pz: Float = c.halfExtents.y - abs(lz)
                            if px < pz { lx = (lx >= 0 ? 1 : -1) * (c.halfExtents.x + radius) } else { lz = (lz >= 0 ? 1 : -1) * (c.halfExtents.y + radius) }
                        }
                        let world: Vec2 = c.center + lft * lx + fwd * lz
                        p.x = world.x
                        p.z = world.y
                    }
                }
            }
        }
    }

    // MARK: - Poses

    private func applyIdlePose(dt: Float) {
        guard let sv = solver else { return }
        var p = WPoseParams()
        let breathe: Float = sinf(time * 1.7)
        p.spinePitch = 0.012 * breathe
        p.headYaw = 0.05 * sinf(time * 0.45)
        p.hipsOffset = Vec3(0, 0, 0)
        p.leftFoot = Vec3(0.105, sv.restAnkleHeight, -0.04)
        p.rightFoot = Vec3(-0.105, sv.restAnkleHeight, -0.04)
        p.leftHand = Vec3(0.30, 1.03 + 0.004 * breathe, 0.02)
        p.rightHand = Vec3(-0.30, 1.03 + 0.004 * breathe, 0.02)
        p.leftElbowPole = Vec3(0.5, -0.2, -0.8)
        p.rightElbowPole = Vec3(-0.5, -0.2, -0.8)
        p.fingerCurl = 0.3
        p.thumbCurl = 0.15
        sv.apply(p)
    }

    private func applyLocomotionPose(dt: Float) {
        guard let sv = solver else { return }
        if speed < 0.12 {
            applyIdlePose(dt: dt)
            return
        }
        let strideLen: Float = clampf(0.95 + 0.42 * speed, 1.0, 3.4)
        gaitPhase += (speed / strideLen) * dt
        gaitPhase -= floorf(gaitPhase)
        let run: Float = smoothstep(2.4, 4.8, speed)
        let amp: Float = strideLen * 0.25
        let stepH: Float = lerpf(0.10, 0.26, run)
        let ankle: Float = sv.restAnkleHeight
        // hips lowered so the legs can reach the stride
        let legLen: Float = (sv.thigh + sv.shin) * 0.97
        let hipY: Float = sv.restHipsPos.y
        let neededDrop: Float = max(0, (hipY - ankle) - sqrtf(max(0, legLen * legLen - amp * amp)))
        let bob: Float = 0.018 * (1 - cosf(gaitPhase * Float.tau * 2)) * (0.6 + run)
        let drop: Float = neededDrop + bob

        var p = WPoseParams()
        p.hipsOffset = Vec3(0, -drop, 0)
        p.hipsPitch = 0.05 + run * 0.22
        let twist: Float = sinf(gaitPhase * Float.tau) * (0.10 + 0.10 * run)
        p.hipsYaw = twist
        p.spineYaw = -twist * 1.4
        p.spinePitch = 0.03 + run * 0.10
        p.headPitch = -(0.05 + run * 0.20)
        p.headYaw = twist * 0.5

        for side in 0..<2 {
            let left: Bool = side == 0
            let ph: Float = (gaitPhase + (left ? 0 : 0.5)).truncatingRemainder(dividingBy: 1)
            var z: Float = 0
            var lift: Float = 0
            if ph < 0.5 {
                let u: Float = ph / 0.5
                z = lerpf(amp, -amp, u)
            } else {
                let u: Float = (ph - 0.5) / 0.5
                z = lerpf(-amp, amp, smoothstep(0, 1, u))
                lift = sinf(u * Float.pi)
            }
            let x: Float = left ? 0.105 : -0.105
            let target = Vec3(x, ankle + lift * stepH, -0.04 + z)
            var pitch: Float = -0.10
            if ph < 0.5 { pitch = -0.12 + 0.75 * smoothstep(0.30, 0.50, ph) } else { pitch = 0.6 * (1 - smoothstep(0.5, 0.68, ph)) - 0.20 * smoothstep(0.8, 1.0, ph) }
            if left { p.leftFoot = target; p.leftFootPitch = pitch } else { p.rightFoot = target; p.rightFootPitch = pitch }
        }

        // arms swing opposite to the legs
        let swing: Float = 0.16 + 0.30 * run
        let handY: Float = lerpf(1.02, 1.28, run) - drop
        let handZ0: Float = lerpf(0.02, 0.30, run)
        let lz: Float = handZ0 - sinf(gaitPhase * Float.tau) * swing
        let rz: Float = handZ0 + sinf(gaitPhase * Float.tau) * swing
        let handX: Float = lerpf(0.30, 0.26, run)
        p.leftHand = Vec3(handX, handY + max(0, -sinf(gaitPhase * Float.tau)) * 0.05 * run, lz)
        p.rightHand = Vec3(-handX, handY + max(0, sinf(gaitPhase * Float.tau)) * 0.05 * run, rz)
        p.leftElbowPole = Vec3(0.5, -0.1, -0.9)
        p.rightElbowPole = Vec3(-0.5, -0.1, -0.9)
        p.fingerCurl = 0.35 + 0.4 * run
        p.thumbCurl = 0.2
        sv.apply(p)

        // footsteps when a foot plants
        let halfNow: Int = Int(floorf(gaitPhase * 2))
        if halfNow != stepIndex {
            stepIndex = halfNow
            playFootstep()
        }
    }

    private func playFootstep() {
        var sfx: SFX = SFX.footConcrete1
        let n: Int = Int.random(in: 0..<3)
        if location == PlayerLocation.house {
            let list: [SFX] = [SFX.footWood1, SFX.footWood2, SFX.footWood3]
            sfx = list[n]
        } else if location == PlayerLocation.garageBuilding {
            let list: [SFX] = [SFX.footConcrete1, SFX.footConcrete2, SFX.footConcrete3]
            sfx = list[n]
        } else if let w = ctx.world {
            let s: SurfaceType = w.surface(at: Vec2(pos.x, pos.z))
            if s == SurfaceType.grass || s == SurfaceType.dirt {
                let list: [SFX] = [SFX.footGrass1, SFX.footGrass2, SFX.footGrass1]
                sfx = list[n]
            } else {
                let list: [SFX] = [SFX.footConcrete1, SFX.footConcrete2, SFX.footConcrete3]
                sfx = list[n]
            }
        }
        let vol: Float = clampf(0.25 + speed * 0.09, 0.25, 0.8)
        ctx.audio.play(sfx, volume: vol, rate: 0.95 + Float.random(in: 0...0.12), position: pos)
    }

    // MARK: - Driving

    func beginDriving(car: PlayerCar) {
        mode = .driving
        seatBlend = 0
        seatStart = pos
        seatLean = -0.32
        speed = 0
        updateHeadVisibility()
        node.isHidden = false
        updateDriving(dt: 0.0166, car: car)
    }

    func updateDriving(dt: Float, car: PlayerCar) {
        guard mode == .driving else { return }
        guard let sv = solver else { return }
        seatBlend = min(1, seatBlend + dt / 0.85)
        let cp: CockpitRig = car.cockpit

        // place the avatar so its hips sit on the seat, following the car body (pitch / roll included)
        let carQ: simd_quatf = car.node.simdWorldOrientation
        let seatWorld: Vec3 = cp.seatHipWorld
        let hipsRest: Vec3 = sv.restHipsPos
        let targetPos: Vec3 = seatWorld - carQ.act(hipsRest)
        let t: Float = smoothstep(0, 1, seatBlend)
        var wp: Vec3 = seatStart + (targetPos - seatStart) * t
        wp.y += sinf(t * Float.pi) * 0.30
        node.simdWorldPosition = wp
        node.simdWorldOrientation = carQ
        // the avatar node is a child of the scene root, so the car's transform is applied directly

        // targets in avatar space
        let grips = cp.gripPointsWorld()
        let pedals = cp.pedalPointsWorld()
        func toAvatar(_ w: Vec3) -> Vec3 { return node.simdConvertPosition(w, from: nil) }
        let wristOffset = Vec3(0, -0.075, -0.05)
        let gl: Vec3 = toAvatar(grips.left) + wristOffset
        let gr: Vec3 = toAvatar(grips.right) + wristOffset

        var p = WPoseParams()
        p.hipsPitch = seatLean
        p.spinePitch = 0.06
        let steer: Float = ctx.state.steer
        p.headYaw = clampf(steer * 0.35, -0.5, 0.5)
        p.headPitch = 0.04
        p.spineYaw = clampf(steer * 0.10, -0.2, 0.2)
        p.leftHand = gl
        p.rightHand = gr
        p.leftElbowPole = Vec3(0.7, -0.5, -0.4)
        p.rightElbowPole = Vec3(-0.7, -0.5, -0.4)
        p.fingerCurl = 0.95
        p.thumbCurl = 0.6

        // feet: right foot on the throttle / brake, left foot on the dead pedal
        let thr: Vec3 = toAvatar(pedals.throttle)
        let brk: Vec3 = toAvatar(pedals.brake)
        let braking: Bool = ctx.state.brake > 0.08
        let rightPedal: Vec3 = braking ? brk : thr
        let ankleOffset = Vec3(0, 0.11, -0.15)
        p.rightFoot = rightPedal + ankleOffset
        p.leftFoot = brk + Vec3(0.13, 0, -0.02) + ankleOffset
        p.rightFootPitch = braking ? 0.95 : 0.85 + 0.25 * ctx.state.throttle
        p.leftFootPitch = 0.75
        p.leftKneePole = Vec3(0.3, 0.6, 1)
        p.rightKneePole = Vec3(-0.1, 0.6, 1)
        sv.apply(p)

        // if the hands cannot reach the wheel, lean the torso forward a little (smoothly)
        let ratio: Float = max(sv.leftReachRatio, sv.rightReachRatio)
        if ratio > 0.95 {
            seatLean = min(0.32, seatLean + dt * 0.9)
        } else if ratio < 0.86 && seatLean > -0.32 {
            seatLean = max(-0.32, seatLean - dt * 0.25)
        }
    }

    func endDriving(exit: Spawn) {
        mode = .walking
        pos = exit.position
        heading = exit.heading
        speed = 0
        camYaw = exit.heading
        camSnap = true
        node.simdWorldOrientation = simd_quatf(angle: 0, axis: Vec3(0, 1, 0))
        node.simdPosition = pos
        node.simdEulerAngles = Vec3(0, heading, 0)
        location = .outside
        updateHeadVisibility()
        applyIdlePose(dt: 0)
    }

    // MARK: - Bed

    /// `heading` = direction from the head toward the feet (avatar +Z); `position` = point on the mattress surface under the hips
    func lieInBed(position: Vec3, heading h: Float) {
        mode = .lying
        lyingPos = position
        heading = h
        pos = position
        node.simdWorldOrientation = simd_quatf(angle: 0, axis: Vec3(0, 1, 0))
        node.simdPosition = position
        node.simdEulerAngles = Vec3(0, h, 0)
        node.isHidden = false
        updateHeadVisibility()
        applyLyingPose()
    }

    private func applyLyingPose() {
        guard let sv = solver else { return }
        var p = WPoseParams()
        p.hipsPitch = -Float.pi * 0.5
        p.hipsOffset = Vec3(0, 0.13 - sv.restHipsPos.y, 0)
        let breathe: Float = sinf(time * 1.2)
        p.spinePitch = 0.02 * breathe
        p.headRoll = 0.15
        p.fingerCurl = 0.25
        p.thumbCurl = 0.1
        sv.apply(p)
    }

    func getUpFromBed(position: Vec3, heading h: Float) {
        place(position: position, heading: h, location: location)
    }

    // MARK: - Camera

    func updateCamera(_ rig: CameraRig, dt: Float) {
        if mode == .lying {
            let target: Vec3 = lyingPos + Vec3(0, 0.6, 0)
            let dirBack: Vec3 = headingForward(heading)
            let desired: Vec3 = target + dirBack * 2.4 + Vec3(0, 1.5, 0)
            rig.fov = 50
            rig.follow(desired: desired, lookAt: target, dt: dt, stiffness: 3, maxLag: 6)
            applyLyingPoseTick(dt)
            return
        }
        rig.fov = 62
        let inside: Bool = location != PlayerLocation.outside
        let dist: Float = inside ? 2.5 : 3.6
        let target: Vec3 = Vec3(pos.x, pos.y + 1.55, pos.z)
        let cp: Float = cosf(camPitch)
        let look: Vec3 = Vec3(sinf(camYaw) * cp, -sinf(camPitch), cosf(camYaw) * cp)
        var d: Float = dist
        // pull the camera in when a wall / building is in the way
        if let w = ctx.world {
            var s: Float = 0.5
            while s <= dist {
                let p: Vec3 = target - look * s
                if p.y < 0.25 { d = max(0.6, s - 0.3); break }
                if pointBlocked(Vec2(p.x, p.z), world: w) { d = max(0.6, s - 0.35); break }
                s += 0.25
            }
        }
        let desired: Vec3 = target - look * d
        if camSnap {
            camSnap = false
            rig.set(position: desired, lookAt: target)
        } else {
            rig.follow(desired: desired, lookAt: target, dt: dt, stiffness: 14, maxLag: 4)
        }
    }

    private func applyLyingPoseTick(_ dt: Float) {
        time += dt
        applyLyingPose()
    }

    private func pointBlocked(_ p: Vec2, world w: World) -> Bool {
        let list: [Collider] = w.colliders.query(center: p, radius: 0.3)
        for c in list {
            if c.kind == ColliderKind.lamp || c.kind == ColliderKind.sign || c.kind == ColliderKind.tree { continue }
            if c.radius > 0 {
                if simd_length(p - c.center) < c.radius { return true }
            } else {
                let rel: Vec2 = p - c.center
                let lx: Float = simd_dot(rel, headingLeft2(c.heading))
                let lz: Float = simd_dot(rel, headingForward2(c.heading))
                if abs(lx) < c.halfExtents.x && abs(lz) < c.halfExtents.y { return true }
            }
        }
        return false
    }
}
