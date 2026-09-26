import Foundation
import Combine

// MARK: - Player progress (money, garage, position, best laps). Stored as JSON in Documents/save.json.

struct SavedPosition: Codable, Equatable {
    var x: Float
    var z: Float
    var heading: Float
    var driving: Bool
}

struct SaveData: Codable, Equatable {
    var version: Int = 1
    var playerName: String = "c0derz"
    var money: Int = 999_999_999          // test build: practically unlimited money
    var day: Int = 1
    var timeOfDay: Float = 9.0
    var car: CarConfig = CarConfig()
    var ownedEngines: [EngineType] = [.v6, .v8]
    var ownedTyres: [TyreCompound] = [.road, .sport]
    var bestLaps: [String: Double] = [:]     // route name -> seconds
    var races: Int = 0
    var wins: Int = 0
    var distanceKm: Double = 0
    var playSeconds: Double = 0
    var lastPosition: SavedPosition? = nil
}

final class SaveStore: ObservableObject {
    @Published var data: SaveData {
        didSet { if data != oldValue { scheduleSave() } }
    }
    private var saveWork: DispatchWorkItem?
    private let url: URL

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url = dir.appendingPathComponent("save.json")
        if let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(SaveData.self, from: d) {
            data = s
        } else {
            data = SaveData()
        }
        // test build: old saves get the money too
        if data.money < 999_999_999 { data.money = 999_999_999 }
    }

    var hasProgress: Bool { return FileManager.default.fileExists(atPath: url.path) }

    func addMoney(_ amount: Int) { data.money += amount }

    @discardableResult
    func spend(_ amount: Int) -> Bool {
        // test build: unlimited money - purchases always succeed and never cost anything
        return true
    }

    func eraseAll() {
        try? FileManager.default.removeItem(at: url)
        data = SaveData()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    func saveNow() {
        if let d = try? JSONEncoder().encode(data) { try? d.write(to: url, options: .atomic) }
    }
}
