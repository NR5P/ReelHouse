import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// Brand accent colors only - everything else (backgrounds, primary/secondary text, card
// surfaces) now comes from the system (.primary, .secondary, Material) so the app follows the
// user's light/dark appearance and matches other native apps, with the brand gold/curtain red kept
// as an accent layered on top rather than a full-screen reskin.
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
}

// Native Material-based card surface, replacing the old hand-painted panel/border combo -
// adapts to light/dark (and to context, e.g. sitting over a photo) automatically.
struct ReelHouseCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.primary.opacity(0.08))
            }
    }
}

extension View {
    func reelHouseCard() -> some View { modifier(ReelHouseCard()) }
}

// .borderedProminent under the app's green tint, with a label that can be read. The system draws
// a prominent label white, and in dark mode the fill is the bright gold - white on it is about
// 1.3:1, the Save / Play / Add buttons all but blank. Dark ink on the gold, as the web dashboard's
// primary buttons do; white stays on light mode's deep green. A disabled button keeps the
// system's own greyed label, since its fill isn't the gold any more.
struct ReelHouseProminentButtonStyle: PrimitiveButtonStyle {
    static let ink = Color(light: .white, dark: .black)

    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            InkedLabel(label: configuration.label)
        }
        // The system style underneath - this said .reelHouseProminent, i.e. itself, so every
        // button using it recursed until the stack ran out: the movie page's Play and every
        // other prominent button crashed the app the moment it was drawn.
        .buttonStyle(.borderedProminent)
    }

    private struct InkedLabel: View {
        @Environment(\.isEnabled) private var isEnabled
        let label: Configuration.Label

        var body: some View {
            if isEnabled { label.foregroundStyle(ReelHouseProminentButtonStyle.ink) } else { label }
        }
    }
}

extension PrimitiveButtonStyle where Self == ReelHouseProminentButtonStyle {
    static var reelHouseProminent: ReelHouseProminentButtonStyle { .init() }
}

// A text box that looks like one. Inside a grouped Form, SwiftUI's TextField draws no border of
// its own, so an empty field is a blank gap under its label with nothing about it to say it can
// be typed in - which is exactly the "where am I supposed to tap?" that the Location section's
// town and coordinates kept provoking. This draws the box: full row width, a faint fill, and a
// border that turns green and thickens while the field has the keyboard. The whole box is the
// tap target, not just the line of text inside it.
struct ReelHouseInputBox: ViewModifier {
    var isFocused: Bool
    var onTap: () -> Void

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 8) }

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: shape)
            .overlay {
                shape.strokeBorder(
                    isFocused ? ReelHouseTheme.gold : Color.secondary.opacity(0.4),
                    lineWidth: isFocused ? 2 : 1)
            }
            .contentShape(shape)
            .onTapGesture(perform: onTap)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

extension View {
    func reelHouseInputBox(focused: Bool = false, onTap: @escaping () -> Void = {}) -> some View {
        modifier(ReelHouseInputBox(isFocused: focused, onTap: onTap))
    }
}

// The gesture this platform actually has, so a hint can name it. Here rather than in any one
// screen because every typed field in the app says the same thing.
enum ReelHouseInput {
    #if os(macOS)
    static let typeVerb = "Click to type"
    static let typeVerbLower = "click to type"
    #else
    static let typeVerb = "Tap to type"
    static let typeVerbLower = "tap to type"
    #endif
}

// One field the user fills in by hand: its name above it, and a box below that looks like
// somewhere to type even when it is empty. The name stays visible once there is a value in the
// box - a placeholder doing double duty as the label vanishes the moment you type, which leaves
// a row of text with nothing saying what it is.
//
// Keyboard modifiers belong at the call site: .keyboardType, .textContentType and
// .textInputAutocapitalization all travel down the environment and reach the field inside.
// The same box without a label above it, for the handful of fields that sit in a row beside the
// button that acts on them - "Add a question" next to Add - where the button already says what
// the field is for and a label on top would only make the row taller.
struct ReelHouseInlineField: View {
    let prompt: String
    @Binding var text: String

    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(prompt))
            .labelsHidden()
            .focused($focused)
            .reelHouseInputBox(focused: focused) { focused = true }
    }
}

struct ReelHouseTextField: View {
    let label: String
    var prompt: String = ReelHouseInput.typeVerb
    @Binding var text: String
    var secure = false
    var axis: Axis = .horizontal

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // fixedSize so a label long enough to wrap makes the row taller instead of drawing
            // over whatever sits under it.
            Text(label).fixedSize(horizontal: false, vertical: true)
            Group {
                if secure {
                    // prompt:, not the title argument: macOS draws a field's title as a label
                    // beside the box and only prompt: as placeholder text inside it.
                    SecureField("", text: $text, prompt: Text(prompt))
                } else if axis == .vertical {
                    // A vertical-axis field measures to zero height inside a macOS Form, which
                    // leaves an empty pill with the value invisible inside it - the schedule
                    // editor's Payload box looked unfillable for exactly this reason. A line
                    // range gives it something to measure, and a field meant for several lines
                    // may as well show several.
                    TextField("", text: $text, prompt: Text(prompt), axis: .vertical)
                        .lineLimit(3...8)
                } else {
                    TextField("", text: $text, prompt: Text(prompt))
                }
            }
            .labelsHidden()
            .focused($focused)
            .reelHouseInputBox(focused: focused) { focused = true }
        }
    }
}

extension Color {
    /// A color that resolves differently per light/dark appearance, defined here in code
    /// (rather than the asset catalog) so the whole brand palette lives in one file.
    init(light: Color, dark: Color) {
        #if os(iOS)
        self.init(UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
        #elseif os(macOS)
        self.init(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
        #else
        self = light
        #endif
    }
}

// UIImage on iPhone and iPad, NSImage on the Mac - artwork is decoded and cached as one of these.
#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#elseif os(macOS)
import AppKit
typealias PlatformImage = NSImage
#endif
