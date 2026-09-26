import Foundation
import simd

// MARK: - Shared NPC types: behaviour states, profiles, identity seeds, configuration and the snapshot structs that a future
// networking layer can serialise (nothing here touches the network).

enum NPCState: String, Codable {
    case idle, walking, running, waiting, lookingAround, talking, crossingStreet
    case waitingForTaxi, enteringTaxi, insideTaxi, leavingTaxi
    case goingToDestination, avoidingObstacle, reactingToPlayer, reactingToCollision
}

/// how far the simulation goes for a pedestrian, chosen from the distance to the player
enum NPCLevel: Int {
    case near = 0       // full AI, full animation, full collision
    case mid = 1        // reduced AI / animation rate, simplified collision
    case far = 2        // very light simulation, no animation
    case dormant = 3    // minimal: moves along its route, hidden
}

enum NPCProfile: Int, CaseIterable {
    case calm, normal, energetic, slowWalker, tourist, worker, business
}

struct NPCTraits {
    var walkSpeed: Float            // m/s, normal walking
    var fastSpeed: Float            // m/s, brisk walking
    var runSpeed: Float             // m/s
    var restless: Float             // 0...1  how often an idle pedestrian changes what it does
    var curious: Float              // 0...1  looking around / at shop windows
    var phoneChance: Float          // 0...1
    var talkChance: Float           // 0...1
    var armSwing: Float             // multiplier
    var hurry: Float                // 0...1  probability of a brisk walk / a run when going somewhere
    var dwell: Float                // multiplier for waiting times
}

extension NPCProfile {
    var traits: NPCTraits {
        switch self {
        case .calm:
            return NPCTraits(walkSpeed: 1.25, fastSpeed: 1.75, runSpeed: 2.7, restless: 0.3, curious: 0.5, phoneChance: 0.2, talkChance: 0.3,
                             armSwing: 0.85, hurry: 0.05, dwell: 1.3)
        case .normal:
            return NPCTraits(walkSpeed: 1.4, fastSpeed: 1.95, runSpeed: 3.2, restless: 0.5, curious: 0.5, phoneChance: 0.35, talkChance: 0.35,
                             armSwing: 1.0, hurry: 0.15, dwell: 1.0)
        case .energetic:
            return NPCTraits(walkSpeed: 1.6, fastSpeed: 2.2, runSpeed: 4.2, restless: 0.75, curious: 0.4, phoneChance: 0.25, talkChance: 0.35,
                             armSwing: 1.2, hurry: 0.4, dwell: 0.7)
        case .slowWalker:
            return NPCTraits(walkSpeed: 1.1, fastSpeed: 1.5, runSpeed: 2.5, restless: 0.35, curious: 0.6, phoneChance: 0.2, talkChance: 0.4,
                             armSwing: 0.7, hurry: 0.0, dwell: 1.6)
        case .tourist:
            return NPCTraits(walkSpeed: 1.2, fastSpeed: 1.7, runSpeed: 2.8, restless: 0.8, curious: 0.95, phoneChance: 0.6, talkChance: 0.3,
                             armSwing: 0.9, hurry: 0.03, dwell: 1.5)
        case .worker:
            return NPCTraits(walkSpeed: 1.5, fastSpeed: 2.1, runSpeed: 3.6, restless: 0.35, curious: 0.25, phoneChance: 0.3, talkChance: 0.25,
                             armSwing: 1.05, hurry: 0.25, dwell: 0.8)
        case .business:
            return NPCTraits(walkSpeed: 1.65, fastSpeed: 2.25, runSpeed: 3.9, restless: 0.3, curious: 0.15, phoneChance: 0.55, talkChance: 0.2,
                             armSwing: 0.8, hurry: 0.3, dwell: 0.6)
        }
    }
}

/// stable identity of a pedestrian: the same seeds always give the same person and the same decisions
struct NPCIdentity {
    let id: Int
    let personalitySeed: UInt64
    let appearanceSeed: UInt64
    let destinationSeed: UInt64
    let behaviorSeed: UInt64
    let profile: NPCProfile

    init(id: Int, worldSeed: UInt64) {
        self.id = id
        var s: UInt64 = worldSeed &+ UInt64(truncatingIfNeeded: id) &* 0x9E37_79B9_7F4A_7C15
        func mix(_ x: inout UInt64) -> UInt64 {
            x &+= 0x9E37_79B9_7F4A_7C15
            var z: UInt64 = x
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        personalitySeed = mix(&s)
        appearanceSeed = mix(&s)
        destinationSeed = mix(&s)
        behaviorSeed = mix(&s)
        let p: Int = Int(personalitySeed % UInt64(NPCProfile.allCases.count))
        profile = NPCProfile(rawValue: p) ?? NPCProfile.normal
    }
}

enum NPCDestinationKind: String {
    case roadside, shopFront, park, plaza, taxiStop, home, downtown, industrial
}

struct NPCDestination {
    var kind: NPCDestinationKind
    var position: Vec2
    var facing: Float?              // heading to face on arrival (nil = keep walking direction)
    var dwell: Float                // seconds to stay
}

// MARK: - Configuration (population budgets scale with the graphics preset; everything is configurable)

struct NPCConfig {
    var maximumActive: Int = 26
    var nearbyBudget: Int = 12          // full simulation
    var farBudget: Int = 14             // reduced / minimal simulation
    var nearDistance: Float = 28
    var midDistance: Float = 62
    var farDistance: Float = 118
    var despawnDistance: Float = 175
    var spawnMinDistance: Float = 48
    var spawnMaxDistance: Float = 150
    var brainRate: [Float] = [10, 4, 1, 0.5]          // AI decisions per second for each NPCLevel
    var moveRate: [Float] = [0, 15, 5, 2]             // integration steps per second (0 = every frame)
    var animationRate: [Float] = [0, 20, 8, 0]        // pose updates per second (0 = every frame); dormant pedestrians are hidden

    func level(forDistance d: Float) -> NPCLevel {
        if d < nearDistance { return NPCLevel.near }
        if d < midDistance { return NPCLevel.mid }
        if d < farDistance { return NPCLevel.far }
        return NPCLevel.dormant
    }

    static func forGraphics(_ g: GraphicsSettings) -> NPCConfig {
        var c = NPCConfig()
        switch g.preset {
        case .low:
            c.maximumActive = 12; c.nearbyBudget = 6; c.farBudget = 6; c.spawnMaxDistance = 110; c.despawnDistance = 130
            c.nearDistance = 22; c.midDistance = 46; c.farDistance = 80
        case .medium:
            c.maximumActive = 20; c.nearbyBudget = 9; c.farBudget = 11; c.spawnMaxDistance = 130; c.despawnDistance = 150
            c.nearDistance = 25; c.midDistance = 54; c.farDistance = 100
        case .high, .custom:
            break
        case .ultra:
            c.maximumActive = 34; c.nearbyBudget = 16; c.farBudget = 18
            c.nearDistance = 32; c.midDistance = 70; c.farDistance = 130; c.despawnDistance = 190
        }
        return c
    }
}

// MARK: - Snapshots (future multiplayer / persistence).  Plain Codable values, no references, no networking.

struct NPCStateSnapshot: Codable {
    var id: Int
    var archetype: String
    var x: Float
    var z: Float
    var heading: Float
    var speed: Float
    var state: String
}

struct PlayerStateSnapshot: Codable {
    var name: String
    var x: Float
    var z: Float
    var heading: Float
    var driving: Bool
}

struct VehicleStateSnapshot: Codable {
    var x: Float
    var z: Float
    var heading: Float
    var speed: Float
    var engine: String
    var paint: String
}

struct RaceStateSnapshot: Codable {
    var active: Bool
    var lap: Int
    var position: Int
    var raceTime: Double
}

struct WorldEvent: Codable {
    var kind: String
    var x: Float
    var z: Float
    var time: Double
    var magnitude: Float
}

struct WorldSnapshot: Codable {
    var timeOfDay: Float
    var wantedLevel: Int
    var player: PlayerStateSnapshot
    var vehicle: VehicleStateSnapshot
    var race: RaceStateSnapshot
    var npcs: [NPCStateSnapshot]
}
