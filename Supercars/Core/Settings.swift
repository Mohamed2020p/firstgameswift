import Foundation
import Combine

// MARK: - User settings (everything the iPhone player can change from the Settings screen).

enum GraphicsPreset: String, Codable, CaseIterable, Identifiable {
    case low, medium, high, ultra, custom
    var id: String { return rawValue }
    var title: String { return rawValue.capitalized }
}

enum ShadowQuality: Int, Codable, CaseIterable, Identifiable {
    case off = 0, low = 1, medium = 2, high = 3
    var id: Int { return rawValue }
    var title: String {
        switch self { case .off: return "Off"; case .low: return "Low"; case .medium: return "Medium"; case .high: return "High" }
    }
    /// shadow map edge in pixels for the sun
    var mapSize: Int { switch self { case .off: return 0; case .low: return 1024; case .medium: return 2048; case .high: return 4096 } }
}

enum AntialiasLevel: Int, Codable, CaseIterable, Identifiable {
    case none = 0, x2 = 2, x4 = 4
    var id: Int { return rawValue }
    var title: String { switch self { case .none: return "Off"; case .x2: return "2x MSAA"; case .x4: return "4x MSAA" } }
}

enum SteeringMode: String, Codable, CaseIterable, Identifiable {
    case tilt, touchWheel, touchButtons
    var id: String { return rawValue }
    var title: String {
        switch self { case .tilt: return "Tilt (motion)"; case .touchWheel: return "Touch wheel"; case .touchButtons: return "Left / Right buttons" }
    }
}

enum CameraView: String, Codable, CaseIterable, Identifiable {
    case chase, close, hood, cockpit, bumper
    var id: String { return rawValue }
    var title: String {
        switch self { case .chase: return "Chase"; case .close: return "Close chase"; case .hood: return "Hood"; case .cockpit: return "Cockpit"; case .bumper: return "Bumper" }
    }
}

enum SpeedUnit: String, Codable, CaseIterable, Identifiable {
    case kmh, mph
    var id: String { return rawValue }
    var title: String { return self == .kmh ? "km/h" : "mph" }
}

struct GraphicsSettings: Codable, Equatable {
    var preset: GraphicsPreset = .high
    var renderScale: Float = 1.0            // 0.5 ... 1.0  (multiplies the native pixel density)
    var shadows: ShadowQuality = .high
    var antialiasing: AntialiasLevel = .x4
    var fpsCap: Int = 60                    // 30 / 60 / 120
    var drawDistance: Float = 1.0           // 0.5 ... 1.5
    var treeDetail: Int = 2                 // 0 low / 1 medium / 2 high
    var propDensity: Float = 1.0            // 0.3 ... 1.2
    var reflections: Bool = true            // environment reflections on the car
    var bloom: Bool = true
    var motionBlur: Bool = false
    var hdr: Bool = true
    var particles: Bool = true
    var cameraShake: Bool = true

    static func preset(_ p: GraphicsPreset) -> GraphicsSettings {
        var g = GraphicsSettings()
        g.preset = p
        switch p {
        case .low:
            g.renderScale = 0.6; g.shadows = .off; g.antialiasing = .none; g.fpsCap = 30; g.drawDistance = 0.6; g.treeDetail = 0
            g.propDensity = 0.4; g.reflections = false; g.bloom = false; g.motionBlur = false; g.hdr = false; g.particles = false
        case .medium:
            g.renderScale = 0.8; g.shadows = .low; g.antialiasing = .none; g.fpsCap = 30; g.drawDistance = 0.8; g.treeDetail = 1
            g.propDensity = 0.7; g.reflections = true; g.bloom = false; g.motionBlur = false; g.hdr = true; g.particles = true
        case .high, .custom:
            break
        case .ultra:
            g.renderScale = 1.0; g.shadows = .high; g.antialiasing = .x4; g.fpsCap = 120; g.drawDistance = 1.4; g.treeDetail = 2
            g.propDensity = 1.2; g.reflections = true; g.bloom = true; g.motionBlur = true; g.hdr = true; g.particles = true
        }
        return g
    }
}

struct ControlSettings: Codable, Equatable {
    var steering: SteeringMode = .tilt
    var tiltSensitivity: Float = 1.0        // 0.3 ... 2.5
    var tiltDeadzone: Float = 0.04          // 0 ... 0.2  (fraction of full lock)
    var tiltRangeDegrees: Float = 35        // 15 ... 60  phone roll for full lock
    var tiltSmoothing: Float = 0.35         // 0 ... 1
    var touchSteerSensitivity: Float = 1.0  // 0.4 ... 2.0
    var cameraSensitivity: Float = 1.0      // 0.3 ... 2.5
    var invertLookY: Bool = false
    var haptics: Bool = true
    var hudScale: Float = 1.0               // 0.7 ... 1.4
    var leftHanded: Bool = false
    var autoThrottle: Bool = false
    var controlOpacity: Float = 0.75        // on-screen controls
}

struct AudioSettings: Codable, Equatable {
    var master: Float = 0.9
    var music: Float = 0.5
    var sfx: Float = 1.0
    var engine: Float = 1.0
    var ambience: Float = 0.8
}

struct GameplaySettings: Codable, Equatable {
    var units: SpeedUnit = .kmh
    var tractionControl: Bool = true
    var abs: Bool = true
    var stability: Float = 0.5              // 0 off ... 1 strong
    var defaultView: CameraView = .chase
    var showMinimap: Bool = true
    var damage: Bool = true                 // crashes hurt / slow the car
    var fovScale: Float = 1.0               // 0.8 ... 1.2
    var opponentSkill: Float = 0.85         // 0.6 ... 1.0
    var dayLengthMinutes: Float = 24        // real minutes per in-game day
}

struct GameSettings: Codable, Equatable {
    var graphics = GraphicsSettings()
    var controls = ControlSettings()
    var audio = AudioSettings()
    var gameplay = GameplaySettings()
}

/// Observable store. Views bind to `settings`; modules read `store.settings` every frame or listen to `changed`.
final class SettingsStore: ObservableObject {
    @Published var settings: GameSettings {
        didSet {
            if settings != oldValue { changed.send(settings); scheduleSave() }
        }
    }
    let changed = PassthroughSubject<GameSettings, Never>()
    private var saveWork: DispatchWorkItem?
    private let url: URL

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url = dir.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(GameSettings.self, from: data) {
            settings = s
        } else {
            settings = GameSettings()
        }
    }

    func applyPreset(_ p: GraphicsPreset) {
        if p == .custom { settings.graphics.preset = .custom; return }
        let keepPreset = GraphicsSettings.preset(p)
        settings.graphics = keepPreset
    }

    /// call after any manual change to a graphics field so the preset label becomes "Custom"
    func markCustom() {
        if settings.graphics.preset != .custom { settings.graphics.preset = .custom }
    }

    func resetToDefaults() { settings = GameSettings() }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    func saveNow() {
        if let data = try? JSONEncoder().encode(settings) { try? data.write(to: url, options: .atomic) }
    }
}
