import SwiftUI
import Combine

// MARK: - RootView: the whole 2D layer on top of the SCNView. It only listens to `screen` / `mode` (not to the per-frame HUD numbers),
// so a 60 Hz speedometer update never re-evaluates the menus.

struct RootView: View {
    let ctx: GameContext
    @State private var screen: MenuScreen = .none
    @State private var mode: GameMode = .loading
    @State private var settingsReturn: MenuScreen = .main

    init(ctx: GameContext) {
        self.ctx = ctx
    }

    var body: some View {
        ZStack {
            if mode == .loading {
                LoadingView(state: ctx.state)
            } else {
                screens
            }
            FadeOverlay(state: ctx.state)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .onReceive(ctx.state.$screen.removeDuplicates()) { (s: MenuScreen) in screen = s }
        .onReceive(ctx.state.$mode.removeDuplicates()) { (m: GameMode) in mode = m }
    }

    @ViewBuilder
    private var screens: some View {
        switch screen {
        case .main:
            MainMenuView(ctx: ctx, openSettings: { openSettings(from: .main) }, openCredits: { ctx.state.screen = .credits })
        case .pause:
            PauseView(ctx: ctx, openSettings: { openSettings(from: .pause) })
        case .settings:
            SettingsView(ctx: ctx, initialTab: .graphics, onClose: { ctx.state.screen = settingsReturn })
        case .credits:
            SettingsView(ctx: ctx, initialTab: .credits, onClose: { ctx.state.screen = .main })
        case .garage:
            GarageView(ctx: ctx)
        case .results:
            ResultsView(ctx: ctx)
        case .raceSetup, .none:
            GameplayView(ctx: ctx)
        }
    }

    private func openSettings(from s: MenuScreen) {
        settingsReturn = s
        ctx.state.screen = .settings
    }
}

// MARK: - Loading

struct LoadingView: View {
    @ObservedObject var state: GameState
    @State private var spin: Bool = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Neon.ink, Color(red: 0.05, green: 0.02, blue: 0.10)], startPoint: .top, endPoint: .bottom)
            GridBackdrop()
            VStack(spacing: 22) {
                LogoView(size: 58)
                VStack(spacing: 10) {
                    ProgressBar(progress: CGFloat(state.loadingProgress))
                        .frame(width: 340, height: 10)
                    Text(state.loadingText)
                        .font(Neon.mono(13, .semibold))
                        .foregroundColor(Neon.dim)
                }
                HStack(spacing: 8) {
                    Circle().fill(Neon.green).frame(width: 8, height: 8).opacity(spin ? 1 : 0.2)
                    Circle().fill(Neon.cyan).frame(width: 8, height: 8).opacity(spin ? 0.2 : 1)
                    Circle().fill(Neon.magenta).frame(width: 8, height: 8).opacity(spin ? 1 : 0.2)
                }
                Text("c0derz  •  free-roam supercar city")
                    .font(Neon.mono(11, .regular))
                    .foregroundColor(Neon.dim.opacity(0.7))
            }
        }
        .onAppear {
            withAnimation(Animation.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { spin = true }
        }
    }
}

struct ProgressBar: View {
    let progress: CGFloat
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule()
                    .fill(LinearGradient(colors: [Neon.green, Neon.cyan, Neon.magenta], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(8, geo.size.width * min(1, max(0, progress))))
                    .shadow(color: Neon.green.opacity(0.6), radius: 6)
            }
        }
    }
}

/// perspective neon grid used behind the loading screen and menus
struct GridBackdrop: View {
    @State private var phase: CGFloat = 0
    var body: some View {
        Canvas { ctx, size in
            let horizon: CGFloat = size.height * 0.55
            var p = Path()
            let lines = 16
            for i in -lines...lines {
                let x0: CGFloat = size.width * 0.5 + CGFloat(i) * 10
                let x1: CGFloat = size.width * 0.5 + CGFloat(i) * size.width * 0.22
                p.move(to: CGPoint(x: x0, y: horizon))
                p.addLine(to: CGPoint(x: x1, y: size.height))
            }
            for j in 0..<10 {
                let t: CGFloat = (CGFloat(j) + phase).truncatingRemainder(dividingBy: 10) / 10
                let y: CGFloat = horizon + (size.height - horizon) * t * t
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: size.width, y: y))
            }
            ctx.stroke(p, with: .color(Neon.magenta.opacity(0.22)), lineWidth: 1)
        }
        .onAppear {
            withAnimation(Animation.linear(duration: 4).repeatForever(autoreverses: false)) { phase = 1 }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Fade (sleep) overlay

struct FadeOverlay: View {
    @ObservedObject var state: GameState
    var body: some View {
        ZStack {
            Color.black.opacity(Double(state.fade))
            if let t = state.fadeText, state.fade > 0.6 {
                VStack(spacing: 10) {
                    Text("Zzz").font(Neon.font(44, .heavy)).foregroundColor(Neon.cyan)
                    Text(t).font(Neon.mono(16, .semibold)).foregroundColor(Neon.dim)
                }
            }
        }
        .allowsHitTesting(state.fade > 0.01)
        .animation(nil, value: state.fade)
    }
}

// MARK: - Pause

struct PauseView: View {
    let ctx: GameContext
    let openSettings: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
            VStack(spacing: 14) {
                Text("PAUSED").font(Neon.font(34, .black)).foregroundColor(.white)
                Text("c0derz  •  \(ctx.state.clockString)  •  Day \(ctx.state.day)").font(Neon.mono(13)).foregroundColor(Neon.dim)
                VStack(spacing: 10) {
                    Button("Resume") { ctx.audio.play(SFX.uiConfirm, volume: 0.8, rate: 1, position: nil); ctx.resume() }
                        .buttonStyle(NeonButtonStyle(tint: Neon.green, filled: true))
                    Button("Settings") { ctx.audio.play(SFX.uiTap, volume: 0.8, rate: 1, position: nil); openSettings() }
                        .buttonStyle(NeonButtonStyle(tint: Neon.cyan))
                    if ctx.state.mode == .driving {
                        Button("Reset car to the street") {
                            ctx.audio.play(SFX.uiTap, volume: 0.8, rate: 1, position: nil)
                            let p: Vec3 = ctx.car.state.position
                            if let r = ctx.world.nearestRoadPoint(to: Vec2(p.x, p.z)) {
                                ctx.car.place(position: Vec3(r.point.x, 0, r.point.y), heading: r.heading)
                            }
                            ctx.car.repair()
                            ctx.resume()
                        }
                        .buttonStyle(NeonButtonStyle(tint: Neon.amber))
                    }
                    Button("Save and quit to menu") {
                        ctx.audio.play(SFX.uiBack, volume: 0.8, rate: 1, position: nil)
                        ctx.returnToMenu()
                    }
                    .buttonStyle(NeonButtonStyle(tint: Neon.magenta))
                }
                .frame(width: 320)
            }
            .padding(28)
            .glassPanel()
        }
    }
}

// MARK: - Race results

struct ResultsView: View {
    let ctx: GameContext
    @ObservedObject private var state: GameState

    init(ctx: GameContext) {
        self.ctx = ctx
        _state = ObservedObject(wrappedValue: ctx.state)
    }

    private func timeString(_ t: Double) -> String {
        if t <= 0 { return "--:--.--" }
        let m: Int = Int(t) / 60
        let s: Double = t - Double(m * 60)
        return String(format: "%d:%05.2f", m, s)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
            VStack(spacing: 12) {
                Text(headline).font(Neon.font(34, .black)).foregroundColor(Neon.green)
                if let r = state.race {
                    Text("Prize: $\(r.prize)").font(Neon.mono(16, .bold)).foregroundColor(Neon.amber)
                    VStack(spacing: 6) {
                        ForEach(r.results) { row in
                            HStack {
                                Text("\(row.position)").font(Neon.mono(15, .heavy)).frame(width: 28, alignment: .leading)
                                Text(row.name).font(Neon.font(15, row.isPlayer ? .heavy : .semibold)).frame(width: 130, alignment: .leading)
                                Spacer()
                                Text(timeString(row.totalTime)).font(Neon.mono(14)).frame(width: 90, alignment: .trailing)
                                Text(timeString(row.bestLap)).font(Neon.mono(14)).foregroundColor(Neon.cyan).frame(width: 90, alignment: .trailing)
                            }
                            .foregroundColor(row.isPlayer ? Neon.green : .white)
                            .padding(.horizontal, 12).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 8).fill(row.isPlayer ? Neon.green.opacity(0.12) : Color.clear))
                        }
                    }
                    .frame(width: 420)
                }
                HStack(spacing: 14) {
                    Button("Race again") {
                        ctx.state.screen = .none
                        ctx.stopRace()
                        ctx.startRace(laps: state.race?.laps ?? 3)
                    }
                    .buttonStyle(NeonButtonStyle(tint: Neon.green, filled: true))
                    Button("Back to the city") {
                        ctx.state.screen = .none
                        ctx.stopRace()
                    }
                    .buttonStyle(NeonButtonStyle(tint: Neon.magenta))
                }
            }
            .padding(24)
            .glassPanel()
        }
    }

    private var headline: String {
        guard let r = state.race else { return "RACE OVER" }
        for row in r.results where row.isPlayer {
            if row.position == 1 { return "YOU WON!" }
            return "FINISHED  P\(row.position)"
        }
        return "RACE OVER"
    }
}
