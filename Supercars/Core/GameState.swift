import Foundation
import Combine
import SwiftUI

// MARK: - Shared enums

enum GameMode: String {
    case loading, menu, onFoot, driving, garage, sleeping
}

enum PlayerLocation: String {
    case outside, house, garageBuilding
}

enum MenuScreen: String {
    case none, main, pause, settings, credits, garage, raceSetup, results
}

// MARK: - HUD / menu state.  Game modules WRITE to this (main thread only); SwiftUI views READ it.

struct RaceResultRow: Identifiable, Equatable {
    let id: Int
    var position: Int
    var name: String
    var totalTime: Double
    var bestLap: Double
    var isPlayer: Bool
}

struct RaceHUD: Equatable {
    var position: Int = 1
    var total: Int = 6
    var lap: Int = 1
    var laps: Int = 3
    var raceTime: Double = 0
    var lapTime: Double = 0
    var lastLap: Double? = nil
    var bestLap: Double? = nil
    var countdown: Int? = nil          // 3,2,1 then 0 = "GO"
    var finished: Bool = false
    var wrongWay: Bool = false
    var results: [RaceResultRow] = []
    var prize: Int = 0
}

struct MinimapData {
    var boundsMin: Vec2 = Vec2(-1000, -1000)
    var boundsMax: Vec2 = Vec2(1000, 1000)
    var roads: [[Vec2]] = []           // polylines of road centre lines (world XZ)
    var route: [Vec2] = []             // race route polyline
}

struct ToastMessage: Equatable, Identifiable {
    let id = UUID()
    var text: String
    var seconds: Double
}

final class GameState: ObservableObject {
    // flow
    @Published var mode: GameMode = .loading
    @Published var location: PlayerLocation = .outside
    @Published var screen: MenuScreen = .none
    @Published var loadingProgress: Float = 0
    @Published var loadingText: String = "Starting engine…"
    @Published var isPaused: Bool = false

    // driving HUD
    @Published var speed: Float = 0                 // m/s (HUD converts to km/h / mph using settings)
    @Published var rpm: Float = 0
    @Published var redline: Float = 8500
    @Published var gear: Int = 1                    // -1 = reverse, 0 = neutral
    @Published var throttle: Float = 0
    @Published var brake: Float = 0
    @Published var steer: Float = 0                 // -1 ... 1  (+ = left)
    @Published var engineName: String = ""
    @Published var view: CameraView = .chase
    @Published var abs: Bool = false
    @Published var tractionControlActive: Bool = false
    @Published var damage: Float = 0                // 0 ... 1
    @Published var headlights: Bool = false

    // world / player
    @Published var prompt: String? = nil            // "Enter house", "Sleep" …
    @Published var toast: ToastMessage? = nil
    @Published var timeOfDay: Float = 9
    @Published var day: Int = 1
    @Published var money: Int = 0
    @Published var fps: Int = 60
    @Published var locationName: String = ""

    // race
    @Published var race: RaceHUD? = nil

    // minimap
    @Published var minimap = MinimapData()
    @Published var playerMapPosition: Vec2 = .zero
    @Published var playerMapHeading: Float = 0
    @Published var opponentMapPositions: [Vec2] = []

    // sleep / fade overlay (0 clear ... 1 black)
    @Published var fade: Float = 0
    @Published var fadeText: String? = nil

    private var toastWork: DispatchWorkItem?

    func showToast(_ text: String, seconds: Double = 2.2) {
        toast = ToastMessage(text: text, seconds: seconds)
        toastWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    /// 24h clock string for the HUD
    var clockString: String {
        let h = Int(timeOfDay) % 24
        let m = Int((timeOfDay - floorf(timeOfDay)) * 60)
        return String(format: "%02d:%02d", h, m)
    }
}
