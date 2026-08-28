import Foundation
import KaijuKit
import ScreenCaptureKit
import CoreGraphics
import AVFoundation

// kaijuctl — the engine with no app around it.
//
// The whole point of this tool is that the recording path can be proved before a
// single pixel of interface exists. If `kaijuctl record` writes a playable file
// with synced audio, the hard part is done.

func printUsage() {
    print("""
    kaijuctl — Kaiju replay engine harness

    USAGE
      kaijuctl doctor
          Check permissions, hardware encoders and capture sources.

      kaijuctl sources
          List displays, windows and applications ScreenCaptureKit can capture.

      kaijuctl record [options]
          Run the replay buffer, then save the last N seconds out of it.

      kaijuctl soak [options]
          Run the buffer for a long time and print memory every few seconds.
          Use this to prove the buffer doesn't grow.

    OPTIONS (record / soak)
      --seconds <n>      How long to run the buffer.        default 30
      --clip <n>         Seconds to save from the buffer.   default 15
      --buffer <n>       Replay buffer length in seconds.   default 60
      --fps <30|60|120>  Capture frame rate.                default 60
      --res <720|1080|1440|2160|native>                     default 1080
      --codec <h264|hevc>                                   default h264
      --display <id>     Capture a specific display.
      --app <bundle-id>  Capture one application.
      --window <id>      Capture one window.
      --mic              Also capture the microphone.
      --no-audio         Capture no audio at all.
      --out <path>       Where to write the clip. default ~/Movies/Kaiju
      --clips <n>        Save this many clips in a row.     default 1
    """)
}

struct Arguments {
    var values: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: [String]) {
        var index = 0
        while index < raw.count {
            let token = raw[index]
            guard token.hasPrefix("--") else { index += 1; continue }
            let key = String(token.dropFirst(2))
            if index + 1 < raw.count, !raw[index + 1].hasPrefix("--") {
                values[key] = raw[index + 1]
                index += 2
            } else {
                flags.insert(key)
                index += 1
            }
        }
    }

    func int(_ key: String, _ fallback: Int) -> Int { values[key].flatMap(Int.init) ?? fallback }
    func double(_ key: String, _ fallback: Double) -> Double { values[key].flatMap(Double.init) ?? fallback }
    func string(_ key: String) -> String? { values[key] }
    func has(_ key: String) -> Bool { flags.contains(key) || values[key] != nil }
}

func makeOptions(_ arguments: Arguments) -> HeadlessRecorder.Options {
    var options = HeadlessRecorder.Options()

    options.recording.frameRate = FrameRateOption(rawValue: arguments.int("fps", 60)) ?? .fps60
    switch arguments.string("res") ?? "1080" {
    case "720":    options.recording.resolution = .p720
    case "1440":   options.recording.resolution = .p1440
    case "2160", "4k", "4K": options.recording.resolution = .p2160
    case "native": options.recording.resolution = .native
    default:       options.recording.resolution = .p1080
    }
    options.recording.codec = (arguments.string("codec") == "hevc") ? .hevc : .h264

    options.replay.bufferSeconds = arguments.double("buffer", 60)
    options.replay.instantReplaySeconds = arguments.double("clip", 15)
    options.replay.captureClipSeconds = arguments.double("clip", 15)

    options.audio.captureSystemAudio = !arguments.flags.contains("no-audio")
    options.audio.captureMicrophone = arguments.flags.contains("mic")

    if let display = arguments.string("display").flatMap({ UInt32($0) }) { options.displayID = display }
    if let window = arguments.string("window").flatMap({ UInt32($0) }) { options.windowID = window }
    if let bundle = arguments.string("app") { options.applicationBundleID = bundle }

    return options
}

func outputDirectory(_ arguments: Arguments) -> URL {
    if let path = arguments.string("out") {
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }
    return StorageConfiguration.defaultSaveDirectory
}

// MARK: - Commands

func doctor() async {
    print("Kaiju engine check")
    print(String(repeating: "─", count: 46))
    print("Machine          \(SystemMetrics.machineDescription())")
    print("Apple Silicon    \(SystemMetrics.isAppleSilicon ? "yes" : "no")")

    let screen = CGPreflightScreenCaptureAccess()
    print("Screen recording \(screen ? "granted" : "NOT GRANTED")")
    if !screen {
        print("                 Run this from a terminal that has Screen Recording permission,")
        print("                 or grant it in System Settings › Privacy & Security.")
    }

    let mic = AVCaptureDevice.authorizationStatus(for: .audio)
    print("Microphone       \(mic == .authorized ? "granted" : String(describing: mic))")

    for codec in VideoCodecOption.allCases {
        let encoder = VideoEncoder()
        var configuration = VideoEncoderConfiguration(width: 1920, height: 1080, codec: codec,
                                                      bitrate: 12_000_000, frameRate: 60,
                                                      keyframeIntervalSeconds: 1,
                                                      requireHardware: true)
        do {
            try encoder.start(configuration)
            print("\(codec.displayName.padding(toLength: 16, withPad: " ", startingAt: 0))hardware encoder available")
            encoder.teardown()
        } catch {
            configuration.requireHardware = false
            if (try? encoder.start(configuration)) != nil {
                print("\(codec.displayName.padding(toLength: 16, withPad: " ", startingAt: 0))software only")
                encoder.teardown()
            } else {
                print("\(codec.displayName.padding(toLength: 16, withPad: " ", startingAt: 0))unavailable")
            }
        }
    }

    if screen {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            print("Displays         \(content.displays.count)")
            print("Windows          \(content.windows.count)")
            print("Applications     \(content.applications.count)")
        } catch {
            print("Sources          failed: \(error.localizedDescription)")
        }
    }

    let saveDirectory = StorageConfiguration.defaultSaveDirectory
    let free = SystemMetrics.availableCapacity(at: saveDirectory)
    print("Save folder      \(saveDirectory.path)")
    print("Free space       \(free.fileSizeString)")
}

func listSources() async {
    guard CGPreflightScreenCaptureAccess() else {
        print("Screen Recording permission is missing — nothing to list.")
        return
    }
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        print("DISPLAYS")
        for display in content.displays {
            let mode = CGDisplayCopyDisplayMode(display.displayID)
            let pixels = mode.map { "\($0.pixelWidth)×\($0.pixelHeight)" } ?? "\(display.width)×\(display.height)"
            print("  \(display.displayID)\t\(pixels)")
        }
        print("\nAPPLICATIONS")
        for app in content.applications.sorted(by: { $0.applicationName < $1.applicationName }) {
            guard !app.bundleIdentifier.isEmpty else { continue }
            print("  \(app.bundleIdentifier)\t\(app.applicationName)")
        }
        print("\nWINDOWS")
        for window in content.windows where window.frame.width > 200 {
            let owner = window.owningApplication?.applicationName ?? "?"
            print("  \(window.windowID)\t\(owner) — \(window.title ?? "")")
        }
    } catch {
        print("Couldn't list sources: \(error.localizedDescription)")
    }
}

func record(_ arguments: Arguments) async {
    let options = makeOptions(arguments)
    let runSeconds = arguments.double("seconds", 30)
    let clipSeconds = arguments.double("clip", 15)
    let clipCount = max(1, arguments.int("clips", 1))
    let directory = outputDirectory(arguments)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let recorder = HeadlessRecorder()
    print("Starting buffer — \(options.recording.resolution.displayName) @ \(options.recording.frameRate.rawValue) fps, \(options.recording.codec.displayName)")
    do {
        try await recorder.start(options)
    } catch let error as KaijuError {
        print("Couldn't start: \(error.title) — \(error.failureReason ?? "")")
        if let fix = error.recoverySuggestion { print("  \(fix)") }
        exit(1)
    } catch {
        print("Couldn't start: \(error.localizedDescription)")
        exit(1)
    }

    print("Backend: \(recorder.backend.displayName)")
    let started = Date()
    while Date().timeIntervalSince(started) < runSeconds {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let stats = recorder.captureStats
        let buffer = recorder.bufferStatus
        let performance = recorder.performance()
        print(String(format: "  t=%4.0fs  fps %5.1f  buffered %5.1fs  cpu %4.1f%%  rss %6.1f MB  drops %d",
                     Date().timeIntervalSince(started),
                     stats.measuredFPS,
                     buffer.bufferedSeconds,
                     SystemMetrics.processUsage().cpuPercent,
                     Double(SystemMetrics.memoryFootprint()) / 1_048_576,
                     performance.framesDropped))
        if let error = recorder.lastError {
            print("  pipeline error: \(error.title) — \(error.failureReason ?? "")")
            break
        }
    }

    for index in 1...clipCount {
        let url = directory.appendingPathComponent("kaijuctl-\(Int(Date().timeIntervalSince1970))-\(index).mp4")
        do {
            let outcome = try await recorder.save(duration: clipSeconds, to: url)
            print(String(format: "Saved %@  %.2fs  %@  %dx%d  written in %.2fs  audio tracks: %d",
                         url.lastPathComponent, outcome.duration,
                         outcome.byteCount.fileSizeString,
                         outcome.width, outcome.height,
                         outcome.writeSeconds, outcome.audioTrackCount))
        } catch let error as KaijuError {
            print("Save failed: \(error.title) — \(error.failureReason ?? "")")
        } catch {
            print("Save failed: \(error.localizedDescription)")
        }
        // Prove the buffer survives a save: keep going and take another one.
        if index < clipCount { try? await Task.sleep(nanoseconds: 2_000_000_000) }
    }

    await recorder.stop()
    print("Buffer stopped.")
}

func soak(_ arguments: Arguments) async {
    var options = makeOptions(arguments)
    if !arguments.has("buffer") { options.replay.bufferSeconds = 120 }
    let runSeconds = arguments.double("seconds", 600)

    let recorder = HeadlessRecorder()
    do {
        try await recorder.start(options)
    } catch {
        print("Couldn't start: \(error.localizedDescription)")
        exit(1)
    }

    print("Soak test — \(Int(runSeconds))s, buffer \(Int(options.replay.effectiveBufferSeconds))s, backend \(recorder.backend.displayName)")
    print("A healthy run holds RSS flat once the buffer is full.\n")
    print("   time     rss(MB)   buffered   fps    drops")

    let started = Date()
    var peak: Double = 0
    while Date().timeIntervalSince(started) < runSeconds {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        let rss = Double(SystemMetrics.memoryFootprint()) / 1_048_576
        peak = max(peak, rss)
        let buffer = recorder.bufferStatus
        let performance = recorder.performance()
        print(String(format: "  %5.0fs   %8.1f   %7.1fs  %5.1f   %5d",
                     Date().timeIntervalSince(started), rss,
                     buffer.bufferedSeconds, recorder.captureStats.measuredFPS,
                     performance.framesDropped))
    }

    await recorder.stop()
    print("\nPeak RSS \(String(format: "%.1f", peak)) MB")
}

// MARK: - Entry point

let rawArguments = Array(CommandLine.arguments.dropFirst())
let command = rawArguments.first ?? "help"
let arguments = Arguments(Array(rawArguments.dropFirst()))

switch command {
case "doctor":  await doctor()
case "sources": await listSources()
case "record":  await record(arguments)
case "soak":    await soak(arguments)
default:        printUsage()
}
