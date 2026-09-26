import Foundation
import SceneKit
import simd
import UIKit

// MARK: - Camera ownership.  Exactly one CameraController drives the camera at a time (set by GameContext when the mode changes).

protocol CameraController: AnyObject {
    /// Called every frame while active; use rig.set(...) / rig.follow(...) to move the camera.
    func updateCamera(_ rig: CameraRig, dt: Float)
}

final class CameraRig {
    let node = SCNNode()
    let camera = SCNCamera()
    weak var controller: CameraController?

    private(set) var position = Vec3(0, 4, 10)
    private(set) var lookTarget = Vec3(0, 1, 0)
    private var shakeAmount: Float = 0
    private var shakeTime: Float = 0
    var shakeEnabled = true

    /// vertical field of view in degrees (SceneKit uses the vertical fov by default on iOS when projectionDirection = .vertical)
    var fov: Float = 62 { didSet { camera.fieldOfView = CGFloat(fov) } }

    init() {
        camera.fieldOfView = 62
        camera.zNear = 0.08
        camera.zFar = 2500
        camera.wantsHDR = true
        camera.projectionDirection = .vertical
        node.camera = camera
        node.name = "cameraRig"
    }

    /// Instantly places the camera (also used to "snap" after teleports so it can never be left far behind).
    func set(position p: Vec3, lookAt target: Vec3, up: Vec3 = Vec3(0, 1, 0)) {
        position = p
        lookTarget = target
        apply(up: up)
    }

    /// Camera *orientation* from a heading/pitch instead of a look-at target (cockpit / on-foot look)
    func set(position p: Vec3, heading: Float, pitch: Float, roll: Float = 0) {
        position = p
        // camera looks down its local -Z; euler order in SceneKit simd is X,Y,Z applied as ZYX. Build the quaternion explicitly.
        let qy = simd_quatf(angle: heading + Float.pi, axis: Vec3(0, 1, 0))
        let qx = simd_quatf(angle: pitch, axis: Vec3(1, 0, 0))
        let qz = simd_quatf(angle: roll, axis: Vec3(0, 0, 1))
        node.simdPosition = p
        node.simdOrientation = qy * qx * qz
        lookTarget = p + headingForward(heading) * 10
    }

    /// Spring-damped follow with a hard cap on how far the camera may lag behind its desired point.
    /// This is the fix for "the camera sometimes gets far from the car": the lag distance can never exceed `maxLag`.
    func follow(desired: Vec3, lookAt target: Vec3, dt: Float, stiffness: Float, maxLag: Float) {
        var p = dampVec3(position, desired, stiffness, dt)
        let off = p - desired
        let d = off.length
        if d > maxLag { p = desired + off * (maxLag / d) }
        position = p
        lookTarget = dampVec3(lookTarget, target, stiffness * 1.5, dt)
        apply(up: Vec3(0, 1, 0))
    }

    func shake(_ amount: Float) { if shakeEnabled { shakeAmount = max(shakeAmount, amount) } }

    /// called by GameContext after the controller ran
    func update(dt: Float) {
        controller?.updateCamera(self, dt: dt)
        if shakeAmount > 0.001 {
            shakeTime += dt * 47
            let s = shakeAmount
            let jitter = Vec3(sinf(shakeTime * 1.7), sinf(shakeTime * 2.3 + 1), sinf(shakeTime * 1.1 + 2)) * (0.06 * s)
            node.simdPosition = position + jitter
            shakeAmount = max(0, shakeAmount - dt * 2.4)
        } else {
            node.simdPosition = position
        }
    }

    private func apply(up: Vec3) {
        node.simdPosition = position
        node.simdLook(at: lookTarget, up: up, localFront: Vec3(0, 0, -1))
    }

    /// applies rendering options that belong to the camera (bloom, HDR, motion blur, fov scale)
    func applyGraphics(_ g: GraphicsSettings, fovScale: Float) {
        camera.wantsHDR = g.hdr
        camera.bloomIntensity = g.bloom ? 0.55 : 0
        camera.bloomThreshold = 0.85
        camera.bloomBlurRadius = 12
        camera.motionBlurIntensity = g.motionBlur ? 0.25 : 0
        camera.zFar = Double(900 + 1600 * g.drawDistance)
        shakeEnabled = g.cameraShake
        camera.fieldOfView = CGFloat(fov * fovScale)
    }
}
