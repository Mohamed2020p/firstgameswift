import Foundation
import simd

// MARK: - NPCInteraction: how pedestrians notice the player.  A fast car passing close makes people look (or step aside), a crash
// makes nearby people stop and stare (some run), and a car that actually touches somebody bumps them.  Reactions are subtle and
// rate limited so the street never turns into chaos.

struct MovingBody {
    var pos: Vec2
    var vel: Vec2
    var radius: Float
    var isPlayer: Bool = false
}

@MainActor
final class NPCInteraction {
    /// called once when the player's car bumps a pedestrian (severity 0...1)
    var onPedestrianHit: ((NPCCharacter, Float) -> Void)? = nil
    private var timer: Float = 0

    func update(dt: Float, npcs: [NPCCharacter], car: MovingBody?, carHeading: Float, env: NPCEnvironment) {
        timer += dt
        for n in npcs { n.reactCooldown = max(0, n.reactCooldown - dt) }
        if timer < 0.15 { return }
        timer = 0
        guard let c = car else { return }
        let speed: Float = simd_length(c.vel)
        if speed < 1.2 { return }
        let vhat: Vec2 = c.vel / speed
        let fwd: Vec2 = headingForward2(carHeading)
        let lft: Vec2 = headingLeft2(carHeading)
        for n in npcs where n.level.rawValue <= NPCLevel.mid.rawValue {
            switch n.state {
            case .enteringTaxi, .insideTaxi, .leavingTaxi:
                continue
            default:
                break
            }
            let rel: Vec2 = n.pos - c.pos
            let dist: Float = simd_length(rel)
            if dist > 26 { continue }

            // ---- contact: the car body is an oriented box
            if speed > 1.5 {
                let lx: Float = simd_dot(rel, lft)
                let lz: Float = simd_dot(rel, fwd)
                if abs(lx) < 1.25 && lz > -2.6 && lz < 2.7 && n.state != NPCState.reactingToCollision {
                    let side: Float = lx >= 0 ? 1 : -1
                    let push: Vec2 = vhat * min(6, speed * 0.45) + lft * (side * 1.6)
                    n.brain.reactToHit(n, impulse: push)
                    n.reactCooldown = 4
                    onPedestrianHit?(n, clampf(speed / 25, 0.1, 1))
                    continue
                }
            }
            if n.reactCooldown > 0 { continue }

            // ---- will the car pass close to this pedestrian in the next couple of seconds?
            let along: Float = simd_dot(rel, vhat)
            if along < -3 { continue }
            let lateral: Float = abs(simd_dot(rel, vhat.leftPerp))
            var danger: Float = 0
            if speed > 7 && along > 0 && along < speed * 2.2 && lateral < 2.8 && dist < 20 {
                danger = clampf(0.55 + speed / 60 + (20 - dist) / 60, 0.55, 1)
            } else if speed > 9 && dist < 20 && lateral < 9 {
                danger = 0.3
            }
            if danger > 0 {
                n.brain.reactToCar(n, carPos: c.pos, carVel: c.vel, danger: danger, env: env)
                n.reactCooldown = danger > 0.5 ? 5 : 8
            }
        }
    }

    /// a crash (or any loud event) at `p`
    func crash(at p: Vec2, magnitude: Float, npcs: [NPCCharacter], env: NPCEnvironment) {
        let radius: Float = 22 + 30 * clampf(magnitude, 0, 1)
        for n in npcs {
            let d: Float = simd_distance(n.pos, p)
            if d > radius { continue }
            if n.reactCooldown > 2 { continue }
            n.brain.reactToCrash(n, at: p, env: env)
            n.reactCooldown = 6
        }
    }
}
