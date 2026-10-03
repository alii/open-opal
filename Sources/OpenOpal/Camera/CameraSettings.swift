import Foundation
import Observation

/// Everything the C1's ISP can be told to do, in one observable model.
///
/// Split into two groups that behave very differently:
///  - **hot** settings stream over the XLink control queue and apply within a
///    frame or two.
///  - **cold** settings (resolution, fps) are baked into the device pipeline and
///    require a reboot of the Myriad — roughly 2-5 seconds of black.
@Observable
final class CameraSettings {

    // MARK: - Cold (require pipeline rebuild)

    var outputMode: OutputMode = .fhd1080 { didSet { if oldValue != outputMode { coldDirty = true; save() } } }
    var fps: Int = 30                     { didSet { if oldValue != fps { coldDirty = true; save() } } }

    /// The C1's sensor is mounted upside down in the housing — Opal's stock
    /// firmware corrects for it, so nobody ever knew. We boot our own pipeline,
    /// so we have to undo it ourselves. Done on the device ISP (free), which is
    /// why it's a cold setting.
    var rotate180 = true                  { didSet { if oldValue != rotate180 { coldDirty = true; save() } } }

    /// Preview only. A webcam preview should read like a mirror, but the image
    /// other people see must NOT be mirrored or your text comes out backwards —
    /// so this never touches the frames themselves.
    var mirrorPreview = true { didSet { save() } }

    /// Set when a cold setting changed and the pipeline needs a reboot to catch up.
    var coldDirty = false

    /// The IMX582 has no native 1080p mode — its smallest sensor config is 4K.
    /// Every mode below captures 4K and scales on the *device* ISP, because
    /// shipping full 4K NV12 over USB saturates SuperSpeed (~370 MB/s) and costs
    /// ~297ms of latency at only 20fps. Scaling first: ~50ms at a solid 30fps.
    enum OutputMode: String, Codable, CaseIterable, Identifiable {
        case uhd4K   = "4K"
        case fhd1080 = "1080p"
        case hd720   = "720p"

        var id: String { rawValue }

        /// ISP downscale numerator/denominator, or nil to pass 4K straight through.
        var ispScale: (num: Int, den: Int)? {
            switch self {
            case .uhd4K:   return nil
            case .fhd1080: return (1, 2)
            case .hd720:   return (1, 3)
            }
        }

        var pixelSize: (w: Int, h: Int) {
            switch self {
            case .uhd4K:   return (3840, 2160)
            case .fhd1080: return (1920, 1080)
            case .hd720:   return (1280, 720)
            }
        }

        var maxFps: Int { self == .uhd4K ? 30 : 42 }

        /// Honest warning for the mode that looks best on paper and worst in practice.
        var caution: String? {
            self == .uhd4K
                ? "Saturates USB — expect ~300ms latency and dropped frames. Great for stills, poor for calls."
                : nil
        }
    }

    // MARK: - Exposure

    var autoExposure = true { didSet { save() } }
    var exposureUs: Int = 8_000 { didSet { save() } } // 1..33000 µs
    var iso: Int = 400 { didSet { save() } } // 100..1600
    var evCompensation: Int = 0 { didSet { save() } } // -9..9
    var aeLock = false { didSet { save() } }

    /// Opt-in face metering. This runs person segmentation even with bokeh off,
    /// so leave it disabled until the user needs help with a backlit subject.
    var meterOnSubject = false { didSet { save() } }

    /// Shutter expressed the way a photographer thinks about it.
    var shutterFraction: String {
        exposureUs <= 0 ? "—" : "1/\(Int((1_000_000.0 / Double(exposureUs)).rounded()))"
    }

    /// The sensor can't expose longer than one frame interval.
    var maxExposureUs: Int { min(33_000, Int(1_000_000.0 / Double(max(fps, 1)))) }

    // MARK: - Focus  (the C1 has a real autofocus lens)

    var manualFocus = false { didSet { save() } }
    var lensPosition: Int = 120 { didSet { save() } } // 0..255
    var afMode: AFMode = .continuousVideo { didSet { save() } }

    enum AFMode: String, Codable, CaseIterable, Identifiable {
        case auto              = "Auto"
        case continuousVideo   = "Continuous"
        case macro             = "Macro"
        case edof              = "Extended DoF"
        var id: String { rawValue }
    }

    // MARK: - White balance

    var manualWhiteBalance = false { didSet { save() } }
    var whiteBalanceK: Int = 5600 { didSet { save() } } // 1000..12000
    var awbMode: AWBMode = .auto { didSet { save() } }
    var awbLock = false { didSet { save() } }

    enum AWBMode: String, Codable, CaseIterable, Identifiable {
        case auto            = "Auto"
        case incandescent    = "Incandescent"
        case fluorescent     = "Fluorescent"
        case warmFluorescent = "Warm Fluorescent"
        case daylight        = "Daylight"
        case cloudy          = "Cloudy"
        case twilight        = "Twilight"
        case shade           = "Shade"
        var id: String { rawValue }
    }

    // MARK: - Flicker  ("Hz" in Composer)

    /// Fluorescent and LED lights pulse at the mains frequency. If the shutter
    /// isn't a multiple of that pulse, you get rolling bands across the frame.
    /// Pick the frequency of your local grid: 60Hz in the US/Americas, 50Hz in
    /// most of Europe/Asia/Africa.
    var antiBanding: AntiBanding = .hz60 { didSet { save() } }

    enum AntiBanding: String, Codable, CaseIterable, Identifiable {
        case off  = "Off"
        case hz50 = "50 Hz"
        case hz60 = "60 Hz"
        case auto = "Auto"
        var id: String { rawValue }

        var hint: String {
            switch self {
            case .hz50: "Europe, Asia, Africa, Australia"
            case .hz60: "North & South America, Japan"
            case .auto: "Let the camera detect it"
            case .off:  "No flicker compensation"
            }
        }
    }

    // MARK: - Image tuning

    var sharpness: Int = 1 { didSet { save() } } // 0..4
    var lumaDenoise: Int = 1 { didSet { save() } } // 0..4
    var chromaDenoise: Int = 1 { didSet { save() } } // 0..4
    var brightness: Int = 0 { didSet { save() } } // -10..10
    var contrast: Int = 0 { didSet { save() } } // -10..10
    var saturation: Int = 0 { didSet { save() } } // -10..10

    // MARK: - Bokeh (host-side; see BokehRenderer)

    /// Most people want one switch and one slider. Everything else is here for
    /// the person who actually wants to argue with the ISP.
    var showAdvanced = false { didSet { save() } }

    var bokehEnabled = false { didSet { save() } }

    /// The one bokeh control a normal person should ever touch: 0 = off, 1 = as
    /// much blur as we can give you. Mapped onto a real f-number underneath,
    /// because that's what the shader wants — but nobody should have to know that
    /// f/1.4 is "more" and f/16 is "less", which is backwards from every other
    /// slider in software.
    var blurAmount: Double {
        get { (16.0 - aperture) / (16.0 - 1.4) }
        set { aperture = 16.0 - newValue.clamped(0, 1) * (16.0 - 1.4) }
    }

    /// Compute the mask for THE frame being rendered, instead of reusing the most
    /// recent one.
    ///
    /// Asynchronous analysis never stalls the frame rate, but it means frame N is
    /// composited with a mask derived from frame N-2 — the mask always describes
    /// where you *were*. That misalignment is the "blur trails me" effect, and no
    /// amount of downstream filtering can fix it, because the data is simply late.
    ///
    /// Waiting costs latency (and some frame rate), and buys exact alignment.
    /// It's the right trade for a video call, where 80ms of latency is invisible
    /// but a blur lagging behind your head is not.
    var syncBokeh = true { didSet { save() } }

    /// Blur everything behind the subject by the same amount, ignoring depth.
    ///
    /// This is the default, and it's the right default. Depth-graded defocus is
    /// more physically correct, but it depends on a monocular depth estimate that
    /// can be wrong about the whole scene — putting a soft patch on a cheek, or
    /// leaving a chunk of wall sharp. A mask can only get the *edge* wrong.
    ///
    /// Dropping depth also removes ~20ms of inference from the frame, which in
    /// synchronous mode is latency you feel. All of that budget goes into a better
    /// mask instead, which is where the visible quality actually lives. This is
    /// essentially what Google Meet does, and it's why Meet looks clean.
    var uniformBlur = true { didSet { save() } }

    /// How much compute to spend on the mask. With depth gone, we can afford the
    /// good one — and the mask is now the only thing standing between us and a
    /// clean edge, so it's worth every millisecond.
    var matteQuality: MatteQuality = .accurate { didSet { save() } }

    enum MatteQuality: String, Codable, CaseIterable, Identifiable {
        case fast     = "Fast"
        case balanced = "Balanced"
        case accurate = "Accurate"
        var id: String { rawValue }

        var hint: String {
            switch self {
            case .fast:     "Blocky edges. Only if you're short on CPU."
            case .balanced: "Good compromise."
            case .accurate: "Best edges — hair and glasses. Costs a few ms."
            }
        }
    }
    /// Real lens math: smaller f-number = shallower depth of field.
    var aperture: Double = 2.8 { didSet { save() } } // f/1.4 .. f/16
    /// Where the focal plane sits, as normalized scene depth (0 = near, 1 = far).
    var focusDistance: Double = 0.35 { didSet { save() } }
    /// Follow the subject automatically instead of a fixed focal plane.
    var autoFocusSubject = true { didSet { save() } }
    var apertureShape: ApertureShape = .circular { didSet { save() } }
    /// Bloom on specular highlights — what makes bokeh read as glass, not blur.
    var highlightBloom: Double = 0.55 { didSet { save() } }

    enum ApertureShape: String, Codable, CaseIterable, Identifiable {
        case circular  = "Circular"
        case hexagonal = "Hexagonal"
        var id: String { rawValue }
    }

    // MARK: - Saved camera controls

    static let persistenceKey = "cameraSettings.v1"
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var restoring = true

    /// Restore before connecting; missing or invalid values keep the defaults above.
    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        defer { restoring = false; coldDirty = false }
        guard let data = preferences.data(forKey: Self.persistenceKey),
              let saved = try? JSONDecoder().decode(SavedControls.self, from: data),
              saved.version == 1 else { return }
        if let value = saved.outputMode { outputMode = value }
        if let value = saved.fps, (1...outputMode.maxFps).contains(value) { fps = value }
        if let value = saved.rotate180 { rotate180 = value }
        if let value = saved.mirrorPreview { mirrorPreview = value }
        if let value = saved.autoExposure { autoExposure = value }
        if let value = saved.exposureUs, (1...maxExposureUs).contains(value) { exposureUs = value }
        if let value = saved.iso, (100...1600).contains(value) { iso = value }
        if let value = saved.evCompensation, (-9...9).contains(value) { evCompensation = value }
        if let value = saved.aeLock { aeLock = value }
        if let value = saved.meterOnSubject { meterOnSubject = value }
        if let value = saved.manualFocus { manualFocus = value }
        if let value = saved.lensPosition, (0...255).contains(value) { lensPosition = value }
        if let value = saved.afMode { afMode = value }
        if let value = saved.manualWhiteBalance { manualWhiteBalance = value }
        if let value = saved.whiteBalanceK, (1000...12000).contains(value) { whiteBalanceK = value }
        if let value = saved.awbMode { awbMode = value }
        if let value = saved.awbLock { awbLock = value }
        if let value = saved.antiBanding { antiBanding = value }
        if let value = saved.sharpness, (0...4).contains(value) { sharpness = value }
        if let value = saved.lumaDenoise, (0...4).contains(value) { lumaDenoise = value }
        if let value = saved.chromaDenoise, (0...4).contains(value) { chromaDenoise = value }
        if let value = saved.brightness, (-10...10).contains(value) { brightness = value }
        if let value = saved.contrast, (-10...10).contains(value) { contrast = value }
        if let value = saved.saturation, (-10...10).contains(value) { saturation = value }
        if let value = saved.showAdvanced { showAdvanced = value }
        if let value = saved.bokehEnabled { bokehEnabled = value }
        if let value = saved.syncBokeh { syncBokeh = value }
        if let value = saved.uniformBlur { uniformBlur = value }
        if let value = saved.matteQuality { matteQuality = value }
        if let value = saved.aperture, (1.4...16).contains(value) { aperture = value }
        if let value = saved.focusDistance, (0...1).contains(value) { focusDistance = value }
        if let value = saved.autoFocusSubject { autoFocusSubject = value }
        if let value = saved.apertureShape { apertureShape = value }
        if let value = saved.highlightBloom, (0...1).contains(value) { highlightBloom = value }
    }

    private func save() {
        guard !restoring else { return }
        let saved = SavedControls(
            outputMode: outputMode,
            fps: fps,
            rotate180: rotate180,
            mirrorPreview: mirrorPreview,
            autoExposure: autoExposure,
            exposureUs: exposureUs,
            iso: iso,
            evCompensation: evCompensation,
            aeLock: aeLock,
            meterOnSubject: meterOnSubject,
            manualFocus: manualFocus,
            lensPosition: lensPosition,
            afMode: afMode,
            manualWhiteBalance: manualWhiteBalance,
            whiteBalanceK: whiteBalanceK,
            awbMode: awbMode,
            awbLock: awbLock,
            antiBanding: antiBanding,
            sharpness: sharpness,
            lumaDenoise: lumaDenoise,
            chromaDenoise: chromaDenoise,
            brightness: brightness,
            contrast: contrast,
            saturation: saturation,
            showAdvanced: showAdvanced,
            bokehEnabled: bokehEnabled,
            syncBokeh: syncBokeh,
            uniformBlur: uniformBlur,
            matteQuality: matteQuality,
            aperture: aperture,
            focusDistance: focusDistance,
            autoFocusSubject: autoFocusSubject,
            apertureShape: apertureShape,
            highlightBloom: highlightBloom
        )
        if let data = try? JSONEncoder().encode(saved) {
            preferences.set(data, forKey: Self.persistenceKey)
        }
    }

    /// Optional fields allow older saved settings to inherit newly added defaults.
    private struct SavedControls: Codable {
        var version: Int = 1
        var outputMode: OutputMode?
        var fps: Int?
        var rotate180: Bool?
        var mirrorPreview: Bool?
        var autoExposure: Bool?
        var exposureUs: Int?
        var iso: Int?
        var evCompensation: Int?
        var aeLock: Bool?
        var meterOnSubject: Bool?
        var manualFocus: Bool?
        var lensPosition: Int?
        var afMode: AFMode?
        var manualWhiteBalance: Bool?
        var whiteBalanceK: Int?
        var awbMode: AWBMode?
        var awbLock: Bool?
        var antiBanding: AntiBanding?
        var sharpness: Int?
        var lumaDenoise: Int?
        var chromaDenoise: Int?
        var brightness: Int?
        var contrast: Int?
        var saturation: Int?
        var showAdvanced: Bool?
        var bokehEnabled: Bool?
        var syncBokeh: Bool?
        var uniformBlur: Bool?
        var matteQuality: MatteQuality?
        var aperture: Double?
        var focusDistance: Double?
        var autoFocusSubject: Bool?
        var apertureShape: ApertureShape?
        var highlightBloom: Double?
    }

    // MARK: - Presets

    func resetBokeh() {
        blurAmount = 0.7
        uniformBlur = true
        syncBokeh = true
        matteQuality = .accurate
    }

    func reset() {
        autoExposure = true; evCompensation = 0; aeLock = false
        meterOnSubject = false
        exposureUs = 8_000; iso = 400
        manualFocus = false; afMode = .continuousVideo; lensPosition = 120
        manualWhiteBalance = false; awbMode = .auto; whiteBalanceK = 5600; awbLock = false
        antiBanding = .hz60
        sharpness = 1; lumaDenoise = 1; chromaDenoise = 1
        brightness = 0; contrast = 0; saturation = 0
    }
}

extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(self, lo), hi) }
}
