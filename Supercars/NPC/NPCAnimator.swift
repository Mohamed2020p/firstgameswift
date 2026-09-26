import Foundation
import SceneKit
import simd

// MARK: - NPCAnimator: procedural animation state machine on top of WPoseSolver (the source characters ship no animation clips, so the
// Mixamo-named skeleton is posed directly).  Speed and animation cannot disagree: the gait phase advances by
// `speed / strideLength` every frame and the planted foot travels backwards at exactly the body speed, so there is no skating.
//
// Layers:  idle (breathing, weight shift, personal phase)  ->  gesture overlay (look, phone, talk, react ...)
//          locomotion (walk / fast walk / jog blend, foot roll, arm swing, torso counter rotation)  ->  sit / enter / exit.

enum NPCGesture {
    case none, lookLeft, lookRight, lookAround, checkPhone, checkWatch, talk, waitAtCurb, startled, stumble, wave
}

@MainActor
final class NPCAnimator {
    let solver: WPoseSolver

    // personal variation
    private let phaseOffset: Float
    private let strideScale: Float
    private let swingScale: Float

    // state
    private var time: Float
    private var gaitPhase: Float = 0
    private var locoBlend: Float = 0
    private var stepIndex: Int = 0
    private var shift: Float = 0                   // weight shift -1 ... 1 (smoothed)
    private var shiftTarget: Float = 0
    private var lookYaw: Float = 0                 // head turn toward a point of interest (smoothed, radians)
    private var poseSmooth: WPoseParams? = nil

    /// called when a foot lands (footsteps)
    var onFootstep: (() -> Void)? = nil

    init?(model: SCNNode, seed: UInt64) {
        guard let s = WPoseSolver(model: model) else { return nil }
        solver = s
        var rng = SeededRNG(seed: seed)
        phaseOffset = rng.float(0, 6.28)
        strideScale = rng.float(0.94, 1.06)
        swingScale = rng.float(0.85, 1.15)
        time = rng.float(0, 30)
        shift = rng.float(-1, 1)
        shiftTarget = shift
    }

    // MARK: idle

    private func idleParams(_ t: Float) -> WPoseParams {
        let sv: WPoseSolver = solver
        var p = WPoseParams()
        let ph: Float = t + phaseOffset
        let breathe: Float = sinf(ph * 1.7)
        let sw: Float = shift
        p.spinePitch = 0.012 * breathe
        p.spineRoll = 0.02 * sw
        p.headYaw = 0.05 * sinf(ph * 0.45)
        p.headPitch = 0.02 * sinf(ph * 0.7)
        p.hipsOffset = Vec3(0.03 * sw, -0.006 * (1 + breathe) - 0.012 * abs(sw), 0)
        p.hipsRoll = -0.035 * sw
        // the unloaded leg relaxes forward / outward, the loaded leg stays under the hip
        let loadedLeft: Float = max(0, sw)
        let loadedRight: Float = max(0, -sw)
        p.leftFoot = Vec3(0.10 + 0.03 * loadedRight, sv.restAnkleHeight + 0.004 * loadedRight, -0.03 + 0.09 * loadedRight)
        p.rightFoot = Vec3(-0.10 - 0.03 * loadedLeft, sv.restAnkleHeight + 0.004 * loadedLeft, -0.03 + 0.09 * loadedLeft)
        p.leftFootPitch = 0.05 * loadedRight
        p.rightFootPitch = 0.05 * loadedLeft
        p.leftHand = Vec3(0.27, 1.01 + 0.004 * breathe, 0.03)
        p.rightHand = Vec3(-0.27, 1.01 + 0.004 * breathe, 0.03)
        p.leftElbowPole = Vec3(0.5, -0.2, -0.8)
        p.rightElbowPole = Vec3(-0.5, -0.2, -0.8)
        p.fingerCurl = 0.3
        p.thumbCurl = 0.15
        return p
    }

    /// bell-shaped envelope 0 -> 1 -> 0 over gesture time g in 0...1 (with flat top)
    private func envelope(_ g: Float, rise: Float = 0.18, fall: Float = 0.82) -> Float {
        return smoothstep(0, rise, g) * (1 - smoothstep(fall, 1, g))
    }

    private func applyGesture(_ p: inout WPoseParams, gesture: NPCGesture, g: Float) {
        let e: Float = envelope(g)
        switch gesture {
        case .none:
            break
        case .lookLeft:
            p.headYaw += 0.95 * e
            p.spineYaw += 0.30 * e
        case .lookRight:
            p.headYaw -= 0.95 * e
            p.spineYaw -= 0.30 * e
        case .lookAround, .waitAtCurb:
            let sweep: Float = sinf(g * Float.tau * 1.15)
            p.headYaw += 0.85 * sweep * envelope(g, rise: 0.1, fall: 0.9)
            p.spineYaw += 0.22 * sweep * e
            p.headPitch += 0.03 * e
        case .checkPhone:
            // right hand up in front of the chest, head tilted down, thumb busy
            let up: Float = smoothstep(0, 0.16, g) * (1 - smoothstep(0.86, 1, g))
            let tap: Float = sinf(g * Float.tau * 5) * 0.012
            p.rightHand = Vec3(-0.10, lerpf(1.01, 1.27, up) + tap, lerpf(0.03, 0.30, up))
            p.rightElbowPole = Vec3(-0.5, -0.4, -0.7)
            p.leftHand = Vec3(0.20, lerpf(1.01, 1.02, up), lerpf(0.03, 0.10, up))
            p.headPitch += 0.42 * up
            p.spinePitch += 0.05 * up
            p.rightHandRoll = -0.7 * up
            p.fingerCurl = 0.3 + 0.3 * up
        case .checkWatch:
            let up: Float = smoothstep(0, 0.2, g) * (1 - smoothstep(0.8, 1, g))
            p.leftHand = Vec3(lerpf(0.27, 0.12, up), lerpf(1.01, 1.24, up), lerpf(0.03, 0.30, up))
            p.leftElbowPole = Vec3(0.4, -0.4, -0.7)
            p.headPitch += 0.28 * up
            p.headYaw -= 0.12 * up
        case .talk:
            let a: Float = g * Float.tau
            p.rightHand = Vec3(-0.26 + 0.05 * sinf(a * 3.1), 1.12 + 0.07 * sinf(a * 2.3 + 1), 0.28 + 0.06 * sinf(a * 3.7))
            p.leftHand = Vec3(0.26 + 0.04 * sinf(a * 2.7 + 2), 1.08 + 0.05 * sinf(a * 2.9), 0.22 + 0.05 * sinf(a * 3.3 + 1))
            p.rightElbowPole = Vec3(-0.7, -0.2, -0.5)
            p.leftElbowPole = Vec3(0.7, -0.2, -0.5)
            p.headPitch += 0.05 * sinf(a * 4) * e
            p.headYaw += 0.10 * sinf(a * 1.3) * e
            p.spineYaw += 0.06 * sinf(a * 1.7) * e
        case .startled:
            p.spinePitch -= 0.16 * e
            p.hipsPitch -= 0.08 * e
            p.leftHand = Vec3(lerpf(0.27, 0.30, e), lerpf(1.01, 1.34, e), lerpf(0.03, 0.22, e))
            p.rightHand = Vec3(lerpf(-0.27, -0.30, e), lerpf(1.01, 1.34, e), lerpf(0.03, 0.22, e))
            p.leftElbowPole = Vec3(0.6, 0.2, -0.4)
            p.rightElbowPole = Vec3(-0.6, 0.2, -0.4)
            p.headPitch -= 0.10 * e
            p.fingerCurl = 0.1
        case .stumble:
            let s: Float = sinf(g * Float.pi)
            p.spinePitch += 0.22 * s
            p.spineRoll += 0.16 * sinf(g * Float.tau)
            p.hipsPitch += 0.10 * s
            p.leftHand = Vec3(0.55 * s + 0.27 * (1 - s), 1.15 * s + 1.01 * (1 - s), 0.05)
            p.rightHand = Vec3(-0.55 * s - 0.27 * (1 - s), 1.10 * s + 1.01 * (1 - s), 0.05)
            p.leftElbowPole = Vec3(0.8, 0.1, -0.2)
            p.rightElbowPole = Vec3(-0.8, 0.1, -0.2)
        case .wave:
            let a: Float = g * Float.tau * 3
            p.rightHand = Vec3(-0.30 + 0.05 * sinf(a), 1.65, 0.12)
            p.rightElbowPole = Vec3(-0.8, -0.3, -0.2)
            p.headYaw -= 0.12 * e
        }
    }

    // MARK: locomotion

    private func locomotionParams(speed: Float, dt: Float, traits: NPCTraits, turnRate: Float) -> WPoseParams {
        let sv: WPoseSolver = solver
        let strideLen: Float = clampf((0.95 + 0.42 * speed) * strideScale, 0.9, 3.5)
        if speed > 0.1 {
            gaitPhase += (speed / strideLen) * dt
            gaitPhase -= floorf(gaitPhase)
        }
        let run: Float = smoothstep(2.4, 4.6, speed)
        let amp: Float = strideLen * 0.25
        let stepH: Float = lerpf(0.085, 0.24, run)
        let ankle: Float = sv.restAnkleHeight
        let legLen: Float = (sv.thigh + sv.shin) * 0.975
        let hipY: Float = sv.restHipsPos.y
        let neededDrop: Float = max(0, (hipY - ankle) - sqrtf(max(0, legLen * legLen - amp * amp)))
        let bob: Float = 0.02 * (0.5 - 0.5 * cosf(gaitPhase * Float.tau * 2)) * (0.6 + run)
        let drop: Float = neededDrop + 0.012 * (1 - run) + bob * 0.4
        let cyc: Float = gaitPhase * Float.tau

        var p = WPoseParams()
        let sway: Float = sinf(cyc) * 0.02 * (1 - 0.5 * run)
        p.hipsOffset = Vec3(sway, -drop, 0)
        p.hipsPitch = 0.035 + run * 0.20
        p.hipsRoll = -sinf(cyc) * 0.045
        let twist: Float = sinf(cyc) * (0.11 + 0.12 * run)
        p.hipsYaw = twist
        p.spineYaw = -twist * 1.6
        p.spineRoll = sinf(cyc) * 0.028
        p.spinePitch = 0.02 + run * 0.10
        p.headPitch = -(0.04 + run * 0.20)
        p.headYaw = twist * 0.6
        let turnLean: Float = clampf(-turnRate * 0.05, -0.14, 0.14) * clampf(speed / 3, 0, 1)
        p.hipsRoll += turnLean
        p.spineRoll += turnLean * 0.6

        for side in 0..<2 {
            let left: Bool = side == 0
            let ph: Float = (gaitPhase + (left ? 0 : 0.5)).truncatingRemainder(dividingBy: 1)
            var z: Float = 0
            var lift: Float = 0
            if ph < 0.5 {
                z = lerpf(amp, -amp, ph / 0.5)                       // stance: the foot travels back at body speed
            } else {
                let u: Float = (ph - 0.5) / 0.5
                z = lerpf(-amp, amp, smoothstep(0, 1, u))            // swing
                lift = powf(sinf(u * Float.pi), 0.8)
            }
            var pitch: Float = 0
            if ph < 0.5 {
                let u: Float = ph / 0.5
                pitch = -0.28 * (1 - smoothstep(0, 0.22, u)) + 0.70 * smoothstep(0.62, 1.0, u)
            } else {
                let u: Float = (ph - 0.5) / 0.5
                pitch = 0.55 * (1 - smoothstep(0, 0.35, u)) - 0.22 * smoothstep(0.6, 1.0, u)
            }
            let roll: Float = 0.12 * sinf(max(0, pitch)) + 0.05 * sinf(max(0, -pitch))
            let x: Float = left ? 0.095 : -0.095
            let target = Vec3(x, ankle + roll + lift * stepH, -0.03 + z)
            if left {
                p.leftFoot = target
                p.leftFootPitch = pitch
            } else {
                p.rightFoot = target
                p.rightFootPitch = pitch
            }
        }

        let swing: Float = (0.14 + 0.30 * run) * traits.armSwing * swingScale
        let handY: Float = lerpf(1.00, 1.24, run) - drop
        let handZ0: Float = lerpf(0.03, 0.26, run)
        let handX: Float = lerpf(0.29, 0.25, run)
        let sL: Float = -sinf(cyc)
        let sR: Float = sinf(cyc)
        p.leftHand = Vec3(handX, handY + max(0, sL) * 0.06 * run, handZ0 + sL * swing)
        p.rightHand = Vec3(-handX, handY + max(0, sR) * 0.06 * run, handZ0 + sR * swing)
        p.leftElbowPole = Vec3(0.55, -0.15, -0.9)
        p.rightElbowPole = Vec3(-0.55, -0.15, -0.9)
        p.fingerCurl = 0.35 + 0.45 * run
        p.thumbCurl = 0.2
        return p
    }

    // MARK: sitting (inside a vehicle)

    private func seatedParams(_ sit: Float, base: WPoseParams) -> WPoseParams {
        let sv: WPoseSolver = solver
        var p = base
        let s: Float = clampf(sit, 0, 1)
        p.hipsOffset = Vec3(base.hipsOffset.x, base.hipsOffset.y - 0.50 * s, base.hipsOffset.z - 0.04 * s)
        p.spinePitch = base.spinePitch + 0.03 * s
        let ankle: Float = sv.restAnkleHeight
        let f: Float = 0.42 * s
        p.leftFoot = Vec3(0.13, ankle, -0.03 + f)
        p.rightFoot = Vec3(-0.13, ankle, -0.03 + f)
        p.leftKneePole = Vec3(0.1, 0.6, 1)
        p.rightKneePole = Vec3(-0.1, 0.6, 1)
        p.leftHand = Vec3(0.22, lerpf(1.01, 0.70, s), lerpf(0.03, 0.26, s))
        p.rightHand = Vec3(-0.22, lerpf(1.01, 0.70, s), lerpf(0.03, 0.26, s))
        return p
    }

    // MARK: main entry

    /// weight shift target (-1 ... 1); the brain calls this every few seconds while a pedestrian stands
    func setWeightShift(_ v: Float) { shiftTarget = clampf(v, -1, 1) }

    /// - speed: world speed of the body (m/s); turnInPlace: -1 ... 1 (sign = direction) while the body rotates on the spot;
    /// - lookAt: head yaw relative to the body toward something interesting (0 = none)
    func update(dt: Float, speed: Float, turnRate: Float, turnInPlace: Float, gesture: NPCGesture, gestureProgress: Float, lookAt: Float,
                sit: Float, traits: NPCTraits) {
        time += dt
        shift = damp(shift, shiftTarget, 1.2, dt)
        lookYaw = damp(lookYaw, lookAt, 5, dt)

        var effSpeed: Float = speed
        if abs(turnInPlace) > 0.05 && speed < 0.3 { effSpeed = 0.5 }
        let moving: Bool = effSpeed > 0.1
        locoBlend = damp(locoBlend, moving ? 1 : 0, 8, max(dt, 0.0001))

        var idle: WPoseParams = idleParams(time)
        applyGesture(&idle, gesture: gesture, g: gestureProgress)
        idle.headYaw += lookYaw

        var out: WPoseParams = idle
        if locoBlend > 0.01 {
            var loco: WPoseParams = locomotionParams(speed: effSpeed, dt: dt, traits: traits, turnRate: turnRate)
            loco.headYaw += lookYaw
            // while walking only the head-turning gestures stay visible (hands belong to the arm swing)
            if gesture == NPCGesture.lookLeft || gesture == NPCGesture.lookRight || gesture == NPCGesture.lookAround {
                loco.headYaw += 0.6 * (idle.headYaw - 0.05 * sinf((time + phaseOffset) * 0.45) - lookYaw)
            }
            out = locoBlend > 0.99 ? loco : idle.blended(with: loco, t: smoothstep(0, 1, locoBlend))
            let half: Int = Int(floorf(gaitPhase * 2))
            if half != stepIndex {
                stepIndex = half
                if effSpeed > 0.3 { onFootstep?() }
            }
        }
        if sit > 0.001 { out = seatedParams(sit, base: out) }

        // light temporal smoothing of the final pose removes any residual pops when states change
        if let prev = poseSmooth {
            let k: Float = 1 - expf(-36 * max(dt, 0.0001))
            out = prev.blended(with: out, t: k)
        }
        poseSmooth = out
        solver.apply(out)
    }
}
