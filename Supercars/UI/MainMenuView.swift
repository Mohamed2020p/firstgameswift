import SwiftUI
import UIKit

// MARK: - Start menu (over the slow cinematic orbit around the Porsche)

struct MainMenuView: View {
    let ctx: GameContext
    let openSettings: () -> Void
    let openCredits: () -> Void

    @ObservedObject private var save: SaveStore
    @State private var confirmNew: Bool = false
    @State private var appear: Bool = false
    @State private var scan: CGFloat = 0

    init(ctx: GameContext, openSettings: @escaping () -> Void, openCredits: @escaping () -> Void) {
        self.ctx = ctx
        self.openSettings = openSettings
        self.openCredits = openCredits
        _save = ObservedObject(wrappedValue: ctx.save)
    }

    private func tap() {
        ctx.audio.play(SFX.uiTap, volume: 0.8, rate: 1, position: nil)
        ctx.input.haptic(HapticKind.light)
    }

    var body: some View {
        let inset: UIEdgeInsets = ScreenInsets.current
        ZStack {
            LinearGradient(colors: [Neon.ink.opacity(0.92), Neon.ink.opacity(0.35), Color.clear], startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [Color.clear, Neon.ink.opacity(0.75)], startPoint: .center, endPoint: .bottom)
            HStack(alignment: .center, spacing: 0) {
                VStack(alignment: .leading, spacing: 18) {
                    LogoView(size: 60)
                    VStack(alignment: .leading, spacing: 10) {
                        if save.hasProgress {
                            Button(action: { tap(); ctx.startGame(continueSave: true) }) {
                                Label("CONTINUE", systemImage: "play.fill").frame(width: 230, alignment: .leading)
                            }
                            .buttonStyle(NeonButtonStyle(tint: Neon.green, filled: true))
                        }
                        Button(action: {
                            tap()
                            if save.hasProgress { confirmNew = true } else { ctx.startGame(continueSave: false) }
                        }) {
                            Label(save.hasProgress ? "NEW GAME" : "START", systemImage: save.hasProgress ? "arrow.counterclockwise" : "play.fill")
                                .frame(width: 230, alignment: .leading)
                        }
                        .buttonStyle(NeonButtonStyle(tint: save.hasProgress ? Neon.cyan : Neon.green, filled: !save.hasProgress))
                        HStack(spacing: 10) {
                            Button(action: { tap(); openSettings() }) {
                                Label("SETTINGS", systemImage: "slider.horizontal.3").frame(width: 130, alignment: .leading)
                            }
                            .buttonStyle(NeonButtonStyle(tint: Neon.magenta, compact: true))
                            Button(action: { tap(); openCredits() }) {
                                Label("CREDITS", systemImage: "info.circle").frame(width: 90, alignment: .leading)
                            }
                            .buttonStyle(NeonButtonStyle(tint: Neon.dim.opacity(0.9), compact: true))
                        }
                    }
                    Text("Tilt your phone to steer  •  drive anywhere  •  race, tune, sleep")
                        .font(Neon.mono(10, .regular))
                        .foregroundColor(Neon.dim.opacity(0.8))
                }
                .padding(.leading, max(inset.left, 20) + 26)
                .offset(x: appear ? 0 : -60)
                .opacity(appear ? 1 : 0)
                Spacer()
                StatCard(save: save)
                    .padding(.trailing, max(inset.right, 20) + 26)
                    .offset(x: appear ? 0 : 60)
                    .opacity(appear ? 1 : 0)
            }
            // scan line
            GeometryReader { geo in
                Rectangle()
                    .fill(LinearGradient(colors: [Color.clear, Neon.green.opacity(0.10), Color.clear], startPoint: .top, endPoint: .bottom))
                    .frame(height: 60)
                    .offset(y: scan * (geo.size.height + 60) - 60)
            }
            .allowsHitTesting(false)
        }
        .alert("Start a new game?", isPresented: $confirmNew) {
            Button("Erase and start", role: .destructive) { ctx.startGame(continueSave: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your money, garage upgrades and lap records will be reset.")
        }
        .onAppear {
            withAnimation(Animation.easeOut(duration: 0.7)) { appear = true }
            withAnimation(Animation.linear(duration: 5).repeatForever(autoreverses: false)) { scan = 1 }
        }
    }
}

struct StatCard: View {
    @ObservedObject var save: SaveStore

    private func row(_ title: String, _ value: String, _ tint: Color) -> some View {
        HStack {
            Text(title).font(Neon.mono(11, .bold)).foregroundColor(Neon.dim)
            Spacer(minLength: 16)
            Text(value).font(Neon.mono(14, .heavy)).foregroundColor(tint)
        }
    }

    var body: some View {
        let d: SaveData = save.data
        let hours: Int = Int(d.playSeconds / 3600)
        let mins: Int = Int(d.playSeconds / 60) % 60
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "person.crop.circle.fill").foregroundColor(Neon.green)
                Text(d.playerName).font(Neon.font(18, .heavy)).foregroundColor(.white)
            }
            Divider().overlay(Neon.faint)
            row("MONEY", "$\(d.money)", Neon.amber)
            row("ENGINE", EngineSpec.spec(d.car.engine).type.rawValue.uppercased(), Neon.green)
            row("DAY", "\(d.day)", Neon.cyan)
            row("RACES / WINS", "\(d.races) / \(d.wins)", Neon.magenta)
            row("DISTANCE", String(format: "%.1f km", d.distanceKm), Neon.cyan)
            row("PLAY TIME", "\(hours)h \(mins)m", Neon.dim)
        }
        .padding(16)
        .frame(width: 250)
        .glassPanel(tint: Neon.cyan)
    }
}
