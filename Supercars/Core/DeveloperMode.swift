import Foundation
import SwiftUI
import simd

// MARK: - DeveloperMode: local, offline test tools (wanted level, teleports, repair, time / weather, spawning, toggles).
// Hidden from the normal UI: it is always on in DEBUG builds; in release builds seven quick taps on the wordmark (main menu) or on the
// version line (Settings > Credits) unlock it, and the pause menu then shows a "Developer tools" entry.  Nothing here touches the network.

@MainActor
final class DeveloperMode: ObservableObject {
    private unowned let ctx: GameContext
    @Published private(set) var isUnlocked: Bool = false
    @Published var npcsEnabled: Bool = true
    @Published var trafficEnabled: Bool = true
    @Published var policeEnabled: Bool = true
    @Published var weather: WeatherKind = WeatherKind.clear
    @Published var freezeWanted: Bool = false
    private static let defaultsKey = "c0derz.developer.unlocked"

    init(ctx: GameContext) {
        self.ctx = ctx
        #if DEBUG
        isUnlocked = true
        #else
        isUnlocked = UserDefaults.standard.bool(forKey: DeveloperMode.defaultsKey)
        #endif
    }

    func toggleUnlocked() {
        isUnlocked.toggle()
        UserDefaults.standard.set(isUnlocked, forKey: DeveloperMode.defaultsKey)
        ctx.toast(isUnlocked ? "Developer tools unlocked (pause menu)" : "Developer tools hidden")
    }

    // MARK: wanted / police

    func setWanted(_ level: Int) {
        ctx.wanted?.frozen = false
        ctx.wanted?.set(level: level)
        ctx.wanted?.frozen = freezeWanted
    }

    func clearPolice() {
        ctx.wanted?.frozen = false
        ctx.wanted?.clear()
        freezeWanted = false
        if let t = ctx.traffic {
            for v in t.police where v.active { v.sirenOn = false }
        }
    }

    func setFreeze(_ on: Bool) {
        freezeWanted = on
        ctx.wanted?.frozen = on
    }

    func spawnTaxi() {
        guard let c = ctx.car, let t = ctx.traffic else { return }
        let ok: Bool = t.spawnNear(TrafficKind.taxi, at: Vec2(c.state.position.x, c.state.position.z), heading: c.state.heading)
        ctx.toast(ok ? "Taxi spawned nearby" : "No free taxi")
    }

    func spawnPolice() {
        guard let c = ctx.car, let t = ctx.traffic else { return }
        let ok: Bool = t.spawnNear(TrafficKind.police, at: Vec2(c.state.position.x, c.state.position.z), heading: c.state.heading)
        ctx.toast(ok ? "Police unit spawned nearby" : "No free police unit")
    }

    // MARK: teleports

    private func teleport(to p: Vec2, heading: Float) {
        guard let car = ctx.car, let player = ctx.player else { return }
        if ctx.state.mode == GameMode.garage || ctx.state.mode == GameMode.menu || ctx.state.mode == GameMode.sleeping { return }
        if player.location != PlayerLocation.outside { ctx.exitHouse() }
        let pos: Vec3 = Vec3(p.x, 0, p.y)
        car.place(position: pos, heading: heading)
        if ctx.state.mode == GameMode.onFoot {
            let side: Vec3 = headingLeft(heading) * 3.6
            player.place(position: pos + side, heading: heading, location: PlayerLocation.outside)
        }
        ctx.state.location = PlayerLocation.outside
        ctx.audio.setAmbience(AmbienceTrack.cityDay)
    }

    func teleportToRace() {
        let g: Spawn = ctx.world.spawn.raceGate
        let back: Vec3 = headingForward(g.heading) * -26
        teleport(to: Vec2(g.position.x + back.x, g.position.z + back.z), heading: g.heading)
        ctx.toast("Race start")
    }

    func teleportHome() {
        let s: Spawn = ctx.world.spawn.car
        teleport(to: Vec2(s.position.x, s.position.z), heading: s.heading)
        ctx.toast("Home")
    }

    func teleportGarage() {
        let s: Spawn = ctx.world.spawn.garageDoor
        let f: Vec3 = headingForward(s.heading) * 6
        teleport(to: Vec2(s.position.x + f.x, s.position.z + f.z), heading: s.heading)
        ctx.toast("Garage")
    }

    func teleportDowntown() {
        let n = WGridNode(i: 0, j: 0)
        let p: Vec2 = TrafficRouter.lanePoint(n, heading: Vec2(1, 0)) - Vec2(30, 0)
        teleport(to: p, heading: Float.pi * 0.5)
        ctx.toast("Downtown")
    }

    func teleportPolice() {
        guard let w = ctx.nav?.registry.waypoint(id: "police") else { return }
        let a: Vec2 = w.routeTarget ?? w.position
        teleport(to: a, heading: 0)
        ctx.toast("Police station")
    }

    // MARK: car / economy

    func repairCar() {
        ctx.car?.repair()
        ctx.toast("Car repaired")
    }

    func resetCar() {
        guard let car = ctx.car else { return }
        let p: Vec3 = car.state.position
        if let r = ctx.world.nearestRoadPoint(to: Vec2(p.x, p.z)) {
            car.place(position: Vec3(r.point.x, 0, r.point.y), heading: r.heading)
        }
        car.repair()
        ctx.toast("Car reset to the street")
    }

    func setMoney(_ amount: Int) {
        ctx.save.data.money = amount
        ctx.toast("Money set to $\(amount)")
    }

    func unlockVehicles() {
        ctx.save.data.ownedEngines = EngineType.allCases
        ctx.save.data.ownedTyres = TyreCompound.allCases
        ctx.toast("All engines and tyres unlocked")
    }

    // MARK: world toggles

    func setNPCs(_ on: Bool) {
        npcsEnabled = on
        ctx.npcs?.enabled = on
    }

    func setTraffic(_ on: Bool) {
        trafficEnabled = on
        ctx.traffic?.setEnabled(taxis: on, police: policeEnabled)
    }

    func setPolice(_ on: Bool) {
        policeEnabled = on
        ctx.traffic?.setEnabled(taxis: trafficEnabled, police: on)
        if !on { ctx.wanted?.clear() }
    }

    func setTime(_ hour: Float) {
        ctx.world.timeOfDay = hour
        ctx.toast(String(format: "Time %02d:00", Int(hour)))
    }

    func setWeather(_ w: WeatherKind) {
        weather = w
        ctx.world.setWeather(w)
    }

    // MARK: info

    var statusLine: String {
        let n: Int = ctx.npcs?.activeCount ?? 0
        let t: Int = ctx.traffic?.taxis.filter { $0.active }.count ?? 0
        let p: Int = ctx.traffic?.police.filter { $0.active }.count ?? 0
        return "pedestrians \(n)  ·  taxis \(t)  ·  police \(p)  ·  wanted \(ctx.state.wanted)"
    }
}
