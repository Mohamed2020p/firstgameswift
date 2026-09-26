import Foundation
import simd

// MARK: - Resampled race route (uniform spacing, smoothed corners, curvature, speed profile).  Pure data, no SceneKit.

struct RouteLocation {
    var index: Int = 0
    var s: Float = 0             // arclength along the route (0 ... length)
    var lateral: Float = 0       // > 0 = left of the driving direction
    var tangent: Vec2 = Vec2(0, 1)
    var distance: Float = 0      // distance from the centre line
}

struct RoutePath {
    let count: Int
    let step: Float
    let length: Float
    let closed: Bool
    let halfWidth: Float
    let points: [Vec2]
    let tangents: [Vec2]
    let curvature: [Float]       // signed, 1/m, + = turning left

    init?(route: RaceRoute, spacing: Float) {
        var pts: [Vec2] = route.points
        let isClosed: Bool = route.closed
        if isClosed && pts.count > 2 {
            if simd_distance(pts[0], pts[pts.count - 1]) < 0.5 { pts.removeLast() }
        }
        if pts.count < 2 { return nil }
        let segCount: Int = isClosed ? pts.count : pts.count - 1
        var cum: [Float] = [0]
        for i in 0..<segCount {
            let a: Vec2 = pts[i]
            let b: Vec2 = pts[(i + 1) % pts.count]
            cum.append(cum[i] + simd_distance(a, b))
        }
        let total: Float = cum[segCount]
        if total < 20 { return nil }
        let n: Int = max(8, Int((total / spacing).rounded()))
        let st: Float = total / Float(n)
        let outCount: Int = isClosed ? n : n + 1
        var res: [Vec2] = []
        var seg: Int = 0
        for k in 0..<outCount {
            let s: Float = Float(k) * st
            while seg < segCount - 1 && cum[seg + 1] < s { seg += 1 }
            let a: Vec2 = pts[seg]
            let b: Vec2 = pts[(seg + 1) % pts.count]
            let l: Float = max(cum[seg + 1] - cum[seg], 1e-4)
            let t: Float = clampf((s - cum[seg]) / l, 0, 1)
            res.append(a + (b - a) * t)
        }
        for _ in 0..<3 { res = RoutePath.smooth(res, closed: isClosed) }

        let cnt: Int = res.count
        var tans: [Vec2] = []
        for i in 0..<cnt {
            let ip: Int = RoutePath.wrap(i - 1, cnt, isClosed)
            let inx: Int = RoutePath.wrap(i + 1, cnt, isClosed)
            var t: Vec2 = (res[inx] - res[ip]).normalizedSafe
            if t == Vec2(0, 0) { t = Vec2(0, 1) }
            tans.append(t)
        }
        var curv: [Float] = []
        for i in 0..<cnt {
            let ip: Int = RoutePath.wrap(i - 1, cnt, isClosed)
            let inx: Int = RoutePath.wrap(i + 1, cnt, isClosed)
            let h0: Float = headingOf(tans[ip])
            let h1: Float = headingOf(tans[inx])
            curv.append(angleDiff(h0, h1) / (2 * st))
        }
        curv = RoutePath.smoothScalar(curv, closed: isClosed)
        curv = RoutePath.smoothScalar(curv, closed: isClosed)

        self.count = cnt
        self.step = st
        self.length = isClosed ? st * Float(cnt) : st * Float(cnt - 1)
        self.closed = isClosed
        self.halfWidth = max(4, route.width * 0.5)
        self.points = res
        self.tangents = tans
        self.curvature = curv
    }

    static func wrap(_ i: Int, _ n: Int, _ closed: Bool) -> Int {
        if closed {
            let m: Int = i % n
            return m < 0 ? m + n : m
        }
        return max(0, min(n - 1, i))
    }

    private static func smooth(_ p: [Vec2], closed: Bool) -> [Vec2] {
        let n: Int = p.count
        var out: [Vec2] = p
        for i in 0..<n {
            if !closed && (i == 0 || i == n - 1) { continue }
            var sum: Vec2 = Vec2(0, 0)
            var wsum: Float = 0
            for k in -2...2 {
                let w: Float = k == 0 ? 3 : (abs(k) == 1 ? 2 : 1)
                sum += p[wrap(i + k, n, closed)] * w
                wsum += w
            }
            out[i] = sum / wsum
        }
        return out
    }

    private static func smoothScalar(_ p: [Float], closed: Bool) -> [Float] {
        let n: Int = p.count
        var out: [Float] = p
        for i in 0..<n {
            var sum: Float = 0
            for k in -2...2 { sum += p[wrap(i + k, n, closed)] }
            out[i] = sum / 5
        }
        return out
    }

    func index(_ i: Int) -> Int { return RoutePath.wrap(i, count, closed) }

    func wrapS(_ s: Float) -> Float {
        if closed {
            var r: Float = s.truncatingRemainder(dividingBy: length)
            if r < 0 { r += length }
            return r
        }
        return s
    }

    /// point at arclength s (wraps on closed routes, extrapolates on open ones) and lateral offset (+ = left)
    func point(atS s: Float, lateral: Float) -> (pos: Vec2, tan: Vec2) {
        if !closed && s < 0 {
            let t: Vec2 = tangents[0]
            return (points[0] + t * s + t.leftPerp * lateral, t)
        }
        if !closed && s > length {
            let t: Vec2 = tangents[count - 1]
            return (points[count - 1] + t * (s - length) + t.leftPerp * lateral, t)
        }
        let ws: Float = wrapS(s)
        let f: Float = ws / step
        let i0f: Float = floorf(f)
        let t: Float = f - i0f
        let i0: Int = index(Int(i0f))
        let i1: Int = index(Int(i0f) + 1)
        let p: Vec2 = points[i0] + (points[i1] - points[i0]) * t
        var tn: Vec2 = (tangents[i0] * (1 - t) + tangents[i1] * t).normalizedSafe
        if tn == Vec2(0, 0) { tn = tangents[i0] }
        return (p + tn.leftPerp * lateral, tn)
    }

    func curvatureAt(s: Float) -> Float {
        let ws: Float = wrapS(s)
        return curvature[index(Int(ws / step))]
    }

    /// nearest point on the centre line; `hint` (sample index) restricts the search to a window for continuity
    func locate(_ p: Vec2, hint: Int?, window: Int) -> RouteLocation {
        var best: Int = 0
        var bestD: Float = Float.greatestFiniteMagnitude
        if let h = hint {
            for k in -window...window {
                let i: Int = index(h + k)
                let dd: Float = simd_distance_squared(points[i], p)
                if dd < bestD {
                    bestD = dd
                    best = i
                }
            }
        } else {
            for i in 0..<count {
                let dd: Float = simd_distance_squared(points[i], p)
                if dd < bestD {
                    bestD = dd
                    best = i
                }
            }
        }
        let along: Float = simd_dot(p - points[best], tangents[best])
        var k0: Int = best
        var k1: Int = index(best + 1)
        if along < 0 {
            k0 = index(best - 1)
            k1 = best
        }
        if !closed && k0 == k1 {
            k0 = index(best - 1)
            k1 = best
        }
        let seg: Vec2 = points[k1] - points[k0]
        let sl2: Float = max(simd_dot(seg, seg), 1e-6)
        let t: Float = clampf(simd_dot(p - points[k0], seg) / sl2, 0, 1)
        let proj: Vec2 = points[k0] + seg * t
        var tn: Vec2 = (tangents[k0] * (1 - t) + tangents[k1] * t).normalizedSafe
        if tn == Vec2(0, 0) { tn = tangents[k0] }
        var out: RouteLocation = RouteLocation()
        out.index = k0
        var s: Float = Float(k0) * step + t * step
        if closed && k1 < k0 { s = Float(k0) * step + t * step }
        out.s = closed ? wrapS(s) : s
        if !closed && best == 0 && along < 0 { out.s = along }
        if !closed && best == count - 1 && along > 0 { out.s = length + along }
        out.lateral = simd_dot(p - proj, tn.leftPerp)
        out.tangent = tn
        out.distance = simd_distance(p, proj)
        return out
    }

    /// Curvature-limited speed for every sample (sim.py Track.speed_profile): friction + downforce, then braking and acceleration passes.
    func speedProfile(skill: Float, topSpeed: Float) -> [Float] {
        let g: Float = 9.81
        let n: Int = count
        let grip: Float = 1.30 * g * skill
        let kdf: Float = 0.9 / (95 * 95)
        var v: [Float] = []
        for i in 0..<n {
            let R: Float = 1 / max(abs(curvature[i]), 1e-5)
            let denom: Float = 1 - grip * kdf * R
            var v2: Float = topSpeed * topSpeed
            if denom > 0.05 { v2 = grip * R / max(denom, 0.05) }
            v.append(min(sqrtf(v2), topSpeed))
        }
        let passes: Int = closed ? 2 : 1
        let ds: Float = step
        for _ in 0..<passes {
            // braking pass (backwards)
            var i: Int = closed ? 2 * n - 1 : n - 2
            while i >= 0 {
                let j: Int = i % n
                let i1: Int = closed ? (i + 1) % n : min(n - 1, i + 1)
                let aBrk: Float = (13.0 + 0.0022 * v[i1] * v[i1]) * skill
                v[j] = min(v[j], sqrtf(v[i1] * v[i1] + 2 * aBrk * ds))
                i -= 1
            }
            // acceleration pass (forwards)
            let last: Int = closed ? 2 * n - 1 : n - 2
            var k: Int = 0
            while k <= last {
                let i0: Int = k % n
                let j: Int = closed ? (k + 1) % n : min(n - 1, k + 1)
                let vv: Float = v[i0]
                let aAcc: Float = min(8.5, 330e3 * skill / (1300 * max(vv, 8))) - 0.0009 * vv * vv
                v[j] = min(v[j], sqrtf(vv * vv + 2 * max(aAcc, 0.3) * ds))
                k += 1
            }
        }
        return v
    }
}

// MARK: - AI driver: follows the route with lane offsets, curvature speed profile, simple avoidance and rubber-banding.
// Kinematic (no tyre model): pose = route point at progress `s` + lateral offset, heading from the path tangent plus lateral drift.

struct AIObstacle {
    var ds: Float           // obstacle progress minus my progress (metres, wrapped)
    var lateral: Float
    var speed: Float
}

final class AIDriver {
    let path: RoutePath
    var skill: Float
    var topSpeed: Float
    private(set) var profile: [Float] = []

    // state
    var s: Float = 0                 // unwrapped progress (negative on the grid)
    var lateral: Float = 0
    var speed: Float = 0
    var pos: Vec2 = Vec2(0, 0)
    var heading: Float = 0
    var steer: Float = 0             // visual front wheel angle
    var wheelPhase: Float = 0
    var slow: Float = 1              // collision penalty, recovers
    var rubber: Float = 1
    var braking: Bool = false
    var finished: Bool = false
    var finishTime: Double? = nil
    var laneWander: Float = 1.0
    private var phase: Float = 0
    private var laneTarget: Float = 0

    init(path: RoutePath, skill: Float, topSpeed: Float, seed: Float) {
        self.path = path
        self.skill = skill
        self.topSpeed = topSpeed
        self.phase = seed * 6.28
        self.profile = path.speedProfile(skill: skill, topSpeed: topSpeed)
    }

    func reset(s: Float, lateral l: Float) {
        self.s = s
        lateral = l
        laneTarget = l
        speed = 0
        slow = 1
        rubber = 1
        finished = false
        finishTime = nil
        braking = false
        let p: (pos: Vec2, tan: Vec2) = path.point(atS: s, lateral: l)
        pos = p.pos
        heading = headingOf(p.tan)
        steer = 0
    }

    /// wraps a progress difference into (-L/2, L/2] on closed routes
    func wrapDelta(_ x: Float) -> Float {
        if !path.closed { return x }
        let L: Float = path.length
        return x - L * (x / L).rounded()
    }

    func update(dt: Float, racing: Bool, others: [AIObstacle]) {
        let sampleF: Float = path.closed ? path.wrapS(s) : max(0, min(path.length, s))
        let idx: Int = path.index(Int(sampleF / path.step))
        let lookSamples: Int = Int(min(40, 2 + speed * 0.25))
        var vt: Float = profile[idx]
        var k: Int = 1
        while k <= lookSamples {
            let vv: Float = profile[path.index(idx + k)]
            if vv < vt { vt = vv }
            k += 2
        }
        vt = vt * rubber * slow
        if finished { vt = min(vt, 28) }
        if !racing { vt = 0 }
        slow = min(1, slow + dt * 0.25)

        // avoidance: follow slower cars ahead in my lane, move to the free side
        var target: Float = laneWander * 2.4 * sinf(s / 260 + phase)
        for ob in others {
            if ob.ds > -6 && ob.ds < 16 && abs(ob.lateral - lateral) < 2.6 {
                target = lateral + (ob.lateral < lateral ? 3.4 : -3.4)
                if ob.ds > 0 && ob.ds < 12 { vt = min(vt, max(ob.speed, 5) + max(0, ob.ds - 5) * 0.6) }
                break
            }
        }
        let maxLat: Float = max(1.0, path.halfWidth - 2.0)
        laneTarget = clampf(target, -maxLat, maxLat)

        let prevSpeed: Float = speed
        if vt > speed {
            let aAcc: Float = min(9, 420e3 * (0.6 + 0.4 * skill) / (1300 * max(speed, 8))) - 0.0009 * speed * speed
            speed = min(vt, speed + max(aAcc, 0.5) * dt)
        } else {
            let dec: Float = racing ? 16 : 30
            speed = max(vt, speed - dec * dt)
        }
        speed = clampf(speed, 0, topSpeed * 1.15)
        braking = speed < prevSpeed - 0.02

        let dd: Float = clampf(laneTarget - lateral, -2.2 * dt, 2.2 * dt)
        lateral += dd
        s += speed * dt
        if !path.closed && s > path.length + 60 { s = path.length + 60 }

        let p: (pos: Vec2, tan: Vec2) = path.point(atS: s, lateral: lateral)
        pos = p.pos
        let latVel: Float = dt > 1e-5 ? dd / dt : 0
        let targetH: Float = headingOf(p.tan) + atan2f(latVel, max(speed, 1))
        let kH: Float = 1 - expf(-14 * dt)
        heading = wrapAngle(heading + angleDiff(heading, targetH) * kH)

        let kappa: Float = path.curvatureAt(s: s)
        let denom: Float = max(0.3, 1 - lateral * kappa)
        let steerTarget: Float = clampf(atanf(2.516 * kappa / denom), -0.5, 0.5)
        steer = damp(steer, steerTarget, 12, dt)
        wheelPhase = (wheelPhase + speed / 0.35 * dt).truncatingRemainder(dividingBy: Float.tau)
    }
}
