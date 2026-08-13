import Foundation
import os

/// Subsystem loggers. Wine process output additionally goes to per-run log
/// files (planned); these are for SyntheholKit's own events.
public enum Log {
    public static let runtime = Logger(
        subsystem: SyntheholPaths.bundleIdentifier, category: "Runtime"
    )
    public static let wine = Logger(
        subsystem: SyntheholPaths.bundleIdentifier, category: "Wine"
    )
    public static let steam = Logger(
        subsystem: SyntheholPaths.bundleIdentifier, category: "Steam"
    )
}
