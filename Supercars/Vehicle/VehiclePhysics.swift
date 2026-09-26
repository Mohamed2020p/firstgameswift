import Foundation
import simd

// MARK: - Pure vehicle dynamics (no SceneKit).  Swift port of C:\blender-claude\game\sim.py `Vehicle.step`
// (2D bicycle model, slip angles, friction circle, aero, load transfer, 6-speed gearbox, TC / ABS / stability assist).
// Conventions: heading h -> forward (sin h, cos h), left (cos h, -sin h); u = forward speed, v = lateral speed (+ left),
// r = yaw rate (+ = turning left = heading increasing).  Position (x, z) is the centre of gravity.

struct VehicleControls {
    var throttle: Float = 0
    var brake: Float = 0
    var steer: Float = 0            // -1 ... 1, + = left
    var handbrake: Bool = false
}

struct VehicleAssists {
    var tractionControl: Bool = true
    var absEnabled: Bool = true
    var stability: Float = 0.5      // 0 off ... 1 strong
}

final class VehiclePhysics {
    static let gravity: Float = 9.81
    static let rpmToRad: Float = 0.10471976
    static let radToRpm: Float = 9.5492966

    // normalised torque curve versus rpm / redline
    static let curveF: [Float] = [0.098, 0.217, 0.380, 0.543, 0.685, 0.815, 0.924, 0.978, 1.020]
    static let curveT: [Float] = [0.42, 0.58, 0.78, 0.93, 1.00, 0.99, 0.90, 0.74, 0.40]

    static func torqueNorm(_ f: Float) -> Float {
        if f <= curveF[0] { return curveT[0] }
        for i in 1..<curveF.count {
            if f <= curveF[i] {
                let span: Float = curveF[i] - curveF[i - 1]
                let t: Float = (f - curveF[i - 1]) / max(span, 1e-5)
                return lerpf(curveT[i - 1], curveT[i], t)
            }
        }
        return 0.4
    }

    // MARK: parameters
    var mass: Float = 1300
    var wheelbase: Float = 2.516
    var distFront: Float = 1.384        // CG -> front axle
    var distRear: Float = 1.132         // CG -> rear axle
    var cgHeight: Float = 0.42
    var yawInertia: Float = 2350
    var cdA: Float = 0.95
    var clA: Float = 2.8
    var airDensity: Float = 1.2
    var tyreMu: Float = 1.5
    var wheelRadius: Float = 0.352
    var idleRPM: Float = 1100
    var redlineRPM: Float = 8800
    var torqueScale: Float = 528
    var gearTotals: [Float] = [10.8, 7.35, 5.8, 4.85, 4.2, 3.75]
    var assists: VehicleAssists = VehicleAssists()
    var damage: Float = 0
    var muScale: Float = 1
    var extraDrag: Float = 0
    var allowReverse: Bool = true
    var topSpeedDesign: Float = 86

    // MARK: state
    var x: Float = 0
    var z: Float = 0
    var heading: Float = 0
    var u: Float = 0
    var v: Float = 0
    var r: Float = 0
    var ax: Float = 0
    var ay: Float = 0
    var steerIn: Float = 0
    var delta: Float = 0
    var gear: Int = 1
    var reverse: Bool = false
    var rpm: Float = 1100
    var shiftTimer: Float = 0
    var manualHold: Float = 0
    var pendingShift: Int = 0
    var rearSpin: Float = 0
    var slipF: Float = 0
    var slipR: Float = 0
    var absActive: Bool = false
    var tcActive: Bool = false
    var frontLocked: Bool = false
    var phaseFront: Float = 0
    var phaseRear: Float = 0
    var throttleApplied: Float = 0
    var brakeApplied: Float = 0

    init() {}

    // MARK: configuration

    /// Engine, tyres and wing -> physical parameters.  Peak power matches the spec; gears give the design top speed.
    func configure(spec: EngineSpec, tyre: TyreCompound, wing: Int, wheelRadius wr: Float, distFront a: Float, distRear b: Float) {
        mass = spec.massKg
        wheelRadius = max(0.25, wr)
        distFront = a
        distRear = b
        wheelbase = a + b
        yawInertia = mass * 1.81
        tyreMu = tyre.grip
        idleRPM = spec.idle
        redlineRPM = spec.redline
        let w: Int = max(0, min(2, wing))
        let clTable: [Float] = [1.5, 2.8, 4.4]
        let cdTable: [Float] = [0.86, 0.95, 1.12]
        clA = clTable[w]
        cdA = cdTable[w]

        var peak: Float = 0.1
        var f: Float = 0.2
        while f <= 1.0 {
            let p: Float = VehiclePhysics.torqueNorm(f) * f
            if p > peak { peak = p }
            f += 0.01
        }
        let pNorm: Float = peak * spec.redline * VehiclePhysics.rpmToRad
        torqueScale = spec.powerKW * 1000 / max(pNorm, 1)

        var vtopKmh: Float = 310
        switch spec.type {
        case .v6: vtopKmh = 280
        case .v8: vtopKmh = 310
        case .v10: vtopKmh = 330
        case .v12: vtopKmh = 350
        case .v16: vtopKmh = 390
        }
        let vtop: Float = vtopKmh / 3.6
        topSpeedDesign = vtop
        let omegaRed: Float = spec.redline * VehiclePhysics.rpmToRad
        let total6: Float = omegaRed * wheelRadius / (vtop * 1.03)
        let span: Float = 2.9
        var gt: [Float] = []
        for i in 1...6 {
            let frac: Float = Float(6 - i) / 5.0
            let e: Float = powf(frac, 1.4)
            gt.append(total6 * powf(span, e))
        }
        gearTotals = gt
        if gear < 1 || gear > 6 { gear = 1 }
    }

    func reset(x nx: Float, z nz: Float, heading h: Float) {
        x = nx
        z = nz
        heading = h
        u = 0
        v = 0
        r = 0
        ax = 0
        ay = 0
        steerIn = 0
        delta = 0
        gear = 1
        reverse = false
        rpm = idleRPM
        shiftTimer = 0
        rearSpin = 0
        slipF = 0
        slipR = 0
        absActive = false
        tcActive = false
        frontLocked = false
    }

    var isValid: Bool {
        return x.isFinite && z.isFinite && heading.isFinite && u.isFinite && v.isFinite && r.isFinite && rpm.isFinite
    }

    var forward2: Vec2 { return headingForward2(heading) }
    var left2: Vec2 { return headingLeft2(heading) }

    func worldVelocity() -> Vec2 {
        let f: Vec2 = headingForward2(heading)
        let l: Vec2 = headingLeft2(heading)
        return f * u + l * v
    }

    func setWorldVelocity(_ w: Vec2) {
        u = simd_dot(w, headingForward2(heading))
        v = simd_dot(w, headingLeft2(heading))
    }

    func steerLimit(_ speed: Float) -> Float {
        let s: Float = speed / 20
        return max(0.03, 0.56 / (1 + s * s))
    }

    func requestShift(_ d: Int) {
        pendingShift = d
        manualHold = 4.0
    }

    // MARK: parked / held: brakes to a stop, no drift

    func stepHold(_ dt: Float, decel: Float) {
        let du: Float = min(abs(u), decel * dt)
        if u > 0 { u -= du } else { u += du }
        let k: Float = expf(-6 * dt)
        v *= k
        r *= k
        steerIn *= expf(-5 * dt)
        if abs(u) < 0.03 { u = 0 }
        if abs(v) < 0.03 { v = 0 }
        if abs(r) < 0.01 { r = 0 }
        rpm = damp(rpm, idleRPM, 6, dt)
        rearSpin = 0
        slipF = 0
        slipR = 0
        absActive = false
        tcActive = false
        ax = 0
        ay = 0
        if u != 0 || v != 0 || r != 0 { integrate(dt) }
    }

    var isAtRest: Bool { return u == 0 && v == 0 && r == 0 }

    private func integrate(_ dt: Float) {
        heading = wrapAngle(heading + r * dt)
        let s: Float = sinf(heading)
        let c: Float = cosf(heading)
        x += (u * s + v * c) * dt
        z += (u * c - v * s) * dt
        phaseFront = (phaseFront + (u / wheelRadius) * dt).truncatingRemainder(dividingBy: Float.tau)
        phaseRear = (phaseRear + (u / wheelRadius) * dt * (1 + 0.35 * rearSpin)).truncatingRemainder(dividingBy: Float.tau)
    }

    // MARK: one fixed sub-step

    func step(_ dt: Float, controls c: VehicleControls) {
        let m: Float = mass
        let a: Float = distFront
        let b: Float = distRear
        let L: Float = wheelbase
        let g: Float = VehiclePhysics.gravity
        let throttle: Float = clampf(c.throttle, 0, 1)
        var brake: Float = clampf(c.brake, 0, 1)
        let steerCmd: Float = clampf(c.steer, -1, 1)
        let handbrake: Bool = c.handbrake
        let u0: Float = u
        let v0: Float = v
        let r0: Float = r
        let sgn: Float = u0 >= 0 ? 1 : -1

        // driver steering smoothing
        var rate: Float = 6.5
        if abs(steerCmd) < abs(steerIn) && steerCmd * steerIn >= 0 { rate = 8.5 }
        rate /= (1 + abs(u0) / 70)
        steerIn += clampf(steerCmd - steerIn, -rate * dt, rate * dt)
        let dlt: Float = steerIn * steerLimit(u0)
        delta = dlt
        let cd: Float = cosf(dlt)
        let sd: Float = sinf(dlt)

        // aerodynamics and axle loads
        let q: Float = 0.5 * airDensity * u0 * u0
        let down: Float = clA * q
        let drag: Float = cdA * q * sgn
        let dW: Float = m * ax * cgHeight / L
        let staticF: Float = m * g * b / L
        let staticR: Float = m * g * a / L
        let Wf: Float = clampf(staticF - dW + 0.42 * down, 0.18 * staticF, 9e5)
        let Wr: Float = clampf(staticR + dW + 0.58 * down, 0.18 * staticR, 9e5)
        let mu: Float = tyreMu * muScale
        let muR: Float = mu * (handbrake ? 0.45 : 1.0)

        // gearbox / engine
        reverse = false
        gear = max(1, min(6, gear))
        var total: Float = gearTotals[gear - 1]
        let rpmWheel: Float = abs(u0) / wheelRadius * total * VehiclePhysics.radToRpm
        let launchW: Float = clampf(1 - abs(u0) / 12, 0, 1)
        var launch: Float = idleRPM
        if gear == 1 { launch = idleRPM + throttle * 0.5 * (redlineRPM - idleRPM) * launchW }
        rpm = clampf(max(rpmWheel, launch), idleRPM, redlineRPM + 250)
        shiftTimer = max(0, shiftTimer - dt)
        manualHold = max(0, manualHold - dt)
        if manualHold <= 0 {
            if shiftTimer <= 0 {
                let upThr: Float = redlineRPM * (0.66 + 0.28 * throttle)
                if rpm > upThr && gear < 6 && throttle > 0.1 {
                    gear += 1
                    shiftTimer = 0.16
                } else if gear > 1 {
                    let ratio: Float = gearTotals[gear - 2] / total
                    let rpmAfter: Float = rpmWheel * ratio
                    let downThr: Float = redlineRPM * (0.32 + 0.2 * throttle)
                    let kick: Bool = throttle > 0.85 && rpm < redlineRPM * 0.5 && rpmAfter < redlineRPM * 0.9
                    if (rpmAfter < redlineRPM * 0.88 && rpm < downThr) || kick {
                        gear -= 1
                        shiftTimer = 0.12
                    }
                }
            }
        } else if pendingShift != 0 && shiftTimer <= 0 {
            let ng: Int = max(1, min(6, gear + pendingShift))
            if ng != gear {
                gear = ng
                shiftTimer = 0.14
            }
        }
        pendingShift = 0
        total = gearTotals[gear - 1]
        let engineOn: Bool = shiftTimer <= 0 && rpm < redlineRPM
        let health: Float = 1 - 0.3 * clampf(damage, 0, 1)
        var T: Float = 0
        if engineOn { T = torqueScale * VehiclePhysics.torqueNorm(rpm / redlineRPM) * throttle * health }
        var Fdrive: Float = T * total * 0.92 / wheelRadius
        if throttle < 0.05 && abs(u0) > 1.0 {
            let ebrake: Float = 0.05 * torqueScale * total / wheelRadius * min(1, rpm / (0.9 * redlineRPM))
            Fdrive = -ebrake * sgn
        }
        if allowReverse && brake > 0.05 && throttle < 0.05 && u0 < 1.0 {
            reverse = true
            if u0 > -12 { Fdrive = -brake * 5.8 * m } else { Fdrive = 0 }
            brake = 0
        } else if throttle > 0.05 && brake < 0.05 && u0 < -0.5 {
            brake = throttle
            Fdrive = 0
        }
        if !allowReverse && u0 < 0.3 && Fdrive < 0 { Fdrive = 0 }

        // traction limit at the driven (rear) axle
        let FmaxR: Float = muR * Wr
        rearSpin = 0
        tcActive = false
        var tc: Float = assists.tractionControl ? 0.78 : 0.98
        if handbrake { tc = 1.0 }
        if abs(Fdrive) > FmaxR * tc {
            rearSpin = clampf(abs(Fdrive) / (FmaxR * tc + 1e-6) - 1.0, 0, 1)
            if assists.tractionControl && !handbrake && rearSpin > 0.02 { tcActive = true }
            Fdrive = (Fdrive >= 0 ? 1 : -1) * FmaxR * tc
        }

        // brakes (axle level ABS)
        let Fb: Float = brake * 1.10 * m * g * (1 + 0.25 * min(1, down / (m * g)))
        let limF: Float = mu * Wf * 0.97
        var Fbf: Float = 0.60 * Fb
        frontLocked = false
        absActive = false
        if Fbf > limF {
            if assists.absEnabled {
                Fbf = limF
                absActive = brake > 0.3
            } else {
                Fbf = limF * 0.85
                frontLocked = abs(u0) > 3
            }
        }
        var Fbr: Float = 0.40 * Fb
        if handbrake { Fbr += 5.5 * m }
        let limR: Float = handbrake ? muR * Wr * 0.85 : muR * Wr * 0.97
        if Fbr > limR { Fbr = limR }
        let Fxf0: Float = -Fbf * sgn
        let Fxr: Float = Fdrive - Fbr * sgn

        // tyre lateral forces (slip angle model with friction circle)
        let ux: Float = max(abs(u0), 3.0)
        let vf: Float = v0 + a * r0
        let vr: Float = v0 - b * r0
        let vlatF: Float = vf * cd - u0 * sd
        let vlonF: Float = u0 * cd + vf * sd
        let af: Float = atan2f(vlatF, max(abs(vlonF), 3.0))
        let ar: Float = atan2f(vr, ux)
        slipF = af
        slipR = ar
        let fyfCap: Float = max(mu * Wf * mu * Wf - Fxf0 * Fxf0, 0.0144 * mu * Wf * mu * Wf)
        let fyrCap: Float = max(muR * Wr * muR * Wr - Fxr * Fxr, 0.0144 * muR * Wr * muR * Wr)
        var FyfMax: Float = sqrtf(fyfCap)
        let FyrMax: Float = sqrtf(fyrCap)
        if frontLocked { FyfMax *= 0.35 }
        var FyfW: Float = -FyfMax * VehiclePhysics.tyreShape(af)
        var Fyr: Float = -FyrMax * VehiclePhysics.tyreShape(ar)
        let low: Float = clampf(abs(u0) / 1.2, 0, 1)
        FyfW *= low
        Fyr *= low
        let Fyf: Float = FyfW * cd
        let Fxf: Float = Fxf0 - FyfW * sd

        // rigid body
        let rolling: Float = 0.014 * m * g * tanhf(u0 / 0.6)
        let extra: Float = extraDrag * m * tanhf(u0 / 1.0)
        let Fx: Float = Fxf + Fxr - drag - rolling - extra
        let Fy: Float = Fyf + Fyr
        var Mz: Float = a * Fyf - b * Fyr - 1400 * r0
        if abs(u0) > 8.0 && assists.stability > 0.001 {
            let rTarget: Float = u0 * tanf(dlt) / L
            let err: Float = clampf(r0 - rTarget, -1.2, 1.2)
            let gain: Float = 2.6 * clampf(assists.stability * 2, 0, 2) * (handbrake ? 0.5 : 1.0)
            Mz += -yawInertia * gain * err
        }
        let du: Float = Fx / m + v0 * r0
        let dv: Float = Fy / m - u0 * r0
        let dr: Float = Mz / yawInertia
        ax = damp(ax, du - v0 * r0, 40, dt)
        ay = damp(ay, dv + u0 * r0, 40, dt)
        if throttle < 0.05 && brake > 0.05 && !reverse && abs(u0) < 0.6 && abs(du) * dt > abs(u0) {
            u = 0
        } else {
            u = u0 + du * dt
        }
        v = v0 + dv * dt
        r = r0 + dr * dt
        u = clampf(u, -40, 150)
        v = clampf(v, -35, 35)
        r = clampf(r, -8, 8)
        throttleApplied = throttle
        brakeApplied = brake
        integrate(dt)
    }

    static func tyreShape(_ alpha: Float) -> Float {
        let a0: Float = 0.075
        let xx: Float = alpha / a0
        let base: Float = tanhf(xx)
        let aa: Float = abs(alpha)
        let fall: Float = 1.0 - 0.32 * clampf((aa - 0.14) / 0.30, 0, 1)
        return base * fall
    }
}
