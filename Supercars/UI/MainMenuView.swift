import SwiftUI
import UIKit

// MARK: - Start menu (over the slow cinematic orbit around the Porsche): clean wordmark, a short list of actions, a quiet stats card.

struct MainMenuView: View {
    let ctx: GameContext
    let openSettings: () -> Void
    let openCredits: () -> Void

    @ObservedObject private var save: SaveStore
    @State private var confirmNew: Bool = false
    @State private var appear: Bool = false

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
            LinearGradient(colors: [Color.black.opacity(0.88), Color.black.opacity(0.40), Color.clear], startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [Color.clear, Color.black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
            HStack(alignment: .center, spacing: 0) {
                VStack(alignment: .leading, spacing: 22) {
                    LogoView(size: 54)
                        .onTapGesture(count: 7) {
                            // hidden: seven quick taps on the wordmark unlock the local developer tools
                            ctx.dev?.toggleUnlocked()
                        }
                    VStack(alignment: .leading, spacing: 10) {
                        if save.hasProgress {
                            Button(action: { tap(); ctx.startGame(continueSave: true) }) {
                                Label("Continue", systemImage: "play.fill").frame(width: 230, alignment: .leading)
                            }
                            .buttonStyle(NeonButtonStyle(filled: true))
                        }
                        Button(action: {
                            tap()
                            if save.hasProgress { confirmNew = true } else { ctx.startGame(continueSave: false) }
                        }) {
                            Label(save.hasProgress ? "New game" : "Start", systemImage: save.hasProgress ? "arrow.counterclockwise" : "play.fill")
                                .frame(width: 230, alignment: .leading)
                        }
                        .buttonStyle(NeonButtonStyle(filled: !save.hasProgress))
                        HStack(spacing: 10) {
                            Button(action: { tap(); openSettings() }) {
                                Label("Settings", systemImage: "slider.horizontal.3").frame(width: 130, alignment: .leading)
                            }
                            .buttonStyle(NeonButtonStyle(compact: true))
                            Button(action: { tap(); openCredits() }) {
                                Label("Credits", systemImage: "info.circle").frame(width: 90, alignment: .leading)
                            }
                            .buttonStyle(NeonButtonStyle(compact: true))
                        }
                    }
                    Text("Tilt to steer  ·  drive anywhere  ·  race, tune, explore")
                        .font(Neon.font(11, .regular))
                        .foregroundColor(Neon.dim.opacity(0.85))
                }
                .padding(.leading, max(inset.left, 20) + 26)
                .offset(x: appear ? 0 : -40)
                .opacity(appear ? 1 : 0)
                Spacer()
                StatCard(save: save)
                    .padding(.trailing, max(inset.right, 20) + 26)
                    .offset(x: appear ? 0 : 40)
                    .opacity(appear ? 1 : 0)
            }
        }
        .alert("Start a new game?", isPresented: $confirmNew) {
            Button("Erase and start", role: .destructive) { ctx.startGame(continueSave: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your money, garage upgrades and lap records will be reset.")
        }
        .onAppear {
            withAnimation(Animation.easeOut(duration: 0.6)) { appear = true }
        }
    }
}

struct StatCard: View {
    @ObservedObject var save: SaveStore

    private func row(_ title: String, _ value: String, _ tint: Color) -> some View {
        HStack {
            Text(title).font(Neon.font(10, .medium)).tracking(1).foregroundColor(Neon.dim)
            Spacer(minLength: 16)
            Text(value).font(Neon.mono(13, .semibold)).foregroundColor(tint)
        }
    }

    var body: some View {
        let d: SaveData = save.data
        let hours: Int = Int(d.playSeconds / 3600)
        let mins: Int = Int(d.playSeconds / 60) % 60
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "person.crop.circle.fill").foregroundColor(Neon.dim)
                Text(d.playerName).font(Neon.font(17, .semibold)).foregroundColor(.white)
            }
            Divider().overlay(Neon.faint)
            row("MONEY", "$\(d.money)", Neon.amber)
            row("ENGINE", EngineSpec.spec(d.car.engine).type.rawValue.uppercased(), Color.white)
            row("DAY", "\(d.day)", Color.white)
            row("RACES / WINS", "\(d.races) / \(d.wins)", Color.white)
            row("DISTANCE", String(format: "%.1f km", d.distanceKm), Color.white)
            row("PLAY TIME", "\(hours)h \(mins)m", Neon.dim)
        }
        .padding(16)
        .frame(width: 250)
        .glassPanel()
    }
}
