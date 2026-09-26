import Foundation
import simd

// MARK: - WantedSystem: a simple offline "heat" model with 0...5 stars.  Reckless events add heat; heat decays while the player is out of
// the police's sight; the star level (derived from heat) tells PoliceSystem how hard to respond.  Everything is local and deterministic.

@MainActor
final class WantedSystem {
    private unowned let ctx: GameContext
    private(set) var heat: Float = 0
    private(set) var level: Int = 0
    /// developer: keep the level fixed (no decay, no escalation)
    var frozen: Bool = false
    private var speedingTimer: Float = 0
    private var offroadTimer: Float = 0
    private var escapeTimer: Float = 0
    private var lastToast: Int = 0

    /// heat needed for 1 ... 5 stars
    static let thresholds: [Float] = [10, 30, 50, 70, 88]

    init(ctx: GameContext) {
        self.ctx = ctx
    }

    static func level(forHeat h: Float) -> Int {
        var l: Int = 0
        for (i, t) in thresholds.enumerated() where h >= t { l = i + 1 }
        return l
    }

    // MARK: events

    func add(heat amount: Float) {
        if frozen { return }
        setHeat(min(100, heat + amount))
    }

    /// a hard collision (with a building, a wall, a parked or moving thing that is not a person)
    func reportCrash(speed: Float, destructible: Bool) {
        if destructible { return }
        if speed > 12 { add(heat: 16) } else if speed > 7 { add(heat: 6) }
    }

    func reportPedestrianHit(severity: Float) {
        add(heat: 22 + 28 * severity)
    }

    func reportVehicleCollision(with kind: TrafficKind, speed: Float) {
        switch kind {
        case .police:
            add(heat: 34)
        case .taxi:
            add(heat: speed > 8 ? 14 : 5)
        }
    }

    // MARK: control

    func set(level l: Int) {
        let lv: Int = max(0, min(5, l))
        if lv == 0 {
            setHeat(0)
        } else {
            let lo: Float = WantedSystem.thresholds[lv - 1]
            let hi: Float = lv < 5 ? WantedSystem.thresholds[lv] : 100
            heat = (lo + hi) * 0.5
            publish(previous: level)
        }
    }

    func clear() {
        setHeat(0)
    }

    /// arrested: fine and reset
    func busted() {
        setHeat(0)
        ctx.toast("Busted. The police let you go with a warning.")
    }

    private func setHeat(_ h: Float) {
        let prev: Int = level
        heat = max(0, h)
        publish(previous: prev)
    }

    private func publish(previous: Int) {
        level = WantedSystem.level(forHeat: heat)
        if ctx.state.wanted != level { ctx.state.wanted = level }
        if level != previous {
            if level == 0 && previous > 0 {
                ctx.toast("Wanted level cleared")
            } else if level > previous {
                ctx.toast("Wanted level \(level)")
            }
        }
    }

    // MARK: per frame

    func update(dt: Float, police: PoliceSystem?) {
        guard let car = ctx.car else { return }
        let driving: Bool = ctx.state.mode == GameMode.driving
        let st = car.state
        let carPos: Vec2 = Vec2(st.position.x, st.position.z)
        var nearest: Float = Float.greatestFiniteMagnitude
        var sirenNearby: Bool = false
        if let pol = police {
            nearest = pol.nearestUnitDistance(to: carPos)
            sirenNearby = pol.hasSirenWithin(60, of: carPos)
        }

        if driving && !frozen {
            // dangerous driving is only noticed when a police car is around
            let speed: Float = abs(st.speed)
            if speed > 36 && nearest < 110 { speedingTimer += dt } else { speedingTimer = max(0, speedingTimer - dt) }
            if speedingTimer > 3 {
                speedingTimer = 0
                add(heat: 9)
            }
            let s: SurfaceType = ctx.world.surface(at: carPos)
            let offroad: Bool = s == SurfaceType.sidewalk || s == SurfaceType.grass || s == SurfaceType.dirt
            if offroad && speed > 11 && nearest < 80 { offroadTimer += dt } else { offroadTimer = max(0, offroadTimer - dt) }
            if offroadTimer > 2.5 {
                offroadTimer = 0
                add(heat: 7)
            }
        }

        // ---- cooling: out of sight for a while, then further away = faster
        if level > 0 && !frozen {
            if nearest > 70 && !sirenNearby {
                escapeTimer += dt
                if escapeTimer > 6 {
                    var rate: Float = 2.2
                    if nearest > 220 { rate = 6 }
                    setHeat(heat - rate * dt)
                }
            } else {
                escapeTimer = 0
            }
        } else if heat > 0 && level == 0 && !frozen {
            setHeat(heat - 3 * dt)
        }
    }
}
