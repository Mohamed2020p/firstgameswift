import Foundation
import simd

// MARK: - NPCSpawner: picks where a new pedestrian appears.  Positions are sidewalks around the player, outside the camera's view,
// accepted with a probability that follows the district (downtown busy, industrial quiet) and the hour.

@MainActor
final class NPCSpawner {
    private let layout: WCityLayout
    private let navigator: PedNavigator

    init(layout: WCityLayout, navigator: PedNavigator) {
        self.layout = layout
        self.navigator = navigator
    }

    func candidate(focus: Vec2, cameraForward: Vec2, config: NPCConfig, hour: Float, existing: [NPCCharacter], rng: inout SeededRNG)
        -> (position: Vec2, heading: Float)? {
        for _ in 0..<6 {
            let a: Float = rng.float(0, Float.tau)
            let dir: Vec2 = Vec2(cosf(a), sinf(a))
            let r: Float = config.spawnMinDistance + (config.spawnMaxDistance - config.spawnMinDistance) * sqrtf(rng.float())
            // never pop in right in front of the camera
            if r < 95 && simd_dot(dir, cameraForward) > 0.3 { continue }
            let q: Vec2 = focus + dir * r
            guard let sp = navigator.sidewalkPoint(near: q, rng: &rng) else { continue }
            if !WGrid.hasGridStreets(at: sp.position) { continue }
            let kind: WBlockKind = WGrid.blockKind(layout, at: sp.position)
            let accept: Float = NPCSchedule.density(kind: kind, hour: hour)
            if rng.float() > accept { continue }
            var clear: Bool = true
            for n in existing where n.isActive && simd_distance(n.pos, sp.position) < 2.2 {
                clear = false
                break
            }
            if !clear { continue }
            return sp
        }
        return nil
    }
}
