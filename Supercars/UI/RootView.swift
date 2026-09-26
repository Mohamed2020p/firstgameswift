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
        case .map:
            MapScreen(ctx: ctx)
        case .developer:
            DeveloperView(ctx: ctx)
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

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.03, green: 0.035, blue: 0.04), Color(red: 0.08, green: 0.085, blue: 0.095)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 26) {
                LogoView(size: 54)
                VStack(spacing: 10) {
                    ProgressBar(progress: CGFloat(state.loadingProgress))
                        .frame(width: 320, height: 3)
                    Text(state.loadingText)
                        .font(Neon.font(12, .regular))
                        .foregroundColor(Neon.dim)
                }
            }
        }
    }
}

struct ProgressBar: View {
    let progress: CGFloat
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: max(6, geo.size.width * min(1, max(0, progress))))
            }
        }
    }
}

// MARK: - Fade (sleep) overlay

struct FadeOverlay: View {
    @ObservedObject var state: GameState
    var body: some View {
        ZStack {
            Color.black.opacity(Double(state.fade))
            if let t = state.fadeText, state.fade > 0.6 {
                VStack(spacing: 8) {
                    Image(systemName: "moon.stars.fill").font(.system(size: 34)).foregroundColor(Neon.dim)
                    Text(t).font(Neon.font(15, .regular)).foregroundColor(Neon.dim)
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
                Text("PAUSED").font(Neon.font(26, .semibold)).tracking(4).foregroundColor(.white)
                Text("c0derz  •  \(ctx.state.clockString)  •  Day \(ctx.state.day)").font(Neon.mono(12, .regular)).foregroundColor(Neon.dim)
                VStack(spacing: 10) {
                    Button("Resume") { ctx.audio.play(SFX.uiConfirm, volume: 0.8, rate: 1, position: nil); ctx.resume() }
                        .buttonStyle(NeonButtonStyle(filled: true))
                    Button("Map") {
                        ctx.audio.play(SFX.uiTap, volume: 0.8, rate: 1, position: nil)
                        ctx.state.screen = .none
                        ctx.state.isPaused = false
                        ctx.openMap()
                    }
                    .buttonStyle(NeonButtonStyle())
                    Button("Settings") { ctx.audio.play(SFX.uiTap, volume: 0.8, rate: 1, position: nil); openSettings() }
                        .buttonStyle(NeonButtonStyle())
                    if ctx.dev?.isUnlocked == true {
                        Button("Developer tools") {
                            ctx.audio.play(SFX.uiTap, volume: 0.8, rate: 1, position: nil)
                            ctx.state.screen = .developer
                        }
                        .buttonStyle(NeonButtonStyle())
                    }
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
                        .buttonStyle(NeonButtonStyle())
                    }
                    Button("Save and quit to menu") {
                        ctx.audio.play(SFX.uiBack, volume: 0.8, rate: 1, position: nil)
                        ctx.returnToMenu()
                    }
                    .buttonStyle(NeonButtonStyle())
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
                Text(headline).font(Neon.font(28, .semibold)).tracking(2).foregroundColor(.white)
                if let r = state.race {
                    Text("Prize: $\(r.prize)").font(Neon.mono(15, .medium)).foregroundColor(Neon.amber)
                    VStack(spacing: 6) {
                        ForEach(r.results) { row in
                            HStack {
                                Text("\(row.position)").font(Neon.mono(14, .semibold)).frame(width: 28, alignment: .leading)
                                Text(row.name).font(Neon.font(14, row.isPlayer ? .semibold : .regular)).frame(width: 130, alignment: .leading)
                                Spacer()
                                Text(timeString(row.totalTime)).font(Neon.mono(13, .regular)).frame(width: 90, alignment: .trailing)
                                Text(timeString(row.bestLap)).font(Neon.mono(13, .regular)).foregroundColor(Neon.dim).frame(width: 90, alignment: .trailing)
                            }
                            .foregroundColor(row.isPlayer ? Color.white : Color.white.opacity(0.8))
                            .padding(.horizontal, 12).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(row.isPlayer ? Color.white.opacity(0.10) : Color.clear))
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
                    .buttonStyle(NeonButtonStyle(filled: true))
                    Button("Back to the city") {
                        ctx.state.screen = .none
                        ctx.stopRace()
                    }
                    .buttonStyle(NeonButtonStyle())
                }
            }
            .padding(24)
            .glassPanel()
        }
    }

    private var headline: String {
        guard let r = state.race else { return "RACE OVER" }
        for row in r.results where row.isPlayer {
            if row.position == 1 { return "VICTORY" }
            return "FINISHED  P\(row.position)"
        }
        return "RACE OVER"
    }
}
