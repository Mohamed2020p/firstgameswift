import Foundation
import simd

// MARK: - LanePath: the centre line of a driving lane through a chain of grid intersections (right-hand traffic).
// Turns are quadratic Bezier arcs through the intersection, the polyline is resampled uniformly, curvature and a braking-aware speed
// profile are precomputed.  Everything is arithmetic on WGrid, so routes exist anywhere in the unbounded street grid.

struct LaneMark {
    var s: Float                // progress of the intersection centre along the path
    var node: WGridNode
    var key: Int
}

struct LanePath {
    let pts: [Vec2]
    let cum: [Float]
    let kappa: [Float]          // signed curvature (1/m), + = turning left
    let length: Float
    let step: Float
    var marks: [LaneMark] = []
    var stopsAtEnd: Bool = false
    private(set) var speedCap: [Float] = []

    var isEmpty: Bool { return pts.count < 2 }

    init(points: [Vec2], step requested: Float) {
        pts = points
        var c: [Float] = [0]
        var total: Float = 0
        if points.count > 1 {
            for i in 1..<points.count {
                total += simd_distance(points[i], points[i - 1])
                c.append(total)
            }
        }
        cum = c
        length = total
        // uniform resampling gives length / (count - 1) as the true spacing
        let step: Float = points.count > 1 ? max(0.05, total / Float(points.count - 1)) : requested
        self.step = step
        var k: [Float] = [Float](repeating: 0, count: points.count)
        if points.count > 2 {
            for i in 1..<(points.count - 1) {
                let a: Vec2 = (points[i] - points[i - 1]).normalizedSafe
                let b: Vec2 = (points[i + 1] - points[i]).normalizedSafe
                let ang: Float = angleDiff(headingOf(a), headingOf(b))
                k[i] = ang / max(step, 0.1)
            }
            // smooth
            var sm: [Float] = k
            for i in 1..<(points.count - 1) {
                let lo: Int = max(0, i - 2)
                let hi: Int = min(points.count - 1, i + 2)
                var sum: Float = 0
                for q in lo...hi { sum += k[q] }
                sm[i] = sum / Float(hi - lo + 1)
            }
            k = sm
        }
        kappa = k
    }

    // MARK: sampling

    func index(atS s: Float) -> Int {
        if step <= 0 || pts.isEmpty { return 0 }
        return max(0, min(pts.count - 1, Int(s / step)))
    }

    func sample(_ s: Float) -> (pos: Vec2, tan: Vec2) {
        if pts.count < 2 { return (pts.first ?? Vec2(0, 0), Vec2(0, 1)) }
        let cs: Float = clampf(s, 0, length)
        let i0: Int = max(0, min(pts.count - 2, Int(cs / step)))
        let a: Vec2 = pts[i0]
        let b: Vec2 = pts[i0 + 1]
        let segLen: Float = max(cum[i0 + 1] - cum[i0], 1e-4)
        let t: Float = clampf((cs - cum[i0]) / segLen, 0, 1)
        var tan: Vec2 = (b - a).normalizedSafe
        if tan == Vec2(0, 0) { tan = Vec2(0, 1) }
        if s > length {
            return (pts[pts.count - 1] + tan * (s - length), tan)
        }
        return (a + (b - a) * t, tan)
    }

    func curvature(atS s: Float) -> Float {
        if kappa.isEmpty { return 0 }
        return kappa[index(atS: s)]
    }

    /// progress of the point of the path closest to `p`, searching a window around `hintS`
    func project(_ p: Vec2, hintS: Float, window: Float = 40) -> (s: Float, distance: Float) {
        if pts.count < 2 { return (0, 0) }
        let i0: Int = max(0, index(atS: hintS - window * 0.4))
        let i1: Int = min(pts.count - 2, index(atS: hintS + window))
        var bestD: Float = Float.greatestFiniteMagnitude
        var bestS: Float = hintS
        if i0 > i1 { return (hintS, simd_distance(p, pts[min(pts.count - 1, i0)])) }
        for i in i0...i1 {
            let a: Vec2 = pts[i]
            let b: Vec2 = pts[i + 1]
            let d = wSegmentDistance(p, a, b)
            if d.dist < bestD {
                bestD = d.dist
                bestS = cum[i] + d.t * (cum[i + 1] - cum[i])
            }
        }
        return (bestS, bestD)
    }

    // MARK: speed profile

    /// per-sample speed cap: cornering limit and speed limit, then a backward braking pass; the end is a stop if `stopsAtEnd`
    mutating func buildSpeedProfile(limit: Float, lateralAccel: Float, brake: Float) {
        var v: [Float] = []
        v.reserveCapacity(pts.count)
        for i in 0..<pts.count {
            let k: Float = max(abs(kappa[i]), 1e-4)
            v.append(min(limit, sqrtf(lateralAccel / k)))
        }
        if stopsAtEnd, !v.isEmpty { v[v.count - 1] = 0 }
        if v.count > 1 {
            var i: Int = v.count - 2
            while i >= 0 {
                v[i] = min(v[i], sqrtf(v[i + 1] * v[i + 1] + 2 * brake * step))
                i -= 1
            }
        }
        speedCap = v
    }

    func capAt(s: Float) -> Float {
        if speedCap.isEmpty { return 10 }
        return speedCap[index(atS: s)]
    }
}

// MARK: - Router

enum TrafficRouter {
    static let dirs: [Vec2] = [Vec2(1, 0), Vec2(-1, 0), Vec2(0, 1), Vec2(0, -1)]

    static func step(_ n: WGridNode, _ d: Vec2) -> WGridNode {
        return WGridNode(i: n.i + Int(d.x), j: n.j + Int(d.y))
    }

    static func direction(from a: WGridNode, to b: WGridNode) -> Vec2 {
        return Vec2(Float(max(-1, min(1, b.i - a.i))), Float(max(-1, min(1, b.j - a.j))))
    }

    static func right(_ d: Vec2) -> Vec2 { return Vec2(-d.y, d.x) }

    /// grid line index of the road travelled when heading `d` through node `n`
    static func line(_ d: Vec2, _ n: WGridNode) -> Int {
        return abs(d.x) > 0.5 ? n.j : n.i
    }

    /// lane centre for heading `d` on the road through `n` (right-hand traffic)
    static func lanePoint(_ n: WGridNode, heading d: Vec2) -> Vec2 {
        return n.position + right(d) * WGrid.laneOffset(line(d, n))
    }

    // MARK: node routes

    /// grid-aligned route from `a` (arriving with heading `arriving`, nil = free) to `b`; U-turns are never used
    static func route(from a: WGridNode, arriving: Vec2?, to b: WGridNode, rng: inout SeededRNG) -> [WGridNode] {
        var path: [WGridNode] = [a]
        var cur: WGridNode = a
        var dir: Vec2? = arriving
        var guardCount: Int = 0
        while (cur.i != b.i || cur.j != b.j) && guardCount < 80 {
            guardCount += 1
            let di: Int = b.i - cur.i
            let dj: Int = b.j - cur.j
            var cands: [Vec2] = []
            if di != 0 { cands.append(Vec2(di > 0 ? 1 : -1, 0)) }
            if dj != 0 { cands.append(Vec2(0, dj > 0 ? 1 : -1)) }
            if let d = dir { cands.removeAll(where: { $0.x == -d.x && $0.y == -d.y }) }
            var pick: Vec2 = Vec2(0, 0)
            if cands.isEmpty {
                // the only way is backwards: take a detour sideways
                if let d = dir { pick = right(d) * (rng.chance(0.5) ? 1 : -1) } else { pick = Vec2(1, 0) }
            } else if let d = dir, cands.contains(where: { $0.x == d.x && $0.y == d.y }), rng.chance(0.65) {
                pick = d
            } else {
                pick = cands[rng.int(0, cands.count - 1)]
            }
            // never drive into the suburb rectangle (it has its own curved streets): try the other axis, else give up
            if !WGrid.hasGridStreets(at: step(cur, pick).position) {
                var alt: Vec2? = nil
                for o in dirs {
                    if let d = dir, o.x == -d.x && o.y == -d.y { continue }
                    if WGrid.hasGridStreets(at: step(cur, o).position) {
                        alt = o
                        break
                    }
                }
                guard let a = alt else { break }
                pick = a
            }
            cur = step(cur, pick)
            path.append(cur)
            dir = pick
        }
        return path
    }

    /// random cruising route: `count` further intersections, mostly straight
    static func cruise(from a: WGridNode, heading d0: Vec2, count: Int, rng: inout SeededRNG) -> [WGridNode] {
        var out: [WGridNode] = []
        var cur: WGridNode = a
        var dir: Vec2 = d0
        for _ in 0..<count {
            var options: [Vec2] = [dir, dir, dir, right(dir), right(dir) * -1]
            options.shuffle(using: &rng)
            var chosen: Vec2 = dir
            for o in options {
                let nxt: WGridNode = step(cur, o)
                if WGrid.hasGridStreets(at: nxt.position) && WGrid.hasGridStreets(at: (cur.position + nxt.position) * 0.5) {
                    chosen = o
                    break
                }
            }
            cur = step(cur, chosen)
            out.append(cur)
            dir = chosen
        }
        return out
    }

    // MARK: geometry

    /// Builds the lane path: start point / heading, then the intersections in `nodes` (the first one is the next intersection ahead),
    /// then optionally a final stop point reached with heading `stopDir`.
    static func build(start: Vec2, heading d0: Vec2, nodes: [WGridNode], stop: (point: Vec2, dir: Vec2)?, limit: Float, step spacing: Float = 1.5) -> LanePath {
        var raw: [Vec2] = [start]
        var marks: [(Vec2, WGridNode)] = []
        var dirIn: Vec2 = d0
        for idx in 0..<nodes.count {
            let n: WGridNode = nodes[idx]
            var dirOut: Vec2? = nil
            if idx + 1 < nodes.count {
                dirOut = direction(from: n, to: nodes[idx + 1])
            } else if let s = stop {
                dirOut = s.dir
            }
            let oIn: Float = WGrid.laneOffset(line(dirIn, n))
            let rIn: Vec2 = right(dirIn)
            let centreIn: Vec2 = n.position + rIn * oIn
            marks.append((centreIn, n))
            guard let dOut = dirOut else {
                raw.append(centreIn)
                break
            }
            if abs(dOut.x - dirIn.x) < 0.01 && abs(dOut.y - dirIn.y) < 0.01 {
                raw.append(centreIn)
            } else {
                let oOut: Float = WGrid.laneOffset(line(dOut, n))
                let rOut: Vec2 = right(dOut)
                let x: Vec2 = n.position + rIn * oIn + rOut * oOut
                let isRight: Bool = simd_dot(dOut, rIn) > 0
                let r: Float = isRight ? 6.5 : 11.5
                let pin: Vec2 = x - dirIn * r
                let pout: Vec2 = x + dOut * r
                let samples: Int = 9
                for s in 0...samples {
                    let t: Float = Float(s) / Float(samples)
                    let a: Float = (1 - t) * (1 - t)
                    let b: Float = 2 * (1 - t) * t
                    let c: Float = t * t
                    raw.append(pin * a + x * b + pout * c)
                }
            }
            dirIn = dOut
        }
        if let s = stop { raw.append(s.point) }
        // remove consecutive duplicates
        var clean: [Vec2] = []
        for p in raw {
            if let l = clean.last, simd_distance(l, p) < 0.05 { continue }
            clean.append(p)
        }
        if clean.count < 2 {
            clean = [start, start + d0 * 5]
        }
        let dense: [Vec2] = WSpline.resample(clean, spacing: spacing, closed: false)
        var lp = LanePath(points: dense, step: spacing)
        lp.stopsAtEnd = stop != nil
        // intersection marks: progress of the closest path sample to each lane crossing point
        var ms: [LaneMark] = []
        for (c, n) in marks {
            var bestI: Int = 0
            var bestD: Float = Float.greatestFiniteMagnitude
            for (i, p) in dense.enumerated() {
                let d: Float = simd_distance_squared(p, c)
                if d < bestD {
                    bestD = d
                    bestI = i
                }
            }
            if bestD < 400 { ms.append(LaneMark(s: lp.cum[bestI], node: n, key: n.key)) }
        }
        lp.marks = ms
        lp.buildSpeedProfile(limit: limit, lateralAccel: 3.2, brake: 4.2)
        return lp
    }

    /// where a vehicle must stop to pick somebody up at the sidewalk point `q`, and the heading it needs (curb on the right)
    static func curbStop(forSidewalkPoint q: Vec2) -> (point: Vec2, dir: Vec2, before: WGridNode)? {
        let j: Int = WGrid.nearestLine(q.y)
        let i: Int = WGrid.nearestLine(q.x)
        let dz: Float = abs(q.y - WGrid.line(j))
        let dx: Float = abs(q.x - WGrid.line(i))
        if dz <= WGrid.corridor(j) + 0.6 && dz >= WGrid.halfWidth(j) - 0.3 && (dz <= dx || dx > WGrid.corridor(i) + 0.6) {
            // sidewalk of street X_j: heading +x has the +z side on its right
            let dir: Vec2 = q.y >= WGrid.line(j) ? Vec2(1, 0) : Vec2(-1, 0)
            let lane: Float = WGrid.line(j) + (q.y >= WGrid.line(j) ? 1 : -1) * WGrid.laneOffset(j)
            let i0: Int = WGrid.blockIndex(q.x)
            let before: WGridNode = WGridNode(i: dir.x > 0 ? i0 : i0 + 1, j: j)
            return (Vec2(q.x, lane), dir, before)
        }
        if dx <= WGrid.corridor(i) + 0.6 && dx >= WGrid.halfWidth(i) - 0.3 {
            // sidewalk of street Z_i: heading +z has the -x side on its right
            let dir: Vec2 = q.x >= WGrid.line(i) ? Vec2(0, -1) : Vec2(0, 1)
            let lane: Float = WGrid.line(i) + (q.x >= WGrid.line(i) ? 1 : -1) * WGrid.laneOffset(i)
            let j0: Int = WGrid.blockIndex(q.y)
            let before: WGridNode = WGridNode(i: i, j: dir.y > 0 ? j0 : j0 + 1)
            return (Vec2(lane, q.y), dir, before)
        }
        return nil
    }
}
