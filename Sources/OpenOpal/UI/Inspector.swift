import SwiftUI

/// The settings panel: five tabs, one subject each, so nothing sits at the
/// bottom of a long scroll.
///
/// Every label says what the control does to the picture. Where a setting has
/// named levels, the levels are described by their effect and their cost, not
/// by words like "fast" or "accurate" that leave you guessing what changed.
struct Inspector: View {
    @Environment(CameraModel.self) private var camera
    @AppStorage("inspector.tab") private var tab: Tab = .blur

    enum Tab: String, CaseIterable, Identifiable {
        case blur   = "Blur"
        case light  = "Light"
        case focus  = "Focus"
        case colour = "Colour"
        case camera = "Camera"
        var id: String { rawValue }
    }

    var body: some View {
        @Bindable var settings = camera.settings

        VStack(spacing: 0) {
            Picker("Settings", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            ScrollView {
                VStack(spacing: 10) {
                    switch tab {
                    case .blur:   blur(settings)
                    case .light:  light(settings)
                    case .focus:  focus(settings)
                    case .colour: colour(settings)
                    case .camera: cameraSetup(settings)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Blur: everything about the background blur, in one place

    @ViewBuilder
    private func blur(_ settings: CameraSettings) -> some View {
        @Bindable var settings = settings

        Card("Background blur") {
            Toggle("Blur what is behind me", isOn: $settings.bokehEnabled)

            if settings.bokehEnabled {
                Slider2("Strength", value: $settings.blurAmount,
                        range: 0...1,
                        display: String(format: "%.0f%%", settings.blurAmount * 100))
            }
        }

        if settings.bokehEnabled {
            Card("How the blur spreads") {
                Choice("", selection: $settings.uniformBlur, options: [
                    (true, "Same everywhere"),
                    (false, "More with distance"),
                ])
                Note(settings.uniformBlur
                     ? "Everything behind you gets the same blur. The Mac only has to find your outline."
                     : "Things further away get more blur, like a real lens. The Mac also has to work out how far away each part of the room is.",
                     tone: .hint)

                if !settings.uniformBlur {
                    Text("Distances are worked out by").foregroundStyle(.secondary)
                    DepthModelRows(installer: camera.depthPro2, settings: settings)

                    Toggle("Keep me sharp wherever I sit", isOn: $settings.autoFocusSubject)
                    if !settings.autoFocusSubject {
                        Slider2("Sharp distance", value: $settings.focusDistance,
                                range: 0...1,
                                display: String(format: "%.0f%%", settings.focusDistance * 100))
                        Note("0% is the nearest thing in view and 100% is the furthest.", tone: .hint)
                    }
                }
            }

            Card("Your outline") {
                Choice("Outline detail", selection: $settings.matteQuality, options: [
                    (.fast, "Rough"), (.balanced, "Medium"), (.accurate, "Fine"),
                ])
                Note(settings.matteQuality.effect
                     + (camera.maskMs > 0
                        ? String(format: " Finding your outline takes %.0f ms per frame right now.", camera.maskMs)
                        : ""),
                     tone: .hint)

                Toggle("Wait for each frame's outline", isOn: $settings.syncBokeh)
                Note(settings.syncBokeh
                     ? "Each frame waits for its own outline, so the blur stays lined up with you. This delays the video by the time above."
                     : "Each frame uses the newest outline already made. No added delay, but the blur can trail behind you when you move.",
                     tone: .hint)
            }

            Card("Blurred lights") {
                Slider2("Glow on bright lights", value: $settings.highlightBloom,
                        range: 0...1,
                        display: String(format: "%.0f%%", settings.highlightBloom * 100))
                Choice("Shape of blurred lights", selection: $settings.apertureShape, options: [
                    (.circular, "Round"), (.hexagonal, "Six-sided"),
                ])
            }

            Button("Reset blur settings") { settings.resetBokeh() }
                .glassButtonStyle()
                .controlSize(.small)
        }
    }

    // MARK: - Light: how bright the picture is

    @ViewBuilder
    private func light(_ settings: CameraSettings) -> some View {
        @Bindable var settings = settings

        Card("Brightness") {
            Choice("Brightness is set by", selection: $settings.autoExposure, options: [
                (true, "The camera"), (false, "Me"),
            ])
            .onChange(of: settings.autoExposure) { camera.push() }

            if settings.autoExposure {
                Slider2("Darker or brighter", value: Binding(
                    get: { Double(settings.evCompensation) },
                    set: { settings.evCompensation = Int($0); camera.push() }
                ), range: -9...9, step: 1,
                display: settings.evCompensation > 0
                    ? "+\(settings.evCompensation)" : "\(settings.evCompensation)")

                Toggle("Hold the brightness where it is now", isOn: $settings.aeLock)
                    .onChange(of: settings.aeLock) { camera.push() }

                Toggle("Set brightness from my face", isOn: $settings.meterOnSubject)
                Note("Stops a bright window behind you leaving your face dark. The Mac finds your outline to do this, even with blur off.",
                     tone: .hint)
            } else {
                Slider2("Shutter time", value: Binding(
                    get: { Double(settings.exposureUs) },
                    set: { settings.exposureUs = Int($0); camera.push() }
                ), range: 100...Double(settings.maxExposureUs),
                display: "\(settings.shutterFraction) s")
                Note("Longer is brighter, but movement smears.", tone: .hint)

                Slider2("Sensor gain (ISO)", value: Binding(
                    get: { Double(settings.iso) },
                    set: { settings.iso = Int($0); camera.push() }
                ), range: 100...1600, step: 50, display: "\(settings.iso)")
                Note("Higher is brighter, but grainier.", tone: .hint)
            }
        }

        Card("Flickering room lights") {
            Choice("Mains frequency where you are", selection: $settings.antiBanding,
                   options: CameraSettings.AntiBanding.allCases.map { ($0, $0.rawValue) })
                .onChange(of: settings.antiBanding) { camera.push() }
            Note("Room lights pulse with the mains. Matching it stops dark bands rolling up the picture. \(settings.antiBanding.hint).",
                 tone: .hint)
        }
    }

    // MARK: - Focus: the lens

    @ViewBuilder
    private func focus(_ settings: CameraSettings) -> some View {
        @Bindable var settings = settings

        Card("Focus") {
            Choice("Focus is set by", selection: $settings.manualFocus, options: [
                (false, "The camera"), (true, "Me"),
            ])
            .onChange(of: settings.manualFocus) { camera.push() }

            if settings.manualFocus {
                Slider2("Lens position", value: Binding(
                    get: { Double(settings.lensPosition) },
                    set: { settings.lensPosition = Int($0); camera.push() }
                ), range: 0...255, step: 1, display: "\(settings.lensPosition)")
                Note("0 focuses far away and 255 focuses up close.", tone: .hint)
            } else {
                Picker("The camera refocuses", selection: $settings.afMode) {
                    ForEach(CameraSettings.AFMode.allCases) { Text($0.behaviour).tag($0) }
                }
                .onChange(of: settings.afMode) { camera.push() }
                Note(settings.afMode.effect, tone: .hint)

                Button {
                    camera.device.triggerAutofocus()
                } label: {
                    Label("Refocus now", systemImage: "camera.metering.center.weighted")
                        .frame(maxWidth: .infinity)
                }
                .glassButtonStyle()
                .controlSize(.small)

                Note("You can also click anywhere on the picture to focus there.", tone: .hint)
            }
        }

        if !settings.manualFocus {
            Card("Stop the focus wandering") {
                // One-shot AF on the face box, re-triggered only when your
                // apparent size changes a lot. Stops the lens reacting to
                // background movement.
                Toggle("Refocus only when I move closer or further away", isOn: $settings.focusOnSubject)
                    .onChange(of: settings.focusOnSubject) { camera.push() }
                Note("The camera focuses on your face once, then leaves the lens alone until your size in the picture changes a lot.",
                     tone: .hint)

                // Unrestricted AF hunts the whole lens travel, so a gesture or
                // someone walking past sends it racking to the far wall and
                // back. A desk sits in a narrow band.
                Toggle("Limit how far the lens may move", isOn: $settings.limitAfRange)
                    .onChange(of: settings.limitAfRange) { camera.push() }

                if settings.limitAfRange {
                    Slider2("Furthest lens position", value: Binding(
                        get: { Double(settings.afRangeInfinity) },
                        set: {
                            settings.afRangeInfinity = min(Int($0), settings.afRangeMacro)
                            camera.push()
                        }
                    ), range: 0...255, step: 1, display: "\(settings.afRangeInfinity)")

                    Slider2("Closest lens position", value: Binding(
                        get: { Double(settings.afRangeMacro) },
                        set: {
                            settings.afRangeMacro = max(Int($0), settings.afRangeInfinity)
                            camera.push()
                        }
                    ), range: 0...255, step: 1, display: "\(settings.afRangeMacro)")

                    // The live lens position is the only way to pick sensible
                    // bounds: focus on yourself, read it, then bracket it.
                    Note("The lens is at \(camera.device.telemetry.lensPosition) now. Focus on yourself, then set the two limits either side of that number.",
                         tone: .hint)
                }
            }
        }
    }

    // MARK: - Colour: white balance, tone and detail

    @ViewBuilder
    private func colour(_ settings: CameraSettings) -> some View {
        @Bindable var settings = settings

        Card("White balance") {
            Choice("White balance is set by", selection: $settings.manualWhiteBalance, options: [
                (false, "The camera"), (true, "Me"),
            ])
            .onChange(of: settings.manualWhiteBalance) { camera.push() }

            if settings.manualWhiteBalance {
                Slider2("Colour of your room light", value: Binding(
                    get: { Double(settings.whiteBalanceK) },
                    set: { settings.whiteBalanceK = Int($0); camera.push() }
                ), range: 2000...10000, step: 100, display: "\(settings.whiteBalanceK) K")
                Note("Lower numbers make the picture bluer. Higher numbers make it more orange.", tone: .hint)
            } else {
                Picker("Kind of light", selection: $settings.awbMode) {
                    ForEach(CameraSettings.AWBMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .onChange(of: settings.awbMode) { camera.push() }
            }
        }

        Card("Picture") {
            Stepper2("Colour strength", value: Binding(
                get: { settings.saturation },
                set: { settings.saturation = $0; camera.push() }), range: -10...10)
            Stepper2("Contrast", value: Binding(
                get: { settings.contrast },
                set: { settings.contrast = $0; camera.push() }), range: -10...10)
            Stepper2("Brightness", value: Binding(
                get: { settings.brightness },
                set: { settings.brightness = $0; camera.push() }), range: -10...10)
        }

        Card("Sharpness and grain") {
            Stepper2("Edge sharpening", value: Binding(
                get: { settings.sharpness },
                set: { settings.sharpness = $0; camera.push() }), range: 0...4)
            Stepper2("Grain smoothing", value: Binding(
                get: { settings.lumaDenoise },
                set: { settings.lumaDenoise = $0; camera.push() }), range: 0...4)
            Stepper2("Colour speckle smoothing", value: Binding(
                get: { settings.chromaDenoise },
                set: { settings.chromaDenoise = $0; camera.push() }), range: 0...4)
            Note("The camera does all three. 0 is off and 4 is the most. More smoothing also blurs fine detail.",
                 tone: .hint)
        }
    }

    // MARK: - Camera: video size, orientation and the virtual camera

    @ViewBuilder
    private func cameraSetup(_ settings: CameraSettings) -> some View {
        @Bindable var settings = settings

        Card("Video size and speed") {
            Choice("Size", selection: $settings.outputMode,
                   options: CameraSettings.OutputMode.allCases.map { ($0, $0.rawValue) })

            Stepper("\(settings.fps) frames per second", value: $settings.fps,
                    in: 5...settings.outputMode.maxFps, step: 5)

            if let caution = settings.outputMode.caution {
                Note(caution, tone: .warning)
            }
        }

        Card("Which way up") {
            Toggle("Turn the picture upside down", isOn: $settings.rotate180)
            Note("The C1's sensor is fitted upside down, so this is normally on. The camera does the turning.",
                 tone: .hint)

            Toggle("Mirror my preview", isOn: $settings.mirrorPreview)
            Note("Only this preview is flipped. Other people still see you the right way round.",
                 tone: .hint)
        }

        // Size, speed and rotation are baked into the device pipeline, so
        // changing them means rebooting the Myriad. Make that an explicit act
        // rather than a surprise mid-call black frame.
        if settings.coldDirty {
            Button {
                Task { await camera.applyColdChanges() }
            } label: {
                Label("Restart camera to apply", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .glassButtonStyle(prominent: true)
            .controlSize(.small)
        }

        Card("Use in other apps") {
            virtualCamera
        }

        Button("Reset every setting") {
            camera.settings.reset()
            camera.settings.resetBokeh()
            camera.push()
        }
        .glassButtonStyle()
        .controlSize(.small)
    }

    @ViewBuilder
    private var virtualCamera: some View {
        if camera.autoLaunch.isIncludedInApp {
            Toggle("Start OpenOpal automatically", isOn: Binding(
                get: { camera.autoLaunch.isEnabled },
                set: { camera.autoLaunch.setEnabled($0) }))
                .disabled(camera.autoLaunch.isChanging)
            Note("A login helper opens OpenOpal when a video app uses “Open Opal Camera”.",
                 tone: .hint)
            if camera.autoLaunch.status == .requiresApproval {
                Note("Allow OpenOpal Launcher in Login Items to enable automatic startup.", tone: .warning)
                Button("Open Login Items") { camera.autoLaunch.openLoginItems() }
                    .glassButtonStyle()
            }
            if let error = camera.autoLaunch.error {
                Note(error, tone: .warning)
            }
        }
        switch camera.installer.status {
        case .installed:
            if camera.feeder.connected {
                Note("Live — pick “Open Opal Camera” in Zoom, Meet, or FaceTime.",
                     tone: .hint)
            } else {
                Note("Installed. Waiting for the camera device to come up…",
                     tone: .hint)
            }
        case .installing:
            Note("Installing…", tone: .hint)
        case .needsApproval:
            Note("Approve the extension in System Settings → General → Login Items & Extensions, then it activates on its own.",
                 tone: .warning)
        case .failed(let message):
            Note(message, tone: .warning)
            if !camera.installer.diagnostics.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(camera.installer.diagnostics, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Try again") { camera.installer.install() }
                .glassButtonStyle()
                .controlSize(.small)
        case .unknown:
            if !camera.installer.isIncludedInApp {
                Note("This build supports camera controls and preview. Use a signed extension build to make the camera available to video apps.",
                     tone: .hint)
            } else {
                Note("Puts the processed image — blur and all — into every video app as “Open Opal Camera”.",
                     tone: .hint)
                Button {
                    camera.installer.install()
                } label: {
                    Label("Install virtual camera", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .glassButtonStyle(prominent: true)
                .controlSize(.small)
            }
        }
    }
}

// MARK: - What the named levels do

private extension CameraSettings.MatteQuality {
    /// What this level changes in the picture and what it costs.
    var effect: String {
        switch self {
        case .fast:     "Blocky edges around you. The least work for the Mac."
        case .balanced: "Smoother edges around you."
        case .accurate: "The outline follows hair and glasses. The most work for the Mac."
        }
    }
}

private extension CameraSettings.AFMode {
    var behaviour: String {
        switch self {
        case .auto:            "Only when asked"
        case .continuousVideo: "All the time"
        case .macro:           "Only for close-up things"
        case .edof:            "Never (fixed lens)"
        }
    }

    /// What the camera's lens does in this mode.
    var effect: String {
        switch self {
        case .auto:            "The lens stays put until you press Refocus or click the picture."
        case .continuousVideo: "The lens keeps adjusting on its own to hold the picture sharp."
        case .macro:           "The lens only searches its close-up range."
        case .edof:            "The lens holds one position that keeps most distances fairly sharp."
        }
    }
}

// MARK: - Building blocks

/// One titled group of controls.
private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.bottom, 1)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .toggleStyle(TrailingSwitch())
        .controlSize(.small)
        .font(.system(size: 12))
        .background(.primary.opacity(0.05), in: .rect(cornerRadius: 14))
    }
}

/// A switch with its label on the left and the switch at the right edge, so a
/// column of them lines up whatever the label lengths.
private struct TrailingSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline) {
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Toggle("", isOn: configuration.$isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

/// A question with a few answers, all visible at once.
private struct Choice<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    init(_ title: String, selection: Binding<Value>, options: [(Value, String)]) {
        self.title = title
        self._selection = selection
        self.options = options.map { (value: $0.0, label: $0.1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !title.isEmpty {
                Text(title).foregroundStyle(.secondary)
            }
            Picker(title, selection: $selection) {
                ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

/// A slider that always shows its value — a bare slider tells you nothing about
/// what f/2.8 or 1/250s actually is.
private struct Slider2: View {
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

    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(display)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            if let step {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
        }
    }
}

private struct Stepper2: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    init(_ label: String, value: Binding<Int>, range: ClosedRange<Int>) {
        self.label = label
        self._value = value
        self.range = range
    }

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text("\(value)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .frame(minWidth: 20, alignment: .trailing)
            Stepper("", value: $value, in: range).labelsHidden()
        }
    }
}

/// The two models that can work out distances, as a pick-one list. Depth Pro 2
/// carries its own download, progress and delete controls, because it cannot be
/// picked until it is on this Mac.
private struct DepthModelRows: View {
    let installer: DepthPro2Installer
    @Bindable var settings: CameraSettings

    private var usingDepthPro2: Bool {
        settings.depthModel == .depthPro2 && installer.isInstalled
    }

    var body: some View {
        ModelRow(name: "Depth Anything V2", experimental: false, selected: !usingDepthPro2,
                 detail: "Built in. Looks at one frame at a time.") {
            settings.depthModel = .depthAnythingV2
        }

        if DepthPro2.isSupported {
            ModelRow(name: "Depth Pro 2", experimental: true, selected: usingDepthPro2,
                     detail: "New from Apple. Also looks at the last 3 frames, so the blur should flicker less. We are still testing it, so it may look wrong.",
                     select: installer.isInstalled ? { settings.depthModel = .depthPro2 } : nil)

            Group {
                switch installer.status {
                case .notInstalled:
                    Note("Not on this Mac yet. It is a 52 MB download from Apple, licensed for research use only.",
                         tone: .hint)
                    Button("Download Depth Pro 2") { installer.install() }
                        .glassButtonStyle()

                case .downloading(let fraction):
                    ProgressView(value: fraction)
                    HStack {
                        Note("Downloading… \(Int((fraction * 100).rounded()))%", tone: .hint)
                        Spacer()
                        Button("Cancel") { installer.cancel() }
                            .glassButtonStyle()
                    }

                case .preparing:
                    HStack(spacing: 6) {
                        ProgressView()
                        Note("Downloaded. Getting it ready for this Mac…", tone: .hint)
                    }

                case .installed:
                    HStack {
                        Note("Downloaded and ready.", tone: .hint)
                        Spacer()
                        Button("Delete download") {
                            settings.depthModel = .depthAnythingV2
                            installer.delete()
                        }
                        .glassButtonStyle()
                    }

                case .failed(let message):
                    Note("Depth Pro 2 could not be installed. \(message)", tone: .warning)
                    Button("Try again") { installer.install() }
                        .glassButtonStyle()
                }
            }
            .controlSize(.small)
            .padding(.leading, 22)
        }
    }
}

/// One line of a pick-one list. `select` is nil when the row cannot be picked yet.
private struct ModelRow: View {
    let name: String
    let experimental: Bool
    let selected: Bool
    let detail: String
    var select: (() -> Void)?

    var body: some View {
        Button {
            select?()
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .font(.system(size: 14))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(name)
                        if experimental {
                            Text("Experimental")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .foregroundStyle(.orange)
                                .background(.orange.opacity(0.18), in: Capsule())
                        }
                    }
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(select == nil)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct Note: View {
    enum Tone { case hint, warning }
    let text: String
    let tone: Tone

    init(_ text: String, tone: Tone) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: tone == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.system(size: 9))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 10))
        .foregroundStyle(tone == .warning ? .orange : .secondary)
    }
}
