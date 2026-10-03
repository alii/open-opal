import AppKit
import CoreMediaIO
import Foundation
import OSLog

private let log = Logger(subsystem: "com.openopal.launcher", category: "demand")

/// Listens to camera metadata only. This helper never opens a stream or loads
/// the camera bridge. All CMIO calls and mutable state stay on one serial queue.
final class CameraDemandWatcher: @unchecked Sendable {
    private let hostURL: URL
    private let queue = DispatchQueue(label: "com.openopal.launcher.demand")
    private var policy = CameraLaunchPolicy()
    private var deviceListener: Listener?
    private var streamsListener: Listener?
    private var demandListener: Listener?

    init(hostURL: URL) { self.hostURL = hostURL }

    func start() {
        queue.async { [self] in
            guard deviceListener == nil else { return }
            deviceListener = listen(
                to: CMIOObjectID(kCMIOObjectSystemObject),
                address: Self.address(kCMIOHardwarePropertyDevices)
            ) { [weak self] in self?.rediscover() }
            guard deviceListener != nil else { return }
            rediscover()
        }
    }

    private func rediscover() {
        guard let devices = objects(CMIOObjectID(kCMIOObjectSystemObject),
                                    address: Self.address(kCMIOHardwarePropertyDevices)) else { return }
        let device = devices.first {
            string($0, address: Self.address(kCMIODevicePropertyDeviceUID)) == CameraDemand.deviceUID
        }

        if streamsListener?.object != device {
            remove(&streamsListener)
            remove(&demandListener)
            _ = policy.updateDemand(false)
            if let device {
                streamsListener = listen(
                    to: device,
                    address: Self.address(kCMIODevicePropertyStreams,
                                          scope: kCMIODevicePropertyScopeInput)
                ) { [weak self] in self?.rediscover() }
            }
        }

        var stream: CMIOObjectID?
        if let device {
            guard let streams = objects(device, address: Self.address(kCMIODevicePropertyStreams,
                                                        scope: kCMIODevicePropertyScopeInput)) else { return }
            stream = streams.first {
                // Legacy CMIO: 1 is input/capture, unlike the extension enum.
                guard uint32($0, address: Self.address(kCMIOStreamPropertyDirection)) == 1
                else { return false }
                var address = CameraDemand.address
                return CMIOObjectHasProperty($0, &address)
            }
        }

        if demandListener?.object != stream {
            remove(&demandListener)
            _ = policy.updateDemand(false)
            if let stream {
                demandListener = listen(to: stream, address: CameraDemand.address) { [weak self] in
                    self?.readDemand()
                }
            }
        }
        // Subscribe before reading: a client may already be capturing, or may
        // start between discovery and listener registration.
        readDemand()
    }

    private func readDemand() {
        guard let stream = demandListener?.object,
              let value = string(stream, address: CameraDemand.address) else { return }
        guard let active = CameraDemand.isActive(value) else {
            log.error("Unrecognized camera demand value: \(value, privacy: .public)")
            return
        }
        guard policy.updateDemand(active) else { return }

        Task { @MainActor [self] in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = false
            configuration.createsNewApplicationInstance = false
            NSWorkspace.shared.openApplication(at: hostURL, configuration: configuration) { [self] _, error in
                if let error {
                    log.error("Could not open host app: \(error.localizedDescription, privacy: .public)")
                }
                queue.async { [self] in policy.launchCompleted() }
            }
        }
    }

    private struct Listener {
        let object: CMIOObjectID
        var address: CMIOObjectPropertyAddress
        let block: CMIOObjectPropertyListenerBlock
    }

    private func listen(to object: CMIOObjectID, address: CMIOObjectPropertyAddress,
                        changed: @escaping @Sendable () -> Void) -> Listener? {
        var address = address
        let block: CMIOObjectPropertyListenerBlock = { _, _ in changed() }
        let status = CMIOObjectAddPropertyListenerBlock(object, &address, queue, block)
        guard status == noErr else {
            log.error("Could not watch CMIO object \(object): \(status)")
            return nil
        }
        return Listener(object: object, address: address, block: block)
    }

    private func remove(_ listener: inout Listener?) {
        guard var existing = listener else { return }
        let status = CMIOObjectRemovePropertyListenerBlock(
            existing.object, &existing.address, queue, existing.block)
        if status != noErr {
            // A disappeared device can invalidate its listener before removal.
            log.debug("CMIO listener removal for \(existing.object) returned \(status)")
        }
        listener = nil
    }

    private static func address(_ selector: Int,
                                scope: Int = kCMIOObjectPropertyScopeGlobal)
        -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: UInt32(selector), mScope: UInt32(scope),
                                  mElement: UInt32(kCMIOObjectPropertyElementMain))
    }

    private func objects(_ object: CMIOObjectID, address: CMIOObjectPropertyAddress) -> [CMIOObjectID]? {
        var address = address
        var size: UInt32 = 0
        let sizeStatus = CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size)
        guard sizeStatus == noErr else {
            log.debug("Could not size CMIO object list for \(object): \(sizeStatus)")
            return nil
        }
        guard Int(size) % MemoryLayout<CMIOObjectID>.size == 0 else { return nil }
        if size == 0 { return [] }
        var values = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &values)
        guard status == noErr, used <= size else {
            log.debug("Could not read CMIO object list for \(object): \(status)")
            return nil
        }
        return Array(values.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    private func uint32(_ object: CMIOObjectID, address: CMIOObjectPropertyAddress) -> UInt32? {
        var address = address
        var value: UInt32 = 0
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &value) == noErr,
              used == size else { return nil }
        return value
    }

    private func string(_ object: CMIOObjectID, address: CMIOObjectPropertyAddress) -> String? {
        var address = address
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &value) == noErr,
              used == size, let value else { return nil }
        // CF-valued CMIO properties return an owned reference, including the
        // custom NSString property bridged by the camera extension.
        return value.takeRetainedValue() as String
    }
}
