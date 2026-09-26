import SwiftUI
import UIKit
import simd

// MARK: - In-game overlay: speedometer, minimap, race panel, prompt, toast, clock. Purely visual (hit testing is done by the touch surface).

struct GameplayView: View {
    let ctx: GameContext
    var body: some View {
        ZStack {
            HUDView(ctx: ctx)
            TouchControlsView(ctx: ctx)
        }
    }
}

struct HUDView: View {
    let ctx: GameContext

    var body: some View {
        ZStack {
            InfoStrip(state: ctx.state, settings: ctx.settings)
            MinimapView(state: ctx.state, settings: ctx.settings)
            RacePanel(state: ctx.state)
            CountdownBanner(state: ctx.state)
            SpeedoView(state: ctx.state, settings: ctx.settings)
            PromptPill(state: ctx.state)
            ToastView(state: ctx.state)
            DrivingCameraLabel(state: ctx.state)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - clock / money / location (top-left, right of the pause button)

struct InfoStrip: View {
    @ObservedObject var state: GameState
    @ObservedObject var settings: SettingsStore

    var body: some View {
        let inset: UIEdgeInsets = ScreenInsets.current
        let s: CGFloat = CGFloat(settings.settings.controls.hudScale)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(state.clockString).font(Neon.mono(17, .heavy)).foregroundColor(.white)
                Text("DAY \(state.day)").font(Neon.mono(11, .bold)).foregroundColor(Neon.cyan)
            }
            Text("$\(state.money)").font(Neon.mono(15, .heavy)).foregroundColor(Neon.amber)
            if !state.locationName.isEmpty {
                Text(state.locationName.uppercased()).font(Neon.mono(10, .bold)).foregroundColor(Neon.magenta)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Neon.ink.opacity(0.5)))
        .scaleEffect(s, anchor: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.leading, max(inset.left, 16) + 66)
        .padding(.top, max(inset.top, 6) + 8)
    }
}

// MARK: - speedometer (driving only)

struct SpeedoView: View {
    @ObservedObject var state: GameState
    @ObservedObject var settings: SettingsStore

    private var gearText: String {
        if state.gear < 0 { return "R" }
        if state.gear == 0 { return "N" }
        return "\(state.gear)"
    }

    var body: some View {
        if state.mode == .driving {
            let mph: Bool = settings.settings.gameplay.units == .mph
            let v: Float = abs(state.speed) * (mph ? 2.23694 : 3.6)
            let s: CGFloat = CGFloat(settings.settings.controls.hudScale)
            let inset: UIEdgeInsets = ScreenInsets.current
            VStack(spacing: 4) {
                RpmBar(rpm: state.rpm, redline: state.redline)
                    .frame(width: 250, height: 12)
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text(gearText)
                        .font(Neon.font(34, .black))
                        .foregroundColor(state.gear < 0 ? Neon.amber : Neon.green)
                        .frame(width: 36)
                    Text("\(Int(v))")
                        .font(Font.system(size: 58, weight: .black, design: .rounded).italic())
                        .foregroundColor(.white)
                        .monospacedDigit()
                        .frame(minWidth: 116, alignment: .trailing)
                    Text(mph ? "MPH" : "KM/H")
                        .font(Neon.mono(12, .bold))
                        .foregroundColor(Neon.dim)
                }
                HStack(spacing: 10) {
                    Text(state.engineName).font(Neon.mono(10, .semibold)).foregroundColor(Neon.dim).lineLimit(1)
                    Indicator(text: "TC", on: state.tractionControlActive, tint: Neon.amber)
                    Indicator(text: "ABS", on: state.abs, tint: Neon.amber)
                    if state.damage > 0.02 {
                        DamageBar(value: state.damage)
                            .frame(width: 60, height: 6)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 16).fill(Neon.ink.opacity(0.45)))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Neon.green.opacity(0.35), lineWidth: 1))
            .scaleEffect(s, anchor: .bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, max(inset.bottom, 8) + 6)
        }
    }
}

struct RpmBar: View {
    let rpm: Float
    let redline: Float

    var body: some View {
        Canvas { c, size in
            let n = 32
            let gap: CGFloat = 2
            let w: CGFloat = (size.width - gap * CGFloat(n - 1)) / CGFloat(n)
            let frac: CGFloat = CGFloat(max(0, min(1.08, rpm / max(1000, redline))))
            for i in 0..<n {
                let t: CGFloat = CGFloat(i) / CGFloat(n - 1)
                let on: Bool = t <= frac
                var col: Color = Neon.green
                if t > 0.72 { col = Neon.amber }
                if t > 0.88 { col = Neon.red }
                let r = CGRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: size.height)
                c.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(on ? col : Color.white.opacity(0.10)))
            }
        }
    }
}

struct Indicator: View {
    let text: String
    let on: Bool
    let tint: Color
    var body: some View {
        Text(text)
            .font(Neon.mono(10, .heavy))
            .foregroundColor(on ? Neon.ink : Neon.dim.opacity(0.5))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(on ? tint : Color.white.opacity(0.06)))
    }
}

struct DamageBar: View {
    let value: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(value > 0.6 ? Neon.red : Neon.amber).frame(width: geo.size.width * CGFloat(min(1, value)))
            }
        }
    }
}

// MARK: - minimap

struct MinimapView: View {
    @ObservedObject var state: GameState
    @ObservedObject var settings: SettingsStore

    var body: some View {
        if settings.settings.gameplay.showMinimap && (state.mode == .driving || state.mode == .onFoot) {
            let inset: UIEdgeInsets = ScreenInsets.current
            let s: CGFloat = CGFloat(settings.settings.controls.hudScale)
            MinimapCanvas(state: state)
                .frame(width: 118, height: 118)
                .clipShape(Circle())
                .overlay(Circle().stroke(Neon.green.opacity(0.7), lineWidth: 2))
                .shadow(color: Neon.green.opacity(0.3), radius: 8)
                .scaleEffect(s, anchor: .topTrailing)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.trailing, max(inset.right, 16) + 8)
                .padding(.top, max(inset.top, 6) + 8)
        }
    }
}

struct MinimapCanvas: View {
    @ObservedObject var state: GameState

    var body: some View {
        Canvas { c, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            c.fill(Path(CGRect(origin: CGPoint.zero, size: size)), with: .color(Neon.ink.opacity(0.78)))
            let pos: Vec2 = state.playerMapPosition
            let h: Float = state.playerMapHeading
            let driving: Bool = state.mode == .driving
            let range: Float = driving ? min(650, 240 + abs(state.speed) * 4.5) : 170
            let scale: CGFloat = CGFloat(size.width * 0.5) / CGFloat(range)
            let right = Vec2(-cosf(h), sinf(h))
            let up = Vec2(sinf(h), cosf(h))
            func map(_ p: Vec2) -> CGPoint {
                let d: Vec2 = p - pos
                return CGPoint(x: center.x + CGFloat(simd_dot(d, right)) * scale, y: center.y - CGFloat(simd_dot(d, up)) * scale)
            }
            let mm: MinimapData = state.minimap
            var roads = Path()
            for line in mm.roads {
                if line.count < 2 { continue }
                var minD: Float = 1e9
                for p in line { minD = min(minD, simd_length(p - pos)) }
                if minD > range * 1.3 && line.count < 6 { continue }
                roads.move(to: map(line[0]))
                for i in 1..<line.count { roads.addLine(to: map(line[i])) }
            }
            c.stroke(roads, with: .color(Color.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            if mm.route.count > 2 {
                var route = Path()
                route.move(to: map(mm.route[0]))
                for i in 1..<mm.route.count { route.addLine(to: map(mm.route[i])) }
                c.stroke(route, with: .color(Neon.magenta.opacity(0.9)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
            for o in state.opponentMapPositions {
                let p = map(o)
                c.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(Neon.red))
            }
            // player arrow
            var arrow = Path()
            arrow.move(to: CGPoint(x: center.x, y: center.y - 8))
            arrow.addLine(to: CGPoint(x: center.x + 5.5, y: center.y + 6))
            arrow.addLine(to: CGPoint(x: center.x, y: center.y + 3))
            arrow.addLine(to: CGPoint(x: center.x - 5.5, y: center.y + 6))
            arrow.closeSubpath()
            c.fill(arrow, with: .color(Neon.green))
            c.stroke(arrow, with: .color(Neon.ink), lineWidth: 1)
            // north marker
            let nr: CGFloat = size.width * 0.5 - 9
            let nx: CGFloat = center.x + CGFloat(sinf(-h)) * nr
            let ny: CGFloat = center.y - CGFloat(cosf(-h)) * nr
            c.draw(Text("N").font(Neon.mono(9, .heavy)).foregroundColor(Neon.cyan), at: CGPoint(x: nx, y: ny))
        }
    }
}

// MARK: - race panel + countdown

struct RacePanel: View {
    @ObservedObject var state: GameState

    private func fmt(_ t: Double?) -> String {
        guard let t = t, t > 0 else { return "--:--.--" }
        let m: Int = Int(t) / 60
        return String(format: "%d:%05.2f", m, t - Double(m * 60))
    }

    var body: some View {
        if let r = state.race, state.screen != .results {
            let inset: UIEdgeInsets = ScreenInsets.current
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text("P\(r.position)").font(Neon.font(30, .black)).foregroundColor(Neon.green)
                    Text("/ \(r.total)").font(Neon.mono(13, .bold)).foregroundColor(Neon.dim)
                    Spacer(minLength: 8)
                    Text("LAP \(min(r.lap, r.laps))/\(r.laps)").font(Neon.mono(14, .heavy)).foregroundColor(.white)
                }
                Text(fmt(r.raceTime)).font(Neon.mono(18, .heavy)).foregroundColor(.white)
                HStack(spacing: 8) {
                    Text("LAP").font(Neon.mono(9, .bold)).foregroundColor(Neon.dim)
                    Text(fmt(r.lapTime)).font(Neon.mono(12, .semibold)).foregroundColor(Neon.cyan)
                    Text("BEST").font(Neon.mono(9, .bold)).foregroundColor(Neon.dim)
                    Text(fmt(r.bestLap)).font(Neon.mono(12, .semibold)).foregroundColor(Neon.amber)
                }
                if r.wrongWay {
                    Text("WRONG WAY").font(Neon.font(15, .black)).foregroundColor(Neon.red)
                }
            }
            .padding(10)
            .frame(width: 210)
            .background(RoundedRectangle(cornerRadius: 12).fill(Neon.ink.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Neon.magenta.opacity(0.6), lineWidth: 1))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, max(inset.left, 16) + 8)
            .padding(.top, max(inset.top, 6) + 76)
        }
    }
}

struct CountdownBanner: View {
    @ObservedObject var state: GameState
    var body: some View {
        if let r = state.race, let c = r.countdown {
            Text(c > 0 ? "\(c)" : "GO!")
                .font(Font.system(size: 120, weight: .black, design: .rounded).italic())
                .foregroundStyle(LinearGradient(colors: [Neon.green, Neon.cyan], startPoint: .top, endPoint: .bottom))
                .shadow(color: Neon.green.opacity(0.7), radius: 24)
                .transition(.scale.combined(with: .opacity))
        }
    }
}

// MARK: - prompt, toast, camera name

struct PromptPill: View {
    @ObservedObject var state: GameState
    var body: some View {
        if let p = state.prompt, state.mode != .menu {
            let inset: UIEdgeInsets = ScreenInsets.current
            HStack(spacing: 8) {
                Image(systemName: "hand.tap.fill").foregroundColor(Neon.green)
                Text(p).font(Neon.font(16, .heavy)).foregroundColor(.white)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Capsule().fill(Neon.ink.opacity(0.7)))
            .overlay(Capsule().stroke(Neon.green, lineWidth: 1.5))
            .shadow(color: Neon.green.opacity(0.4), radius: 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, max(inset.bottom, 8) + (state.mode == .driving ? 132 : 96))
        }
    }
}

struct ToastView: View {
    @ObservedObject var state: GameState
    var body: some View {
        if let t = state.toast {
            let inset: UIEdgeInsets = ScreenInsets.current
            Text(t.text)
                .font(Neon.font(15, .bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(Capsule().fill(Neon.panel.opacity(0.92)))
                .overlay(Capsule().stroke(Neon.magenta.opacity(0.8), lineWidth: 1.2))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, max(inset.top, 6) + 12)
                .id(t.id)
        }
    }
}

struct DrivingCameraLabel: View {
    @ObservedObject var state: GameState
    var body: some View {
        EmptyView()
    }
}
