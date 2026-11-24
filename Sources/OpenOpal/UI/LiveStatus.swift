import SwiftUI

/// Everything that is shaping the picture right now, drawn over the preview
/// the way a camera draws its settings over the viewfinder.
///
/// The rule for this app is that nothing is hidden. The camera makes choices of
/// its own (shutter, ISO, white balance, where the lens sits), and the app adds
/// things on top (blur, extra brightness, a colour fix). All of it is on the
/// picture it affects: the camera's numbers along the bottom, and a line at
/// the top left for each thing the app is doing right now.
///
/// It sits on the preview, not beside it, so a reading that changes or a line
/// that appears cannot move any control. Other apps never see it: it is drawn
/// by this panel, on top of the picture, and is not part of the picture.
///
/// It is a view of its own because these numbers change a few times a second,
/// and only this overlay should redraw when they do.
struct LiveStatus: View {
    @Environment(CameraModel.self) private var camera
    /// The docked panel's preview is small, so it gets smaller type.
    let compact: Bool

    var body: some View {
        if camera.device.state.isLive {
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: compact ? 3 : 5) {
                        ForEach(appLines.filter { $0.on || $0.limit }) { LineView(line: $0, compact: compact) }
                    }
                    Spacer(minLength: 12)
                    Text(format)
                        .font(.system(size: compact ? 10 : 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Opal.text)
                }
                .padding(compact ? 9 : 14)
                .frame(maxWidth: .infinity)
                .background(alignment: .top) { scrim(from: .top) }

                Spacer(minLength: 0)

                HStack(spacing: 0) {
                    ForEach(readings) { ReadingView(reading: $0, compact: compact) }
                }
                .padding(.horizontal, compact ? 4 : 8)
                .padding(.vertical, compact ? 7 : 11)
                .background(alignment: .bottom) { scrim(from: .bottom) }
            }
            .shadow(color: .black.opacity(0.75), radius: 1.5, y: 0.5)
            .allowsHitTesting(false)
        }
    }

    /// Darkens the edge of the picture just enough for white text to read on
    /// a bright wall.
    private func scrim(from edge: UnitPoint) -> some View {
        // A straight fade from dark to clear has a visible edge where it ends.
        // These stops follow an ease-out curve, so it thins away to nothing.
        let curve: [(Double, Double)] = [(0, 0.60), (0.15, 0.47), (0.3, 0.35), (0.45, 0.24),
                                         (0.6, 0.15), (0.75, 0.08), (0.88, 0.03), (1, 0)]
        return LinearGradient(stops: curve.map { .init(color: .black.opacity($0.1), location: $0.0) },
                              startPoint: edge, endPoint: edge == .top ? .bottom : .top)
            .frame(height: compact ? 76 : 130)
    }

    private var format: String {
        let telemetry = camera.device.telemetry
        return String(format: "%dp  %.0f fps  %.0f ms", camera.device.resolution.h,
                      telemetry.fps, telemetry.latencyMs)
    }

    // MARK: What the camera chose

    private var readings: [Reading] {
        let telemetry = camera.device.telemetry
        let settings = camera.settings
        let none = "–"

        var shutter = Reading("Shutter", none)
        var iso = Reading("ISO", none)
        if telemetry.exposureUs > 0 {
            let fraction = Int((1_000_000.0 / Double(telemetry.exposureUs)).rounded())
            let auto = settings.autoExposure
            let maxed = auto && telemetry.iso >= 1500
            shutter = Reading("Shutter", "1/\(fraction)", tag: auto ? "auto" : "manual")
            iso = Reading("ISO", "\(telemetry.iso)", tag: maxed ? "max" : auto ? "auto" : "manual",
                          limit: maxed)
        }

        var white = Reading("White bal", none)
        if telemetry.colorTempK > 0 {
            let byApp = camera.assist.whiteBalanceK != nil
            let auto = !settings.manualWhiteBalance && !byApp
            let stuck = auto && telemetry.colorTempK <= LowLightAssist.autoFloorK
            white = Reading("White bal", "\(telemetry.colorTempK)K",
                            tag: byApp ? "app" : stuck ? "limit" : auto ? "auto" : "manual",
                            limit: stuck)
        }

        return [shutter, iso, white,
                Reading("Lens", "\(telemetry.lensPosition)", tag: camera.focusHeld ? "held" : nil)]
    }

    // MARK: What the app is adding

    /// Every way the app can change the picture. Only the ones that are on
    /// are drawn.
    private var appLines: [Line] {
        let settings = camera.settings
        let assist = camera.assist

        let blur: Line
        if settings.bokehEnabled {
            let mask = camera.maskMs > 0 ? String(format: ", mask %.0f ms", camera.maskMs) : ""
            blur = Line("blur", (settings.uniformBlur ? "Blur" : "Depth blur")
                        + String(format: " f/%.1f", settings.aperture) + mask, on: true)
        } else {
            blur = Line("blur", "Blur off")
        }

        let metering = settings.meterOnSubject && settings.autoExposure
            ? Line("meter", "Exposure measured on you", on: true)
            : Line("meter", "Exposure measured on the whole picture")

        let helping = settings.lowLightHelp
        let brightness = helping && assist.gain > 1.02
            ? Line("gain", String(format: "Brightness ×%.1f added", assist.gain), on: true,
                   help: "The camera ran out of exposure, so the app is brightening the picture. This adds grain.")
            : Line("gain", helping ? "No brightness added" : "Low light help off")

        let white = assist.whiteBalanceK.map {
            Line("white", "Camera white balance set to \($0) K", on: true,
                 help: "Auto white balance was stuck and the picture was orange, so the app set a warmer one on the camera.")
        } ?? Line("white", "Camera white balance not touched")

        let tint = assist.tint
        let colour = abs(tint.x - 1) > 0.03 || abs(tint.z - 1) > 0.03
            ? Line("tint", String(format: "Colour: red ×%.2f, green ×%.2f, blue ×%.2f", tint.x, tint.y, tint.z),
                   on: true,
                   help: "The camera's white balance could go no further, so the app is removing the rest of the orange.")
            : Line("tint", "No colour shift")

        let virtual: Line
        switch camera.installer.status {
        case .installed:
            virtual = camera.feeder.refused
                ? Line("virtual", "Virtual camera refused this app", limit: true)
                : camera.feeder.missing
                ? Line("virtual", "Virtual camera not running. Restart your Mac.", limit: true)
                : Line("virtual", camera.feeder.connected ? "Virtual camera live" : "Virtual camera starting",
                       on: camera.feeder.connected)
        case .installing:    virtual = Line("virtual", "Virtual camera installing")
        case .needsApproval: virtual = Line("virtual", "Virtual camera needs approval", limit: true)
        case .failed:        virtual = Line("virtual", "Virtual camera failed", limit: true)
        case .unknown:       virtual = Line("virtual", "Virtual camera not installed")
        }

        var lines = [blur, metering, brightness, white, colour, virtual]
        if camera.device.usbIsSlow {
            lines.insert(Line("usb", "Slow USB 2 link, so fewer frames. Replug the cable or try another port.",
                              limit: true), at: 0)
        }
        if camera.previewFrozen { lines.insert(Line("frozen", "Preview frozen", limit: true), at: 0) }
        return lines
    }
}

/// One number the camera reports, under its name.
private struct Reading: Identifiable {
    let name: String
    let value: String
    /// How the number came about: auto, manual, at its limit, or set by the app.
    let tag: String?
    let limit: Bool
    var id: String { name }

    init(_ name: String, _ value: String, tag: String? = nil, limit: Bool = false) {
        self.name = name
        self.value = value
        self.tag = tag
        self.limit = limit
    }
}

private struct ReadingView: View {
    let reading: Reading
    let compact: Bool

    var body: some View {
        VStack(spacing: compact ? 1 : 3) {
            Text((reading.name + (reading.tag.map { " " + $0 } ?? "")).uppercased())
                .font(.system(size: compact ? 8 : 9.5, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(reading.limit ? Opal.warning : Color.white.opacity(0.72))
            Text(reading.value)
                .font(.system(size: compact ? 13 : 17, weight: .medium, design: .monospaced))
                .foregroundStyle(reading.limit ? Opal.warning : .white)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// One thing the app is doing, or could be doing, to the picture.
private struct Line: Identifiable {
    let text: String
    /// True while this is changing the picture.
    let on: Bool
    let limit: Bool
    let id: String

    init(_ id: String, _ text: String, on: Bool = false, limit: Bool = false, help: String? = nil) {
        self.id = id
        self.text = text
        self.on = on
        self.limit = limit
    }
}

private struct LineView: View {
    let line: Line
    let compact: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Rectangle()
                .fill(line.limit ? Opal.warning : Opal.accent)
                .frame(width: compact ? 5 : 6, height: compact ? 5 : 6)
            Text(line.text)
                .foregroundStyle(line.limit ? Opal.warning : .white)
                .lineLimit(1)
        }
        .font(.system(size: compact ? 10 : 12, weight: .medium))
        .accessibilityElement(children: .combine)
    }
}
