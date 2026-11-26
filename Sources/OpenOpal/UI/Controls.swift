import SwiftUI

/// Every setting, grouped into sections that open and close.
///
/// Controls are named for the setting they change. The explanation of each one
/// is a press away, behind the question mark in its section's header, so the
/// panel is short by default and nothing has to be guessed.
struct Controls: View {
    var body: some View {
        VStack(spacing: 0) {
            BlurControls()
            LightControls()
            ColourControls()
            FocusControls()
            CameraControls()
        }
    }
}

/// The handful of settings worth reaching for mid-call. This is all the docked
/// panel shows. The rest is one press away, in the floating window.
struct QuickControls: View {
    @Environment(CameraModel.self) private var camera

    var body: some View {
        @Bindable var settings = camera.settings

        // Every row is always here. One that does not apply right now is
        // dimmed, not removed, so the rows below it never jump.
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Background blur", isOn: $settings.bokehEnabled)
            OpalSlider("Blur amount", value: $settings.blurAmount, range: 0...1,
                       display: settings.bokehEnabled ? String(format: "f/%.1f", settings.aperture) : "off")
                .applies(settings.bokehEnabled)
            ExposureCompensation()
                .applies(settings.autoExposure)
            Choice("White balance", selection: $settings.manualWhiteBalance, options: [
                (false, "Auto"), (true, "Manual"),
            ])
            .onChange(of: settings.manualWhiteBalance) { camera.push() }
            ColourTemperature()
                .applies(settings.manualWhiteBalance)
        }
        .font(Opal.label)
        .foregroundStyle(Opal.text)
        .toggleStyle(OpalSwitch())
    }
}

private extension View {
    /// Dims a control and stops it taking input while it has no effect.
    func applies(_ applies: Bool) -> some View {
        disabled(!applies).opacity(applies ? 1 : 0.32)
    }
}

private struct ExposureCompensation: View {
    @Environment(CameraModel.self) private var camera

    var body: some View {
        let settings = camera.settings
        OpalSlider("Brightness", value: Binding(
            get: { Double(settings.evCompensation) },
            set: { settings.evCompensation = Int($0); camera.push() }
        ), range: -9...9, step: 1,
        display: settings.evCompensation > 0 ? "+\(settings.evCompensation)" : "\(settings.evCompensation)")
    }
}

private struct ColourTemperature: View {
    @Environment(CameraModel.self) private var camera

    var body: some View {
        let settings = camera.settings
        OpalSlider("Colour temperature", value: Binding(
            get: { Double(settings.whiteBalanceK) },
            set: { settings.whiteBalanceK = Int($0); camera.push() }
        ), range: 1500...10000, step: 100, display: "\(settings.whiteBalanceK) K")
    }
}

// MARK: - Blur

private struct BlurControls: View {
    @Environment(CameraModel.self) private var camera

    var body: some View {
        @Bindable var settings = camera.settings

        Fold("Blur", key: "blur", open: true,
             about: "Blurs everything behind you, the way a camera with a large lens does. This Mac does the blurring, not the camera.") {
            Toggle("Background blur", isOn: $settings.bokehEnabled)

            if settings.bokehEnabled {
                OpalSlider("Simulated aperture", value: $settings.blurAmount, range: 0...1,
                           display: String(format: "f/%.1f", settings.aperture))
                Note("A real lens blurs the background more as its opening, the aperture, gets wider. A lower f-number is a wider opening: f/1.4 is the most blur and f/16 is almost none.",
                     tone: .hint)

                Choice("Blur mode", selection: $settings.uniformBlur, options: [
                    (true, "Uniform"), (false, "Depth-graded"),
                ])
                Note(settings.uniformBlur
                     ? "Everything that is not you gets the same blur. The app only needs to know which pixels are you (the person mask, below)."
                     : "Things further from you get more blur, like a real lens. For that the Mac has to estimate how far away every pixel is. The estimate is called a depth map. A neural network makes it from the picture, on every second frame.",
                     tone: .hint)

                if !settings.uniformBlur {
                    Sub("Depth model")
                    DepthModelRows(installer: camera.depthPro2, settings: settings)

                    Toggle("Focal plane follows subject", isOn: $settings.autoFocusSubject)
                    if settings.autoFocusSubject {
                        Note("The focal plane is the distance that stays sharp. On: it is kept at your distance (the median depth of the pixels inside the person mask), so you stay sharp when you move.", tone: .hint)
                    } else {
                        OpalSlider("Focal plane depth", value: $settings.focusDistance, range: 0...1,
                                   display: String(format: "%.2f", settings.focusDistance))
                        Note("The focal plane is the distance that stays sharp. Here you fix it yourself: 0 is the nearest thing in view and 1 is the furthest.", tone: .hint)
                    }
                }

                Sub("Person mask")
                Note("To blur the background and not you, the app has to know which pixels are you. Apple's Vision framework works that out for every frame and returns a black and white image, white where a person is. Its edge is where the blur starts.",
                     tone: .hint)
                Choice("Mask quality", selection: $settings.matteQuality, options: [
                    (.fast, "Fast"), (.balanced, "Balanced"), (.accurate, "Accurate"),
                ])
                Note("A larger mask follows hair, fingers and glasses more closely, and takes longer to make. "
                     + settings.matteQuality.effect
                     + (camera.maskMs > 0
                        ? String(format: " Measured now: %.0f ms per mask.", camera.maskMs)
                        : ""),
                     tone: .hint)

                Toggle("Sync mask to frame", isOn: $settings.syncBokeh)
                Note(settings.syncBokeh
                     ? "On: each frame waits for its own mask, so the edge of the blur sits exactly on you. This delays the picture by one mask time, and never by more than 50 ms."
                     : "Off: frames never wait. Each uses the last mask that finished, which is 1 to 2 frames old, so the edge of the blur trails behind you when you move fast.",
                     tone: .hint)

                Choice("Blur shape", selection: $settings.apertureShape, options: [
                    (.circular, "Circular"), (.hexagonal, "Hexagonal"),
                ])
                Note("Through a real lens, a small light in the background blurs into a disc in the shape of the lens opening. This picks that shape.",
                     tone: .hint)

                Button("Reset blur settings") { settings.resetBokeh() }
                    .buttonStyle(.quiet)
            }
        }
    }
}

// MARK: - Light

private struct LightControls: View {
    @Environment(CameraModel.self) private var camera

    var body: some View {
        @Bindable var settings = camera.settings

        Fold("Light", key: "light", open: true,
             about: "How bright the camera makes the picture. Two things set it: the shutter (how long each frame collects light) and ISO (how much the sensor's signal is amplified).") {
            Choice("Exposure", selection: $settings.autoExposure, options: [
                (true, "Auto"), (false, "Manual"),
            ])
            .onChange(of: settings.autoExposure) { camera.push() }

            if settings.autoExposure {
                ExposureCompensation()
                Note("Tells auto-exposure to aim brighter (+) or darker (−) than it would on its own.", tone: .hint)

                Toggle("Lock exposure", isOn: $settings.aeLock)
                    .onChange(of: settings.aeLock) { camera.push() }
                Note("Freezes the shutter and ISO where they are now, so the brightness stops changing.", tone: .hint)

                Toggle("Expose for your face", isOn: $settings.exposeForFace)
                Note("The camera measures the whole picture, so a bright window behind you leaves your face dark, and turning towards it can make you too bright. On: the app looks at how bright your face is and moves the camera's exposure compensation up or down by up to 3 steps. What it added is shown on the picture. The Brightness slider still works, and sets how bright it aims for.",
                     tone: .hint)

                Toggle("Low light help", isOn: $settings.lowLightHelp)
                Note("The camera stops at ISO 1600, and its auto white balance stops near 2600 K. On: when either limit is reached the app brightens the picture itself, and takes the orange tint out of lamp light, first with a lower white balance on the camera and then in the app. It adds some grain. Whatever it is doing is listed under App in the status area. Manual exposure or manual white balance turns that half off.",
                     tone: .hint)
            } else {
                OpalSlider("Shutter", value: Binding(
                    get: { Double(settings.exposureUs) },
                    set: { settings.exposureUs = Int($0); camera.push() }
                ), range: 100...Double(settings.maxExposureUs),
                display: "\(settings.shutterFraction) s")
                Note("Longer is brighter, but movement blurs.", tone: .hint)

                OpalSlider("ISO", value: Binding(
                    get: { Double(settings.iso) },
                    set: { settings.iso = Int($0); camera.push() }
                ), range: 100...1600, step: 50, display: "\(settings.iso)")
                Note("Higher ISO is brighter, but grainier. The shutter can be at most one frame long (\(settings.maxExposureUs) µs at \(settings.fps) fps).",
                     tone: .hint)
            }

            OpalSlider("Lift shadows", value: $settings.shadowLift, range: 0...1,
                       display: settings.shadowLift > 0
                           ? String(format: "%.0f%%", settings.shadowLift * 100) : "off")
            Note("Brightens the dark parts of the picture much more than the bright parts. Use it when a window or lamp lights one side of your face. The app does this, after the camera has set its exposure. More of it shows more grain, so it backs off when low light help is adding brightness.",
                 tone: .hint)

            Choice("Anti-banding", selection: $settings.antiBanding,
                   options: CameraSettings.AntiBanding.allCases.map { ($0, $0.rawValue) })
                .onChange(of: settings.antiBanding) { camera.push() }
            Note("Room lights flicker with the mains, too fast to see. A camera can catch that as dark bands rolling through the picture. Anti-banding times the shutter to the flicker. Auto lets the camera work out the mains frequency. Pick one yourself only if you still see bands. \(settings.antiBanding.hint).",
                 tone: .hint)
        }
    }
}

// MARK: - Colour

private struct ColourControls: View {
    @Environment(CameraModel.self) private var camera

    var body: some View {
        @Bindable var settings = camera.settings

        Fold("Colour", key: "colour",
             about: "Light bulbs are orange and daylight is blue. White balance removes that tint so white things look white. The rest is done by the ISP, the image signal processor inside the camera, before the picture reaches the Mac.") {
            Choice("White balance", selection: $settings.manualWhiteBalance, options: [
                (false, "Auto"), (true, "Manual"),
            ])
            .onChange(of: settings.manualWhiteBalance) { camera.push() }

            if settings.manualWhiteBalance {
                ColourTemperature()
                Note("Set it to the colour of your light, in kelvin: about 2700 K for warm bulbs and 5600 K for daylight. Set too low the picture turns blue, too high it turns orange.",
                     tone: .hint)
            } else {
                HStack {
                    Text("Auto mode").foregroundStyle(Opal.dim)
                    Spacer()
                    Picker("Auto mode", selection: $settings.awbMode) {
                        ForEach(CameraSettings.AWBMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: settings.awbMode) { camera.push() }
                }
            }

            Sub("Tone")
            OpalStepper("Saturation", value: Binding(
                get: { settings.saturation },
                set: { settings.saturation = $0; camera.push() }), range: -10...10)
            OpalStepper("Contrast", value: Binding(
                get: { settings.contrast },
                set: { settings.contrast = $0; camera.push() }), range: -10...10)
            OpalStepper("Brightness", value: Binding(
                get: { settings.brightness },
                set: { settings.brightness = $0; camera.push() }), range: -10...10)
            Note("Each goes from -10 to 10. 0 leaves the picture as it is.", tone: .hint)

            Sub("Detail")
            OpalStepper("Sharpness", value: Binding(
                get: { settings.sharpness },
                set: { settings.sharpness = $0; camera.push() }), range: 0...4)
            OpalStepper("Luma denoise", value: Binding(
                get: { settings.lumaDenoise },
                set: { settings.lumaDenoise = $0; camera.push() }), range: 0...4)
            OpalStepper("Chroma denoise", value: Binding(
                get: { settings.chromaDenoise },
                set: { settings.chromaDenoise = $0; camera.push() }), range: 0...4)
            Note("Sharpness makes edges crisper. Luma denoise smooths grain in brightness. Chroma denoise smooths coloured speckles. Denoising also softens fine detail. Each goes from 0 (off) to 4.", tone: .hint)
        }
    }
}

// MARK: - Focus

/// One list, one answer. Manual focus and the camera's autofocus modes are
/// stored separately, but they are one decision, and showing them as separate
/// switches let them read as if they disagreed.
private struct FocusControls: View {
    @Environment(CameraModel.self) private var camera

    var body: some View {
        @Bindable var settings = camera.settings
        let choice = FocusChoice(settings)

        Fold("Focus", key: "focus",
             about: "The C1 has a lens that physically moves to focus. This chooses what moves it. Autofocus is the camera moving the lens by itself until the picture is sharp.") {
            VStack(spacing: 2) {
                ForEach(FocusChoice.allCases) { option in
                    Button {
                        option.apply(to: settings)
                        camera.resumeAutofocus()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: option == choice ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(option == choice ? Opal.accent : Opal.faint)
                            Text(option.label)
                                .foregroundStyle(option == choice ? Opal.text : Opal.dim)
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 24)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(option == choice ? .isSelected : [])
                }
            }

            if camera.focusHeld && choice.cameraDriven && choice != .whenAsked {
                Note("Holding the focus set by your click on the picture.", tone: .warning)
                Button("Release and return to this mode") { camera.resumeAutofocus() }
                    .buttonStyle(.glow)
            } else {
                Note(choice.effect, tone: .hint)
            }

            if choice == .byHand {
                OpalSlider("Lens position", value: Binding(
                    get: { Double(settings.lensPosition) },
                    set: { settings.lensPosition = Int($0); camera.push() }
                ), range: 0...255, step: 1, display: "\(settings.lensPosition)")
                Note("Lens position 0 to 255. 0 is infinity and 255 is the closest focus.", tone: .hint)
            } else if choice.cameraDriven {
                Button {
                    camera.device.triggerAutofocus()
                } label: {
                    Label("Focus now", systemImage: "camera.metering.center.weighted")
                }
                .buttonStyle(.quiet)
                Note("Clicking the picture focuses and meters there, once, and holds the result.",
                     tone: .hint)

                // Unrestricted autofocus hunts the whole lens travel, so a
                // gesture or someone walking past sends it racking to the far
                // wall and back. A desk sits in a narrow band.
                Toggle("Limit autofocus range", isOn: $settings.limitAfRange)
                    .onChange(of: settings.limitAfRange) { camera.push() }
                Note("Lens position is a number from 0 (focused far away) to 255 (focused very close). On: autofocus may only search between the two positions below, so it cannot rack to the far wall and back.",
                     tone: .hint)

                if settings.limitAfRange {
                    OpalSlider("Far limit", value: Binding(
                        get: { Double(settings.afRangeInfinity) },
                        set: {
                            settings.afRangeInfinity = min(Int($0), settings.afRangeMacro)
                            camera.push()
                        }
                    ), range: 0...255, step: 1, display: "\(settings.afRangeInfinity)")

                    OpalSlider("Near limit", value: Binding(
                        get: { Double(settings.afRangeMacro) },
                        set: {
                            settings.afRangeMacro = max(Int($0), settings.afRangeInfinity)
                            camera.push()
                        }
                    ), range: 0...255, step: 1, display: "\(settings.afRangeMacro)")
                    Note("The lens position right now is in the status area. Focus on yourself, read it, then set the limits either side of it.",
                         tone: .hint)
                }
            }
        }
    }
}

// MARK: - Camera

private struct CameraControls: View {
    @Environment(CameraModel.self) private var camera

    var body: some View {
        @Bindable var settings = camera.settings

        Fold("Camera", key: "camera",
             about: "The picture size and frame rate the camera sends to the Mac over USB, which way up it is, and the virtual camera that other apps see.") {
            Choice("Resolution", selection: $settings.outputMode,
                   options: CameraSettings.OutputMode.allCases.map { ($0, $0.rawValue) })
            if settings.outputMode == .fhd1080 {
                Note("1080p is the best choice for nearly everyone. It is exactly what other apps receive. The sensor always captures 3840×2160, and the camera scales it down before USB.",
                     tone: .hint)
            } else if let caution = settings.outputMode.caution {
                Note(caution, tone: .warning)
            } else {
                Note("Other apps always receive 1080p, so this picture is stretched up to fit and looks softer. Leave this at 1080p unless you have a reason.",
                     tone: .warning)
            }

            OpalStepper("Frame rate", value: $settings.fps,
                        range: 5...settings.outputMode.maxFps, step: 5,
                        display: "\(settings.fps) fps")
            if settings.fps > 30 {
                Note("Leave this at 30 unless you have a reason. Other apps only ever get 30 frames a second from Open Opal, so the extra frames show in this preview and nowhere else. They also cost light: at \(settings.fps) fps each frame has less time to collect it, so the picture is darker and grainier indoors.",
                     tone: .warning)
                Button("Go back to 30 fps") { settings.fps = 30 }.buttonStyle(.quiet)
            } else if settings.fps < 30 {
                Note("Leave this at 30 unless you have a reason. Below 30 the picture looks choppy in calls. It does let in more light, which can help in a very dark room.",
                     tone: .warning)
                Button("Go back to 30 fps") { settings.fps = 30 }.buttonStyle(.quiet)
            } else {
                Note("30 is the best choice for nearly everyone. It is what other apps receive, and it gives each frame the most time to collect light.",
                     tone: .hint)
            }

            Toggle("Rotate 180°", isOn: $settings.rotate180)
            Note("Done on the camera's ISP. The C1's sensor is mounted upside down, so this is normally on.",
                 tone: .hint)

            Toggle("Mirror preview", isOn: $settings.mirrorPreview)
            Note("Preview only. The virtual camera output is never mirrored.", tone: .hint)

            if settings.coldDirty {
                Note("Resolution, frame rate and rotation need the camera restarted. The button is in the status area.",
                     tone: .warning)
            }

            Sub("Virtual camera")
            Note("A virtual camera makes Open Opal's finished picture, blur included, show up as a camera called “Open Opal Camera” in Zoom, Meet, FaceTime and other apps.",
                 tone: .hint)
            VirtualCameraControls()

            Sub("Status light")
            HStack {
                Text("Light").foregroundStyle(Opal.dim)
                Spacer()
                Picker("Light", selection: $settings.statusLight) {
                    ForEach(CameraSettings.StatusLight.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Note("Lights the front of the camera while a video app is using it.", tone: .hint)
            Toggle("Startup animation", isOn: $settings.lightStartupAnimation)
            Note("Plays a quick rainbow when the camera connects.", tone: .hint)

            LightTestControls()
        }
    }
}

/// Temporary buttons for trying the status light by hand. Remove once the
/// colors and the startup animation are settled.
private struct LightTestControls: View {
    @Environment(CameraModel.self) private var camera

    var body: some View {
        Sub("Light test (temporary)")
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
            ForEach(CameraSettings.StatusLight.allCases) { light in
                Button(light.rawValue) { camera.lightOverride = light }
            }
        }
        .buttonStyle(.quiet)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
            ForEach(OpalDevice.LightAnimation.allCases) { animation in
                Button(animation.rawValue) { camera.device.playLightAnimation(animation) }
            }
        }
        .buttonStyle(.quiet)
        Button("Back to setting") { camera.lightOverride = nil }
            .buttonStyle(.quiet)
        Note(camera.lightOverride.map { "Showing \($0.rawValue) no matter what." }
             ?? "Following the setting above.", tone: .hint)
    }
}

private struct VirtualCameraControls: View {
    @Environment(CameraModel.self) private var camera

    var body: some View {
        if camera.autoLaunch.isIncludedInApp {
            Toggle("Start Open Opal automatically", isOn: Binding(
                get: { camera.autoLaunch.isEnabled },
                set: { camera.autoLaunch.setEnabled($0) }))
                .disabled(camera.autoLaunch.isChanging)
            Note("A login helper opens Open Opal when a video app uses “Open Opal Camera”.",
                 tone: .hint)
            if camera.autoLaunch.status == .requiresApproval {
                Note("Allow OpenOpal Launcher in Login Items to enable automatic startup.", tone: .warning)
                Button("Open Login Items") { camera.autoLaunch.openLoginItems() }
                    .buttonStyle(.quiet)
            }
            if let error = camera.autoLaunch.error {
                Note(error, tone: .warning)
            }
        }
        switch camera.installer.status {
        case .installed where camera.feeder.refused:
            Note("The virtual camera is installed but will not take pictures from this app, because the two come from different builds. Other apps see the camera-off card. Install the latest Open Opal and open it again.",
                 tone: .warning)
        case .installed where camera.feeder.missing:
            Note("The virtual camera is installed, but macOS did not start it after the last update. Restart your Mac to bring it back. Everything in this app still works.",
                 tone: .warning)
        case .installed:
            HStack(spacing: 6) {
                Circle().fill(camera.feeder.connected ? Opal.accent : Opal.faint).frame(width: 6, height: 6)
                Text(camera.feeder.connected
                     ? "Live. Pick “Open Opal Camera” in Zoom, Meet or FaceTime."
                     : "Installed. Waiting for the camera device to come up…")
                    .font(Opal.note)
                    .foregroundStyle(Opal.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .installing:
            Note("Installing…", tone: .warning)
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
                            .foregroundStyle(Opal.dim)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Try again") { camera.installer.install() }
                .buttonStyle(.quiet)
        case .unknown:
            if !camera.installer.isIncludedInApp {
                Note("This build supports camera controls and preview. Use a signed extension build to make the camera available to video apps.",
                     tone: .warning)
            } else {
                Button {
                    camera.installer.install()
                } label: {
                    Label("Install virtual camera", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.glow)
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
                        .buttonStyle(.quiet)

                case .downloading(let fraction):
                    ProgressView(value: fraction).tint(Opal.accent)
                    HStack {
                        Note("Downloading… \(Int((fraction * 100).rounded()))%", tone: .hint)
                        Spacer()
                        Button("Cancel") { installer.cancel() }
                            .buttonStyle(.quiet)
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
                        .buttonStyle(.quiet)
                    }

                case .failed(let message):
                    Note("Depth Pro 2 could not be installed. \(message)", tone: .warning)
                    Button("Try again") { installer.install() }
                        .buttonStyle(.quiet)
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
                    .foregroundStyle(selected ? Opal.accent : Opal.faint)
                    .font(.system(size: 14))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(name)
                        if experimental {
                            Text("Experimental")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .foregroundStyle(Opal.warning)
                                .background(Opal.warning.opacity(0.18), in: Capsule())
                        }
                    }
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(Opal.dim)
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

