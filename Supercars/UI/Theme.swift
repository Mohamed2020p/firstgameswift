import SwiftUI
import UIKit

// MARK: - Premium automotive look: black / charcoal / graphite / white / soft grey, one restrained accent (warm brass) and a muted red
// for warnings.  No glow, no gradients on strokes, no neon.  The palette type keeps the name `Neon` only so existing call sites
// keep compiling; every value below is a calm, desaturated colour.

enum Neon {
    /// primary accent: soft platinum (was neon green)
    static let green = Color(red: 0.86, green: 0.88, blue: 0.90)
    /// secondary accent: muted brass (was magenta)
    static let magenta = Color(red: 0.78, green: 0.66, blue: 0.44)
    /// info tone: cool steel (was cyan)
    static let cyan = Color(red: 0.62, green: 0.70, blue: 0.78)
    /// caution: amber, desaturated
    static let amber = Color(red: 0.90, green: 0.70, blue: 0.32)
    /// warning: muted red
    static let red = Color(red: 0.80, green: 0.27, blue: 0.25)
    static let ink = Color(red: 0.035, green: 0.037, blue: 0.042)
    static let panel = Color(red: 0.085, green: 0.09, blue: 0.10)
    static let dim = Color.white.opacity(0.62)
    static let faint = Color.white.opacity(0.12)
    static let hairline = Color.white.opacity(0.16)

    static func font(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        return Font.system(size: size, weight: weight, design: .default)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        return Font.system(size: size, weight: weight, design: .monospaced)
    }
}

enum ScreenInsets {
    @MainActor
    static var current: UIEdgeInsets {
        let scene: UIWindowScene? = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window: UIWindow? = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first
        return window?.safeAreaInsets ?? UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }
}

/// Buttons: flat graphite or platinum fill, hairline border, no glow.
struct NeonButtonStyle: ButtonStyle {
    var tint: Color = Neon.green
    var filled: Bool = false
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed: Bool = configuration.isPressed
        return configuration.label
            .font(Neon.font(compact ? 13 : 16, .semibold))
            .foregroundColor(filled ? Neon.ink : Color.white.opacity(0.92))
            .padding(.horizontal, compact ? 14 : 22)
            .padding(.vertical, compact ? 8 : 12)
            .background(RoundedRectangle(cornerRadius: 8).fill(filled ? Neon.green : Color.white.opacity(pressed ? 0.16 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(filled ? Color.clear : Neon.hairline, lineWidth: 1))
            .opacity(pressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.1), value: pressed)
    }
}

/// Panel: dark graphite with a hairline border and a soft drop shadow.
struct GlassPanel: ViewModifier {
    var tint: Color = Neon.green
    var radius: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius)
                    .fill(Neon.panel.opacity(0.88))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .stroke(Neon.hairline, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.45), radius: 16, x: 0, y: 6)
    }
}

extension View {
    func glassPanel(tint: Color = Neon.green, radius: CGFloat = 14) -> some View {
        modifier(GlassPanel(tint: tint, radius: radius))
    }
}

/// The "SUPERCARS" wordmark: clean white capitals, the c0derz signature small underneath.
struct LogoView: View {
    var size: CGFloat = 64

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SUPERCARS")
                .font(.system(size: size, weight: .semibold, design: .default))
                .tracking(size * 0.10)
                .foregroundColor(.white)
            HStack(spacing: 8) {
                Rectangle().fill(Neon.magenta).frame(width: size * 0.45, height: 1.5)
                Text("c0derz")
                    .font(Neon.font(size * 0.24, .medium))
                    .tracking(size * 0.05)
                    .foregroundColor(Neon.dim)
            }
        }
    }
}

struct NeonToggleRow: View {
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Neon.font(15, .medium)).foregroundColor(.white)
                if let s = subtitle { Text(s).font(Neon.font(11, .regular)).foregroundColor(Neon.dim) }
            }
        }
        .tint(Neon.magenta)
    }
}

struct NeonSliderRow: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(Neon.font(15, .medium)).foregroundColor(.white)
                Spacer()
                Text(valueText).font(Neon.mono(13, .medium)).foregroundColor(Neon.dim)
            }
            Slider(value: $value, in: range).tint(Neon.magenta)
        }
    }
}

struct NeonPickerRow<T: Hashable>: View {
    let title: String
    let options: [T]
    let label: (T) -> String
    @Binding var selection: T

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Neon.font(15, .medium)).foregroundColor(.white)
            HStack(spacing: 6) {
                ForEach(options.indices, id: \.self) { i in
                    let opt: T = options[i]
                    let on: Bool = opt == selection
                    Button(action: { selection = opt }) {
                        Text(label(opt))
                            .font(Neon.font(12, .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundColor(on ? Neon.ink : Color.white.opacity(0.85))
                            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Neon.green : Color.white.opacity(0.07)))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? Color.clear : Neon.hairline, lineWidth: 1))
                    }
                }
            }
        }
    }
}

extension Binding where Value == Float {
    /// Slider helper: Float property -> Double binding
    func asDouble() -> Binding<Double> {
        return Binding<Double>(get: { Double(self.wrappedValue) }, set: { self.wrappedValue = Float($0) })
    }
}
