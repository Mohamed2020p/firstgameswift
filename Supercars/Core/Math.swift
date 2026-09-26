import Foundation
import simd
import SceneKit
import UIKit

// MARK: - Shared math helpers.  ALL game logic uses SIMD (Vec2/Vec3) and converts at the SceneKit boundary through the
// `simd*` properties of SCNNode (simdPosition, simdOrientation, simdEulerAngles, simdScale).  Do NOT redefine operators.

typealias Vec2 = SIMD2<Float>
typealias Vec3 = SIMD3<Float>
typealias Vec4 = SIMD4<Float>

extension Float {
    static let tau: Float = 2 * Float.pi
    static let deg2rad: Float = Float.pi / 180
    static let rad2deg: Float = 180 / Float.pi
}

@inline(__always) func clampf(_ x: Float, _ lo: Float, _ hi: Float) -> Float { return min(max(x, lo), hi) }
@inline(__always) func lerpf(_ a: Float, _ b: Float, _ t: Float) -> Float { return a + (b - a) * t }
@inline(__always) func signf(_ x: Float) -> Float { return x < 0 ? -1 : 1 }

func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let t = clampf((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)
}

/// Frame-rate independent exponential smoothing: current -> target with rate `lambda` (1/seconds).
@inline(__always) func damp(_ current: Float, _ target: Float, _ lambda: Float, _ dt: Float) -> Float {
    return lerpf(current, target, 1 - expf(-lambda * dt))
}

func dampVec3(_ current: Vec3, _ target: Vec3, _ lambda: Float, _ dt: Float) -> Vec3 {
    let t = 1 - expf(-lambda * dt)
    return current + (target - current) * t
}

/// wraps an angle into (-pi, pi]
func wrapAngle(_ a: Float) -> Float {
    var r = a
    while r > Float.pi { r -= Float.tau }
    while r <= -Float.pi { r += Float.tau }
    return r
}

/// shortest signed angular difference b - a
func angleDiff(_ a: Float, _ b: Float) -> Float { return wrapAngle(b - a) }

// Heading convention (radians): forward = (sin h, 0, cos h);  left = (cos h, 0, -sin h).  node.simdEulerAngles.y = h faces a +Z model along the heading.
@inline(__always) func headingForward(_ h: Float) -> Vec3 { return Vec3(sinf(h), 0, cosf(h)) }
@inline(__always) func headingLeft(_ h: Float) -> Vec3 { return Vec3(cosf(h), 0, -sinf(h)) }
@inline(__always) func headingForward2(_ h: Float) -> Vec2 { return Vec2(sinf(h), cosf(h)) }
@inline(__always) func headingLeft2(_ h: Float) -> Vec2 { return Vec2(cosf(h), -sinf(h)) }
@inline(__always) func headingOf(_ dir: Vec2) -> Float { return atan2f(dir.x, dir.y) }

extension SIMD3 where Scalar == Float {
    var xz: Vec2 { return Vec2(x, z) }
    init(xz: Vec2, y: Float = 0) { self.init(xz.x, y, xz.y) }
    var length: Float { return simd_length(self) }
    var normalizedSafe: Vec3 {
        let l = simd_length(self)
        return l > 1e-6 ? self / l : Vec3(0, 0, 0)
    }
}

extension SIMD2 where Scalar == Float {
    var length: Float { return simd_length(self) }
    var normalizedSafe: Vec2 {
        let l = simd_length(self)
        return l > 1e-6 ? self / l : Vec2(0, 0)
    }
    /// counter-clockwise perpendicular in the XZ ground plane sense used by headingLeft2 for direction (sin h, cos h)
    var leftPerp: Vec2 { return Vec2(y, -x) }
}

/// Deterministic random numbers (city generation must be identical on every launch).
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func float() -> Float { return Float(next() >> 40) / Float(1 << 24) }
    mutating func float(_ lo: Float, _ hi: Float) -> Float { return lo + (hi - lo) * float() }
    mutating func int(_ lo: Int, _ hi: Int) -> Int { return lo + Int(next() % UInt64(max(1, hi - lo + 1))) }
    mutating func chance(_ p: Float) -> Bool { return float() < p }
}

extension UIColor {
    /// UIColor(hex: 0xRRGGBB)
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: alpha)
    }
    /// "#rrggbb" or "rrggbb"; falls back to grey.
    convenience init(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0x808080
        Scanner(string: s).scanHexInt64(&v)
        self.init(hex: UInt32(truncatingIfNeeded: v))
    }
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02x%02x%02x", Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
    }
}

/// The c0derz visual identity (neon green / magenta on near-black).
enum Palette {
    static let neonGreen = UIColor(hex: 0x39FF88)
    static let neonMagenta = UIColor(hex: 0xFF2BD6)
    static let neonCyan = UIColor(hex: 0x2BE6FF)
    static let ink = UIColor(hex: 0x05060A)
    static let panel = UIColor(hex: 0x0B0E16)
}

extension SCNNode {
    /// Places the node on the ground plane with a heading (see convention above).
    func setGround(position: Vec3, heading: Float) {
        simdPosition = position
        simdEulerAngles = Vec3(0, heading, 0)
    }
    /// Recursively finds a descendant by exact name (nil if absent).
    func findNode(named n: String) -> SCNNode? {
        return childNode(withName: n, recursively: true)
    }
}
