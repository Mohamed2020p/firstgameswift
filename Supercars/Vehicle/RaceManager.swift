import Foundation
import SceneKit
import simd
import UIKit

// MARK: - One AI opponent (visual + kinematic driver)

@MainActor
final class RaceOpponent {
    let name: String
    let hex: String
    let node: SCNNode
    let rig: CarVisualRig
    let customizer: CarCustomizer
    var driver: AIDriver? = nil
    var groundY: Float = 0
    var lapsDone: Int = 0
    var lapStart: Double = 0
    var bestLap: Double? = nil

    init(name: String, hex: String, node: SCNNode, rig: CarVisualRig, customizer: CarCustomizer) {
        self.name = name
        self.hex = hex
        self.node = node
        self.rig = rig
        self.customizer = customizer
    }
}

// MARK: - Race flow: grid, countdown, laps, positions, results, prize money

@MainActor
final class RaceManager {
    private unowned let ctx: GameContext

    private enum Phase {
        case idle, countdown, racing, finished
    }

    private var phase: Phase = .idle
    private var opponents: [RaceOpponent] = []
    private var path: RoutePath? = nil
    private var route: RaceRoute? = nil
    private var laps: Int = 3
    private var totalDistance: Float = 0
    private var hud: RaceHUD = RaceHUD()

    private var countdownClock: Float = 0
    private var lastCountShown: Int = 99
    private var goShown: Float = 0
    private var raceClock: Double = 0
    private var lapStartClock: Double = 0
    private var lapTimes: [Double] = []
    private var currentLapIndex: Int = -1

    private var playerProgress: Float = 0
    private var playerS: Float = 0
    private var playerLateral: Float = 0
    private var playerHint: Int? = nil
    private var playerFinishTime: Double? = nil
    private var wrongWayTimer: Float = 0
    private var hudTimer: Float = 0
    private var contactCooldown: Float = 0
    private var resultsShown: Bool = false
    private var night: Bool = false

    private let playerSlot: Int = 3
    private static let names: [String] = ["Vega", "Kaito", "Nyx", "Rook", "Zephyr"]
    private static let colors: [String] = ["#c8102e", "#1f5fff", "#ff7a00", "#f2c200", "#0fa958"]

    init(ctx: GameContext) {
        self.ctx = ctx
    }

    var isActive: Bool { return phase != .idle }

    // MARK: Build

    func build() async {
        for i in 0..<5 {
            let hex: String = RaceManager.colors[i % RaceManager.colors.count]
            var model: SCNNode
            do {
                model = try ctx.assets.model("car_ai")
            } catch {
                do {
                    model = try ctx.assets.model("car_player")
                } catch {
                    model = VehicleModelFactory.placeholderCar(color: UIColor(hexString: hex))
                }
            }
            let wrapper: SCNNode = SCNNode()
            wrapper.name = "aiCar\(i)"
            wrapper.addChildNode(model)
            wrapper.isHidden = true
            ctx.scene.rootNode.addChildNode(wrapper)
            let rig: CarVisualRig = CarVisualRig(root: model, wingNames: [])
            let cust: CarCustomizer = CarCustomizer(root: model)
            var cfg: CarConfig = CarConfig()
            cfg.paint = hex
            cfg.livery = false
            cfg.finish = .metallic
            cfg.wing = 1
            cfg.tint = 0.8
            cust.apply(cfg)
            rig.setWing(1)
            let name: String = RaceManager.names[i % RaceManager.names.count]
            opponents.append(RaceOpponent(name: name, hex: hex, node: wrapper, rig: rig, customizer: cust))
            await Task.yield()
        }
    }

    // MARK: Start / stop

    func start(routeIndex: Int, laps l: Int) {
        if phase != .idle { stop() }
        guard let w = ctx.world, !w.raceRoutes.isEmpty else {
            ctx.toast("No race route available")
            return
        }
        guard let car = ctx.car else { return }
        let idx: Int = max(0, min(w.raceRoutes.count - 1, routeIndex))
        let rt: RaceRoute = w.raceRoutes[idx]
        guard let p = RoutePath(route: rt, spacing: 3.0) else {
            ctx.toast("Race route is invalid")
            return
        }
        route = rt
        path = p
        laps = p.closed ? max(1, min(l, 20)) : 1
        totalDistance = p.closed ? Float(laps) * p.length : p.length
        night = w.timeOfDay < 6.5 || w.timeOfDay > 18.5

        let baseSkill: Float = clampf(ctx.settings.settings.gameplay.opponentSkill, 0.5, 1.05)
        let maxLat: Float = min(2.4, max(1.0, p.halfWidth - 2.0))

        // grid: 2 columns, staggered rows behind the line
        var slots: [(s: Float, lat: Float)] = []
        for k in 0..<6 {
            let row: Int = k / 2
            let col: Int = k % 2
            let s: Float = -(8 + 8 * Float(row)) - (col == 1 ? 3 : 0)
            slots.append((s, col == 0 ? maxLat : -maxLat))
        }

        // player
        let ps: (s: Float, lat: Float) = slots[playerSlot]
        let pp: (pos: Vec2, tan: Vec2) = p.point(atS: ps.s, lateral: ps.lat)
        let py: Float = w.groundHeight(at: pp.pos)
        car.place(position: Vec3(pp.pos.x, py, pp.pos.y), heading: headingOf(pp.tan))
        let loc: RouteLocation = p.locate(pp.pos, hint: nil, window: 0)
        playerS = loc.s
        playerHint = loc.index
        playerLateral = loc.lateral
        playerProgress = ps.s
        playerFinishTime = nil
        wrongWayTimer = 0
        car.controlOverride = VehicleControls()
        car.holdBrake = true

        // opponents
        for (i, o) in opponents.enumerated() {
            let slot: Int = i < playerSlot ? i : i + 1
            let sl: (s: Float, lat: Float) = slots[min(slot, slots.count - 1)]
            let skill: Float = baseSkill * (1.0 - 0.015 * Float(i))
            let top: Float = 82 * (0.85 + 0.15 * skill)
            let drv: AIDriver = AIDriver(path: p, skill: skill, topSpeed: top, seed: Float(i) * 0.37 + 0.11)
            drv.reset(s: sl.s, lateral: sl.lat)
            drv.laneWander = 0.6 + 0.4 * Float(i % 3)
            o.driver = drv
            o.lapsDone = 0
            o.lapStart = 0
            o.bestLap = nil
            o.node.isHidden = false
            o.customizer.setHeadlights(night)
            o.groundY = w.groundHeight(at: drv.pos)
            placeOpponentNode(o, snap: true, dt: 0)
        }

        lapTimes = []
        currentLapIndex = -1
        raceClock = 0
        lapStartClock = 0
        countdownClock = 0
        lastCountShown = 3
        goShown = 0
        hudTimer = 0
        contactCooldown = 0
        resultsShown = false

        hud = RaceHUD()
        hud.position = playerSlot + 1
        hud.total = opponents.count + 1
        hud.lap = 1
        hud.laps = laps
        hud.countdown = 3
        hud.finished = false
        ctx.state.race = hud
        phase = .countdown
        ctx.world.setStartLights(red: 1, green: false)
        ctx.audio.play(SFX.countdownBeep, volume: 1, rate: 1, position: nil)
    }

    func stop() {
        phase = .idle
        ctx.world.setStartLights(red: 0, green: false)
        for o in opponents {
            o.node.isHidden = true
            o.driver = nil
        }
        if let car = ctx.car {
            car.controlOverride = nil
            car.holdBrake = false
        }
        ctx.state.race = nil
        ctx.state.opponentMapPositions = []
        resultsShown = false
        path = nil
    }

    // MARK: Frame update

    func update(dt: Float) {
        if phase == .idle { return }
        guard let p = path, let car = ctx.car else { return }
        let d: Float = clampf(dt, 0, 0.1)
        contactCooldown = max(0, contactCooldown - d)

        switch phase {
        case .idle:
            return
        case .countdown:
            countdownClock += d
            if countdownClock >= 3 {
                beginRacing(car)
            } else {
                let n: Int = 3 - Int(countdownClock)
                if n != lastCountShown {
                    lastCountShown = n
                    hud.countdown = n
                    ctx.state.race = hud
                    ctx.world.setStartLights(red: 4 - n, green: false)
                    ctx.audio.play(SFX.countdownBeep, volume: 1, rate: 1, position: nil)
                }
            }
            updateOpponents(d, racing: false, car: car, path: p)
        case .racing:
            raceClock += Double(d)
            if hud.countdown != nil {
                goShown -= d
                if goShown <= 0 {
                    hud.countdown = nil
                    ctx.state.race = hud
                    ctx.world.setStartLights(red: 0, green: false)
                }
            }
            updateOpponents(d, racing: true, car: car, path: p)
            updatePlayer(d, car: car, path: p)
            resolveContacts(car)
            publishHUD(d, car: car, force: false)
        case .finished:
            raceClock += Double(d)
            updateOpponents(d, racing: true, car: car, path: p)
            hudTimer += d
            if hudTimer > 0.1 {
                hudTimer = 0
                publishOpponentMap()
            }
            if resultsShown && ctx.state.screen != .results { stop() }
        }
    }

    private func beginRacing(_ car: PlayerCar) {
        phase = .racing
        raceClock = 0
        lapStartClock = 0
        hud.countdown = 0
        goShown = 1.0
        ctx.world.setStartLights(red: 0, green: true)
        car.holdBrake = false
        car.controlOverride = nil
        ctx.state.race = hud
        ctx.audio.play(SFX.raceGo, volume: 1, rate: 1, position: nil)
        ctx.input.haptic(HapticKind.medium)
    }

    // MARK: Opponents

    private func updateOpponents(_ d: Float, racing: Bool, car: PlayerCar, path p: RoutePath) {
        let count: Int = opponents.count
        for i in 0..<count {
            let o: RaceOpponent = opponents[i]
            guard let drv = o.driver else { continue }
            var obs: [AIObstacle] = []
            for j in 0..<count where j != i {
                if let other = opponents[j].driver {
                    obs.append(AIObstacle(ds: drv.wrapDelta(other.s - drv.s), lateral: other.lateral, speed: other.speed))
                }
            }
            obs.append(AIObstacle(ds: drv.wrapDelta(playerProgress - drv.s), lateral: playerLateral, speed: abs(car.state.speed)))

            // rubber banding keeps the race close without being obvious
            let gap: Float = drv.s - playerProgress
            var rubber: Float = 1
            if gap > 40 {
                rubber = 1 - min(0.12, (gap - 40) / 600)
            } else if gap < -30 {
                rubber = 1 + min(0.10, (-gap - 30) / 500)
            }
            drv.rubber = rubber
            drv.update(dt: d, racing: racing, others: obs)

            if racing {
                if p.closed {
                    let lapIdx: Int = Int(floorf(drv.s / p.length))
                    if lapIdx > o.lapsDone && lapIdx >= 1 {
                        let t: Double = raceClock - o.lapStart
                        o.lapStart = raceClock
                        if let b = o.bestLap {
                            if t < b { o.bestLap = t }
                        } else {
                            o.bestLap = t
                        }
                    }
                    if lapIdx > o.lapsDone { o.lapsDone = lapIdx }
                }
                if !drv.finished && drv.s >= totalDistance {
                    drv.finished = true
                    drv.finishTime = raceClock
                }
            }
            placeOpponentNode(o, snap: false, dt: d)
        }
    }

    private func placeOpponentNode(_ o: RaceOpponent, snap: Bool, dt: Float) {
        guard let drv = o.driver else { return }
        var y: Float = o.groundY
        if let w = ctx.world {
            let gy: Float = w.groundHeight(at: drv.pos)
            y = snap ? gy : damp(o.groundY, gy, 20, dt)
        }
        o.groundY = y
        o.node.simdPosition = Vec3(drv.pos.x, y, drv.pos.y)
        o.node.simdOrientation = simd_quatf(angle: drv.heading, axis: Vec3(0, 1, 0))
        o.rig.setWheels(steer: drv.steer, spinFront: drv.wheelPhase, spinRear: drv.wheelPhase)
        let roll: Float = clampf(0.0018 * drv.speed * drv.speed * drv.steer, -0.06, 0.06)
        o.rig.setBody(pitchX: 0, rollZ: roll, heave: 0)
        o.customizer.setBrakeLights(drv.braking, night: night)
    }

    // MARK: Player progress

    private func updatePlayer(_ d: Float, car: PlayerCar, path p: RoutePath) {
        let pos: Vec2 = Vec2(car.state.position.x, car.state.position.z)
        let loc: RouteLocation = p.locate(pos, hint: playerHint, window: 40)
        playerHint = loc.distance > 35 ? nil : loc.index
        playerLateral = loc.lateral
        var delta: Float = loc.s - playerS
        if p.closed { delta = delta - p.length * (delta / p.length).rounded() }
        if abs(delta) > 50 { delta = 0 }
        playerS = loc.s
        playerProgress += delta

        // wrong way
        let vel: Vec2 = Vec2(car.state.velocity.x, car.state.velocity.z)
        if vel.length > 5 && simd_dot(vel.normalizedSafe, loc.tangent) < -0.3 {
            wrongWayTimer += d
        } else {
            wrongWayTimer = max(0, wrongWayTimer - d * 2)
        }
        let ww: Bool = wrongWayTimer > 1.2
        if ww != hud.wrongWay {
            hud.wrongWay = ww
            ctx.state.race = hud
        }

        // laps
        let lapIdx: Int = p.closed ? Int(floorf(playerProgress / p.length)) : 0
        if lapIdx > currentLapIndex {
            if lapIdx >= 1 && p.closed {
                let t: Double = raceClock - lapStartClock
                lapStartClock = raceClock
                lapTimes.append(t)
                hud.lastLap = t
                var best: Double = t
                if let b = hud.bestLap, b < t { best = b }
                hud.bestLap = best
                if lapIdx < laps {
                    ctx.audio.play(SFX.lapComplete, volume: 1, rate: 1, position: nil)
                    ctx.toast(String(format: "Lap %d  %@", lapIdx, RaceManager.formatTime(t)))
                }
            }
            currentLapIndex = lapIdx
        }
        if playerProgress >= totalDistance { finishRace(car) }
    }

    private func resolveContacts(_ car: PlayerCar) {
        let st: VehicleState = car.state
        let pp: Vec2 = Vec2(st.position.x, st.position.z)
        let pf: Vec2 = headingForward2(st.heading)
        let pv: Vec2 = Vec2(st.velocity.x, st.velocity.z)
        let pcs: [Vec2] = [pp + pf * 1.4, pp - pf * 1.4]
        for o in opponents {
            guard let drv = o.driver else { continue }
            if simd_distance(drv.pos, pp) > 7 { continue }
            let af: Vec2 = headingForward2(drv.heading)
            let acs: [Vec2] = [drv.pos + af * 1.4, drv.pos - af * 1.4]
            let av: Vec2 = af * drv.speed
            for pc in pcs {
                for ac in acs {
                    let dv: Vec2 = ac - pc
                    let dist: Float = dv.length
                    if dist >= 2.1 || dist < 1e-3 { continue }
                    let n: Vec2 = dv / dist
                    let pen: Float = 2.1 - dist
                    let closing: Float = simd_dot(pv - av, n)
                    var vd: Vec2 = Vec2(0, 0)
                    if closing > 0 { vd = n * (-closing * 0.18) }
                    car.nudge(shift: n * (-pen * 0.25), velocityDelta: vd)
                    let latShift: Float = simd_dot(n, headingLeft2(drv.heading)) * pen * 0.5
                    drv.lateral = clampf(drv.lateral + latShift, -(drv.path.halfWidth - 1.5), drv.path.halfWidth - 1.5)
                    if closing > 0 { drv.slow = max(0.6, drv.slow - closing * 0.03) }
                    if closing > 3 && contactCooldown <= 0 {
                        contactCooldown = 0.5
                        ctx.audio.play(SFX.crashMetalLight, volume: clampf(closing / 12, 0.3, 0.8), rate: 1, position: st.position)
                        ctx.cameraRig.shake(clampf(closing / 15, 0.1, 0.5))
                        ctx.input.haptic(HapticKind.medium)
                    }
                }
            }
        }
    }

    // MARK: Ranking / HUD

    private struct RankEntry {
        var id: Int
        var progress: Float
        var finish: Double?
    }

    private func ranking() -> [RankEntry] {
        var list: [RankEntry] = []
        list.append(RankEntry(id: 100, progress: playerProgress, finish: playerFinishTime))
        for (i, o) in opponents.enumerated() {
            if let drv = o.driver {
                list.append(RankEntry(id: i, progress: drv.s, finish: drv.finishTime))
            }
        }
        list.sort { (a: RankEntry, b: RankEntry) -> Bool in
            if let fa = a.finish {
                if let fb = b.finish { return fa < fb }
                return true
            }
            if b.finish != nil { return false }
            return a.progress > b.progress
        }
        return list
    }

    private func playerPosition() -> Int {
        let order: [RankEntry] = ranking()
        for (i, e) in order.enumerated() where e.id == 100 { return i + 1 }
        return 1
    }

    private func publishHUD(_ d: Float, car: PlayerCar, force: Bool) {
        hudTimer += d
        if hudTimer < 0.066 && !force { return }
        hudTimer = 0
        hud.position = playerPosition()
        hud.raceTime = raceClock
        hud.lapTime = raceClock - lapStartClock
        hud.lap = max(1, min(laps, currentLapIndex + 1))
        ctx.state.race = hud
        publishOpponentMap()
    }

    private func publishOpponentMap() {
        var pts: [Vec2] = []
        for o in opponents {
            if let drv = o.driver { pts.append(drv.pos) }
        }
        ctx.state.opponentMapPositions = pts
    }

    // MARK: Finish

    private func finishRace(_ car: PlayerCar) {
        if phase != .racing { return }
        phase = .finished
        playerFinishTime = raceClock
        if lapTimes.isEmpty { lapTimes.append(raceClock) }
        car.holdBrake = true

        struct Entry {
            var name: String
            var time: Double
            var best: Double
            var isPlayer: Bool
        }
        var entries: [Entry] = []
        let playerBest: Double = lapTimes.min() ?? raceClock
        entries.append(Entry(name: ctx.save.data.playerName, time: raceClock, best: playerBest, isPlayer: true))
        let lapCount: Double = Double(max(1, laps))
        for o in opponents {
            guard let drv = o.driver else { continue }
            var t: Double = raceClock
            if let ft = drv.finishTime {
                t = ft
            } else {
                let remaining: Float = max(0, totalDistance - drv.s)
                t = raceClock + Double(remaining / max(25, drv.speed))
            }
            entries.append(Entry(name: o.name, time: t, best: o.bestLap ?? (t / lapCount), isPlayer: false))
        }
        entries.sort { (a: Entry, b: Entry) -> Bool in return a.time < b.time }

        var rows: [RaceResultRow] = []
        var playerPos: Int = entries.count
        for (i, e) in entries.enumerated() {
            rows.append(RaceResultRow(id: i, position: i + 1, name: e.name, totalTime: e.time, bestLap: e.best, isPlayer: e.isPlayer))
            if e.isPlayer { playerPos = i + 1 }
        }

        let base: [Int] = [6000, 3500, 2000, 1000, 500, 250]
        let b: Int = base[min(playerPos - 1, base.count - 1)]
        var prize: Int = Int((Float(b) * Float(laps) / 3.0 / 50.0).rounded()) * 50
        if prize < 50 { prize = 50 }

        ctx.save.addMoney(prize)
        ctx.save.data.races += 1
        if playerPos == 1 { ctx.save.data.wins += 1 }
        if let rt = route, let bl = lapTimes.min() {
            if let old = ctx.save.data.bestLaps[rt.name] {
                if bl < old { ctx.save.data.bestLaps[rt.name] = bl }
            } else {
                ctx.save.data.bestLaps[rt.name] = bl
            }
        }

        hud.finished = true
        hud.position = playerPos
        hud.raceTime = raceClock
        hud.results = rows
        hud.prize = prize
        hud.wrongWay = false
        hud.countdown = nil
        ctx.state.race = hud
        ctx.state.screen = .results
        resultsShown = true
        ctx.audio.play(playerPos == 1 ? SFX.raceWin : SFX.raceLose, volume: 1, rate: 1, position: nil)
        ctx.input.haptic(HapticKind.success)
    }

    static func formatTime(_ t: Double) -> String {
        let m: Int = Int(t / 60)
        let s: Double = t - Double(m) * 60
        return String(format: "%d:%05.2f", m, s)
    }
}
