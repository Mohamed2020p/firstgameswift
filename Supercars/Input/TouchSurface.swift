import UIKit
import SwiftUI

// MARK: - One UIKit view that tracks every finger by zone (multi-touch safe) and writes into `TouchInput`.
// The SwiftUI controls only draw; the zones they are drawn in come from the same `TouchLayout`.

@MainActor
struct TouchSurface: UIViewRepresentable {
    let touch: TouchInput
    let visuals: TouchVisuals
    let zones: [TouchZone]

    func makeUIView(context: Context) -> TouchSurfaceView {
        let view: TouchSurfaceView = TouchSurfaceView(touch: touch, visuals: visuals)
        view.setZones(zones)
        return view
    }

    func updateUIView(_ uiView: TouchSurfaceView, context: Context) {
        uiView.setZones(zones)
    }
}

@MainActor
final class TouchSurfaceView: UIView {

    private struct ActiveTouch {
        var kind: TouchZoneKind
        var start: CGPoint
        var last: CGPoint
        var lastAngle: CGFloat
        var wheelAccum: CGFloat
        var joyBase: CGPoint
    }

    private let input: TouchInput
    private let visuals: TouchVisuals
    private var zones: [TouchZone] = []
    private var active: [ObjectIdentifier: ActiveTouch] = [:]

    private let joystickRadius: CGFloat = 58
    private let maxWheelAngle: CGFloat = 1.9      // radians of hand rotation for full lock

    init(touch: TouchInput, visuals: TouchVisuals) {
        self.input = touch
        self.visuals = visuals
        super.init(frame: CGRect.zero)
        backgroundColor = UIColor.clear
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true
        isExclusiveTouch = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { releaseAll() }
    }

    // MARK: Zones

    func setZones(_ newZones: [TouchZone]) {
        if newZones == zones { return }
        zones = newZones
        // fingers whose control disappeared are released, everything else keeps working
        var changed: Bool = false
        for (key, a) in active {
            let stillThere: Bool = zones.contains(where: { $0.kind == a.kind })
            if !stillThere {
                active.removeValue(forKey: key)
                changed = true
            }
        }
        if changed { syncHeldState() }
    }

    func releaseAll() {
        active.removeAll()
        syncHeldState()
    }

    private func zoneAt(_ p: CGPoint) -> TouchZone? {
        for z in zones {
            if z.contains(p) { return z }
        }
        return nil
    }

    private func zoneRect(_ kind: TouchZoneKind) -> CGRect? {
        for z in zones {
            if z.kind == kind { return z.rect }
        }
        return nil
    }

    // MARK: Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let p: CGPoint = t.location(in: self)
            guard let zone = zoneAt(p) else { continue }
            var a: ActiveTouch = ActiveTouch(kind: zone.kind, start: p, last: p, lastAngle: 0, wheelAccum: 0, joyBase: p)
            beginTouch(&a, zone: zone, at: p)
            active[ObjectIdentifier(t)] = a
        }
        syncHeldState()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        var needsSync: Bool = false
        for t in touches {
            let key: ObjectIdentifier = ObjectIdentifier(t)
            guard var a = active[key] else { continue }
            let p: CGPoint = t.location(in: self)
            moveTouch(&a, to: p)
            active[key] = a
            if a.kind == TouchZoneKind.joystick { needsSync = true }
        }
        if needsSync { syncHeldState() }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouches(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouches(touches)
    }

    private func endTouches(_ touches: Set<UITouch>) {
        for t in touches {
            active.removeValue(forKey: ObjectIdentifier(t))
        }
        syncHeldState()
    }

    private func beginTouch(_ a: inout ActiveTouch, zone: TouchZone, at p: CGPoint) {
        switch zone.kind {
        case .wheel:
            let c: CGPoint = CGPoint(x: zone.rect.midX, y: zone.rect.midY)
            a.lastAngle = atan2(p.y - c.y, p.x - c.x)
            a.wheelAccum = -CGFloat(input.steerWheel) * maxWheelAngle
        case .joystick:
            a.joyBase = p
        case .interact, .prompt:
            input.interactTap = true
        case .camera:
            input.cameraTap = true
        case .shiftUp:
            input.shiftUpTap = true
        case .shiftDown:
            input.shiftDownTap = true
        case .lights:
            input.lightsTap = true
        case .pause:
            input.pauseTap = true
        case .map:
            input.mapTap = true
        case .jump:
            input.jumpTap = true
        case .calibrate:
            input.calibrateTap = true
        case .run:
            input.runHeld = !input.runHeld
            visuals.runLatched = input.runHeld
        default:
            break
        }
    }

    private func moveTouch(_ a: inout ActiveTouch, to p: CGPoint) {
        switch a.kind {
        case .wheel:
            guard let r = zoneRect(TouchZoneKind.wheel) else { return }
            let c: CGPoint = CGPoint(x: r.midX, y: r.midY)
            let dx: CGFloat = p.x - c.x
            let dy: CGFloat = p.y - c.y
            if dx * dx + dy * dy < 18 * 18 { return }
            let ang: CGFloat = atan2(dy, dx)
            var d: CGFloat = ang - a.lastAngle
            while d > CGFloat.pi { d -= 2 * CGFloat.pi }
            while d < -CGFloat.pi { d += 2 * CGFloat.pi }
            a.lastAngle = ang
            a.wheelAccum = min(max(a.wheelAccum + d, -maxWheelAngle), maxWheelAngle)
            input.steerWheel = Float(-a.wheelAccum / maxWheelAngle)
        case .joystick:
            var base: CGPoint = a.joyBase
            var ox: CGFloat = p.x - base.x
            var oy: CGFloat = p.y - base.y
            let len: CGFloat = sqrt(ox * ox + oy * oy)
            if len > joystickRadius {
                // the stick base follows the finger when it is dragged past the rim
                let excess: CGFloat = (len - joystickRadius) / len
                base.x += ox * excess
                base.y += oy * excess
                ox = p.x - base.x
                oy = p.y - base.y
                a.joyBase = base
            }
            let nx: CGFloat = min(max(ox / joystickRadius, -1), 1)
            let ny: CGFloat = min(max(oy / joystickRadius, -1), 1)
            input.moveX = Float(nx)
            input.moveY = Float(-ny)
            visuals.joystickBase = base
            visuals.joystickKnob = CGPoint(x: base.x + nx * joystickRadius, y: base.y + ny * joystickRadius)
        case .look:
            input.lookDX += Float(p.x - a.last.x)
            input.lookDY += Float(p.y - a.last.y)
        default:
            break
        }
        a.last = p
    }

    /// Recomputes every held-state flag from the fingers that are currently down (robust against several fingers on one control).
    private func syncHeldState() {
        var kinds: Set<TouchZoneKind> = []
        var joy: ActiveTouch? = nil
        for (_, a) in active {
            kinds.insert(a.kind)
            if a.kind == TouchZoneKind.joystick { joy = a }
        }
        input.gas = kinds.contains(.gas) ? 1 : 0
        input.brake = kinds.contains(.brake) ? 1 : 0
        input.handbrake = kinds.contains(.handbrake)
        input.leftDown = kinds.contains(.leftButton)
        input.rightDown = kinds.contains(.rightButton)
        input.hornHeld = kinds.contains(.horn)
        input.wheelActive = kinds.contains(.wheel)
        if let j = joy {
            if !visuals.joystickActive {
                visuals.joystickActive = true
                visuals.joystickBase = j.joyBase
                visuals.joystickKnob = j.joyBase
            }
        } else {
            input.moveX = 0
            input.moveY = 0
            if visuals.joystickActive { visuals.joystickActive = false }
        }
        if visuals.pressed != kinds { visuals.pressed = kinds }
    }
}
