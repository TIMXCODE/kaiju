import Foundation
import os

/// Central logging. Uses the unified logging system so it costs almost nothing
/// when nobody is listening, which matters while a game is running.
public enum KaijuLog {
    public static let subsystem = "com.mac.Kaiju"

    public static let capture  = Logger(subsystem: subsystem, category: "capture")
    public static let encoder  = Logger(subsystem: subsystem, category: "encoder")
    public static let buffer   = Logger(subsystem: subsystem, category: "buffer")
    public static let audio    = Logger(subsystem: subsystem, category: "audio")
    public static let clips    = Logger(subsystem: subsystem, category: "clips")
    public static let hotkeys  = Logger(subsystem: subsystem, category: "hotkeys")
    public static let games    = Logger(subsystem: subsystem, category: "games")
    public static let export   = Logger(subsystem: subsystem, category: "export")
    public static let perf     = Logger(subsystem: subsystem, category: "performance")
    public static let app      = Logger(subsystem: subsystem, category: "app")
}
