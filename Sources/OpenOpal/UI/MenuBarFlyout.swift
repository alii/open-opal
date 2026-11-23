import SwiftUI

struct MenuBarFlyout: View {
    @Environment(CameraModel.self) private var camera
    let controller: MenuBarPanelController

    var body: some View {
        GeometryReader { geometry in
            // Wide enough for the picture and the settings side by side. The
            // width decides, not the floating flag, because a panel being
            // dragged off the menu bar floats before it has grown.
            let wide = geometry.size.width >= 700
            VStack(spacing: 0) {
                header
                if wide {
                    HStack(spacing: 0) {
                        LivePreview()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.black)
                            .overlay { PreviewOverlays(compact: false) }
                            .clipped()
                        Rectangle().fill(Opal.line).frame(width: 1)
                        ScrollView {
                            Controls()
                                .padding(.horizontal, 18)
                                .padding(.bottom, 12)
                        }
                        .scrollIndicators(.never)
                        .frame(width: 330)
                    }
                } else {
                    LivePreview()
                        .frame(height: geometry.size.width * 9 / 16)
                        .background(.black)
                        .overlay { PreviewOverlays(compact: true) }
                        .clipped()
                    Rectangle().fill(Opal.line).frame(height: 1)
                    // Always the same rows, so the panel is one fixed size and
                    // has nothing to scroll.
                    QuickControls()
                        .padding(16)
                    Spacer(minLength: 0)
                }
            }
        }
        .background { shortcuts }
        .padding(.top, controller.isFloating ? 0 : 10)
        .background(Opal.background, in: outline)
        .clipShape(outline)
        .overlay { outline.strokeBorder(Color.white.opacity(0.12), lineWidth: 1) }
        .preferredColorScheme(.dark)
        .tint(Opal.accent)
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Rectangle().fill(Opal.accent).frame(width: 7, height: 7)
                Caps("Open Opal", color: Opal.text)
                Text(controller.snapReady
                     ? "Release to dock"
                     : controller.isFloating ? "Drag to move or dock" : "Drag to float")
                    .font(Opal.note)
                    .foregroundStyle(controller.snapReady ? Opal.accent : Opal.faint)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 28)
            .contentShape(Rectangle())
            .overlay { PanelDragHandle(controller: controller) }

            actions

            Button {
                if controller.isFloating { controller.dock() } else { controller.detach() }
            } label: {
                Label(controller.isFloating ? "Dock" : "Float",
                      systemImage: controller.isFloating
                        ? "menubar.dock.rectangle" : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.quiet)
            .help(controller.isFloating ? "Dock to the menu bar" : "Float: all settings and a bigger picture")

            Button {
                controller.hide()
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.quiet)
            .help("Hide the controls. The camera keeps running.")
            .accessibilityLabel("Hide controls")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Everything that acts on the whole app or the whole camera, in one place.
    private var actions: some View {
        Menu {
            Button("Focus Now") { camera.device.triggerAutofocus() }
                .disabled(!camera.device.state.isLive)
            Button(camera.previewFrozen ? "Unfreeze Preview" : "Freeze Preview") {
                camera.previewFrozen.toggle()
            }
            Button("Reconnect Camera") { Task { await camera.reconnect() } }
            Divider()
            Button("Reset All Settings") {
                camera.settings.reset()
                camera.settings.resetBokeh()
                camera.push()
            }
            Divider()
            Button("Quit Open Opal") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Opal.text)
                .frame(width: 30, height: 26)
                .overlay { RoundedRectangle(cornerRadius: Opal.corner).strokeBorder(Opal.line, lineWidth: 1) }
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Focus now, freeze the preview, reconnect, reset, quit")
        .accessibilityLabel("More actions")
    }

    private var outline: PanelOutline {
        PanelOutline(arrowX: controller.anchorOffset, floating: controller.isFloating)
    }

    /// The app has no main menu as an accessory, so the old Camera menu's
    /// shortcuts live here and work while the panel is key.
    private var shortcuts: some View {
        Group {
            Button("Reconnect") { Task { await camera.reconnect() } }
                .keyboardShortcut("r")
            Button("Trigger Autofocus") { camera.device.triggerAutofocus() }
                .keyboardShortcut("f")
                .disabled(!camera.device.state.isLive)
            Button("Freeze Preview") { camera.previewFrozen.toggle() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Quit Open Opal") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

/// What is drawn over the picture: the camera-style readout, and above it the
/// connection state and the restart notice.
private struct PreviewOverlays: View {
    let compact: Bool

    var body: some View {
        // The readout hugs the picture, which keeps its 16:9 shape inside
        // whatever room the preview has.
        LiveStatus(compact: compact)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { PreviewStatus() }
    }
}

/// The picture, in a view of its own. It reads the newest frame, which changes
/// 30 times a second, and SwiftUI re-runs whichever view reads it. When that was
/// the whole panel, redrawing the panel cost a quarter of a core.
private struct LivePreview: View {
    @Environment(CameraModel.self) private var camera
    @State private var focusPulse: CGPoint?

    var body: some View {
        Color.black
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                GeometryReader { preview in
                    MetalPreview(
                        frame: camera.latestFrame,
                        mirrored: camera.settings.mirrorPreview,
                        paused: camera.previewPaused
                    ) { viewPoint, sensorPoint in
                        // Focus in sensor space; draw the reticle where the user clicked.
                        camera.focus(at: sensorPoint)
                        let p = CGPoint(x: viewPoint.x * preview.size.width,
                                        y: viewPoint.y * preview.size.height)
                        withAnimation(.smooth) { focusPulse = p }
                        Task {
                            try? await Task.sleep(for: .milliseconds(900))
                            withAnimation(.easeOut) { focusPulse = nil }
                        }
                    }
                    if let focusPulse {
                        FocusReticle()
                            .position(x: focusPulse.x, y: focusPulse.y)
                            .allowsHitTesting(false)
                    }
                }
            }
            // The picture keeps its shape and sits in the middle of whatever
            // room it is given.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FocusReticle: View {
    @State private var scale: CGFloat = 1.35

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Opal.accent, lineWidth: 1.5)
            .frame(width: 52, height: 52)
            .scaleEffect(scale)
            .onAppear {
                withAnimation(.spring(duration: 0.35)) { scale = 1.0 }
            }
    }
}

private struct PanelOutline: InsettableShape {
    let arrowX: CGFloat
    let floating: Bool
    var inset: CGFloat = 0

    func inset(by amount: CGFloat) -> Self {
        var copy = self
        copy.inset += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: inset, dy: inset)
        let top = rect.minY + (floating ? 0 : 10)
        let radius: CGFloat = 12
        let arrow = max(rect.minX + radius + 10, min(arrowX, rect.maxX - radius - 10))
        return Path { path in
            path.move(to: CGPoint(x: rect.minX + radius, y: top))
            if !floating {
                path.addLine(to: CGPoint(x: arrow - 10, y: top))
                path.addLine(to: CGPoint(x: arrow, y: rect.minY))
                path.addLine(to: CGPoint(x: arrow + 10, y: top))
            }
            path.addLine(to: CGPoint(x: rect.maxX - radius, y: top))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: top + radius), control: CGPoint(x: rect.maxX, y: top))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: top + radius))
            path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: top), control: CGPoint(x: rect.minX, y: top))
            path.closeSubpath()
        }
    }
}
