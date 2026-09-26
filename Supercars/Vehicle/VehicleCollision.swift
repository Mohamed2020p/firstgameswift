import Foundation
import simd

// MARK: - Car (oriented box) vs static colliders (circles / oriented boxes) with a proper 2D impulse response.

struct VehicleImpact {
    var speed: Float = 0            // closing speed along the contact normal (m/s)
    var point: Vec2 = Vec2(0, 0)
    var normal: Vec2 = Vec2(0, 0)   // from the obstacle toward the car
    var destructible: Bool = false
    var scrapeSpeed: Float = 0      // tangential sliding speed while in contact
    var mass: Float = 0
}

/// cross-product-like helper: torque of force `f` applied at lever arm `rv` (positive = increasing heading)
@inline(__always) func vehicleTorque(_ rv: Vec2, _ f: Vec2) -> Float {
    return rv.y * f.x - rv.x * f.y
}

final class VehicleCollisionSolver {
    var halfLength: Float = 2.38
    var halfWidth: Float = 1.02
    /// forward offset of the box centre from the centre of gravity (metres)
    var centreOffset: Float = 0.126

    private(set) var frameImpact: VehicleImpact = VehicleImpact()
    private(set) var frameScrape: Float = 0
    private var struck: Set<Int> = []
    var restitution: Float = 0.15
    var wallFriction: Float = 0.30

    func beginFrame() {
        frameImpact = VehicleImpact()
        frameScrape = 0
        if struck.count > 64 { struck.removeAll() }
    }

    func forgetStruck() { struck.removeAll() }

    /// Resolves all contacts for the current pose.  `strike` is called for destructible colliders hit at speed and returns the
    /// fraction of momentum absorbed.  Returns the strongest impact of this call (speed 0 when nothing happened).
    @discardableResult
    func resolve(_ p: VehiclePhysics, colliders: [Collider], strike: (Collider, Float, Vec2) -> Float) -> Float {
        var strongest: Float = 0
        if colliders.isEmpty { return 0 }
        for _ in 0..<2 {
            var any: Bool = false
            for c in colliders {
                if struck.contains(c.id) { continue }
                let s: Float = contact(p, c, strike: strike)
                if s > 0 { any = true }
                if s > strongest { strongest = s }
            }
            if !any { break }
        }
        return strongest
    }

    // returns the closing speed if a contact was processed, else 0 (also 0.0001 for resting contacts so the caller iterates)
    private func contact(_ p: VehiclePhysics, _ c: Collider, strike: (Collider, Float, Vec2) -> Float) -> Float {
        let fwd: Vec2 = p.forward2
        let lft: Vec2 = p.left2
        let cg: Vec2 = Vec2(p.x, p.z)
        let centre: Vec2 = cg + fwd * centreOffset
        let hl: Float = halfLength
        let hw: Float = halfWidth
        var n: Vec2 = Vec2(0, 0)
        var pen: Float = 0
        var pt: Vec2 = centre

        if c.radius > 0 {
            let rel: Vec2 = c.center - centre
            let lx: Float = simd_dot(rel, lft)
            let lz: Float = simd_dot(rel, fwd)
            let cx: Float = clampf(lx, -hw, hw)
            let cz: Float = clampf(lz, -hl, hl)
            let dx: Float = lx - cx
            let dz: Float = lz - cz
            let dist: Float = sqrtf(dx * dx + dz * dz)
            if dist >= c.radius { return 0 }
            var nl: Vec2 = Vec2(0, 0)      // local (left, forward) direction from car toward the obstacle
            if dist > 1e-4 {
                nl = Vec2(dx / dist, dz / dist)
                pen = c.radius - dist
            } else {
                let penX: Float = hw - abs(lx)
                let penZ: Float = hl - abs(lz)
                if penX < penZ {
                    nl = Vec2(lx >= 0 ? 1 : -1, 0)
                    pen = penX + c.radius
                } else {
                    nl = Vec2(0, lz >= 0 ? 1 : -1)
                    pen = penZ + c.radius
                }
            }
            let toObstacle: Vec2 = lft * nl.x + fwd * nl.y
            n = Vec2(-toObstacle.x, -toObstacle.y)
            pt = centre + lft * cx + fwd * cz
        } else {
            let cf: Vec2 = headingForward2(c.heading)
            let cl: Vec2 = headingLeft2(c.heading)
            let diff: Vec2 = centre - c.center
            let axes: [Vec2] = [fwd, lft, cf, cl]
            var best: Float = Float.greatestFiniteMagnitude
            var bestAxis: Vec2 = fwd
            for axis in axes {
                let rA: Float = hl * abs(simd_dot(fwd, axis)) + hw * abs(simd_dot(lft, axis))
                let rB: Float = c.halfExtents.y * abs(simd_dot(cf, axis)) + c.halfExtents.x * abs(simd_dot(cl, axis))
                let d: Float = simd_dot(diff, axis)
                let overlap: Float = rA + rB - abs(d)
                if overlap <= 0 { return 0 }
                if overlap < best {
                    best = overlap
                    bestAxis = d >= 0 ? axis : Vec2(-axis.x, -axis.y)
                }
            }
            n = bestAxis
            pen = best
            let sf: Float = simd_dot(n, fwd) > 0 ? -hl : hl
            let sl: Float = simd_dot(n, lft) > 0 ? -hw : hw
            pt = centre + fwd * sf + lft * sl
        }

        // velocity of the contact point
        let cgv: Vec2 = cg
        let rv: Vec2 = pt - cgv
        let vel: Vec2 = p.worldVelocity()
        let spin: Vec2 = Vec2(rv.y, -rv.x) * p.r
        let vc: Vec2 = vel + spin
        let vn: Float = simd_dot(vc, n)

        // destructible things: absorb momentum instead of blocking
        if c.destructible {
            let toward: Vec2 = (c.center - centre).normalizedSafe
            let approach: Float = simd_dot(vel, toward)
            if approach > 1.5 {
                let speed: Float = vel.length
                let dir: Vec2 = vel.normalizedSafe
                struck.insert(c.id)
                let f: Float = clampf(strike(c, speed, dir), 0, 0.95)
                let nv: Vec2 = vel * (1 - f)
                p.setWorldVelocity(nv)
                let lever: Float = simd_dot(rv, p.left2)
                p.r = clampf(p.r + clampf(-lever * speed * 0.012 * f, -0.6, 0.6), -6, 6)
                registerImpact(speed: speed * f + 1, point: pt, normal: n, destructible: true, scrape: 0, mass: c.mass)
                return speed
            }
        }

        // positional correction (static obstacle: the car moves out)
        p.x += n.x * (pen + 0.004)
        p.z += n.y * (pen + 0.004)
        let cgNow: Vec2 = Vec2(p.x, p.z)
        let rv2: Vec2 = pt + n * (pen + 0.004) - cgNow
        if vn >= 0 { return 0.0001 }

        let m: Float = p.mass
        let I: Float = p.yawInertia
        let rn: Float = vehicleTorque(rv2, n)
        let invM: Float = 1 / m + rn * rn / I
        let e: Float = vn < -3 ? restitution : 0
        let j: Float = -(1 + e) * vn / invM
        let tang: Vec2 = Vec2(-n.y, n.x)
        let vt: Float = simd_dot(vc, tang)
        let rt: Float = vehicleTorque(rv2, tang)
        let invMt: Float = 1 / m + rt * rt / I
        let jt: Float = clampf(-vt / invMt, -wallFriction * j, wallFriction * j)
        let J: Vec2 = n * j + tang * jt
        let nvel: Vec2 = vel + J / m
        p.setWorldVelocity(nvel)
        p.r = clampf(p.r + vehicleTorque(rv2, J) / I, -6, 6)
        registerImpact(speed: -vn, point: pt, normal: n, destructible: false, scrape: abs(vt), mass: 0)
        return -vn
    }

    private func registerImpact(speed: Float, point: Vec2, normal: Vec2, destructible: Bool, scrape: Float, mass: Float) {
        if speed > frameImpact.speed {
            frameImpact.speed = speed
            frameImpact.point = point
            frameImpact.normal = normal
            frameImpact.destructible = destructible
            frameImpact.mass = mass
        }
        if scrape > frameScrape { frameScrape = scrape }
        frameImpact.scrapeSpeed = frameScrape
    }

    /// true when a disc of `radius` at `p` touches any collider
    static func isBlocked(_ p: Vec2, radius: Float, colliders: [Collider]) -> Bool {
        for c in colliders {
            if c.radius > 0 {
                let d: Float = simd_distance(p, c.center)
                if d < c.radius + radius { return true }
            } else {
                let rel: Vec2 = p - c.center
                let cf: Vec2 = headingForward2(c.heading)
                let cl: Vec2 = headingLeft2(c.heading)
                let lx: Float = simd_dot(rel, cl)
                let lz: Float = simd_dot(rel, cf)
                let qx: Float = abs(lx) - c.halfExtents.x
                let qz: Float = abs(lz) - c.halfExtents.y
                let ox: Float = max(qx, 0)
                let oz: Float = max(qz, 0)
                if sqrtf(ox * ox + oz * oz) < radius && (qx < radius && qz < radius) { return true }
            }
        }
        return false
    }
}
