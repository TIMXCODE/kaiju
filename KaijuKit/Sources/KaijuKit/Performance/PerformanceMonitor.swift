import Foundation
import Combine
import Darwin

public struct PerformanceSnapshot: Sendable, Equatable {
    // Process
    public var cpuPercent: Double = 0
    public var memoryBytes: Int64 = 0
    public var threadCount: Int = 0
    // Machine
    public var systemMemoryTotal: Int64 = 0
    public var systemMemoryUsed: Int64 = 0
    public var availableDiskBytes: Int64 = 0
    // Capture / encode
    public var captureFPS: Double = 0
    public var targetFPS: Int = 0
    public var framesDropped: Int = 0
    public var framesIdle: Int = 0
    public var encoderIsHardware = false
    public var encoderCodec: String = "—"
    public var encoderRunning = false
    public var measuredBitrate: Double = 0
    public var configuredBitrate: Int = 0
    public var resolutionLabel: String = "—"
    // Buffer
    public var bufferedSeconds: TimeInterval = 0
    public var bufferCapacitySeconds: TimeInterval = 0
    public var bufferBackend: String = "—"
    public var bufferMemoryBytes: Int = 0
    public var bufferDiskBytes: Int = 0

    public init() {}

    public var systemMemoryFraction: Double {
        guard systemMemoryTotal > 0 else { return 0 }
        return Double(systemMemoryUsed) / Double(systemMemoryTotal)
    }

    public var bufferFillFraction: Double {
        guard bufferCapacitySeconds > 0 else { return 0 }
        return min(1, bufferedSeconds / bufferCapacitySeconds)
    }

    public var measuredBitrateLabel: String {
        guard measuredBitrate > 0 else { return "—" }
        return String(format: "%.1f Mbps", measuredBitrate / 1_000_000)
    }

    public var configuredBitrateLabel: String {
        guard configuredBitrate > 0 else { return "—" }
        return String(format: "%.0f Mbps", Double(configuredBitrate) / 1_000_000)
    }
}

/// Real process and machine metrics, read from mach — nothing here is estimated.
///
/// The performance panel is only useful if you can trust it, so every number it
/// shows either comes from the kernel or is a count kept by the capture pipeline
/// itself.
@MainActor
public final class PerformanceMonitor: ObservableObject {
    @Published public private(set) var snapshot = PerformanceSnapshot()

    /// Filled in by the engine each tick with capture/encode/buffer numbers.
    public var engineSampler: (() -> PerformanceSnapshot)?
    /// Folder whose free space we report.
    public var monitoredVolume: URL = StorageConfiguration.defaultSaveDirectory

    private var timer: Timer?
    private var isRunning = false

    public init() {}

    deinit { timer?.invalidate() }

    public func start(interval: TimeInterval = 1.0) {
        guard !isRunning else { return }
        isRunning = true
        sample()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        timer.tolerance = interval * 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    public func sample() {
        var next = engineSampler?() ?? PerformanceSnapshot()
        let process = SystemMetrics.processUsage()
        next.cpuPercent = process.cpuPercent
        next.memoryBytes = process.footprintBytes
        next.threadCount = process.threadCount
        let memory = SystemMetrics.systemMemory()
        next.systemMemoryTotal = memory.total
        next.systemMemoryUsed = memory.used
        next.availableDiskBytes = SystemMetrics.availableCapacity(at: monitoredVolume)
        snapshot = next
    }
}

public enum SystemMetrics {

    public struct ProcessUsage: Sendable {
        public var cpuPercent: Double
        public var footprintBytes: Int64
        public var threadCount: Int
    }

    /// Sums per-thread CPU from `thread_info`, which is the same source Activity
    /// Monitor uses. 100% means one core fully busy.
    public static func processUsage() -> ProcessUsage {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threadList else {
            return ProcessUsage(cpuPercent: 0, footprintBytes: memoryFootprint(), threadCount: 0)
        }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: threadList)),
                          vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride))
        }

        var total: Double = 0
        for index in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(THREAD_BASIC_INFO_COUNT)
            let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(threadList[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { continue }
            if info.flags & TH_FLAGS_IDLE != 0 { continue }
            total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE)
        }

        return ProcessUsage(cpuPercent: total * 100,
                            footprintBytes: memoryFootprint(),
                            threadCount: Int(threadCount))
    }

    /// `phys_footprint` is the number macOS itself uses to judge a process's
    /// memory use — the one that matters for "does this app leak".
    public static func memoryFootprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int64(info.phys_footprint)
    }

    public struct SystemMemory: Sendable {
        public var total: Int64
        public var used: Int64
    }

    public static func systemMemory() -> SystemMemory {
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size
                                           / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return SystemMemory(total: total, used: 0) }

        let pageSize = Int64(vm_kernel_page_size)
        // "Used" the way Activity Monitor means it: everything that isn't free or
        // trivially reclaimable.
        let active = Int64(statistics.active_count) * pageSize
        let wired = Int64(statistics.wire_count) * pageSize
        let compressed = Int64(statistics.compressor_page_count) * pageSize
        return SystemMemory(total: total, used: active + wired + compressed)
    }

    public static func availableCapacity(at url: URL) -> Int64 {
        var directory = url
        // Walk up until we hit something that exists; a not-yet-created save folder
        // still has a volume with free space.
        while !FileManager.default.fileExists(atPath: directory.path),
              directory.pathComponents.count > 1 {
            directory = directory.deletingLastPathComponent()
        }
        let values = try? directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage {
            return Int64(important)
        }
        return Int64(values?.volumeAvailableCapacity ?? 0)
    }

    /// Marketing-ish machine name plus core counts, shown once in the Home header.
    public static func machineDescription() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        let brand = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        let cores = ProcessInfo.processInfo.processorCount
        return brand.isEmpty ? "\(cores) cores" : "\(brand) · \(cores) cores"
    }

    public static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }
}
