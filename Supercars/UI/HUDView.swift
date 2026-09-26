import SwiftUI
import UIKit
import simd

// MARK: - In-game overlay: speedometer, minimap, navigation guidance, wanted stars, race panel, prompt, toast, clock.
// Purely visual (hit testing is done by the touch surface).  Style: graphite glass, white type, one brass accent, no glow.

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
            NavGuidanceView(state: ctx.state)
            WantedStarsView(state: ctx.state)
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
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(state.clockString).font(Neon.mono(16, .semibold)).foregroundColor(.white)
                Text("DAY \(state.day)").font(Neon.mono(10, .medium)).foregroundColor(Neon.dim)
            }
            Text("$\(state.money)").font(Neon.mono(13, .semibold)).foregroundColor(Neon.amber)
            let place: String = !state.locationName.isEmpty ? state.locationName : state.districtName
            if !place.isEmpty {
                Text(place.uppercased()).font(Neon.font(9, .semibold)).tracking(1.2).foregroundColor(Neon.dim)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.42)))
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
            // slim readout at the very bottom so it never covers the road / cockpit; smaller still in the inside views
            let inside: Bool = state.view == .cockpit || state.view == .hood || state.view == .bumper
            let numSize: CGFloat = inside ? 26 : 34
            let barW: CGFloat = inside ? 130 : 170
            VStack(spacing: 3) {
                RpmBar(rpm: state.rpm, redline: state.redline)
                    .frame(width: barW, height: inside ? 3 : 4)
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text(gearText)
                        .font(Neon.font(numSize * 0.62, .semibold))
                        .foregroundColor(state.gear < 0 ? Neon.amber : Neon.dim)
                    Text("\(Int(v))")
                        .font(Font.system(size: numSize, weight: .semibold, design: .default))
                        .foregroundColor(.white)
                        .monospacedDigit()
                    Text(mph ? "MPH" : "KM/H")
                        .font(Neon.font(9, .medium))
                        .tracking(1)
                        .foregroundColor(Neon.dim)
                    if state.tractionControlActive { Indicator(text: "TC", on: true, tint: Neon.amber) }
                    if state.abs { Indicator(text: "ABS", on: true, tint: Neon.amber) }
                    if state.damage > 0.02 {
                        DamageBar(value: state.damage).frame(width: 34, height: 4)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(inside ? 0.20 : 0.34)))
            .scaleEffect(s, anchor: .bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, max(inset.bottom, 4) + 2)
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
                var col: Color = Color.white.opacity(0.85)
                if t > 0.78 { col = Neon.amber }
                if t > 0.90 { col = Neon.red }
                let r = CGRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: size.height)
                c.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(on ? col : Color.white.opacity(0.12)))
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
            .font(Neon.mono(9, .semibold))
            .foregroundColor(on ? Neon.ink : Neon.dim.opacity(0.5))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(on ? tint : Color.white.opacity(0.06)))
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
                .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1.5))
                .shadow(color: Color.black.opacity(0.4), radius: 6)
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
            c.fill(Path(CGRect(origin: CGPoint.zero, size: size)), with: .color(Color(red: 0.06, green: 0.065, blue: 0.075).opacity(0.86)))
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
            let period: Float = max(500, mm.tilePeriod)
            let half: Float = period * 0.5
            // the streets repeat with the tile period (endless city)
            let tx0: Int = Int(floorf((pos.x - range + half) / period))
            let tx1: Int = Int(floorf((pos.x + range + half) / period))
            let tz0: Int = Int(floorf((pos.y - range + half) / period))
            let tz1: Int = Int(floorf((pos.y + range + half) / period))
            if tx1 >= tx0 && tz1 >= tz0 {
                var roads = Path()
                for tx in tx0...tx1 {
                    for tz in tz0...tz1 {
                        let off: Vec2 = Vec2(Float(tx) * period, Float(tz) * period)
                        for line in mm.roads {
                            if line.count < 2 { continue }
                            var minD: Float = 1e9
                            for p in line { minD = min(minD, simd_length(p + off - pos)) }
                            if minD > range * 1.3 && line.count < 6 { continue }
                            roads.move(to: map(line[0] + off))
                            for i in 1..<line.count { roads.addLine(to: map(line[i] + off)) }
                        }
                    }
                }
                c.stroke(roads, with: .color(Color.white.opacity(0.42)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
            // navigation route
            if let nav = state.navigation, nav.route.count > 1 {
                var route = Path()
                route.move(to: map(nav.route[0]))
                for i in 1..<nav.route.count { route.addLine(to: map(nav.route[i])) }
                c.stroke(route, with: .color(Color(red: 0.92, green: 0.76, blue: 0.42)), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
            // places of interest (letters); an off-map destination shows on the rim
            for w in state.pois {
                let p: CGPoint = map(w.position)
                let d: CGFloat = hypot(p.x - center.x, p.y - center.y)
                let isDest: Bool = state.navigation?.destinationID == w.id
                let rim: CGFloat = size.width * 0.5 - 9
                if d > rim {
                    if !isDest { continue }
                    let k: CGFloat = rim / max(d, 1)
                    let q = CGPoint(x: center.x + (p.x - center.x) * k, y: center.y + (p.y - center.y) * k)
                    c.fill(Path(ellipseIn: CGRect(x: q.x - 6, y: q.y - 6, width: 12, height: 12)), with: .color(Color(red: 0.92, green: 0.76, blue: 0.42)))
                    c.draw(Text(w.kind.letter).font(Neon.font(8, .heavy)).foregroundColor(Neon.ink), at: q)
                    continue
                }
                let col: Color = isDest ? Color(red: 0.92, green: 0.76, blue: 0.42) : Color(red: 0.16, green: 0.17, blue: 0.19)
                c.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(col))
                c.stroke(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(Color.white.opacity(0.7)), lineWidth: 1)
                c.draw(Text(w.kind.letter).font(Neon.font(8, .heavy)).foregroundColor(isDest ? Neon.ink : Color.white), at: p)
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
            c.fill(arrow, with: .color(Color.white))
            c.stroke(arrow, with: .color(Neon.ink), lineWidth: 1)
            // north marker
            let nr: CGFloat = size.width * 0.5 - 9
            let nx: CGFloat = center.x + CGFloat(sinf(-h)) * nr
            let ny: CGFloat = center.y - CGFloat(cosf(-h)) * nr
            c.draw(Text("N").font(Neon.mono(9, .semibold)).foregroundColor(Neon.dim), at: CGPoint(x: nx, y: ny))
        }
    }
}

// MARK: - navigation guidance (top centre, unobtrusive)

struct NavGuidanceView: View {
    @ObservedObject var state: GameState

    private func distanceText(_ d: Float) -> String {
        if d >= 1000 { return String(format: "%.1f km", d / 1000) }
        return "\(Int((d / 10).rounded()) * 10) m"
    }

    var body: some View {
        if let n = state.navigation, (state.mode == .driving || state.mode == .onFoot), state.race == nil {
            let inset: UIEdgeInsets = ScreenInsets.current
            HStack(spacing: 10) {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Color(red: 0.92, green: 0.76, blue: 0.42))
                    .rotationEffect(.radians(Double(-n.bearing)))
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text(n.name).font(Neon.font(13, .semibold)).foregroundColor(.white).lineLimit(1)
                    Text(distanceText(n.distance)).font(Neon.mono(11, .medium)).foregroundColor(Neon.dim)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Color.black.opacity(0.5)))
            .overlay(Capsule().stroke(Neon.hairline, lineWidth: 1))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, max(inset.top, 6) + 8)
        }
    }
}

// MARK: - wanted level

struct WantedStarsView: View {
    @ObservedObject var state: GameState

    var body: some View {
        if state.wanted > 0 && (state.mode == .driving || state.mode == .onFoot) {
            let inset: UIEdgeInsets = ScreenInsets.current
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    Image(systemName: "star.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(i < state.wanted ? Color(red: 0.95, green: 0.78, blue: 0.34) : Color.white.opacity(0.18))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.5)))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, max(inset.top, 6) + 52)
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
                    Text("P\(r.position)").font(Neon.font(28, .semibold)).foregroundColor(.white)
                    Text("/ \(r.total)").font(Neon.mono(12, .medium)).foregroundColor(Neon.dim)
                    Spacer(minLength: 8)
                    Text("LAP \(min(r.lap, r.laps))/\(r.laps)").font(Neon.mono(13, .semibold)).foregroundColor(.white)
                }
                Text(fmt(r.raceTime)).font(Neon.mono(18, .semibold)).foregroundColor(.white)
                HStack(spacing: 8) {
                    Text("LAP").font(Neon.mono(9, .medium)).foregroundColor(Neon.dim)
                    Text(fmt(r.lapTime)).font(Neon.mono(12, .medium)).foregroundColor(.white)
                    Text("BEST").font(Neon.mono(9, .medium)).foregroundColor(Neon.dim)
                    Text(fmt(r.bestLap)).font(Neon.mono(12, .medium)).foregroundColor(Neon.amber)
                }
                if r.wrongWay {
                    Text("WRONG WAY").font(Neon.font(14, .semibold)).foregroundColor(Neon.red)
                }
            }
            .padding(10)
            .frame(width: 210)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Neon.hairline, lineWidth: 1))
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
            Text(c > 0 ? "\(c)" : "GO")
                .font(Font.system(size: 110, weight: .semibold, design: .default))
                .foregroundColor(.white)
                .shadow(color: Color.black.opacity(0.5), radius: 10)
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
                Image(systemName: "hand.tap.fill").foregroundColor(Color(red: 0.92, green: 0.76, blue: 0.42))
                Text(p).font(Neon.font(15, .semibold)).foregroundColor(.white)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Capsule().fill(Color.black.opacity(0.62)))
            .overlay(Capsule().stroke(Neon.hairline, lineWidth: 1))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, max(inset.bottom, 8) + (state.mode == .driving ? 92 : 96))
        }
    }
}

struct ToastView: View {
    @ObservedObject var state: GameState
    var body: some View {
        if let t = state.toast {
            let inset: UIEdgeInsets = ScreenInsets.current
            Text(t.text)
                .font(Neon.font(14, .medium))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(Capsule().fill(Neon.panel.opacity(0.94)))
                .overlay(Capsule().stroke(Neon.hairline, lineWidth: 1))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, max(inset.top, 6) + 96)
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
