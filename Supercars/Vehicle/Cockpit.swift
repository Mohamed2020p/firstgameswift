import Foundation
import SceneKit
import simd

// MARK: - Interior helpers: the steering wheel turns with the player's input, hands/eyes/hips/pedals in world space.

@MainActor
final class CockpitRig {
    /// radians, + = left turn (what the driver's hands have turned the wheel to right now)
    private(set) var wheelAngle: Float = 0

    private var wheelNode: SCNNode? = nil
    private var wheelRest: simd_quatf = simd_quatf(angle: 0, axis: Vec3(0, 1, 0))
    private var wheelSign: Float = 1
    private var eyeAnchor: SCNNode? = nil
    private var hipAnchor: SCNNode? = nil
    private var hubAnchor: SCNNode? = nil
    private var throttleAnchor: SCNNode? = nil
    private var brakeAnchor: SCNNode? = nil
    private var gripL: Vec3 = Vec3(0.17, 0, 0)
    private var gripR: Vec3 = Vec3(-0.17, 0, 0)
    private var throttlePress: Float = 0
    private var brakePress: Float = 0
    private var smoothed: Float = 0

    init() {}

    /// Called by PlayerCar.build().  Anchors move with the body (pitch / roll).
    func configure(eye: SCNNode?, hip: SCNNode?, hub: SCNNode?, throttle: SCNNode?, brake: SCNNode?,
                   wheel: SCNNode?, gripLeft: Vec3, gripRight: Vec3, wheelSign sign: Float) {
        eyeAnchor = eye
        hipAnchor = hip
        hubAnchor = hub
        throttleAnchor = throttle
        brakeAnchor = brake
        wheelNode = wheel
        if let w = wheel { wheelRest = w.simdOrientation }
        gripL = gripLeft
        gripR = gripRight
        wheelSign = sign
    }

    /// input: steering -1...1 (+ = left), speed m/s.  Rotates `steering_wheel` about its local Z (about ±450 degrees at full lock,
    /// less at speed so it matches the small road-wheel angles).
    func update(steerInput: Float, speed: Float, throttle: Float, brake: Float, dt: Float) {
        let sf: Float = clampf(abs(speed) / 70, 0, 1)
        let lock: Float = 7.85 * (0.45 + 0.55 * (1 - sf))
        let target: Float = clampf(steerInput, -1, 1) * lock
        smoothed = damp(smoothed, target, 16, dt)
        wheelAngle = smoothed
        if let w = wheelNode {
            let q: simd_quatf = simd_quatf(angle: wheelSign * wheelAngle, axis: Vec3(0, 0, 1))
            w.simdOrientation = wheelRest * q
        }
        throttlePress = throttle
        brakePress = brake
    }

    func resetWheel() {
        smoothed = 0
        wheelAngle = 0
        if let w = wheelNode { w.simdOrientation = wheelRest }
    }

    var seatHipWorld: Vec3 {
        if let a = hipAnchor { return a.simdWorldPosition }
        return Vec3(0, 0, 0)
    }

    var eyeWorld: Vec3 {
        if let a = eyeAnchor { return a.simdWorldPosition }
        return Vec3(0, 0, 0)
    }

    /// forward / up direction of the interior frame (includes body pitch and roll)
    var forwardWorld: Vec3 {
        if let a = eyeAnchor { return a.simdConvertVector(Vec3(0, 0, 1), to: nil).normalizedSafe }
        return Vec3(0, 0, 1)
    }

    var upWorld: Vec3 {
        if let a = eyeAnchor { return a.simdConvertVector(Vec3(0, 1, 0), to: nil).normalizedSafe }
        return Vec3(0, 1, 0)
    }

    /// hand contact points on the rim: the meta grip points (wheel local space) transformed by the wheel's CURRENT transform
    func gripPointsWorld() -> (left: Vec3, right: Vec3) {
        if let w = wheelNode {
            let l: Vec3 = w.simdConvertPosition(gripL, to: nil)
            let r: Vec3 = w.simdConvertPosition(gripR, to: nil)
            return (l, r)
        }
        if let h = hubAnchor {
            let l: Vec3 = h.simdConvertPosition(gripL, to: nil)
            let r: Vec3 = h.simdConvertPosition(gripR, to: nil)
            return (l, r)
        }
        return (Vec3(0, 0, 0), Vec3(0, 0, 0))
    }

    func pedalPointsWorld() -> (throttle: Vec3, brake: Vec3) {
        var t: Vec3 = Vec3(0, 0, 0)
        var b: Vec3 = Vec3(0, 0, 0)
        if let a = throttleAnchor { t = a.simdConvertPosition(Vec3(0, -0.02 * throttlePress, -0.06 * throttlePress), to: nil) }
        if let a = brakeAnchor { b = a.simdConvertPosition(Vec3(0, -0.02 * brakePress, -0.06 * brakePress), to: nil) }
        return (t, b)
    }
}
