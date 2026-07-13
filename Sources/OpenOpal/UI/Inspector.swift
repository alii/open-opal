import SwiftUI

struct Inspector: View {
    @Environment(CameraModel.self) private var camera
    /// Ties each section's glass to an identity so the shapes can morph into one
    /// another rather than being destroyed and recreated.
    @Namespace private var glass

    /// Live-measured height of the advanced block, so the fold spacer can match
    /// it exactly at the moment of collapse.
    @State private var advancedHeight: CGFloat = 0
    /// Stand-in for the just-removed advanced block. Starts at its exact height
    /// (net layout change: zero) and springs to nothing.
    @State private var foldSpacer: CGFloat = 0

    @State private var scrollPos = ScrollPosition()


    var body: some View {
        @Bindable var settings = camera.settings

        // Each section is its OWN piece of glass inside a container, rather than
        // one big static pane with content sliding around inside it. That's what
        // makes the expansion feel liquid: the container lets neighbouring shapes
        // merge when they're close and split apart as they separate, and
        // matchedGeometry lets the glass flow between layouts instead of popping.
        //
        // The old version animated a fixed pane while its contents jumped — every
        // part of that reads as cheap, because the material stayed rigid while the
        // things inside it teleported.
        ScrollView {
            GlassEffectContainer(spacing: 12) {
                VStack(spacing: 12) {

                // ============================================================
                // SIMPLE — what almost everyone actually wants. One switch and
                // one slider. The camera handles the rest.
                // ============================================================
                Section("Background", icon: "camera.aperture", in: glass) {
                    Toggle("Blur background", isOn: $settings.bokehEnabled)

                    if settings.bokehEnabled {
                        Slider2("Amount", value: $settings.blurAmount,
                                range: 0...1,
                                display: String(format: "%.0f%%", settings.blurAmount * 100))

                        if camera.maskMs > 0 {
                            Note(String(format: "Mask: %.0f ms · %@ quality",
                                        camera.maskMs, settings.matteQuality.rawValue),
                                 tone: .hint)
                        }
                    }
                }

                Section("Image", icon: "person.crop.square", in: glass) {
                    Toggle("Mirror preview", isOn: $settings.mirrorPreview)
                    Toggle("Expose for my face", isOn: $settings.meterOnSubject)
                }

                // A Button, not a Toggle — a disclosure control's state is shown
                // by the open panel and the chevron, so it needs no "on" fill
                // (and buttons sidestep the light/dark × focused/unfocused fill
                // matrix that made every hand-painted attempt wrong somewhere).
                //
                // It sits in its OWN GlassEffectContainer, which is the whole
                // trick: glass is the right material over live video (a flat
                // tint was invisible and left bare text floating on the image),
                // but any glass shape in the outer container joins its liquid
                // blending — scrolling dragged the sections within merge
                // distance and visibly pulled the button's shape toward them.
                // Containers don't blend across nesting, so this one keeps the
                // legible glass chip with none of the goo, and the plain button
                // style keeps it from gel-squishing on press.
                GlassEffectContainer {
                Button {
                    camera.holdPreviewDuringAnimation()
                    if settings.showAdvanced {
                        // Swap the block for its own ghost in one frame, then
                        // melt the ghost AND drive the scroll home in the same
                        // transaction. Left to clamping, the offset only moves
                        // when the shrinking content forces it — indirect and
                        // lumpy. On the same spring, offset and max-offset
                        // follow the same curve, so it never clamps.
                        foldSpacer = advancedHeight
                        settings.showAdvanced = false
                        Task { @MainActor in
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                                foldSpacer = 0
                                scrollPos.scrollTo(edge: .top)
                            }
                        }
                    } else {
                        foldSpacer = 0
                        settings.showAdvanced = true
                    }
                } label: {
                    Label("Advanced", systemImage: settings.showAdvanced
                          ? "chevron.up" : "slider.horizontal.3")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .glassEffect(.regular, in: .capsule)
                }

                // Collapse without the snap, in a way glass actually permits.
                //
                // Two constraints collide here. (1) Removing the advanced block
                // takes its height out of the scroll content in one frame, and a
                // scroll offset pointing into that vanished space snaps hard.
                // (2) But the block can't be "folded" with frame/clip/opacity
                // tricks either — the slabs are rendered by the enclosing
                // GlassEffectContainer, not by these views, so clipping the
                // subtree hides the controls while the glass keeps drawing at
                // full size (that was the everything-always-visible bug).
                //
                // So: remove the views for real — glass dissolves them correctly
                // — and in the SAME frame drop in an invisible spacer of the
                // exact measured height. Net content change: zero, so nothing
                // snaps. Then the spacer animates away on the spring, shrinking
                // the content continuously and riding the panel home smoothly.
                if settings.showAdvanced {
                    advanced(settings)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            advancedHeight = $0
                        }
                        // Plain fade. blurReplace ran a live gaussian over the
                        // entire advanced subtree on every animation frame,
                        // stacked on top of the glass compositing — a large part
                        // of why the spring stuttered.
                        .transition(.opacity)
                } else if foldSpacer > 0 {
                    Color.clear.frame(height: foldSpacer)
                }
                }
                .padding(16)
            }
            // A spring, not a duration curve. Expanding a panel is a physical
            // gesture and should decelerate like one; a linear-ish ease is exactly
            // what made it feel mechanical.
            .animation(.spring(response: 0.42, dampingFraction: 0.82),
                       value: settings.showAdvanced)
            .animation(.spring(response: 0.35, dampingFraction: 0.85),
                       value: settings.bokehEnabled)
        }
        .scrollIndicators(.never)
        // Only scroll (and only bounce) once the content genuinely overflows —
        // i.e. when Advanced is open.
        .scrollBounceBehavior(.basedOnSize)
        // The scroll region runs edge-to-edge — all the way to the window's top
        // and bottom — and the CONTENT carries the inset instead. So at rest the
        // panel sits exactly where it used to, but scrolled content travels to
        // the real window edge before it clips. A window edge is a legitimate
        // boundary; the old floating viewport sliced rows mid-air at an
        // arbitrary line, which is what read as broken. No fades needed — this
        // is how every native macOS sidebar behaves.
        .contentMargins(.top, 62, for: .scrollContent)
        .contentMargins(.bottom, 18, for: .scrollContent)
        .scrollPosition($scrollPos)
        // The glass slabs cast a soft shadow that reaches past the scroll
        // viewport's width, and the default clip cut it off in a dead-straight
        // vertical line over the video. The clip isn't protecting anything —
        // vertically the scroll region already ends at the window edges, which
        // clip for free — so let the shadows fall where they naturally would.
        .scrollClipDisabled()
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // ================================================================
    // ADVANCED — every knob the ISP exposes, for people who want them.
    // ================================================================
    @ViewBuilder
    private func advanced(_ settings: CameraSettings) -> some View {
        @Bindable var settings = settings

        VStack(spacing: 14) {

                // --- Format -------------------------------------------------
                Section("Format", icon: "aspectratio", plain: true) {
                    Picker("", selection: $settings.outputMode) {
                        ForEach(CameraSettings.OutputMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Stepper("\(settings.fps) fps", value: $settings.fps,
                            in: 5...settings.outputMode.maxFps, step: 5)
                        .font(.system(size: 12))

                    if let caution = settings.outputMode.caution {
                        Note(caution, tone: .warning)
                    }

                    Toggle("Rotate 180°", isOn: $settings.rotate180)
                    Toggle("Mirror preview", isOn: $settings.mirrorPreview)

                    if settings.rotate180 {
                        Note("The C1's sensor is mounted upside down. Rotation happens on the camera, so it costs nothing.",
                             tone: .hint)
                    }

                    // Resolution and fps are baked into the device pipeline, so
                    // changing them means rebooting the Myriad. Make that an
                    // explicit act rather than a surprise mid-call black frame.
                    if settings.coldDirty {
                        Button {
                            Task { await camera.applyColdChanges() }
                        } label: {
                            Label("Restart camera to apply", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                    }
                }

                // --- Exposure -----------------------------------------------
                Section("Exposure", icon: "sun.max", plain: true) {
                    Toggle("Auto", isOn: $settings.autoExposure)
                        .onChange(of: settings.autoExposure) { camera.push() }

                    if settings.autoExposure {
                        Slider2("Compensation", value: Binding(
                            get: { Double(settings.evCompensation) },
                            set: { settings.evCompensation = Int($0); camera.push() }
                        ), range: -9...9, step: 1,
                        display: settings.evCompensation > 0
                            ? "+\(settings.evCompensation)" : "\(settings.evCompensation)")

                        Toggle("Lock", isOn: $settings.aeLock)
                            .onChange(of: settings.aeLock) { camera.push() }

                        Toggle("Meter on me", isOn: $settings.meterOnSubject)

                        if settings.meterOnSubject {
                            Note("Exposes for your face instead of the whole frame — stops a bright window behind you leaving you in shadow.",
                                 tone: .hint)
                        }
                    } else {
                        Slider2("Shutter", value: Binding(
                            get: { Double(settings.exposureUs) },
                            set: { settings.exposureUs = Int($0); camera.push() }
                        ), range: 100...Double(settings.maxExposureUs),
                        display: settings.shutterFraction)

                        Slider2("ISO", value: Binding(
                            get: { Double(settings.iso) },
                            set: { settings.iso = Int($0); camera.push() }
                        ), range: 100...1600, step: 50, display: "\(settings.iso)")
                    }
                }

                // --- Focus ---------------------------------------------------
                Section("Focus", icon: "camera.metering.spot", plain: true) {
                    Toggle("Manual", isOn: $settings.manualFocus)
                        .onChange(of: settings.manualFocus) { camera.push() }

                    if settings.manualFocus {
                        Slider2("Position", value: Binding(
                            get: { Double(settings.lensPosition) },
                            set: { settings.lensPosition = Int($0); camera.push() }
                        ), range: 0...255, step: 1, display: "\(settings.lensPosition)")
                    } else {
                        Picker("Mode", selection: $settings.afMode) {
                            ForEach(CameraSettings.AFMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .onChange(of: settings.afMode) { camera.push() }

                        Button {
                            camera.device.triggerAutofocus()
                        } label: {
                            Label("Refocus now", systemImage: "camera.metering.center.weighted")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)

                        Note("Click anywhere on the image to focus there.", tone: .hint)
                    }
                }

                // --- Colour ---------------------------------------------------
                Section("Colour", icon: "drop", plain: true) {
                    Toggle("Manual white balance", isOn: $settings.manualWhiteBalance)
                        .onChange(of: settings.manualWhiteBalance) { camera.push() }

                    if settings.manualWhiteBalance {
                        Slider2("Temperature", value: Binding(
                            get: { Double(settings.whiteBalanceK) },
                            set: { settings.whiteBalanceK = Int($0); camera.push() }
                        ), range: 2000...10000, step: 100, display: "\(settings.whiteBalanceK)K")
                    } else {
                        Picker("Preset", selection: $settings.awbMode) {
                            ForEach(CameraSettings.AWBMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .onChange(of: settings.awbMode) { camera.push() }
                    }

                    Stepper2("Saturation", value: Binding(
                        get: { settings.saturation },
                        set: { settings.saturation = $0; camera.push() }), range: -10...10)
                    Stepper2("Contrast", value: Binding(
                        get: { settings.contrast },
                        set: { settings.contrast = $0; camera.push() }), range: -10...10)
                    Stepper2("Brightness", value: Binding(
                        get: { settings.brightness },
                        set: { settings.brightness = $0; camera.push() }), range: -10...10)
                }

                // --- Flicker --------------------------------------------------
                Section("Flicker", icon: "lightbulb", plain: true) {
                    Picker("", selection: $settings.antiBanding) {
                        ForEach(CameraSettings.AntiBanding.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: settings.antiBanding) { camera.push() }

                    Note(settings.antiBanding.hint, tone: .hint)
                }

                // --- Detail ----------------------------------------------------
                Section("Detail", icon: "wand.and.sparkles", plain: true) {
                    Stepper2("Sharpness", value: Binding(
                        get: { settings.sharpness },
                        set: { settings.sharpness = $0; camera.push() }), range: 0...4)
                    Stepper2("Luma denoise", value: Binding(
                        get: { settings.lumaDenoise },
                        set: { settings.lumaDenoise = $0; camera.push() }), range: 0...4)
                    Stepper2("Chroma denoise", value: Binding(
                        get: { settings.chromaDenoise },
                        set: { settings.chromaDenoise = $0; camera.push() }), range: 0...4)
                }

                // --- Bokeh ------------------------------------------------------
                Section("Bokeh", icon: "camera.aperture", plain: true) {
                    Picker("Mask", selection: $settings.matteQuality) {
                        ForEach(CameraSettings.MatteQuality.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Note(settings.matteQuality.hint, tone: .hint)

                    Toggle("Match blur to frame", isOn: $settings.syncBokeh)
                    Note(settings.syncBokeh
                         ? "Waits for this frame's mask. Adds latency; the blur can't lag behind you."
                         : "Reuses the newest mask. Faster, but the blur trails your movement.",
                         tone: .hint)

                    Toggle("Depth-graded blur", isOn: Binding(
                        get: { !settings.uniformBlur },
                        set: { settings.uniformBlur = !$0 }
                    ))
                    Note(settings.uniformBlur
                         ? "Uniform: everything behind you blurs equally. Robust, and skips the depth model entirely."
                         : "Blur grows with distance, like a real lens — when the depth map is right. Adds ~20ms.",
                         tone: .hint)

                    Slider2("Aperture", value: $settings.aperture,
                            range: 1.4...16,
                            display: String(format: "f/%.1f", settings.aperture))

                    if !settings.uniformBlur {
                        Toggle("Track subject", isOn: $settings.autoFocusSubject)

                        if !settings.autoFocusSubject {
                            Slider2("Focal plane", value: $settings.focusDistance,
                                    range: 0...1,
                                    display: String(format: "%.2f", settings.focusDistance))
                        }
                    }

                    Slider2("Highlight bloom", value: $settings.highlightBloom,
                            range: 0...1,
                            display: String(format: "%.0f%%", settings.highlightBloom * 100))

                    Picker("Iris", selection: $settings.apertureShape) {
                        ForEach(CameraSettings.ApertureShape.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Button("Reset all") {
                    camera.settings.reset()
                    camera.settings.resetBokeh()
                    camera.push()
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .padding(.top, 2)
        }
        .padding(6)
        // ONE glass surface for the entire advanced region, with flat fills for
        // the sections inside it. Glass is live — it re-refracts the video
        // behind it on every frame — so seven independent slabs being spring-
        // animated together multiplied the compositing cost of every animation
        // frame. Collapsing them into a single slab is what lets the
        // expand/collapse run at full frame rate.
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .modifier(GlassID(id: "advanced-slab", namespace: glass))
    }
}

// MARK: - Building blocks

/// Each section is a real piece of glass with its own identity, so the container
/// can morph it — merge it with a neighbour when they're close, split it away
/// when they aren't. A flat tinted rectangle inside a single static pane can't do
/// any of that; it can only appear and disappear.
private struct Section<Content: View>: View {
    let title: String
    let icon: String
    var namespace: Namespace.ID?
    /// Plain sections draw a flat fill instead of their own glass. Glass is a
    /// LIVE surface — it re-refracts the video behind it every frame — so nine
    /// independent slabs being spring-animated at once is a compositing bill
    /// the animation cannot pay. The advanced sections all share one slab (see
    /// `advanced`), and only the few always-visible sections keep their own.
    var plain = false
    @ViewBuilder var content: Content

    init(_ title: String, icon: String, in namespace: Namespace.ID? = nil,
         plain: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.namespace = namespace
        self.plain = plain
        self.content = content()
    }

    var body: some View {
        let core = VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.bottom, 1)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.system(size: 12))

        if plain {
            core.background(.primary.opacity(0.05), in: .rect(cornerRadius: 14))
        } else {
            core.glassEffect(.regular, in: .rect(cornerRadius: 18))
                .modifier(GlassID(id: title, namespace: namespace))
        }
    }
}

/// glassEffectID is only meaningful inside a container; apply it when we have one.
private struct GlassID: ViewModifier {
    let id: String
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            content.glassEffectID(id, in: namespace)
        } else {
            content
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
