import Foundation
import simd

// MARK: - PoliceSystem: patrol, response, pursuit and stop behaviour for the Ford Ranger police trucks.
//   0 stars  every unit cruises the streets (one or two at a time, fewer at night)
//   1 star   the closest unit drives to where the player was seen and observes (no siren)
//   2 stars  the closest unit chases with the siren on (limit 20 m/s)
//   3 stars  two more units join, higher speed limit;  4 - 5 stars: up to four units, up to 32 m/s
// A pursuing unit that gets close to a player who has stopped holds position; after a few seconds the player is "busted" (warning).
// Units follow the street grid like every AI car, so they can be outrun on open ground and around corners.

@MainActor
final class PoliceSystem {
    private enum UnitMode {
        case patrol, investigate, pursue
    }

    private struct Unit {
        var mode: UnitMode = UnitMode.patrol
        var replanTimer: Float = 0
        var holdTimer: Float = 0
        var lastNode: WGridNode? = nil
    }

    private unowned let ctx: GameContext
    private unowned let traffic: TrafficManager
    private var units: [Int: Unit] = [:]
    private var spawnTimer: Float = 2
    private var sirenTimer: Float = 0
    private var stoppedTimer: Float = 0
    private var rng = SeededRNG(seed: 0x501CE)

    init(ctx: GameContext, traffic: TrafficManager) {
        self.ctx = ctx
        self.traffic = traffic
    }

    private var vehicles: [TrafficVehicle] { return traffic.police }

    // MARK: queries

    func nearestUnitDistance(to p: Vec2) -> Float {
        var best: Float = Float.greatestFiniteMagnitude
        for v in vehicles where v.active { best = min(best, simd_distance(v.pos, p)) }
        return best
    }

    func hasSirenWithin(_ r: Float, of p: Vec2) -> Bool {
        for v in vehicles where v.active && v.sirenOn && simd_distance(v.pos, p) < r { return true }
        return false
    }

    var activeCount: Int {
        var n: Int = 0
        for v in vehicles where v.active { n += 1 }
        return n
    }

    // MARK: per frame

    func update(dt: Float) {
        guard traffic.policeEnabled, let car = ctx.car, let wanted = ctx.wanted else { return }
        let st = car.state
        let carPos: Vec2 = Vec2(st.position.x, st.position.z)
        let lvl: Int = wanted.level
        let all: [TrafficVehicle] = vehicles
        if all.isEmpty { return }

        // ---- how many units should be on the street
        let night: Bool = traffic.isNight
        let patrolBase: Int = night ? 1 : 2
        let responders: [Int] = [0, 1, 2, 3, 4, 4]
        let wanted4: Int = min(all.count, responders[max(0, min(5, lvl))])
        let target: Int = max(min(patrolBase, all.count), wanted4)

        spawnTimer -= dt
        if spawnTimer <= 0 {
            spawnTimer = 1.5
            var activeNow: Int = 0
            for v in all where v.active { activeNow += 1 }
            if activeNow < target {
                for v in all where !v.active {
                    // reinforcements arrive from further away and head straight for the player
                    if traffic.spawnCruising(v, around: carPos, minDistance: lvl > 0 ? 200 : 220, maxDistance: lvl > 0 ? 340 : 420) {
                        units[v.id] = Unit()
                    }
                    break
                }
            } else if activeNow > target {
                // retire units that are far away and unseen
                for v in all where v.active {
                    let d: Float = simd_distance(v.pos, carPos)
                    if d > 300 && lvl == 0 {
                        traffic.deactivate(v)
                        units[v.id] = nil
                        break
                    }
                }
            }
        }

        // ---- choose responders: the closest active units
        var order: [(TrafficVehicle, Float)] = []
        for v in all where v.active { order.append((v, simd_distance(v.pos, carPos))) }
        order.sort { $0.1 < $1.1 }
        var respond: Set<Int> = []
        for (i, o) in order.enumerated() where i < wanted4 { respond.insert(o.0.id) }

        var busting: Bool = false
        let playerStopped: Bool = abs(st.speed) < 2.0 && ctx.state.mode == GameMode.driving
        for (v, d) in order {
            var u: Unit = units[v.id] ?? Unit()
            let isResponder: Bool = respond.contains(v.id) && lvl > 0
            var newMode: UnitMode = UnitMode.patrol
            if isResponder { newMode = lvl >= 2 ? UnitMode.pursue : UnitMode.investigate }
            if newMode != u.mode {
                u.mode = newMode
                u.replanTimer = 0
                u.holdTimer = 0
                configure(v, mode: newMode, level: lvl)
            }
            u.replanTimer -= dt

            switch u.mode {
            case .patrol:
                traffic.extendCruise(v)
            case .investigate:
                if d < 32 && playerStopped {
                    v.hold = true
                } else {
                    v.hold = false
                    if u.replanTimer <= 0 && traffic.canReplan(v) {
                        u.replanTimer = 2.5
                        let n: WGridNode = WGridNode.nearest(to: carPos)
                        if planToNode(v, n) { u.lastNode = n }
                    }
                }
            case .pursue:
                if d < 18 && playerStopped {
                    v.hold = true
                    u.holdTimer += dt
                    if u.holdTimer > 3.5 { busting = true }
                } else {
                    v.hold = false
                    u.holdTimer = 0
                    let n: WGridNode = WGridNode.nearest(to: carPos)
                    let changed: Bool = u.lastNode == nil || u.lastNode! != n
                    if traffic.canReplan(v) && (u.replanTimer <= 0 && (changed || v.remainingDistance < 70)) {
                        u.replanTimer = 1.1
                        if planToNode(v, n) { u.lastNode = n }
                    } else if v.remainingDistance < 25 && traffic.canReplan(v) {
                        traffic.extendCruise(v)
                    }
                }
            }
            units[v.id] = u
        }
        if busting {
            wanted.busted()
            for (v, _) in order {
                units[v.id]?.mode = UnitMode.patrol
                configure(v, mode: UnitMode.patrol, level: 0)
                v.hold = false
            }
        }

        // ---- siren sound (a six second wail, re-triggered while somebody is close)
        sirenTimer -= dt
        if sirenTimer <= 0 {
            var best: Float = Float.greatestFiniteMagnitude
            var bestPos: Vec2 = Vec2(0, 0)
            for v in all where v.active && v.sirenOn {
                let d: Float = simd_distance(v.pos, carPos)
                if d < best {
                    best = d
                    bestPos = v.pos
                }
            }
            if best < 260 {
                sirenTimer = 5.6
                let vol: Float = clampf(1.1 - best / 260, 0.15, 1)
                ctx.audio.play(SFX.policeSiren, volume: vol * 0.8, rate: 1, position: Vec3(bestPos.x, 1.5, bestPos.y))
            } else {
                sirenTimer = 1
            }
        }
        _ = stoppedTimer
    }

    private func configure(_ v: TrafficVehicle, mode: UnitMode, level: Int) {
        switch mode {
        case .patrol:
            v.speedLimit = 13.9
            v.aMax = 2.6
            v.brakeComfort = 3.4
            v.sirenOn = false
        case .investigate:
            v.speedLimit = 19
            v.aMax = 3.6
            v.brakeComfort = 4.0
            v.sirenOn = false
        case .pursue:
            v.speedLimit = min(32, 17 + 3.2 * Float(max(1, level)))
            v.aMax = 4.6
            v.brakeComfort = 5.5
            v.sirenOn = true
        }
    }

    private func planToNode(_ v: TrafficVehicle, _ n: WGridNode) -> Bool {
        return traffic.plan(v, toNode: n)
    }
}
