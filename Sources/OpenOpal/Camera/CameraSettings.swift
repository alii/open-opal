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

    var outputMode: OutputMode = .fhd1080 { didSet { if oldValue != outputMode { coldDirty = true } } }
    var fps: Int = 30                     { didSet { if oldValue != fps { coldDirty = true } } }

    /// Set when a cold setting changed and the pipeline needs a reboot to catch up.
    var coldDirty = false

    /// The IMX582 has no native 1080p mode — its smallest sensor config is 4K.
    /// Every mode below captures 4K and scales on the *device* ISP, because
    /// shipping full 4K NV12 over USB saturates SuperSpeed (~370 MB/s) and costs
    /// ~297ms of latency at only 20fps. Scaling first: ~50ms at a solid 30fps.
    enum OutputMode: String, CaseIterable, Identifiable {
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

    var autoExposure = true
    var exposureUs: Int = 8_000       // 1..33000 µs
    var iso: Int = 400                // 100..1600
    var evCompensation: Int = 0       // -9..9
    var aeLock = false

    /// Shutter expressed the way a photographer thinks about it.
    var shutterFraction: String {
        exposureUs <= 0 ? "—" : "1/\(Int((1_000_000.0 / Double(exposureUs)).rounded()))"
    }

    /// The sensor can't expose longer than one frame interval.
    var maxExposureUs: Int { min(33_000, Int(1_000_000.0 / Double(max(fps, 1)))) }

    // MARK: - Focus  (the C1 has a real autofocus lens)

    var manualFocus = false
    var lensPosition: Int = 120       // 0..255
    var afMode: AFMode = .continuousVideo

    enum AFMode: String, CaseIterable, Identifiable {
        case auto              = "Auto"
        case continuousVideo   = "Continuous"
        case macro             = "Macro"
        case edof              = "Extended DoF"
        var id: String { rawValue }
    }

    // MARK: - White balance

    var manualWhiteBalance = false
    var whiteBalanceK: Int = 5600     // 1000..12000
    var awbMode: AWBMode = .auto
    var awbLock = false

    enum AWBMode: String, CaseIterable, Identifiable {
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
    var antiBanding: AntiBanding = .hz60

    enum AntiBanding: String, CaseIterable, Identifiable {
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

    var sharpness: Int = 1            // 0..4
    var lumaDenoise: Int = 1          // 0..4
    var chromaDenoise: Int = 1        // 0..4
    var brightness: Int = 0           // -10..10
    var contrast: Int = 0             // -10..10
    var saturation: Int = 0           // -10..10

    // MARK: - Bokeh (host-side; see BokehRenderer)

    var bokehEnabled = false
    /// Real lens math: smaller f-number = shallower depth of field.
    var aperture: Double = 2.8        // f/1.4 .. f/16
    /// Where the focal plane sits, as normalized scene depth (0 = near, 1 = far).
    var focusDistance: Double = 0.35
    /// Follow the subject automatically instead of a fixed focal plane.
    var autoFocusSubject = true
    var apertureShape: ApertureShape = .circular
    /// Bloom on specular highlights — what makes bokeh read as glass, not blur.
    var highlightBloom: Double = 0.55

    enum ApertureShape: String, CaseIterable, Identifiable {
        case circular  = "Circular"
        case hexagonal = "Hexagonal"
        var id: String { rawValue }
    }

    // MARK: - Presets

    func reset() {
        autoExposure = true; evCompensation = 0; aeLock = false
        exposureUs = 8_000; iso = 400
        manualFocus = false; afMode = .continuousVideo; lensPosition = 120
        manualWhiteBalance = false; awbMode = .auto; whiteBalanceK = 5600; awbLock = false
        sharpness = 1; lumaDenoise = 1; chromaDenoise = 1
        brightness = 0; contrast = 0; saturation = 0
    }
}
