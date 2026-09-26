import Foundation
import simd

// MARK: - Waypoints: every place the player may want to find (house, garage, race start / finish, police station, taxi stands, districts).
// The registry is filled by the world builder (real, physical locations) and can be extended at any time (`register`).

enum WaypointKind: String {
    case home, garage, raceStart, raceFinish, policeStation, taxiStand
    case downtown, residential, luxuryResidential, industrial, park, plaza, custom

    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .garage: return "wrench.and.screwdriver.fill"
        case .raceStart: return "flag.checkered"
        case .raceFinish: return "flag.checkered.2.crossed"
        case .policeStation: return "shield.fill"
        case .taxiStand: return "car.fill"
        case .downtown: return "building.2.fill"
        case .residential: return "house.and.flag.fill"
        case .luxuryResidential: return "star.fill"
        case .industrial: return "gearshape.2.fill"
        case .park: return "leaf.fill"
        case .plaza: return "circle.hexagongrid.fill"
        case .custom: return "mappin"
        }
    }

    /// short label used on the minimap and as a fallback when SF Symbols are unavailable
    var letter: String {
        switch self {
        case .home: return "H"
        case .garage: return "G"
        case .raceStart: return "R"
        case .raceFinish: return "F"
        case .policeStation: return "P"
        case .taxiStand: return "T"
        case .downtown: return "D"
        case .residential: return "r"
        case .luxuryResidential: return "L"
        case .industrial: return "I"
        case .park: return "p"
        case .plaza: return "•"
        case .custom: return "×"
        }
    }

    /// waypoints of these kinds are drawn on the minimap; district labels are only on the big map
    var isPointOfInterest: Bool {
        switch self {
        case .home, .garage, .raceStart, .raceFinish, .policeStation, .taxiStand: return true
        default: return false
        }
    }
}

struct MapWaypoint: Identifiable, Equatable {
    let id: String
    var name: String
    var subtitle: String
    var kind: WaypointKind
    var position: Vec2
    /// where a vehicle should be steered to when routing (nil = the position itself)
    var routeTarget: Vec2? = nil

    static func == (a: MapWaypoint, b: MapWaypoint) -> Bool { return a.id == b.id && a.position == b.position }
}

@MainActor
final class WaypointRegistry {
    private(set) var all: [MapWaypoint] = []

    func register(_ w: MapWaypoint) {
        if let i = all.firstIndex(where: { $0.id == w.id }) {
            all[i] = w
        } else {
            all.append(w)
        }
    }

    func remove(id: String) {
        all.removeAll(where: { $0.id == id })
    }

    func waypoint(id: String) -> MapWaypoint? {
        return all.first(where: { $0.id == id })
    }

    func nearest(to p: Vec2, maxDistance: Float, pointsOfInterestOnly: Bool = true) -> MapWaypoint? {
        var best: MapWaypoint? = nil
        var bd: Float = maxDistance
        for w in all {
            if pointsOfInterestOnly && !w.kind.isPointOfInterest { continue }
            let d: Float = simd_distance(w.position, p)
            if d < bd {
                bd = d
                best = w
            }
        }
        return best
    }

    var pointsOfInterest: [MapWaypoint] {
        return all.filter { $0.kind.isPointOfInterest }
    }
}
