import Foundation
import SceneKit
import simd

// MARK: - TrafficManager: owns the AI vehicles (taxis, police).  Loads the vehicle meta, spawns cars on lanes around the player, keeps
// their colliders in the collider world (so the Porsche cannot drive through them), shares the perception data (bodies, intersection
// claims) and resolves contact with the player's car.

private struct TrafficVehicleMeta: Decodable {
    let file: String
    let length: Float
    let width: Float
    let height: Float
    let wheelRadius: Float
    let frontAxleZ: Float
    let rearAxleZ: Float
    let trackFront: Float
    let hubY: Float
    let wheelbase: Float
    let bodyMinZ: Float
    let bodyMaxZ: Float
}

private struct TrafficMetaFile: Decodable {
    let taxi: TrafficVehicleMeta
    let police: TrafficVehicleMeta
}

@MainActor
final class TrafficManager {
    private unowned let ctx: GameContext
    private(set) var vehicles: [TrafficVehicle] = []
    private var specs: [TrafficKind: TrafficSpec] = [:]
    private var claims: [Int: (owner: Int, time: Float)] = [:]
    private var colliderIDs: [Int: Int] = [:]
    private var lastColliderPos: [Int: Vec2] = [:]
    private var allBodies: [TrafficBody] = []
    private var rng = SeededRNG(seed: 0x7A11)
    private var nextID: Int = 1
    private var clock: Float = 0
    private var built: Bool = false
    private var spawnTimer: Float = 1
    private let root = SCNNode()
    private var lastFocus: Vec2 = Vec2(0, 0)

    var taxiEnabled: Bool = true
    var policeEnabled: Bool = true
    var isNight: Bool = false
    private(set) var focus: Vec2 = Vec2(0, 0)

    /// number of AI vehicles per kind (scaled by the graphics preset)
    var taxiCount: Int = 5
    var policeCount: Int = 4

    init(ctx: GameContext) {
        self.ctx = ctx
        root.name = "trafficRoot"
    }

    var taxis: [TrafficVehicle] { return vehicles.filter { $0.kind == TrafficKind.taxi } }
    var police: [TrafficVehicle] { return vehicles.filter { $0.kind == TrafficKind.police } }

    // MARK: build

    func build() async {
        if built { return }
        built = true
        ctx.scene.rootNode.addChildNode(root)
        switch ctx.settings.settings.graphics.preset {
        case .low:
            taxiCount = 3
            policeCount = 2
        case .medium:
            taxiCount = 4
            policeCount = 3
        default:
            taxiCount = 5
            policeCount = 4
        }
        var meta: TrafficMetaFile? = nil
        do {
            meta = try ctx.assets.json("traffic_meta", as: TrafficMetaFile.self)
        } catch {
            assetLog("traffic_meta.json not readable: \(error.localizedDescription)")
        }
        guard let m = meta else { return }
        await ctx.assets.preload(["taxi", "police"])
        specs[TrafficKind.taxi] = TrafficSpec(model: "taxi", length: m.taxi.length, halfWidth: 0.93, wheelbase: m.taxi.wheelbase,
                                              wheelRadius: m.taxi.wheelRadius, mass: 1550, aMax: 2.3, brake: 3.0, speedLimit: 13.9,
                                              frontAxleZ: m.taxi.frontAxleZ, rearAxleZ: m.taxi.rearAxleZ, track: m.taxi.trackFront,
                                              hubY: m.taxi.hubY, bodyMinZ: m.taxi.bodyMinZ, bodyMaxZ: m.taxi.bodyMaxZ)
        specs[TrafficKind.police] = TrafficSpec(model: "police", length: m.police.length, halfWidth: 1.0, wheelbase: m.police.wheelbase,
                                                wheelRadius: m.police.wheelRadius, mass: 2300, aMax: 3.4, brake: 4.0, speedLimit: 15.5,
                                                frontAxleZ: m.police.frontAxleZ, rearAxleZ: m.police.rearAxleZ, track: m.police.trackFront,
                                                hubY: m.police.hubY, bodyMinZ: m.police.bodyMinZ, bodyMaxZ: m.police.bodyMaxZ)
        for _ in 0..<taxiCount { addVehicle(TrafficKind.taxi) }
        await Task.yield()
        for _ in 0..<policeCount { addVehicle(TrafficKind.police) }
    }

    private func addVehicle(_ kind: TrafficKind) {
        guard let spec = specs[kind] else { return }
        let v = TrafficVehicle(id: nextID, kind: kind, spec: spec, manager: self)
        nextID += 1
        if v.buildVisual(assets: ctx.assets) {
            root.addChildNode(v.node)
            vehicles.append(v)
            if let w = ctx.world { colliderIDs[v.id] = w.colliders.allocateID() }
        }
    }

    // MARK: perception API used by vehicles

    func bodies(near p: Vec2, radius: Float, excluding id: Int) -> [TrafficBody] {
        var out: [TrafficBody] = []
        let r2: Float = radius * radius
        for b in allBodies where b.id != id {
            if simd_distance_squared(b.pos, p) <= r2 { out.append(b) }
        }
        return out
    }

    func claimOwner(of key: Int) -> Int? {
        guard let c = claims[key] else { return nil }
        if clock - c.time > 9 {
            claims[key] = nil
            return nil
        }
        return c.owner
    }

    @discardableResult
    func claim(intersection key: Int, by id: Int) -> Bool {
        if let c = claims[key], c.owner != id, clock - c.time <= 9 { return false }
        claims[key] = (id, clock)
        return true
    }

    func release(intersection key: Int, by id: Int) {
        if let c = claims[key], c.owner == id { claims[key] = nil }
    }

    // MARK: helpers for the controllers

    /// heading direction (axis aligned) of a vehicle and the intersection it reaches next
    func nextNode(for v: TrafficVehicle) -> (node: WGridNode, dir: Vec2) {
        let f: Vec2 = headingForward2(v.heading)
        var dir: Vec2 = Vec2(0, 0)
        if abs(f.x) >= abs(f.y) { dir = Vec2(f.x >= 0 ? 1 : -1, 0) } else { dir = Vec2(0, f.y >= 0 ? 1 : -1) }
        let p: Vec2 = v.pos
        var i: Int = WGrid.nearestLine(p.x)
        var j: Int = WGrid.nearestLine(p.y)
        let margin: Float = 8
        if dir.x > 0 { i = Int(ceilf((p.x + margin) / WGrid.pitch)) }
        else if dir.x < 0 { i = Int(floorf((p.x - margin) / WGrid.pitch)) }
        if dir.y > 0 { j = Int(ceilf((p.y + margin) / WGrid.pitch)) }
        else if dir.y < 0 { j = Int(floorf((p.y - margin) / WGrid.pitch)) }
        return (WGridNode(i: i, j: j), dir)
    }

    /// Plans a route that ends stopped at the curb next to sidewalk point `q`. Returns false when no lane geometry exists there.
    @discardableResult
    func plan(_ v: TrafficVehicle, toSidewalkPoint q: Vec2) -> Bool {
        guard let stop = TrafficRouter.curbStop(forSidewalkPoint: q) else { return false }
        if !WGrid.hasGridStreets(at: stop.point) { return false }
        let nx = nextNode(for: v)
        var nodes: [WGridNode] = TrafficRouter.route(from: nx.node, arriving: nx.dir, to: stop.before, rng: &rng)
        // never end with a U-turn into the stop leg: detour around the block corner instead
        var arrival: Vec2 = nx.dir
        if nodes.count >= 2 { arrival = TrafficRouter.direction(from: nodes[nodes.count - 2], to: nodes[nodes.count - 1]) }
        if arrival.x == -stop.dir.x && arrival.y == -stop.dir.y {
            if nodes.count < 2 { return false }
            let before: WGridNode = stop.before
            let r: Vec2 = TrafficRouter.right(arrival)
            let prev: WGridNode = nodes[nodes.count - 2]
            nodes.removeLast()
            nodes.append(TrafficRouter.step(prev, r))
            nodes.append(TrafficRouter.step(before, r))
            nodes.append(before)
        }
        if nodes.isEmpty { return false }
        let tan: Vec2 = headingForward2(v.heading)
        let path = TrafficRouter.build(start: v.pos, heading: tan, nodes: nodes, stop: (stop.point, stop.dir), limit: v.speedLimit)
        v.setPath(path, nodes: nodes)
        return true
    }

    /// true when no intersection (turn arc) is close ahead, so the path can be replaced safely
    func canReplan(_ v: TrafficVehicle) -> Bool {
        for m in v.path.marks where m.s > v.progress - 1 { return m.s - v.progress > 38 }
        return true
    }

    /// route to an intersection (pursuit / investigation); the path continues a little beyond so it never ends abruptly
    @discardableResult
    func plan(_ v: TrafficVehicle, toNode n: WGridNode) -> Bool {
        if !WGrid.hasGridStreets(at: n.position) { return false }
        let nx = nextNode(for: v)
        var nodes: [WGridNode] = TrafficRouter.route(from: nx.node, arriving: nx.dir, to: n, rng: &rng)
        if nodes.isEmpty { return false }
        var lastDir: Vec2 = nx.dir
        if nodes.count >= 2 { lastDir = TrafficRouter.direction(from: nodes[nodes.count - 2], to: nodes[nodes.count - 1]) }
        if let last = nodes.last {
            nodes += TrafficRouter.cruise(from: last, heading: lastDir, count: 3, rng: &rng)
        }
        let tan: Vec2 = headingForward2(v.heading)
        let path = TrafficRouter.build(start: v.pos, heading: tan, nodes: nodes, stop: nil, limit: v.speedLimit)
        v.setPath(path, nodes: nodes)
        return true
    }

    /// cruising: keeps at least ~100 m of route ahead
    func extendCruise(_ v: TrafficVehicle) {
        if v.path.length - v.progress > 110 { return }
        var firstAhead: Int = v.routeNodes.count
        for (k, m) in v.path.marks.enumerated() where m.s > v.progress - 1 {
            firstAhead = k
            break
        }
        // wait until the current intersection is behind us (no path surgery inside a turn)
        if firstAhead < v.path.marks.count && v.path.marks[firstAhead].s - v.progress < 38 { return }
        var nodes: [WGridNode] = firstAhead < v.routeNodes.count ? Array(v.routeNodes[firstAhead...]) : []
        var lastDir: Vec2 = headingForward2(v.heading)
        if abs(lastDir.x) >= abs(lastDir.y) { lastDir = Vec2(lastDir.x >= 0 ? 1 : -1, 0) } else { lastDir = Vec2(0, lastDir.y >= 0 ? 1 : -1) }
        var startNode: WGridNode
        if let l = nodes.last {
            startNode = l
            if nodes.count >= 2 { lastDir = TrafficRouter.direction(from: nodes[nodes.count - 2], to: l) }
        } else {
            let nx = nextNode(for: v)
            startNode = nx.node
            lastDir = nx.dir
            nodes = [nx.node]
        }
        nodes += TrafficRouter.cruise(from: startNode, heading: lastDir, count: 6, rng: &rng)
        let tan: Vec2 = v.path.sample(v.progress).tan
        let path = TrafficRouter.build(start: v.pos, heading: tan, nodes: nodes, stop: nil, limit: v.speedLimit)
        v.setPath(path, nodes: nodes)
    }

    /// puts a vehicle on a lane `distance` metres from `around`, out of sight, heading along a random street
    @discardableResult
    func spawnCruising(_ v: TrafficVehicle, around: Vec2, minDistance: Float, maxDistance: Float) -> Bool {
        for _ in 0..<10 {
            let a: Float = rng.float(0, Float.tau)
            let r: Float = rng.float(minDistance, maxDistance)
            let q: Vec2 = around + Vec2(cosf(a), sinf(a)) * r
            let n: WGridNode = WGridNode.nearest(to: q)
            if !WGrid.hasGridStreets(at: n.position) { continue }
            let d: Vec2 = TrafficRouter.dirs[rng.int(0, 3)]
            let start: Vec2 = TrafficRouter.lanePoint(n, heading: d) - d * 45
            if !WGrid.hasGridStreets(at: start) { continue }
            var clear: Bool = true
            for o in vehicles where o.active && simd_distance(o.pos, start) < 20 {
                clear = false
                break
            }
            if !clear { continue }
            var nodes: [WGridNode] = [n]
            nodes += TrafficRouter.cruise(from: n, heading: d, count: 6, rng: &rng)
            let path = TrafficRouter.build(start: start, heading: d, nodes: nodes, stop: nil, limit: v.speedLimit)
            v.place(pos: start, heading: headingOf(d), path: path, nodes: nodes)
            v.speed = min(v.speedLimit * 0.6, 8)
            return true
        }
        return false
    }

    // MARK: per frame

    func update(dt: Float, focus f: Vec3) {
        if !built { return }
        clock += dt
        focus = Vec2(f.x, f.z)
        if let w = ctx.world { isNight = w.timeOfDay < 6.5 || w.timeOfDay > 18.5 }
        let suspended: Bool = ctx.player != nil && (ctx.player.location != PlayerLocation.outside || ctx.state.mode == GameMode.garage
            || ctx.state.mode == GameMode.menu || ctx.state.mode == GameMode.sleeping)
        root.isHidden = suspended
        if suspended { return }

        collectBodies()
        for v in vehicles where v.active {
            let d: Float = simd_distance(v.pos, focus)
            let detailed: Bool = d < 200
            if detailed {
                v.update(dt: dt, detailed: true)
            } else {
                v.update(dt: min(dt * 2, 0.1), detailed: false)
            }
            v.node.isHidden = d > 380
            syncCollider(v, near: d < 90)
        }
        contactWithPlayer()
    }

    private func collectBodies() {
        allBodies.removeAll(keepingCapacity: true)
        for v in vehicles where v.active { allBodies.append(v.body) }
        if let car = ctx.car {
            let st = car.state
            allBodies.append(TrafficBody(id: -1, pos: Vec2(st.position.x, st.position.z), vel: Vec2(st.velocity.x, st.velocity.z), radius: 1.15,
                                         halfLength: 2.3, isPedestrian: false, isPlayer: true))
        }
        if ctx.state.mode == GameMode.onFoot, let p = ctx.player {
            allBodies.append(TrafficBody(id: -2, pos: Vec2(p.node.simdPosition.x, p.node.simdPosition.z), vel: Vec2(0, 0), radius: 0.4,
                                         halfLength: 0.3, isPedestrian: true, isPlayer: true))
        }
        if let npcs = ctx.npcs {
            for n in npcs.pool.all where n.isActive && n.level.rawValue <= NPCLevel.far.rawValue {
                if simd_distance(n.pos, focus) > 140 { continue }
                let vel: Vec2 = headingForward2(n.heading) * n.speed
                allBodies.append(TrafficBody(id: -1000 - n.slot, pos: n.pos, vel: vel, radius: 0.4, halfLength: 0.3, isPedestrian: true))
            }
        }
    }

    /// bodies of moving vehicles for the pedestrians' crossing checks
    func movingBodies() -> [MovingBody] {
        var out: [MovingBody] = []
        for v in vehicles where v.active {
            let vel: Vec2 = headingForward2(v.heading) * v.speed
            out.append(MovingBody(pos: v.pos, vel: vel, radius: v.halfWidth + 0.6, isPlayer: false))
        }
        return out
    }

    // MARK: colliders (the Porsche cannot drive through AI cars)

    private func syncCollider(_ v: TrafficVehicle, near: Bool) {
        guard let w = ctx.world, let id = colliderIDs[v.id] else { return }
        if !near {
            if lastColliderPos[v.id] != nil {
                w.colliders.remove(id: id)
                lastColliderPos[v.id] = nil
            }
            return
        }
        if let last = lastColliderPos[v.id], simd_distance(last, v.pos) < 0.04 { return }
        lastColliderPos[v.id] = v.pos
        let centre: Vec2 = v.pos
        let c = Collider.box(id: id, kind: ColliderKind.prop, center: centre, halfExtents: Vec2(v.halfWidth, v.length * 0.5 - 0.15),
                             heading: v.heading, height: 1.6, mass: v.spec.mass)
        w.colliders.add(c)
    }

    private func removeColliders(for v: TrafficVehicle) {
        guard let w = ctx.world, let id = colliderIDs[v.id] else { return }
        w.colliders.remove(id: id)
        lastColliderPos[v.id] = nil
    }

    func deactivate(_ v: TrafficVehicle) {
        removeColliders(for: v)
        v.deactivate()
    }

    // MARK: contact with the player's car

    private func contactWithPlayer() {
        guard let car = ctx.car, ctx.state.mode == GameMode.driving else { return }
        let st = car.state
        let cp: Vec2 = Vec2(st.position.x, st.position.z)
        let cv: Vec2 = Vec2(st.velocity.x, st.velocity.z)
        let fwd: Vec2 = headingForward2(st.heading)
        let lft: Vec2 = headingLeft2(st.heading)
        for v in vehicles where v.active {
            let rel: Vec2 = v.pos - cp
            let d: Float = simd_length(rel)
            if d > 7.5 { continue }
            // separating axis test with slightly inflated boxes
            let axes: [Vec2] = [fwd, lft, headingForward2(v.heading), headingLeft2(v.heading)]
            var minPen: Float = Float.greatestFiniteMagnitude
            var normal: Vec2 = Vec2(0, 0)
            var hit: Bool = true
            for ax in axes {
                let rA: Float = 2.45 * abs(simd_dot(fwd, ax)) + 1.15 * abs(simd_dot(lft, ax))
                let rB: Float = (v.length * 0.5 + 0.1) * abs(simd_dot(headingForward2(v.heading), ax)) + (v.halfWidth + 0.15) * abs(simd_dot(headingLeft2(v.heading), ax))
                let dist: Float = simd_dot(rel, ax)
                let pen: Float = rA + rB - abs(dist)
                if pen <= 0 {
                    hit = false
                    break
                }
                if pen < minPen {
                    minPen = pen
                    normal = dist >= 0 ? ax : ax * -1
                }
            }
            if !hit { continue }
            let closing: Float = simd_dot(cv - headingForward2(v.heading) * v.speed, normal)
            if closing < 0.6 { continue }
            let strength: Float = min(closing, 18)
            v.bump(velocity: normal * (strength * 0.6), yaw: simd_dot(normal, headingLeft2(v.heading)) * strength * 0.01)
            v.pos += normal * min(minPen * 0.5, 0.4)
            ctx.wanted?.reportVehicleCollision(with: v.kind, speed: closing)
            ctx.npcs?.notifyCrash(at: v.pos, magnitude: clampf(closing / 18, 0.1, 1))
        }
    }

    // MARK: control

    func setEnabled(taxis: Bool, police: Bool) {
        taxiEnabled = taxis
        policeEnabled = police
        for v in vehicles where (v.kind == TrafficKind.taxi && !taxis) || (v.kind == TrafficKind.police && !police) {
            if v.active { deactivate(v) }
        }
    }

    func vehicle(near p: Vec2, kind: TrafficKind, maxDistance: Float) -> TrafficVehicle? {
        var best: TrafficVehicle? = nil
        var bd: Float = maxDistance
        for v in vehicles where v.kind == kind && v.active {
            let d: Float = simd_distance(v.pos, p)
            if d < bd {
                bd = d
                best = v
            }
        }
        return best
    }

    /// developer: put one more vehicle of `kind` right in front of the player
    func spawnNear(_ kind: TrafficKind, at p: Vec2, heading: Float) -> Bool {
        for v in vehicles where v.kind == kind && !v.active {
            let dir: Vec2 = headingForward2(heading)
            let n: WGridNode = WGridNode.nearest(to: p + dir * 60)
            if spawnCruising(v, around: n.position, minDistance: 10, maxDistance: 60) { return true }
        }
        return false
    }
}
