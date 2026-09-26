import Foundation
import SceneKit
import simd
import UIKit

// MARK: - TrafficVehicle: an AI car (taxi / police).  It does NOT drive like the player: a kinematic bicycle model with a rate-limited,
// speed-sensitive steering angle follows a LanePath by pure pursuit; longitudinal control is the Intelligent Driver Model (smooth
// acceleration, comfortable braking, time headway to whatever is ahead: cars, pedestrians, the player, an intersection somebody else
// owns, the end of the route).  Cornering speed comes from the path curvature.  The visuals steer the front wheels, spin all four from
// the real travelled distance (omega = v / r) and pitch / roll the body from the accelerations.

enum TrafficKind {
    case taxi, police
}

struct TrafficBody {
    var id: Int
    var pos: Vec2
    var vel: Vec2
    var radius: Float
    var halfLength: Float
    var isPedestrian: Bool = false
    var isPlayer: Bool = false
}

struct TrafficSpec {
    var model: String
    var length: Float
    var halfWidth: Float
    var wheelbase: Float
    var wheelRadius: Float
    var mass: Float
    var aMax: Float
    var brake: Float
    var speedLimit: Float
    var frontAxleZ: Float
    var rearAxleZ: Float
    var track: Float
    var hubY: Float
    var bodyMinZ: Float
    var bodyMaxZ: Float
}

@MainActor
final class TrafficVehicle {
    let id: Int
    let kind: TrafficKind
    let node = SCNNode()
    private(set) var spec: TrafficSpec
    private unowned let manager: TrafficManager

    // state
    var pos: Vec2 = Vec2(0, 0)
    var heading: Float = 0
    var speed: Float = 0
    var steer: Float = 0
    var accel: Float = 0
    var lateralAccel: Float = 0
    var active: Bool = false

    // route
    var path: LanePath = LanePath(points: [Vec2(0, 0), Vec2(0, 5)], step: 1.5)
    var progress: Float = 0
    var routeNodes: [WGridNode] = []
    var speedLimit: Float = 13.9
    var aMax: Float = 2.4
    var brakeComfort: Float = 3.2
    var stopLineCaution: Bool = true
    var hold: Bool = false                       // stay put (passenger boarding, parked)
    private(set) var arrived: Bool = false       // reached the end of a path that stops there
    var crashedTimer: Float = 0
    var bumpVelocity: Vec2 = Vec2(0, 0)
    var offPathTimer: Float = 0
    var sirenOn: Bool = false
    var hazards: Bool = false

    // perception (10 Hz)
    private var perceiveTimer: Float = 0
    private var gapAhead: Float? = nil
    private var leadSpeed: Float = 0
    private var gapIsHard: Bool = false
    private var claimedKeys: [Int] = []

    // visuals
    private var bodyPivot = SCNNode()
    private var steerNodes: [SCNNode] = []
    private var wheelNodes: [SCNNode] = []
    private var steerRest: [simd_quatf] = []
    private var wheelSpin: [Float] = [0, 0, 0, 0]       // FL FR RL RR
    private var lampL: SCNNode? = nil
    private var lampR: SCNNode? = nil
    private var brakeMat: SCNMaterial = SCNMaterial()
    private var headMat: SCNMaterial = SCNMaterial()
    private var lampLMat: SCNMaterial? = nil
    private var lampRMat: SCNMaterial? = nil
    private var pitch: Float = 0
    private var roll: Float = 0
    private var sirenPhase: Float = 0
    private var brakeLit: Bool = false
    private var headLit: Bool = false
    private var wheelSlot: [String: Int] = ["FL": 0, "FR": 1, "RL": 2, "RR": 3]
    private var wheelByTag: [String: SCNNode] = [:]
    private var steerByTag: [String: SCNNode] = [:]

    init(id: Int, kind: TrafficKind, spec: TrafficSpec, manager: TrafficManager) {
        self.id = id
        self.kind = kind
        self.spec = spec
        self.manager = manager
        node.name = "traffic\(id)"
        speedLimit = spec.speedLimit
        aMax = spec.aMax
        brakeComfort = spec.brake
    }

    var length: Float { return spec.length }
    var halfWidth: Float { return spec.halfWidth }

    // MARK: visuals

    func buildVisual(assets: AssetLibrary) -> Bool {
        let model: SCNNode
        do {
            model = try assets.model(spec.model)
        } catch {
            assetLog("traffic model \(spec.model) failed: \(error.localizedDescription)")
            return false
        }
        // body + lamps go under a pivot so they can pitch / roll on the suspension while the wheels stay on the road
        node.addChildNode(bodyPivot)
        bodyPivot.simdPosition = Vec3(0, 0.35, 0)
        var bodyParts: [SCNNode] = []
        for child in model.childNodes {
            let nm: String = child.name ?? ""
            if nm == "body" || nm.hasPrefix("lamp") { bodyParts.append(child) }
        }
        for part in bodyParts {
            let t: simd_float4x4 = part.simdWorldTransform
            bodyPivot.addChildNode(part)
            part.simdWorldTransform = t
            if part.name == "lamp_L" || part.name == "lamp_R" {
                // own geometry + material per vehicle, so one truck's siren never lights another's lamps
                if let geo = part.geometry?.copy() as? SCNGeometry, let mat = geo.firstMaterial?.copy() as? SCNMaterial {
                    geo.materials = [mat]
                    part.geometry = geo
                }
                if part.name == "lamp_L" { lampL = part } else { lampR = part }
            }
        }
        // the remaining children (steer_XX, wheel_XX) stay directly under the vehicle node
        let rest: [SCNNode] = Array(model.childNodes)
        for c in rest { node.addChildNode(c) }
        for tag in ["FL", "FR"] {
            if let s = node.childNode(withName: "steer_" + tag, recursively: false) {
                steerByTag[tag] = s
                if let w = s.childNode(withName: "wheel_" + tag, recursively: false) { wheelByTag[tag] = w }
            }
        }
        for tag in ["RL", "RR"] {
            if let w = node.childNode(withName: "wheel_" + tag, recursively: false) { wheelByTag[tag] = w }
        }
        node.enumerateHierarchy { (n: SCNNode, _: UnsafeMutablePointer<ObjCBool>) in
            if n.geometry != nil {
                n.castsShadow = true
                n.categoryBitMask = 1
            }
        }
        // lights: small emissive lenses
        let bm = SCNMaterial()
        bm.lightingModel = SCNMaterial.LightingModel.constant
        bm.diffuse.contents = UIColor(red: 0.30, green: 0.02, blue: 0.02, alpha: 1)
        bm.emission.contents = UIColor(red: 1.0, green: 0.05, blue: 0.04, alpha: 1)
        bm.emission.intensity = 0
        brakeMat = bm
        let hm = SCNMaterial()
        hm.lightingModel = SCNMaterial.LightingModel.constant
        hm.diffuse.contents = UIColor(red: 0.75, green: 0.75, blue: 0.70, alpha: 1)
        hm.emission.contents = UIColor(red: 1.0, green: 0.92, blue: 0.75, alpha: 1)
        hm.emission.intensity = 0
        headMat = hm
        let ly: Float = kind == TrafficKind.police ? 0.95 : 0.80
        for sx in [Float(-1), Float(1)] {
            let rear = SCNBox(width: 0.34, height: 0.10, length: 0.05, chamferRadius: 0.01)
            rear.materials = [bm]
            let rn = SCNNode(geometry: rear)
            rn.simdPosition = Vec3(sx * (spec.halfWidth - 0.32), ly - 0.35, spec.bodyMinZ + 0.03)
            bodyPivot.addChildNode(rn)
            let front = SCNBox(width: 0.32, height: 0.10, length: 0.05, chamferRadius: 0.01)
            front.materials = [hm]
            let fn = SCNNode(geometry: front)
            fn.simdPosition = Vec3(sx * (spec.halfWidth - 0.36), 0.70 - 0.35, spec.bodyMaxZ - 0.03)
            bodyPivot.addChildNode(fn)
        }
        if kind == TrafficKind.police {
            if let m = lampL?.geometry?.firstMaterial { lampLMat = m }
            if let m = lampR?.geometry?.firstMaterial { lampRMat = m }
        }
        node.isHidden = true
        return true
    }

    // MARK: lifecycle

    func place(pos p: Vec2, heading h: Float, path newPath: LanePath, nodes: [WGridNode]) {
        pos = p
        heading = h
        speed = 0
        steer = 0
        accel = 0
        crashedTimer = 0
        bumpVelocity = Vec2(0, 0)
        arrived = false
        hold = false
        path = newPath
        routeNodes = nodes
        progress = 0
        claimedKeys.removeAll()
        active = true
        node.isHidden = false
        applyTransform()
    }

    func deactivate() {
        releaseClaims()
        active = false
        node.isHidden = true
    }

    func setPath(_ newPath: LanePath, nodes: [WGridNode]) {
        releaseClaims()
        path = newPath
        routeNodes = nodes
        progress = newPath.project(pos, hintS: 0, window: 60).s
        arrived = false
    }

    private func releaseClaims() {
        for k in claimedKeys { manager.release(intersection: k, by: id) }
        claimedKeys.removeAll()
    }

    var body: TrafficBody {
        let f: Vec2 = headingForward2(heading)
        return TrafficBody(id: id, pos: pos, vel: f * speed, radius: spec.halfWidth + 0.15, halfLength: spec.length * 0.5)
    }

    var remainingDistance: Float { return max(0, path.length - progress) }

    /// speed limit for the current section (police in pursuit override it)
    private func effectiveLimit() -> Float { return speedLimit }

    // MARK: dynamics

    func update(dt: Float, detailed: Bool) {
        if !active { return }
        if crashedTimer > 0 {
            crashedTimer -= dt
            speed = max(0, speed - 9 * dt)
        }
        // ---- progress along the lane
        let pr = path.project(pos, hintS: progress)
        progress = pr.s
        if pr.distance > 7 { offPathTimer += dt } else { offPathTimer = 0 }

        // ---- perception at 10 Hz (or every frame while in trouble)
        perceiveTimer -= dt
        if perceiveTimer <= 0 {
            perceiveTimer = detailed ? 0.1 : 0.4
            perceive()
        }

        // ---- longitudinal: IDM
        var vFree: Float = min(effectiveLimit(), path.capAt(s: progress))
        if crashedTimer > 0 || hold { vFree = 0 }
        var a: Float = idm(vFree: vFree)
        if hold {
            // hard hold: brake to a standstill
            a = -max(2, speed * 2)
        }
        a = clampf(a, -9, aMax)
        accel = damp(accel, a, 12, dt)
        var v: Float = speed + accel * dt
        if v < 0 { v = 0 }
        if hold && v < 0.05 { v = 0 }
        let prev: Float = speed
        speed = v

        // arrived: the path ends in a stop and we are at it
        if path.stopsAtEnd && (path.length - progress) < 1.6 && speed < 0.4 {
            arrived = true
        }

        // ---- lateral: pure pursuit with a rate-limited steering angle
        let ld: Float = clampf(3.0 + speed * 0.6, 3.5, 16)
        let target = path.sample(progress + ld)
        let fwd: Vec2 = headingForward2(heading)
        let toT: Vec2 = target.pos - pos
        var alpha: Float = 0
        if simd_length(toT) > 0.1 {
            alpha = angleDiff(heading, headingOf(toT))
        }
        var delta: Float = atan2f(2 * spec.wheelbase * sinf(alpha), ld)
        let maxDelta: Float = 0.55 / (1 + powf(speed / 15, 2))
        delta = clampf(delta, -maxDelta, maxDelta)
        let rate: Float = 1.3 / (1 + speed / 20)
        steer += clampf(delta - steer, -rate * dt, rate * dt)

        if speed > 0.01 || abs(bumpVelocity.x) + abs(bumpVelocity.y) > 0.01 {
            let yawRate: Float = speed * tanf(steer) / spec.wheelbase
            heading = wrapAngle(heading + yawRate * dt)
            lateralAccel = yawRate * speed
            let f2: Vec2 = headingForward2(heading)
            pos += f2 * (speed * dt) + bumpVelocity * dt
            bumpVelocity = bumpVelocity * expf(-3.5 * dt)
        } else {
            lateralAccel = 0
        }
        _ = fwd
        let longAccel: Float = dt > 0 ? (speed - prev) / dt : 0
        pitch = damp(pitch, clampf(-0.0042 * longAccel, -0.06, 0.06), 8, dt)
        roll = damp(roll, clampf(0.0045 * lateralAccel, -0.06, 0.06), 8, dt)

        // ---- intersections passed: release claims
        for m in path.marks where progress > m.s + 14 {
            if claimedKeys.contains(m.key) {
                manager.release(intersection: m.key, by: id)
                claimedKeys.removeAll(where: { $0 == m.key })
            }
        }
        applyTransform()
        if detailed { animateVisual(dt: dt) }
    }

    private func idm(vFree: Float) -> Float {
        let a: Float = aMax
        let b: Float = brakeComfort
        let v: Float = speed
        let free: Float = 1 - powf(v / max(vFree, 0.4), 4)
        var interaction: Float = 0
        if let g = gapAhead {
            let s0: Float = gapIsHard ? 1.0 : 2.4
            let T: Float = 1.25
            let dv: Float = v - leadSpeed
            let sStar: Float = s0 + max(0, v * T + v * dv / (2 * sqrtf(a * b)))
            let r: Float = sStar / max(g, 0.15)
            interaction = r * r
        }
        return a * (free - interaction)
    }

    // MARK: perception

    private func perceive() {
        gapAhead = nil
        leadSpeed = 0
        gapIsHard = false
        let look: Float = max(28, speed * 3.6 + 14)
        var bestGap: Float = Float.greatestFiniteMagnitude
        var bestLead: Float = 0

        // ---- moving / standing obstacles that intersect the planned lane
        let half: Float = spec.halfWidth
        for b in manager.bodies(near: pos, radius: look + 6, excluding: id) {
            let clear: Float = half + b.radius + (b.isPedestrian ? 0.55 : 0.45)
            var d: Float = 1.0
            while d < look {
                let q: Vec2 = path.sample(progress + d).pos
                let dist: Float = simd_distance(q, b.pos)
                if dist < clear {
                    let ahead: Float = d - spec.length * 0.5 - b.halfLength
                    if ahead < bestGap {
                        bestGap = ahead
                        let tan: Vec2 = path.sample(progress + d).tan
                        bestLead = max(0, simd_dot(b.vel, tan))
                        if b.isPedestrian || b.isPlayer { bestLead = min(bestLead, simd_length(b.vel)) }
                    }
                    break
                }
                d += 1.5
            }
        }

        // ---- the end of a route that stops
        if path.stopsAtEnd {
            let g: Float = (path.length - progress) - 0.2
            if g < bestGap {
                bestGap = g
                bestLead = 0
                gapIsHard = true
            }
        }

        // ---- intersections: first come, first served
        for m in path.marks {
            let dc: Float = m.s - progress
            if dc < -6 || dc > 34 { continue }
            let owner: Int? = manager.claimOwner(of: m.key)
            if owner == nil || owner == id {
                if manager.claim(intersection: m.key, by: id) && !claimedKeys.contains(m.key) { claimedKeys.append(m.key) }
            } else if dc > 6 {
                // somebody else is using it: stop at the line
                let line: Float = WGrid.corridor(TrafficRouter.line(path.sample(m.s).tan, m.node)) + 3.0
                let g: Float = dc - line
                if g < bestGap {
                    bestGap = g
                    bestLead = 0
                    gapIsHard = true
                }
            }
            break
        }
        if bestGap < Float.greatestFiniteMagnitude {
            gapAhead = max(bestGap, 0.05)
            leadSpeed = bestLead
        }
    }

    // MARK: transform + visuals

    func applyTransform() {
        node.simdPosition = Vec3(pos.x, 0, pos.y)
        node.simdEulerAngles = Vec3(0, heading, 0)
    }

    func bump(velocity v: Vec2, yaw: Float) {
        bumpVelocity += v
        heading = wrapAngle(heading + yaw)
        speed = max(0, speed - simd_length(v) * 0.5)
        if simd_length(v) > 3 { crashedTimer = 3.5 }
    }

    private func animateVisual(dt: Float) {
        // wheels: omega = v / r, integrated (reverse never happens here, the phase only runs forward)
        let dphi: Float = speed / spec.wheelRadius * dt
        for k in 0..<4 { wheelSpin[k] = (wheelSpin[k] + dphi).truncatingRemainder(dividingBy: Float.tau) }
        // Ackermann: the inner wheel turns more
        let d: Float = steer
        var dl: Float = d
        var dr: Float = d
        if abs(d) > 0.001 {
            let t: Float = tanf(abs(d))
            let inner: Float = atanf(spec.wheelbase * t / max(0.5, spec.wheelbase - spec.track * 0.5 * t))
            let outer: Float = atanf(spec.wheelbase * t / (spec.wheelbase + spec.track * 0.5 * t))
            if d > 0 {
                dl = inner
                dr = outer
            } else {
                dl = -outer
                dr = -inner
            }
        }
        if let s = steerByTag["FL"] { s.simdOrientation = simd_quatf(angle: dl, axis: Vec3(0, 1, 0)) }
        if let s = steerByTag["FR"] { s.simdOrientation = simd_quatf(angle: dr, axis: Vec3(0, 1, 0)) }
        for (tag, slot) in wheelSlot {
            if let w = wheelByTag[tag] { w.simdOrientation = simd_quatf(angle: wheelSpin[slot], axis: Vec3(1, 0, 0)) }
        }
        bodyPivot.simdOrientation = simd_quatf(angle: pitch, axis: Vec3(1, 0, 0)) * simd_quatf(angle: roll, axis: Vec3(0, 0, 1))

        // lights
        let braking: Bool = accel < -0.6 || (speed < 0.2 && !hold) || hold
        if braking != brakeLit {
            brakeLit = braking
            brakeMat.emission.intensity = braking ? 1.4 : 0
        }
        let night: Bool = manager.isNight
        if night != headLit {
            headLit = night
            headMat.emission.intensity = night ? 1.6 : 0
        }
        if kind == TrafficKind.police {
            if sirenOn {
                sirenPhase += dt * 7
                let a: Bool = sinf(sirenPhase) > 0
                setLamp(lampLMat, on: a, red: false)
                setLamp(lampRMat, on: !a, red: true)
            } else {
                setLamp(lampLMat, on: false, red: false)
                setLamp(lampRMat, on: false, red: true)
            }
        }
    }

    private func setLamp(_ m: SCNMaterial?, on: Bool, red: Bool) {
        guard let m = m else { return }
        let c: UIColor = red ? UIColor(red: 1.0, green: 0.05, blue: 0.05, alpha: 1) : UIColor(red: 0.15, green: 0.35, blue: 1.0, alpha: 1)
        m.emission.contents = c
        m.emission.intensity = on ? 2.2 : 0
    }
}
