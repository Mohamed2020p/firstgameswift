import Foundation
import simd

// MARK: - Pose blending (idle <-> walk <-> run transitions without pops)

extension WPoseParams {
    /// linear blend of two poses: t = 0 -> self, t = 1 -> other. Optional targets are blended only when both poses have them.
    func blended(with o: WPoseParams, t: Float) -> WPoseParams {
        var r: WPoseParams = self
        let k: Float = clampf(t, 0, 1)
        func f(_ a: Float, _ b: Float) -> Float { return a + (b - a) * k }
        func v(_ a: Vec3, _ b: Vec3) -> Vec3 { return a + (b - a) * k }
        func ov(_ a: Vec3?, _ b: Vec3?) -> Vec3? {
            if let x = a, let y = b { return x + (y - x) * k }
            return k < 0.5 ? a : b
        }
        r.hipsOffset = v(hipsOffset, o.hipsOffset)
        r.hipsPitch = f(hipsPitch, o.hipsPitch)
        r.hipsRoll = f(hipsRoll, o.hipsRoll)
        r.hipsYaw = f(hipsYaw, o.hipsYaw)
        r.spinePitch = f(spinePitch, o.spinePitch)
        r.spineRoll = f(spineRoll, o.spineRoll)
        r.spineYaw = f(spineYaw, o.spineYaw)
        r.headPitch = f(headPitch, o.headPitch)
        r.headYaw = f(headYaw, o.headYaw)
        r.headRoll = f(headRoll, o.headRoll)
        r.leftHand = ov(leftHand, o.leftHand)
        r.rightHand = ov(rightHand, o.rightHand)
        r.leftElbowPole = v(leftElbowPole, o.leftElbowPole)
        r.rightElbowPole = v(rightElbowPole, o.rightElbowPole)
        r.leftHandRoll = f(leftHandRoll, o.leftHandRoll)
        r.rightHandRoll = f(rightHandRoll, o.rightHandRoll)
        r.leftFoot = ov(leftFoot, o.leftFoot)
        r.rightFoot = ov(rightFoot, o.rightFoot)
        r.leftFootPitch = f(leftFootPitch, o.leftFootPitch)
        r.rightFootPitch = f(rightFootPitch, o.rightFootPitch)
        r.footYaw = f(footYaw, o.footYaw)
        r.leftKneePole = v(leftKneePole, o.leftKneePole)
        r.rightKneePole = v(rightKneePole, o.rightKneePole)
        r.fingerCurl = f(fingerCurl, o.fingerCurl)
        r.thumbCurl = f(thumbCurl, o.thumbCurl)
        return r
    }
}
