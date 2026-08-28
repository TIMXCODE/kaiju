import Foundation
import Combine
import AppKit

/// Anywhere a clip can go.
///
/// The macOS share sheet is built in and always available. Anything else —
/// Discord, YouTube, an S3 bucket — plugs in as an `UploadProvider`. The clipping
/// engine has no idea any of this exists, which is the point: a broken or missing
/// integration can't affect recording.
public protocol UploadProvider: AnyObject {
    var identifier: String { get }
    var displayName: String { get }
    var symbolName: String { get }
    /// False when the provider needs credentials it doesn't have yet.
    var isConfigured: Bool { get }
    /// Uploads and returns a shareable link. Report progress 0…1.
    func upload(fileURL: URL,
                title: String,
                progress: @escaping (Double) -> Void,
                isCancelled: @escaping () -> Bool) async throws -> URL
    func deleteRemote(identifier: String) async throws
}

public struct UploadRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var clipID: UUID
    public var providerIdentifier: String
    public var remoteIdentifier: String
    public var shareURL: URL
    public var uploadedAt: Date
}

@MainActor
public final class ShareManager: ObservableObject {
    @Published public private(set) var providers: [String: any UploadProvider] = [:]
    @Published public private(set) var uploads: [UploadRecord] = []
    @Published public private(set) var activeUploadProgress: [UUID: Double] = [:]

    private var cancellations: [UUID: Guarded<Bool>] = [:]
    private let recordsURL: URL

    public init(supportDirectory: URL = SettingsStore.supportDirectory) {
        self.recordsURL = supportDirectory.appendingPathComponent("uploads.json")
        loadRecords()
    }

    // MARK: - macOS share sheet

    /// Shows the standard share sheet anchored to a view. Everything the user has
    /// installed — Messages, Mail, AirDrop, third-party extensions — shows up here
    /// for free.
    public func presentSharePicker(for urls: [URL], relativeTo view: NSView) {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }
        let picker = NSSharingServicePicker(items: existing as [Any])
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    public func copyToPasteboard(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSPasteboardWriting])
    }

    // MARK: - Providers

    public func register(_ provider: any UploadProvider) {
        providers[provider.identifier] = provider
    }

    public func unregister(identifier: String) {
        providers[identifier] = nil
    }

    public var configuredProviders: [any UploadProvider] {
        providers.values.filter(\.isConfigured)
            .sorted { $0.displayName < $1.displayName }
    }

    // MARK: - Uploading

    @discardableResult
    public func upload(clip: Clip, fileURL: URL, using providerIdentifier: String) async -> UploadRecord? {
        guard let provider = providers[providerIdentifier], provider.isConfigured else { return nil }
        let flag = Guarded(false)
        cancellations[clip.id] = flag
        activeUploadProgress[clip.id] = 0
        defer {
            cancellations[clip.id] = nil
            activeUploadProgress[clip.id] = nil
        }

        do {
            let shareURL = try await provider.upload(
                fileURL: fileURL,
                title: clip.title,
                progress: { fraction in
                    Task { @MainActor [weak self] in
                        self?.activeUploadProgress[clip.id] = fraction
                    }
                },
                isCancelled: { flag.current })

            let record = UploadRecord(clipID: clip.id,
                                      providerIdentifier: providerIdentifier,
                                      remoteIdentifier: shareURL.lastPathComponent,
                                      shareURL: shareURL,
                                      uploadedAt: Date())
            uploads.append(record)
            saveRecords()
            return record
        } catch {
            KaijuLog.app.error("Upload failed: \(String(describing: error))")
            return nil
        }
    }

    public func cancelUpload(for clipID: UUID) {
        cancellations[clipID]?.withLock { $0 = true }
    }

    public func uploads(for clipID: UUID) -> [UploadRecord] {
        uploads.filter { $0.clipID == clipID }
    }

    public func deleteUpload(_ record: UploadRecord) async {
        if let provider = providers[record.providerIdentifier] {
            try? await provider.deleteRemote(identifier: record.remoteIdentifier)
        }
        uploads.removeAll { $0.id == record.id }
        saveRecords()
    }

    // MARK: - Persistence

    private func loadRecords() {
        guard let data = try? Data(contentsOf: recordsURL),
              let decoded = try? JSONDecoder().decode([UploadRecord].self, from: data) else { return }
        uploads = decoded
    }

    private func saveRecords() {
        let snapshot = uploads
        let url = recordsURL
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(snapshot).write(to: url, options: .atomic)
        }
    }
}
