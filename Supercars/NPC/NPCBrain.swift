import Foundation
import simd

// MARK: - NPCBrain: the behaviour state machine of one pedestrian.
//   spawn -> choose a destination -> walk (turn first, accelerate) -> curb: look both ways, wait for traffic -> cross -> arrive -> stand,
//   look around / check the phone / talk -> choose the next destination ...  Reactions (a fast car, a crash, being bumped) interrupt
//   the cycle and hand control back to `resume`.  The brain runs at a low rate (see NPCConfig.brainRate); motion and animation run
//   every frame in NPCCharacter, so slow thinking never makes movement choppy.

@MainActor
protocol NPCEnvironment: AnyObject {
    var hour: Float { get }
    var navigator: PedNavigator { get }
    func crossingThreat(from a: Vec2, to b: Vec2) -> Bool
    func hasNearbyPedestrian(_ npc: NPCCharacter, within radius: Float) -> Bool
}

@MainActor
final class NPCBrain {
    var route: PedRoute = PedRoute()
    private var crossingLeg: Bool = false
    private var dwellLeft: Float = 0
    private var nextGestureIn: Float = 1
    private var tripSpeed: Float = 1.4
    private var reactTime: Float = 0
    private var stuckTimer: Float = 0
    private var lastCheckPos: Vec2 = Vec2(0, 0)
    private var stuckCount: Int = 0
    private var retryIn: Float = 0
    private var leavesAtHome: Bool = false
    private var waitedAtCurb: Float = 0

    init() {}

    func reset() {
        route = PedRoute()
        crossingLeg = false
        dwellLeft = 0
        nextGestureIn = 1
        reactTime = 0
        stuckTimer = 0
        stuckCount = 0
        retryIn = 0
        leavesAtHome = false
        waitedAtCurb = 0
    }

    var hasRoute: Bool { return !route.isFinished }
    var destinationKind: NPCDestinationKind? { return route.destination?.kind }

    // MARK: entry point

    func think(_ n: NPCCharacter, dt: Float, env: NPCEnvironment) {
        switch n.state {
        case .enteringTaxi, .insideTaxi, .leavingTaxi:
            return
        case .reactingToPlayer, .reactingToCollision, .avoidingObstacle:
            reactTime -= dt
            if reactTime <= 0 { resume(n, env: env) }
        case .idle, .lookingAround, .talking, .waitingForTaxi:
            idleThink(n, dt: dt, env: env)
        case .walking, .running, .goingToDestination, .crossingStreet, .waiting:
            travelThink(n, dt: dt, env: env)
        }
    }

    // MARK: planning

    func planNewTrip(_ n: NPCCharacter, env: NPCEnvironment) {
        leavesAtHome = false
        var made: (dest: NPCDestination, anchors: [PedNode])? = env.navigator.makeDestination(near: n.pos, rng: &n.rng, hour: env.hour, dwellScale: n.traits.dwell)
        var attempts: Int = 0
        var planned: PedRoute? = nil
        while attempts < 3 {
            attempts += 1
            guard let m = made else {
                made = env.navigator.makeDestination(near: n.pos, rng: &n.rng, hour: env.hour, dwellScale: n.traits.dwell)
                continue
            }
            planned = env.navigator.route(from: n.pos, to: m.dest, anchors: m.anchors)
            if planned != nil { break }
            made = env.navigator.makeDestination(near: n.pos, rng: &n.rng, hour: env.hour, dwellScale: n.traits.dwell)
        }
        guard let r = planned else {
            // nothing reachable right now: stand for a moment and try again
            n.target = nil
            n.desiredSpeed = 0
            n.state = NPCState.idle
            dwellLeft = 3
            retryIn = 3
            return
        }
        route = r
        crossingLeg = false
        stuckCount = 0
        let t: NPCTraits = n.traits
        let roll: Float = n.rng.float()
        if roll < t.hurry * 0.25 {
            tripSpeed = t.runSpeed * n.rng.float(0.92, 1.08)
            n.state = NPCState.running
        } else if roll < t.hurry {
            tripSpeed = t.fastSpeed * n.rng.float(0.94, 1.06)
            n.state = NPCState.goingToDestination
        } else {
            tripSpeed = n.walkSpeedPersonal
            n.state = NPCState.walking
        }
        n.facingTarget = nil
        n.lookAt = 0
        lastCheckPos = n.pos
        stuckTimer = 0
    }

    private func resume(_ n: NPCCharacter, env: NPCEnvironment) {
        n.lookAt = 0
        n.gesture = NPCGesture.none
        if route.isFinished {
            planNewTrip(n, env: env)
        } else {
            n.state = tripSpeed > 2.5 ? NPCState.running : NPCState.goingToDestination
        }
    }

    // MARK: travelling

    private func travelThink(_ n: NPCCharacter, dt: Float, env: NPCEnvironment) {
        guard let wp = route.current else {
            arrive(n, env: env)
            return
        }
        let d: Float = simd_distance(n.pos, wp.p)
        let tol: Float = n.level == NPCLevel.near ? 1.0 : 1.7
        var switchDist: Float = wp.isFinal ? 0.45 : (wp.crossing ? 0.9 : 1.1)
        switchDist *= tol

        // ---- reached a waypoint
        if d < switchDist {
            if crossingLeg {
                crossingLeg = false
                n.state = tripSpeed > 2.5 ? NPCState.running : NPCState.goingToDestination
            }
            if wp.crossing {
                // standing at the curb: look both ways, wait until the road is clear
                if env.crossingThreat(from: wp.p, to: wp.crossEnd) {
                    n.state = NPCState.waiting
                    n.target = nil
                    n.desiredSpeed = 0
                    waitedAtCurb += dt
                    if n.gesture == NPCGesture.none { n.startGesture(NPCGesture.waitAtCurb, duration: 3.5) }
                    return
                }
                waitedAtCurb = 0
                crossingLeg = true
                n.state = NPCState.crossingStreet
                route.index += 1
                return
            }
            route.index += 1
            if route.isFinished {
                arrive(n, env: env)
                return
            }
        }

        // ---- head for the current waypoint
        guard let cur = route.current else { return }
        n.target = cur.p
        var v: Float = tripSpeed
        if crossingLeg {
            v = max(tripSpeed, n.traits.fastSpeed)
            if env.crossingThreat(from: n.pos, to: cur.p) { v = max(v, 3.0) }       // a car is coming: hurry across
        }
        if cur.isFinal {
            let rem: Float = simd_distance(n.pos, cur.p)
            v = min(v, max(0.4, rem * 1.3))
        }
        n.desiredSpeed = v
        if n.state == NPCState.waiting { n.state = NPCState.goingToDestination }

        // ---- stuck detection (blocked by props, people or a wall): re-plan
        stuckTimer += dt
        if stuckTimer > 2.0 {
            let moved: Float = simd_distance(n.pos, lastCheckPos)
            lastCheckPos = n.pos
            stuckTimer = 0
            if moved < 0.5 && n.desiredSpeed > 0.5 {
                stuckCount += 1
                if stuckCount >= 2 {
                    route.index = min(route.points.count, route.index + 1)
                    if stuckCount >= 4 { planNewTrip(n, env: env) }
                }
            } else {
                stuckCount = 0
            }
        }
    }

    private func arrive(_ n: NPCCharacter, env: NPCEnvironment) {
        let dest: NPCDestination? = route.destination
        n.target = nil
        n.desiredSpeed = 0
        n.facingTarget = dest?.facing
        dwellLeft = dest?.dwell ?? 4
        n.state = NPCState.idle
        leavesAtHome = false
        if let k = dest?.kind {
            switch k {
            case .taxiStop:
                n.state = NPCState.waitingForTaxi
                dwellLeft = 80
            case .home:
                leavesAtHome = true
            default:
                break
            }
        }
        nextGestureIn = n.rng.float(0.5, 2.0)
    }

    // MARK: standing around

    private func pickIdleGesture(_ n: NPCCharacter, env: NPCEnvironment) {
        let t: NPCTraits = n.traits
        let neighbour: Bool = env.hasNearbyPedestrian(n, within: 3.2)
        var opts: [(NPCGesture, Float)] = [
            (NPCGesture.lookAround, t.curious * 1.3),
            (NPCGesture.checkPhone, t.phoneChance),
            (NPCGesture.checkWatch, 0.18),
            (NPCGesture.lookLeft, 0.35),
            (NPCGesture.lookRight, 0.35),
            (NPCGesture.talk, neighbour ? t.talkChance * 2.2 : t.talkChance * 0.25)
        ]
        if n.state == NPCState.waitingForTaxi { opts.append((NPCGesture.lookLeft, 1.0)); opts.append((NPCGesture.checkWatch, 0.7)) }
        var total: Float = 0
        for o in opts { total += o.1 }
        var r: Float = n.rng.float() * total
        var chosen: NPCGesture = NPCGesture.lookAround
        for o in opts {
            r -= o.1
            if r <= 0 {
                chosen = o.0
                break
            }
        }
        var dur: Float = 2.4
        switch chosen {
        case .lookAround: dur = n.rng.float(3.0, 5.0)
        case .checkPhone: dur = n.rng.float(6.0, 13.0)
        case .checkWatch: dur = 2.6
        case .talk: dur = n.rng.float(4.0, 9.0)
        default: dur = n.rng.float(1.8, 2.8)
        }
        n.startGesture(chosen, duration: dur)
        if chosen == NPCGesture.talk { n.state = NPCState.talking } else if chosen == NPCGesture.lookAround { n.state = NPCState.lookingAround } else if n.state != NPCState.waitingForTaxi { n.state = NPCState.idle }
        n.animator.setWeightShift(n.rng.float(-1, 1))
        nextGestureIn = dur + n.rng.float(1.0, 5.0) / max(0.25, t.restless)
    }

    private func idleThink(_ n: NPCCharacter, dt: Float, env: NPCEnvironment) {
        if retryIn > 0 {
            retryIn -= dt
            if retryIn <= 0 {
                planNewTrip(n, env: env)
                return
            }
        }
        dwellLeft -= dt
        nextGestureIn -= dt
        if n.state == NPCState.waitingForTaxi && n.taxiAssigned { dwellLeft = max(dwellLeft, 20) }
        if n.gesture == NPCGesture.none {
            if n.state == NPCState.lookingAround || n.state == NPCState.talking { n.state = NPCState.idle }
            if nextGestureIn <= 0 { pickIdleGesture(n, env: env) }
        }
        if dwellLeft <= 0 {
            if leavesAtHome {
                n.requestDespawn = true
            } else {
                planNewTrip(n, env: env)
            }
        }
    }

    // MARK: reactions (called by NPCInteraction)

    private func headYaw(_ n: NPCCharacter, toward p: Vec2) -> Float {
        let d: Vec2 = p - n.pos
        if simd_length(d) < 0.1 { return 0 }
        return clampf(angleDiff(n.heading, headingOf(d)), -1.15, 1.15)
    }

    /// something fast or loud passes nearby: look at it, or step out of its way
    func reactToCar(_ n: NPCCharacter, carPos: Vec2, carVel: Vec2, danger: Float, env: NPCEnvironment) {
        switch n.state {
        case .enteringTaxi, .insideTaxi, .leavingTaxi, .reactingToCollision:
            return
        default:
            break
        }
        n.lookAt = headYaw(n, toward: carPos)
        if danger < 0.55 {
            if n.state == NPCState.idle || n.state == NPCState.waitingForTaxi || n.state == NPCState.lookingAround {
                reactTime = max(reactTime, 1.4)
                if n.state == NPCState.idle { n.state = NPCState.reactingToPlayer }
            }
            return
        }
        // dangerous: startle, then step away sideways from the car's path
        n.startGesture(NPCGesture.startled, duration: 1.0)
        let dir: Vec2 = carVel.normalizedSafe
        var away: Vec2 = n.pos - carPos
        away -= dir * simd_dot(away, dir)
        var al: Float = simd_length(away)
        if al < 0.05 {
            away = dir.leftPerp
            al = 1
        }
        away /= al
        n.target = n.pos + away * 3.0
        n.desiredSpeed = max(n.traits.fastSpeed, 2.4)
        n.facingTarget = nil
        n.state = NPCState.avoidingObstacle
        reactTime = 1.5
    }

    /// a crash somewhere close: stop and look, sometimes run the other way
    func reactToCrash(_ n: NPCCharacter, at p: Vec2, env: NPCEnvironment) {
        switch n.state {
        case .enteringTaxi, .insideTaxi, .leavingTaxi:
            return
        default:
            break
        }
        n.lookAt = headYaw(n, toward: p)
        n.startGesture(NPCGesture.startled, duration: 1.2)
        if n.rng.chance(0.4) {
            let away: Vec2 = (n.pos - p).normalizedSafe
            n.target = n.pos + away * 9
            n.desiredSpeed = n.traits.runSpeed
            n.state = NPCState.reactingToCollision
            reactTime = 3.0
            // the old route is abandoned: after the scare pick somewhere new
            route = PedRoute()
        } else {
            n.target = nil
            n.desiredSpeed = 0
            n.state = NPCState.reactingToPlayer
            reactTime = 2.5
        }
    }

    /// bumped by a vehicle
    func reactToHit(_ n: NPCCharacter, impulse: Vec2) {
        n.knock = impulse
        n.speed = 0
        n.target = nil
        n.desiredSpeed = 0
        n.startGesture(NPCGesture.stumble, duration: 1.4)
        n.state = NPCState.reactingToCollision
        reactTime = 2.0
        route = PedRoute()
    }
}
