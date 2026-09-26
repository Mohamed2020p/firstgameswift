import Foundation
import SceneKit
import simd

// MARK: - Procedural skeleton driver for the rider avatar (68 Mixamo-named bones, T/A-pose, no animation clips).
// All poses are expressed in AVATAR SPACE (Y up, +Z forward, +X = avatar left, origin between the feet). Bones are driven by absolute
// world-space rotations ("aim this bone along that direction") so no knowledge of the bones' local axes is needed; fingers and spine use
// local deltas whose axes are derived from the rest pose.

let wIdentityQuat = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

@inline(__always) func wXYZ(_ v: Vec4) -> Vec3 { return Vec3(v.x, v.y, v.z) }

/// shortest-arc rotation taking direction a onto direction b
func wQuatFromTo(_ a: Vec3, _ b: Vec3) -> simd_quatf {
    let na: Vec3 = a.normalizedSafe
    let nb: Vec3 = b.normalizedSafe
    if simd_length(na) < 0.5 || simd_length(nb) < 0.5 { return wIdentityQuat }
    let d: Float = simd_dot(na, nb)
    if d > 0.99999 { return wIdentityQuat }
    if d < -0.99999 {
        var axis: Vec3 = simd_cross(na, Vec3(1, 0, 0))
        if simd_length(axis) < 0.1 { axis = simd_cross(na, Vec3(0, 1, 0)) }
        return simd_quatf(angle: Float.pi, axis: axis.normalizedSafe)
    }
    let axis: Vec3 = simd_cross(na, nb).normalizedSafe
    let angle: Float = acosf(clampf(d, -1, 1))
    return simd_quatf(angle: angle, axis: axis)
}

/// analytic two-bone IK. Returns the middle joint (elbow / knee) and the reached end point.
func wSolveTwoBone(root: Vec3, target: Vec3, l1: Float, l2: Float, pole: Vec3) -> (mid: Vec3, end: Vec3) {
    let d: Vec3 = target - root
    var dist: Float = simd_length(d)
    let maxReach: Float = (l1 + l2) * 0.9995
    let minReach: Float = abs(l1 - l2) + 0.02
    if dist < 1e-4 { return (root + Vec3(0, -l1, 0), root + Vec3(0, -l1 - l2, 0)) }
    let dir: Vec3 = d / dist
    dist = clampf(dist, minReach, maxReach)
    let end: Vec3 = root + dir * dist
    let a: Float = (l1 * l1 - l2 * l2 + dist * dist) / (2 * dist)
    let h: Float = sqrtf(max(0, l1 * l1 - a * a))
    var pv: Vec3 = pole - dir * simd_dot(pole, dir)
    if simd_length(pv) < 1e-3 {
        pv = Vec3(0, 0, -1) - dir * simd_dot(Vec3(0, 0, -1), dir)
        if simd_length(pv) < 1e-3 { pv = Vec3(1, 0, 0) - dir * simd_dot(Vec3(1, 0, 0), dir) }
    }
    pv = pv.normalizedSafe
    let mid: Vec3 = root + dir * a + pv * h
    return (mid, end)
}

@MainActor
final class WBone {
    let name: String
    let node: SCNNode
    weak var parent: WBone?
    var children: [WBone] = []
    var restLocalRot: simd_quatf = wIdentityQuat
    var restLocalPos: Vec3 = Vec3(0, 0, 0)
    var restWorldRot: simd_quatf = wIdentityQuat
    var restWorldPos: Vec3 = Vec3(0, 0, 0)
    var curWorldRot: simd_quatf = wIdentityQuat
    var curWorldPos: Vec3 = Vec3(0, 0, 0)
    var overrideRot: simd_quatf? = nil
    var localDelta: simd_quatf = wIdentityQuat
    var posOffset: Vec3 = Vec3(0, 0, 0)

    init(name: String, node: SCNNode) {
        self.name = name
        self.node = node
    }

    /// world direction (rest pose) from this bone to its first child
    var restDirection: Vec3 {
        guard let c = children.first else { return Vec3(0, -1, 0) }
        return (c.restWorldPos - restWorldPos).normalizedSafe
    }
}

@MainActor
final class WRig {
    let root: SCNNode
    private(set) var bones: [WBone] = []
    private var byName: [String: WBone] = [:]
    private var rootParentRot: simd_quatf = wIdentityQuat
    private var rootParentPos: Vec3 = Vec3(0, 0, 0)

    static func stripped(_ n: String) -> String {
        guard let us = n.lastIndex(of: "_") else { return n }
        let tail = n[n.index(after: us)...]
        if tail.isEmpty { return n }
        for ch in tail where !ch.isNumber { return n }
        return String(n[..<us])
    }

    init?(model: SCNNode) {
        root = model
        var nodes: [String: SCNNode] = [:]
        model.enumerateHierarchy { (n: SCNNode, _: UnsafeMutablePointer<ObjCBool>) in
            if let nm = n.name, n.geometry == nil { nodes[WRig.stripped(nm)] = n }
        }
        var startNode: SCNNode? = nodes["GLTF_created_0_rootJoint"]
        if startNode == nil, let hips = nodes["Hips"] { startNode = hips }
        guard let start = startNode, nodes["Hips"] != nil else { return nil }
        let inv: simd_float4x4 = simd_inverse(model.simdWorldTransform)
        if let p = start.parent {
            let m: simd_float4x4 = simd_mul(inv, p.simdWorldTransform)
            rootParentRot = simd_quatf(m)
            rootParentPos = wXYZ(m.columns.3)
        }
        build(node: start, parent: nil, inv: inv)
    }

    private func build(node: SCNNode, parent: WBone?, inv: simd_float4x4) {
        let name: String = WRig.stripped(node.name ?? "bone")
        let b = WBone(name: name, node: node)
        b.parent = parent
        b.restLocalRot = node.simdOrientation
        b.restLocalPos = node.simdPosition
        let m: simd_float4x4 = simd_mul(inv, node.simdWorldTransform)
        b.restWorldRot = simd_quatf(m)
        b.restWorldPos = wXYZ(m.columns.3)
        b.curWorldRot = b.restWorldRot
        b.curWorldPos = b.restWorldPos
        bones.append(b)
        byName[name] = b
        parent?.children.append(b)
        for c in node.childNodes where c.geometry == nil {
            build(node: c, parent: b, inv: inv)
        }
    }

    func bone(_ n: String) -> WBone? { return byName[n] }

    func resetPose() {
        for b in bones {
            b.overrideRot = nil
            b.localDelta = wIdentityQuat
            b.posOffset = Vec3(0, 0, 0)
        }
    }

    /// forward kinematics with the current overrides / deltas
    func solve() {
        for b in bones {
            let parentRot: simd_quatf = b.parent?.curWorldRot ?? rootParentRot
            let parentPos: Vec3 = b.parent?.curWorldPos ?? rootParentPos
            var local: simd_quatf
            if let o = b.overrideRot {
                local = parentRot.inverse * o
            } else {
                local = b.restLocalRot * b.localDelta
            }
            local = simd_normalize(local)
            let localPos: Vec3 = b.restLocalPos + b.posOffset
            b.node.simdOrientation = local
            b.node.simdPosition = localPos
            b.curWorldRot = simd_normalize(parentRot * local)
            b.curWorldPos = parentPos + parentRot.act(localPos)
        }
    }

    /// makes `bone` point (bone -> its first child) along `dir` (avatar space)
    func aim(_ bone: WBone, toward dir: Vec3) {
        let q: simd_quatf = wQuatFromTo(bone.restDirection, dir)
        bone.overrideRot = simd_normalize(q * bone.restWorldRot)
    }

    /// rotation about an avatar-space axis expressed as a delta in the bone's own frame
    func localAxisRotation(_ bone: WBone, axis: Vec3, angle: Float) -> simd_quatf {
        let a: Vec3 = bone.restWorldRot.inverse.act(axis).normalizedSafe
        return simd_quatf(angle: angle, axis: a)
    }
}

// MARK: - Pose description + application

struct WPoseParams {
    var hipsOffset: Vec3 = Vec3(0, 0, 0)
    var hipsPitch: Float = 0          // about avatar X, + = lean forward
    var hipsRoll: Float = 0           // about avatar Z
    var hipsYaw: Float = 0            // about avatar Y
    var spinePitch: Float = 0
    var spineRoll: Float = 0
    var spineYaw: Float = 0
    var headPitch: Float = 0
    var headYaw: Float = 0
    var headRoll: Float = 0

    var leftHand: Vec3? = nil         // wrist targets, avatar space
    var rightHand: Vec3? = nil
    var leftElbowPole: Vec3 = Vec3(0.6, -0.3, -0.6)
    var rightElbowPole: Vec3 = Vec3(-0.6, -0.3, -0.6)
    var leftHandRoll: Float = 0
    var rightHandRoll: Float = 0

    var leftFoot: Vec3? = nil         // ankle targets, avatar space
    var rightFoot: Vec3? = nil
    var leftFootPitch: Float = 0
    var rightFootPitch: Float = 0
    var footYaw: Float = 0
    var leftKneePole: Vec3 = Vec3(0.15, 0, 1)
    var rightKneePole: Vec3 = Vec3(-0.15, 0, 1)

    var fingerCurl: Float = 0.2       // 0 open ... 1 fist
    var thumbCurl: Float = 0.2
}

@MainActor
final class WPoseSolver {
    let rig: WRig
    private let hips: WBone
    private let spine: [WBone]
    private let neck: WBone?
    private let head: WBone?
    private var fingers: [(bone: WBone, left: Bool, index: Int, isThumb: Bool)] = []
    private var lastLeftReach: Float = 0
    private var lastRightReach: Float = 0

    let upperArm: Float
    let foreArm: Float
    let thigh: Float
    let shin: Float
    let restHipsPos: Vec3
    let restAnkleHeight: Float
    let shoulderRestLeft: Vec3

    init?(model: SCNNode) {
        guard let r = WRig(model: model) else { return nil }
        guard let h = r.bone("Hips") else { return nil }
        rig = r
        hips = h
        var sp: [WBone] = []
        for n in ["Spine", "Spine1", "Spine2"] { if let b = r.bone(n) { sp.append(b) } }
        spine = sp
        neck = r.bone("Neck")
        head = r.bone("Head")
        func dist(_ a: String, _ b: String, _ fallback: Float) -> Float {
            guard let x = r.bone(a), let y = r.bone(b) else { return fallback }
            return simd_length(y.restWorldPos - x.restWorldPos)
        }
        upperArm = dist("LeftArm", "LeftForeArm", 0.285)
        foreArm = dist("LeftForeArm", "LeftHand", 0.252)
        thigh = dist("LeftUpLeg", "LeftLeg", 0.4585)
        shin = dist("LeftLeg", "LeftFoot", 0.4417)
        restHipsPos = h.restWorldPos
        restAnkleHeight = r.bone("LeftFoot")?.restWorldPos.y ?? 0.126
        shoulderRestLeft = r.bone("LeftArm")?.restWorldPos ?? Vec3(0.166, 1.503, -0.038)
        for (side, isLeft) in [("Left", true), ("Right", false)] {
            for (fi, f) in ["Thumb", "Index", "Middle", "Ring", "Pinky"].enumerated() {
                for k in 1...3 {
                    if let b = r.bone("\(side)Hand\(f)\(k)") {
                        fingers.append((b, isLeft, k, fi == 0))
                    }
                }
            }
        }
    }

    var maxArmReach: Float { return upperArm + foreArm }

    /// world (avatar space) positions after the last apply
    func position(of name: String) -> Vec3? { return rig.bone(name)?.curWorldPos }

    /// distance shoulder -> hand target divided by the full arm length in the last applied pose (>= 1 = out of reach)
    var leftReachRatio: Float { return lastLeftReach }
    var rightReachRatio: Float { return lastRightReach }

    func apply(_ p: WPoseParams) {
        rig.resetPose()

        // ---- body
        let qy = simd_quatf(angle: p.hipsYaw, axis: Vec3(0, 1, 0))
        let qz = simd_quatf(angle: p.hipsRoll, axis: Vec3(0, 0, 1))
        let qx = simd_quatf(angle: p.hipsPitch, axis: Vec3(1, 0, 0))
        hips.overrideRot = simd_normalize(qy * qz * qx * hips.restWorldRot)
        hips.posOffset = p.hipsOffset
        let n: Float = Float(max(1, spine.count))
        for b in spine {
            let qp = rig.localAxisRotation(b, axis: Vec3(1, 0, 0), angle: p.spinePitch / n)
            let qr = rig.localAxisRotation(b, axis: Vec3(0, 0, 1), angle: p.spineRoll / n)
            let qw = rig.localAxisRotation(b, axis: Vec3(0, 1, 0), angle: p.spineYaw / n)
            b.localDelta = simd_normalize(qw * qr * qp)
        }
        if let nk = neck {
            let qp = rig.localAxisRotation(nk, axis: Vec3(1, 0, 0), angle: p.headPitch * 0.4)
            let qw = rig.localAxisRotation(nk, axis: Vec3(0, 1, 0), angle: p.headYaw * 0.4)
            let qr = rig.localAxisRotation(nk, axis: Vec3(0, 0, 1), angle: p.headRoll * 0.4)
            nk.localDelta = simd_normalize(qw * qr * qp)
        }
        if let hd = head {
            let qp = rig.localAxisRotation(hd, axis: Vec3(1, 0, 0), angle: p.headPitch * 0.6)
            let qw = rig.localAxisRotation(hd, axis: Vec3(0, 1, 0), angle: p.headYaw * 0.6)
            let qr = rig.localAxisRotation(hd, axis: Vec3(0, 0, 1), angle: p.headRoll * 0.6)
            hd.localDelta = simd_normalize(qw * qr * qp)
        }
        rig.solve()

        // ---- arms and legs (IK reads the joint positions produced by the body pass)
        lastLeftReach = 0
        lastRightReach = 0
        if let t = p.leftHand { lastLeftReach = applyArm(left: true, target: t, pole: p.leftElbowPole, roll: p.leftHandRoll) }
        if let t = p.rightHand { lastRightReach = applyArm(left: false, target: t, pole: p.rightElbowPole, roll: p.rightHandRoll) }
        if let t = p.leftFoot { applyLeg(left: true, target: t, pole: p.leftKneePole, pitch: p.leftFootPitch, yaw: p.footYaw) }
        if let t = p.rightFoot { applyLeg(left: false, target: t, pole: p.rightKneePole, pitch: p.rightFootPitch, yaw: p.footYaw) }

        // ---- fingers
        for f in fingers {
            let handSide: Float = f.left ? 1 : -1
            let palm: Vec3 = Vec3(-handSide, 0, 0)
            let restDir: Vec3 = f.bone.restDirection
            var axis: Vec3 = simd_cross(restDir, palm).normalizedSafe
            if simd_length(axis) < 0.1 { axis = Vec3(0, 0, -handSide) }
            let base: Float = f.isThumb ? p.thumbCurl : p.fingerCurl
            let amounts: [Float] = f.isThumb ? [0.35, 0.55, 0.5] : [0.85, 1.05, 0.8]
            let angle: Float = base * amounts[f.index - 1]
            f.bone.localDelta = rig.localAxisRotation(f.bone, axis: axis, angle: angle)
        }
        rig.solve()
    }

    private func applyArm(left: Bool, target: Vec3, pole: Vec3, roll: Float) -> Float {
        let s: String = left ? "Left" : "Right"
        guard let arm = rig.bone("\(s)Arm"), let fore = rig.bone("\(s)ForeArm"), let hand = rig.bone("\(s)Hand") else { return 0 }
        let root: Vec3 = arm.curWorldPos
        let r = wSolveTwoBone(root: root, target: target, l1: upperArm, l2: foreArm, pole: pole)
        rig.aim(arm, toward: r.mid - root)
        rig.aim(fore, toward: r.end - r.mid)
        let qFore: simd_quatf = (fore.overrideRot ?? fore.restWorldRot) * fore.restWorldRot.inverse
        var hq: simd_quatf = simd_normalize(qFore * hand.restWorldRot)
        if abs(roll) > 1e-4 {
            let forward: Vec3 = (r.end - r.mid).normalizedSafe
            hq = simd_normalize(simd_quatf(angle: roll, axis: forward) * hq)
        }
        hand.overrideRot = hq
        return simd_length(target - root) / (upperArm + foreArm)
    }

    private func applyLeg(left: Bool, target: Vec3, pole: Vec3, pitch: Float, yaw: Float) {
        let s: String = left ? "Left" : "Right"
        guard let up = rig.bone("\(s)UpLeg"), let leg = rig.bone("\(s)Leg"), let foot = rig.bone("\(s)Foot") else { return }
        let root: Vec3 = up.curWorldPos
        let r = wSolveTwoBone(root: root, target: target, l1: thigh, l2: shin, pole: pole)
        rig.aim(up, toward: r.mid - root)
        rig.aim(leg, toward: r.end - r.mid)
        let qy = simd_quatf(angle: yaw, axis: Vec3(0, 1, 0))
        let qx = simd_quatf(angle: pitch, axis: Vec3(1, 0, 0))
        foot.overrideRot = simd_normalize(qy * qx * foot.restWorldRot)
    }

    /// avatar-space position of a bone after the last `apply`
    func joint(_ name: String) -> Vec3 { return rig.bone(name)?.curWorldPos ?? Vec3(0, 0, 0) }
}
