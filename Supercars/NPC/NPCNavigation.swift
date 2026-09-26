import Foundation
import simd

// MARK: - NPCNavigation: the pedestrian network.  Sidewalks run along every grid street; each intersection has four corner nodes
// (bit 0 = east of the crossing street line, bit 1 = north of the crossing street line).  Edges follow the sidewalk to the next
// intersection or cross a street between two corners on the same side.  Everything is arithmetic on WGrid, so the network exists
// for any grid index (endless world) without building any data structure up front.

struct PedNode: Hashable {
    var i: Int
    var j: Int
    var c: Int

    var sx: Float { return (c & 1) != 0 ? 1 : -1 }
    var sz: Float { return (c & 2) != 0 ? 1 : -1 }

    var position: Vec2 {
        return Vec2(WGrid.line(i) + sx * WGrid.walkOffset(i), WGrid.line(j) + sz * WGrid.walkOffset(j))
    }
}

struct PedWaypoint {
    var p: Vec2
    /// the segment that STARTS at this waypoint crosses a street
    var crossing: Bool = false
    var crossEnd: Vec2 = Vec2(0, 0)
    /// destination waypoint (last one)
    var isFinal: Bool = false
}

struct PedRoute {
    var points: [PedWaypoint] = []
    var index: Int = 0
    var destination: NPCDestination? = nil

    var isFinished: Bool { return index >= points.count }
    var current: PedWaypoint? { return index < points.count ? points[index] : nil }
}

struct PedTaxiStop {
    var position: Vec2          // on the sidewalk
    var facing: Float           // heading toward the road (where the taxi comes from)
    var name: String
}

// MARK: - Local collision helpers (static colliders)

enum PedCollision {
    /// nearest point of a collider's footprint to `p`
    static func nearestPoint(_ c: Collider, to p: Vec2) -> Vec2 {
        if c.radius > 0 {
            let d: Vec2 = p - c.center
            let l: Float = simd_length(d)
            if l < 1e-4 { return c.center + Vec2(c.radius, 0) }
            return c.center + d / l * c.radius
        }
        let lft: Vec2 = headingLeft2(c.heading)
        let fwd: Vec2 = headingForward2(c.heading)
        let rel: Vec2 = p - c.center
        let lx: Float = clampf(simd_dot(rel, lft), -c.halfExtents.x, c.halfExtents.x)
        let lz: Float = clampf(simd_dot(rel, fwd), -c.halfExtents.y, c.halfExtents.y)
        return c.center + lft * lx + fwd * lz
    }

    /// pushes `p` out of every collider (2 iterations)
    static func resolve(_ p: inout Vec2, radius: Float, colliders: [Collider]) {
        for _ in 0..<2 {
            for c in colliders {
                let q: Vec2 = nearestPoint(c, to: p)
                let d: Vec2 = p - q
                let l: Float = simd_length(d)
                if l < radius {
                    if l > 1e-4 {
                        p = q + d / l * radius
                    } else if c.radius > 0 {
                        p = c.center + Vec2(c.radius + radius, 0)
                    } else {
                        // centre inside a box: leave through the nearest face
                        let lft: Vec2 = headingLeft2(c.heading)
                        let fwd: Vec2 = headingForward2(c.heading)
                        let rel: Vec2 = p - c.center
                        var lx: Float = simd_dot(rel, lft)
                        var lz: Float = simd_dot(rel, fwd)
                        let px: Float = c.halfExtents.x - abs(lx)
                        let pz: Float = c.halfExtents.y - abs(lz)
                        if px < pz { lx = (lx >= 0 ? 1 : -1) * (c.halfExtents.x + radius) } else { lz = (lz >= 0 ? 1 : -1) * (c.halfExtents.y + radius) }
                        p = c.center + lft * lx + fwd * lz
                    }
                }
            }
        }
    }

    /// bends a desired walking direction away from nearby obstacles (soft avoidance before the hard resolve)
    static func steer(desired: Vec2, pos: Vec2, colliders: [Collider], clearance: Float) -> Vec2 {
        var push: Vec2 = Vec2(0, 0)
        for c in colliders {
            let q: Vec2 = nearestPoint(c, to: pos)
            let d: Vec2 = pos - q
            let l: Float = simd_length(d)
            if l < clearance && l > 1e-4 {
                let ahead: Float = simd_dot(-d / l, desired)          // > 0 when the obstacle is in front of us
                let w: Float = (clearance - l) / clearance
                push += (d / l) * (w * (1.2 + max(0, ahead)))
                // slide sideways along the obstacle instead of pushing straight back
                let side: Vec2 = Vec2(-d.y, d.x) / l
                let sgn: Float = simd_dot(side, desired) >= 0 ? 1 : -1
                push += side * sgn * (w * max(0, ahead) * 0.9)
            }
        }
        let out: Vec2 = desired + push
        let l: Float = simd_length(out)
        return l > 1e-4 ? out / l : desired
    }
}

// MARK: - Navigator

final class PedNavigator {
    private let layout: WCityLayout
    var taxiStops: [PedTaxiStop] = []

    init(layout: WCityLayout) {
        self.layout = layout
    }

    // MARK: graph

    private func neighbors(_ n: PedNode) -> [(node: PedNode, cost: Float, crossing: Bool)] {
        var out: [(node: PedNode, cost: Float, crossing: Bool)] = []
        let here: Vec2 = n.position
        // along X (sidewalk of street X_j)
        var a: PedNode = n
        if n.sx > 0 {
            a = PedNode(i: n.i + 1, j: n.j, c: n.c & 2)
        } else {
            a = PedNode(i: n.i - 1, j: n.j, c: n.c | 1)
        }
        out.append((a, simd_distance(here, a.position), false))
        // along Z (sidewalk of street Z_i)
        var b: PedNode = n
        if n.sz > 0 {
            b = PedNode(i: n.i, j: n.j + 1, c: n.c & 1)
        } else {
            b = PedNode(i: n.i, j: n.j - 1, c: n.c | 2)
        }
        out.append((b, simd_distance(here, b.position), false))
        // crossings (a little more expensive: waiting for traffic)
        let cx: PedNode = PedNode(i: n.i, j: n.j, c: n.c ^ 1)
        out.append((cx, simd_distance(here, cx.position) * 1.5 + 6, true))
        let cz: PedNode = PedNode(i: n.i, j: n.j, c: n.c ^ 2)
        out.append((cz, simd_distance(here, cz.position) * 1.5 + 6, true))
        // the hillside suburb has no grid streets: never route through it
        return out.filter { WGrid.hasGridStreets(at: $0.node.position) }
    }

    private func key(_ n: PedNode) -> Int { return ((n.i + 2048) << 20) | ((n.j + 2048) << 4) | n.c }

    /// corner nodes reachable from `p` along the sidewalk without crossing asphalt (fallback: the nearest corners)
    func startNodes(for p: Vec2) -> [(node: PedNode, cost: Float)] {
        let i0: Int = WGrid.blockIndex(p.x)
        let j0: Int = WGrid.blockIndex(p.y)
        var all: [(PedNode, Float)] = []
        for di in 0...1 {
            for dj in 0...1 {
                for c in 0..<4 {
                    let n = PedNode(i: i0 + di, j: j0 + dj, c: c)
                    all.append((n, simd_distance(p, n.position)))
                }
            }
        }
        var clear: [(node: PedNode, cost: Float)] = []
        for (n, d) in all where d < WGrid.pitch * 1.25 {
            if segmentClearOfAsphalt(p, n.position) { clear.append((n, d)) }
        }
        if clear.isEmpty {
            let sorted = all.sorted { $0.1 < $1.1 }
            for k in 0..<min(2, sorted.count) { clear.append((sorted[k].0, sorted[k].1)) }
        }
        return clear
    }

    private func segmentClearOfAsphalt(_ a: Vec2, _ b: Vec2) -> Bool {
        let steps: Int = max(2, Int(simd_distance(a, b) / 6))
        for s in 0...steps {
            let t: Float = Float(s) / Float(steps)
            let q: Vec2 = a + (b - a) * t
            if WGrid.isOnGridAsphalt(q, margin: -0.4) { return false }
        }
        return true
    }

    // MARK: search

    /// A* from the start candidates to any goal node; returns the node sequence
    func search(starts: [(node: PedNode, cost: Float)], goals: [(node: PedNode, cost: Float)], maxExpansions: Int = 900) -> [PedNode]? {
        if starts.isEmpty || goals.isEmpty { return nil }
        var goalCost: [Int: Float] = [:]
        var goalCenter: Vec2 = Vec2(0, 0)
        for g in goals {
            goalCost[key(g.node)] = g.cost
            goalCenter += g.node.position
        }
        goalCenter /= Float(goals.count)

        var gScore: [Int: Float] = [:]
        var came: [Int: PedNode] = [:]
        var nodeOf: [Int: PedNode] = [:]
        var open: [(node: PedNode, f: Float)] = []
        for s in starts {
            let k: Int = key(s.node)
            if let old = gScore[k], old <= s.cost { continue }
            gScore[k] = s.cost
            nodeOf[k] = s.node
            open.append((s.node, s.cost + simd_distance(s.node.position, goalCenter)))
        }
        var best: Float = Float.greatestFiniteMagnitude
        var bestKey: Int = -1
        var expansions: Int = 0
        var closed = Set<Int>()
        while !open.isEmpty && expansions < maxExpansions {
            var bi: Int = 0
            for k in 1..<open.count where open[k].f < open[bi].f { bi = k }
            let cur = open.remove(at: bi)
            let ck: Int = key(cur.node)
            if closed.contains(ck) { continue }
            closed.insert(ck)
            expansions += 1
            if cur.f >= best { break }
            let g: Float = gScore[ck] ?? 0
            if let gc = goalCost[ck] {
                let total: Float = g + gc
                if total < best {
                    best = total
                    bestKey = ck
                }
            }
            for nb in neighbors(cur.node) {
                let nk: Int = key(nb.node)
                if closed.contains(nk) { continue }
                let ng: Float = g + nb.cost
                if let old = gScore[nk], old <= ng { continue }
                gScore[nk] = ng
                came[nk] = cur.node
                nodeOf[nk] = nb.node
                open.append((nb.node, ng + simd_distance(nb.node.position, goalCenter) * 0.98))
            }
        }
        if bestKey < 0 { return nil }
        var path: [PedNode] = []
        var k: Int = bestKey
        var guardCount: Int = 0
        while guardCount < 400 {
            guardCount += 1
            guard let n = nodeOf[k] else { break }
            path.append(n)
            guard let prev = came[k] else { break }
            k = key(prev)
        }
        path.reverse()
        return path
    }

    // MARK: routes

    private func buildRoute(from start: Vec2, nodes: [PedNode], to dest: NPCDestination) -> PedRoute {
        var pts: [PedWaypoint] = []
        pts.append(PedWaypoint(p: start))
        var prev: PedNode? = nil
        for n in nodes {
            var w = PedWaypoint(p: n.position)
            if let pr = prev {
                // was the step pr -> n a street crossing (same intersection, different corner)?
                if pr.i == n.i && pr.j == n.j {
                    pts[pts.count - 1].crossing = true
                    pts[pts.count - 1].crossEnd = n.position
                }
            }
            w.isFinal = false
            pts.append(w)
            prev = n
        }
        pts.append(PedWaypoint(p: dest.position, crossing: false, crossEnd: Vec2(0, 0), isFinal: true))
        // drop degenerate first hop
        if pts.count > 2 && simd_distance(pts[0].p, pts[1].p) < 0.6 && !pts[0].crossing { pts.remove(at: 0) }
        var r = PedRoute()
        r.points = pts
        r.index = 0
        r.destination = dest
        return r
    }

    /// route from wherever the pedestrian stands to the destination (anchors = corner nodes the final approach starts from)
    func route(from start: Vec2, to dest: NPCDestination, anchors: [PedNode]) -> PedRoute? {
        let starts = startNodes(for: start)
        var goals: [(node: PedNode, cost: Float)] = []
        for a in anchors { goals.append((a, simd_distance(a.position, dest.position))) }
        guard let nodes = search(starts: starts, goals: goals) else { return nil }
        return buildRoute(from: start, nodes: nodes, to: dest)
    }

    // MARK: sidewalk geometry

    /// the two corner nodes at the ends of the sidewalk segment that contains `q` (nil when `q` is not on a grid sidewalk)
    func edgeEndpoints(for q: Vec2) -> [PedNode]? {
        let j: Int = WGrid.nearestLine(q.y)
        let i: Int = WGrid.nearestLine(q.x)
        let dz: Float = abs(q.y - WGrid.line(j))
        let dx: Float = abs(q.x - WGrid.line(i))
        let onX: Bool = dz >= WGrid.halfWidth(j) - 0.3 && dz <= WGrid.corridor(j) + 0.6
        let onZ: Bool = dx >= WGrid.halfWidth(i) - 0.3 && dx <= WGrid.corridor(i) + 0.6
        if onX && (!onZ || dz <= dx) {
            let sz: Int = q.y >= WGrid.line(j) ? 2 : 0
            let i0: Int = WGrid.blockIndex(q.x)
            return [PedNode(i: i0, j: j, c: 1 | sz), PedNode(i: i0 + 1, j: j, c: 0 | sz)]
        }
        if onZ {
            let sx: Int = q.x >= WGrid.line(i) ? 1 : 0
            let j0: Int = WGrid.blockIndex(q.y)
            return [PedNode(i: i, j: j0, c: sx | 2), PedNode(i: i, j: j0 + 1, c: sx | 0)]
        }
        return nil
    }

    /// a spawn point on a sidewalk near `candidate` (clear of the crossings), with the heading along the sidewalk
    func sidewalkPoint(near candidate: Vec2, rng: inout SeededRNG) -> (position: Vec2, heading: Float)? {
        let j: Int = WGrid.nearestLine(candidate.y)
        let i: Int = WGrid.nearestLine(candidate.x)
        let dz: Float = abs(candidate.y - WGrid.line(j))
        let dx: Float = abs(candidate.x - WGrid.line(i))
        let alongX: Bool = dz < dx
        if alongX {
            let sz: Float = rng.chance(0.5) ? 1 : -1
            let i0: Int = WGrid.blockIndex(candidate.x)
            let lo: Float = WGrid.line(i0) + WGrid.corridor(i0) + 1.8
            let hi: Float = WGrid.line(i0 + 1) - WGrid.corridor(i0 + 1) - 1.8
            if hi <= lo { return nil }
            let x: Float = clampf(candidate.x, lo, hi)
            let z: Float = WGrid.line(j) + sz * WGrid.walkOffset(j) + rng.float(-0.8, 0.8)
            return (Vec2(x, z), rng.chance(0.5) ? Float.pi * 0.5 : -Float.pi * 0.5)
        }
        let sx: Float = rng.chance(0.5) ? 1 : -1
        let j0: Int = WGrid.blockIndex(candidate.y)
        let lo: Float = WGrid.line(j0) + WGrid.corridor(j0) + 1.8
        let hi: Float = WGrid.line(j0 + 1) - WGrid.corridor(j0 + 1) - 1.8
        if hi <= lo { return nil }
        let z: Float = clampf(candidate.y, lo, hi)
        let x: Float = WGrid.line(i) + sx * WGrid.walkOffset(i) + rng.float(-0.8, 0.8)
        return (Vec2(x, z), rng.chance(0.5) ? 0 : Float.pi)
    }

    // MARK: destinations

    private func cornerAnchors(ofBlockI bi: Int, j bj: Int) -> [PedNode] {
        return [PedNode(i: bi, j: bj, c: 3), PedNode(i: bi + 1, j: bj, c: 2), PedNode(i: bi, j: bj + 1, c: 1), PedNode(i: bi + 1, j: bj + 1, c: 0)]
    }

    private func blockRect(_ bi: Int, _ bj: Int) -> WRect {
        return WRect(x0: WGrid.line(bi) + WGrid.corridor(bi), z0: WGrid.line(bj) + WGrid.corridor(bj),
                     x1: WGrid.line(bi + 1) - WGrid.corridor(bi + 1), z1: WGrid.line(bj + 1) - WGrid.corridor(bj + 1))
    }

    /// a believable place to go, within a few blocks of `p`.  `hour` steers the choice (shops by day, home late, nightlife downtown)
    func makeDestination(near p: Vec2, rng: inout SeededRNG, hour: Float, dwellScale: Float) -> (dest: NPCDestination, anchors: [PedNode])? {
        let gi: Int = WGrid.blockIndex(p.x) + rng.int(-3, 3)
        let gj: Int = WGrid.blockIndex(p.y) + rng.int(-3, 3)
        let kind: WBlockKind = WGrid.blockKind(layout, at: Vec2(WGrid.line(gi) + 30, WGrid.line(gj) + 30))
        var dwell: Float = rng.float(3, 12) * dwellScale

        if kind == WBlockKind.park || kind == WBlockKind.plaza {
            let r: WRect = blockRect(gi, gj)
            let q: Vec2 = Vec2(rng.float(r.x0 + 4, r.x1 - 4), rng.float(r.z0 + 4, r.z1 - 4))
            let anchors: [PedNode] = cornerAnchors(ofBlockI: gi, j: gj)
            let k: NPCDestinationKind = kind == WBlockKind.park ? NPCDestinationKind.park : NPCDestinationKind.plaza
            dwell = rng.float(8, 30) * dwellScale
            return (NPCDestination(kind: k, position: q, facing: rng.float(-3.1, 3.1), dwell: dwell), anchors)
        }

        // taxi stop (a few of them per area)
        if !taxiStops.isEmpty && rng.chance(0.12) {
            var bestStop: PedTaxiStop? = nil
            var bestD: Float = 500
            for s in taxiStops {
                let d: Float = simd_distance(s.position, p)
                if d < bestD && d > 25 && rng.chance(0.6) {
                    bestD = d
                    bestStop = s
                }
            }
            if let s = bestStop, let anc = edgeEndpoints(for: s.position) {
                return (NPCDestination(kind: NPCDestinationKind.taxiStop, position: s.position, facing: s.facing, dwell: 60), anc)
            }
        }

        // a point on a sidewalk of the chosen intersection region
        let alongX: Bool = rng.chance(0.5)
        let side: Float = rng.chance(0.5) ? 1 : -1
        var pos: Vec2 = Vec2(0, 0)
        var anchors: [PedNode] = []
        var faceDir: Vec2 = Vec2(0, 0)
        var adj: WBlockKind = kind
        if alongX {
            let lo: Float = WGrid.line(gi) + WGrid.corridor(gi) + 2
            let hi: Float = WGrid.line(gi + 1) - WGrid.corridor(gi + 1) - 2
            if hi <= lo { return nil }
            let z: Float = WGrid.line(gj) + side * WGrid.walkOffset(gj)
            pos = Vec2(rng.float(lo, hi), z)
            let sz: Int = side > 0 ? 2 : 0
            anchors = [PedNode(i: gi, j: gj, c: 1 | sz), PedNode(i: gi + 1, j: gj, c: 0 | sz)]
            faceDir = Vec2(0, side)
            adj = WGrid.blockKind(layout, at: pos + faceDir * 12)
        } else {
            let lo: Float = WGrid.line(gj) + WGrid.corridor(gj) + 2
            let hi: Float = WGrid.line(gj + 1) - WGrid.corridor(gj + 1) - 2
            if hi <= lo { return nil }
            let x: Float = WGrid.line(gi) + side * WGrid.walkOffset(gi)
            pos = Vec2(x, rng.float(lo, hi))
            let sx: Int = side > 0 ? 1 : 0
            anchors = [PedNode(i: gi, j: gj, c: sx | 2), PedNode(i: gi, j: gj + 1, c: sx | 0)]
            faceDir = Vec2(side, 0)
            adj = WGrid.blockKind(layout, at: pos + faceDir * 12)
        }
        var k: NPCDestinationKind = NPCDestinationKind.roadside
        var facing: Float? = nil
        let roll: Float = rng.float()
        switch adj {
        case .downtown, .midrise:
            let shopsOpen: Bool = hour > 8 && hour < 22
            if roll < (shopsOpen ? 0.55 : 0.2) {
                k = NPCDestinationKind.shopFront
                facing = headingOf(faceDir)
                dwell = rng.float(4, 14) * dwellScale
            } else if roll < 0.8 {
                k = NPCDestinationKind.downtown
            }
        case .residential:
            if roll < (hour > 19 || hour < 7 ? 0.5 : 0.25) {
                k = NPCDestinationKind.home
                facing = headingOf(faceDir)
                dwell = rng.float(1.5, 4)
            }
        case .industrial:
            k = roll < 0.3 ? NPCDestinationKind.industrial : NPCDestinationKind.roadside
        default:
            break
        }
        return (NPCDestination(kind: k, position: pos, facing: facing, dwell: dwell), anchors)
    }
}
