import Foundation
import simd

// MARK: - VehicleSuspension: four independent corners (quarter-car spring / damper each) plus per-wheel steering and rotation.
//   * the body is NOT tilted by a fake angle: every corner is a mass on a spring and damper, driven by the load transfer from the real
//     accelerations (braking dive, acceleration squat, cornering roll), aero downforce and the road (kerbs, rough ground);
//     heave / pitch / roll of the body are derived from the four corner heights;
//   * wheel rotation is integrated from the real wheel-plane speed: omega = v / r for each wheel (front wheels see the steering angle,
//     inner / outer wheels see the differential of a turn); reverse rotates backwards; locked brakes stop the wheel, wheelspin adds to it;
//   * front wheels steer with Ackermann geometry (inner wheel turns more), following the smoothed steering angle of the physics.
// Corner order everywhere: 0 = front left, 1 = front right, 2 = rear left, 3 = rear right (+X = left).

struct WheelVisual {
    var steer: Float = 0            // radians, + = left
    var phase: Float = 0            // rotation angle (radians)
    var omega: Float = 0            // rad/s
    var lift: Float = 0             // metres the wheel is raised by the ground under it (kerb, bump)
}

struct SuspensionInput {
    var ax: Float = 0               // body accelerations (m/s2): + forward / + to the left
    var ay: Float = 0
    var u: Float = 0                // forward speed
    var v: Float = 0                // lateral speed
    var yawRate: Float = 0
    var steerDelta: Float = 0       // front wheel angle of the bicycle model (smoothed, speed limited)
    var rearSpin: Float = 0         // 0...1 excess drive force
    var frontLocked: Bool = false
    var absActive: Bool = false
    var handbrake: Bool = false
    var ground: [Float] = [0, 0, 0, 0]   // surface height under each wheel
    var mass: Float = 1300
    var downforceCoefficient: Float = 2.8
    var cgHeight: Float = 0.42
    var wheelbase: Float = 2.516
    var distFront: Float = 1.384
    var trackFront: Float = 1.68
    var trackRear: Float = 1.66
    var radiusFront: Float = 0.34
    var radiusRear: Float = 0.352
}

final class VehicleSuspension {
    // corner model
    private let springRate: Float = 40000            // N/m
    private let damping: Float = 4000                // Ns/m (about 0.58 of critical)
    private let cornerMass: Float = 300              // kg (sprung share)
    private let travel: Float = 0.10                 // bump stop distance (m)
    /// the body tilt is shown slightly larger than the physical value so it reads on a phone screen
    private let visualGain: Float = 1.35

    private var y: [Float] = [0, 0, 0, 0]            // body corner height deviation (m, + up)
    private var vy: [Float] = [0, 0, 0, 0]
    private var uSmooth: [Float] = [0, 0, 0, 0]      // filtered road height (tyre envelopment)
    private var time: Float = 0

    private(set) var wheels: [WheelVisual] = [WheelVisual(), WheelVisual(), WheelVisual(), WheelVisual()]
    private(set) var heave: Float = 0
    private(set) var pitch: Float = 0                 // + = nose down
    private(set) var roll: Float = 0                  // + = left side up

    func reset() {
        y = [0, 0, 0, 0]
        vy = [0, 0, 0, 0]
        uSmooth = [0, 0, 0, 0]
        for i in 0..<4 {
            wheels[i].omega = 0
            wheels[i].steer = 0
            wheels[i].lift = 0
        }
        heave = 0
        pitch = 0
        roll = 0
    }

    func snapGround(_ g: [Float]) {
        for i in 0..<4 {
            uSmooth[i] = g[i]
            y[i] = g[i]
            vy[i] = 0
            wheels[i].lift = g[i]
        }
    }

    func step(_ dt: Float, _ inp: SuspensionInput) {
        let dtc: Float = clampf(dt, 0.0002, 0.05)
        time += dtc
        let g: Float = 9.81
        _ = g

        // ---- vertical forces on each corner (deviation from the static load, + = pushes the corner down)
        let L: Float = max(inp.wheelbase, 1)
        let tAvg: Float = 0.5 * (inp.trackFront + inp.trackRear)
        let longTransfer: Float = inp.mass * inp.ax * inp.cgHeight / L
        let latTransfer: Float = inp.mass * inp.ay * inp.cgHeight / max(tAvg, 1)
        // aero downforce compresses the springs, scaled down: a real GT3 sits on much stiffer springs than this soft visual model
        let down: Float = 0.5 * 1.2 * inp.downforceCoefficient * inp.u * inp.u * 0.25
        var dF: [Float] = [0, 0, 0, 0]
        // acceleration unloads the front / loads the rear; braking the opposite
        dF[0] = -longTransfer * 0.5 + 0.42 * down * 0.5
        dF[1] = -longTransfer * 0.5 + 0.42 * down * 0.5
        dF[2] = longTransfer * 0.5 + 0.58 * down * 0.5
        dF[3] = longTransfer * 0.5 + 0.58 * down * 0.5
        // turning left (ay > 0) loads the right wheels, unloads the left ones (front axle carries 55 % of the roll moment)
        dF[0] -= 0.55 * latTransfer * 0.5
        dF[1] += 0.55 * latTransfer * 0.5
        dF[2] -= 0.45 * latTransfer * 0.5
        dF[3] += 0.45 * latTransfer * 0.5

        // ---- road input: tyre envelopment (a kerb is a short ramp, not a step) and rough ground
        var target: [Float] = inp.ground
        let n: Int = 4
        let k: Float = 1 - expf(-dtc / 0.055)
        var uDot: [Float] = [0, 0, 0, 0]
        for i in 0..<n {
            let prev: Float = uSmooth[i]
            uSmooth[i] = prev + (target[i] - prev) * k
            uDot[i] = (uSmooth[i] - prev) / dtc
            target[i] = uSmooth[i]
        }

        // ---- integrate the four springs (sub-steps keep the stiff system stable at low frame rates)
        let subs: Int = max(1, Int(ceilf(dtc / 0.004)))
        let h: Float = dtc / Float(subs)
        for _ in 0..<subs {
            for i in 0..<n {
                let comp: Float = uSmooth[i] - y[i]
                var f: Float = springRate * comp + damping * (uDot[i] - vy[i]) - dF[i]
                // bump / droop stops
                if comp > travel { f += 220000 * (comp - travel) }
                if comp < -travel { f += 220000 * (comp + travel) }
                let acc: Float = f / cornerMass
                vy[i] += acc * h
                y[i] += vy[i] * h
            }
        }
        for i in 0..<n {
            if !y[i].isFinite || !vy[i].isFinite {
                y[i] = uSmooth[i]
                vy[i] = 0
            }
        }
        heave = 0.25 * (y[0] + y[1] + y[2] + y[3])
        let frontAvg: Float = 0.5 * (y[0] + y[1])
        let rearAvg: Float = 0.5 * (y[2] + y[3])
        let leftAvg: Float = 0.5 * (y[0] + y[2])
        let rightAvg: Float = 0.5 * (y[1] + y[3])
        pitch = clampf((rearAvg - frontAvg) / L * visualGain, -0.09, 0.09)
        roll = clampf((leftAvg - rightAvg) / max(tAvg, 1) * visualGain, -0.10, 0.10)

        // ---- steering: Ackermann
        let d: Float = inp.steerDelta
        var dl: Float = d
        var dr: Float = d
        if abs(d) > 0.0005 {
            let t: Float = tanf(abs(d))
            let inner: Float = atanf(L * t / max(0.5, L - inp.trackFront * 0.5 * t))
            let outer: Float = atanf(L * t / (L + inp.trackFront * 0.5 * t))
            if d > 0 {
                dl = inner
                dr = outer
            } else {
                dl = -outer
                dr = -inner
            }
        }
        wheels[0].steer = dl
        wheels[1].steer = dr
        wheels[2].steer = 0
        wheels[3].steer = 0

        // ---- wheel rotation from the actual motion of each wheel: omega = v / r
        let u: Float = inp.u
        let r: Float = inp.yawRate
        let a: Float = inp.distFront
        for i in 0..<4 {
            let left: Bool = i == 0 || i == 2
            let front: Bool = i < 2
            let halfTrack: Float = (front ? inp.trackFront : inp.trackRear) * 0.5
            // longitudinal velocity of the wheel centre (the inner wheel of a turn is slower)
            let vLong: Float = u - (left ? 1 : -1) * r * halfTrack
            var vWheel: Float = vLong
            if front {
                let s: Float = sinf(wheels[i].steer)
                let c: Float = cosf(wheels[i].steer)
                vWheel = vLong * c + (inp.v + a * r) * s
            }
            let radius: Float = front ? inp.radiusFront : inp.radiusRear
            var omegaT: Float = vWheel / max(radius, 0.1)
            if front {
                if inp.frontLocked { omegaT = 0 }
                else if inp.absActive { omegaT *= 0.88 + 0.12 * sinf(time * 46) }
            } else {
                omegaT += inp.rearSpin * 64 * (u >= 0 ? 1 : -1)
                if inp.handbrake && abs(u) > 0.5 { omegaT = 0 }
            }
            // wheels follow within the limits of their inertia (locking / spinning up takes a fraction of a second)
            let maxStep: Float = 1400 * dtc
            let dO: Float = clampf(omegaT - wheels[i].omega, -maxStep, maxStep)
            wheels[i].omega += dO
            wheels[i].phase = (wheels[i].phase + wheels[i].omega * dtc).truncatingRemainder(dividingBy: Float.tau)
            wheels[i].lift = uSmooth[i]
        }
    }
}
