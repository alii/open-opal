import SwiftUI

/// The settings panel: five tabs, one subject each, so nothing sits at the
/// bottom of a long scroll.
///
/// Controls are named for the setting they change, and the line under each one
/// says what that setting does, with real numbers where there are any. Nothing
/// is hidden behind a friendly word that leaves you guessing what changed.
struct Inspector: View {
    @Environment(CameraModel.self) private var camera
    @AppStorage("inspector.tab") private var tab: Tab = .blur

    enum Tab: String, CaseIterable, Identifiable {
        case blur   = "Blur"
        case light  = "Exposure"
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
            // Five labels at the regular size are wider than the 400pt panel.
            .controlSize(.small)
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
                // Exactly as wide as the panel. Left to itself the scroll view
                // grows to fit its widest row, and the panel then clips both
                // edges of every card.
                .containerRelativeFrame(.horizontal)
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
            Toggle("Background blur", isOn: $settings.bokehEnabled)

            if settings.bokehEnabled {
                Slider2("Simulated aperture", value: $settings.blurAmount,
                        range: 0...1,
                        display: String(format: "f/%.1f", settings.aperture))
                Note("f/1.4 gives the most blur and f/16 almost none. Blur radius scales with 1 / f-number.",
                     tone: .hint)
            }
        }

        if settings.bokehEnabled {
            Card("Blur mode") {
                Choice("", selection: $settings.uniformBlur, options: [
                    (true, "Uniform"),
                    (false, "Depth-graded"),
                ])
                Note(settings.uniformBlur
                     ? "One blur radius for everything outside the person mask. No depth model runs."
                     : "Blur radius grows with distance from the focal plane. Needs a depth map, made by the model below on every second frame.",
                     tone: .hint)

                if !settings.uniformBlur {
                    Text("Depth model").foregroundStyle(.secondary)
                    DepthModelRows(installer: camera.depthPro2, settings: settings)

                    Toggle("Focal plane follows subject", isOn: $settings.autoFocusSubject)
                    if settings.autoFocusSubject {
                        Note("The focal plane is the median depth under the person mask.", tone: .hint)
                    } else {
                        Slider2("Focal plane depth", value: $settings.focusDistance,
                                range: 0...1,
                                display: String(format: "%.2f", settings.focusDistance))
                        Note("Normalised depth: 0 is nearest, 1 is furthest.", tone: .hint)
                    }
                }
            }

            Card("Person mask") {
                Choice("Vision segmentation quality", selection: $settings.matteQuality, options: [
                    (.fast, "Fast"), (.balanced, "Balanced"), (.accurate, "Accurate"),
                ])
                Note(settings.matteQuality.effect
                     + (camera.maskMs > 0
                        ? String(format: " Measured now: %.0f ms per mask.", camera.maskMs)
                        : ""),
                     tone: .hint)

                Toggle("Sync mask to frame", isOn: $settings.syncBokeh)
                Note(settings.syncBokeh
                     ? "Each frame is held until its own mask is ready, so mask and frame match exactly. Adds one mask time to latency."
                     : "Frames are not held. Each uses the newest finished mask, which is 1 to 2 frames old, so the blur edge lags fast movement.",
                     tone: .hint)
            }

            Card("Bokeh highlights") {
                Slider2("Highlight bloom", value: $settings.highlightBloom,
                        range: 0...1,
                        display: String(format: "%.0f%%", settings.highlightBloom * 100))
                Note("How much brighter pixels count in the blur, which is what makes lights turn into discs.",
                     tone: .hint)
                Choice("Aperture shape", selection: $settings.apertureShape, options: [
                    (.circular, "Circular"), (.hexagonal, "Hexagonal"),
                ])
            }

            Button("Reset blur settings") { settings.resetBokeh() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    // MARK: - Exposure

    @ViewBuilder
    private func light(_ settings: CameraSettings) -> some View {
        @Bindable var settings = settings

        Card("Exposure") {
            Choice("", selection: $settings.autoExposure, options: [
                (true, "Auto"), (false, "Manual"),
            ])
            .onChange(of: settings.autoExposure) { camera.push() }

            if settings.autoExposure {
                Slider2("Exposure compensation", value: Binding(
                    get: { Double(settings.evCompensation) },
                    set: { settings.evCompensation = Int($0); camera.push() }
                ), range: -9...9, step: 1,
                display: settings.evCompensation > 0
                    ? "+\(settings.evCompensation)" : "\(settings.evCompensation)")

                Toggle("AE lock", isOn: $settings.aeLock)
                    .onChange(of: settings.aeLock) { camera.push() }
                Note("Freezes shutter and ISO at their current values.", tone: .hint)

                Toggle("Meter on subject", isOn: $settings.meterOnSubject)
                Note("Sets the auto-exposure region to the person mask's bounding box. The mask runs for this even with blur off.",
                     tone: .hint)
            } else {
                Slider2("Shutter", value: Binding(
                    get: { Double(settings.exposureUs) },
                    set: { settings.exposureUs = Int($0); camera.push() }
                ), range: 100...Double(settings.maxExposureUs),
                display: "\(settings.shutterFraction) s")

                Slider2("ISO", value: Binding(
                    get: { Double(settings.iso) },
                    set: { settings.iso = Int($0); camera.push() }
                ), range: 100...1600, step: 50, display: "\(settings.iso)")
                Note("Shutter can be at most one frame interval (\(settings.maxExposureUs) µs at \(settings.fps) fps).",
                     tone: .hint)
            }
        }

        Card("Anti-banding") {
            Choice("Mains frequency", selection: $settings.antiBanding,
                   options: CameraSettings.AntiBanding.allCases.map { ($0, $0.rawValue) })
                .onChange(of: settings.antiBanding) { camera.push() }
            Note("Locks exposure to multiples of the mains cycle so lights do not band. \(settings.antiBanding.hint).",
                 tone: .hint)
        }
    }

    // MARK: - Focus: the lens

    /// One list, one answer. Manual focus and the camera's autofocus modes are
    /// stored separately, but they are one decision, and showing them as
    /// separate switches let them read as if they disagreed.
    @ViewBuilder
    private func focus(_ settings: CameraSettings) -> some View {
        @Bindable var settings = settings
        let choice = FocusChoice(settings)

        Card("Focus") {
            Picker("Focus mode", selection: Binding(
                get: { choice },
                set: { $0.apply(to: settings); camera.resumeAutofocus() }
            )) {
                ForEach(FocusChoice.allCases) { Text($0.label).tag($0) }
            }

            if camera.focusHeld && choice.cameraDriven && choice != .whenAsked {
                Note("Holding the focus set by your click on the picture (one-shot AF on that region).", tone: .hint)
                Button {
                    camera.resumeAutofocus()
                } label: {
                    Text("Release and return to this mode").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Note(choice.effect, tone: .hint)
            }

            if choice == .byHand {
                Slider2("Lens position", value: Binding(
                    get: { Double(settings.lensPosition) },
                    set: { settings.lensPosition = Int($0); camera.push() }
                ), range: 0...255, step: 1, display: "\(settings.lensPosition)")
                Note("Lens position 0 to 255. 0 is infinity and 255 is the closest focus.", tone: .hint)
            } else if choice.cameraDriven {
                Button {
                    camera.device.triggerAutofocus()
                } label: {
                    Label("Trigger autofocus", systemImage: "camera.metering.center.weighted")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Note("Clicking the picture sets the AF and AE region there, runs one-shot AF and holds the result.",
                     tone: .hint)
            }
        }

        if choice.cameraDriven {
            Card("AF range limit") {
                // Unrestricted AF hunts the whole lens travel, so a gesture or
                // someone walking past sends it racking to the far wall and
                // back. A desk sits in a narrow band.
                Toggle("Limit AF lens range", isOn: $settings.limitAfRange)
                    .onChange(of: settings.limitAfRange) { camera.push() }
                Note("Autofocus may only search between the two lens positions below, so it cannot rack to the far wall and back.",
                     tone: .hint)

                if settings.limitAfRange {
                    Slider2("Far limit", value: Binding(
                        get: { Double(settings.afRangeInfinity) },
                        set: {
                            settings.afRangeInfinity = min(Int($0), settings.afRangeMacro)
                            camera.push()
                        }
                    ), range: 0...255, step: 1, display: "\(settings.afRangeInfinity)")

                    Slider2("Near limit", value: Binding(
                        get: { Double(settings.afRangeMacro) },
                        set: {
                            settings.afRangeMacro = max(Int($0), settings.afRangeInfinity)
                            camera.push()
                        }
                    ), range: 0...255, step: 1, display: "\(settings.afRangeMacro)")

                    // The live lens position is the only way to pick sensible
                    // bounds: focus on yourself, read it, then bracket it.
                    Note("Lens position now: \(camera.device.telemetry.lensPosition). Focus on yourself, then set the limits either side of it.",
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
            Choice("", selection: $settings.manualWhiteBalance, options: [
                (false, "Auto"), (true, "Manual"),
            ])
            .onChange(of: settings.manualWhiteBalance) { camera.push() }

            if settings.manualWhiteBalance {
                Slider2("Colour temperature", value: Binding(
                    get: { Double(settings.whiteBalanceK) },
                    set: { settings.whiteBalanceK = Int($0); camera.push() }
                ), range: 2000...10000, step: 100, display: "\(settings.whiteBalanceK) K")
            } else {
                Picker("AWB mode", selection: $settings.awbMode) {
                    ForEach(CameraSettings.AWBMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .onChange(of: settings.awbMode) { camera.push() }
            }
        }

        Card("ISP tone") {
            Stepper2("Saturation", value: Binding(
                get: { settings.saturation },
                set: { settings.saturation = $0; camera.push() }), range: -10...10)
            Stepper2("Contrast", value: Binding(
                get: { settings.contrast },
                set: { settings.contrast = $0; camera.push() }), range: -10...10)
            Stepper2("Brightness", value: Binding(
                get: { settings.brightness },
                set: { settings.brightness = $0; camera.push() }), range: -10...10)
            Note("Applied by the camera's ISP. Range -10 to 10, 0 is neutral.", tone: .hint)
        }

        Card("ISP detail") {
            Stepper2("Sharpness", value: Binding(
                get: { settings.sharpness },
                set: { settings.sharpness = $0; camera.push() }), range: 0...4)
            Stepper2("Luma denoise", value: Binding(
                get: { settings.lumaDenoise },
                set: { settings.lumaDenoise = $0; camera.push() }), range: 0...4)
            Stepper2("Chroma denoise", value: Binding(
                get: { settings.chromaDenoise },
                set: { settings.chromaDenoise = $0; camera.push() }), range: 0...4)
            Note("Applied by the camera's ISP. Range 0 to 4, 0 is off.", tone: .hint)
        }
    }

    // MARK: - Camera: output format, orientation and the virtual camera

    @ViewBuilder
    private func cameraSetup(_ settings: CameraSettings) -> some View {
        @Bindable var settings = settings

        Card("Output") {
            Choice("Resolution", selection: $settings.outputMode,
                   options: CameraSettings.OutputMode.allCases.map { ($0, $0.rawValue) })

            Stepper("\(settings.fps) fps", value: $settings.fps,
                    in: 5...settings.outputMode.maxFps, step: 5)

            Note("The sensor always captures 3840×2160. 1080p and 720p are scaled on the camera's ISP before USB.",
                 tone: .hint)
            if let caution = settings.outputMode.caution {
                Note(caution, tone: .warning)
            }
        }

        Card("Orientation") {
            Toggle("Rotate 180°", isOn: $settings.rotate180)
            Note("Done on the camera's ISP. The C1's sensor is mounted upside down, so this is normally on.",
                 tone: .hint)

            Toggle("Mirror preview", isOn: $settings.mirrorPreview)
            Note("Preview only. The virtual camera output is never mirrored.", tone: .hint)
        }

        // Resolution, fps and rotation are baked into the device pipeline, so
        // changing them means rebooting the Myriad. Make that an explicit act
        // rather than a surprise mid-call black frame.
        if settings.coldDirty {
            Button {
                Task { await camera.applyColdChanges() }
            } label: {
                Label("Restart camera to apply", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }

        Card("Virtual camera") {
            virtualCamera
        }

        Button("Reset all settings") {
            camera.settings.reset()
            camera.settings.resetBokeh()
            camera.push()
        }
        .buttonStyle(.bordered)
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
                    .buttonStyle(.bordered)
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
                .buttonStyle(.bordered)
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
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }
}

// MARK: - What the named levels do

private extension CameraSettings.MatteQuality {
    /// What the quality level of VNGeneratePersonSegmentationRequest changes:
    /// the size of the mask it returns, and so how long it takes. Sizes and
    /// times were measured on an M4 Max, one mask at a time at 30fps.
    var effect: String {
        switch self {
        case .fast:     "Mask is 256×192. About 8 ms on an M4 Max."
        case .balanced: "Mask is 512×384. About 20 ms on an M4 Max."
        case .accurate: "Mask is 2016×1512. About 31 ms on an M4 Max."
        }
    }
}

/// Every way the lens can be driven, as one list.
private enum FocusChoice: String, CaseIterable, Identifiable {
    case always, whenAsked, closeUp, fixed, byHand
    var id: String { rawValue }

    @MainActor init(_ settings: CameraSettings) {
        if settings.manualFocus { self = .byHand; return }
        self = switch settings.afMode {
        case .continuousVideo: .always
        case .auto:            .whenAsked
        case .macro:           .closeUp
        case .edof:            .fixed
        }
    }

    @MainActor func apply(to settings: CameraSettings) {
        settings.manualFocus = self == .byHand
        switch self {
        case .always:    settings.afMode = .continuousVideo
        case .whenAsked: settings.afMode = .auto
        case .closeUp:   settings.afMode = .macro
        case .fixed:     settings.afMode = .edof
        case .byHand:    break
        }
    }

    /// The camera moves the lens itself, so refocusing and limits apply.
    var cameraDriven: Bool { self == .always || self == .whenAsked || self == .closeUp }

    var label: String {
        switch self {
        case .always:    "Continuous autofocus"
        case .whenAsked: "One-shot autofocus"
        case .closeUp:   "Macro autofocus"
        case .fixed:     "Extended depth of field (EDOF)"
        case .byHand:    "Manual lens position"
        }
    }

    /// What the camera does in this mode.
    var effect: String {
        switch self {
        case .always:    "depthai CONTINUOUS_VIDEO. The camera's AF loop runs all the time and moves the lens whenever sharpness drops."
        case .whenAsked: "depthai AUTO. The lens moves only on a trigger: the button below, or a click on the picture."
        case .closeUp:   "depthai MACRO. Autofocus tuned for close-up subjects."
        case .fixed:     "depthai EDOF. The lens is parked where the widest range of distances stays acceptably sharp."
        case .byHand:    "Autofocus is off. The lens goes to the position you set."
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
                 detail: "Small, 518×392 input. One frame at a time. Relative depth, rescaled on every frame. Built in.") {
            settings.depthModel = .depthAnythingV2
        }

        if DepthPro2.isSupported {
            ModelRow(name: "Depth Pro 2", experimental: true, selected: usingDepthPro2,
                     detail: "Small, 640×360 input. Uses the last 4 frames, and outputs metric depth with a fixed scale. Untested against Depth Anything, so it may look worse.",
                     select: installer.isInstalled ? { settings.depthModel = .depthPro2 } : nil)

            Group {
                switch installer.status {
                case .notInstalled:
                    Note("Not downloaded. 52 MB from huggingface.co/apple/DepthPro2-coreml, under Apple's research-only model licence.",
                         tone: .hint)
                    Button("Download Depth Pro 2") { installer.install() }
                        .buttonStyle(.bordered)

                case .downloading(let fraction):
                    ProgressView(value: fraction)
                    HStack {
                        Note("Downloading… \(Int((fraction * 100).rounded()))%", tone: .hint)
                        Spacer()
                        Button("Cancel") { installer.cancel() }
                            .buttonStyle(.bordered)
                    }

                case .preparing:
                    HStack(spacing: 6) {
                        ProgressView()
                        Note("Downloaded. Compiling the Core ML model…", tone: .hint)
                    }

                case .installed:
                    HStack {
                        Note("Downloaded (52 MB).", tone: .hint)
                        Spacer()
                        Button("Delete download") {
                            settings.depthModel = .depthAnythingV2
                            installer.delete()
                        }
                        .buttonStyle(.bordered)
                    }

                case .failed(let message):
                    Note("Depth Pro 2 could not be installed. \(message)", tone: .warning)
                    Button("Try again") { installer.install() }
                        .buttonStyle(.bordered)
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
