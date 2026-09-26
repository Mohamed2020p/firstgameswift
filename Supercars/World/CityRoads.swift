import Foundation
import simd

// MARK: - Road network data: polylines with widths, and a spatial index for distance / coverage queries

enum WRoadClass { case street, avenue, boulevard, ring, suburb, connector }

final class WRoad {
    let id: Int
    let cls: WRoadClass
    let name: String
    let points: [Vec2]
    let closed: Bool
    let halfWidth: Float        // asphalt half width (outer edge for boulevards)
    let sidewalk: Float
    let medianHalf: Float
    let isGrid: Bool
    private(set) var cum: [Float] = []
    private(set) var normals: [Vec2] = []      // unit left normals per point
    private(set) var length: Float = 0

    static func dimensions(_ cls: WRoadClass) -> (half: Float, sidewalk: Float, median: Float) {
        switch cls {
        case .street: return (8, 4, 0)
        case .avenue: return (10, 4, 0)
        case .boulevard: return (13, 4, 3)
        case .ring: return (10, 4, 0)
        case .suburb: return (5.5, 3, 0)
        case .connector: return (8, 3, 0)
        }
    }

    init(id: Int, cls: WRoadClass, name: String, points: [Vec2], closed: Bool, isGrid: Bool) {
        self.id = id
        self.cls = cls
        self.name = name
        self.points = points
        self.closed = closed
        self.isGrid = isGrid
        let d = WRoad.dimensions(cls)
        self.halfWidth = d.half
        self.sidewalk = d.sidewalk
        self.medianHalf = d.median
        var c: [Float] = [0]
        var total: Float = 0
        let n = points.count
        let segs = closed ? n : n - 1
        var i = 0
        while i < segs {
            let a = points[i]
            let b = points[(i + 1) % n]
            total += simd_length(b - a)
            c.append(total)
            i += 1
        }
        cum = c
        length = total
        var nr: [Vec2] = []
        for k in 0..<n {
            var dPrev = Vec2(0, 0)
            var dNext = Vec2(0, 0)
            if closed || k > 0 {
                let pk = points[(k + n - 1) % n]
                dPrev = (points[k] - pk).normalizedSafe
            }
            if closed || k < n - 1 {
                dNext = (points[(k + 1) % n] - points[k]).normalizedSafe
            }
            var dir = dPrev + dNext
            if simd_length(dir) < 0.2 { dir = dNext.x == 0 && dNext.y == 0 ? dPrev : dNext }
            dir = dir.normalizedSafe
            nr.append(dir.leftPerp)
        }
        normals = nr
    }

    var corridor: Float { return halfWidth + sidewalk }
    var segCount: Int { return closed ? points.count : points.count - 1 }
    func segA(_ i: Int) -> Vec2 { return points[i] }
    func segB(_ i: Int) -> Vec2 { return points[(i + 1) % points.count] }
    func normalA(_ i: Int) -> Vec2 { return normals[i] }
    func normalB(_ i: Int) -> Vec2 { return normals[(i + 1) % points.count] }

    /// position and unit direction at arclength s
    func sample(at s: Float) -> (p: Vec2, dir: Vec2) {
        var ss = s
        if closed && length > 0 {
            ss = s.truncatingRemainder(dividingBy: length)
            if ss < 0 { ss += length }
        } else {
            ss = clampf(s, 0, length)
        }
        var lo = 0
        var hi = segCount - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if cum[mid] <= ss { lo = mid } else { hi = mid - 1 }
        }
        let a = segA(lo)
        let b = segB(lo)
        let l = max(cum[lo + 1] - cum[lo], 0.0001)
        let t = clampf((ss - cum[lo]) / l, 0, 1)
        return (a + (b - a) * t, (b - a).normalizedSafe)
    }
}

struct WRoadHit {
    var road: WRoad
    var seg: Int
    var t: Float
    var point: Vec2
    var dist: Float
    var dir: Vec2
}

final class WRoadIndex {
    private(set) var roads: [WRoad] = []
    private var cells: [Int: [Int]] = [:]
    private let cs: Float = 40

    private func key(_ cx: Int, _ cz: Int) -> Int { return (cx + 100) * 512 + (cz + 100) }

    func add(_ r: WRoad) {
        let ri = roads.count
        roads.append(r)
        let m = r.corridor + 3
        for s in 0..<r.segCount {
            let a = r.segA(s)
            let b = r.segB(s)
            let x0 = Int(floorf((min(a.x, b.x) - m) / cs))
            let x1 = Int(floorf((max(a.x, b.x) + m) / cs))
            let z0 = Int(floorf((min(a.y, b.y) - m) / cs))
            let z1 = Int(floorf((max(a.y, b.y) + m) / cs))
            let packed = (ri << 20) | s
            var cx = x0
            while cx <= x1 {
                var cz = z0
                while cz <= z1 {
                    let k = key(cx, cz)
                    if cells[k] == nil { cells[k] = [packed] } else { cells[k]!.append(packed) }
                    cz += 1
                }
                cx += 1
            }
        }
    }

    /// unique packed (road << 20 | segment) references whose corridor touches the rect
    func segments(in rect: WRect) -> [Int] {
        var out: [Int] = []
        var seen = Set<Int>()
        let x0 = Int(floorf(rect.x0 / cs))
        let x1 = Int(floorf(rect.x1 / cs))
        let z0 = Int(floorf(rect.z0 / cs))
        let z1 = Int(floorf(rect.z1 / cs))
        var cx = x0
        while cx <= x1 {
            var cz = z0
            while cz <= z1 {
                if let list = cells[key(cx, cz)] {
                    for p in list where !seen.contains(p) {
                        seen.insert(p)
                        out.append(p)
                    }
                }
                cz += 1
            }
            cx += 1
        }
        return out
    }

    func nearest(_ p: Vec2, maxDist: Float) -> WRoadHit? {
        var best: WRoadHit? = nil
        var bestD: Float = maxDist
        let x0 = Int(floorf((p.x - maxDist) / cs))
        let x1 = Int(floorf((p.x + maxDist) / cs))
        let z0 = Int(floorf((p.y - maxDist) / cs))
        let z1 = Int(floorf((p.y + maxDist) / cs))
        var cx = x0
        while cx <= x1 {
            var cz = z0
            while cz <= z1 {
                if let list = cells[key(cx, cz)] {
                    for packed in list {
                        let ri = packed >> 20
                        let si = packed & 0xFFFFF
                        let r = roads[ri]
                        let a = r.segA(si)
                        let b = r.segB(si)
                        let d = wSegmentDistance(p, a, b)
                        if d.dist < bestD {
                            bestD = d.dist
                            let q = a + (b - a) * d.t
                            best = WRoadHit(road: r, seg: si, t: d.t, point: q, dist: d.dist, dir: (b - a).normalizedSafe)
                        }
                    }
                }
                cz += 1
            }
            cx += 1
        }
        return best
    }

    /// true when p lies inside the asphalt of a road other than `excluding` (+ margin)
    func insideAsphalt(_ p: Vec2, excluding: Int, margin: Float) -> Bool {
        let cx = Int(floorf(p.x / cs))
        let cz = Int(floorf(p.y / cs))
        guard let list = cells[key(cx, cz)] else { return false }
        for packed in list {
            let ri = packed >> 20
            if ri == excluding { continue }
            let r = roads[ri]
            let si = packed & 0xFFFFF
            let d = wSegmentDistance(p, r.segA(si), r.segB(si))
            if d.dist <= r.halfWidth + margin { return true }
        }
        return false
    }

    /// true when p lies within the corridor (asphalt + sidewalk) of a non-grid road (used to keep buildings clear of curved roads)
    func insideCurvedCorridor(_ p: Vec2, extra: Float) -> Bool {
        let cx = Int(floorf(p.x / cs))
        let cz = Int(floorf(p.y / cs))
        guard let list = cells[key(cx, cz)] else { return false }
        for packed in list {
            let ri = packed >> 20
            let r = roads[ri]
            if r.isGrid { continue }
            let si = packed & 0xFFFFF
            let d = wSegmentDistance(p, r.segA(si), r.segB(si))
            if d.dist <= r.corridor + extra { return true }
        }
        return false
    }

    /// 0 = none, 1 = asphalt, 2 = sidewalk, 3 = planted median
    func classify(_ p: Vec2) -> Int {
        let cx = Int(floorf(p.x / cs))
        let cz = Int(floorf(p.y / cs))
        guard let list = cells[key(cx, cz)] else { return 0 }
        var result = 0
        for packed in list {
            let ri = packed >> 20
            let r = roads[ri]
            let si = packed & 0xFFFFF
            let d = wSegmentDistance(p, r.segA(si), r.segB(si)).dist
            if d <= r.halfWidth {
                if r.medianHalf > 0 && d < r.medianHalf { if result == 0 || result == 2 { result = 3 } }
                else { return 1 }
            } else if d <= r.halfWidth + r.sidewalk {
                if result == 0 { result = 2 }
            }
        }
        return result
    }
}

enum WSpline {
    /// Catmull-Rom through the control points, sampled roughly every `step` metres.
    static func catmull(_ pts: [Vec2], step: Float, closed: Bool) -> [Vec2] {
        let n = pts.count
        if n < 2 { return pts }
        var out: [Vec2] = []
        let segs = closed ? n : n - 1
        for i in 0..<segs {
            let p1 = pts[i]
            let p2 = pts[(i + 1) % n]
            let p0: Vec2 = closed ? pts[(i + n - 1) % n] : (i == 0 ? p1 : pts[i - 1])
            let p3: Vec2 = closed ? pts[(i + 2) % n] : (i + 2 < n ? pts[i + 2] : p2)
            let dist = simd_length(p2 - p1)
            let count = max(2, Int(ceilf(dist / step)))
            for k in 0..<count {
                let t: Float = Float(k) / Float(count)
                let t2 = t * t
                let t3 = t2 * t
                let a: Vec2 = p1 * 2
                let b: Vec2 = (p2 - p0) * t
                let c: Vec2 = (p0 * 2 - p1 * 5 + p2 * 4 - p3) * t2
                let d: Vec2 = (p1 * 3 - p0 - p2 * 3 + p3) * t3
                out.append((a + b + c + d) * 0.5)
            }
        }
        if !closed { out.append(pts[n - 1]) }
        return out
    }

    /// Resamples a polyline to uniform spacing.
    static func resample(_ pts: [Vec2], spacing: Float, closed: Bool) -> [Vec2] {
        if pts.count < 2 { return pts }
        var list = pts
        if closed { list.append(pts[0]) }
        var total: Float = 0
        var cum: [Float] = [0]
        for i in 1..<list.count {
            total += simd_length(list[i] - list[i - 1])
            cum.append(total)
        }
        let count = max(2, Int(total / spacing))
        var out: [Vec2] = []
        var seg = 0
        for k in 0..<count {
            let s: Float = Float(k) * total / Float(count)
            while seg < list.count - 2 && cum[seg + 1] < s { seg += 1 }
            let l = max(cum[seg + 1] - cum[seg], 0.0001)
            let t = clampf((s - cum[seg]) / l, 0, 1)
            out.append(list[seg] + (list[seg + 1] - list[seg]) * t)
        }
        if !closed { out.append(pts[pts.count - 1]) }
        return out
    }

    static func length(_ pts: [Vec2], closed: Bool) -> Float {
        var total: Float = 0
        if pts.count < 2 { return 0 }
        for i in 1..<pts.count { total += simd_length(pts[i] - pts[i - 1]) }
        if closed { total += simd_length(pts[0] - pts[pts.count - 1]) }
        return total
    }
}
