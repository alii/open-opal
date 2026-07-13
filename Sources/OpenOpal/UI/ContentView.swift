import SwiftUI

struct ContentView: View {
    @Environment(CameraModel.self) private var camera
    @State private var focusPulse: CGPoint?
    @State private var showInspector = true
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        ZStack(alignment: .topLeading) {
            preview
                .ignoresSafeArea()

            // A scrim over the toolbar strip. Two jobs: it gives the toolbar
            // something to sit on so the controls stay legible over a bright
            // frame, and — more importantly — it makes that strip *read* as
            // chrome rather than image, so it's obvious you can drag there and
            // that clicking won't refocus the lens.
            //
            // Multiple stops rather than a straight two-colour ramp: a linear
            // fade has a visible "edge" where it ends, because the eye is very
            // good at spotting a discontinuity in the second derivative. Easing
            // it out makes the boundary genuinely invisible.
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.55), location: 0.0),
                    .init(color: .black.opacity(0.38), location: 0.35),
                    .init(color: .black.opacity(0.16), location: 0.65),
                    .init(color: .black.opacity(0.04), location: 0.85),
                    .init(color: .clear,               location: 1.0),
                ],
                startPoint: .top, endPoint: .bottom)
            .frame(height: 96)
            .frame(maxWidth: .infinity, alignment: .top)
            .allowsHitTesting(false)
            .ignoresSafeArea()

            // Everything floats above the image. Liquid Glass is at its best
            // when there's something worth seeing *through* it.
            GlassEffectContainer(spacing: 18) {
                HStack(alignment: .top, spacing: 18) {
                    Spacer()
                    if showInspector {
                        Inspector()
                            .frame(width: 330)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                // Horizontal inset only. The inspector's scroll region runs to
                // the window's top and bottom edges — the resting position is
                // recreated by content margins inside the scroll view — so
                // scrolled content clips at the real window edge instead of at
                // an arbitrary line floating over the video.
                .padding(.horizontal, 18)
            }
            .ignoresSafeArea(edges: .vertical)
            .animation(.smooth(duration: 0.3), value: showInspector)

            if let focusPulse {
                FocusReticle()
                    .position(x: focusPulse.x, y: focusPulse.y)
                    .allowsHitTesting(false)
            }
        }
        .background(.black)
        .toolbar {
            // The status readout belongs in the toolbar, beside the button —
            // floating it over the image just stole space from the video, which
            // is the one thing the window exists to show.
            ToolbarItem(placement: .navigation) {
                StatusPill()
            }

            ToolbarItem(placement: .primaryAction) {
                // A Toggle in .button style, NOT a Button that swaps its icon.
                // Swapping the glyph makes the control look like a different
                // button depending on state; the platform convention is one
                // stable icon that highlights when the panel is open — which is
                // exactly what toggleStyle(.button) gives you, for free, with the
                // right selected-state appearance and accessibility semantics.
                Toggle(isOn: $showInspector) {
                    Label("Controls", systemImage: "sidebar.trailing")
                }
                .toggleStyle(.button)
                // White fill when open — the approved look. (A `.primary` fill
                // was tried and rendered as a heavy black disc in light mode.)
                // The glyph follows window activity so the system's inactive
                // dimming never pairs with a hardcoded black.
                .tint(.white)
                .foregroundStyle(showInspector && activeState != .inactive
                                 ? AnyShapeStyle(.black) : AnyShapeStyle(.primary))
                .help(showInspector ? "Hide controls" : "Show controls")
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        GeometryReader { geo in
            ZStack {
                MetalPreview(texture: camera.latestTexture,
                             mirrored: camera.settings.mirrorPreview) { viewPoint, sensorPoint in
                    // The camera is told where to focus in SENSOR space; the
                    // reticle is drawn where the user actually clicked. Using the
                    // sensor point for both is what made the box land mirrored.
                    camera.focus(at: sensorPoint)

                    let p = CGPoint(x: viewPoint.x * geo.size.width,
                                    y: viewPoint.y * geo.size.height)
                    withAnimation(.smooth) { focusPulse = p }
                    Task {
                        try? await Task.sleep(for: .milliseconds(900))
                        withAnimation(.easeOut) { focusPulse = nil }
                    }
                }

                switch camera.device.state {
                case .searching, .connecting:
                    Overlay(icon: "camera.aperture",
                            title: camera.isRebooting ? "Rebooting camera…" : "Connecting…",
                            spinning: true,
                            log: camera.device.bootLog)
                case .notFound:
                    Overlay(icon: "cable.connector.slash",
                            title: "No Opal C1 found",
                            detail: "Plug the camera in over USB.",
                            retry: { Task { await camera.reconnect() } })
                case .failed(let message):
                    Overlay(icon: "exclamationmark.triangle",
                            title: "Couldn't open the camera",
                            detail: message,
                            retry: { Task { await camera.reconnect() } },
                            log: camera.device.bootLog)
                case .streaming:
                    EmptyView()
                }
            }
        }
    }
}

// MARK: - Status

private struct StatusPill: View {
    @Environment(CameraModel.self) private var camera

    var body: some View {
        let t = camera.device.telemetry
        let live = camera.device.state.isLive

        HStack(spacing: 8) {
            Circle()
                .fill(live ? .green : .orange)
                .frame(width: 6, height: 6)

            if live {
                metric("\(camera.device.resolution.h)p")
                metric(String(format: "%.0f fps", t.fps))

                // Composer shipped ~300ms here. Showing the number is a quiet way
                // of proving the difference is real.
                //
                // Colour is reserved for trouble: the status dot already says
                // "healthy", and green metric text over warm glass is both
                // redundant and unreadable. Quiet when fine, loud when not.
                metric(String(format: "%.0f ms", t.latencyMs))
                    .foregroundStyle(t.latencyMs < 150 ? AnyShapeStyle(.secondary)
                                     : t.latencyMs < 250 ? AnyShapeStyle(.orange)
                                     : AnyShapeStyle(.red))
            } else {
                Text("Opal C1").font(.system(size: 11, weight: .medium))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .help(live
              ? "\(camera.device.sensorName) · \(camera.device.resolution.w)×\(camera.device.resolution.h) · \(camera.device.usbSpeed)"
              : "Opal C1")
    }

    private func metric(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Bits

private struct FocusReticle: View {
    @State private var scale: CGFloat = 1.35

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(.yellow.opacity(0.9), lineWidth: 1.5)
            .frame(width: 78, height: 78)
            .scaleEffect(scale)
            .onAppear {
                withAnimation(.spring(duration: 0.35)) { scale = 1.0 }
            }
    }
}

private struct Overlay: View {
    let icon: String
    let title: String
    var detail: String = ""
    var spinning = false
    var retry: (() -> Void)?
    var log: [String] = []
    @State private var angle: Double = 0

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .rotationEffect(.degrees(angle))
                .onAppear {
                    guard spinning else { return }
                    withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
                        angle = 360
                    }
                }
            Text(title).font(.system(size: 16, weight: .semibold))
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }

            // The takeover, narrated live: firmware size, the VPU falling off
            // the bus and re-enumerating, the pipeline graph, the handshake.
            // Real telemetry, not theatre — every line comes from the bridge as
            // it happens.
            if !log.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(log.suffix(8).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 430, alignment: .leading)
                .padding(.top, 4)
            }

            if let retry {
                Button("Try again", action: retry)
                    .buttonStyle(.glassProminent)
                    .controlSize(.regular)
                    .padding(.top, 4)
            }
        }
        .padding(34)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
