import Foundation
import UIKit

// MARK: - Engines (garage swaps these; vehicle physics, audio and UI all read the same table)

enum EngineType: String, Codable, CaseIterable, Identifiable {
    case v6, v8, v10, v12, v16
    var id: String { return rawValue }
}

struct EngineSpec {
    let type: EngineType
    let name: String
    let cylinders: Int
    let displacementL: Float
    let powerKW: Float        // peak power
    let torqueNm: Float       // peak torque
    let redline: Float        // rpm
    let idle: Float           // rpm
    let massKg: Float         // total car mass with this engine
    let price: Int            // garage price (in-game money)
    let blurb: String

    static let all: [EngineType: EngineSpec] = [
        .v6:  EngineSpec(type: .v6,  name: "3.4L Twin-Turbo V6",   cylinders: 6,  displacementL: 3.4, powerKW: 330, torqueNm: 480, redline: 8200, idle: 1000, massKg: 1240, price: 0,      blurb: "Light and sharp. Great turn-in."),
        .v8:  EngineSpec(type: .v8,  name: "4.0L Flat-Plane V8",   cylinders: 8,  displacementL: 4.0, powerKW: 405, torqueNm: 560, redline: 8800, idle: 1100, massKg: 1300, price: 0,      blurb: "The all-rounder. Crisp and loud."),
        .v10: EngineSpec(type: .v10, name: "5.2L Screaming V10",   cylinders: 10, displacementL: 5.2, powerKW: 490, torqueNm: 620, redline: 9200, idle: 1150, massKg: 1350, price: 38000,  blurb: "High-revving wail. Serious pace."),
        .v12: EngineSpec(type: .v12, name: "6.5L Naturally-Aspirated V12", cylinders: 12, displacementL: 6.5, powerKW: 585, torqueNm: 700, redline: 9000, idle: 1200, massKg: 1420, price: 95000, blurb: "Silky, huge and relentless."),
        .v16: EngineSpec(type: .v16, name: "8.0L Quad-Turbo V16",  cylinders: 16, displacementL: 8.0, powerKW: 850, torqueNm: 1050, redline: 8600, idle: 1250, massKg: 1520, price: 240000, blurb: "Absurd. Hold on tight."),
    ]
    static func spec(_ t: EngineType) -> EngineSpec { return all[t]! }
}

enum PaintFinish: String, Codable, CaseIterable, Identifiable {
    case gloss, metallic, matte, satin, chrome, pearl
    var id: String { return rawValue }
    var title: String { return rawValue.capitalized }
    /// PBR values used by the vehicle module when re-colouring the body: (metalness, roughness, clearcoat-like extra)
    var pbr: (metalness: Float, roughness: Float) {
        switch self {
        case .gloss: return (0.05, 0.10)
        case .metallic: return (0.65, 0.22)
        case .matte: return (0.05, 0.85)
        case .satin: return (0.15, 0.45)
        case .chrome: return (1.0, 0.04)
        case .pearl: return (0.35, 0.16)
        }
    }
}

enum TyreCompound: String, Codable, CaseIterable, Identifiable {
    case road, sport, slick
    var id: String { return rawValue }
    var title: String { return rawValue.capitalized }
    var grip: Float { switch self { case .road: return 1.25; case .sport: return 1.5; case .slick: return 1.7 } }
    var price: Int { switch self { case .road: return 0; case .sport: return 3500; case .slick: return 9000 } }
}

/// Persistent customisation of the player's car (garage).
struct CarConfig: Codable, Equatable {
    var engine: EngineType = .v8
    var paint: String = "#e8e8ec"       // hex
    var finish: PaintFinish = .metallic
    var livery: Bool = true             // the black/gold Manthey race livery (texture) instead of a solid paint colour
    var rims: String = "#151515"
    var caliper: String = "#d40000"
    var tint: Float = 0.75              // 0 clear ... 1 dark windows
    var wing: Int = 1                   // 0 none / 1 GT3 wing / 2 big wing (more downforce, more drag)
    var tyres: TyreCompound = .sport
}
