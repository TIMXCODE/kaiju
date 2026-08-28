import Foundation
import Combine
import AVFoundation

public struct ExportJob: Identifiable, Equatable {
    public enum State: Equatable {
        case preparing
        case running
        case finished
        case failed(KaijuError)
        case cancelled

        public var isActive: Bool { self == .preparing || self == .running }
        public var label: String {
            switch self {
            case .preparing: return "Preparing…"
            case .running:   return "Exporting…"
            case .finished:  return "Done"
            case .failed:    return "Failed"
            case .cancelled: return "Cancelled"
            }
        }
    }

    public let id: UUID
    public var sourceClipID: UUID?
    public var title: String
    public var outputURL: URL
    public var progress: Double
    public var state: State
    public var startedAt: Date
    public var finishedAt: Date?

    public var progressPercent: Int { Int((progress * 100).rounded()) }

    public var elapsed: TimeInterval {
        (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }
}

/// Runs exports off the main thread, one job at a time, with real progress.
///
/// Progress is driven by output timestamps as frames are written, so the bar
/// tracks actual work rather than a timer. Cancelling stops between frames and
/// deletes the partial file.
@MainActor
public final class ExportManager: ObservableObject {
    @Published public private(set) var jobs: [ExportJob] = []

    /// Set by the app so a finished export can land in the library.
    public var onExportFinished: ((ExportJob, Clip?) -> Void)?

    private var cancellationFlags: [UUID: Guarded<Bool>] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let library: ClipLibrary?

    public init(library: ClipLibrary? = nil) {
        self.library = library
    }

    public var activeJobs: [ExportJob] { jobs.filter { $0.state.isActive } }
    public var isBusy: Bool { !activeJobs.isEmpty }

    @discardableResult
    public func export(sourceURL: URL,
                       outputURL: URL,
                       title: String,
                       plan: EditPlan,
                       settings: ExportSettings,
                       sourceClipID: UUID? = nil,
                       addToLibrary: Bool = true) -> UUID {
        let id = UUID()
        var job = ExportJob(id: id,
                            sourceClipID: sourceClipID,
                            title: title,
                            outputURL: outputURL,
                            progress: 0,
                            state: .preparing,
                            startedAt: Date())
        jobs.insert(job, at: 0)

        let flag = Guarded(false)
        cancellationFlags[id] = flag

        // Overlays are laid out on the main actor before the export starts, so the
        // render loop never has to touch AppKit.
        let outputSize = plannedOutputSize(sourceURL: sourceURL, plan: plan, settings: settings)

        tasks[id] = Task { [weak self] in
            guard let self else { return }
            let overlays = OverlayRenderer.prepare(plan: plan, outputSize: outputSize)
            self.update(id) { $0.state = .running }

            let request = VideoExportPipeline.Request(sourceURL: sourceURL,
                                                      outputURL: outputURL,
                                                      plan: plan,
                                                      settings: settings,
                                                      overlays: overlays)
            do {
                _ = try await VideoExportPipeline.run(
                    request,
                    progress: { fraction in
                        Task { @MainActor [weak self] in
                            self?.update(id) { $0.progress = fraction }
                        }
                    },
                    isCancelled: { flag.current })

                self.update(id) {
                    $0.state = .finished
                    $0.progress = 1
                    $0.finishedAt = Date()
                }

                var created: Clip?
                if addToLibrary, let library = self.library {
                    let gameName = sourceClipID.flatMap { identifier in
                        library.clips.first { $0.id == identifier }?.gameName
                    }
                    let bundle = sourceClipID.flatMap { identifier in
                        library.clips.first { $0.id == identifier }?.gameBundleIdentifier
                    }
                    if outputURL.deletingLastPathComponent() == library.directory,
                       let clip = await ClipLibrary.makeClip(from: outputURL,
                                                             kind: .edited,
                                                             gameName: gameName,
                                                             gameBundleIdentifier: bundle,
                                                             title: title) {
                        library.add(clip)
                        created = clip
                    }
                }

                if let finished = self.jobs.first(where: { $0.id == id }) {
                    NotificationManager.shared.exportCompleted(name: finished.title, at: outputURL)
                    self.onExportFinished?(finished, created)
                }
            } catch let error as KaijuError {
                self.update(id) {
                    $0.state = (error == .exportCancelled) ? .cancelled : .failed(error)
                    $0.finishedAt = Date()
                }
                if error != .exportCancelled { NotificationManager.shared.problem(error) }
            } catch {
                let wrapped = KaijuError.exportFailed(reason: error.localizedDescription)
                self.update(id) {
                    $0.state = .failed(wrapped)
                    $0.finishedAt = Date()
                }
                NotificationManager.shared.problem(wrapped)
            }

            self.cancellationFlags[id] = nil
            self.tasks[id] = nil
        }

        job.state = .running
        return id
    }

    public func cancel(_ id: UUID) {
        cancellationFlags[id]?.withLock { $0 = true }
    }

    public func cancelAll() {
        for flag in cancellationFlags.values { flag.withLock { $0 = true } }
    }

    public func clearFinished() {
        jobs.removeAll { !$0.state.isActive }
    }

    private func update(_ id: UUID, _ mutate: (inout ExportJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&jobs[index])
    }

    /// Best-effort output size for laying out overlays. Uses the settings preset
    /// when one is chosen and falls back to 1080p only if the source can't be read.
    private func plannedOutputSize(sourceURL: URL, plan: EditPlan, settings: ExportSettings) -> CGSize {
        if !settings.matchSource, let height = settings.resolution.targetHeight {
            return CGSize(width: CGFloat(height) * 16.0 / 9.0, height: CGFloat(height))
        }
        if let clip = library?.clips.first(where: { $0.fileName == sourceURL.lastPathComponent }),
           clip.width > 0 {
            let width = CGFloat(clip.width) * (plan.cropRect?.width ?? 1)
            let height = CGFloat(clip.height) * (plan.cropRect?.height ?? 1)
            return CGSize(width: width, height: height)
        }
        return CGSize(width: 1920, height: 1080)
    }

    /// Somewhere to put an export that isn't going back into the library.
    public static func defaultOutputURL(for title: String, in directory: URL) -> URL {
        let safe = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        var candidate = directory.appendingPathComponent("\(safe) (edited).mp4")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(safe) (edited \(counter)).mp4")
            counter += 1
        }
        return candidate
    }
}
