import Foundation
import SceneKit
import UIKit
import simd

// MARK: - NavigationManager: destination + route guidance.
//   * a destination is a MapWaypoint (house, garage, race, police, taxi, district ...) or a dropped pin;
//   * the route follows the real streets: the hillside suburb roads down to the grid, then the street grid (Manhattan route between
//     the intersections nearest to the start and the target);
//   * it publishes NavigationInfo (distance, bearing arrow, polyline) for the HUD, the minimap and the big map, and shows a subtle
//     white light column over the destination while it is far away.

@MainActor
final class NavigationManager {
    private unowned let ctx: GameContext
    let registry = WaypointRegistry()
    private(set) var destination: MapWaypoint? = nil
    private var route: [Vec2] = []
    private var routeLength: Float = 0
    private var routeTimer: Float = 0
    private var districtTimer: Float = 0
    private var beam = SCNNode()
    private var beamBuilt: Bool = false
    private var rng = SeededRNG(seed: 0x9A71)

    init(ctx: GameContext) {
        self.ctx = ctx
    }

    // MARK: destination

    func setDestination(_ w: MapWaypoint) {
        destination = w
        routeTimer = 0
        ctx.state.showToast("Navigating to \(w.name)")
        recompute()
        buildBeamIfNeeded()
        beam.isHidden = false
    }

    func setDestination(point: Vec2, name: String) {
        let id: String = "pin"
        let w = MapWaypoint(id: id, name: name, subtitle: "Dropped pin", kind: WaypointKind.custom, position: point)
        registry.register(w)
        setDestination(w)
    }

    func clear() {
        destination = nil
        route = []
        beam.isHidden = true
        if ctx.state.navigation != nil { ctx.state.navigation = nil }
    }

    func setDestination(id: String) {
        if let w = registry.waypoint(id: id) { setDestination(w) }
    }

    // MARK: per frame

    func update(dt: Float) {
        guard let dest = destination else {
            updateDistrict(dt: dt)
            return
        }
        routeTimer -= dt
        if routeTimer <= 0 {
            routeTimer = 2.5
            recompute()
        }
        let p: Vec2 = playerPosition()
        let toTarget: Float = simd_distance(p, dest.routeTarget ?? dest.position)
        let arriveRadius: Float = ctx.state.mode == GameMode.driving ? 32 : 12
        if toTarget < arriveRadius {
            ctx.state.showToast("Arrived: \(dest.name)", seconds: 3)
            destination = nil
            route = []
            beam.isHidden = true
            ctx.state.navigation = nil
            return
        }
        publish(dest: dest, player: p, straight: toTarget)
        // light column: only while the target is far away
        beam.isHidden = toTarget < 70
        let t: Vec2 = dest.routeTarget ?? dest.position
        beam.simdPosition = Vec3(t.x, 0, t.y)
        updateDistrict(dt: dt)
    }

    private func updateDistrict(dt: Float) {
        districtTimer -= dt
        if districtTimer > 0 { return }
        districtTimer = 1.0
        let name: String = districtName(at: playerPosition())
        if ctx.state.districtName != name { ctx.state.districtName = name }
    }

    func playerPosition() -> Vec2 {
        if ctx.state.mode == GameMode.driving || ctx.state.mode == GameMode.menu, let c = ctx.car {
            return Vec2(c.state.position.x, c.state.position.z)
        }
        if let p = ctx.player { return Vec2(p.node.simdPosition.x, p.node.simdPosition.z) }
        return Vec2(0, 0)
    }

    func playerHeading() -> Float {
        if ctx.state.mode == GameMode.driving || ctx.state.mode == GameMode.menu, let c = ctx.car { return c.state.heading }
        if let p = ctx.player { return p.node.simdEulerAngles.y }
        return 0
    }

    // MARK: publishing

    private func publish(dest: MapWaypoint, player p: Vec2, straight: Float) {
        var info = NavigationInfo()
        info.destinationID = dest.id
        info.name = dest.name
        info.kind = dest.kind.rawValue
        info.target = dest.routeTarget ?? dest.position
        info.route = route
        // remaining distance: route length ahead of the closest route point
        var remaining: Float = straight
        var aim: Vec2 = info.target
        if route.count >= 2 {
            var bestI: Int = 0
            var bestD: Float = Float.greatestFiniteMagnitude
            for (i, q) in route.enumerated() {
                let d: Float = simd_distance_squared(q, p)
                if d < bestD {
                    bestD = d
                    bestI = i
                }
            }
            var acc: Float = simd_distance(p, route[bestI])
            var k: Int = bestI
            var aimed: Bool = false
            var walked: Float = 0
            while k + 1 < route.count {
                let seg: Float = simd_distance(route[k], route[k + 1])
                acc += seg
                walked += seg
                if !aimed && walked >= 45 {
                    aim = route[k + 1]
                    aimed = true
                }
                k += 1
            }
            remaining = acc
            if !aimed { aim = route[route.count - 1] }
        }
        info.distance = remaining
        let hd: Float = playerHeading()
        let d: Vec2 = aim - p
        info.bearing = simd_length(d) > 0.5 ? angleDiff(hd, headingOf(d)) : 0
        if ctx.state.navigation != info { ctx.state.navigation = info }
    }

    // MARK: route

    private func recompute() {
        guard let dest = destination else { return }
        let p: Vec2 = playerPosition()
        let q: Vec2 = dest.routeTarget ?? dest.position
        route = computeRoute(from: p, to: q)
        var len: Float = 0
        if route.count > 1 { for i in 1..<route.count { len += simd_distance(route[i], route[i - 1]) } }
        routeLength = len
        publish(dest: dest, player: p, straight: simd_distance(p, q))
    }

    private func inSuburb(_ p: Vec2) -> Bool {
        return WGrid.suburbRect.expanded(40).contains(p)
    }

    /// polyline from `p` along the suburb roads down to the grid (returns the polyline and the grid node where it joins)
    private func suburbToGrid(from p: Vec2, target: Vec2) -> (points: [Vec2], node: WGridNode)? {
        guard let w = ctx.world else { return nil }
        let layout: WCityLayout = w.cityLayout
        if layout.suburbRoadIDs.count < 3 { return nil }
        let hill: WRoad = layout.roads[layout.suburbRoadIDs[0]]
        let summit: WRoad = layout.roads[layout.suburbRoadIDs[1]]
        let bulb: WRoad = layout.roads[layout.suburbRoadIDs[2]]
        var pts: [Vec2] = [p]

        func arc(_ road: WRoad, _ hit: WRoadHit) -> Float {
            return road.cum[hit.seg] + hit.t * (road.cum[hit.seg + 1] - road.cum[hit.seg])
        }
        func walk(_ road: WRoad, from a: Float, to b: Float) {
            let step: Float = 8
            let n: Int = max(1, Int(abs(b - a) / step))
            for k in 1...n {
                let s: Float = a + (b - a) * Float(k) / Float(n)
                pts.append(road.sample(at: s).p)
            }
        }
        var onHill: Bool = false
        if let hit = layout.index.nearest(p, maxDist: 140) {
            if hit.road.id == summit.id || hit.road.id == bulb.id {
                // down Summit Lane to the junction with Hillcrest Drive (its start)
                walk(summit, from: hit.road.id == summit.id ? arc(summit, hit) : summit.length, to: 0)
            } else if hit.road.id == hill.id {
                onHill = true
            }
            if onHill {
                let s: Float = arc(hill, hit)
                let toStart: Float = s
                let toEnd: Float = hill.length - s
                let startNode = WGridNode(i: 8, j: 2)
                let endNode = WGridNode(i: 8, j: 5)
                let dStart: Float = simd_distance(startNode.position, target) + toStart * 0.3
                let dEnd: Float = simd_distance(endNode.position, target) + toEnd * 0.3
                if dStart <= dEnd {
                    walk(hill, from: s, to: 0)
                    return (pts, startNode)
                }
                walk(hill, from: s, to: hill.length)
                return (pts, endNode)
            }
        }
        // from the junction (start of Summit Lane = a point of Hillcrest Drive)
        let junction: Vec2 = summit.sample(at: 0).p
        if let jh = layout.index.nearest(junction, maxDist: 30), jh.road.id == hill.id {
            let s: Float = arc(hill, jh)
            let startNode = WGridNode(i: 8, j: 2)
            let endNode = WGridNode(i: 8, j: 5)
            let dStart: Float = simd_distance(startNode.position, target) + s * 0.3
            let dEnd: Float = simd_distance(endNode.position, target) + (hill.length - s) * 0.3
            if dStart <= dEnd {
                walk(hill, from: s, to: 0)
                return (pts, startNode)
            }
            walk(hill, from: s, to: hill.length)
            return (pts, endNode)
        }
        return nil
    }

    /// street-grid polyline between two points
    private func gridRoute(from a: Vec2, to b: Vec2) -> [Vec2] {
        let na: WGridNode = WGridNode.nearest(to: a)
        let nb: WGridNode = WGridNode.nearest(to: b)
        let nodes: [WGridNode] = TrafficRouter.route(from: na, arriving: nil, to: nb, rng: &rng)
        var out: [Vec2] = [a]
        for n in nodes { out.append(n.position) }
        out.append(b)
        return out
    }

    func computeRoute(from p: Vec2, to q: Vec2) -> [Vec2] {
        let pSub: Bool = inSuburb(p)
        let qSub: Bool = inSuburb(q)
        if pSub && qSub {
            return [p, q]
        }
        var result: [Vec2] = []
        var gridStart: Vec2 = p
        var gridEnd: Vec2 = q
        if pSub, let s = suburbToGrid(from: p, target: q) {
            result = s.points
            gridStart = s.node.position
        }
        var tail: [Vec2] = []
        if qSub, let s = suburbToGrid(from: q, target: p) {
            tail = s.points.reversed()
            gridEnd = s.node.position
        }
        let mid: [Vec2] = gridRoute(from: gridStart, to: gridEnd)
        result.append(contentsOf: mid)
        result.append(contentsOf: tail)
        // drop consecutive duplicates
        var clean: [Vec2] = []
        for pt in result {
            if let l = clean.last, simd_distance(l, pt) < 0.5 { continue }
            clean.append(pt)
        }
        return clean
    }

    // MARK: beam

    private func buildBeamIfNeeded() {
        if beamBuilt { return }
        beamBuilt = true
        let cyl = SCNCylinder(radius: 0.9, height: 320)
        let m = SCNMaterial()
        m.lightingModel = SCNMaterial.LightingModel.constant
        m.diffuse.contents = UIColor(white: 1, alpha: 1)
        m.transparency = 0.16
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        m.blendMode = SCNBlendMode.add
        cyl.materials = [m]
        let holder = SCNNode(geometry: cyl)
        holder.simdPosition = Vec3(0, 160, 0)
        holder.castsShadow = false
        holder.categoryBitMask = 0x2
        beam.addChildNode(holder)
        beam.name = "navBeam"
        ctx.scene.rootNode.addChildNode(beam)
        beam.isHidden = true
    }

    // MARK: districts

    func districtName(at p: Vec2) -> String {
        if inSuburb(p) { return "Hillside Estates" }
        let layout = ctx.world?.cityLayout
        if let l = layout {
            for r in l.parkRects where r.expanded(20).contains(p) { return "City Park" }
            if l.plazaRect.width > 10 && l.plazaRect.expanded(20).contains(p) { return "City Plaza" }
            if !WGrid.isCityBlock(l, at: p) { return "Countryside" }
            let kind: WBlockKind = WGrid.blockKind(l, at: p)
            let bi: Int = WGrid.wrapIndex(WGrid.blockIndex(p.x))
            let bj: Int = WGrid.wrapIndex(WGrid.blockIndex(p.y))
            switch kind {
            case .downtown: return "Downtown"
            case .midrise: return "Midtown"
            case .residential: return (bi >= 1 && bj >= 1) ? "Luxury Residential" : "Residential"
            case .industrial: return "Industrial District"
            case .park: return "City Park"
            case .plaza: return "City Plaza"
            case .civic: return "Civic Centre"
            }
        }
        return ""
    }
}
