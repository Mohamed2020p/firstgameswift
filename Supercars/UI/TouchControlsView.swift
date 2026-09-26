import SwiftUI
import UIKit

// MARK: - On-screen controls. `TouchLayout` computes the zones; the same zones are (a) handed to the UIKit `TouchSurface` that tracks
// the fingers and (b) drawn here, so what you see is exactly what reacts.

enum TouchLayout {
    static func zones(size: CGSize, insets: UIEdgeInsets, driving: Bool, controls: ControlSettings, hasPrompt: Bool) -> [TouchZone] {
        let W: CGFloat = size.width
        let H: CGFloat = size.height
        let s: CGFloat = CGFloat(max(0.7, min(1.4, controls.hudScale)))
        let l: CGFloat = max(insets.left, 14) + 10
        let r: CGFloat = max(insets.right, 14) + 10
        let b: CGFloat = max(insets.bottom, 8) + 10
        let t: CGFloat = max(insets.top, 6) + 8
        let lefty: Bool = controls.leftHanded
        var zones: [TouchZone] = []

        func circle(_ kind: TouchZoneKind, cx: CGFloat, cy: CGFloat, d: CGFloat) {
            zones.append(TouchZone(kind: kind, rect: CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d), isCircle: true))
        }
        func box(_ kind: TouchZoneKind, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
            zones.append(TouchZone(kind: kind, rect: CGRect(x: x, y: y, width: w, height: h), isCircle: false))
        }
        /// x measured from the primary (pedal / action) side edge
        func px(_ offset: CGFloat, _ w: CGFloat) -> CGFloat { return lefty ? l + offset - 10 : W - r - offset - w + 10 }
        /// x measured from the secondary (steering / movement) side edge
        func sx(_ offset: CGFloat, _ w: CGFloat) -> CGFloat { return lefty ? W - r - offset - w + 10 : l + offset - 10 }

        circle(TouchZoneKind.pause, cx: l + 22, cy: t + 22, d: 46)
        if hasPrompt {
            box(TouchZoneKind.prompt, x: W / 2 - 130, y: H - b - (driving ? 178 : 142), w: 260, h: 52)
        }

        if driving {
            let pedalW: CGFloat = 92 * s
            let gasH: CGFloat = 122 * s
            let brakeH: CGFloat = 96 * s
            box(TouchZoneKind.gas, x: px(0, pedalW), y: H - b - gasH, w: pedalW, h: gasH)
            box(TouchZoneKind.brake, x: px(pedalW + 14, pedalW), y: H - b - brakeH, w: pedalW, h: brakeH)
            circle(TouchZoneKind.handbrake, cx: px(pedalW + 14, pedalW) + pedalW / 2, cy: H - b - brakeH - 34 * s, d: 52 * s)
            // paddles + utility column on the primary side, camera / lights / horn on the secondary side under the pause button
            circle(TouchZoneKind.shiftUp, cx: px(0, 46) + 23, cy: t + 190 * s, d: 46 * s)
            circle(TouchZoneKind.shiftDown, cx: px(0, 46) + 23, cy: t + 190 * s + 54 * s, d: 46 * s)
            circle(TouchZoneKind.camera, cx: l + 23, cy: t + 78, d: 46 * s)
            circle(TouchZoneKind.lights, cx: l + 23, cy: t + 78 + 54 * s, d: 46 * s)
            circle(TouchZoneKind.horn, cx: l + 23, cy: t + 78 + 108 * s, d: 46 * s)
            switch controls.steering {
            case .touchWheel:
                let d: CGFloat = 168 * s
                box(TouchZoneKind.wheel, x: sx(6, d), y: H - b - d, w: d, h: d)
                if let i = zones.lastIndex(where: { $0.kind == TouchZoneKind.wheel }) { zones[i].isCircle = true }
            case .touchButtons:
                let bw: CGFloat = 92 * s
                let bh: CGFloat = 116 * s
                box(TouchZoneKind.leftButton, x: sx(0, bw * 2 + 12), y: H - b - bh, w: bw, h: bh)
                box(TouchZoneKind.rightButton, x: sx(0, bw * 2 + 12) + bw + 12, y: H - b - bh, w: bw, h: bh)
            case .tilt:
                circle(TouchZoneKind.calibrate, cx: sx(0, 44) + 22, cy: H - b - 24, d: 44 * s)
            }
        } else {
            circle(TouchZoneKind.interact, cx: px(0, 84) + 42, cy: H - b - 70, d: 84 * s)
            circle(TouchZoneKind.jump, cx: px(96, 58) + 29, cy: H - b - 34, d: 58 * s)
            circle(TouchZoneKind.run, cx: px(12, 58) + 29, cy: H - b - 70 - 84 * s, d: 58 * s)
            if lefty {
                box(TouchZoneKind.joystick, x: W * 0.58, y: H * 0.25, w: W * 0.42, h: H * 0.75)
                box(TouchZoneKind.look, x: 0, y: 0, w: W * 0.58, h: H)
            } else {
                box(TouchZoneKind.joystick, x: 0, y: H * 0.25, w: W * 0.42, h: H * 0.75)
                box(TouchZoneKind.look, x: W * 0.42, y: 0, w: W * 0.58, h: H)
            }
        }
        return zones
    }
}

struct TouchControlsView: View {
    let ctx: GameContext
    @ObservedObject private var state: GameState
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var visuals: TouchVisuals

    init(ctx: GameContext) {
        self.ctx = ctx
        _state = ObservedObject(wrappedValue: ctx.state)
        _settings = ObservedObject(wrappedValue: ctx.settings)
        _visuals = ObservedObject(wrappedValue: ctx.input.visuals)
    }

    var body: some View {
        GeometryReader { geo in
            let active: Bool = (state.mode == .driving || state.mode == .onFoot) && state.screen == .none && !state.isPaused
            if active {
                let driving: Bool = state.mode == .driving
                let ctrl: ControlSettings = settings.settings.controls
                let zones: [TouchZone] = TouchLayout.zones(size: geo.size, insets: ScreenInsets.current, driving: driving, controls: ctrl, hasPrompt: state.prompt != nil)
                ZStack {
                    ForEach(zones) { z in
                        ControlGlyph(zone: z, pressed: visuals.pressed.contains(z.kind), latched: visuals.runLatched, ctx: ctx)
                    }
                    if !driving { JoystickHint(visuals: visuals, zones: zones) }
                    if driving && ctrl.steering == .tilt { TiltMeter(steer: ctx.input.steerVisuals) }
                }
                .opacity(Double(ctrl.controlOpacity))
                .allowsHitTesting(false)
                TouchSurface(touch: ctx.input.touch, visuals: ctx.input.visuals, zones: zones)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - drawing of one control

struct ControlGlyph: View {
    let zone: TouchZone
    let pressed: Bool
    let latched: Bool
    let ctx: GameContext

    private func symbol(_ name: String, _ tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: max(16, zone.rect.width * 0.36), weight: .bold))
            .foregroundColor(pressed ? Neon.ink : tint)
    }

    private func roundLabel(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(Neon.font(max(12, zone.rect.width * 0.30), .heavy))
            .foregroundColor(pressed ? Neon.ink : tint)
    }

    @ViewBuilder
    private var content: some View {
        switch zone.kind {
        case .gas: pedal("GAS", Neon.green)
        case .brake: pedal("BRAKE", Neon.red)
        case .handbrake: roundLabel("HB", Neon.amber)
        case .shiftUp: roundLabel("▲", Neon.cyan)
        case .shiftDown: roundLabel("▼", Neon.cyan)
        case .camera: symbol("camera.viewfinder", Neon.cyan)
        case .lights: symbol("lightbulb.fill", Neon.amber)
        case .horn: symbol("megaphone.fill", Neon.magenta)
        case .pause: symbol("pause.fill", Color.white)
        case .interact: symbol("hand.tap.fill", Neon.green)
        case .jump: symbol("arrow.up", Neon.cyan)
        case .run: symbol("figure.run", latched ? Neon.ink : Neon.amber)
        case .calibrate: symbol("scope", Neon.cyan)
        case .leftButton: symbol("chevron.left", Neon.green)
        case .rightButton: symbol("chevron.right", Neon.green)
        case .wheel: WheelWidget(steer: ctx.input.steerVisuals, pressed: pressed)
        default: EmptyView()
        }
    }

    private func pedal(_ text: String, _ tint: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "chevron.up.2").font(.system(size: 16, weight: .bold))
            Text(text).font(Neon.font(14, .black))
        }
        .foregroundColor(pressed ? Neon.ink : tint)
    }

    private var tintColor: Color {
        switch zone.kind {
        case .gas: return Neon.green
        case .brake: return Neon.red
        case .handbrake: return Neon.amber
        case .interact: return Neon.green
        case .horn: return Neon.magenta
        case .lights: return Neon.amber
        case .run: return Neon.amber
        case .pause: return Color.white
        default: return Neon.cyan
        }
    }

    var body: some View {
        switch zone.kind {
        case .joystick, .look, .prompt:
            EmptyView()
        case .wheel:
            content
                .frame(width: zone.rect.width, height: zone.rect.height)
                .position(x: zone.rect.midX, y: zone.rect.midY)
        default:
            let isOn: Bool = pressed || (zone.kind == TouchZoneKind.run && latched)
            let shape = RoundedRectangle(cornerRadius: zone.isCircle ? zone.rect.width / 2 : 18)
            content
                .frame(width: zone.rect.width, height: zone.rect.height)
                .background(shape.fill(isOn ? tintColor : Neon.ink.opacity(0.5)))
                .overlay(shape.stroke(tintColor.opacity(0.9), lineWidth: 2))
                .shadow(color: tintColor.opacity(isOn ? 0.8 : 0.25), radius: isOn ? 14 : 6)
                .scaleEffect(pressed ? 0.95 : 1)
                .position(x: zone.rect.midX, y: zone.rect.midY)
        }
    }
}

struct WheelWidget: View {
    @ObservedObject var steer: SteerVisuals
    let pressed: Bool

    var body: some View {
        ZStack {
            Circle().fill(Neon.ink.opacity(0.35))
            Circle().stroke(pressed ? Neon.green : Neon.green.opacity(0.55), lineWidth: 12)
                .padding(10)
            Rectangle().fill(pressed ? Neon.green : Neon.green.opacity(0.55)).frame(width: 8).padding(.vertical, 70)
            Rectangle().fill(pressed ? Neon.green : Neon.green.opacity(0.55)).frame(height: 8).padding(.horizontal, 22).offset(y: -6)
            Circle().fill(Neon.magenta).frame(width: 26, height: 26)
            Rectangle().fill(Neon.magenta).frame(width: 10, height: 26).offset(y: -66)
        }
        .rotationEffect(.degrees(-Double(steer.wheel) * 108))
        .shadow(color: Neon.green.opacity(pressed ? 0.7 : 0.25), radius: 10)
    }
}

struct JoystickHint: View {
    @ObservedObject var visuals: TouchVisuals
    let zones: [TouchZone]

    var body: some View {
        ZStack {
            if visuals.joystickActive {
                Circle().stroke(Neon.green.opacity(0.7), lineWidth: 3)
                    .frame(width: 116, height: 116)
                    .position(visuals.joystickBase)
                Circle().fill(Neon.green.opacity(0.75))
                    .frame(width: 54, height: 54)
                    .position(visuals.joystickKnob)
            } else if let z = zones.first(where: { $0.kind == TouchZoneKind.joystick }) {
                Circle().stroke(Neon.green.opacity(0.28), style: StrokeStyle(lineWidth: 3, dash: [6, 6]))
                    .frame(width: 110, height: 110)
                    .position(x: z.rect.midX, y: z.rect.maxY - 78)
                Text("MOVE").font(Neon.mono(10, .bold)).foregroundColor(Neon.green.opacity(0.4))
                    .position(x: z.rect.midX, y: z.rect.maxY - 78)
            }
        }
    }
}

/// live tilt indicator (bottom left) so the player sees how far the phone is turned
struct TiltMeter: View {
    @ObservedObject var steer: SteerVisuals

    var body: some View {
        VStack {
            Spacer()
            HStack {
                ZStack {
                    Capsule().fill(Color.white.opacity(0.12)).frame(width: 150, height: 8)
                    Rectangle().fill(Color.white.opacity(0.4)).frame(width: 2, height: 14)
                    Circle().fill(Neon.green).frame(width: 16, height: 16)
                        .offset(x: CGFloat(max(-1, min(1, steer.steer))) * -67)
                        .shadow(color: Neon.green, radius: 6)
                }
                .padding(.leading, 78)
                .padding(.bottom, 24)
                Spacer()
            }
        }
    }
}
