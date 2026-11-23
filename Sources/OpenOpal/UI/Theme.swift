import SwiftUI

/// Open Opal's own look. The panel is drawn like the display on the back of a
/// camera: near black, so the picture is the brightest thing on screen, flat,
/// square-cornered, with numbers in a fixed-width face. One amber marks
/// whatever is switched on or being applied right now, and red marks a limit.
///
/// Nothing here uses the system's control styles. Every slider, switch and
/// button is drawn below, so the panel looks the same on every macOS version.
enum Opal {
    static let background = Color(red: 0.043, green: 0.043, blue: 0.047)
    static let line = Color.white.opacity(0.13)
    static let text = Color.white.opacity(0.94)
    static let dim = Color.white.opacity(0.58)
    static let faint = Color.white.opacity(0.36)
    /// On, selected, or being applied.
    static let accent = Color(red: 1.0, green: 0.70, blue: 0.14)
    /// A limit reached, or something that needs a look.
    static let warning = Color(red: 1.0, green: 0.42, blue: 0.33)
    static let danger = warning

    static let corner: CGFloat = 3

    static let label = Font.system(size: 12, weight: .regular)
    static let value = Font.system(size: 11.5, weight: .medium, design: .monospaced)
    static let note = Font.system(size: 11, weight: .regular)
    static let title = Font.system(size: 10, weight: .semibold, design: .monospaced)
}

extension EnvironmentValues {
    /// True while a section's explanations are showing.
    @Entry var showHelp = false
}

// MARK: - Text

/// The small spaced-out capitals that head a section or a status row.
struct Caps: View {
    let text: String
    var color = Opal.dim

    init(_ text: String, color: Color = Opal.dim) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(Opal.title)
            .tracking(0.8)
            .foregroundStyle(color)
    }
}

/// An explanation or a warning under a control. Explanations stay out of the
/// way until the section's question mark is pressed. Warnings always show.
struct Note: View {
    enum Tone { case hint, warning }
    @Environment(\.showHelp) private var showHelp
    let text: String
    let tone: Tone

    init(_ text: String, tone: Tone) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        if tone == .warning || showHelp {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if tone == .warning {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                }
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
            .font(Opal.note)
            .foregroundStyle(tone == .warning ? Opal.warning : Opal.dim)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A heading for a group of controls inside a section.
struct Sub: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Caps(text, color: Opal.faint)
            .padding(.top, 6)
    }
}

// MARK: - Sections

/// A group of settings that opens and closes. The question mark in its header
/// shows or hides every explanation inside it.
struct Fold<Content: View>: View {
    let title: String
    let about: String?
    @AppStorage private var open: Bool
    @State private var help = false
    @ViewBuilder var content: Content

    init(_ title: String, key: String, open: Bool = false, about: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.about = about
        _open = AppStorage(wrappedValue: open, "fold.\(key)")
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.snappy(duration: 0.18)) { open.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Opal.faint)
                            .rotationEffect(.degrees(open ? 90 : 0))
                        Caps(title, color: open ? Opal.text : Opal.dim)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if open {
                    Button {
                        withAnimation(.snappy(duration: 0.18)) { help.toggle() }
                    } label: {
                        Image(systemName: help ? "questionmark.circle.fill" : "questionmark.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(help ? Opal.accent : Opal.faint)
                    }
                    .buttonStyle(.plain)
                    .help(help ? "Hide the explanations" : "Explain these settings")
                    .accessibilityLabel(help ? "Hide explanations" : "Explain these settings")
                }
            }
            .padding(.vertical, 13)

            if open {
                VStack(alignment: .leading, spacing: 12) {
                    if help, let about {
                        Text(about)
                            .font(Opal.note)
                            .foregroundStyle(Opal.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    content
                }
                .environment(\.showHelp, help)
                .padding(.bottom, 18)
            }

            Rectangle().fill(Opal.line).frame(height: 1)
        }
        .font(Opal.label)
        .foregroundStyle(Opal.text)
        .toggleStyle(OpalSwitch())
    }
}

// MARK: - Controls

/// A slider that always shows its value, drawn like a fader.
struct OpalSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    let display: String

    init(_ label: String, value: Binding<Double>, range: ClosedRange<Double>,
         step: Double? = nil, display: String) {
        self.label = label
        self._value = value
        self.range = range
        self.step = step
        self.display = display
    }

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        return span > 0 ? min(max((value - range.lowerBound) / span, 0), 1) : 0
    }

    private func set(_ fraction: Double) {
        var next = range.lowerBound + min(max(fraction, 0), 1) * (range.upperBound - range.lowerBound)
        if let step, step > 0 {
            next = range.lowerBound + ((next - range.lowerBound) / step).rounded() * step
        }
        next = min(max(next, range.lowerBound), range.upperBound)
        if next != value { value = next }
    }

    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Text(label).foregroundStyle(Opal.dim)
                Spacer()
                Text(display).font(Opal.value).foregroundStyle(Opal.text)
            }
            GeometryReader { track in
                let thumb: CGFloat = 5
                let travel = max(track.size.width - thumb, 1)
                ZStack(alignment: .leading) {
                    Rectangle().fill(Opal.line).frame(height: 2)
                    Rectangle().fill(Opal.accent)
                        .frame(width: thumb / 2 + travel * fraction, height: 2)
                    Rectangle().fill(.white)
                        .frame(width: thumb, height: 14)
                        .offset(x: travel * fraction)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    set((drag.location.x - thumb / 2) / travel)
                })
            }
            .frame(height: 16)
        }
        .accessibilityRepresentation {
            Slider(value: $value, in: range) { Text(label) }
                .accessibilityValue(display)
        }
    }
}

/// A switch with its label on the left, so a column of them lines up.
struct OpalSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.16)) { configuration.isOn.toggle() }
        } label: {
            HStack(alignment: .center) {
                configuration.label
                    .foregroundStyle(Opal.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    RoundedRectangle(cornerRadius: Opal.corner)
                        .fill(configuration.isOn ? Opal.accent : .clear)
                    RoundedRectangle(cornerRadius: Opal.corner)
                        .strokeBorder(configuration.isOn ? .clear : Opal.line, lineWidth: 1)
                    RoundedRectangle(cornerRadius: Opal.corner - 1)
                        .fill(configuration.isOn ? Color.black.opacity(0.85) : Opal.dim)
                        .frame(width: 12)
                        .padding(3)
                }
                .frame(width: 32, height: 18)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

/// A question with a few answers, all visible at once.
struct Choice<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    init(_ title: String, selection: Binding<Value>, options: [(Value, String)]) {
        self.title = title
        self._selection = selection
        self.options = options.map { (value: $0.0, label: $0.1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty {
                Text(title).foregroundStyle(Opal.dim)
            }
            HStack(spacing: 2) {
                ForEach(options, id: \.value) { option in
                    let picked = option.value == selection
                    Button {
                        withAnimation(.snappy(duration: 0.16)) { selection = option.value }
                    } label: {
                        Text(option.label)
                            .font(.system(size: 11, weight: picked ? .semibold : .regular))
                            .foregroundStyle(picked ? Color.black.opacity(0.9) : Opal.dim)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, minHeight: 24)
                            .background(picked ? Color.white.opacity(0.92) : .clear,
                                        in: .rect(cornerRadius: Opal.corner - 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(picked ? .isSelected : [])
                }
            }
            .padding(2)
            .overlay { RoundedRectangle(cornerRadius: Opal.corner).strokeBorder(Opal.line, lineWidth: 1) }
        }
    }
}

/// A whole number with a minus and a plus.
struct OpalStepper: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    var display: String?

    init(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1,
         display: String? = nil) {
        self.label = label
        self._value = value
        self.range = range
        self.step = step
        self.display = display
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(Opal.dim)
            Spacer()
            nudge("minus", by: -step)
            Text(display ?? "\(value)")
                .font(Opal.value)
                .foregroundStyle(Opal.text)
                .frame(minWidth: 34)
            nudge("plus", by: step)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(display ?? "\(value)")
        .accessibilityAdjustableAction { direction in
            let next = value + (direction == .increment ? step : -step)
            value = min(max(next, range.lowerBound), range.upperBound)
        }
    }

    private func nudge(_ symbol: String, by amount: Int) -> some View {
        let next = min(max(value + amount, range.lowerBound), range.upperBound)
        return Button {
            value = next
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 22, height: 22)
                .overlay { RoundedRectangle(cornerRadius: Opal.corner).strokeBorder(Opal.line, lineWidth: 1) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(next == value ? Opal.faint : Opal.text)
        .disabled(next == value)
    }
}

/// The one button that matters right now.
struct GlowButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.black.opacity(0.88))
            .padding(.horizontal, 12)
            .frame(minHeight: 26)
            .background(Opal.accent, in: .rect(cornerRadius: Opal.corner))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

/// Every other button.
struct QuietButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(enabled ? Opal.text : Opal.faint)
            .padding(.horizontal, 10)
            .frame(minHeight: 26)
            .background(Color.white.opacity(configuration.isPressed ? 0.14 : 0),
                        in: .rect(cornerRadius: Opal.corner))
            .overlay { RoundedRectangle(cornerRadius: Opal.corner).strokeBorder(Opal.line, lineWidth: 1) }
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == GlowButton {
    static var glow: GlowButton { GlowButton() }
}

extension ButtonStyle where Self == QuietButton {
    static var quiet: QuietButton { QuietButton() }
}

// MARK: - Layout

/// Lays its children out in rows and starts a new row when one is full.
struct Flow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        let spots = arrange(width: bounds.width, subviews: subviews).spots
        for (subview, spot) in zip(subviews, spots) {
            subview.place(at: CGPoint(x: bounds.minX + spot.x, y: bounds.minY + spot.y),
                          proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, spots: [CGPoint]) {
        var spots: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            spots.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: min(widest, width), height: y + rowHeight), spots)
    }
}
