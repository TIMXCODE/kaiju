import Foundation
import Combine
import AVFoundation

public struct MicrophoneDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let isDefault: Bool
}

/// Lists audio input devices for the Audio settings picker. Only enumerates —
/// it never opens a device, so browsing the list can't trip the mic indicator.
@MainActor
public final class MicrophoneCatalog: ObservableObject {
    @Published public private(set) var devices: [MicrophoneDevice] = []

    private var observers: [NSObjectProtocol] = []

    public init() {
        refresh()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureDevice.wasConnectedNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    public func refresh() {
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone],
                                                       mediaType: .audio,
                                                       position: .unspecified)
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        devices = session.devices.map {
            MicrophoneDevice(id: $0.uniqueID,
                             name: $0.localizedName,
                             isDefault: $0.uniqueID == defaultID)
        }
    }

    public func device(withID id: String?) -> MicrophoneDevice? {
        guard let id else { return devices.first(where: \.isDefault) }
        return devices.first { $0.id == id } ?? devices.first(where: \.isDefault)
    }

    /// True when a device the user picked earlier is no longer plugged in.
    public func isSelectionMissing(_ id: String?) -> Bool {
        guard let id, !id.isEmpty else { return false }
        return !devices.contains { $0.id == id }
    }
}
