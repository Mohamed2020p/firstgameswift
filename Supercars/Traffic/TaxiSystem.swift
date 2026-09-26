import Foundation
import SceneKit
import simd

// MARK: - TaxiSystem: offline taxi service.
//   cruise -> find a passenger (someone waiting at a taxi stop, or a pedestrian who hails) -> drive to the curb next to them -> stop ->
//   the passenger walks to the rear right door, turns to the car, bends and sits down (the body moves into the seat while it lowers) ->
//   the taxi pulls away with a door thud -> drives to a destination -> stops at the curb -> the passenger steps out through the same
//   door, stands, and walks on with the normal pedestrian brain -> the taxi cruises again.
// The taxi model has no separate doors, so the door is represented by the sound and the passenger's motion; nobody teleports.

@MainActor
final class TaxiSystem {
    private enum Phase {
        case cruising, toPickup, boarding, carrying, alighting
    }

    private final class Job {
        var phase: Phase = Phase.cruising
        var passenger: NPCCharacter? = nil
        var pickup: Vec2 = Vec2(0, 0)
        var dropoff: Vec2 = Vec2(0, 0)
        var timer: Float = 0
        var enterT: Float = 0
        var entering: Bool = false
        var searchTimer: Float = 0
        var stuckTimer: Float = 0
    }

    private unowned let ctx: GameContext
    private unowned let traffic: TrafficManager
    private unowned let npcs: NPCManager
    private var jobs: [Int: Job] = [:]
    private var spawnTimer: Float = 1
    private var rng = SeededRNG(seed: 0x7A81)
    private var claimed = Set<Int>()

    private let enterDuration: Float = 1.5

    init(ctx: GameContext, traffic: TrafficManager, npcs: NPCManager) {
        self.ctx = ctx
        self.traffic = traffic
        self.npcs = npcs
    }

    private var taxis: [TrafficVehicle] { return traffic.taxis }

    var activeCount: Int {
        var n: Int = 0
        for v in taxis where v.active { n += 1 }
        return n
    }

    // MARK: geometry of a taxi

    private func doorPoint(_ v: TrafficVehicle) -> Vec2 {
        let f: Vec2 = headingForward2(v.heading)
        let r: Vec2 = headingLeft2(v.heading) * -1
        return v.pos + r * (v.halfWidth + 0.62) + f * -0.45
    }

    private func seatPoint(_ v: TrafficVehicle) -> Vec2 {
        let f: Vec2 = headingForward2(v.heading)
        let r: Vec2 = headingLeft2(v.heading) * -1
        return v.pos + r * 0.40 + f * -0.55
    }

    // MARK: per frame

    func update(dt: Float) {
        guard traffic.taxiEnabled else { return }
        let f: Vec2 = traffic.focus
        let hour: Float = ctx.world?.timeOfDay ?? 12
        let all: [TrafficVehicle] = taxis
        if all.isEmpty { return }

        // ---- fleet size follows demand
        spawnTimer -= dt
        if spawnTimer <= 0 {
            spawnTimer = 2.0
            let target: Int = max(1, Int((Float(all.count) * NPCSchedule.taxiDemand(hour: hour)).rounded()))
            var activeNow: Int = 0
            for v in all where v.active { activeNow += 1 }
            if activeNow < target {
                for v in all where !v.active {
                    if traffic.spawnCruising(v, around: f, minDistance: 170, maxDistance: 340) {
                        v.speedLimit = 13.9
                        jobs[v.id] = Job()
                    }
                    break
                }
            }
            for v in all where v.active {
                let j: Job? = jobs[v.id]
                if simd_distance(v.pos, f) > 520 && (j == nil || j!.phase == Phase.cruising) {
                    traffic.deactivate(v)
                    jobs[v.id] = nil
                }
            }
        }

        for v in all where v.active {
            let job: Job = jobs[v.id] ?? Job()
            jobs[v.id] = job
            step(v, job: job, dt: dt)
        }
    }

    private func step(_ v: TrafficVehicle, job: Job, dt: Float) {
        switch job.phase {
        case .cruising:
            traffic.extendCruise(v)
            job.searchTimer -= dt
            if job.searchTimer <= 0 {
                job.searchTimer = 1.5
                findPassenger(v, job: job)
            }
        case .toPickup:
            guard let p = job.passenger, p.isActive, p.state == NPCState.waitingForTaxi else {
                cancel(v, job: job)
                return
            }
            job.timer += dt
            // passengers move a little while waiting: keep aiming at the curb next to where they stand
            if v.arrived && simd_distance(v.pos, curbTarget(for: p)) < 9 {
                v.hold = true
                job.phase = Phase.boarding
                job.timer = 0
                job.entering = false
                p.state = NPCState.enteringTaxi
                p.target = doorPoint(v)
                p.desiredSpeed = 1.6
                p.facingTarget = nil
                p.gesture = NPCGesture.none
            } else if job.timer > 120 || (v.arrived && job.timer > 4) {
                cancel(v, job: job)
            }
        case .boarding:
            boarding(v, job: job, dt: dt)
        case .carrying:
            if let p = job.passenger {
                p.pos = v.pos
                p.node.isHidden = true
                p.applyTransform()
            }
            if v.arrived {
                v.hold = true
                job.phase = Phase.alighting
                job.timer = 0
                job.enterT = 0
                if let p = job.passenger {
                    ctx.audio.play(SFX.carDoorOpen, volume: 0.7, rate: 1, position: Vec3(v.pos.x, 1, v.pos.y))
                    p.node.isHidden = false
                    p.pos = seatPoint(v)
                    p.heading = wrapAngle(v.heading - Float.pi * 0.5)
                    p.sit = 1
                    p.state = NPCState.leavingTaxi
                    p.applyTransform()
                }
            } else {
                job.timer += dt
                if job.timer > 240 { finishTrip(v, job: job, force: true) }
            }
        case .alighting:
            alighting(v, job: job, dt: dt)
        }
    }

    /// where the taxi should stop for this passenger: the curb lane next to the sidewalk point they stand on
    private func curbTarget(for p: NPCCharacter) -> Vec2 {
        if let s = TrafficRouter.curbStop(forSidewalkPoint: p.pos) { return s.point }
        return p.pos
    }

    // MARK: finding somebody

    private func findPassenger(_ v: TrafficVehicle, job: Job) {
        // 1. people who are waiting at a taxi stop
        var best: NPCCharacter? = nil
        var bd: Float = 520
        for n in npcs.waitingPassengers where !claimed.contains(n.slot) {
            let d: Float = simd_distance(n.pos, v.pos)
            if d < bd && TrafficRouter.curbStop(forSidewalkPoint: n.pos) != nil {
                bd = d
                best = n
            }
        }
        // 2. somebody standing on the sidewalk close by who raises a hand
        if best == nil {
            for n in npcs.pool.all where n.isActive && n.state == NPCState.idle && !claimed.contains(n.slot) && n.level.rawValue <= NPCLevel.mid.rawValue {
                let d: Float = simd_distance(n.pos, v.pos)
                if d < 85 && d > 20 && rng.chance(0.10) && TrafficRouter.curbStop(forSidewalkPoint: n.pos) != nil {
                    n.state = NPCState.waitingForTaxi
                    n.startGesture(NPCGesture.wave, duration: 3.0)
                    best = n
                    break
                }
            }
        }
        guard let p = best else { return }
        if traffic.plan(v, toSidewalkPoint: p.pos) {
            job.phase = Phase.toPickup
            job.passenger = p
            job.pickup = p.pos
            job.timer = 0
            claimed.insert(p.slot)
            p.taxiAssigned = true
            v.speedLimit = 13.9
        }
    }

    private func cancel(_ v: TrafficVehicle, job: Job) {
        if let p = job.passenger {
            claimed.remove(p.slot)
            p.taxiAssigned = false
            if p.isActive && (p.state == NPCState.enteringTaxi || p.state == NPCState.waitingForTaxi) {
                p.state = NPCState.idle
                p.target = nil
                p.desiredSpeed = 0
                p.sit = 0
                p.node.isHidden = false
                p.brain.planNewTrip(p, env: npcs)
            }
        }
        job.passenger = nil
        job.phase = Phase.cruising
        job.searchTimer = 4
        v.hold = false
        traffic.extendCruise(v)
    }

    // MARK: boarding

    private func boarding(_ v: TrafficVehicle, job: Job, dt: Float) {
        guard let p = job.passenger, p.isActive else {
            cancel(v, job: job)
            return
        }
        job.timer += dt
        v.hold = true
        if !job.entering {
            // walk to the door (the pedestrian controller does the walking, turning and stopping)
            let door: Vec2 = doorPoint(v)
            p.target = door
            p.desiredSpeed = min(1.7, max(0.5, simd_distance(p.pos, door) * 1.3))
            if simd_distance(p.pos, door) < 0.55 && p.speed < 0.6 {
                job.entering = true
                job.enterT = 0
                p.target = nil
                p.desiredSpeed = 0
                p.speed = 0
                ctx.audio.play(SFX.carDoorOpen, volume: 0.7, rate: 1, position: Vec3(v.pos.x, 1, v.pos.y))
            } else if job.timer > 25 {
                cancel(v, job: job)
            }
            return
        }
        // entering: turn to the car, bend, move into the seat while sitting down
        job.enterT += dt
        let t: Float = clampf(job.enterT / enterDuration, 0, 1)
        let door: Vec2 = doorPoint(v)
        let seat: Vec2 = seatPoint(v)
        let faceCar: Float = wrapAngle(v.heading + Float.pi * 0.5)
        p.heading = wrapAngle(p.heading + clampf(angleDiff(p.heading, faceCar), -4 * dt, 4 * dt))
        let move: Float = smoothstep(0.30, 0.95, t)
        p.pos = door + (seat - door) * move
        p.sit = smoothstep(0.35, 1.0, t)
        p.applyTransform()
        if t >= 1 {
            p.node.isHidden = true
            p.state = NPCState.insideTaxi
            ctx.audio.play(SFX.carDoorClose, volume: 0.8, rate: 1, position: Vec3(v.pos.x, 1, v.pos.y))
            startTrip(v, job: job)
        }
    }

    private func startTrip(_ v: TrafficVehicle, job: Job) {
        guard let p = job.passenger else { return }
        // destination: a sidewalk point at least ~250 m away with a valid curb
        var chosen: Vec2? = nil
        for _ in 0..<12 {
            guard let m = npcs.navigator.makeDestination(near: v.pos, rng: &rng, hour: ctx.world?.timeOfDay ?? 12, dwellScale: 1) else { continue }
            if m.dest.kind == NPCDestinationKind.park || m.dest.kind == NPCDestinationKind.plaza { continue }
            if simd_distance(m.dest.position, v.pos) < 220 { continue }
            if !WGrid.hasGridStreets(at: m.dest.position) { continue }
            if TrafficRouter.curbStop(forSidewalkPoint: m.dest.position) == nil { continue }
            chosen = m.dest.position
            break
        }
        job.timer = 0
        v.hold = false
        if let d = chosen, traffic.plan(v, toSidewalkPoint: d) {
            job.dropoff = d
            job.phase = Phase.carrying
            _ = p
        } else {
            // nothing suitable: let them out right here
            job.dropoff = v.pos
            job.phase = Phase.alighting
            job.enterT = 0
            v.hold = true
            p.node.isHidden = false
            p.pos = seatPoint(v)
            p.sit = 1
            p.state = NPCState.leavingTaxi
        }
    }

    // MARK: alighting

    private func alighting(_ v: TrafficVehicle, job: Job, dt: Float) {
        guard let p = job.passenger, p.isActive else {
            finishTrip(v, job: job, force: true)
            return
        }
        v.hold = true
        job.enterT += dt
        let t: Float = clampf(job.enterT / (enterDuration * 0.9), 0, 1)
        let door: Vec2 = doorPoint(v)
        let seat: Vec2 = seatPoint(v)
        let move: Float = smoothstep(0.05, 0.70, t)
        p.pos = seat + (door - seat) * move
        p.sit = 1 - smoothstep(0.0, 0.7, t)
        let faceOut: Float = wrapAngle(v.heading - Float.pi * 0.5)
        p.heading = wrapAngle(p.heading + clampf(angleDiff(p.heading, faceOut), -4 * dt, 4 * dt))
        p.applyTransform()
        if t >= 1 {
            p.sit = 0
            ctx.audio.play(SFX.carDoorClose, volume: 0.7, rate: 1, position: Vec3(v.pos.x, 1, v.pos.y))
            finishTrip(v, job: job, force: false)
        }
    }

    private func finishTrip(_ v: TrafficVehicle, job: Job, force: Bool) {
        if let p = job.passenger {
            claimed.remove(p.slot)
            p.taxiAssigned = false
            p.node.isHidden = false
            p.sit = 0
            p.state = NPCState.idle
            p.target = nil
            p.desiredSpeed = 0
            p.brain.planNewTrip(p, env: npcs)
        }
        job.passenger = nil
        job.phase = Phase.cruising
        job.searchTimer = 6
        v.hold = false
        traffic.extendCruise(v)
    }
}
