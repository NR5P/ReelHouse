import SwiftUI
import UIKit

// Brand accent colors only - everything else (backgrounds, primary/secondary text, card
// surfaces) comes from the system so the app follows tvOS's light/dark appearance, with
// the brand green/cyan kept as an accent layered on top.
enum ReelHouseTheme {
    // The wordmark's fill: marquee gold running into curtain red, like a lit sign.
    static let marquee = LinearGradient(colors: [gold, amber, curtain], startPoint: .leading, endPoint: .trailing)

    // "Movie palace": gold marquee bulbs and red velvet curtains. Gold is the main accent
    // (buttons, selection, the wordmark); curtain red is the second one. `red` (errors and
    // destructive actions) is a brighter orange-red so it never reads as the curtain accent.
    static let gold = Color(light: .init(red: 0.66, green: 0.40, blue: 0.04),
                            dark: .init(red: 1.0, green: 0.76, blue: 0.29))
    static let goldDim = Color(light: .init(red: 0.48, green: 0.29, blue: 0.02),
                               dark: .init(red: 0.79, green: 0.54, blue: 0.12))
    static let curtain = Color(light: .init(red: 0.70, green: 0.13, blue: 0.16),
                               dark: .init(red: 0.89, green: 0.24, blue: 0.24))
    static let amber = Color(light: .init(red: 0.64, green: 0.29, blue: 0.0),
                             dark: .init(red: 1.0, green: 0.60, blue: 0.24))
    static let red = Color(light: .init(red: 0.76, green: 0.25, blue: 0.05),
                           dark: .init(red: 1.0, green: 0.35, blue: 0.21))

    // Ceiling on the clip/snapshot at the top of a detail screen. A detail screen is a ScrollView,
    // so its height proposal is unbounded and a 16:9 image asked to fit the full 1800pt content
    // width sizes itself to ~1010pt - taller than the 1080pt screen has left under the title,
    // which pushes its own bottom edge and everything after it off the screen. It scrolls, but on
    // tvOS scrolling means moving focus, and the media is the one thing up there that isn't
    // focusable, so it reads as simply cut off. This leaves room for the detail card below it.
    static let detailMediaMaxHeight: CGFloat = 560
}

struct ReelHouseCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(.primary.opacity(0.08))
            }
    }
}

extension View {
    func reelHouseCard() -> some View { modifier(ReelHouseCard()) }
}

// The label colour for a standard (non-card) tvOS button or Menu. Left alone, a button under the
// app's green tint draws its title in the tint - a blank green pill - and a title forced white
// vanishes the moment focus turns the pill white. So: light until focused, dark once it is.
// Goes INSIDE the label (or on the Menu's label): \.isFocused reads the nearest focusable
// ancestor, so on the Button itself, or on a container around several, it never turns true.
struct FocusContrastForeground: ViewModifier {
    @Environment(\.isFocused) private var isFocused
    var unfocused: Color

    func body(content: Content) -> some View {
        content.foregroundStyle(isFocused ? Color.black : unfocused)
    }
}

extension View {
    /// `unfocused` is `.white` over artwork or video; `.primary` on the app's own surfaces, so
    /// it still reads in light mode.
    func focusContrastForeground(unfocused: Color = .primary) -> some View {
        modifier(FocusContrastForeground(unfocused: unfocused))
    }
}

// The app-wide default button style (set in RootView): the platform's own button, with the label
// coloured by FocusContrastForeground. Under the green tint a focused tvOS button fills with the
// bright gold and keeps a pale label - Surprise Me, the library's filter buttons and the movie
// page's Play / Mark as Watched were all close to blank under the remote. A label that sets its
// own colour still wins; one forced white needs focusContrastForeground(unfocused: .white).
// Lists and Forms put .automatic back: their rows already go white with a dark label on focus,
// and keep the green and red their titles are drawn in. Menus aren't buttons, so a Menu label
// carries focusContrastForeground itself.
struct FocusContrastButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label
                .focusContrastForeground(unfocused: configuration.role == .destructive ? ReelHouseTheme.red : .primary)
        }
        .buttonStyle(.automatic)
    }
}

extension Color {
    init(light: Color, dark: Color) {
        self.init(UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
    }
}

struct StatusChip: View {
    let text: String
    let systemImage: String?
    let color: Color

    init(_ text: String, systemImage: String? = nil, color: Color) {
        self.text = text
        self.systemImage = systemImage
        self.color = color
    }

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption.bold())
        .foregroundStyle(color)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        // A dark backing under the tint: these chips sit on top of artwork as often
        // as on the app's own surfaces, and a purely translucent fill disappears completely
        // over a bright frame - the LIVE badge was unreadable against anything but a dark scene.
        .background(.black.opacity(0.55), in: Capsule())
        .background(color.opacity(0.18), in: Capsule())
        .overlay { Capsule().stroke(color.opacity(0.55)) }
    }
}
