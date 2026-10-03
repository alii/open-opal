import Foundation

/// Hardware-free regression test. Compile alongside CameraSettings.swift.
@main
struct CameraSettingsPersistenceTests {
    static func main() throws {
        let preferences = MemoryPreferences()
        let initial = CameraSettings(preferences: preferences)
        precondition(initial.lensPosition == 120 && initial.brightness == 0)
        precondition(!initial.meterOnSubject && !initial.bokehEnabled)

        initial.manualFocus = true
        initial.lensPosition = 187
        initial.brightness = -3
        initial.autoExposure = false
        initial.exposureUs = 12_000
        initial.iso = 800
        initial.manualWhiteBalance = true
        initial.whiteBalanceK = 4200
        initial.antiBanding = .hz50
        initial.outputMode = .hd720
        initial.fps = 40
        initial.mirrorPreview = false
        initial.showAdvanced = true
        initial.meterOnSubject = true
        precondition(initial.coldDirty)

        let restored = CameraSettings(preferences: preferences)
        precondition(restored.manualFocus && restored.lensPosition == 187)
        precondition(restored.brightness == -3)
        precondition(!restored.autoExposure && restored.exposureUs == 12_000 && restored.iso == 800)
        precondition(restored.manualWhiteBalance && restored.whiteBalanceK == 4200)
        precondition(restored.antiBanding == .hz50 && restored.meterOnSubject)
        precondition(restored.outputMode == .hd720 && restored.fps == 40)
        precondition(!restored.mirrorPreview && restored.showAdvanced && !restored.coldDirty)

        restored.reset()
        precondition(!restored.meterOnSubject && restored.antiBanding == .hz60)
        let reset = CameraSettings(preferences: preferences)
        precondition(!reset.manualFocus && reset.lensPosition == 120 && reset.brightness == 0)
        precondition(reset.autoExposure && reset.exposureUs == 8000)
        precondition(!reset.meterOnSubject && reset.antiBanding == .hz60)

        // Blur-only changes must save immediately, without another camera
        // control change accidentally triggering the write for them.
        let blur = CameraSettings(preferences: preferences)
        blur.bokehEnabled = true
        precondition(CameraSettings(preferences: preferences).bokehEnabled)
        blur.blurAmount = 0.4
        precondition(abs(CameraSettings(preferences: preferences).blurAmount - 0.4) < 0.000001)
        blur.syncBokeh = false
        precondition(!CameraSettings(preferences: preferences).syncBokeh)
        blur.uniformBlur = false
        precondition(!CameraSettings(preferences: preferences).uniformBlur)
        blur.matteQuality = .fast
        precondition(CameraSettings(preferences: preferences).matteQuality == .fast)
        blur.focusDistance = 0.7
        precondition(CameraSettings(preferences: preferences).focusDistance == 0.7)
        blur.autoFocusSubject = false
        precondition(!CameraSettings(preferences: preferences).autoFocusSubject)
        blur.apertureShape = .hexagonal
        precondition(CameraSettings(preferences: preferences).apertureShape == .hexagonal)
        blur.highlightBloom = 0.2
        let restoredBlur = CameraSettings(preferences: preferences)
        precondition(restoredBlur.highlightBloom == 0.2 && restoredBlur.bokehEnabled)
        precondition(abs(restoredBlur.blurAmount - 0.4) < 0.000001)
        precondition(!restoredBlur.syncBokeh && !restoredBlur.uniformBlur && restoredBlur.matteQuality == .fast)
        precondition(restoredBlur.focusDistance == 0.7 && !restoredBlur.autoFocusSubject)
        precondition(restoredBlur.apertureShape == .hexagonal && !restoredBlur.coldDirty)

        restoredBlur.resetBokeh()
        let resetBlur = CameraSettings(preferences: preferences)
        precondition(abs(resetBlur.blurAmount - 0.7) < 0.000001)
        precondition(resetBlur.uniformBlur && resetBlur.syncBokeh && resetBlur.matteQuality == .accurate)
        resetBlur.bokehEnabled = false
        precondition(!CameraSettings(preferences: preferences).bokehEnabled)

        func restore(_ json: String) -> CameraSettings {
            preferences.set(Data(json.utf8), forKey: CameraSettings.persistenceKey)
            return CameraSettings(preferences: preferences)
        }
        let partial = restore(#"{"version":1,"brightness":4}"#)
        precondition(partial.brightness == 4 && partial.lensPosition == 120)
        precondition(!partial.meterOnSubject)
        precondition(!partial.bokehEnabled && partial.aperture == 2.8)
        precondition(partial.syncBokeh && partial.uniformBlur && partial.matteQuality == .accurate)
        precondition(partial.focusDistance == 0.35 && partial.autoFocusSubject)
        precondition(partial.apertureShape == .circular && partial.highlightBloom == 0.55)
        let invalid = restore(#"{"version":1,"brightness":999,"lensPosition":-1,"fps":0,"iso":99999,"exposureUs":-1,"contrast":2}"#)
        precondition(invalid.brightness == 0 && invalid.lensPosition == 120 && invalid.fps == 30)
        precondition(invalid.iso == 400 && invalid.exposureUs == 8000 && invalid.contrast == 2)
        let invalidBlur = restore(#"{"version":1,"bokehEnabled":true,"aperture":999,"focusDistance":-1,"highlightBloom":2,"brightness":4}"#)
        precondition(invalidBlur.bokehEnabled && invalidBlur.brightness == 4)
        precondition(invalidBlur.aperture == 2.8 && invalidBlur.focusDistance == 0.35 && invalidBlur.highlightBloom == 0.55)
        for json in ["not JSON", #"{"version":1,"lensPosition":"wrong type"}"#,
                     #"{"version":1,"afMode":"unknown"}"#,
                     #"{"version":2,"brightness":4}"#] {
            let fallback = restore(json)
            precondition(fallback.brightness == 0 && fallback.lensPosition == 120 && !fallback.coldDirty)
        }
        print("Camera settings persistence: passed round-trip, reset, defaults, and invalid-data checks")
    }
}

/// Exercise real JSON persistence without changing the user's preference domain.
private final class MemoryPreferences: UserDefaults {
    private var stored: [String: Data] = [:]
    override func data(forKey defaultName: String) -> Data? { stored[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { stored[defaultName] = value as? Data }
}
