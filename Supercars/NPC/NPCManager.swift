import Foundation
import SceneKit
import simd

// MARK: - NPCManager: the living pedestrian population.  Owns the pool, decides who spawns / despawns around the player, runs the
// level-of-detail schedule (near: full AI + animation + collision; mid: reduced rates; far: light; dormant: minimal) and provides the
// shared environment (traffic threat checks, neighbours, hour of day) to every brain.

@MainActor
final class NPCManager: NPCEnvironment {
    private unowned let ctx: GameContext
    let variants = NPCVariantSystem()
    let navigator: PedNavigator
    let pool = NPCPool()
    let interaction = NPCInteraction()
    private let spawner: NPCSpawner
    private(set) var config: NPCConfig = NPCConfig()

    var enabled: Bool = true {
        didSet { if !enabled { releaseAll() } }
    }
    private var suspended: Bool = false
    private var built: Bool = false
    private var spawnTimer: Float = 0
    private var nextID: Int = 1
    private var rng = SeededRNG(seed: 0xC0DE_25)
    private var bodies: [MovingBody] = []
    private var footstepsThisFrame: Int = 0
    private var scratchPositions: [Vec2] = []

    /// other moving vehicles (taxis, police) for threat checks: set by the traffic manager
    var trafficBodies: () -> [MovingBody] = { return [] }

    var activeCount: Int { return pool.activeCount }
    var hour: Float { return ctx.world?.timeOfDay ?? 12 }

    init(ctx: GameContext, layout: WCityLayout) {
        self.ctx = ctx
        let nav = PedNavigator(layout: layout)
        navigator = nav
        spawner = NPCSpawner(layout: layout, navigator: nav)
        interaction.onPedestrianHit = { [weak self] (n: NPCCharacter, severity: Float) in
            self?.ctx.wanted?.reportPedestrianHit(severity: severity)
        }
    }

    // MARK: build

    func build() async {
        if built { return }
        built = true
        config = NPCConfig.forGraphics(ctx.settings.settings.graphics)
        variants.load(assets: ctx.assets)
        var names: [String] = []
        for k in variants.archetypes {
            if let a = variants.archetype(k) { names.append(a.file) }
        }
        await ctx.assets.preload(names)
        await pool.build(capacity: config.maximumActive, archetypes: variants.archetypes, assets: ctx.assets, variants: variants, parent: ctx.scene.rootNode)
        for n in pool.all {
            n.animator.onFootstep = { [weak self, weak n] in
                guard let self = self, let n = n else { return }
                self.footstep(n)
            }
        }
        assetLog("NPC pool: \(pool.capacity) pedestrians, \(variants.archetypes.count) archetypes")
    }

    func applyGraphics(_ g: GraphicsSettings) {
        config = NPCConfig.forGraphics(g)
    }

    // MARK: environment (NPCEnvironment)

    func crossingThreat(from a: Vec2, to b: Vec2) -> Bool {
        let mid: Vec2 = (a + b) * 0.5
        for v in bodies {
            let sp: Float = simd_length(v.vel)
            if sp < 0.8 { continue }
            if simd_distance(v.pos, mid) > 75 { continue }
            var t: Float = 0
            while t <= 3.6 {
                let p: Vec2 = v.pos + v.vel * t
                let d: Float = wSegmentDistance(p, a, b).dist
                if d < v.radius + 1.3 { return true }
                t += 0.4
            }
        }
        return false
    }

    func hasNearbyPedestrian(_ npc: NPCCharacter, within radius: Float) -> Bool {
        for o in pool.all where o.isActive && o !== npc {
            if simd_distance(o.pos, npc.pos) < radius { return true }
        }
        return false
    }

    // MARK: per frame

    func update(dt: Float, focus: Vec3, cameraForward: Vec3) {
        if !built || !enabled { return }
        let f2: Vec2 = Vec2(focus.x, focus.z)
        let indoors: Bool = ctx.player != nil && (ctx.player.location != PlayerLocation.outside || ctx.state.mode == GameMode.garage
            || ctx.state.mode == GameMode.sleeping || ctx.state.mode == GameMode.menu)
        if indoors != suspended {
            suspended = indoors
            pool.root.isHidden = indoors
        }
        if suspended { return }

        // moving bodies for the crossing / reaction checks
        bodies.removeAll(keepingCapacity: true)
        var playerBody: MovingBody? = nil
        if let car = ctx.car {
            let st = car.state
            let b = MovingBody(pos: Vec2(st.position.x, st.position.z), vel: Vec2(st.velocity.x, st.velocity.z), radius: 1.3, isPlayer: true)
            bodies.append(b)
            if ctx.state.mode == GameMode.driving { playerBody = b }
        }
        bodies.append(contentsOf: trafficBodies())

        let hourNow: Float = hour
        let active: [NPCCharacter] = pool.active

        // ---- spawn
        spawnTimer -= dt
        if spawnTimer <= 0 {
            spawnTimer = 0.45
            let target: Int = Int(Float(config.maximumActive) * NPCSchedule.populationScale(hour: hourNow))
            if active.count < target {
                let fwd: Vec2 = Vec2(cameraForward.x, cameraForward.z).normalizedSafe
                // fill up quickly when the street is empty (start of the game, after a teleport), one at a time otherwise
                let burst: Int = active.count < target / 2 ? 3 : 1
                var placed: [NPCCharacter] = active
                for _ in 0..<burst {
                    guard let sp = spawner.candidate(focus: f2, cameraForward: fwd, config: config, hour: hourNow, existing: placed, rng: &rng),
                          let n = pool.acquire(rng: &rng) else { break }
                    n.configure(id: nextID, worldSeed: 0xC0DE, variants: variants, position: sp.position, heading: sp.heading)
                    nextID += 1
                    n.brain.planNewTrip(n, env: self)
                    n.animator.setWeightShift(n.rng.float(-1, 1))
                    placed.append(n)
                }
            }
        }

        // ---- levels (budgeted): nearest pedestrians get the full simulation
        var order: [(NPCCharacter, Float)] = []
        for n in active { order.append((n, simd_distance(n.pos, f2))) }
        order.sort { $0.1 < $1.1 }
        var nearCount: Int = 0
        var farCount: Int = 0
        footstepsThisFrame = 0
        var playerFoot: Vec2? = nil
        if ctx.state.mode == GameMode.onFoot, let p = ctx.player { playerFoot = Vec2(p.node.simdPosition.x, p.node.simdPosition.z) }

        for (n, d) in order {
            var lvl: NPCLevel = config.level(forDistance: d)
            if lvl == NPCLevel.near {
                if nearCount >= config.nearbyBudget { lvl = NPCLevel.mid } else { nearCount += 1 }
            } else if lvl == NPCLevel.far || lvl == NPCLevel.dormant {
                farCount += 1
                if farCount > config.farBudget && lvl == NPCLevel.far { lvl = NPCLevel.dormant }
            }
            // passengers belong to the taxi system while they board, ride and get out
            var inTaxi: Bool = false
            switch n.state {
            case .enteringTaxi, .insideTaxi, .leavingTaxi:
                inTaxi = true
            default:
                break
            }
            if inTaxi {
                n.level = NPCLevel.near
                n.age += dt
                if n.state != NPCState.insideTaxi { step(n, level: NPCLevel.near, dt: dt, playerFoot: playerFoot) }
                continue
            }
            if d > config.despawnDistance || n.requestDespawn {
                pool.release(n)
                continue
            }
            n.level = lvl
            n.age += dt
            let hidden: Bool = lvl == NPCLevel.dormant
            if n.node.isHidden != hidden { n.node.isHidden = hidden }
            step(n, level: lvl, dt: dt, playerFoot: playerFoot)
        }

        // ---- reactions to the player's car
        interaction.update(dt: dt, npcs: order.map { $0.0 }.filter { $0.isActive }, car: playerBody,
                           carHeading: ctx.car?.state.heading ?? 0, env: self)
    }

    private func step(_ n: NPCCharacter, level: NPCLevel, dt: Float, playerFoot: Vec2?) {
        let li: Int = level.rawValue
        // ---- brain
        n.brainAccum += dt
        let brainDt: Float = 1 / max(0.2, config.brainRate[li])
        if n.brainAccum >= brainDt {
            n.brain.think(n, dt: n.brainAccum, env: self)
            n.brainAccum = 0
        }
        // ---- motion
        n.moveAccum += dt
        let moveRate: Float = config.moveRate[li]
        if moveRate <= 0 || n.moveAccum >= 1 / moveRate {
            let mdt: Float = n.moveAccum
            n.moveAccum = 0
            var colliders: [Collider] = []
            var neighbours: [Vec2] = []
            if level == NPCLevel.near || level == NPCLevel.mid {
                if let w = ctx.world { colliders = w.colliders.query(center: n.pos, radius: 3.0) }
                scratchPositions.removeAll(keepingCapacity: true)
                for o in pool.all where o.isActive && o !== n && simd_distance(o.pos, n.pos) < 1.4 { scratchPositions.append(o.pos) }
                neighbours = scratchPositions
                if let p = playerFoot, simd_distance(p, n.pos) < 1.4 { neighbours.append(p) }
            }
            n.stepMotion(dt: mdt, colliders: colliders, neighbors: neighbours)
        }
        // ---- animation (only where somebody can see it)
        if level == NPCLevel.near {
            n.animate(dt: dt)
        } else if level == NPCLevel.mid || level == NPCLevel.far {
            n.animAccum += dt
            let ar: Float = config.animationRate[li]
            if ar <= 0 || n.animAccum >= 1 / ar {
                n.animate(dt: n.animAccum)
                n.animAccum = 0
            }
        } else {
            n.stateTime += dt
            if n.gesture != NPCGesture.none {
                n.gestureTime += dt
                if n.gestureTime >= n.gestureDuration { n.gesture = NPCGesture.none }
            }
        }
    }

    // MARK: audio

    private func footstep(_ n: NPCCharacter) {
        if n.level != NPCLevel.near || footstepsThisFrame >= 3 { return }
        guard let p = ctx.player else { return }
        let listener: Vec3 = ctx.state.mode == GameMode.driving ? (ctx.car?.state.position ?? Vec3(0, 0, 0)) : p.node.simdPosition
        let d: Float = simd_distance(Vec2(listener.x, listener.z), n.pos)
        if d > 12 { return }
        footstepsThisFrame += 1
        let list: [SFX] = [SFX.footConcrete1, SFX.footConcrete2, SFX.footConcrete3]
        let vol: Float = clampf(0.10 + n.speed * 0.04, 0.10, 0.28) * (1 - d / 14)
        ctx.audio.play(list[Int.random(in: 0..<3)], volume: vol, rate: 0.94 + Float.random(in: 0...0.12), position: Vec3(n.pos.x, 0, n.pos.y))
    }

    // MARK: events / control

    func notifyCrash(at p: Vec2, magnitude: Float) {
        if !built || suspended { return }
        interaction.crash(at: p, magnitude: magnitude, npcs: pool.active, env: self)
    }

    /// pedestrians currently waiting for a taxi
    var waitingPassengers: [NPCCharacter] {
        var out: [NPCCharacter] = []
        for n in pool.all where n.isActive && n.state == NPCState.waitingForTaxi { out.append(n) }
        return out
    }

    func releaseAll() {
        for n in pool.active { pool.release(n) }
    }

    func release(_ n: NPCCharacter) {
        pool.release(n)
    }

    func snapshots() -> [NPCStateSnapshot] {
        var out: [NPCStateSnapshot] = []
        for n in pool.all where n.isActive { out.append(n.snapshot()) }
        return out
    }

    /// nearest pedestrian to a point (for taxis, police, debugging)
    func nearest(to p: Vec2, maxDistance: Float) -> NPCCharacter? {
        var best: NPCCharacter? = nil
        var bd: Float = maxDistance
        for n in pool.all where n.isActive {
            let d: Float = simd_distance(n.pos, p)
            if d < bd {
                bd = d
                best = n
            }
        }
        return best
    }
}
