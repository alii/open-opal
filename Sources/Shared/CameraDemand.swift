import CoreMediaIO
import Foundation

/// Metadata shared by the camera extension and its demand observer. Reading
/// this source-stream property never starts a stream or opens the physical C1.
enum CameraDemand {
    // Keep this identity stable: capture applications remember the device UID.
    static let deviceUID = "7E671FBA-4A0A-4B0A-8F5D-3A1A1B4DE6F2"
    static var deviceUUID: UUID { UUID(uuidString: deviceUID)! }

    // CMIO's custom-property bridge encodes selector, scope, and element in
    // the extension key. NSString bridges to a CFString value in the C API.
    static let property = CMIOExtensionProperty(rawValue: "4cc_opdm_glob_0000")
    static let selector: CMIOObjectPropertySelector = 0x6F70646D // 'opdm'
    static var address: CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: selector,
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    static func propertyState(isActive: Bool) -> CMIOExtensionPropertyState<AnyObject> {
        CMIOExtensionPropertyState(
            value: (isActive ? "1" : "0") as NSString,
            attributes: CMIOExtensionPropertyAttributes<AnyObject>(
                minValue: nil, maxValue: nil,
                validValues: ["0" as NSString, "1" as NSString], readOnly: true))
    }

    /// Unknown values are unavailable metadata, never an implicit stop signal.
    static func isActive(_ value: String) -> Bool? {
        switch value {
        case "0": return false
        case "1": return true
        default: return nil
        }
    }
}
